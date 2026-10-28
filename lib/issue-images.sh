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
#   2. download_issue_images <issue-json> <dest> — best-effort: downloads those
#      on GitHub's own image hosts (gh token only where _image_url_gets_token
#      allows) and prints local paths. Never fails the run.
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
# Maximum redirect hops _download_one follows by hand (each one re-checked).
RUN_ISSUES_IMAGE_MAX_REDIRECTS="${RUN_ISSUES_IMAGE_MAX_REDIRECTS:-5}"

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

# _image_url_host <url> — print the host of an https URL, rc 1 if there is
# none we are willing to compare. Pure (no network). The host is parsed out of
# the URL rather than matched with a shell glob: `*` also matches `/`, `?`, `#`
# and `@`, so "https://*.githubusercontent.com/*" would accept
# https://attacker.example/x.githubusercontent.com/a.png. The authority must not
# carry userinfo (`@`), a port (`:` — this also rejects every IPv6 literal), a
# backslash or whitespace. Callers compare the result case-sensitively on
# purpose: an unexpected spelling is refused, not normalised (fail-closed).
_image_url_host() {
  local url="$1"
  case "$url" in
    https://*) ;;
    *) return 1 ;;
  esac

  local rest authority
  rest=${url#https://}
  authority=${rest%%[/?#]*}

  [ -n "$authority" ] || return 1
  case "$authority" in
    *[@:\\[:space:]]*) return 1 ;;
  esac
  printf '%s\n' "$authority"
}

# _image_url_gets_token <url> — rc 0 iff the gh token may be sent to <url>.
# Pure, so the decision is unit-testable. GitHub's own image hosts only:
#   - github.com, any path (user-attachments, <owner>/<repo>/assets, /raw/ …) —
#     narrowing the path adds nothing, the token goes to GitHub either way
#   - user-images.githubusercontent.com          (legacy attachments)
#   - private-user-images.githubusercontent.com  (private-repo attachments)
#   - raw.githubusercontent.com                  (private-repo files)
_image_url_gets_token() {
  local host
  host=$(_image_url_host "$1") || return 1
  case "$host" in
    github.com|user-images.githubusercontent.com|private-user-images.githubusercontent.com|raw.githubusercontent.com)
      return 0 ;;
  esac
  return 1
}

# _image_url_may_fetch <url> — rc 0 iff the runner may download <url> at all.
# Pure. The allow-list is the token hosts plus the storage hosts GitHub
# attachments redirect to (fetched WITHOUT the token: a signed S3 URL rejects an
# extra Authorization header):
#   - objects.githubusercontent.com
#   - github-production-user-asset-<[a-z0-9]+>.s3.amazonaws.com
#
# Why an allow-list and not "any public address": image URLs come from the
# issue body and comments, whose authors are not trusted, so an open fetch is
# SSRF — the runner machine would request the LAN, localhost, the tailnet or a
# cloud metadata service on the author's behalf. Refusing private addresses
# instead would need name resolution, and there is no portable resolver across
# macOS, Linux and Git Bash (getent, dig, dscacheutil each miss one); it would
# also need --resolve pinning against DNS rebinding and parsing of every IP
# spelling (IPv6, v4-mapped, decimal, octal). Each of those is a new way to
# fail open. Any other host is reported to the agent instead (skipped-urls.txt).
_image_url_may_fetch() {
  local host
  host=$(_image_url_host "$1") || return 1
  _image_url_gets_token "$1" && return 0
  case "$host" in
    objects.githubusercontent.com) return 0 ;;
  esac
  local prefix="github-production-user-asset-" suffix=".s3.amazonaws.com" mid
  case "$host" in
    "$prefix"*"$suffix") ;;
    *) return 1 ;;
  esac
  mid=${host#"$prefix"}
  mid=${mid%"$suffix"}
  [ -n "$mid" ] || return 1
  # Spelled out, not a range: bash 3.2 matches [a-z] by locale collation, so
  # under a UTF-8 locale it also accepts uppercase (aAbB…z).
  case "$mid" in
    *[!abcdefghijklmnopqrstuvwxyz0123456789]*) return 1 ;;
  esac
  return 0
}

