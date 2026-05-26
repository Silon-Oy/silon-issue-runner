#!/usr/bin/env bash
# test-image-extraction.sh — network-less regression test for extract_image_urls
# (lib/issue-images.sh).
#
# INVARIANT PROTECTED: image URL recognition is a pure, deterministic function
# over the issue JSON (body + comments). It must:
#   - recognise Markdown images ![alt](url), HTML <img src="url">, and bare
#     GitHub attachment URLs (github.com/user-attachments + user-images.*);
#   - SKIP bot comments (bodies containing the "run-issues:" token), like
#     detect_answer;
#   - deduplicate a URL that appears in both the body and a comment;
#   - NOT match non-image Markdown links [text](url).
#
# No network: a synthetic issue-JSON fixture drives the function. (Downloading
# is best-effort and network-bound, so — like db-clone — it is not unit-tested.)
#
# Run: bash tests/test-image-extraction.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG_LIB="$HERE/../lib/issue-images.sh"

WORK=$(mktemp -d -t image-extract.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=lib/issue-images.sh
. "$IMG_LIB"

DUP_URL="https://github.com/user-attachments/assets/dup-1111-2222"

FIX="$WORK/issue.json"
jq -n \
  --arg dup "$DUP_URL" \
  '{
    title: "t",
    body: ("Korjaa tämä, ks. kuvakaappaus:\n"
      + "![screenshot](https://github.com/user-attachments/assets/aaaa-bbbb)\n"
      + "Mockup HTML:nä: <img alt=\"m\" src=\"https://user-images.githubusercontent.com/1/cccc.png\">\n"
      + "Diagrammi markdownina, jossa otsikko: ![d](https://example.com/diagram.png \"otsikko\")\n"
      + "Tavallinen linkki EI ole kuva: [docs](https://example.com/readme.md)\n"
      + "Sama kuva myös kommentissa: " + $dup + "\n"),
    comments: [
      # Human comment with an HTML img + the duplicate attachment URL (deduped).
      { author: {login: "maintainer"}, createdAt: "2026-05-26T10:00:00Z",
        body: ("Tässä lisäkuva: <img src='\''https://github.com/user-attachments/assets/eeee-ffff'\''/>\n"
          + "ja sama kuin bodyssä: " + $dup) },
      # Bot comment (contains run-issues:) — its image MUST be skipped.
      { author: {login: "maintainer"}, createdAt: "2026-05-26T10:01:00Z",
        body: "<!-- run-issues:awaiting-answer --> ![bot](https://github.com/user-attachments/assets/9999-bot)" }
    ]
  }' > "$FIX"

FAIL=0
URLS=$(extract_image_urls "$FIX")
echo "--- extract_image_urls output ---"; echo "$URLS"

want() {
  local desc="$1" pat="$2"
  if printf '%s\n' "$URLS" | grep -qF -- "$pat"; then
    echo "ok: $desc"
  else
    echo "FAIL: missing $desc ($pat)"; FAIL=1
  fi
}
reject() {
  local desc="$1" pat="$2"
  if printf '%s\n' "$URLS" | grep -qF -- "$pat"; then
    echo "FAIL: should not contain $desc ($pat)"; FAIL=1
  else
    echo "ok: rejected $desc"
  fi
}

# Markdown image in body
want   "markdown image (body)"        "https://github.com/user-attachments/assets/aaaa-bbbb"
# HTML img in body (double-quoted)
want   "html img (body)"              "https://user-images.githubusercontent.com/1/cccc.png"
# Markdown image with a title — URL only, no title, no trailing paren
want   "markdown image with title"    "https://example.com/diagram.png"
# HTML img in a human comment (single-quoted, self-closing)
want   "html img (comment)"           "https://github.com/user-attachments/assets/eeee-ffff"
# Duplicate across body + comment
want   "duplicate url present once"   "$DUP_URL"

# Non-image markdown link must NOT match
reject "non-image markdown link"      "https://example.com/readme.md"
# Bot-comment image must be skipped
reject "bot-comment image"            "https://github.com/user-attachments/assets/9999-bot"
# The title text must not leak into the captured URL
reject "markdown title leak"          "otsikko"

# Dedup: the duplicated URL appears exactly once.
DUP_COUNT=$(printf '%s\n' "$URLS" | grep -cF -- "$DUP_URL")
if [ "$DUP_COUNT" -eq 1 ]; then
  echo "ok: duplicate url deduped (count=1)"
else
  echo "FAIL: duplicate url count=$DUP_COUNT (expected 1)"; FAIL=1
fi

# === No images -> empty output =============================================
FIX2="$WORK/issue-noimages.json"
jq -n '{ title: "t", body: "Pelkkää tekstiä, ei kuvia. [linkki](https://x.test/a.md)", comments: [] }' > "$FIX2"
URLS2=$(extract_image_urls "$FIX2")
echo "--- extract_image_urls (no images) output ---"; echo "[$URLS2]"
[ -z "$URLS2" ] || { echo "FAIL: expected empty output for issue with no images"; FAIL=1; }

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "image-extraction: all passed" || echo "image-extraction: FAILURES"
[ "$FAIL" -eq 0 ]
