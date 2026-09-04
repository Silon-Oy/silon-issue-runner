#!/usr/bin/env bash
# test-default-paths.sh — platform defaults for the lock root and the log
# directory (issue #216).
#
# lib/paths.sh branches on `uname -s`: Darwin keeps the macOS layout, EVERYTHING
# ELSE gets the XDG state directory. The branch is asserted through a `uname`
# shim on PATH, because the alternative — asserting whatever this machine
# happens to be — would leave the other platform untested on every machine.
#
# MINGW64_NT-10.0 (Git Bash on Windows) is a case of its own and not a
# duplicate of Linux: it is the value an allow-list implementation would forget,
# and forgetting it means Windows silently keeps the macOS default. That is the
# exact regression this file exists to catch, so the assertion is not folded
# into the Linux case.
#
# Cases:
#   1  Darwin              -> ~/Library/Application Support/... and ~/Library/Logs
#   2  Linux               -> XDG state fallback under $HOME/.local/state
#   3  MINGW64_NT-10.0     -> the same XDG paths (not an allow-list)
#   4  XDG_STATE_HOME set  -> honoured on the non-Darwin branch
#   5  RUN_ISSUES_LOCK_ROOT / RUN_ISSUES_LOG_DIR always win, on every platform
#
# Case 5 goes through the real consumers (lib/locking.sh, lib/rate-limit.sh)
# rather than through paths.sh, because "the override wins" is a property of the
# call sites, not of the defaults.
#
# Run: bash tests/test-default-paths.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

FAIL=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1 (got '$2', want '$3')"; FAIL=1; }

WORK=$(mktemp -d -t default-paths.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ---- uname shim ------------------------------------------------------------
# Prints whatever $WORK/uname-s holds when called as `uname -s`, and defers to
# the real uname for anything else, so a shimmed PATH stays usable.
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/uname" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "-s" ]; then
  cat "$WORK/uname-s"
  exit 0
fi
exec /usr/bin/uname "\$@"
SH
chmod +x "$BIN/uname"

# paths_under <uname-s-value> [<extra env assignment>...]
# Prints "<lock-root>|<log-dir>" as lib/paths.sh resolves them for that platform.
paths_under() {
  local sys="$1"; shift
  printf '%s' "$sys" > "$WORK/uname-s"
  env -i HOME="$WORK/home" PATH="$BIN:/usr/bin:/bin" "$@" \
    bash -c '. "$1/lib/paths.sh"; printf "%s|%s" "$(default_lock_root)" "$(default_log_dir)"' \
    _ "$ROOT"
}

expect() {
  local label="$1" got="$2" want="$3"
  [ "$got" = "$want" ] && ok "$label" || bad "$label" "$got" "$want"
}

H="$WORK/home"
XDG="$H/.local/state"

# ---- Case 1: Darwin keeps the existing layout, bit for bit ----
expect "case1 Darwin keeps the macOS defaults" \
  "$(paths_under Darwin)" \
  "$H/Library/Application Support/run-issues/locks|$H/Library/Logs"

# ---- Case 2: Linux gets the XDG state fallback ----
expect "case2 Linux gets the XDG state defaults" \
  "$(paths_under Linux)" \
  "$XDG/run-issues/locks|$XDG/run-issues/logs"

# ---- Case 3: Git Bash on Windows gets them too (the not-an-allow-list case) ----
expect "case3 MINGW64_NT-10.0 gets the XDG state defaults" \
  "$(paths_under MINGW64_NT-10.0)" \
  "$XDG/run-issues/locks|$XDG/run-issues/logs"

# ---- Case 4: an explicit XDG_STATE_HOME is honoured ----
expect "case4 XDG_STATE_HOME is honoured off the Darwin branch" \
  "$(paths_under Linux XDG_STATE_HOME=/var/tmp/state)" \
  "/var/tmp/state/run-issues/locks|/var/tmp/state/run-issues/logs"

expect "case4 XDG_STATE_HOME does not leak onto the Darwin branch" \
  "$(paths_under Darwin XDG_STATE_HOME=/var/tmp/state)" \
  "$H/Library/Application Support/run-issues/locks|$H/Library/Logs"

# ---- Case 5: the environment overrides win on every platform ----
# Read back through the real consumers: locking.sh publishes
# RUN_ISSUES_LOCK_ROOT, rate-limit.sh builds its state path from
# RUN_ISSUES_LOG_DIR. locking.sh enables `set -euo pipefail`, hence the subshell
# that `bash -c` already provides.
override_under() {
  local sys="$1"
  printf '%s' "$sys" > "$WORK/uname-s"
  env -i HOME="$WORK/home" PATH="$BIN:/usr/bin:/bin" \
    RUN_ISSUES_LOCK_ROOT=/tmp/forced/locks \
    RUN_ISSUES_LOG_DIR=/tmp/forced/logs \
    bash -c '
      . "$1/lib/locking.sh"
      . "$1/lib/rate-limit.sh"
      printf "%s|%s" "$RUN_ISSUES_LOCK_ROOT" "$(rate_limit_state_file)"
    ' _ "$ROOT"
}

for sys in Darwin Linux MINGW64_NT-10.0; do
  expect "case5 the explicit override wins on $sys" \
    "$(override_under "$sys")" \
    "/tmp/forced/locks|/tmp/forced/logs/.rate-limit-backoff"
done

echo
if [ "$FAIL" -eq 0 ]; then
  echo "All default-path cases passed."
else
  echo "Some default-path cases FAILED."
fi
exit "$FAIL"
