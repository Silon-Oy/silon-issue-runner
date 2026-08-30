#!/usr/bin/env bash
# test-github-app-auth.sh — regression coverage for lib/github-app-auth.sh.
#
# What this protects
# ------------------
# 1. gha_enabled responds correctly to the three opt-in env vars + .pem
#    presence (off by default, on when configured, fail-closed when key
#    missing/unreadable — so misconfiguration cannot silently fall back to the
#    personal gh identity).
# 2. gha_token caches: a fresh cache file is NOT re-minted; an expiring cache
#    file IS re-minted. We assert the mint-endpoint invocation count.
# 3. Cache file is written atomically and ends up with mode 0600.
# 4. JWT generation produces a valid header.payload.signature triple whose
#    signature verifies against the corresponding public key — proving the
#    openssl RS256 path is correct (not just that it ran without error).
# 5. gha_with_token wraps a subprocess with GH_TOKEN/GITHUB_TOKEN set; the
#    no-op pass-through still works when App mode is OFF.
# 6. gha_git_push_header emits "Authorization: Bearer ghs_…" and refuses to
#    return anything when App mode is OFF.
# 7. The heavy LIST reads (pick_oldest_candidate, issue_assignees, epic_list_open,
#    scan_clean's label query) route through the App when App mode is on, so their
#    volume spends the App's rate limit, not maintainer's personal quota (issue #127).
#    A PATH `gh` shim records GH_TOKEN presence per call: TEST 8 proves the reads
#    carry the token, that N reads mint ONCE (cache holds under volume), and that
#    the per-issue count_open_blockers probe stays bare (scope boundary). TEST 9
#    proves the fallbacks: App env absent => bare gh + no mint; a non-origin remote
#    bypasses the App even with App env set; and a repo the App cannot read fails
#    soft (empty result, rc 0, diagnostic to RUN_ISSUES_GH_ERR) instead of a silent
#    "no candidates".
#
# How it stays network-free
# -------------------------
# RUN_ISSUES_GHA_TOKEN_ENDPOINT_BASE points at a local Python stdlib HTTP
# server we spawn in setup. The server returns a JSON envelope shaped like the
# real GitHub /app/installations/{id}/access_tokens response and increments a
# counter file every time it's hit — that counter is the discriminator behind
# "did we re-mint or not".
#
# Run: bash tests/test-github-app-auth.sh
# Verified locally before committing — pre-commit hook reminder.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib/github-app-auth.sh"

WORK=$(mktemp -d -t gha-test.XXXXXX)
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

FAIL=0
fail() { echo "FAIL: $*"; FAIL=1; }
ok()   { echo "ok:   $*"; }

# ---------- generate a throwaway RSA keypair (the App's .pem stand-in) -------
# 2048 bits matches what GitHub Apps issue. We extract the public key so we
# can independently verify the JWT signature in test 4.
PEM="$WORK/app.pem"
PUB="$WORK/app.pub"
openssl genrsa -out "$PEM" 2048 2>/dev/null || { echo "openssl genrsa failed"; exit 99; }
openssl rsa -in "$PEM" -pubout -out "$PUB" 2>/dev/null || { echo "openssl rsa -pubout failed"; exit 99; }
chmod 600 "$PEM"

# ---------- spin up a mock token endpoint ------------------------------------
# Python is in macOS by default (3.x). The server emits a 201 with a fake
# `ghs_xxx` token and a configurable expires_at, and writes a hit-count to a
# file so the test can assert "we minted N times".
HIT_COUNTER="$WORK/hits"
echo 0 > "$HIT_COUNTER"
EXPIRES_FILE="$WORK/expires_at"
# Default: token expires 1 hour from now (the real GitHub default).
date -u -v+1H +%FT%TZ 2>/dev/null > "$EXPIRES_FILE" || \
  date -u -d "+1 hour" +%FT%TZ > "$EXPIRES_FILE"

SERVER_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
SERVER_LOG="$WORK/server.log"

