#!/usr/bin/env bash
# orchestrate.sh — /run-issues orchestrator (12-state machine).
#
# Usage:
#   orchestrate.sh <repo-root> <issue-number-or-"poll">
#
# Env:
#   RUN_ISSUES_AUTO         "1" = no interactive prompts (default 0)
#   RUN_ISSUES_REVIEW_GATE  "auto" (default) parses cycle-review output;
#                           "interactive" reads stdin for PROCEED/etc.
#   RUN_ISSUES_LABELS_CSV   labels filter for "poll" mode (default empty)
#
# Exit codes:
#   0 success — PR opened
#   1 fatal — invalid usage
#   2 no candidate issue (poll mode, nothing to do)
#   3 lock/claim race lost (another runner picked the same issue)
#   4 cycle review blocked the run
#   5 implementer or evolution failed
#   6 PR open failed

set -euo pipefail

# ---------- argument parsing ----------
if [ "$#" -ne 2 ]; then
  echo "usage: orchestrate.sh <repo-root> <issue-number-or-poll>" >&2
  exit 1
fi
REPO_ROOT="$1"
ISSUE_ARG="$2"
[ -d "$REPO_ROOT/.git" ] || { echo "orchestrate: not a git repo: $REPO_ROOT" >&2; exit 1; }

RUN_ISSUES_AUTO="${RUN_ISSUES_AUTO:-0}"
RUN_ISSUES_REVIEW_GATE="${RUN_ISSUES_REVIEW_GATE:-auto}"
LABELS_CSV="${RUN_ISSUES_LABELS_CSV:-}"

# ---------- library loading ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/locking.sh
source "$SCRIPT_DIR/lib/locking.sh"
# shellcheck source=lib/issue.sh
source "$SCRIPT_DIR/lib/issue.sh"
# shellcheck source=lib/worktree.sh
source "$SCRIPT_DIR/lib/worktree.sh"
# shellcheck source=lib/state.sh
source "$SCRIPT_DIR/lib/state.sh"
# shellcheck source=lib/claude-call.sh
source "$SCRIPT_DIR/lib/claude-call.sh"
# shellcheck source=lib/hook-runner.sh
source "$SCRIPT_DIR/lib/hook-runner.sh"

# Make sure committers see POST_COMMIT_SYNC for the whole run, including
# any sub-shells claude spawns.
export POST_COMMIT_SYNC=1
export RUN_ISSUES_AUTO

# ---------- helpers ----------
slugify_title() {
  # snake_case + ascii alnum, max 32 chars
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c '[:alnum:]' '_' \
    | sed 's/_\{2,\}/_/g; s/^_//; s/_$//' \
    | cut -c1-32
}

log() {
  printf '[orchestrate %s] %s\n' "$(date -u +%FT%TZ)" "$*" >&2
}

# Globals used by trap/cleanup; set as we progress.
ISSUE_NUM=""
RUN_ID=""
RUN_DIR=""
WORKTREE_PATH=""
LOCK_HELD=0
CLAIMED=0

cleanup_on_exit() {
  local rc=$?
  if [ "$LOCK_HELD" = "1" ] && [ -n "$ISSUE_NUM" ]; then
    # Release the lock unless we already succeeded; on success the lock
    # still exists but the workflow is done and a stale-detection cycle
    # will reclaim it next time. Releasing keeps things tidy.
    unlock_issue "$ISSUE_NUM" || true
  fi
  exit "$rc"
}
trap cleanup_on_exit EXIT

# ---------- S1: pick issue ----------
log "S1_PickIssue"
if [ "$ISSUE_ARG" = "poll" ]; then
  ISSUE_NUM=$(pick_oldest_unassigned "$REPO_ROOT" "$LABELS_CSV" || true)
  if [ -z "$ISSUE_NUM" ]; then
    log "no candidate issue"
    exit 2
  fi
else
  ISSUE_NUM=$(printf '%s' "$ISSUE_ARG" | sed 's/^#//')
  case "$ISSUE_NUM" in
    ''|*[!0-9]*) echo "orchestrate: invalid issue argument '$ISSUE_ARG'" >&2; exit 1 ;;
  esac
