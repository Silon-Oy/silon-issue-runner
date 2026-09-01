#!/usr/bin/env bash
# test-pr-label-propagation.sh — propagate merge-relevant issue labels to the PR.
#
# Issue #27: orchestrate.sh opens the PR without --label, so an `auto-merge`
# label on the source issue never reaches the PR and pr-watch's merge-policy
# (label + CI + mergeable) never fires. propagate_pr_labels() copies the
# configured labels (RUN_ISSUES_PR_LABELS_CSV, default "auto-merge") from the
# cached issue.json onto the PR, best-effort.
#
# We drive orchestrate.sh in resume mode (PROCEED) so it jumps straight to
# phase_b/S10 (PR creation) without pick/claim. Everything external (claude,
# git, gh) is mocked via PATH shims; the gh mock records its calls so we can
# assert exactly which `gh pr edit --add-label` was issued.
#
# Cases:
#   (a) issue has auto-merge + default config -> PR gets auto-merge, exit 0,
#       status completed, pr_labels_propagated event recorded.
#   (b) issue lacks auto-merge -> no `gh pr edit --add-label` call at all.
#   (c) multiple configured labels, both on the issue -> one combined
#       `--add-label auto-merge,priority` call (configured-but-absent label
#       `release` is filtered out).
#
# Run: bash tests/test-pr-label-propagation.sh   (exit 0 = all pass)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$HERE/../orchestrate.sh"
STATE_LIB="$HERE/../lib/state.sh"

