#!/usr/bin/env bash
# test-timeout-detection.sh — diagnostic + permanent probe for the timeout
# detection mechanism that the auto-restart feature relies on.
#
# Protects two invariants the orchestrator depends on (S8 + cleanup trap):
#
#   1. `timeout N cmd` returns rc=124 reliably when cmd overruns its budget.
#      The S8 rc-check (imp_rc=124 -> finalize_timeout) is built on this.
#
#   2. Code AFTER a timed-out command, when that command runs inside a
#      subshell `( timeout N cmd ); rc=$?`, still executes — i.e. timeout
#      kills only its CHILD (the slow command), not the surrounding subshell.
#      claude-call.sh line 55 (`printf rc > exit_file`) lives after the
#      timed-out claude call, so if the subshell itself were killed the .exit
#      file would never be written and the rc-path would be the only signal.
#
# If invariant 2 holds, the rc/.exit mechanism is load-bearing. If it ever
# breaks (e.g. timeout sends the signal to the whole process group), this
# test catches the regression and the cleanup-trap safety net becomes the
# only reliable mechanism.
#
# Run: bash tests/test-timeout-detection.sh

set -uo pipefail

# Resolve a timeout binary through the same function claude-call.sh uses, so
# this test cannot assert the invariants against a binary production would
# reject: preflight_timeout_bin requires a `--version` answer, and a copy of
# the old existence check would pick up the Windows delay tool of that name.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/preflight.sh
. "$HERE/../lib/preflight.sh"
# The lib sets -e for its production callers; a test must collect every failure.
set +e

TIMEOUT_BIN="$(preflight_timeout_bin)"

if [ -z "$TIMEOUT_BIN" ]; then
  echo "SKIP test-timeout-detection: no GNU timeout/gtimeout binary ($(preflight_install_hint timeout))"
  exit 0
fi

FAIL=0

# --- invariant 1: timeout returns 124 on overrun -------------------------
rc=0
"$TIMEOUT_BIN" 1 sleep 5 || rc=$?
echo "invariant 1: '$TIMEOUT_BIN 1 sleep 5' -> rc=$rc"
if [ "$rc" = "124" ]; then
  echo "PASS timeout returns 124 on overrun"
else
  echo "FAIL expected rc 124, got $rc"
  FAIL=1
fi

# --- invariant 2: post-timeout code runs in the subshell -----------------
# Mirror the orchestrator's pattern: a subshell runs a function that calls
# timeout and writes a marker file AFTER the timed-out command, exactly like
# claude-call.sh writes the .exit file on line 55.
WORK=$(mktemp -d -t timeout-detect.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
MARKER="$WORK/exit_file"

inner_call() {
  local inner_rc=0
  "$TIMEOUT_BIN" 1 sleep 5 || inner_rc=$?
  # This line is the analogue of claude-call.sh:55. It MUST run.
  printf '%s\n' "$inner_rc" > "$MARKER"
  return "$inner_rc"
}

# The `( ... ) || true` shape is exactly orchestrate.sh's S8 today.
sub_rc=0
( inner_call ) || sub_rc=$?
echo "invariant 2: subshell post-timeout rc=$sub_rc, marker=$( [ -f "$MARKER" ] && cat "$MARKER" || echo MISSING )"

if [ -f "$MARKER" ]; then
  echo "PASS post-timeout code ran (marker written)"
  if [ "$(cat "$MARKER")" = "124" ]; then
    echo "PASS marker recorded rc=124"
  else
    echo "FAIL marker did not record 124: $(cat "$MARKER")"
    FAIL=1
  fi
else
  echo "FAIL post-timeout code did NOT run (subshell killed) — rc-path unreliable, trap is mandatory"
  FAIL=1
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "timeout-detection: all passed" || echo "timeout-detection: FAILURES"
[ "$FAIL" -eq 0 ]
