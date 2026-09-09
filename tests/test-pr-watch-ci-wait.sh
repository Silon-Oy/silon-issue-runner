#!/usr/bin/env bash
# test-pr-watch-ci-wait.sh — unit tests for pr-watch.sh:pr_wait_ci_green.
#
# Issue #276, symptom A: the old pr_wait_ci_green polled `gh pr checks`, whose
# "no checks reported" (rc=1) on a repo with NO checks configured matched neither
# the pass nor the fail branch, so it spun the FULL 40×15s window and returned 1
# — leaving an otherwise mergeable PR stuck for ~10 min per rebase. The fix reads
# the SAME source as pr_decide's merge gate — the statusCheckRollup via
# pr_ci_state (CLAUDE.md §7) — so an empty rollup is GREEN and the function
# returns 0 IMMEDIATELY, without consuming any timeout budget.
#
# We extract pr_wait_ci_green from pr-watch.sh (same pattern as
# tests/test-pr-watch-scan-cost.sh), source pr_ci_state from lib/pr-watch-lib.sh,
# and stub gh_route + sleep so the poll is deterministic and the budget spend is
# observable (each sleep is one wasted poll).
#
# Run: bash tests/test-pr-watch-ci-wait.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_WATCH="$HERE/../pr-watch.sh"
PR_WATCH_LIB="$HERE/../lib/pr-watch-lib.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed"
  exit 0
fi

# pr_ci_state (the shared source of truth) lives here; functions only.
# shellcheck source=../lib/pr-watch-lib.sh
. "$PR_WATCH_LIB"

# Extract pr_wait_ci_green from pr-watch.sh (avoids sourcing the whole script,
# which does real work at load time).
body=$(awk '/^pr_wait_ci_green\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$PR_WATCH")
[ -n "$body" ] || { echo "FAIL: could not extract pr_wait_ci_green from pr-watch.sh"; exit 1; }
eval "$body"

FAIL=0

# Stubs. gh_route echoes the payload the test wants for this call; sleep is
# counted so we can assert an empty/red rollup consumes ZERO timeout budget.
SLEEPS=0
sleep() { SLEEPS=$((SLEEPS + 1)); }
GH_PAYLOAD='{"statusCheckRollup":[]}'
gh_route() { printf '%s' "$GH_PAYLOAD"; }

# run_case <name> <payload> <expected-rc> <expected-max-sleeps>
run_case() {
  local name="$1" payload="$2" want_rc="$3" want_sleeps="$4"
  GH_PAYLOAD="$payload"; SLEEPS=0
  local rc=0
  PR_WATCH_CI_MAX_POLLS=5 PR_WATCH_CI_POLL_SECS=0 pr_wait_ci_green 1 || rc=$?
  local ok=1
  [ "$rc" = "$want_rc" ] || ok=0
  [ "$SLEEPS" -le "$want_sleeps" ] || ok=0
  if [ "$ok" = "1" ]; then
    printf 'PASS  %-38s -> rc=%s sleeps=%s\n' "$name" "$rc" "$SLEEPS"
  else
    FAIL=1
    printf 'FAIL  %-38s -> rc=%s (want %s) sleeps=%s (want <=%s)\n' \
      "$name" "$rc" "$want_rc" "$SLEEPS" "$want_sleeps"
  fi
}

GREEN='{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}'
RED='{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE"}]}'

# THE symptom-A case: no checks configured => GREEN immediately, zero budget.
run_case "empty rollup -> 0, no budget"  '{"statusCheckRollup":[]}'  0 0
run_case "green rollup -> 0, no budget"  "$GREEN"                    0 0
run_case "red rollup   -> 1, no budget"  "$RED"                      1 0

# A pending rollup DOES consume the budget (that is the point of the poll) and
# then times out to a non-green result.
PENDING='{"statusCheckRollup":[{"status":"IN_PROGRESS","conclusion":null}]}'
GH_PAYLOAD="$PENDING"; SLEEPS=0; rc=0
PR_WATCH_CI_MAX_POLLS=3 PR_WATCH_CI_POLL_SECS=0 pr_wait_ci_green 1 || rc=$?
if [ "$rc" = "1" ] && [ "$SLEEPS" = "3" ]; then
  printf 'PASS  %-38s -> rc=%s sleeps=%s\n' "pending -> times out after budget" "$rc" "$SLEEPS"
else
  FAIL=1
  printf 'FAIL  %-38s -> rc=%s sleeps=%s (want rc=1 sleeps=3)\n' "pending -> times out" "$rc" "$SLEEPS"
fi

# A failed fetch (gh_route non-zero, empty output) must NEVER count as green:
# fail-safe, like the old rc!=0 path. It waits and eventually times out.
GH_PAYLOAD=""; gh_route() { return 1; }; SLEEPS=0; rc=0
PR_WATCH_CI_MAX_POLLS=2 PR_WATCH_CI_POLL_SECS=0 pr_wait_ci_green 1 || rc=$?
if [ "$rc" = "1" ]; then
  printf 'PASS  %-38s -> rc=%s\n' "failed fetch -> never green" "$rc"
else
  FAIL=1
  printf 'FAIL  %-38s -> rc=%s (want 1)\n' "failed fetch -> never green" "$rc"
fi
gh_route() { printf '%s' "$GH_PAYLOAD"; }   # restore

# AC2 (CLAUDE.md §7): pr_wait_ci_green and pr_ci_state cannot disagree, because
# the former DERIVES its verdict from the latter. Assert convergence on the same
# inputs, empty rollup included: GREEN/pending => 0-or-wait, RED => 1.
echo "--- convergence with pr_ci_state on the same input ---"
for payload in '{"statusCheckRollup":[]}' "$GREEN" "$RED"; do
  ci=$(pr_ci_state "$payload")
  GH_PAYLOAD="$payload"; SLEEPS=0; rc=0
  PR_WATCH_CI_MAX_POLLS=1 PR_WATCH_CI_POLL_SECS=0 pr_wait_ci_green 1 || rc=$?
  case "$ci" in
    GREEN) exp=0 ;;
    RED)   exp=1 ;;
    *)     exp=1 ;;   # pending times out with max_polls=1
  esac
  if [ "$rc" = "$exp" ]; then
    printf 'PASS  pr_ci_state=%-7s -> wait rc=%s (converges)\n' "$ci" "$rc"
  else
    FAIL=1
    printf 'FAIL  pr_ci_state=%-7s -> wait rc=%s (want %s)\n' "$ci" "$rc" "$exp"
  fi
done

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "pr-watch-ci-wait: all passed" || echo "pr-watch-ci-wait: FAILURES"
[ "$FAIL" -eq 0 ]
