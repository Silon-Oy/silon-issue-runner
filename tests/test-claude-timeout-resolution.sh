#!/usr/bin/env bash
# test-claude-timeout-resolution.sh — the three-step resolution order for the
# per-call claude budget (issue #200).
#
# THE BUG. lib/claude-call.sh used to assign
# `RUN_ISSUES_CLAUDE_TIMEOUT="${RUN_ISSUES_CLAUDE_TIMEOUT:-3600}"` at source
# time. orchestrate.sh sources it long before it reads the target repo's
# .claude/run-issues.json, and load_repo_timeout's first line asks "is
# RUN_ISSUES_CLAUDE_TIMEOUT already set? then someone overrode me, stand down".
# After the source-time assignment that answer was YES on every run, so
# claude_timeout_seconds was dead configuration — documented in README §7 and
# never applied. The same trap is what locked the machine env file out of
# RUN_ISSUES_CLAUDE_CMD (tests/test-machine-env.sh, cases 8-11 and Y).
#
# The fix keeps the variable UNSET unless someone actually configured it, and
# applies the default in one place at call time (claude_call_timeout). Case (a)
# is the structural guard: it fails the moment anyone reintroduces a `:-`
# default at source time, which is the only way this can regress.
#
# Cases:
#   (a) sourcing lib/claude-call.sh leaves RUN_ISSUES_CLAUDE_TIMEOUT UNSET
#   (b) claude_call_timeout -> the packaged default when nothing is configured
#   (c) claude_call_timeout -> the environment value when one is set
#   (d) load_repo_timeout applies claude_timeout_seconds from the repo config
#   (e) an environment value beats the repo config
#   (f) absent file / absent key / broken JSON / non-numeric -> default, no error
#   (g) the resolved value reaches the actual `timeout` prefix, not just a var
#
# Run: bash tests/test-claude-timeout-resolution.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
LIB="$ROOT/lib/claude-call.sh"
ORCH="$ROOT/orchestrate.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }

WORK=$(mktemp -d -t claude-timeout.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — got '$2', want '$3'"; fi; }

# orchestrate.sh exports RUN_ISSUES_CLAUDE_TIMEOUT into the agents it launches,
# so a run of this suite from inside an orchestrated step would inherit a value
# and turn the "nothing configured" cases red for an unrelated reason. Every
# case below supplies its own inputs.
unset RUN_ISSUES_CLAUDE_TIMEOUT

# ===========================================================================
# (a) the structural guard
# ===========================================================================
OUT=$(bash -c '. "$1" >/dev/null 2>&1; printf "%s" "${RUN_ISSUES_CLAUDE_TIMEOUT-<unset>}"' _ "$LIB")
if [ "$OUT" = "<unset>" ]; then
  pass "(a) sourcing claude-call.sh leaves RUN_ISSUES_CLAUDE_TIMEOUT unset"
else
  fail "(a) sourcing claude-call.sh SET RUN_ISSUES_CLAUDE_TIMEOUT to '$OUT' — this makes load_repo_timeout's override test always true and claude_timeout_seconds dead configuration"
fi

# The default must still exist somewhere; a fix that just deletes the assignment
# would leave `timeout` with an empty argument.
OUT=$(bash -c '. "$1" >/dev/null 2>&1; printf "%s" "${RUN_ISSUES_CLAUDE_TIMEOUT_DEFAULT-<unset>}"' _ "$LIB")
case "$OUT" in
  ''|*[!0-9]*) fail "(a) RUN_ISSUES_CLAUDE_TIMEOUT_DEFAULT is not a number: '$OUT'" ;;
  *) pass "(a) the default lives in RUN_ISSUES_CLAUDE_TIMEOUT_DEFAULT ($OUT)" ;;
esac
DEFAULT_TIMEOUT="$OUT"

# ===========================================================================
# (b)(c) claude_call_timeout
# ===========================================================================
OUT=$(bash -c '. "$1" >/dev/null 2>&1; claude_call_timeout' _ "$LIB")
check "(b) unconfigured -> the packaged default" "$OUT" "$DEFAULT_TIMEOUT"