python3 - "$SERVER_PORT" "$HIT_COUNTER" "$EXPIRES_FILE" > "$SERVER_LOG" 2>&1 <<'PY' &
import sys, http.server, json, pathlib

port = int(sys.argv[1])
hit_counter = pathlib.Path(sys.argv[2])
expires_file = pathlib.Path(sys.argv[3])

class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        # Bump hit counter.
        n = int(hit_counter.read_text().strip()) + 1
        hit_counter.write_text(str(n))
        # Reject if no JWT.
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            self.send_response(401)
            self.end_headers()
            return
        body = json.dumps({
            "token": f"ghs_test_token_{n}",
            "expires_at": expires_file.read_text().strip(),
            "permissions": {"issues": "write", "pull_requests": "write", "contents": "write"},
        }).encode()
        self.send_response(201)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a, **kw):
        pass  # quiet

http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
SERVER_PID=$!

# Wait for the server to accept connections (up to ~3s).
for _ in $(seq 1 30); do
  if curl -sS -o /dev/null -w '' "http://127.0.0.1:${SERVER_PORT}/" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

# ---------- configure the library --------------------------------------------
export RUN_ISSUES_GHA_TOKEN_ENDPOINT_BASE="http://127.0.0.1:${SERVER_PORT}"
export RUN_ISSUES_GHA_CACHE_FILE="$WORK/token-cache.json"
# Make tests deterministic: 5s buffer instead of 5min so we can construct an
# "expires in 4 seconds" scenario quickly.
export RUN_ISSUES_GHA_REFRESH_BUFFER_SECONDS=5

# shellcheck source=lib/github-app-auth.sh
. "$LIB"

# ---------- TEST 1: gha_enabled gate ----------------------------------------
echo "--- TEST 1: gha_enabled gate ---"
# OFF when env vars absent.
unset RUN_ISSUES_GITHUB_APP_ID RUN_ISSUES_GITHUB_APP_INSTALLATION_ID RUN_ISSUES_GITHUB_APP_PRIVATE_KEY_PATH
if gha_enabled; then fail "1a: gha_enabled returned 0 with no env"; else ok "1a: off when env vars unset"; fi

# ON when all three set and .pem exists.
export RUN_ISSUES_GITHUB_APP_ID="123456"
export RUN_ISSUES_GITHUB_APP_INSTALLATION_ID="98765"
export RUN_ISSUES_GITHUB_APP_PRIVATE_KEY_PATH="$PEM"
if gha_enabled; then ok "1b: on when env+key present"; else fail "1b: gha_enabled returned 1 with valid config"; fi

# OFF when private key path points to a missing file (fail-closed).
RUN_ISSUES_GITHUB_APP_PRIVATE_KEY_PATH="$WORK/nope.pem" gha_enabled 2>/dev/null \
  && fail "1c: gha_enabled accepted a non-existent .pem (must fail closed)" \
  || ok "1c: fail-closed when .pem missing"

# OFF when private key path points to an unreadable file.
NOREAD="$WORK/noread.pem"; cp "$PEM" "$NOREAD"; chmod 000 "$NOREAD"
RUN_ISSUES_GITHUB_APP_PRIVATE_KEY_PATH="$NOREAD" gha_enabled 2>/dev/null \
  && fail "1d: gha_enabled accepted an unreadable .pem" \
  || ok "1d: fail-closed when .pem unreadable"
chmod 600 "$NOREAD"  # so cleanup can remove it

# ---------- TEST 2: gha_token mints + caches --------------------------------
echo "--- TEST 2: gha_token mints + caches ---"
gha_clear_cache
T1=$(gha_token 2>/dev/null) || { fail "2a: gha_token returned non-zero on first call"; T1=""; }
HITS1=$(cat "$HIT_COUNTER")
[ "$HITS1" = "1" ] && ok "2a: first call hit the endpoint exactly once" || fail "2a: expected 1 hit, got $HITS1"
[ "$T1" = "ghs_test_token_1" ] && ok "2b: returned expected token" || fail "2b: token mismatch: '$T1'"

