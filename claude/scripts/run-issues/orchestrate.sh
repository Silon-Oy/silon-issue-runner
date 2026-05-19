#!/usr/bin/env bash
# orchestrate.sh — /run-issues orchestrator with resume support.
#
# Usage:
#   orchestrate.sh <repo-root> <issue-number-or-"poll">
#   orchestrate.sh --resume <run-dir> --decision PROCEED|CANCEL
#
# The state machine runs in two phases:
#   Phase A (S1..S6)  pick → claim → worktree → db-clone → cycle-review
#   Review gate (S7)  auto-mode: in-process; interactive: exit 10
#   Phase B (S8..S12) implementer → evolution → push → PR
#
# Exit code 10 means "awaiting human review": the run dir and lock are kept
# alive, and the caller (slash command or poller) is expected to inspect the
# cycle-review output, ask the human, and invoke this script again with
# --resume <run-dir> --decision PROCEED|CANCEL.
#
# Env:
#   RUN_ISSUES_AUTO         "1" = no interactive prompts (default 0)
#   RUN_ISSUES_REVIEW_GATE  "auto" or "interactive" (default: interactive
#                           unless RUN_ISSUES_AUTO=1)
#   RUN_ISSUES_LABELS_CSV   labels filter for "poll" mode (default empty)
#
# Exit codes:
#   0   success — PR opened, or resume cancelled cleanly
#   1   fatal — invalid usage / missing run.json on resume
#   2   no candidate issue (poll mode, nothing to do)
#   3   lock/claim race lost
#   4   cycle review blocked the run (auto mode only)
#   5   implementer or evolution failed
#   6   PR open failed
#  10   awaiting human review — invoke --resume to continue

set -euo pipefail

# ---------- argument parsing ----------
MODE="start"
RESUME_RUN_DIR=""
RESUME_DECISION=""
REPO_ROOT=""
ISSUE_ARG=""

usage() {
  cat >&2 <<'USAGE'
usage:
  orchestrate.sh <repo-root> <issue-number-or-"poll">
  orchestrate.sh --resume <run-dir> --decision PROCEED|CANCEL
USAGE
  exit 1
}

if [ "${1:-}" = "--resume" ]; then
  MODE="resume"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision)
        RESUME_DECISION="${2:-}"
        shift 2 || true
        ;;
      --decision=*)
        RESUME_DECISION="${1#*=}"
        shift
        ;;
      *)
        if [ -z "$RESUME_RUN_DIR" ]; then
          RESUME_RUN_DIR="$1"
          shift
        else
          usage
        fi
        ;;
    esac
  done
  [ -n "$RESUME_RUN_DIR" ] && [ -n "$RESUME_DECISION" ] || usage
  case "$RESUME_DECISION" in
    PROCEED|CANCEL) ;;
    *) echo "orchestrate: --decision must be PROCEED or CANCEL (got '$RESUME_DECISION')" >&2; exit 1 ;;
  esac
  [ -d "$RESUME_RUN_DIR" ] || { echo "orchestrate: run-dir not found: $RESUME_RUN_DIR" >&2; exit 1; }
else
  if [ "$#" -ne 2 ]; then usage; fi
  REPO_ROOT="$1"
  ISSUE_ARG="$2"
  [ -d "$REPO_ROOT/.git" ] || { echo "orchestrate: not a git repo: $REPO_ROOT" >&2; exit 1; }
fi

RUN_ISSUES_AUTO="${RUN_ISSUES_AUTO:-0}"
if [ -z "${RUN_ISSUES_REVIEW_GATE:-}" ]; then
  if [ "$RUN_ISSUES_AUTO" = "1" ]; then
    RUN_ISSUES_REVIEW_GATE="auto"
  else
    RUN_ISSUES_REVIEW_GATE="interactive"
  fi
fi
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

export POST_COMMIT_SYNC=1
export RUN_ISSUES_AUTO