fi

# Fetch issue payload now so we have title for the branch name.
ISSUE_JSON_TMP=$(mktemp)
fetch_issue_json "$REPO_ROOT" "$ISSUE_NUM" > "$ISSUE_JSON_TMP"
ISSUE_TITLE=$(jq -r '.title // empty' "$ISSUE_JSON_TMP")
ISSUE_BODY=$(jq -r '.body // ""' "$ISSUE_JSON_TMP")
ISSUE_COMMENTS=$(jq -r '[.comments[]? | "--- @\(.author.login // "?") @ \(.createdAt // "?")\n\(.body)"] | join("\n\n")' "$ISSUE_JSON_TMP")
SLUG=$(slugify_title "$ISSUE_TITLE")
[ -n "$SLUG" ] || SLUG="issue_${ISSUE_NUM}"

RUN_ID="$(date +%Y%m%d-%H%M%S)-issue-${ISSUE_NUM}"
RUN_DIR="$REPO_ROOT/.claude/run-issues/$RUN_ID"
mkdir -p "$RUN_DIR"
state_init "$RUN_DIR" "$RUN_ID" "$REPO_ROOT" "$ISSUE_NUM"
state_event "$RUN_DIR" "issue_picked" "issue_number=$ISSUE_NUM" "title=$ISSUE_TITLE"

BRANCH="auto-run/issue-${ISSUE_NUM}-${SLUG}"
state_set "$RUN_DIR" "branch" "$BRANCH"

# ---------- S2: lock ----------
log "S2_Lock issue=$ISSUE_NUM"
if ! lock_issue "$ISSUE_NUM"; then
  log "lock held by another runner; exiting"
  state_finalize "$RUN_DIR" "lost_race" "lock_held"
  exit 3
fi
LOCK_HELD=1
state_event "$RUN_DIR" "lock_acquired"

# ---------- S3: claim ----------
log "S3_Claim issue=$ISSUE_NUM"
claim_issue "$REPO_ROOT" "$ISSUE_NUM"
state_event "$RUN_DIR" "claim_attempted"
sleep 5
if ! verify_claim "$REPO_ROOT" "$ISSUE_NUM"; then
  log "claim race lost after verification"
  state_finalize "$RUN_DIR" "lost_race" "claim_lost"
  exit 3
fi
CLAIMED=1
state_event "$RUN_DIR" "claim_verified"

# ---------- S4: worktree ----------
log "S4_Worktree run_id=$RUN_ID branch=$BRANCH"
WORKTREE_PATH=$(create_worktree "$REPO_ROOT" "$RUN_ID" "$BRANCH")
state_set "$RUN_DIR" "worktree_path" "$WORKTREE_PATH"
state_event "$RUN_DIR" "worktree_created" "path=$WORKTREE_PATH"

# ---------- S5: db clone (opt-in) ----------
log "S5_DBClone"
DB_CLONE_VALUE=""
DB_CLONE_LOG="$RUN_DIR/db-clone.log"
set +e
"$SCRIPT_DIR/db-clone/db-clone.sh" "$REPO_ROOT" "$RUN_ID" > "$DB_CLONE_LOG" 2>&1
DB_RC=$?
set -e
case "$DB_RC" in
  0)
    DB_CLONE_VALUE=$(grep -E '^RUN_ISSUES_DB_CLONE=' "$DB_CLONE_LOG" | tail -1 | cut -d= -f2-)
    state_event "$RUN_DIR" "db_clone_ok" "value=$DB_CLONE_VALUE"
    ;;
  1)
    state_event "$RUN_DIR" "db_clone_skipped"
    ;;
  *)
    log "db-clone failed (rc=$DB_RC) — see $DB_CLONE_LOG"
    state_finalize "$RUN_DIR" "blocked" "db_clone_rc_$DB_RC"
    exit 5
    ;;
esac