# Cache file exists with mode 0600.
[ -f "$RUN_ISSUES_GHA_CACHE_FILE" ] && ok "2c: cache file written" || fail "2c: cache file missing"
PERM=""
if [ "$(uname -s)" = "Darwin" ]; then
  PERM=$(stat -f '%Lp' "$RUN_ISSUES_GHA_CACHE_FILE" 2>/dev/null || echo "")
else
  PERM=$(stat -c '%a' "$RUN_ISSUES_GHA_CACHE_FILE" 2>/dev/null || echo "")
fi
[ "$PERM" = "600" ] && ok "2d: cache file mode 0600" || fail "2d: cache file mode $PERM (expected 600)"

# Second call with a still-valid cache must NOT mint again.
T2=$(gha_token 2>/dev/null) || fail "2e: gha_token failed on cached call"
HITS2=$(cat "$HIT_COUNTER")
[ "$HITS2" = "1" ] && ok "2e: cached call did not hit endpoint" || fail "2e: cache miss — expected 1 hit, got $HITS2"
[ "$T2" = "$T1" ] && ok "2f: cached token returned identically" || fail "2f: cached token differs ($T1 vs $T2)"

# ---------- TEST 3: cache expires within the buffer -> re-mint --------------
echo "--- TEST 3: expiring cache triggers re-mint ---"
# Rewrite the cache file with an expires_at that is INSIDE the 5s buffer
# window: <buffer left -> _gha_cache_valid returns false -> re-mint.
NEAR_EXPIRY=$(date -u -v+3S +%FT%TZ 2>/dev/null || date -u -d "+3 sec" +%FT%TZ)
jq -n \
  --arg token "$T1" \
  --arg expires_at "$NEAR_EXPIRY" \
  --arg installation_id "$RUN_ISSUES_GITHUB_APP_INSTALLATION_ID" \
  '{token:$token, expires_at:$expires_at, installation_id:$installation_id}' \
  > "$RUN_ISSUES_GHA_CACHE_FILE"
chmod 600 "$RUN_ISSUES_GHA_CACHE_FILE"

T3=$(gha_token 2>/dev/null) || fail "3a: gha_token failed on near-expiry cache"
HITS3=$(cat "$HIT_COUNTER")
[ "$HITS3" = "2" ] && ok "3a: near-expiry cache triggered a re-mint (hits=2)" || fail "3a: expected 2 hits, got $HITS3"
[ "$T3" = "ghs_test_token_2" ] && ok "3b: returned freshly minted token" || fail "3b: got '$T3'"

# ---------- TEST 4: installation ID change invalidates cache ----------------
echo "--- TEST 4: installation ID change invalidates cache ---"
# Write a cache for a DIFFERENT installation ID and assert gha_token re-mints.
FUTURE=$(date -u -v+1H +%FT%TZ 2>/dev/null || date -u -d "+1 hour" +%FT%TZ)
jq -n \
  --arg token "stale_other_install" \
  --arg expires_at "$FUTURE" \
  --arg installation_id "OTHER_INSTALL_ID" \
  '{token:$token, expires_at:$expires_at, installation_id:$installation_id}' \
  > "$RUN_ISSUES_GHA_CACHE_FILE"
chmod 600 "$RUN_ISSUES_GHA_CACHE_FILE"
HITS_BEFORE=$(cat "$HIT_COUNTER")
T4=$(gha_token 2>/dev/null) || fail "4a: gha_token failed when installation ID changed"
HITS_AFTER=$(cat "$HIT_COUNTER")
[ "$HITS_AFTER" = "$((HITS_BEFORE + 1))" ] && ok "4a: installation ID mismatch forced re-mint" || \
  fail "4a: hits did not advance ($HITS_BEFORE -> $HITS_AFTER) on installation ID change"
[ "$T4" != "stale_other_install" ] && ok "4b: stale token was discarded" || fail "4b: returned stale token"

