#!/usr/bin/env bash
# lib/issue-images.sh — extract and download images embedded in a GitHub issue
# (body + comments) so the cycle-review and implementer agents can SEE them.
#
# Why: claude-call.sh deliberately runs `npx @anthropic-ai/claude-code -p` in
# text mode through the Claude plan (cost control) — it never makes a multimodal
# API call. So an issue that leans on a screenshot/mockup ("fix this, see image")
# arrives at the agent as a bare Markdown line `![alt](url)`; the agent cannot
# see the pixels. The fix stays in the plan-billing model: download the images
# locally and tell the agent to open them with the Read tool, which renders
# images visually in the Claude Code CLI.
#
# Two responsibilities, kept separate so the URL recognition is a pure,
# fixture-testable function (mirroring detect_answer / parse_marker in issue.sh):
#   1. extract_image_urls <issue-json>  — pure: prints deduped image URLs.
#   2. download_issue_images <issue-json> <dest> — best-effort: downloads them
#      with the gh token and prints local paths. Never fails the run.
#
# All download failures (auth/network/404/non-image) degrade gracefully: the URL
# is skipped with a log line and the run proceeds in text mode, exactly like the
# no-images case.

set -euo pipefail

# Caps to keep the run dir and the prompt path-list bounded (an issue could in
# principle embed dozens of large images).
RUN_ISSUES_MAX_IMAGES="${RUN_ISSUES_MAX_IMAGES:-10}"
# Per-image wall-clock budget for the download.
RUN_ISSUES_IMAGE_TIMEOUT="${RUN_ISSUES_IMAGE_TIMEOUT:-60}"
# Per-image size ceiling (bytes) — curl aborts when the server advertises a
# larger Content-Length. Default 10 MiB.
RUN_ISSUES_MAX_IMAGE_BYTES="${RUN_ISSUES_MAX_IMAGE_BYTES:-10485760}"

_img_log() {
  printf '[issue-images %s] %s\n' "$(date -u +%FT%TZ)" "$*" >&2
}

# _dedup_lines — read stdin, drop empty/whitespace-only lines, and emit each
# distinct line once, preserving first-occurrence order (deterministic).
_dedup_lines() {
  awk 'NF && !seen[$0]++'
}

# _extract_image_urls_from_text — read a text blob on stdin and print every
# image URL it references, one per line, deduped. Recognises:
#   1. Markdown images:  ![alt](URL)            (also ![alt](URL "title"))
#   2. HTML images:      <img ... src="URL">    (single- or double-quoted)
#   3. GitHub attachment URLs pasted bare:
#        https://github.com/user-attachments/assets/…
#        https://user-images.githubusercontent.com/…
# A GitHub attachment URL inside a Markdown image matches both (1) and (3); the
# dedup pass collapses it to one. Non-image Markdown links `[text](url)` do NOT
# match — the leading `!` is required.
_extract_image_urls_from_text() {
  local text
  text=$(cat)
  # Each pattern pipeline ends in `|| true`: grep exits 1 on "no match", which
  # under this lib's `set -euo pipefail` would otherwise abort the extraction
  # (or make the function return non-zero) the moment any one pattern finds
  # nothing — the common case. Neutralizing it keeps extraction total and pure.
  {
    # 1. Markdown image URL — stop at whitespace or ')' so a `"title"` suffix and
    #    the closing paren are excluded.
    printf '%s\n' "$text" \
      | grep -oE '!\[[^]]*\]\([^)[:space:]]+' \
      | sed -E 's/^!\[[^]]*\]\(//' || true
    # 2. HTML <img> src — isolate the tag first, then its src attribute, then
    #    strip the src= and surrounding quotes (quoted or bare value).
    printf '%s\n' "$text" \
      | grep -oiE '<img[^>]*>' \
      | grep -oiE 'src=("[^"]*"|'\''[^'\'']*'\''|[^[:space:]>"'\'']+)' \
      | sed -E 's/^[Ss][Rr][Cc]=//; s/^["'\'']//; s/["'\'']$//' || true
    # 3. Bare GitHub attachment URLs (two known hosts).
    printf '%s\n' "$text" \
      | grep -oE 'https://github\.com/user-attachments/assets/[A-Za-z0-9._/-]+' || true
    printf '%s\n' "$text" \
      | grep -oE 'https://user-images\.githubusercontent\.com/[A-Za-z0-9._/?=&%-]+' || true
  } | _dedup_lines
}

