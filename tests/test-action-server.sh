#!/usr/bin/env bash
# test-action-server.sh — the Ohjaamo action service and its dispatch (issue #77).
#
# Three layers, all runnable without a tailnet, gh, or the orchestrator:
#
#   A. action-dispatch.sh — each of the four actions delegates to the right
#      script/label with the right arguments (stop-run / labels / orchestrate),
#      exercised through a fixture package dir with stub stop-run.sh /
#      orchestrate.sh + gh/tmux shims on PATH.
#   B. lib/action-service.py — the auth + CSRF + audit core, driven over HTTP by
#      curl against a real bound socket (127.0.0.1), with a `tailscale` shim for
#      whois and a stub dispatch. Covers security-model rules 1–5.
#   C. action-server.sh — config resolution (--check) and the host gate (rule:
#      a foreign machine no-ops), plus the structural bind/peer-IP invariants.
#
# SKIP when a prerequisite is absent (python3 / jq / curl), the same discipline
# as tests/test-status-github.sh.
#
# Run: bash tests/test-action-server.sh   (exit 0 = all pass)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

command -v jq   >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "SKIP: curl not installed"; exit 0; }
PYBIN=""
if command -v python3 >/dev/null 2>&1; then PYBIN="python3"; fi
[ -n "$PYBIN" ] || { echo "SKIP: python3 not available"; exit 0; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got=[$2] expected=[$3]"; fi; }

FX="$(mktemp -d "${TMPDIR:-/tmp}/action-test.XXXXXX")"
trap 'rm -rf "$FX"; [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null' EXIT

# ===========================================================================
# A. action-dispatch.sh — delegation
# ===========================================================================
# A fixture package dir: real action-dispatch.sh + real label/git libs
# (symlinked), but STUB stop-run.sh / orchestrate.sh so we observe the argv
# instead of running the real teardown. SCRIPT_DIR resolves to this dir.
PKG="$FX/pkg"; mkdir -p "$PKG/lib"
ln -s "$ROOT/action-dispatch.sh" "$PKG/action-dispatch.sh"
ln -s "$ROOT/lib/labels.sh"      "$PKG/lib/labels.sh"
ln -s "$ROOT/lib/git-remote.sh"  "$PKG/lib/git-remote.sh"

STOP_ARGS="$FX/stop-args.txt"; : > "$STOP_ARGS"
STOP_RC="$FX/stop-rc.txt"; echo 0 > "$STOP_RC"
cat > "$PKG/stop-run.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$STOP_ARGS"
exit "\$(cat "$STOP_RC" 2>/dev/null || echo 0)"
SH
chmod +x "$PKG/stop-run.sh"
cat > "$PKG/orchestrate.sh" <<SH
#!/usr/bin/env bash
exit 0
SH
chmod +x "$PKG/orchestrate.sh"

# gh + tmux shims on PATH.
BIN="$FX/bin"; mkdir -p "$BIN"
GH_ARGS="$FX/gh-args.txt"; : > "$GH_ARGS"
GH_RC="$FX/gh-rc.txt"; echo 0 > "$GH_RC"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_ARGS"
exit "\$(cat "$GH_RC" 2>/dev/null || echo 0)"
SH
chmod +x "$BIN/gh"
TMUX_ARGS="$FX/tmux-args.txt"; : > "$TMUX_ARGS"
cat > "$BIN/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMUX_ARGS"
exit 0
SH
chmod +x "$BIN/tmux"

dispatch() { PATH="$BIN:$PATH" bash "$PKG/action-dispatch.sh" "$@"; }

# --- stop: delegates to stop-run.sh --run-dir <dir> --yes ---
: > "$STOP_ARGS"; echo 0 > "$STOP_RC"
RUN_DIR="$FX/somerun"; mkdir -p "$RUN_DIR"
dispatch stop --run-dir "$RUN_DIR"; check "stop exit 0" "$?" "0"
if grep -q -- "--run-dir $RUN_DIR --yes" "$STOP_ARGS"; then ok "stop calls stop-run.sh with --run-dir … --yes"; else bad "stop args wrong: $(cat "$STOP_ARGS")"; fi

# --- stop: delegate failure surfaces as exit 2 (rule 5) ---
echo 3 > "$STOP_RC"
dispatch stop --run-dir "$RUN_DIR"; check "stop delegate failure -> exit 2" "$?" "2"

# --- clean: adds auto-clean label to the issue ---
: > "$GH_ARGS"; echo 0 > "$GH_RC"
dispatch clean --repo "$FX/repo" --owner o/acme --issue 5; check "clean exit 0" "$?" "0"
if grep -q 'repos/o/acme/issues/5/labels' "$GH_ARGS" && grep -q 'labels\[\]=auto-clean' "$GH_ARGS"; then
  ok "clean POSTs auto-clean label to the issue"
else bad "clean gh args wrong: $(cat "$GH_ARGS")"; fi

# --- allow-merge: adds auto-merge label to the PR ---
: > "$GH_ARGS"
dispatch allow-merge --repo "$FX/repo" --owner o/acme --pr 9; check "allow-merge exit 0" "$?" "0"
if grep -q 'repos/o/acme/issues/9/labels' "$GH_ARGS" && grep -q 'labels\[\]=auto-merge' "$GH_ARGS"; then
  ok "allow-merge POSTs auto-merge label to the PR"
else bad "allow-merge gh args wrong: $(cat "$GH_ARGS")"; fi

# --- resume (non-timed_out): removes needs-human label ---
: > "$GH_ARGS"
BLOCKED_DIR="$FX/blockedrun"; mkdir -p "$BLOCKED_DIR"
echo '{"status":"blocked"}' > "$BLOCKED_DIR/run.json"
dispatch resume --repo "$FX/repo" --owner o/acme --issue 5 --run-dir "$BLOCKED_DIR"
check "resume (blocked) exit 0" "$?" "0"
if grep -q 'DELETE' "$GH_ARGS" && grep -q 'labels/needs-human' "$GH_ARGS"; then
  ok "resume removes the needs-human label"
else bad "resume gh args wrong: $(cat "$GH_ARGS")"; fi

# --- resume (timed_out): launches orchestrate.sh --restart via tmux ---
: > "$TMUX_ARGS"
TO_DIR="$FX/timedout"; mkdir -p "$TO_DIR"
echo '{"status":"timed_out"}' > "$TO_DIR/run.json"
dispatch resume --repo "$FX/repo" --owner o/acme --issue 7 --run-dir "$TO_DIR" --remote origin --repo-slug acme
check "resume (timed_out) exit 0" "$?" "0"
if grep -q 'new-session' "$TMUX_ARGS" && grep -q -- '--restart' "$TMUX_ARGS" && grep -q "$TO_DIR" "$TMUX_ARGS"; then
  ok "resume of a timed_out run launches orchestrate --restart in tmux"
else bad "resume timed_out tmux args wrong: $(cat "$TMUX_ARGS")"; fi

# --- usage errors ---
dispatch bogus-action --issue 1 >/dev/null 2>&1; check "unknown action -> exit 1" "$?" "1"
dispatch clean --repo "$FX/repo" >/dev/null 2>&1; check "clean without --issue -> exit 1" "$?" "1"

# ===========================================================================
# B. lib/action-service.py — auth + CSRF + audit over HTTP
# ===========================================================================
PORT="$($PYBIN -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
TOKEN="deadbeefcafe1234567890abcdef00000000000000000000000000000000cafe"
TOKFILE="$FX/token"; printf '%s\n' "$TOKEN" > "$TOKFILE"; chmod 600 "$TOKFILE"
ORIGIN="http://localhost:8080"
AUDIT_DIR="$FX/logs"; mkdir -p "$AUDIT_DIR"
AUDIT_LOG="$AUDIT_DIR/run-issues-action.audit.log"

# tailscale shim: whois returns the login named in a control file (or fails);
# ip -4 / status --json satisfy action-server.sh's resolution (Part C).
WHOIS_CTL="$FX/whois.txt"; echo "maintainer@example" > "$WHOIS_CTL"
TS_SHIM="$BIN/tailscale"
cat > "$TS_SHIM" <<SH
#!/usr/bin/env bash
case "\$1" in
  whois)
    v="\$(cat "$WHOIS_CTL" 2>/dev/null || echo FAIL)"
    [ "\$v" = "FAIL" ] && exit 1
    printf '{"UserProfile":{"LoginName":"%s"}}\n' "\$v"; exit 0 ;;
  ip) printf '127.0.0.1\n'; exit 0 ;;
  status) printf '{"Self":{"UserID":1},"User":{"1":{"LoginName":"maintainer@example"}}}\n'; exit 0 ;;