# ---------- TEST 5: JWT actually signs correctly ----------------------------
echo "--- TEST 5: JWT verifies against the public key ---"
JWT=$(_gha_make_jwt) || fail "5a: _gha_make_jwt failed"
# Split header.payload.signature
HEADER_B64="${JWT%%.*}"
REST="${JWT#*.}"
PAYLOAD_B64="${REST%%.*}"
SIG_B64="${REST#*.}"
[ -n "$HEADER_B64" ] && [ -n "$PAYLOAD_B64" ] && [ -n "$SIG_B64" ] && ok "5a: JWT has three segments" || \
  fail "5a: JWT malformed ($JWT)"

# Decode header + payload + verify signature with openssl + the public key.
b64url_decode() {
  local s="$1"
  # restore padding
  local mod=$(( ${#s} % 4 ))
  case "$mod" in
    2) s="${s}==" ;;
    3) s="${s}=" ;;
  esac
  printf '%s' "$s" | tr '_-' '/+' | openssl base64 -A -d
}
HEADER_JSON=$(b64url_decode "$HEADER_B64")
PAYLOAD_JSON=$(b64url_decode "$PAYLOAD_B64")
echo "header: $HEADER_JSON"
echo "payload: $PAYLOAD_JSON"
echo "$HEADER_JSON" | grep -q '"alg":"RS256"' && ok "5b: header alg=RS256" || fail "5b: bad header"
echo "$PAYLOAD_JSON" | grep -q '"iss":"123456"' && ok "5c: payload iss=app id" || fail "5c: bad iss"

# Verify the signature: write the raw signature back to a file, then ask
# openssl to verify the signing input ("$HEADER_B64.$PAYLOAD_B64") against the
# public key with SHA-256.
SIG_FILE="$WORK/sig.bin"
b64url_decode "$SIG_B64" > "$SIG_FILE"
if printf '%s.%s' "$HEADER_B64" "$PAYLOAD_B64" \
   | openssl dgst -sha256 -verify "$PUB" -signature "$SIG_FILE" >/dev/null 2>&1; then
  ok "5d: signature verifies against the public key"
else
  fail "5d: signature did not verify"
fi

# ---------- TEST 6: gha_with_token sets GH_TOKEN in subprocess --------------
echo "--- TEST 6: gha_with_token propagates token ---"
# Make a tiny script that echoes its GH_TOKEN. Then call it via gha_with_token
# and assert the echoed value matches the minted token. We do NOT echo the
# token from this test's stdout — only compare.
SUBSCRIPT="$WORK/echo-gh-token.sh"
cat > "$SUBSCRIPT" <<'SH'
#!/usr/bin/env bash
printf '%s|%s' "${GH_TOKEN:-MISSING}" "${GITHUB_TOKEN:-MISSING}"
SH
chmod +x "$SUBSCRIPT"

OUT=$(gha_with_token "$SUBSCRIPT")
EXPECTED=$(gha_token 2>/dev/null)
EXP_PAIR="${EXPECTED}|${EXPECTED}"
if [ "$OUT" = "$EXP_PAIR" ]; then
  ok "6a: GH_TOKEN + GITHUB_TOKEN both set to current token in subprocess"
else
  fail "6a: subprocess token mismatch (got len=${#OUT}, expected len=${#EXP_PAIR})"
fi

# When App mode is OFF, gha_with_token must be a pass-through that does NOT
# overwrite caller-supplied env. We unset GH_TOKEN/GITHUB_TOKEN in the subshell
# first so a pre-existing token in the test runner's environment cannot mask a
# regression where the helper would falsely inject something.
( unset RUN_ISSUES_GITHUB_APP_ID GH_TOKEN GITHUB_TOKEN
  OUT2=$(gha_with_token "$SUBSCRIPT")
  case "$OUT2" in
    "MISSING|MISSING") echo "ok:   6b: pass-through when App mode off (no env injected)" ;;
    *) echo "FAIL: 6b: pass-through leaked or injected env ($OUT2)"; exit 1 ;;
  esac
) || FAIL=1

