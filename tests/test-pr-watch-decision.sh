#!/usr/bin/env bash
# test-pr-watch-decision.sh — unit tests for lib/pr-watch-lib.sh:pr_decide.
#
# Pure decision logic, no GitHub access. Feeds mocked `gh pr view` JSON and
# asserts the decision token. Enforces the core invariant: MERGE is only ever
# returned when (merge label AND CI green AND mergeable) all hold together.
#
# Run: bash tests/test-pr-watch-decision.sh   (exit 0 = all pass)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pr-watch-lib.sh
. "$HERE/../lib/pr-watch-lib.sh"

PASS=0
FAIL=0

# mk <state> <mergeable> <mergeState> <label> <ci-conclusion>
# Empty <label> => no labels; empty <ci> => empty rollup (= green, no checks).
mk() {
  jq -nc --arg s "$1" --arg m "$2" --arg ms "$3" --arg lbl "$4" --arg ci "$5" '
    {state:$s, mergeable:$m, mergeStateStatus:$ms,
     labels: (if $lbl=="" then [] else [{name:$lbl}] end),
     statusCheckRollup: (if $ci=="" then [] else [{status:"COMPLETED", conclusion:$ci}] end)}'
}

# assert <name> <expected> <json> <enable-res> <label>
assert() {
  local name="$1" expected="$2" json="$3" res="$4" lbl="$5"
  local got
  got=$(pr_decide "$json" "$res" "$lbl")
  if [ "$got" = "$expected" ]; then
    PASS=$((PASS + 1))
    printf 'PASS  %-40s -> %s\n' "$name" "$got"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  %-40s -> got=%s expected=%s\n' "$name" "$got" "$expected"
  fi
}

L=auto-merge

# --- conflict resolution OFF (default) ---
assert "label+green+clean=MERGE"   MERGE         "$(mk OPEN MERGEABLE CLEAN $L SUCCESS)"        0 "$L"
assert "no-label=SKIP_NO_LABEL"    SKIP_NO_LABEL "$(mk OPEN MERGEABLE CLEAN '' SUCCESS)"        0 "$L"
assert "label+red=WAIT_CI"         WAIT_CI       "$(mk OPEN MERGEABLE CLEAN $L FAILURE)"        0 "$L"
assert "label+dirty+resOFF=WAIT"   WAIT_DIRTY    "$(mk OPEN CONFLICTING DIRTY $L SUCCESS)"      0 "$L"
assert "label+behind+resOFF=WAIT"  WAIT_DIRTY    "$(mk OPEN MERGEABLE BEHIND $L SUCCESS)"       0 "$L"
assert "closed=SKIP_CLOSED"        SKIP_CLOSED   "$(mk MERGED MERGEABLE CLEAN $L SUCCESS)"      0 "$L"
assert "blocked=SKIP_BLOCKED"      SKIP_BLOCKED  "$(mk OPEN MERGEABLE BLOCKED $L SUCCESS)"      0 "$L"

# --- conflict resolution ON ---
assert "label+behind+resON=REBASE" REBASE        "$(mk OPEN MERGEABLE BEHIND $L SUCCESS)"       1 "$L"
assert "label+dirty+resON=REBASE"  REBASE        "$(mk OPEN CONFLICTING DIRTY $L SUCCESS)"      1 "$L"

# --- pending CI check (real pending, not empty rollup) ---
PENDING=$(jq -nc '{state:"OPEN",mergeable:"MERGEABLE",mergeStateStatus:"CLEAN",
  labels:[{name:"auto-merge"}],statusCheckRollup:[{status:"IN_PROGRESS",conclusion:null}]}')
assert "label+pending=WAIT_CI"     WAIT_CI       "$PENDING" 0 "$L"

# --- INVARIANT: MERGE requires all three. Brute-force every combination of
#     the three gate inputs and assert MERGE only with the all-true row. ---
echo "--- invariant sweep: MERGE iff (label AND green AND mergeable) ---"
for has_label in 0 1; do
  for ci in SUCCESS FAILURE; do
    for ms in CLEAN DIRTY; do
      lbl=""; [ "$has_label" = "1" ] && lbl="$L"
      mrg="MERGEABLE"; [ "$ms" = "DIRTY" ] && mrg="CONFLICTING"
      j=$(mk OPEN "$mrg" "$ms" "$lbl" "$ci")
      d=$(pr_decide "$j" 0 "$L")
      should_merge=0
      if [ "$has_label" = "1" ] && [ "$ci" = "SUCCESS" ] && [ "$ms" = "CLEAN" ]; then
        should_merge=1
      fi
      if [ "$should_merge" = "1" ] && [ "$d" = "MERGE" ]; then
        PASS=$((PASS + 1))
      elif [ "$should_merge" = "0" ] && [ "$d" != "MERGE" ]; then
        PASS=$((PASS + 1))
      else
        FAIL=$((FAIL + 1))
        printf 'FAIL  invariant label=%s ci=%s ms=%s -> %s (should_merge=%s)\n' \
          "$has_label" "$ci" "$ms" "$d" "$should_merge"
      fi
    done
  done
done

echo "----------------------------------------"
printf 'pr-watch-decision: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
