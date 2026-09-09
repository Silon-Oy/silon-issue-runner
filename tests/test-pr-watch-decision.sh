#!/usr/bin/env bash
# test-pr-watch-decision.sh — unit tests for lib/pr-watch-lib.sh:pr_decide.
#
# Pure decision logic, no GitHub access. Feeds mocked `gh pr view` JSON and
# asserts the decision token. Enforces the core invariant: MERGE is only ever
# returned when (merge label AND mergeable AND required-checks-green) all hold
# together — where "required-checks-green" is ci==GREEN, or mergeStateStatus
# UNSTABLE (GitHub's verdict that the required checks passed while a non-required
# check is red/pending — issue #276, symptom C).
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

# assert <name> <expected> <json> <enable-res> <label> [enable-ci-repair]
assert() {
  local name="$1" expected="$2" json="$3" res="$4" lbl="$5" repair="${6:-0}"
  local got
  got=$(pr_decide "$json" "$res" "$lbl" "$repair")
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

# --- issue #131: a failed/empty fetch is SKIP_UNKNOWN, NOT SKIP_CLOSED ---------
# A blank .state or an absent .labels / .statusCheckRollup means `gh pr view`
# failed (rate limit / network / permissions), not that the PR is closed.
# Conflating the two silently stalls an open auto-merge PR for a whole rate-limit
# episode: SKIP_CLOSED is the very decision #65 suppresses on repeat, so the stall
# would leave no log line at all. These must classify DISTINCTLY as SKIP_UNKNOWN.
assert "empty-payload=SKIP_UNKNOWN"   SKIP_UNKNOWN ""              0 "$L"
assert "empty-object=SKIP_UNKNOWN"    SKIP_UNKNOWN "{}"            0 "$L"
assert "broken-json=SKIP_UNKNOWN"     SKIP_UNKNOWN "{not valid"   0 "$L"
# Partial payload: .state present but a required key missing (truncated response).
# No merge/skip decision is drawn from half a payload — SKIP_UNKNOWN.
assert "partial-no-labels=SKIP_UNKNOWN" SKIP_UNKNOWN \
  '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","statusCheckRollup":[]}' 0 "$L"
assert "partial-no-rollup=SKIP_UNKNOWN" SKIP_UNKNOWN \
  '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","labels":[]}'            0 "$L"
# Regression: genuine CLOSED/MERGED stay SKIP_CLOSED (blank state is the ONLY
# unknown), and an OPEN PR with a COMPLETE payload but an empty labels array is
# SKIP_NO_LABEL, NOT SKIP_UNKNOWN — an empty array is present, not missing.
assert "genuine-closed=SKIP_CLOSED"    SKIP_CLOSED   "$(mk CLOSED MERGEABLE CLEAN $L SUCCESS)"  0 "$L"
assert "open+empty-labels=SKIP_NO_LABEL" SKIP_NO_LABEL "$(mk OPEN MERGEABLE CLEAN '' SUCCESS)"  0 "$L"

# --- conflict resolution ON ---
assert "label+behind+resON=REBASE" REBASE        "$(mk OPEN MERGEABLE BEHIND $L SUCCESS)"       1 "$L"
assert "label+dirty+resON=REBASE"  REBASE        "$(mk OPEN CONFLICTING DIRTY $L SUCCESS)"      1 "$L"

# --- pending CI check (real pending, not empty rollup) ---
PENDING=$(jq -nc '{state:"OPEN",mergeable:"MERGEABLE",mergeStateStatus:"CLEAN",
  labels:[{name:"auto-merge"}],statusCheckRollup:[{status:"IN_PROGRESS",conclusion:null}]}')
assert "label+pending=WAIT_CI"     WAIT_CI       "$PENDING" 0 "$L"

# --- CI repair (issue #25): the new FIX_CI token, 4th arg = enable_ci_repair ---
# The motivating case is a REQUIRED check red => mergeStateStatus BLOCKED. RED +
# repair ON => FIX_CI; RED + repair OFF => WAIT_CI (bit-for-bit prior behaviour);
# PENDING => WAIT_CI regardless.
assert "red+blocked+repairON=FIX_CI"  FIX_CI   "$(mk OPEN MERGEABLE BLOCKED $L FAILURE)"  0 "$L" 1
assert "red+clean+repairON=FIX_CI"    FIX_CI   "$(mk OPEN MERGEABLE CLEAN   $L FAILURE)"  0 "$L" 1
assert "red+blocked+repairOFF=WAIT"   WAIT_CI  "$(mk OPEN MERGEABLE BLOCKED $L FAILURE)"  0 "$L" 0
assert "red+clean+repairOFF=WAIT"     WAIT_CI  "$(mk OPEN MERGEABLE CLEAN   $L FAILURE)"  0 "$L" 0
assert "pending+repairON=WAIT_CI"     WAIT_CI  "$PENDING"                                 0 "$L" 1

# Edge (issue #276, symptom C): UNSTABLE means GitHub deems the REQUIRED checks
# green and the PR mergeable; a non-required red must NOT be repaired (no FIX_CI)
# and must NOT block the merge. In a repo with NO required checks (branch
# protection off) EVERY red check yields UNSTABLE, so gating it on ci==GREEN left
# such a repo un-mergeable forever. So UNSTABLE + red + MERGEABLE + label => MERGE
# regardless of the CI-repair toggle — never FIX_CI, never WAIT_CI, and never a
# merge on a red REQUIRED check (that is BLOCKED, tested above).
assert "unstable+red+repairON=MERGE"  MERGE    "$(mk OPEN MERGEABLE UNSTABLE $L FAILURE)" 0 "$L" 1
assert "unstable+red+repairOFF=MERGE" MERGE    "$(mk OPEN MERGEABLE UNSTABLE $L FAILURE)" 0 "$L" 0
assert "unstable+green=MERGE"         MERGE    "$(mk OPEN MERGEABLE UNSTABLE $L SUCCESS)" 0 "$L" 1
# UNSTABLE but NOT mergeable (e.g. GitHub still computing) must not merge.
assert "unstable+red+notmergeable=WAIT" WAIT_CI "$(mk OPEN CONFLICTING UNSTABLE $L FAILURE)" 0 "$L" 1

# Edge: a PR that is both DIRTY and red rebases FIRST — REBASE (res ON) takes
# precedence over FIX_CI, so the two paths never nest in one invocation.
assert "dirty+red+resON+repairON=REBASE" REBASE "$(mk OPEN CONFLICTING DIRTY $L FAILURE)" 1 "$L" 1
assert "behind+red+resON+repairON=REBASE" REBASE "$(mk OPEN MERGEABLE BEHIND $L FAILURE)" 1 "$L" 1

# INVARIANT still holds with repair ON: FIX_CI is never MERGE.
assert "red+repairON!=MERGE(is FIX)" FIX_CI "$(mk OPEN MERGEABLE CLEAN $L FAILURE)" 0 "$L" 1

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

# ---------------------------------------------------------------------------
# Layer 2 (issue #131): SKIP_UNKNOWN must NEVER be written to state.jsonl as a
# pr_classified decision — otherwise the pr_last_decision tail-read learns a
# transient rate-limit failure as history (and, should #130 ever filter the scan
# on that history, permanently drops the PR). Runs pr-watch.sh with a mocked gh
# whose `pr view` serves an empty payload (an exit-0 soft failure that slips past
# the hard `if ! gh pr view` guard), and asserts: no pr_classified event, no
# merge, and a log line. A genuine CLOSED PR is the contrast — it DOES record the
# first SKIP_CLOSED — proving the non-recording is specific to the unknown case.
# ---------------------------------------------------------------------------
echo "--- pr-watch.sh integration: SKIP_UNKNOWN is not recorded ---"

PRWATCH="$HERE/../pr-watch.sh"
STATE_LIB="$HERE/../lib/state.sh"

# run_unknown_case <name> <pr-view-payload> <expect-classified:0|1>
run_unknown_case() {
  local name="$1" payload="$2" expect_classified="$3"

  local WORK; WORK=$(mktemp -d -t prwatch-unknown.XXXXXX)
  local REPO="$WORK/repo"
  git -C "$WORK" init -q "repo"

  local BIN="$WORK/bin"; mkdir -p "$BIN"
  local CALL_LOG="$WORK/gh-calls.log"; : > "$CALL_LOG"

  # gh mock: `pr view` prints the given payload (empty string => soft failure);
  # `pr merge` is recorded so we can assert it never fires. Everything else 0.
  cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
echo "gh \$*" >> "$CALL_LOG"
case "\$1 \$2" in
  "pr view")  printf '%s' '$payload' ;;
  "pr merge") echo "merged (mock)" ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$BIN/gh"

  local RID="20260829-1200-issue-77"
  local RD="$REPO/.claude/run-issues/$RID"
  # shellcheck source=../lib/state.sh
  . "$STATE_LIB"
  state_init "$RD" "$RID" "$REPO" "77"
  state_set "$RD" "pr_url" "https://github.com/Silon-Oy/dotfiles/pull/900"
  state_finalize "$RD" "completed"

  local out; out="$WORK/out.log"
  local rc=0
  (
    export PATH="$BIN:$PATH"
    export RUN_ISSUES_LOCK_ROOT="$WORK/locks"
    export PR_WATCH_ENABLE_CONFLICT_RESOLUTION=0
    set +e
    "$PRWATCH" "$REPO" 900 >"$out" 2>&1
    set -e
  ) || rc=$?

  local classified=0
  grep -q '"event":"pr_classified"' "$RD/state.jsonl" 2>/dev/null && classified=1
  local merged=0
  grep -q '^gh pr merge' "$CALL_LOG" && merged=1

  local ok=1
  [ "$classified" = "$expect_classified" ] || ok=0
  # Fail-closed: an unknown payload must NEVER merge.
  [ "$expect_classified" = "0" ] && [ "$merged" = "1" ] && ok=0

  if [ "$ok" = "1" ]; then
    PASS=$((PASS + 1)); printf 'PASS  %-44s -> classified=%s merged=%s\n' "$name" "$classified" "$merged"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL  %-44s -> classified=%s (want %s) merged=%s\n' \
      "$name" "$classified" "$expect_classified" "$merged"
    echo "    watcher output:"; sed 's/^/      /' "$out"
    echo "    state.jsonl:";    sed 's/^/      /' "$RD/state.jsonl"
  fi
  rm -rf "$WORK"
}

# Empty payload (soft fetch failure) => SKIP_UNKNOWN, not recorded.
run_unknown_case "empty payload -> not recorded"   ""                                        0
# Genuine closed PR => SKIP_CLOSED, IS recorded (first transition) — the contrast.
run_unknown_case "closed PR -> recorded (contrast)" '{"state":"CLOSED","mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","labels":[],"statusCheckRollup":[]}' 1

echo "----------------------------------------"
printf 'pr-watch-decision: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
