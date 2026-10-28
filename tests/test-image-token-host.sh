#!/usr/bin/env bash
# test-image-token-host.sh — network-less regression test for the image
# download policy in lib/issue-images.sh (_image_url_gets_token,
# _image_url_may_fetch, _download_one, download_issue_images).
#
# INVARIANTS PROTECTED:
#   1. The operator's gh token is sent ONLY to an exactly parsed GitHub image
#      host. A shell glob is not a host check — `*` also matches `/`, so
#      https://attacker.example/x.githubusercontent.com/a.png used to receive
#      `Authorization: Bearer <token>`.
#   2. Nothing outside GitHub's own image hosts is fetched at all (SSRF): image
#      URLs come from the issue body and comments, whose authors are not
#      trusted, and must not make the runner request the LAN, localhost, the
#      tailnet or a cloud metadata service — not even via a redirect.
#
# Layers: the pure predicates over tables of URLs, and _download_one with a
# curl shim on PATH that records each call's argv and replays a scripted
# response — so the assertions are on what would actually be requested and
# sent. Positive controls keep the negative assertions from passing vacuously.
#
# The file runs itself once per distinct bash it finds (3.2 is /bin/bash on
# macOS; a Homebrew bash gives 5, also when unlinked as in CI), because set -u
# array semantics differ.
#
# Run: bash tests/test-image-token-host.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"

if [ -z "${IMAGE_TOKEN_HOST_VARIANT:-}" ]; then
  seen="" rc=0 modern=0
  for b in "$BASH" /bin/bash "$(command -v bash 2>/dev/null || true)" \
           /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash \
           /opt/homebrew/opt/bash/bin/bash /usr/local/opt/bash/bin/bash; do
    [ -n "$b" ] && [ -x "$b" ] || continue
    ver=$("$b" -c 'printf %s "$BASH_VERSION"' 2>/dev/null) || continue
    case "|$seen|" in *"|$ver|"*) continue ;; esac
    seen="$seen|$ver"
    case "$ver" in [4-9].*|[1-9][0-9]*) modern=1 ;; esac
    echo "=== variant: bash $ver ($b)"
    IMAGE_TOKEN_HOST_VARIANT=1 "$b" "$SELF" || rc=1
  done
  [ "$modern" -eq 1 ] || echo "SKIP: bash 5 variant (no bash >= 4 found)"
  exit "$rc"
fi

IMG_LIB="$HERE/../lib/issue-images.sh"