# When App mode is OFF and the caller already has GH_TOKEN set (e.g. a personal
# fine-grained token sourced from machine env), gha_with_token must preserve
# that token unchanged — App mode being off means "leave whatever the user
# already configured alone".
( unset RUN_ISSUES_GITHUB_APP_ID
  export GH_TOKEN="caller_supplied_token"
  export GITHUB_TOKEN="caller_supplied_token"
  OUT3=$(gha_with_token "$SUBSCRIPT")
  if [ "$OUT3" = "caller_supplied_token|caller_supplied_token" ]; then
    echo "ok:   6c: pass-through preserves caller's GH_TOKEN when App off"
  else
    echo "FAIL: 6c: pass-through overwrote caller's GH_TOKEN ($OUT3)"
    exit 1
  fi
) || FAIL=1

# ---------- TEST 7: gha_git_push_header gates correctly ---------------------
echo "--- TEST 7: gha_git_push_header ---"
HDR=$(gha_git_push_header) || fail "7a: gha_git_push_header failed in App mode"
case "$HDR" in
  "Authorization: Bearer ghs_test_token_"*) ok "7a: emits 'Authorization: Bearer ghs_…' value" ;;
  *) fail "7a: unexpected header value (got '${HDR:0:40}…')" ;;
esac
( unset RUN_ISSUES_GITHUB_APP_ID
  HDR2=$(gha_git_push_header 2>/dev/null)
  if [ -z "$HDR2" ] && ! ( unset RUN_ISSUES_GITHUB_APP_ID; gha_git_push_header 2>/dev/null ); then
    echo "ok:   7b: returns non-zero + empty when App mode off"
  else
    echo "FAIL: 7b: should fail when App mode off (got '$HDR2')"
    exit 1
  fi
) || FAIL=1

# ---------- TEST 8: heavy LIST reads route through the App (issue #127) -------
# The pickup / assignee / epic / clean-scan reads must run through gha_with_token
# when App mode is on, so their volume spends the App's rate limit rather than
# maintainer's personal quota. We source the read helpers, put a `gh` shim on PATH that
# records whether GH_TOKEN was set per call, and assert the routed reads carry the
# token while the token cache is hit exactly once across many reads.
echo "--- TEST 8: pickup/assignee/epic/clean reads route via App ---"

# issue.sh / epic.sh set `set -euo pipefail`; sourcing them turns on -e for the
# rest of this file. Restore the test's own mode (no -e) so a benign non-zero in a
# helper below does not abort the run.
# shellcheck source=lib/issue.sh
. "$HERE/../lib/issue.sh"
# shellcheck source=lib/epic.sh
. "$HERE/../lib/epic.sh"
set +e

# App mode ON with a cold cache.
export RUN_ISSUES_GITHUB_APP_ID="123456"
export RUN_ISSUES_GITHUB_APP_INSTALLATION_ID="98765"
export RUN_ISSUES_GITHUB_APP_PRIVATE_KEY_PATH="$PEM"
gha_clear_cache

# PATH shim `gh`: logs "<yes|no>\t<arg1> <arg2>" per call (token presence + path)
# and emits just enough output for each read helper to complete. It is a real
# executable, not a function, so `GH_TOKEN=… gh …` (how gha_with_token injects the
# token) is observed exactly as the real gh would see it.
SHIMBIN="$WORK/shimbin"; mkdir -p "$SHIMBIN"
GH_CALL_LOG="$WORK/gh-calls.log"; : > "$GH_CALL_LOG"
GH_DENY_LIST="$WORK/gh-deny"; : > "$GH_DENY_LIST"   # non-empty => list read fails (mixed-access)
cat > "$SHIMBIN/gh" <<SH
#!/usr/bin/env bash
if [ -n "\${GH_TOKEN:-}" ]; then tok=yes; else tok=no; fi
printf '%s\t%s %s\n' "\$tok" "\$1" "\$2" >> "$GH_CALL_LOG"
case "\$*" in
  *dependencies/blocked_by*) echo "0" ;;
  "api user"*) echo "maintainer" ;;
  *"issue view"*assignees*) echo "maintainer" ;;
  *labels=epic*) echo "100" ;;
  *labels=auto-clean*) : ;;
  *labels=auto-run*)
    # Simulate a repo the App identity cannot read (private repo, no App access):
    # the list call fails, which must degrade to "no candidate", not crash.
    if [ -s "$GH_DENY_LIST" ]; then echo "gh: 404 Not Found" >&2; exit 1; fi
    echo "10" ;;
  *) : ;;
