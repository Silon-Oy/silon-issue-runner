#!/usr/bin/env bash
# test-image-token-host.sh — network-less regression test for the gh-token
# host decision in lib/issue-images.sh (_image_url_gets_token, _download_one).
#
# INVARIANT PROTECTED: the operator's gh token is sent ONLY to an exactly
# parsed GitHub attachment host. A shell glob is not a host check — `*` also
# matches `/`, so https://attacker.example/x.githubusercontent.com/a.png used
# to receive `Authorization: Bearer <token>`. Image URLs come from the issue
# body and comments, whose authors are not trusted.
#
# Two layers: the pure predicate over a table of URLs, and _download_one with a
# curl shim on PATH that records its argv — so the assertion is on what would
# actually be sent. The shim's positive control keeps the negative assertion
# from passing vacuously (e.g. if the header were never sent at all).
#
# Run: bash tests/test-image-token-host.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG_LIB="$HERE/../lib/issue-images.sh"

WORK=$(mktemp -d -t image-token-host.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=lib/issue-images.sh
. "$IMG_LIB"

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

# === Predicate: legitimate attachments =====================================
gets_token "https://github.com/user-attachments/assets/0f1e2d3c-aaaa-bbbb-cccc-123456789abc"
gets_token "https://user-images.githubusercontent.com/1/a.png"

# === Predicate: attacks and out-of-scope targets ===========================
no_token "https://attacker.example/x.githubusercontent.com/a.png"
no_token "https://attacker.example#.githubusercontent.com/a.png"
no_token "https://attacker.example?.githubusercontent.com/"
no_token "https://github.com@attacker.example/user-attachments/x"
no_token "https://github.com:443@attacker.example/"
no_token "https://github.com:443/user-attachments/x"
no_token 'https://attacker.example\@github.com/user-attachments/x'
no_token "https://user-images.githubusercontent.com.attacker.example/a.png"
no_token "https://user-images.githubusercontent.com"
no_token "https://evil.githubusercontent.com/a.png"
no_token "https://github.com.attacker.example/user-attachments/x"
no_token "https://GITHUB.COM/user-attachments/x"
no_token "http://github.com/user-attachments/x"
no_token "https://github.com/owner/repo/raw/main/x.png"
no_token "https://github.com/user-attachmentsX/x"
no_token "https://example.com/diagram.png"

# === _download_one with a recording curl shim ==============================
SHIM_DIR="$WORK/bin"
mkdir -p "$SHIM_DIR"
ARGS_LOG="$WORK/curl-args"
cat > "$SHIM_DIR/curl" <<'SHIM'
#!/usr/bin/env bash
# Records argv one per line, then writes a minimal PNG to the -o target.
: > "$CURL_ARGS_LOG"
out=""
while [ "$#" -gt 0 ]; do
  printf '%s\n' "$1" >> "$CURL_ARGS_LOG"
  if [ "$1" = "-o" ]; then out="$2"; fi
  shift
done
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89' > "$out"
SHIM
chmod +x "$SHIM_DIR/curl"
export CURL_ARGS_LOG="$ARGS_LOG"

run_download() {
  local url="$1" n="$2"
  PATH="$SHIM_DIR:$PATH" _download_one "$url" "$WORK/image-$n" "tok" >/dev/null 2>&1
}

ATTACK="https://attacker.example/x.githubusercontent.com/a.png"
run_download "$ATTACK" 1
if [ ! -s "$ARGS_LOG" ]; then
  echo "FAIL: curl shim was not invoked for $ATTACK"; FAIL=1
elif grep -q 'Authorization' "$ARGS_LOG"; then
  echo "FAIL: _download_one sent Authorization to $ATTACK"; FAIL=1
else
  echo "ok: _download_one sent no Authorization to $ATTACK"
fi

CONTROL="https://github.com/user-attachments/assets/0f1e2d3c-aaaa"
run_download "$CONTROL" 2
if grep -qx 'Authorization: Bearer tok' "$ARGS_LOG"; then
  echo "ok: _download_one sent Authorization to $CONTROL (control)"
else
  echo "FAIL: control — _download_one did not send Authorization to $CONTROL"; FAIL=1
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "image-token-host: all passed" || echo "image-token-host: FAILURES"
[ "$FAIL" -eq 0 ]