WORK=$(mktemp -d -t image-token-host.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=lib/issue-images.sh
. "$IMG_LIB"
# The lib sets -e; this test collects failures instead.
set +e

FAIL=0

gets_token() {
  local url="$1"
  if _image_url_gets_token "$url"; then
    echo "ok: token for $url"
  else
    echo "FAIL: expected token for $url"; FAIL=1
  fi
}

no_token() {
  local url="$1"
  if _image_url_gets_token "$url"; then
    echo "FAIL: token would be sent to $url"; FAIL=1
  else
    echo "ok: no token for $url"
  fi
}

may_fetch() {
  if _image_url_may_fetch "$1"; then
    echo "ok: may fetch $1"
  else
    echo "FAIL: expected fetch allowed for $1"; FAIL=1
  fi
}

no_fetch() {
  if _image_url_may_fetch "$1"; then
    echo "FAIL: fetch would be allowed for $1"; FAIL=1
  else
    echo "ok: no fetch for $1"
  fi
}

# === Predicate: GitHub's own image hosts get the token =====================
gets_token "https://github.com/user-attachments/assets/0f1e2d3c-aaaa-bbbb-cccc-123456789abc"
gets_token "https://github.com/owner/repo/assets/12345/0f1e2d3c-aaaa"
gets_token "https://github.com/owner/repo/raw/main/x.png"
gets_token "https://user-images.githubusercontent.com/1/a.png"
gets_token "https://private-user-images.githubusercontent.com/1/a.png?jwt=eyJ0eXAi.x.y"
gets_token "https://raw.githubusercontent.com/owner/repo/main/x.png"

# === Predicate: attacks and out-of-scope targets ===========================
no_token "https://attacker.example/x.githubusercontent.com/a.png"
no_token "https://attacker.example#.githubusercontent.com/a.png"
no_token "https://attacker.example?.githubusercontent.com/"
no_token "https://github.com@attacker.example/user-attachments/x"
no_token "https://github.com:443@attacker.example/"
no_token "https://github.com:443/user-attachments/x"
no_token 'https://attacker.example\@github.com/user-attachments/x'
no_token "https://github .com/user-attachments/x"
no_token "https://user-images.githubusercontent.com.attacker.example/a.png"
no_token "https://raw.githubusercontent.com.attacker.example/a.png"
no_token "https://evil.githubusercontent.com/a.png"
no_token "https://github.com.attacker.example/user-attachments/x"
no_token "https://GITHUB.COM/user-attachments/x"
no_token "http://github.com/user-attachments/x"
no_token "https://example.com/diagram.png"
no_token "https://objects.githubusercontent.com/github-production-user-asset/x"
no_token "https://github-production-user-asset-6210df.s3.amazonaws.com/1/a.png"

# === Predicate: fetch allow-list (SSRF) ====================================
may_fetch "https://github.com/user-attachments/assets/0f1e2d3c-aaaa"
may_fetch "https://raw.githubusercontent.com/owner/repo/main/x.png"
may_fetch "https://objects.githubusercontent.com/github-production-user-asset/x"
may_fetch "https://github-production-user-asset-6210df.s3.amazonaws.com/1/a.png?X-Amz-Signature=abc"
no_fetch "https://example.com/x.png"
no_fetch "https://127.0.0.1/x.png"
no_fetch "http://localhost/x.png"
no_fetch "https://localhost/x.png"
no_fetch "http://169.254.169.254/latest/meta-data/"
no_fetch "https://169.254.169.254/latest/meta-data/"
no_fetch "https://metadata.google.internal/computeMetadata/v1/"
no_fetch "https://10.0.0.1/x.png"
no_fetch "https://192.168.1.1/x.png"
no_fetch "https://172.16.0.1/x.png"
no_fetch "https://100.100.100.100/x.png"
no_fetch "https://[::1]/x.png"
no_fetch "https://2130706433/x.png"
no_fetch "file:///etc/passwd"
no_fetch "https://github-production-user-asset-.s3.amazonaws.com/a.png"
no_fetch "https://github-production-user-asset-x.y.s3.amazonaws.com/a.png"
no_fetch "https://github-production-user-asset-EVIL.s3.amazonaws.com/a.png"
no_fetch "https://evil-github-production-user-asset-6210df.s3.amazonaws.com/a.png"
no_fetch "https://github-production-user-asset-6210df.s3.amazonaws.com.attacker.example/a"

# === _download_one with a recording, scripted curl shim ====================
# CURL_SCRIPT holds one response per call, "<http_code> <redirect_url>"; call
# N records its argv to $CURL_LOG_DIR/call-N. No call file ⇒ never invoked.
SHIM_DIR="$WORK/bin"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/curl" <<'SHIM'
#!/usr/bin/env bash
n=$(( $(ls "$CURL_LOG_DIR" | wc -l) + 1 ))
log="$CURL_LOG_DIR/call-$n"
: > "$log"
out=""
while [ "$#" -gt 0 ]; do
  printf '%s\n' "$1" >> "$log"
  if [ "$1" = "-o" ]; then out="$2"; fi
  shift
done
line=$(sed -n "${n}p" "$CURL_SCRIPT")
code=${line%% *}
redirect=""
case "$line" in *" "*) redirect=${line#* } ;; esac
[ -n "$code" ] || code=200
if [ "${code#2}" != "$code" ]; then
  printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89' > "$out"
else
  : > "$out"
fi
printf '%s\n%s\n' "$code" "$redirect"
SHIM
chmod +x "$SHIM_DIR/curl"
export CURL_SCRIPT="$WORK/curl-script"

# run_download <url> <name> [response ...] — runs _download_one under the shim
# with a fresh call log; sets DL_RC and DL_ERR (stderr file).
DL_RC=0
DL_ERR=""
run_download() {
  local url="$1" name="$2"; shift 2
  export CURL_LOG_DIR="$WORK/calls-$name"
  rm -rf "$CURL_LOG_DIR"; mkdir -p "$CURL_LOG_DIR"
  : > "$CURL_SCRIPT"
  local r
  for r in "$@"; do printf '%s\n' "$r" >> "$CURL_SCRIPT"; done
  DL_ERR="$WORK/err-$name"
  # Subshell: a set -u abort inside _download_one must fail this test (the
  # call-count checks), not end the whole script silently.
  ( PATH="$SHIM_DIR:$PATH"; set -euo pipefail; _download_one "$url" "$WORK/image-$name" "tok" ) >/dev/null 2>"$DL_ERR"
  DL_RC=$?
}

calls() { ls "$CURL_LOG_DIR" | wc -l | tr -d ' '; }

# Refused before curl runs: external, private, loopback, metadata, tailnet.
for url in \
    "https://attacker.example/x.githubusercontent.com/a.png" \
    "https://example.com/x.png" \
    "https://127.0.0.1/x.png" \
    "http://localhost/x.png" \
    "http://169.254.169.254/latest/meta-data/" \
    "https://10.0.0.1/x.png" \
    "https://192.168.1.1/x.png" \
    "https://100.100.100.100/x.png" \
    "https://[::1]/x.png"; do
  run_download "$url" refused 200
  if [ "$(calls)" -ne 0 ]; then
    echo "FAIL: curl was invoked for $url"; FAIL=1
  elif [ "$DL_RC" -eq 0 ]; then
    echo "FAIL: _download_one succeeded for $url"; FAIL=1
  elif ! grep -q 'refusing non-GitHub image host' "$DL_ERR"; then
    echo "FAIL: no refusal log line for $url"; FAIL=1
  else
    echo "ok: refused without a request: $url"
  fi
done

# Every token host gets the header (positive control for the refusals above).
for url in \
    "https://github.com/user-attachments/assets/0f1e2d3c-aaaa" \
    "https://github.com/owner/repo/assets/1/0f1e2d3c" \
    "https://private-user-images.githubusercontent.com/1/a.png?jwt=x" \
    "https://raw.githubusercontent.com/o/r/main/x.png" \
    "https://user-images.githubusercontent.com/1/a.png"; do
  run_download "$url" tokhost 200
  if [ "$DL_RC" -eq 0 ] && grep -qx 'Authorization: Bearer tok' "$CURL_LOG_DIR/call-1" 2>/dev/null; then
    echo "ok: Authorization sent to $url"
  else
    echo "FAIL: Authorization not sent to $url (rc=$DL_RC)"; FAIL=1
  fi
done

# A fetchable non-token host is requested without the header.
run_download "https://objects.githubusercontent.com/x" storage 200
if [ "$(calls)" -eq 1 ] && ! grep -q 'Authorization' "$CURL_LOG_DIR/call-1" && [ "$DL_RC" -eq 0 ]; then
  echo "ok: storage host fetched without Authorization"
else
  echo "FAIL: storage host — calls=$(calls) rc=$DL_RC or Authorization sent"; FAIL=1
fi

# No hop may follow redirects on its own or leave https.
if grep -qx -- '-L' "$CURL_LOG_DIR/call-1" || ! grep -qx '=https' "$CURL_LOG_DIR/call-1"; then
  echo "FAIL: curl called with -L or without --proto =https"; FAIL=1
else
  echo "ok: curl called without -L and with --proto =https"
fi

# Redirects from an allowed host to a refused one: one request, then refusal.
for target in \
    "http://169.254.169.254/latest/meta-data/" \
    "https://10.0.0.1/x.png" \
    "https://attacker.example/x.png"; do
  run_download "https://github.com/user-attachments/assets/abc" redir "302 $target"
  if [ "$(calls)" -ne 1 ]; then
    echo "FAIL: redirect to $target — curl called $(calls) times, expected 1"; FAIL=1
  elif [ "$DL_RC" -eq 0 ]; then
    echo "FAIL: redirect to $target — _download_one succeeded"; FAIL=1
  elif ! grep -q 'refusing redirect' "$DL_ERR"; then
    echo "FAIL: redirect to $target — no 'refusing redirect' log line"; FAIL=1
  else
    echo "ok: redirect refused: $target"
  fi
done

# Control: the real attachment chain — token on the first hop, not on S3.
S3="https://github-production-user-asset-6210df.s3.amazonaws.com/1/a.png?X-Amz-Signature=abc"
run_download "https://github.com/user-attachments/assets/abc" chain "302 $S3" "200"
if [ "$DL_RC" -ne 0 ] || [ "$(calls)" -ne 2 ]; then
  echo "FAIL: attachment chain — rc=$DL_RC calls=$(calls), expected 0 and 2"; FAIL=1
elif ! grep -qx 'Authorization: Bearer tok' "$CURL_LOG_DIR/call-1"; then
  echo "FAIL: attachment chain — first hop sent no Authorization"; FAIL=1
elif grep -q 'Authorization' "$CURL_LOG_DIR/call-2"; then
  echo "FAIL: attachment chain — Authorization forwarded to S3"; FAIL=1
elif ! grep -qxF "$S3" "$CURL_LOG_DIR/call-2"; then
  echo "FAIL: attachment chain — second hop did not request the S3 URL"; FAIL=1
else
  echo "ok: attachment chain — token on github.com, none on S3"
fi

# A cross-host redirect between two token hosts drops the token too.
run_download "https://github.com/o/r/assets/1/x" xhost \
  "302 https://private-user-images.githubusercontent.com/1/a.png?jwt=x" "200"
if [ "$DL_RC" -eq 0 ] && [ "$(calls)" -eq 2 ] && ! grep -q 'Authorization' "$CURL_LOG_DIR/call-2"; then
  echo "ok: no Authorization across a host change"
else
  echo "FAIL: cross-host redirect — rc=$DL_RC calls=$(calls) or Authorization forwarded"; FAIL=1
fi

# Redirect loop is bounded.
loop=()
for _ in 1 2 3 4 5 6 7 8; do loop+=("302 https://github.com/user-attachments/assets/abc"); done
RUN_ISSUES_IMAGE_MAX_REDIRECTS=3 run_download "https://github.com/user-attachments/assets/abc" loop "${loop[@]}"
if [ "$DL_RC" -ne 0 ] && [ "$(calls)" -eq 4 ] && grep -q 'too many redirects' "$DL_ERR"; then
  echo "ok: redirect chain capped"
else
  echo "FAIL: redirect cap — rc=$DL_RC calls=$(calls)"; FAIL=1
fi

# === download_issue_images: refusals are listed, never fatal ===============
FIXTURE="$WORK/issue.json"
cat > "$FIXTURE" <<'JSON'
{"body": "![a](https://example.com/x.png)\n![b](http://169.254.169.254/latest/meta-data/)\n![c](https://github.com/user-attachments/assets/abc)", "comments": []}
JSON
export CURL_LOG_DIR="$WORK/calls-full"
rm -rf "$CURL_LOG_DIR"; mkdir -p "$CURL_LOG_DIR"
printf '200\n' > "$CURL_SCRIPT"
DEST="$WORK/attachments"
gh() { echo tok; }
out=$( ( PATH="$SHIM_DIR:$PATH"; set -euo pipefail; download_issue_images "$FIXTURE" "$DEST" ) 2>/dev/null )
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: download_issue_images returned $rc"; FAIL=1
elif [ "$out" != "$DEST/image-01.png" ]; then
  echo "FAIL: download_issue_images printed '$out', expected only $DEST/image-01.png"; FAIL=1
elif [ "$(calls)" -ne 1 ]; then
  echo "FAIL: download_issue_images made $(calls) requests, expected 1"; FAIL=1
elif ! grep -qxF "https://example.com/x.png" "$DEST/skipped-urls.txt" \
  || ! grep -qxF "http://169.254.169.254/latest/meta-data/" "$DEST/skipped-urls.txt"; then
  echo "FAIL: skipped-urls.txt does not list the refused URLs"; FAIL=1
else
  echo "ok: download_issue_images fetched the GitHub image only and listed the rest"
fi

block=$(ISSUE_IMAGES_SKIPPED=$(cat "$DEST/skipped-urls.txt" 2>/dev/null) build_issue_images_block)
if printf '%s' "$block" | grep -q 'ei ladattu' && printf '%s' "$block" | grep -qF 'https://example.com/x.png'; then
  echo "ok: prompt block names the skipped URLs"
else
  echo "FAIL: prompt block does not name the skipped URLs"; FAIL=1
fi
if [ -z "$(build_issue_images_block)" ]; then
  echo "ok: prompt block empty with no images and no skipped URLs"
else
  echo "FAIL: prompt block not empty with nothing to report"; FAIL=1
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "image-token-host (bash $BASH_VERSION): all passed" || echo "image-token-host (bash $BASH_VERSION): FAILURES"
[ "$FAIL" -eq 0 ]