esac
exit 0
SH
chmod +x "$TS_SHIM"

# stub dispatch the service exec's: records argv, returns a controllable rc.
DISP_ARGS="$FX/disp-args.txt"; : > "$DISP_ARGS"
DISP_RC="$FX/disp-rc.txt"; echo 0 > "$DISP_RC"
STUB_DISPATCH="$FX/stub-dispatch.sh"
cat > "$STUB_DISPATCH" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$DISP_ARGS"
printf 'stub-ok\n'
exit "\$(cat "$DISP_RC" 2>/dev/null || echo 0)"
SH
chmod +x "$STUB_DISPATCH"

RUN_ISSUES_ACTION_BIND=127.0.0.1 RUN_ISSUES_ACTION_PORT="$PORT" \
  RUN_ISSUES_ACTION_DISPATCH="$STUB_DISPATCH" \
  RUN_ISSUES_TAILSCALE_BIN="$TS_SHIM" \
  RUN_ISSUES_ACTION_TOKEN_FILE="$TOKFILE" \
  RUN_ISSUES_ACTION_ALLOWED_USERS="maintainer@example" \
  RUN_ISSUES_ACTION_ORIGIN="$ORIGIN" \
  RUN_ISSUES_LOG_DIR="$AUDIT_DIR" \
  "$PYBIN" "$ROOT/lib/action-service.py" >"$FX/srv.out" 2>&1 &