# _download_one <url> <out-base> <token> — download a single image best-effort.
# On success renames to <out-base><ext> and prints that path; returns non-zero
# on any failure (refused host, HTTP error, network, or non-image content).
#
# Redirects are followed by hand, not with `curl -L`: every hop's target must
# pass _image_url_may_fetch BEFORE it is requested, so an allowed host cannot
# bounce the runner to a private address. The token is decided per hop: sent
# only when the hop passes _image_url_gets_token AND stays on the original
# URL's host (the cross-host drop `curl -L` used to provide).
_download_one() {
  local url="$1" out_base="$2" token="$3"

  local origin_host
  if ! _image_url_may_fetch "$url"; then
    _img_log "refusing non-GitHub image host $(_image_url_host "$url" 2>/dev/null || echo '(unparsable or non-https)')"
    return 1
  fi
  origin_host=$(_image_url_host "$url")

  local tmp="${out_base}.download"
  local hop=0 meta code next host
  local -a auth
  while :; do
    auth=()
    host=$(_image_url_host "$url")
    if [ -n "$token" ] && [ "$host" = "$origin_host" ] && _image_url_gets_token "$url"; then
      auth=(-H "Authorization: Bearer $token")
    fi
    # -f fail on HTTP >=400 (3xx returns 0), no -L: redirects are handled
    # below. https only, bounded by time and advertised size.
    # ${auth[@]+...}: an empty array is "unbound" under set -u on bash 3.2.
    if ! meta=$(curl -fsS ${auth[@]+"${auth[@]}"} \
          --proto '=https' \
          --max-time "$RUN_ISSUES_IMAGE_TIMEOUT" \
          --max-filesize "$RUN_ISSUES_MAX_IMAGE_BYTES" \
          -w '%{http_code}\n%{redirect_url}\n' \
          -o "$tmp" "$url" 2>/dev/null); then
      rm -f "$tmp" 2>/dev/null || true
      return 1
    fi
    code=$(printf '%s\n' "$meta" | sed -n 1p)
    next=$(printf '%s\n' "$meta" | sed -n 2p)
    case "$code" in
      2??) break ;;
      3??) ;;
      *)
        _img_log "unexpected HTTP status $code — skipping"
        rm -f "$tmp" 2>/dev/null || true
        return 1 ;;
    esac
    rm -f "$tmp" 2>/dev/null || true
    hop=$((hop + 1))
    if [ "$hop" -gt "$RUN_ISSUES_IMAGE_MAX_REDIRECTS" ]; then
      _img_log "too many redirects (> $RUN_ISSUES_IMAGE_MAX_REDIRECTS) — skipping"
      return 1
    fi
    if [ -z "$next" ] || ! _image_url_may_fetch "$next"; then
      _img_log "refusing redirect to $(_image_url_host "$next" 2>/dev/null || echo '(unparsable or non-https)')"
      return 1
    fi
    url="$next"
  done

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
# Filenames are deterministic (image-NN<ext>) given the stable, deduped URL order
# from extract_image_urls; a re-run overwrites them in place. The orchestrator's
# prepare_issue_images guards against re-running within a single process (so the
# S6->S8 chain downloads once); a separate --continue/--restart/--resume process
# re-downloads from the freshest issue.json on purpose, so a clarification reply
# that adds a new screenshot is picked up.
#
# URLs refused by _image_url_may_fetch are not requested at all: they consume
# neither an image-NN number nor the cap, and are written one per line to
# <dest>/skipped-urls.txt so the prompt can name them. stdout stays paths only.
download_issue_images() {
  local fixture="$1" dest="$2"
  local max="$RUN_ISSUES_MAX_IMAGES"

  local urls
  urls=$(extract_image_urls "$fixture")
  [ -n "$urls" ] || return 0

  mkdir -p "$dest"
  local skipped_file="$dest/skipped-urls.txt"
  rm -f "$skipped_file" 2>/dev/null || true

  # Resolve the gh token once. Never logged, never written to disk.
  local token=""
  token=$(gh auth token 2>/dev/null || true)

  local i=0 url out_base
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    if ! _image_url_may_fetch "$url"; then
      _img_log "refusing non-GitHub image host $(_image_url_host "$url" 2>/dev/null || echo '(unparsable or non-https)') — listed in the prompt instead"
      printf '%s\n' "$url" >> "$skipped_file"
      continue
    fi
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
# ISSUE_IMAGES_SKIPPED (newline-separated URLs, optional) adds a note naming the
# image URLs that were not downloaded because their host is not GitHub's own.
# Empty output when there are neither paths nor skipped URLs, so the prompt
# section collapses cleanly (mirroring CLARIFICATION_CONTEXT / RESTART_CONTEXT).
build_issue_images_block() {
  local skipped="${ISSUE_IMAGES_SKIPPED:-}"
  [ "$#" -gt 0 ] || [ -n "$skipped" ] || return 0
  printf '### Issueen liitetyt kuvat\n\n'
  if [ "$#" -gt 0 ]; then
    printf 'Tähän issueen on liitetty %d kuva(a), jotka on ladattu paikallisesti. **Lue jokainen Read-työkalulla** — Claude Code -CLI:n Read näyttää kuvat visuaalisesti, joten näet kuvakaappausten, mockuppien tai diagrammien sisällön:\n\n' "$#"
    local p
    for p in "$@"; do
      printf -- '- `%s`\n' "$p"
    done
  fi
  if [ -n "$skipped" ]; then
    [ "$#" -gt 0 ] && printf '\n'
    printf 'Seuraavia kuvaosoitteita ei ladattu, koska ne eivät ole GitHubin omilla kuvapalvelimilla (runner ei hae issuen kirjoittajan valitsemia osoitteita). Et näe niiden sisältöä:\n\n'
    local u
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      printf -- '- `%s`\n' "$(printf '%s' "$u" | tr -d '`')"
    done <<EOF
$skipped
EOF
  fi
}