# ---------- helpers ----------
slugify_title() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c '[:alnum:]' '_' \
    | sed 's/_\{2,\}/_/g; s/^_//; s/_$//' \
    | cut -c1-32
}

log() {
  printf '[orchestrate %s] %s\n' "$(date -u +%FT%TZ)" "$*" >&2
}

# ---------- globals (populated as we progress; also restored on resume) ----------
ISSUE_NUM=""
ISSUE_TITLE=""
ISSUE_BODY=""
ISSUE_COMMENTS=""
RUN_ID=""
RUN_DIR=""
BRANCH=""
WORKTREE_PATH=""
CR_DECISION=""
DB_CLONE_VALUE=""
LOCK_HELD=0
CLAIMED=0

cleanup_on_exit() {
  local rc=$?
  # Awaiting-review exit (10) keeps the lock alive so --resume still owns
  # the issue. Any other exit releases it. The lock is a per-machine
  # advisory only; the GitHub assignee remains in place as the durable claim.
  if [ "$LOCK_HELD" = "1" ] && [ -n "$ISSUE_NUM" ] && [ "$rc" != "10" ]; then
    unlock_issue "$ISSUE_NUM" || true
  fi
  exit "$rc"
}
trap cleanup_on_exit EXIT

# ===========================================================================
# Phase A: pick → cycle-review
# ===========================================================================
phase_a() {
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

  # Snapshot issue payload — used now for branch name and later (incl. resume).
  RUN_ID="$(date +%Y%m%d-%H%M%S)-issue-${ISSUE_NUM}"
  RUN_DIR="$REPO_ROOT/.claude/run-issues/$RUN_ID"
  mkdir -p "$RUN_DIR"
  local issue_json="$RUN_DIR/issue.json"
  fetch_issue_json "$REPO_ROOT" "$ISSUE_NUM" > "$issue_json"
  ISSUE_TITLE=$(jq -r '.title // empty' "$issue_json")
  ISSUE_BODY=$(jq -r '.body // ""' "$issue_json")
  ISSUE_COMMENTS=$(jq -r '[.comments[]? | "--- @\(.author.login // "?") @ \(.createdAt // "?")\n\(.body)"] | join("\n\n")' "$issue_json")
  local slug
  slug=$(slugify_title "$ISSUE_TITLE")
  [ -n "$slug" ] || slug="issue_${ISSUE_NUM}"

  state_init "$RUN_DIR" "$RUN_ID" "$REPO_ROOT" "$ISSUE_NUM"
  state_event "$RUN_DIR" "issue_picked" "issue_number=$ISSUE_NUM" "title=$ISSUE_TITLE"

  BRANCH="auto-run/issue-${ISSUE_NUM}-${slug}"
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
  local db_clone_log="$RUN_DIR/db-clone.log"
  set +e
  "$SCRIPT_DIR/db-clone/db-clone.sh" "$REPO_ROOT" "$RUN_ID" > "$db_clone_log" 2>&1
  local db_rc=$?
  set -e
  case "$db_rc" in
    0)
      DB_CLONE_VALUE=$(grep -E '^RUN_ISSUES_DB_CLONE=' "$db_clone_log" | tail -1 | cut -d= -f2-)
      state_set "$RUN_DIR" "db_clone" "$DB_CLONE_VALUE"
      state_event "$RUN_DIR" "db_clone_ok" "value=$DB_CLONE_VALUE"
      ;;
    1)
      state_event "$RUN_DIR" "db_clone_skipped"
      ;;
    *)
      log "db-clone failed (rc=$db_rc) — see $db_clone_log"
      state_finalize "$RUN_DIR" "blocked" "db_clone_rc_$db_rc"
      exit 5
      ;;
  esac

  # ---------- S6: cycle review ----------
  log "S6_CycleReview"
  local repo_claude_md=""
  [ -f "$REPO_ROOT/CLAUDE.md" ] && repo_claude_md=$(cat "$REPO_ROOT/CLAUDE.md")

  local cr_prompt="$RUN_DIR/01-cycle-review.prompt"
  render_prompt \
    "$SCRIPT_DIR/prompts/01-cycle-review.md" \
    "$cr_prompt" \
    "ISSUE_BODY=$ISSUE_BODY" \
    "ISSUE_COMMENTS=$ISSUE_COMMENTS" \
    "REPO_ROOT=$REPO_ROOT" \
    "REPO_CLAUDE_MD=$repo_claude_md"

  (
    cd "$WORKTREE_PATH"
    call_claude "$RUN_DIR" "01-cycle-review" "$cr_prompt"
  ) || true

  local cr_out="$RUN_DIR/01-cycle-review.out"
  CR_DECISION=$(grep -E '^CYCLE_REVIEW_DECISION:' "$cr_out" | tail -1 | awk '{print $2}')
  state_set "$RUN_DIR" "cycle_review_decision" "${CR_DECISION:-UNKNOWN}"
  state_event "$RUN_DIR" "cycle_review_done" "decision=${CR_DECISION:-UNKNOWN}"
}