SRV_PID=$!

# Wait for the socket.
base="http://127.0.0.1:$PORT"
up=0
for _ in $(seq 1 50); do
  if curl -fsS "$base/healthz" >/dev/null 2>&1; then up=1; break; fi
  sleep 0.1
done
check "service answers /healthz" "$up" "1"
if [ "$up" -ne 1 ]; then echo "server output:"; cat "$FX/srv.out"; fi

# A valid POST: all three CSRF layers satisfied + an allowed whois identity.
post() {
  # post <extra-curl-args...> — prints "HTTP_CODE<newline>BODY"
  curl -sS -o "$FX/body.txt" -w '%{http_code}' -X POST "$base/action" "$@"
}
VALID=(-H "Origin: $ORIGIN" -H "Content-Type: application/json"
       -H "X-Run-Issues-Action: 1" -H "X-Run-Issues-Token: $TOKEN"
       --data '{"action":"clean","issue_number":5,"repo_path":"/x","owner_repo":"o/acme"}')

echo "maintainer@example" > "$WHOIS_CTL"; : > "$DISP_ARGS"; echo 0 > "$DISP_RC"
code="$(post "${VALID[@]}")"
check "valid POST -> 200" "$code" "200"
check "valid POST ok:true" "$(jq -r '.ok' "$FX/body.txt" 2>/dev/null)" "true"
if grep -q 'clean --issue 5' "$DISP_ARGS"; then ok "service execs dispatch with the action argv"; else bad "dispatch argv wrong: $(cat "$DISP_ARGS")"; fi

# Rule 5: a failing delegate surfaces its output + a non-2xx.
echo 2 > "$DISP_RC"
code="$(post "${VALID[@]}")"
check "delegate failure -> 502" "$code" "502"
check "delegate failure ok:false" "$(jq -r '.ok' "$FX/body.txt")" "false"
echo 0 > "$DISP_RC"

# CSRF layer 3: no / wrong token -> 403.
code="$(post -H "Origin: $ORIGIN" -H "Content-Type: application/json" -H "X-Run-Issues-Action: 1" \
  --data '{"action":"clean","issue_number":5}')"
check "missing token -> 403" "$code" "403"
code="$(post -H "Origin: $ORIGIN" -H "Content-Type: application/json" -H "X-Run-Issues-Action: 1" \
  -H "X-Run-Issues-Token: wrong" --data '{"action":"clean","issue_number":5}')"
