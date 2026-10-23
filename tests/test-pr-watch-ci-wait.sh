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
# Issue #354 bound the wait to the push: GitHub registers the new head's check
# runs seconds after a push, so an empty rollup (or one still carrying the old
# headRefOid) right after the push is PENDING. A checkless repo is accepted once
# its rollup has stayed empty for PR_WATCH_CI_EMPTY_GRACE_SECS, counted in polls.
#
# Run: bash tests/test-pr-watch-ci-wait.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Hermetic: never source this machine's real env file (CLAUDE.md §5.5, #358).
export RUN_ISSUES_ENV_FILE="$HERE/.no-such-machine-env"
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

SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OLD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# rollup <sha> <rollup-json-array> — a gh pr view --json headRefOid,statusCheckRollup payload.
rollup() { printf '{"headRefOid":"%s","statusCheckRollup":%s}' "$1" "$2"; }

GREEN_R='[{"status":"COMPLETED","conclusion":"SUCCESS"}]'
RED_R='[{"status":"COMPLETED","conclusion":"FAILURE"}]'
PENDING_R='[{"status":"IN_PROGRESS","conclusion":null}]'

# Stubs. gh_route serves GH_PAYLOADS one per call (the last one repeats), so a
# test can script how the rollup evolves across polls; sleep is counted so the
# budget spend is observable. log is pr-watch.sh's logger; captured for asserts.
# gh_route runs inside $(...), so its call counter lives in a file, not a var.
SLEEPS=0
sleep() { SLEEPS=$((SLEEPS + 1)); }
LOGS=""
log() { LOGS="${LOGS}$*"$'\n'; }
GH_PAYLOADS=()
GH_CALL_FILE=$(mktemp)
trap 'rm -f "$GH_CALL_FILE"' EXIT
gh_route() {
  local n=${#GH_PAYLOADS[@]} idx
  idx=$(cat "$GH_CALL_FILE"); idx=${idx:-0}
  printf '%s' "$((idx + 1))" >"$GH_CALL_FILE"
  [ "$idx" -lt "$n" ] || idx=$((n - 1))
  printf '%s' "${GH_PAYLOADS[$idx]}"
}

# check <name> <got-rc> <want-rc> [got-sleeps want-sleeps]
check() {
  local name="$1" rc="$2" want_rc="$3" sl="${4:-}" want_sl="${5:-}"
  local ok=1
  [ "$rc" = "$want_rc" ] || ok=0
  [ -z "$want_sl" ] || [ "$sl" = "$want_sl" ] || ok=0
  if [ "$ok" = "1" ]; then
    printf 'PASS  %-52s -> rc=%s sleeps=%s\n' "$name" "$rc" "$sl"
  else
    FAIL=1
    printf 'FAIL  %-52s -> rc=%s (want %s) sleeps=%s (want %s)\n' \
      "$name" "$rc" "$want_rc" "$sl" "${want_sl:-any}"
  fi
}

# wait_case <name> <max-polls> <poll-secs> <grace> <expected-sha> <want-rc> <want-sleeps> <payload>...
wait_case() {
  local name="$1" mp="$2" ps="$3" gr="$4" exp_sha="$5" want_rc="$6" want_sl="$7"
  shift 7
  GH_PAYLOADS=("$@"); : >"$GH_CALL_FILE"; SLEEPS=0; LOGS=""
  local rc=0
  PR_WATCH_CI_MAX_POLLS="$mp" PR_WATCH_CI_POLL_SECS="$ps" PR_WATCH_CI_EMPTY_GRACE_SECS="$gr" \
    pr_wait_ci_green 1 "$exp_sha" || rc=$?
  check "$name" "$rc" "$want_rc" "$SLEEPS" "$want_sl"
}

echo "--- pr_wait_ci_green (post-push wait) ---"
wait_case "green on pushed sha -> 0, no budget"   5 10 120 "$SHA" 0 0 "$(rollup "$SHA" "$GREEN_R")"
wait_case "red on pushed sha -> 1, no budget"     5 10 120 "$SHA" 1 0 "$(rollup "$SHA" "$RED_R")"
wait_case "pending -> times out after budget"     3 10 120 "$SHA" 1 3 "$(rollup "$SHA" "$PENDING_R")"

# (a) AC1: an empty rollup right after the push is NOT green.
wait_case "(a) empty right after push -> not green" 3 10 120 "$SHA" 1 3 "$(rollup "$SHA" '[]')"
# (b) checks appear on the pushed sha -> green as soon as they are.
wait_case "(b) empty -> pending -> green -> 0"      10 10 120 "$SHA" 0 2 \
  "$(rollup "$SHA" '[]')" "$(rollup "$SHA" "$PENDING_R")" "$(rollup "$SHA" "$GREEN_R")"
# (c) AC2: a checkless repo is green once the grace has elapsed (polls 0,10,20,30 -> 4th).
wait_case "(c) checkless repo -> 0 after grace"     10 10 30 "$SHA" 0 3 "$(rollup "$SHA" '[]')"
case "$LOGS" in
  *"no CI checks"*) printf 'PASS  %-52s\n' "(c) checkless acceptance is logged" ;;
  *) FAIL=1; printf 'FAIL  %-52s -> logs: %s\n' "(c) checkless acceptance is logged" "$LOGS" ;;