OUT=$(RUN_ISSUES_CLAUDE_TIMEOUT=99 bash -c '. "$1" >/dev/null 2>&1; claude_call_timeout' _ "$LIB")
check "(c) environment value wins" "$OUT" "99"

# An empty value is "not configured", not "a zero-second budget": a zero would
# make `timeout` kill every call instantly.
OUT=$(RUN_ISSUES_CLAUDE_TIMEOUT='' bash -c '. "$1" >/dev/null 2>&1; claude_call_timeout' _ "$LIB")
check "(c) empty value falls back to the default" "$OUT" "$DEFAULT_TIMEOUT"

# ===========================================================================
# (d)(e)(f) load_repo_timeout
# ===========================================================================
# orchestrate.sh has no main-guard, so the helper is extracted with sed+eval —
# the same technique tests/test-base-branch.sh uses for load_repo_base_branch.
eval "$(sed -n '/^load_repo_timeout() {/,/^}/p' "$ORCH")"
declare -F load_repo_timeout >/dev/null 2>&1 \
  || { echo "FAIL: could not extract load_repo_timeout from orchestrate.sh"; exit 1; }
log() { :; }  # the helper logs its decision; the suite does not read it

CFGREPO="$WORK/cfgrepo"
mkdir -p "$CFGREPO/.claude"

# resolve <config-json-or-empty> — runs load_repo_timeout in a subshell and
# prints the budget that a claude call would actually get.
resolve() {
  (
    . "$LIB" >/dev/null 2>&1
    load_repo_timeout "$CFGREPO" >/dev/null 2>&1
    claude_call_timeout
  )
}

echo '{"claude_timeout_seconds":2700}' > "$CFGREPO/.claude/run-issues.json"
check "(d) repo claude_timeout_seconds applies" "$(resolve)" "2700"

OUT=$(RUN_ISSUES_CLAUDE_TIMEOUT=99 resolve)
check "(e) environment override beats the repo config" "$OUT" "99"

F_OK=1
rm -f "$CFGREPO/.claude/run-issues.json"
[ "$(resolve)" = "$DEFAULT_TIMEOUT" ] || { fail "(f) absent config did not fall back to the default"; F_OK=0; }
echo '{"base_branch":"twenty"}' > "$CFGREPO/.claude/run-issues.json"
[ "$(resolve)" = "$DEFAULT_TIMEOUT" ] || { fail "(f) absent key did not fall back to the default"; F_OK=0; }
echo '{not json' > "$CFGREPO/.claude/run-issues.json"
[ "$(resolve)" = "$DEFAULT_TIMEOUT" ] || { fail "(f) broken JSON did not fall back to the default"; F_OK=0; }
echo '{"claude_timeout_seconds":"soon"}' > "$CFGREPO/.claude/run-issues.json"
[ "$(resolve)" = "$DEFAULT_TIMEOUT" ] || { fail "(f) non-numeric value did not fall back to the default"; F_OK=0; }
[ "$F_OK" = "1" ] && pass "(f) absent config / absent key / broken JSON / non-numeric -> default, no error"

# ===========================================================================
# (g) the value reaches the command line
# ===========================================================================
# Without this the whole resolution could be correct bookkeeping that no claude
# call ever consults.
if [ -z "$(bash -c '. "$1" >/dev/null 2>&1; preflight_timeout_bin' _ "$LIB")" ]; then
  echo "SKIP: (g) no timeout/gtimeout binary on this machine"
else
  echo '{"claude_timeout_seconds":2700}' > "$CFGREPO/.claude/run-issues.json"
  OUT=$(
    . "$LIB" >/dev/null 2>&1
    load_repo_timeout "$CFGREPO" >/dev/null 2>&1
    _resolve_timeout
  )
  case "$OUT" in
    *" 2700") pass "(g) the timeout prefix carries the repo value: $OUT" ;;
    *) fail "(g) the timeout prefix does not carry the repo value — got '$OUT'" ;;
  esac
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "claude-timeout-resolution: all passed" || echo "claude-timeout-resolution: FAILURES"
[ "$FAIL" -eq 0 ]
