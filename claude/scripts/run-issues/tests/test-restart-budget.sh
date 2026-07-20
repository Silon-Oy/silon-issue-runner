#!/usr/bin/env bash
# test-restart-budget.sh — --restart retry budget + worktree validation.
#
# Covers:
#   (a) retry increment: a timed_out run with retry_count<max is restartable;
#       state_increment_retry bumps the counter before the claude call.
#   (b) budget exhausted: retry_count>=max -> finalize timed_out +
#       timeout_budget_exhausted, best-effort needs-human label (mocked gh),
#       exit 0 (terminal, not an error).
#   (c) worktree validation: a missing/corrupt worktree -> finalize blocked +
#       restart_worktree_corrupt, exit 0, needs-human.
#
# gh + claude + git mocked via PATH shims. No network, no real worktree builds.
#
# Run: bash tests/test-restart-budget.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$HERE/../orchestrate.sh"
STATE_LIB="$HERE/../lib/state.sh"

WORK=$(mktemp -d -t restart-budget.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
git -C "$WORK" init -q "repo"

BIN="$WORK/bin"
mkdir -p "$BIN"

# gh mock: record label-add calls so we can assert needs-human was attempted.
GH_LOG="$WORK/gh-calls.log"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"
exit 0
SH
chmod +x "$BIN/gh"

# shellcheck source=lib/state.sh
. "$STATE_LIB"

# Helper: make a feature worktree with one commit ahead of origin/main.
make_worktree() {
  local wt="$1"
  git -C "$WORK" init -q "$(basename "$wt")"
  ( cd "$wt"
    git config user.email t@t; git config user.name t
    git commit -q --allow-empty -m base
    git branch -q -f origin/main HEAD 2>/dev/null || true
    # emulate origin/main ref so `origin/main..HEAD` resolves
    git update-ref refs/remotes/origin/main HEAD
    git commit -q --allow-empty -m "feat: partial work from prior run"
  )
}

run_orch() {
  ( cd "$REPO" && \
    PATH="$BIN:$PATH" \
    RUN_ISSUES_AUTO=1 \
    RUN_ISSUES_CLAUDE_CMD="$BIN/claude" \
    RUN_ISSUES_LOCK_ROOT="$WORK/locks" \
    "$@" )
}

FAIL=0

# === (a) retry increment under budget =====================================
# claude mock that just emits a SUCCESS line and exits 0 so phase_b proceeds
# past S8 (it will then fail at evolution/PR with mocked gh — we only assert
# the retry was incremented, which happens BEFORE the claude call).
cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
echo "IMPLEMENTER_RESULT: BLOCKED — stop here, we only test the increment"
SH
chmod +x "$BIN/claude"

RID="20260521-1600-issue-50"
RD="$REPO/.claude/run-issues/$RID"
WT="$WORK/wt-a"
make_worktree "$WT"
state_init "$RD" "$RID" "$REPO" "50"
state_set "$RD" "branch" "auto-run/issue-50-x"
state_set "$RD" "worktree_path" "$WT"
echo '{"title":"t","body":"b","comments":[]}' > "$RD/issue.json"
echo "ok" > "$RD/01-cycle-review.out"
state_finalize "$RD" "timed_out" "implementer_timeout"

set +e
OUT_A=$(run_orch env RUN_ISSUES_MAX_RETRIES=1 "$ORCH" --restart "$RD" 2>&1)
RC_A=$?
set -e
echo "--- (a) retry increment (rc=$RC_A) ---"; echo "$OUT_A" | tail -4
NEW_RETRY=$(jq -r '.retry_count' "$RD/run.json")
[ "$NEW_RETRY" = "1" ] || { echo "FAIL (a): retry_count='$NEW_RETRY' (want 1)"; FAIL=1; }
grep -q '"event":"restart_attempt"' "$RD/state.jsonl" || { echo "FAIL (a): no restart_attempt event"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (a) retry incremented to 1 before claude call"

# === (b) budget exhausted =================================================
RID2="20260521-1601-issue-51"
RD2="$REPO/.claude/run-issues/$RID2"
WT2="$WORK/wt-b"
make_worktree "$WT2"
state_init "$RD2" "$RID2" "$REPO" "51"
state_set "$RD2" "branch" "auto-run/issue-51-x"
state_set "$RD2" "worktree_path" "$WT2"
echo '{"title":"t","body":"b","comments":[]}' > "$RD2/issue.json"
# Already spent the budget.
tmp=$(mktemp); jq '.retry_count = 1' "$RD2/run.json" > "$tmp"; mv "$tmp" "$RD2/run.json"
state_finalize "$RD2" "timed_out" "implementer_timeout"
: > "$GH_LOG"

set +e
OUT_B=$(run_orch env RUN_ISSUES_MAX_RETRIES=1 "$ORCH" --restart "$RD2" 2>&1)
RC_B=$?
set -e
echo "--- (b) budget exhausted (rc=$RC_B) ---"; echo "$OUT_B" | tail -4
[ "$RC_B" = "0" ] || { echo "FAIL (b): expected exit 0, got $RC_B"; FAIL=1; }
ST_B=$(jq -r '.status' "$RD2/run.json")
RE_B=$(jq -r '.blocked_reason' "$RD2/run.json")
[ "$ST_B" = "timed_out" ] || { echo "FAIL (b): status='$ST_B'"; FAIL=1; }
[ "$RE_B" = "timeout_budget_exhausted" ] || { echo "FAIL (b): reason='$RE_B'"; FAIL=1; }
grep -qF 'labels[]=needs-human' "$GH_LOG" || { echo "FAIL (b): needs-human label not attempted"; FAIL=1; }
[ "$(jq -r '.retry_count' "$RD2/run.json")" = "1" ] || { echo "FAIL (b): retry_count changed despite exhaustion"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (b) budget exhausted -> timed_out + needs-human + exit 0"

# === (c) corrupt worktree =================================================
RID3="20260521-1602-issue-52"
RD3="$REPO/.claude/run-issues/$RID3"
state_init "$RD3" "$RID3" "$REPO" "52"
state_set "$RD3" "branch" "auto-run/issue-52-x"
state_set "$RD3" "worktree_path" "$WORK/does-not-exist"
echo '{"title":"t","body":"b","comments":[]}' > "$RD3/issue.json"
state_finalize "$RD3" "timed_out" "implementer_timeout"
: > "$GH_LOG"

set +e
OUT_C=$(run_orch env RUN_ISSUES_MAX_RETRIES=1 "$ORCH" --restart "$RD3" 2>&1)
RC_C=$?
set -e
echo "--- (c) corrupt worktree (rc=$RC_C) ---"; echo "$OUT_C" | tail -4
[ "$RC_C" = "0" ] || { echo "FAIL (c): expected exit 0, got $RC_C"; FAIL=1; }
ST_C=$(jq -r '.status' "$RD3/run.json")
RE_C=$(jq -r '.blocked_reason' "$RD3/run.json")
[ "$ST_C" = "blocked" ] || { echo "FAIL (c): status='$ST_C'"; FAIL=1; }
[ "$RE_C" = "restart_worktree_corrupt" ] || { echo "FAIL (c): reason='$RE_C'"; FAIL=1; }
grep -qF 'labels[]=needs-human' "$GH_LOG" || { echo "FAIL (c): needs-human not attempted"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (c) corrupt worktree -> blocked + needs-human + exit 0"

# === (d) poller second-timeout: restart proceeds, claude times out AGAIN ===
# This is the autoflow path the budget-branch never covers: scan_timed_out only
# restarts runs with retry_count<MAX, so a restarted run that times out a second
# time finalizes via finalize_timeout's rc-path. That path must hand to a human
# (needs-human + comment), otherwise the issue wedges silently with no signal.
#
# Drive it: a timed_out run at retry_count=0 (eligible), MAX_RETRIES=1. The
# restart increments to 1, then the claude mock overruns a 1s timeout (rc=124).
# finalize_timeout sees retry_count=1 >= 1 -> _hand_to_human.
RID4="20260521-1603-issue-53"
RD4="$REPO/.claude/run-issues/$RID4"
WT4="$WORK/wt-d"
make_worktree "$WT4"
state_init "$RD4" "$RID4" "$REPO" "53"
state_set "$RD4" "branch" "auto-run/issue-53-x"
state_set "$RD4" "worktree_path" "$WT4"
echo '{"title":"t","body":"b","comments":[]}' > "$RD4/issue.json"
echo "ok" > "$RD4/01-cycle-review.out"
state_finalize "$RD4" "timed_out" "implementer_timeout"
: > "$GH_LOG"

# claude mock that overruns the (tiny) timeout so timeout(1) returns 124.
cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
chmod +x "$BIN/claude"

set +e
OUT_D=$(run_orch env RUN_ISSUES_MAX_RETRIES=1 RUN_ISSUES_CLAUDE_TIMEOUT=1 \
  "$ORCH" --restart "$RD4" 2>&1)
RC_D=$?
set -e
echo "--- (d) second timeout via rc-path (rc=$RC_D) ---"; echo "$OUT_D" | tail -5
[ "$RC_D" = "7" ] || { echo "FAIL (d): expected exit 7, got $RC_D"; FAIL=1; }
ST_D=$(jq -r '.status' "$RD4/run.json")
RE_D=$(jq -r '.blocked_reason' "$RD4/run.json")
RT_D=$(jq -r '.retry_count' "$RD4/run.json")
[ "$ST_D" = "timed_out" ] || { echo "FAIL (d): status='$ST_D'"; FAIL=1; }
[ "$RT_D" = "1" ] || { echo "FAIL (d): retry_count='$RT_D' (want 1)"; FAIL=1; }
[ "$RE_D" = "timeout_budget_exhausted" ] || { echo "FAIL (d): reason='$RE_D' (want budget-exhausted from finalize_timeout)"; FAIL=1; }
grep -qF 'labels[]=needs-human' "$GH_LOG" || { echo "FAIL (d): needs-human label NOT attempted on second timeout (the wedge bug)"; FAIL=1; }
grep -q '"event":"handed_to_human"' "$RD4/state.jsonl" || { echo "FAIL (d): no handed_to_human event"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (d) second timeout via rc-path -> needs-human + exit 7"

# === (e) FIRST timeout (retry_count=0 < max) must NOT hand to human ========
# Negative control: the first timeout finalizes timed_out so the poller can
# restart it. It must NOT label needs-human (otherwise we'd hand off prematurely).
RID5="20260521-1604-issue-54"
RD5="$REPO/.claude/run-issues/$RID5"
WT5="$WORK/wt-e"
make_worktree "$WT5"
state_init "$RD5" "$RID5" "$REPO" "54"
state_set "$RD5" "branch" "auto-run/issue-54-x"
state_set "$RD5" "worktree_path" "$WT5"
state_set "$RD5" "cycle_review_decision" "PROCEED"
echo '{"title":"t","body":"b","comments":[]}' > "$RD5/issue.json"
echo "CYCLE_REVIEW_DECISION: PROCEED" > "$RD5/01-cycle-review.out"
: > "$GH_LOG"

# Drive a FIRST-run timeout via --resume PROCEED (retry_count stays 0).
set +e
OUT_E=$(run_orch env RUN_ISSUES_MAX_RETRIES=1 RUN_ISSUES_CLAUDE_TIMEOUT=1 \
  RUN_ISSUES_REVIEW_GATE=auto \
  "$ORCH" --resume "$RD5" --decision PROCEED 2>&1)
RC_E=$?
set -e
echo "--- (e) first timeout, no hand-off (rc=$RC_E) ---"; echo "$OUT_E" | tail -4
[ "$RC_E" = "7" ] || { echo "FAIL (e): expected exit 7, got $RC_E"; FAIL=1; }
[ "$(jq -r '.status' "$RD5/run.json")" = "timed_out" ] || { echo "FAIL (e): status not timed_out"; FAIL=1; }
[ "$(jq -r '.retry_count' "$RD5/run.json")" = "0" ] || { echo "FAIL (e): retry_count moved off 0 on first timeout"; FAIL=1; }
if grep -qF 'labels[]=needs-human' "$GH_LOG"; then echo "FAIL (e): needs-human labelled on FIRST timeout (premature hand-off)"; FAIL=1; fi
[ "$FAIL" = "0" ] && echo "PASS (e) first timeout -> timed_out, NO needs-human (poller will restart)"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "restart-budget: all passed" || echo "restart-budget: FAILURES"
[ "$FAIL" -eq 0 ]