WORK=$(mktemp -d -t pr-label-prop.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
git -C "$WORK" init -q "repo"
WORKTREE="$WORK/worktree"
mkdir -p "$WORKTREE"

BIN="$WORK/bin"
mkdir -p "$BIN"
GH_LOG="$WORK/gh-calls.log"

# gh mock: record every call; `gh pr create` prints a PR URL (the orchestrator
# greps stdout for ^https://github.com/). Everything else succeeds quietly.
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"
if [ "\$1" = "pr" ] && [ "\$2" = "create" ]; then
  echo "https://github.com/acme/widgets/pull/42"
fi
exit 0
SH
chmod +x "$BIN/gh"

# git mock: phase_b only uses `git push` here; no-op so push "succeeds".
cat > "$BIN/git" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$BIN/git"

# claude mock: emit both result markers so implementer (02) and evolution (03)
# steps parse SUCCESS regardless of which step is calling.
cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
echo "IMPLEMENTER_RESULT: SUCCESS"
echo "EVOLUTION_RESULT: OK"
SH
chmod +x "$BIN/claude"

# shellcheck source=lib/state.sh
. "$STATE_LIB"

# setup_run <issue-labels-json> — fresh awaiting_review run-dir for a PROCEED resume.
RID="20260521-1600-issue-27"
RD="$REPO/.claude/run-issues/$RID"
setup_run() {
  local labels_json="$1"
  rm -rf "$RD"
  state_init "$RD" "$RID" "$REPO" "27"
  state_set "$RD" "branch" "auto-run/issue-27-x"
  state_set "$RD" "worktree_path" "$WORKTREE"
  state_set "$RD" "cycle_review_decision" "PROCEED"
  printf '{"title":"t","body":"b","comments":[],"labels":%s}\n' "$labels_json" > "$RD/issue.json"
  echo "CYCLE_REVIEW_DECISION: PROCEED" > "$RD/01-cycle-review.out"
  : > "$GH_LOG"
}

run_orch() {
  ( cd "$REPO" && \
    PATH="$BIN:$PATH" \
    RUN_ISSUES_AUTO=1 RUN_ISSUES_REVIEW_GATE=auto \
    RUN_ISSUES_CLAUDE_CMD="$BIN/claude" \
    RUN_ISSUES_LOCK_ROOT="$WORK/locks" \
    "$@" )
}

FAIL=0

# === (a) issue has auto-merge, default config ==============================
setup_run '[{"name":"auto-run"},{"name":"auto-merge"}]'
set +e
OUT_A=$(run_orch "$ORCH" --resume "$RD" --decision PROCEED 2>&1)
RC_A=$?
set -e
echo "--- (a) default config output (rc=$RC_A) ---"; echo "$OUT_A" | tail -3

[ "$RC_A" = "0" ] || { echo "FAIL (a): expected exit 0, got $RC_A"; FAIL=1; }
ST_A=$(jq -r '.status' "$RD/run.json")
[ "$ST_A" = "completed" ] || { echo "FAIL (a): status='$ST_A' (want completed)"; FAIL=1; }
grep -qF 'api --method POST repos/acme/widgets/issues/42/labels' "$GH_LOG" \
  || { echo "FAIL (a): no REST label call against the PR"; cat "$GH_LOG"; FAIL=1; }
grep -qF 'labels[]=auto-merge' "$GH_LOG" \
  || { echo "FAIL (a): auto-merge not in the label payload"; cat "$GH_LOG"; FAIL=1; }
# The scope-fragile path must not come back: `gh pr edit` needs read:project
# and silently no-op'd on 16 production runs.
grep -qE 'pr edit|issue edit' "$GH_LOG" \
  && { echo "FAIL (a): used gh pr/issue edit instead of the REST endpoint"; cat "$GH_LOG"; FAIL=1; }
grep -q '"event":"pr_labels_propagated"' "$RD/state.jsonl" \
  || { echo "FAIL (a): no pr_labels_propagated event"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (a): auto-merge propagated to PR + event recorded"

# === (b) issue lacks auto-merge -> no add-label call =======================
PREV_FAIL=$FAIL
setup_run '[{"name":"auto-run"},{"name":"bug"}]'
set +e
OUT_B=$(run_orch "$ORCH" --resume "$RD" --decision PROCEED 2>&1)
RC_B=$?
set -e
echo "--- (b) no-label output (rc=$RC_B) ---"; echo "$OUT_B" | tail -3

[ "$RC_B" = "0" ] || { echo "FAIL (b): expected exit 0, got $RC_B"; FAIL=1; }
if grep -qE 'labels\[\]=|/labels' "$GH_LOG"; then
  echo "FAIL (b): unexpected label call when issue has no propagatable label"; cat "$GH_LOG"; FAIL=1
fi
[ "$FAIL" = "$PREV_FAIL" ] && echo "PASS (b): no add-label call when issue lacks auto-merge"

# === (c) multiple configured labels, combined into one call ================
PREV_FAIL=$FAIL
setup_run '[{"name":"auto-merge"},{"name":"priority"},{"name":"auto-run"}]'
set +e
OUT_C=$(run_orch env RUN_ISSUES_PR_LABELS_CSV="auto-merge,priority,release" \
  "$ORCH" --resume "$RD" --decision PROCEED 2>&1)
RC_C=$?
set -e
echo "--- (c) multi-label output (rc=$RC_C) ---"; echo "$OUT_C" | tail -3

[ "$RC_C" = "0" ] || { echo "FAIL (c): expected exit 0, got $RC_C"; FAIL=1; }
# Both present labels ride in ONE call; configured-but-absent `release` filtered out.
ADD_CALLS=$(grep -c 'issues/42/labels' "$GH_LOG")
[ "$ADD_CALLS" = "1" ] || { echo "FAIL (c): expected 1 combined label call, got $ADD_CALLS"; cat "$GH_LOG"; FAIL=1; }
grep -qF 'labels[]=auto-merge' "$GH_LOG" && grep -qF 'labels[]=priority' "$GH_LOG" \
  || { echo "FAIL (c): expected both auto-merge and priority in the payload"; cat "$GH_LOG"; FAIL=1; }
if grep -qF 'labels[]=release' "$GH_LOG"; then
  echo "FAIL (c): absent label 'release' was added"; FAIL=1
fi
[ "$FAIL" = "$PREV_FAIL" ] && echo "PASS (c): multiple labels combined into one call, absent label filtered"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "pr-label-propagation: all passed" || echo "pr-label-propagation: FAILURES"
[ "$FAIL" -eq 0 ]
