#!/usr/bin/env bash
# test-timeout-finalize.sh — S8 implementer timeout finalization.
#
# Verifies that when the implementer claude call times out (rc=124), the
# orchestrator finalizes the run as timed_out (not left initialized), records
# current_state + timeout_phase, and exits 7 — via BOTH:
#   (a) the rc-path: imp_rc=124 -> finalize_timeout + exit 7
#   (b) the cleanup-trap safety net: the run is left non-terminal in S8 and the
#       EXIT trap finalizes it as timed_out.
#
# Everything external is mocked via PATH shims (claude, gh, git) so no network,
# no GitHub, no real worktree. We drive orchestrate.sh in resume mode (PROCEED)
# so it jumps straight to phase_b/S8 without going through pick/claim.
#
# Run: bash tests/test-timeout-finalize.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$HERE/../orchestrate.sh"
STATE_LIB="$HERE/../lib/state.sh"

WORK=$(mktemp -d -t timeout-finalize.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
git -C "$WORK" init -q "repo"
WORKTREE="$WORK/worktree"
git -C "$WORK" init -q "worktree"

BIN="$WORK/bin"
mkdir -p "$BIN"

# gh mock: claim/comment/etc — accept everything quietly.
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$BIN/gh"

# Set up a run-dir in awaiting_review state so resume jumps to phase_b.
RID="20260521-1500-issue-99"
RD="$REPO/.claude/run-issues/$RID"
# shellcheck source=lib/state.sh
. "$STATE_LIB"
state_init "$RD" "$RID" "$REPO" "99"
state_set "$RD" "branch" "auto-run/issue-99-x"
state_set "$RD" "worktree_path" "$WORKTREE"
state_set "$RD" "cycle_review_decision" "PROCEED"
# Minimal issue.json so resume_load_state doesn't try to fetch.
mkdir -p "$RD"
echo '{"title":"t","body":"b","comments":[]}' > "$RD/issue.json"
echo "CYCLE_REVIEW_DECISION: PROCEED" > "$RD/01-cycle-review.out"

run_orch() {
  ( cd "$REPO" && \
    PATH="$BIN:$PATH" \
    RUN_ISSUES_AUTO=1 RUN_ISSUES_REVIEW_GATE=auto \
    RUN_ISSUES_CLAUDE_CMD="$BIN/claude" \
    RUN_ISSUES_LOCK_ROOT="$WORK/locks" \
    "$@" )
}

FAIL=0

# === (a) rc-path: claude mock sleeps past a tiny timeout -> rc 124 =========
# The rc-path exists only when timeout(1) can return 124; without a timeout
# binary call_claude runs the mock uncapped, so the case is SKIPped the way the
# sibling timeout tests do. Case (b) drives the cleanup trap and does not need it.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
chmod +x "$BIN/claude"

set +e
OUT_A=$(run_orch env RUN_ISSUES_CLAUDE_TIMEOUT=1 \
  "$ORCH" --resume "$RD" --decision PROCEED 2>&1)
RC_A=$?
set -e
echo "--- rc-path output (rc=$RC_A) ---"
echo "$OUT_A" | tail -5

[ "$RC_A" = "7" ] || { echo "FAIL rc-path: expected exit 7, got $RC_A"; FAIL=1; }
ST_A=$(jq -r '.status' "$RD/run.json")
[ "$ST_A" = "timed_out" ] || { echo "FAIL rc-path: status='$ST_A' (want timed_out)"; FAIL=1; }
TP_A=$(jq -r '.timeout_phase' "$RD/run.json")
[ "$TP_A" = "S8_Implementer" ] || { echo "FAIL rc-path: timeout_phase='$TP_A'"; FAIL=1; }
CS_A=$(jq -r '.current_state' "$RD/run.json")
[ "$CS_A" = "S8_Implementer" ] || { echo "FAIL rc-path: current_state='$CS_A'"; FAIL=1; }
grep -q '"event":"implementer_timed_out"' "$RD/state.jsonl" \
  || { echo "FAIL rc-path: no implementer_timed_out event"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS rc-path: timed_out + exit 7 + current_state/timeout_phase"
else
  echo "SKIP: rc-path case needs a timeout/gtimeout binary on PATH (brew install coreutils)"
fi

# === (b) trap-path: simulate a hard kill that skips the rc handler =========
# Reset the run-dir to a fresh non-terminal S8 state, then make finalize_timeout's
# rc-branch unreachable by having claude exit non-124 BUT leaving status stuck.
# We emulate "rc-path didn't finalize" by making claude write nothing and exit
# with a signal-like code that is NOT 124, while pre-marking current_state=S8.
# The trap must catch the non-terminal status and finalize it.
state_init "$RD" "$RID" "$REPO" "99"
state_set "$RD" "branch" "auto-run/issue-99-x"
state_set "$RD" "worktree_path" "$WORKTREE"
state_set "$RD" "cycle_review_decision" "PROCEED"
echo "CYCLE_REVIEW_DECISION: PROCEED" > "$RD/01-cycle-review.out"

# claude mock that kills the orchestrator's own process group to skip the
# rc-handler entirely, simulating a hard SIGKILL mid-S8. The EXIT trap still
# runs in bash for SIGTERM, exercising the safety net.
cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
# Signal the orchestrator (our parent chain) with TERM so the rc-handler after
# the subshell is skipped; bash runs the EXIT trap on TERM.
kill -TERM $PPID 2>/dev/null
sleep 5
SH
chmod +x "$BIN/claude"

set +e
OUT_B=$(run_orch env RUN_ISSUES_CLAUDE_TIMEOUT=30 \
  "$ORCH" --resume "$RD" --decision PROCEED 2>&1)
RC_B=$?
set -e
echo "--- trap-path output (rc=$RC_B) ---"
echo "$OUT_B" | tail -5

ST_B=$(jq -r '.status' "$RD/run.json")
[ "$ST_B" = "timed_out" ] || { echo "FAIL trap-path: status='$ST_B' (want timed_out, trap safety net)"; FAIL=1; }
TP_B=$(jq -r '.timeout_phase' "$RD/run.json")
[ "$TP_B" = "S8_Implementer" ] || { echo "FAIL trap-path: timeout_phase='$TP_B'"; FAIL=1; }
{ [ "$FAIL" = "0" ] || [ "$ST_B" = "timed_out" ]; } && echo "PASS trap-path: status timed_out via cleanup trap"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "timeout-finalize: all passed" || echo "timeout-finalize: FAILURES"
[ "$FAIL" -eq 0 ]