esac
SH
chmod +x "$SHIMBIN/gh"
export PATH="$SHIMBIN:$PATH"

REPO8="$WORK/repo8"; mkdir -p "$REPO8"
# shellcheck disable=SC2034
THIS_HOST="apphost"
# shellcheck disable=SC2034
RUN_ISSUES_CLEAN_LABEL="auto-clean"

# Extract scan_clean from poller.sh and source it (same idiom as test-scan-clean).
POLLER8="$HERE/../poller.sh"
FN8=$(awk '/^scan_clean\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$POLLER8")
eval "$FN8"

# 8a: N App-routed reads in ONE process => exactly ONE token mint (cache holds).
MINTS_BEFORE=$(cat "$HIT_COUNTER")
pick_oldest_candidate "$REPO8" "auto-run" "o/r" "origin" >/dev/null 2>&1
issue_assignees "$REPO8" 10 "o/r" "origin" >/dev/null 2>&1
epic_list_open "$REPO8" "auto-run" "o/r" "origin" >/dev/null 2>&1
MINTS_AFTER=$(cat "$HIT_COUNTER")
DELTA=$((MINTS_AFTER - MINTS_BEFORE))
[ "$DELTA" = "1" ] && ok "8a: N App reads => exactly one token mint (cache reused)" || \
  fail "8a: expected 1 mint across N reads, got $DELTA (token cache is not holding under volume)"

# Helper: run a read, then report the token flag + path of the FIRST gh call.
first_flag() { head -1 "$GH_CALL_LOG" | cut -f1; }
first_path() { head -1 "$GH_CALL_LOG" | cut -f2-; }

# 8b: pickup list read routed (yes); the count_open_blockers probe stays bare (no).
: > "$GH_CALL_LOG"
pick_oldest_candidate "$REPO8" "auto-run" "o/r" "origin" >/dev/null 2>&1
[ "$(first_flag)" = "yes" ] && case "$(first_path)" in *"labels=auto-run"*) ok "8b: pickup list read carried GH_TOKEN" ;; *) fail "8b: first call was not the pickup list ($(first_path))" ;; esac || fail "8b: pickup list read did NOT carry GH_TOKEN"
BLOCKER_LINE=$(grep 'dependencies/blocked_by' "$GH_CALL_LOG" | head -1)
case "$BLOCKER_LINE" in
  "no	"*) ok "8c: count_open_blockers probe stayed on bare gh (scope boundary held)" ;;
  *) fail "8c: count_open_blockers unexpectedly routed or missing ($BLOCKER_LINE)" ;;
esac

# 8d: issue_assignees routed.
: > "$GH_CALL_LOG"
issue_assignees "$REPO8" 10 "o/r" "origin" >/dev/null 2>&1
[ "$(first_flag)" = "yes" ] && ok "8d: issue_assignees read carried GH_TOKEN" || fail "8d: issue_assignees did NOT route via App"

# 8e: epic_list_open routed.
: > "$GH_CALL_LOG"
epic_list_open "$REPO8" "auto-run" "o/r" "origin" >/dev/null 2>&1
[ "$(first_flag)" = "yes" ] && case "$(first_path)" in *"labels=epic"*) ok "8e: epic_list_open read carried GH_TOKEN" ;; *) fail "8e: epic_list_open path unexpected ($(first_path))" ;; esac || fail "8e: epic_list_open did NOT route via App"