# ===========================================================================
# Review gate (S7) — between phase A and phase B
# ===========================================================================
review_gate() {
  log "S7_ReviewGate decision=$CR_DECISION mode=$RUN_ISSUES_REVIEW_GATE"
  case "$RUN_ISSUES_REVIEW_GATE" in
    auto)
      if [ "$CR_DECISION" = "PROCEED" ]; then
        state_event "$RUN_DIR" "review_gate_auto_proceed"
        return 0
      fi
      log "auto review-gate did not PROCEED (decision=$CR_DECISION)"
      local reason="cycle_review_${CR_DECISION:-empty}"
      state_finalize "$RUN_DIR" "blocked" "$reason"
      comment_issue "$REPO_ROOT" "$ISSUE_NUM" \
        "/run-issues pysähtyi cycle-review-vaiheessa: \`$reason\`. Ks. run-kansio: \`$RUN_DIR\`" \
        || true
      exit 4
      ;;
    interactive)
      # Pause for human. Keep lock, keep claim, keep worktree.
      # The caller (slash command or poller) reads the run-dir, presents
      # the cycle-review summary to the user, and re-invokes with --resume.
      state_event "$RUN_DIR" "awaiting_review" "decision=${CR_DECISION:-UNKNOWN}" "run_dir=$RUN_DIR"
      log "awaiting human review — re-run with: orchestrate.sh --resume $RUN_DIR --decision PROCEED|CANCEL"
      exit 10
      ;;
    *)
      log "unknown RUN_ISSUES_REVIEW_GATE='$RUN_ISSUES_REVIEW_GATE' — treating as auto"
      if [ "$CR_DECISION" = "PROCEED" ]; then return 0; fi
      state_finalize "$RUN_DIR" "blocked" "cycle_review_unknown_gate"
      exit 4
      ;;
  esac
}