# ---------- S6: cycle review ----------
log "S6_CycleReview"
REPO_CLAUDE_MD=""
[ -f "$REPO_ROOT/CLAUDE.md" ] && REPO_CLAUDE_MD=$(cat "$REPO_ROOT/CLAUDE.md")

CR_PROMPT="$RUN_DIR/01-cycle-review.prompt"
render_prompt \
  "$SCRIPT_DIR/prompts/01-cycle-review.md" \
  "$CR_PROMPT" \
  "ISSUE_BODY=$ISSUE_BODY" \
  "ISSUE_COMMENTS=$ISSUE_COMMENTS" \
  "REPO_ROOT=$REPO_ROOT" \
  "REPO_CLAUDE_MD=$REPO_CLAUDE_MD"

# Run cycle-review inside the worktree so any reads see the right tree.
(
  cd "$WORKTREE_PATH"
  call_claude "$RUN_DIR" "01-cycle-review" "$CR_PROMPT"
) || true

CR_OUT="$RUN_DIR/01-cycle-review.out"
CR_DECISION=$(grep -E '^CYCLE_REVIEW_DECISION:' "$CR_OUT" | tail -1 | awk '{print $2}')
state_set "$RUN_DIR" "cycle_review_decision" "${CR_DECISION:-UNKNOWN}"
state_event "$RUN_DIR" "cycle_review_done" "decision=${CR_DECISION:-UNKNOWN}"

# ---------- S7: review gate ----------
log "S7_ReviewGate decision=$CR_DECISION"
PROCEED=0
case "$RUN_ISSUES_REVIEW_GATE" in
  auto)
    [ "$CR_DECISION" = "PROCEED" ] && PROCEED=1
    ;;
  interactive)
    echo "Cycle review decision: $CR_DECISION"
    echo "Proceed? [y/N]:"
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]] && PROCEED=1
    ;;
  *)
    log "unknown RUN_ISSUES_REVIEW_GATE='$RUN_ISSUES_REVIEW_GATE' — defaulting to auto"
    [ "$CR_DECISION" = "PROCEED" ] && PROCEED=1
    ;;
esac

if [ "$PROCEED" = "0" ]; then
  log "cycle review did not PROCEED — leaving issue claimed for human review"
  REASON="cycle_review_${CR_DECISION:-empty}"
  state_finalize "$RUN_DIR" "blocked" "$REASON"
  # Comment on the issue so maintainer sees why we stopped.
  comment_issue "$REPO_ROOT" "$ISSUE_NUM" \
    "/run-issues pysähtyi cycle-review-vaiheessa: \`$REASON\`. Ks. run-kansio: \`$RUN_DIR\`" \
    || true
  exit 4
fi

# ---------- S8: implementer ----------
log "S8_Implementer"
IMP_PROMPT="$RUN_DIR/02-implementer.prompt"
CR_FULL=$(cat "$CR_OUT")
render_prompt \
  "$SCRIPT_DIR/prompts/02-implementer.md" \
  "$IMP_PROMPT" \
  "REPO_ROOT=$REPO_ROOT" \
  "WORKTREE_PATH=$WORKTREE_PATH" \
  "BRANCH=$BRANCH" \
  "ISSUE_NUMBER=$ISSUE_NUM" \
  "ISSUE_TITLE=$ISSUE_TITLE" \
  "ISSUE_BODY=$ISSUE_BODY" \
  "RUN_ISSUES_DB_CLONE=$DB_CLONE_VALUE" \
  "CYCLE_REVIEW_OUTPUT=$CR_FULL"

(
  cd "$WORKTREE_PATH"
  call_claude "$RUN_DIR" "02-implementer" "$IMP_PROMPT"
) || true

IMP_OUT="$RUN_DIR/02-implementer.out"
IMP_RESULT=$(grep -E '^IMPLEMENTER_RESULT:' "$IMP_OUT" | tail -1 | sed 's/^IMPLEMENTER_RESULT: *//')
state_event "$RUN_DIR" "implementer_done" "result=${IMP_RESULT:-UNKNOWN}"