check "wrong token -> 403" "$code" "403"

# CSRF layer 2: missing custom header, or non-JSON content type -> 403.
code="$(post -H "Origin: $ORIGIN" -H "Content-Type: application/json" -H "X-Run-Issues-Token: $TOKEN" \
  --data '{"action":"clean","issue_number":5}')"
check "missing action header -> 403" "$code" "403"
code="$(post -H "Origin: $ORIGIN" -H "Content-Type: text/plain" -H "X-Run-Issues-Action: 1" \
  -H "X-Run-Issues-Token: $TOKEN" --data '{"action":"clean","issue_number":5}')"
check "non-JSON content-type -> 403" "$code" "403"

# CSRF layer 1: origin not on the allowlist -> 403.
code="$(post -H "Origin: http://evil.example" -H "Content-Type: application/json" -H "X-Run-Issues-Action: 1" \
  -H "X-Run-Issues-Token: $TOKEN" --data '{"action":"clean","issue_number":5}')"
check "foreign origin -> 403" "$code" "403"

# Rule 1/2: whois failure (unknown device) and a disallowed user both 403.
echo "FAIL" > "$WHOIS_CTL"
code="$(post "${VALID[@]}")"
check "whois failure (unknown device) -> 403" "$code" "403"
echo "someone@else" > "$WHOIS_CTL"
code="$(post "${VALID[@]}")"
check "disallowed tailnet user -> 403" "$code" "403"
echo "maintainer@example" > "$WHOIS_CTL"

# Rule 3: the audit log recorded actions AND denials, and NEVER the token.
if [ -s "$AUDIT_LOG" ]; then
  ok "audit log written"
  check "audit has an ok result" "$(jq -sr '[.[]|select(.result=="ok")]|length>0' "$AUDIT_LOG" 2>/dev/null)" "true"
  check "audit has a denied result" "$(jq -sr '[.[]|select(.result=="denied")]|length>0' "$AUDIT_LOG" 2>/dev/null)" "true"
  if grep -q "$TOKEN" "$AUDIT_LOG"; then bad "token leaked into the audit log"; else ok "token never appears in the audit log"; fi
else
  bad "audit log missing"
fi

# CORS preflight: an allowlisted origin gets ACAO; a foreign one does not.
acao_ok="$(curl -sS -X OPTIONS "$base/action" -H "Origin: $ORIGIN" \
  -H "Access-Control-Request-Method: POST" -D - -o /dev/null 2>/dev/null | grep -ci "access-control-allow-origin: $ORIGIN" || true)"
check "preflight ACAO for allowlisted origin" "$acao_ok" "1"
acao_evil="$(curl -sS -X OPTIONS "$base/action" -H "Origin: http://evil.example" \
  -H "Access-Control-Request-Method: POST" -D - -o /dev/null 2>/dev/null | grep -ci "access-control-allow-origin" || true)"
check "preflight NO ACAO for foreign origin" "$acao_evil" "0"

kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""

# --- audit log rotation (AC4): a tiny cap rotates the log to .1 ---
# A fresh server with RUN_ISSUES_LOG_MAX_BYTES tiny and a prefilled audit log:
# the next append rotates it (open-append-close honours the cap even for a
# long-lived daemon).
PORT2="$($PYBIN -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
ROT_DIR="$FX/rotlogs"; mkdir -p "$ROT_DIR"
ROT_LOG="$ROT_DIR/run-issues-action.audit.log"
head -c 500 /dev/zero | tr '\0' 'x' > "$ROT_LOG"   # 500 bytes, over the 50-byte cap
RUN_ISSUES_ACTION_BIND=127.0.0.1 RUN_ISSUES_ACTION_PORT="$PORT2" \
  RUN_ISSUES_ACTION_DISPATCH="$STUB_DISPATCH" RUN_ISSUES_TAILSCALE_BIN="$TS_SHIM" \
  RUN_ISSUES_ACTION_TOKEN_FILE="$TOKFILE" RUN_ISSUES_ACTION_ALLOWED_USERS="maintainer@example" \
  RUN_ISSUES_ACTION_ORIGIN="$ORIGIN" RUN_ISSUES_LOG_DIR="$ROT_DIR" \
  RUN_ISSUES_LOG_MAX_BYTES=50 \
  "$PYBIN" "$ROOT/lib/action-service.py" >/dev/null 2>&1 &