esac
# (d) AC1: the old head's green list never vouches for the new head.
wait_case "(d) old head green -> not green"         3 10 0 "$SHA" 1 3 "$(rollup "$OLD" "$GREEN_R")"
wait_case "(d') old head red -> not red either"     3 10 0 "$SHA" 1 3 "$(rollup "$OLD" "$RED_R")"
# (e) the head catches up to the pushed sha -> green.
wait_case "(e) old head -> new head green -> 0"     10 10 120 "$SHA" 0 1 \
  "$(rollup "$OLD" "$GREEN_R")" "$(rollup "$SHA" "$GREEN_R")"
# (f) no expected sha -> fail closed at once, even on a green list: green is
# impossible, so no budget is spent waiting for it.
wait_case "(f) empty expected sha -> 1, no budget"  2 10 0 "" 1 0 "$(rollup "$SHA" "$GREEN_R")"
# (g) the PR had checks before the push, so the repo has CI: an empty rollup is
# GitHub being slow, never a checkless repo — it times out to a human instead
# of merging the pushed head unchecked.
PR_HAD_CHECKS=1
wait_case "(g) had checks: empty stays pending -> 1" 10 10 30 "$SHA" 1 10 "$(rollup "$SHA" '[]')"
wait_case "(g') had checks: checks appear -> 0"     10 10 30 "$SHA" 0 5 \
  "$(rollup "$SHA" '[]')" "$(rollup "$SHA" '[]')" "$(rollup "$SHA" '[]')" "$(rollup "$SHA" '[]')" \
  "$(rollup "$SHA" '[]')" "$(rollup "$SHA" "$GREEN_R")"
PR_HAD_CHECKS=0
# a payload without headRefOid (old --json shape) never verifies.
wait_case "missing headRefOid -> not green"         2 10 0 "$SHA" 1 2 "{\"statusCheckRollup\":$GREEN_R}"

# A failed fetch (gh_route non-zero, empty output) must NEVER count as green:
# fail-safe, like the old rc!=0 path. It waits and eventually times out.
gh_route() { return 1; }; SLEEPS=0; rc=0
PR_WATCH_CI_MAX_POLLS=2 PR_WATCH_CI_POLL_SECS=0 PR_WATCH_CI_EMPTY_GRACE_SECS=0 \
  pr_wait_ci_green 1 "$SHA" || rc=$?
check "failed fetch -> never green" "$rc" 1

echo "--- pr_ci_wait_state (pure) ---"
# state_case <name> <json> <expected-sha> <elapsed> <grace> <want>
state_case() {
  local got; got=$(pr_ci_wait_state "$2" "$3" "$4" "$5" "${7:-0}")
  if [ "$got" = "$6" ]; then printf 'PASS  %-52s -> %s\n' "$1" "$got"
  else FAIL=1; printf 'FAIL  %-52s -> %s (want %s)\n' "$1" "$got" "$6"; fi
}
state_case "empty, grace not elapsed"     "$(rollup "$SHA" '[]')"         "$SHA" 0   120 PENDING
state_case "empty, grace just elapsed"    "$(rollup "$SHA" '[]')"         "$SHA" 120 120 GREEN
state_case "null rollup, grace elapsed"   "{\"headRefOid\":\"$SHA\",\"statusCheckRollup\":null}" "$SHA" 120 120 GREEN
state_case "green on sha"                 "$(rollup "$SHA" "$GREEN_R")"   "$SHA" 0   120 GREEN
state_case "red on sha"                   "$(rollup "$SHA" "$RED_R")"     "$SHA" 0   120 RED
state_case "pending on sha"               "$(rollup "$SHA" "$PENDING_R")" "$SHA" 999 120 PENDING
state_case "old sha green"                "$(rollup "$OLD" "$GREEN_R")"   "$SHA" 999 0   PENDING
state_case "empty expected sha"           "$(rollup "$SHA" "$GREEN_R")"   ""     999 0   PENDING
state_case "unparseable json"             "not json"                      "$SHA" 999 0   PENDING
state_case "empty, had checks, grace long gone" "$(rollup "$SHA" '[]')"    "$SHA" 999 0   PENDING 1
state_case "green, had checks"            "$(rollup "$SHA" "$GREEN_R")"   "$SHA" 0   120 GREEN   1

# CLAUDE.md §7: on the pushed sha with a non-empty rollup the wait's verdict is
# pr_ci_state's — one definition of "green". The empty rollup is the deliberate
# exception (push timing), and pr_ci_state itself still maps it to GREEN, so
# pr_decide's steady-state reading for a checkless repo is unchanged.
echo "--- convergence with pr_ci_state on the same input ---"
for r in "$GREEN_R" "$RED_R" "$PENDING_R"; do
  j=$(rollup "$SHA" "$r")
  a=$(pr_ci_state "$j"); b=$(pr_ci_wait_state "$j" "$SHA" 0 120)
  if [ "$a" = "$b" ]; then printf 'PASS  pr_ci_state=%-7s == pr_ci_wait_state\n' "$a"
  else FAIL=1; printf 'FAIL  pr_ci_state=%s but pr_ci_wait_state=%s\n' "$a" "$b"; fi
done
a=$(pr_ci_state "$(rollup "$SHA" '[]')")
if [ "$a" = "GREEN" ]; then printf 'PASS  %-52s\n' "pr_ci_state still maps empty rollup to GREEN"
else FAIL=1; printf 'FAIL  pr_ci_state empty rollup -> %s (want GREEN)\n' "$a"; fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "pr-watch-ci-wait: all passed" || echo "pr-watch-ci-wait: FAILURES"
[ "$FAIL" -eq 0 ]