case "$IMP_RESULT" in
  SUCCESS*) : ;;
  PARTIAL*) log "implementer returned PARTIAL — continuing to evolution with what we have" ;;
  BLOCKED*|"")
    log "implementer blocked or no result line"
    state_finalize "$RUN_DIR" "blocked" "implementer_${IMP_RESULT:-no_result}"
    exit 5
    ;;
esac

# ---------- S9: evolution ----------
log "S9_Evolution"
IMP_TAIL=$(tail -200 "$IMP_OUT")
EVO_PROMPT="$RUN_DIR/03-evolution.prompt"
render_prompt \
  "$SCRIPT_DIR/prompts/03-evolution.md" \
  "$EVO_PROMPT" \
  "REPO_ROOT=$REPO_ROOT" \
  "WORKTREE_PATH=$WORKTREE_PATH" \
  "BRANCH=$BRANCH" \
  "ISSUE_NUMBER=$ISSUE_NUM" \
  "ISSUE_TITLE=$ISSUE_TITLE" \
  "IMPLEMENTER_OUTPUT_TAIL=$IMP_TAIL"

(
  cd "$WORKTREE_PATH"
  call_claude "$RUN_DIR" "03-evolution" "$EVO_PROMPT"
) || true

EVO_OUT="$RUN_DIR/03-evolution.out"
EVO_RESULT=$(grep -E '^EVOLUTION_RESULT:' "$EVO_OUT" | tail -1 | sed 's/^EVOLUTION_RESULT: *//')
state_event "$RUN_DIR" "evolution_done" "result=${EVO_RESULT:-UNKNOWN}"

# ---------- S10: PR ----------
log "S10_PR"
PR_BODY_FILE="$RUN_DIR/pr-body.md"
{
  echo "Auto-run for issue #$ISSUE_NUM — $ISSUE_TITLE"
  echo
  echo "## Cycle review"
  echo
  echo '```'
  echo "$CR_FULL"
  echo '```'
  echo
  echo "## Evolution result"
  echo
  echo '```'
  echo "${EVO_RESULT:-UNKNOWN}"
  echo '```'
  echo
  echo "Run dir: \`$RUN_DIR\`"
  echo
  echo "Closes #$ISSUE_NUM"
} > "$PR_BODY_FILE"

PR_DRAFT_FLAG=""
case "${IMP_RESULT}${EVO_RESULT}" in
  *PARTIAL*|*NEEDS_FOLLOWUP*) PR_DRAFT_FLAG="--draft" ;;
esac

PR_URL=""
set +e
(
  cd "$WORKTREE_PATH"
  git push --set-upstream origin "$BRANCH"
) >> "$RUN_DIR/git-push.log" 2>&1
PUSH_RC=$?
set -e
if [ "$PUSH_RC" -ne 0 ]; then
  log "git push failed (rc=$PUSH_RC)"
  state_finalize "$RUN_DIR" "blocked" "git_push_failed"
  exit 6
fi

set +e
PR_URL=$(
  cd "$REPO_ROOT"
  gh pr create \
    --head "$BRANCH" \
    --title "Auto: $ISSUE_TITLE (#$ISSUE_NUM)" \
    --body-file "$PR_BODY_FILE" \
    $PR_DRAFT_FLAG \
    2>&1 | tee "$RUN_DIR/gh-pr-create.log" | grep -E '^https://github.com/' | tail -1
)
PR_RC=$?
set -e
if [ -z "$PR_URL" ] || [ "$PR_RC" -ne 0 ]; then
  log "gh pr create failed"
  state_finalize "$RUN_DIR" "blocked" "pr_create_failed"
  exit 6
fi

state_set "$RUN_DIR" "pr_url" "$PR_URL"
state_event "$RUN_DIR" "pr_opened" "url=$PR_URL"

# ---------- S11: cleanup ----------
log "S11_PostRunCleanup"
# Keep the worktree intentionally; it's our forensic artefact. Only the
# lock is released (via trap). PR is in maintainer's court now.

# ---------- S12: finalize ----------
log "S12_Finalize pr_url=$PR_URL"
state_finalize "$RUN_DIR" "completed"
exit 0