# extract_image_urls <issue-json-file>
# Pure function: prints deduped image URLs found in the issue body and in every
# comment that is NOT a run-issues bot comment (bodies containing the
# "run-issues:" token are skipped, mirroring detect_answer). One URL per line;
# empty output when the issue references no images.
extract_image_urls() {
  local fixture="$1"
  jq -r '
    ( [ (.body // "") ]
      + [ .comments[]?
          | select((.body // "" | contains("run-issues:")) | not)
          | (.body // "") ]
    )
    | join("\n")
  ' "$fixture" | _extract_image_urls_from_text
}

# _detect_image_ext <downloaded-file> — print a file extension (with leading
# dot) for a downloaded file, or empty string if it is NOT an image. The MIME
# type from `file` is authoritative because GitHub attachment URLs carry no
# extension (they are opaque UUIDs); a non-image MIME (e.g. an HTML login page
# returned when auth failed) yields empty so the caller skips it.
_detect_image_ext() {
  local f="$1"
  local mime
  mime=$(file -b --mime-type "$f" 2>/dev/null || echo "")
  case "$mime" in
    image/png)      printf '.png' ;;
    image/jpeg)     printf '.jpg' ;;
    image/gif)      printf '.gif' ;;
    image/webp)     printf '.webp' ;;
    image/svg+xml)  printf '.svg' ;;
    image/*)        printf '.img' ;;
    *)              printf '' ;;
  esac
}

# _download_one <url> <out-base> <token> — download a single image best-effort.
# On success renames to <out-base><ext> and prints that path; returns non-zero
# on any failure (bad scheme, HTTP error, network, or non-image content). The gh
# token is sent ONLY to github.com hosts (private user-attachments need it) and
# is never forwarded across a redirect to a different host — curl drops the
# Authorization header on cross-host redirects by default, so it cannot leak to
# the signed S3 asset URL the attachment redirects to.
_download_one() {
  local url="$1" out_base="$2" token="$3"

  # Only fetch over http(s). Guards against file:// and other schemes.
  case "$url" in
    https://*|http://*) ;;
    *) _img_log "skipping non-http(s) URL"; return 1 ;;
  esac

  local -a auth=()
  case "$url" in
    https://github.com/*|https://*.githubusercontent.com/*)
      [ -n "$token" ] && auth=(-H "Authorization: Bearer $token") ;;
  esac

  local tmp="${out_base}.download"
  # -f fail on HTTP >=400, -s/-S quiet but show errors, -L follow redirects,
  # bounded by time and advertised size.
  if ! curl -fsSL "${auth[@]}" \
        --max-time "$RUN_ISSUES_IMAGE_TIMEOUT" \
        --max-filesize "$RUN_ISSUES_MAX_IMAGE_BYTES" \
        -o "$tmp" "$url" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi

  local ext
  ext=$(_detect_image_ext "$tmp")
  if [ -z "$ext" ]; then
    _img_log "downloaded content is not an image (auth failure or wrong URL?) — skipping"
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi

  mv "$tmp" "${out_base}${ext}"
  printf '%s\n' "${out_base}${ext}"
}

# download_issue_images <issue-json-file> <dest-dir>
# Best-effort: download the images referenced by the issue into <dest-dir> and
# print the local paths of those that succeeded (one per line). Always returns 0
# — a failed download never breaks the run (graceful degradation).
#
# Idempotent reuse: if <dest-dir> already holds image-* files (a prior call on
# the S6->S8 path, or a --restart/--continue re-run), those are reused without
# re-downloading. Filenames are deterministic (image-NN<ext>) given the stable,
# deduped URL order from extract_image_urls.
download_issue_images() {
  local fixture="$1" dest="$2"
  local max="$RUN_ISSUES_MAX_IMAGES"

  if [ -d "$dest" ]; then
    local existing
    existing=$(find "$dest" -maxdepth 1 -type f -name 'image-*' 2>/dev/null | sort)
    if [ -n "$existing" ]; then
      printf '%s\n' "$existing"
      return 0
    fi
  fi

  local urls
  urls=$(extract_image_urls "$fixture")
  [ -n "$urls" ] || return 0

  mkdir -p "$dest"

  # Resolve the gh token once. Never logged, never written to disk.
  local token=""
  token=$(gh auth token 2>/dev/null || true)

  local i=0 url out_base
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    i=$((i + 1))
    if [ "$i" -gt "$max" ]; then
      _img_log "image cap ($max) reached — skipping remaining URLs"
      break
    fi
    out_base="$dest/$(printf 'image-%02d' "$i")"
    _download_one "$url" "$out_base" "$token" || _img_log "download $i failed — degrading gracefully"
  done <<EOF
$urls
EOF
  return 0
}

# build_issue_images_block <path1> [<path2> ...] — produce the {{ISSUE_IMAGES}}
# prompt block listing the downloaded image paths with a Read-tool instruction.
# Empty output when given no paths, so the prompt section collapses cleanly
# (mirroring CLARIFICATION_CONTEXT / RESTART_CONTEXT).
build_issue_images_block() {
  [ "$#" -gt 0 ] || return 0
  printf '### Issueen liitetyt kuvat\n\n'
  printf 'Tähän issueen on liitetty %d kuva(a), jotka on ladattu paikallisesti. **Lue jokainen Read-työkalulla** — Claude Code -CLI:n Read näyttää kuvat visuaalisesti, joten näet kuvakaappausten, mockuppien tai diagrammien sisällön:\n\n' "$#"
  local p
  for p in "$@"; do
    printf -- '- `%s`\n' "$p"
  done
}