# 8f: scan_clean label read routed. Needs one LOCAL run-dir so phase 2 fires.
mkdir -p "$REPO8/.claude/run-issues/run-1"
printf '{"host":"%s","remote":"origin","issue_number":"60"}\n' "$THIS_HOST" \
  > "$REPO8/.claude/run-issues/run-1/run.json"
: > "$GH_CALL_LOG"
scan_clean "$REPO8" "origin" "o/r" >/dev/null 2>&1
LABEL_LINE=$(grep 'labels=auto-clean' "$GH_CALL_LOG" | head -1)
case "$LABEL_LINE" in
  "yes	"*) ok "8f: scan_clean label read carried GH_TOKEN" ;;
  *) fail "8f: scan_clean label read did NOT route via App ($LABEL_LINE)" ;;
esac

# ---------- TEST 9: fallbacks — App off, non-origin, mixed-access -------------
echo "--- TEST 9: bare-gh fallbacks (issue #127) ---"

# 9a: App env ABSENT => bare gh (no token), no mint, no error. Bit-for-bit the
# pre-#127 behaviour. Unset GH_TOKEN/GITHUB_TOKEN too so a stray token in the
# runner env cannot mask a regression.
( unset RUN_ISSUES_GITHUB_APP_ID GH_TOKEN GITHUB_TOKEN
  : > "$GH_CALL_LOG"
  M0=$(cat "$HIT_COUNTER")
  pick_oldest_candidate "$REPO8" "auto-run" "o/r" "origin" >/dev/null 2>&1
  M1=$(cat "$HIT_COUNTER")
  flag=$(head -1 "$GH_CALL_LOG" | cut -f1)
  if [ "$flag" = "no" ] && [ "$M0" = "$M1" ]; then
    echo "ok:   9a: App off => bare gh, no token, no mint"
  else
    echo "FAIL: 9a: App off leaked a token or minted (flag=$flag mints $M0->$M1)"; exit 1
  fi
) || FAIL=1

# 9b: non-origin remote => bare gh even with App env SET (per-org App scope).
: > "$GH_CALL_LOG"
MB=$(cat "$HIT_COUNTER")
( unset GH_TOKEN GITHUB_TOKEN
  pick_oldest_candidate "$REPO8" "auto-run" "customer-d-oy/rahti" "customer-d" >/dev/null 2>&1
)
MA=$(cat "$HIT_COUNTER")
flag9b=$(head -1 "$GH_CALL_LOG" | cut -f1)
if [ "$flag9b" = "no" ] && [ "$MB" = "$MA" ]; then
  ok "9b: non-origin remote bypasses App (bare gh, no mint) despite App env set"
else
  fail "9b: non-origin remote routed via App (flag=$flag9b mints $MB->$MA)"
fi

# 9c: mixed-access — the App cannot read the repo, so the list read fails. Must
# degrade to "no candidate" (rc 0, empty) and surface the error to RUN_ISSUES_GH_ERR
# rather than crash or silently hide it. This is the silent "no candidates" trap
# the spec calls out as the case that MUST be tested.
printf 'x' > "$GH_DENY_LIST"   # arm the list-read failure
GH_ERR9="$WORK/gh-err.log"; : > "$GH_ERR9"
OUT9=$(RUN_ISSUES_GH_ERR="$GH_ERR9" pick_oldest_candidate "$REPO8" "auto-run" "o/r" "origin"); RC9=$?
if [ "$RC9" = "0" ] && [ -z "$OUT9" ]; then
  ok "9c: unreadable-by-App repo => empty result, rc 0 (fail-soft, no crash)"
else
  fail "9c: mixed-access did not fail soft (rc=$RC9 out='$OUT9')"
fi
[ -s "$GH_ERR9" ] && ok "9d: the failed App read left a diagnostic in RUN_ISSUES_GH_ERR (not silent)" || \
  fail "9d: mixed-access failure was silent (RUN_ISSUES_GH_ERR empty)"
: > "$GH_DENY_LIST"   # disarm

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "github-app-auth: all passed" || echo "github-app-auth: FAILURES"
[ "$FAIL" -eq 0 ]