SRV_PID=$!
base2="http://127.0.0.1:$PORT2"
for _ in $(seq 1 50); do curl -fsS "$base2/healthz" >/dev/null 2>&1 && break; sleep 0.1; done
echo "maintainer@example" > "$WHOIS_CTL"
curl -sS -o /dev/null -X POST "$base2/action" -H "Origin: $ORIGIN" -H "Content-Type: application/json" \
  -H "X-Run-Issues-Action: 1" -H "X-Run-Issues-Token: $TOKEN" \
  --data '{"action":"clean","issue_number":5}' >/dev/null 2>&1
if [ -f "$ROT_LOG.1" ]; then ok "audit log rotates to .1 past the size cap"; else bad "audit log did not rotate"; fi
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""

# ===========================================================================
# C. action-server.sh — config resolution, host gate, structural invariants
# ===========================================================================
# Host gate: a non-matching host no-ops (exit 0) with no output — like the pollers.
out="$(RUN_ISSUES_ACTION_HOSTS='no-such-host-xyz' RUN_ISSUES_TAILSCALE_BIN="$TS_SHIM" \
       bash "$ROOT/action-server.sh" --check 2>&1)"; rc=$?
check "foreign host no-ops (exit 0)" "$rc" "0"
check "foreign host prints nothing" "$out" ""

# --check with an allowed host + shims resolves config and exits 0.
out="$(RUN_ISSUES_ACTION_HOSTS='*' RUN_ISSUES_TAILSCALE_BIN="$TS_SHIM" \
       RUN_ISSUES_ACTION_BIND=127.0.0.1 RUN_ISSUES_ACTION_ALLOWED_USERS='maintainer@example' \
       RUN_ISSUES_ACTION_TOKEN_FILE="$FX/token2" RUN_ISSUES_LOG_DIR="$AUDIT_DIR" \
       bash "$ROOT/action-server.sh" --check 2>&1)"; rc=$?
check "--check with shims exits 0" "$rc" "0"
if printf '%s' "$out" | grep -q 'bind=127.0.0.1:8081'; then ok "--check reports the resolved bind"; else bad "--check output: $out"; fi

# A wildcard bind is refused (never 0.0.0.0). tailscale ip returns nothing here.
TS_EMPTY="$BIN/tailscale-empty"
cat > "$TS_EMPTY" <<'SH'
#!/usr/bin/env bash
case "$1" in ip) exit 0 ;; status) printf '{"Self":{"UserID":1},"User":{"1":{"LoginName":"maintainer@example"}}}\n'; exit 0 ;; esac
exit 0
SH
chmod +x "$TS_EMPTY"
out="$(RUN_ISSUES_ACTION_HOSTS='*' RUN_ISSUES_TAILSCALE_BIN="$TS_EMPTY" \
       RUN_ISSUES_ACTION_ALLOWED_USERS='maintainer@example' RUN_ISSUES_ACTION_TOKEN_FILE="$FX/token3" \
       RUN_ISSUES_LOG_DIR="$AUDIT_DIR" bash "$ROOT/action-server.sh" --check 2>&1)"; rc=$?
check "no Tailscale address -> refuse bind (exit 3)" "$rc" "3"

# Structural: the service reads the SOCKET peer IP, never a forwarded header
# (design decision 2 — no reverse proxy). Guarded so a refactor cannot regress it.
if grep -q 'client_address' "$ROOT/lib/action-service.py"; then ok "service reads client_address (socket peer IP)"; else bad "service does not read client_address"; fi
if grep -qi 'X-Forwarded-For\|X-Real-IP' "$ROOT/lib/action-service.py"; then
  bad "service reads a forwarded IP header (must not — no reverse proxy)"
else ok "service never trusts a forwarded IP header"; fi

echo "----------------------------------------"
echo "action-server: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