# ===========================================================================
# Resume: restore state from a prior run-dir
# ===========================================================================
resume_load_state() {
  RUN_DIR="$RESUME_RUN_DIR"
  RUN_ID="$(basename "$RUN_DIR")"
  local rj="$RUN_DIR/run.json"
  [ -f "$rj" ] || { echo "orchestrate: no run.json in $RUN_DIR" >&2; exit 1; }

  REPO_ROOT=$(jq -r '.repo // ""' "$rj")
  ISSUE_NUM=$(jq -r '.issue_number // empty | tostring' "$rj")
  BRANCH=$(jq -r '.branch // ""' "$rj")
  WORKTREE_PATH=$(jq -r '.worktree_path // ""' "$rj")
  CR_DECISION=$(jq -r '.cycle_review_decision // ""' "$rj")
  DB_CLONE_VALUE=$(jq -r '.db_clone // ""' "$rj")

  if [ -z "$REPO_ROOT" ] || [ -z "$ISSUE_NUM" ] || [ -z "$WORKTREE_PATH" ]; then
    echo "orchestrate: incomplete run.json (missing repo/issue_number/worktree_path)" >&2
    exit 1
  fi

  local issue_json="$RUN_DIR/issue.json"
  if [ ! -f "$issue_json" ]; then
    log "issue.json missing in $RUN_DIR — re-fetching from GitHub"
    fetch_issue_json "$REPO_ROOT" "$ISSUE_NUM" > "$issue_json"
  fi
  ISSUE_TITLE=$(jq -r '.title // ""' "$issue_json")
  ISSUE_BODY=$(jq -r '.body // ""' "$issue_json")
  ISSUE_COMMENTS=$(jq -r '[.comments[]? | "--- @\(.author.login // "?") @ \(.createdAt // "?")\n\(.body)"] | join("\n\n")' "$issue_json")

  # The original run held the lock and the GitHub assignee; the trap kept
  # them alive on exit 10. Mark our globals so cleanup behaves correctly.
  LOCK_HELD=1
  CLAIMED=1

  state_event "$RUN_DIR" "resumed" "decision=$RESUME_DECISION"
}

resume_cancel() {
  log "Resume cancelled at review gate"
  state_finalize "$RUN_DIR" "cancelled" "cancelled_at_gate"
  comment_issue "$REPO_ROOT" "$ISSUE_NUM" \
    "/run-issues peruutettu review-gate-vaiheessa. Worktree ja branch jätettiin paikoilleen: \`$WORKTREE_PATH\` ja \`$BRANCH\`. Voit jatkaa manuaalisesti tai poistaa nuo." \
    || true
  unclaim_issue "$REPO_ROOT" "$ISSUE_NUM" || true
  exit 0
}

# ===========================================================================
# Phase B: implementer → evolution → PR
# ===========================================================================
phase_b() {
  # ---------- S8: implementer ----------
  log "S8_Implementer"
  local cr_out="$RUN_DIR/01-cycle-review.out"
  local cr_full=""
  [ -f "$cr_out" ] && cr_full=$(cat "$cr_out")

  local imp_prompt="$RUN_DIR/02-implementer.prompt"
  render_prompt \
    "$SCRIPT_DIR/prompts/02-implementer.md" \
    "$imp_prompt" \
    "REPO_ROOT=$REPO_ROOT" \
    "WORKTREE_PATH=$WORKTREE_PATH" \
    "BRANCH=$BRANCH" \
    "ISSUE_NUMBER=$ISSUE_NUM" \
    "ISSUE_TITLE=$ISSUE_TITLE" \
    "ISSUE_BODY=$ISSUE_BODY" \
    "RUN_ISSUES_DB_CLONE=$DB_CLONE_VALUE" \
    "CYCLE_REVIEW_OUTPUT=$cr_full"

  (
    cd "$WORKTREE_PATH"
    call_claude "$RUN_DIR" "02-implementer" "$imp_prompt"
  ) || true

  local imp_out="$RUN_DIR/02-implementer.out"
  local imp_result
  imp_result=$(grep -E '^IMPLEMENTER_RESULT:' "$imp_out" | tail -1 | sed 's/^IMPLEMENTER_RESULT: *//')
  state_event "$RUN_DIR" "implementer_done" "result=${imp_result:-UNKNOWN}"

  case "$imp_result" in
    SUCCESS*) : ;;
    PARTIAL*) log "implementer returned PARTIAL — continuing to evolution with what we have" ;;
    BLOCKED*|"")
      log "implementer blocked or no result line"
      state_finalize "$RUN_DIR" "blocked" "implementer_${imp_result:-no_result}"
      exit 5
      ;;
  esac

  # ---------- S9: evolution ----------
  log "S9_Evolution"
  local imp_tail
  imp_tail=$(tail -200 "$imp_out")
  local evo_prompt="$RUN_DIR/03-evolution.prompt"
  render_prompt \
    "$SCRIPT_DIR/prompts/03-evolution.md" \
    "$evo_prompt" \
    "REPO_ROOT=$REPO_ROOT" \
    "WORKTREE_PATH=$WORKTREE_PATH" \
    "BRANCH=$BRANCH" \
    "ISSUE_NUMBER=$ISSUE_NUM" \
    "ISSUE_TITLE=$ISSUE_TITLE" \
    "IMPLEMENTER_OUTPUT_TAIL=$imp_tail"

  (
    cd "$WORKTREE_PATH"
    call_claude "$RUN_DIR" "03-evolution" "$evo_prompt"
  ) || true

  local evo_out="$RUN_DIR/03-evolution.out"
  local evo_result
  evo_result=$(grep -E '^EVOLUTION_RESULT:' "$evo_out" | tail -1 | sed 's/^EVOLUTION_RESULT: *//')
  state_event "$RUN_DIR" "evolution_done" "result=${evo_result:-UNKNOWN}"

  # ---------- S10: PR ----------
  log "S10_PR"
  local pr_body="$RUN_DIR/pr-body.md"
  {
    echo "Auto-run for issue #$ISSUE_NUM — $ISSUE_TITLE"
    echo
    echo "## Cycle review"
    echo
    echo '```'
    echo "$cr_full"
    echo '```'
    echo
    echo "## Evolution result"
    echo
    echo '```'
    echo "${evo_result:-UNKNOWN}"
    echo '```'
    echo
    echo "Run dir: \`$RUN_DIR\`"
    echo
    echo "Closes #$ISSUE_NUM"
  } > "$pr_body"

  local pr_draft_flag=""
  case "${imp_result}${evo_result}" in
    *PARTIAL*|*NEEDS_FOLLOWUP*) pr_draft_flag="--draft" ;;
  esac

  set +e
  (
    cd "$WORKTREE_PATH"
    git push --set-upstream origin "$BRANCH"
  ) >> "$RUN_DIR/git-push.log" 2>&1
  local push_rc=$?
  set -e
  if [ "$push_rc" -ne 0 ]; then
    log "git push failed (rc=$push_rc)"
    state_finalize "$RUN_DIR" "blocked" "git_push_failed"
    exit 6
  fi

  local pr_url=""
  set +e
  pr_url=$(
    cd "$REPO_ROOT"
    gh pr create \
      --head "$BRANCH" \
      --title "Auto: $ISSUE_TITLE (#$ISSUE_NUM)" \
      --body-file "$pr_body" \
      $pr_draft_flag \
      2>&1 | tee "$RUN_DIR/gh-pr-create.log" | grep -E '^https://github.com/' | tail -1
  )
  local pr_rc=$?
  set -e
  if [ -z "$pr_url" ] || [ "$pr_rc" -ne 0 ]; then
    log "gh pr create failed"
    state_finalize "$RUN_DIR" "blocked" "pr_create_failed"
    exit 6
  fi

  state_set "$RUN_DIR" "pr_url" "$pr_url"
  state_event "$RUN_DIR" "pr_opened" "url=$pr_url"

  # ---------- S11/S12: finalize ----------
  # Worktree is kept intentionally as a forensic artefact. The lock is
  # released by cleanup_on_exit.
  log "S12_Finalize pr_url=$pr_url"
  state_finalize "$RUN_DIR" "completed"
}

# ===========================================================================
# Main flow
# ===========================================================================
case "$MODE" in
  start)
    phase_a
    review_gate     # auto: returns; interactive: exits 10
    phase_b
    ;;
  resume)
    resume_load_state
    case "$RESUME_DECISION" in
      PROCEED) phase_b ;;
      CANCEL)  resume_cancel ;;
    esac
    ;;
esac

exit 0
