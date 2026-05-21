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
#   7   implementer (S8) timed out — run finalized as timed_out, eligible for
#       auto-restart via --restart (or budget-exhausted handed to a human)
#  10   awaiting human review — invoke --resume to continue
#
# --restart <run-dir> resumes a timed_out run with a ramped, capped timeout
# (base*(1+retry_count), cap RUN_ISSUES_CLAUDE_TIMEOUT_MAX). It skips pick/claim
# and re-enters Phase B. Budget is RUN_ISSUES_MAX_RETRIES (default 1).

set -euo pipefail

# ---------- argument parsing ----------
MODE="start"
RESUME_RUN_DIR=""
RESUME_DECISION=""
RESTART_RUN_DIR=""
REPO_ROOT=""
ISSUE_ARG=""

usage() {
  cat >&2 <<'USAGE'
usage:
  orchestrate.sh <repo-root> <issue-number-or-"poll">
  orchestrate.sh --resume <run-dir> --decision PROCEED|CANCEL
  orchestrate.sh --restart <run-dir>
USAGE
  exit 1
}

if [ "${1:-}" = "--restart" ]; then
  MODE="restart"
  shift
  RESTART_RUN_DIR="${1:-}"
  [ -n "$RESTART_RUN_DIR" ] || usage
  [ -d "$RESTART_RUN_DIR" ] || { echo "orchestrate: run-dir not found: $RESTART_RUN_DIR" >&2; exit 1; }
elif [ "${1:-}" = "--resume" ]; then
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

# ---------- claude timeout configuration ----------
# Base wall-clock budget per claude invocation. Resolution order:
#   1. RUN_ISSUES_CLAUDE_TIMEOUT already set in the environment (explicit override)
#   2. claude_timeout_seconds in the target repo's .claude/run-issues.json (opt-in,
#      same convention as .claude/db-clone.json)
#   3. claude-call.sh's own default (1800s)
# On restart we ramp the budget up per retry; see restart_load_state.
RUN_ISSUES_CLAUDE_TIMEOUT_MAX="${RUN_ISSUES_CLAUDE_TIMEOUT_MAX:-3600}"

# load_repo_timeout <repo-root> — sets and exports RUN_ISSUES_CLAUDE_TIMEOUT from
# the repo config if present and not already overridden via the environment.
load_repo_timeout() {
  local repo="$1"
  # An explicit environment override always wins.
  if [ -n "${RUN_ISSUES_CLAUDE_TIMEOUT:-}" ]; then
    export RUN_ISSUES_CLAUDE_TIMEOUT
    return 0
  fi
  local cfg="$repo/.claude/run-issues.json"
  if [ -f "$cfg" ] && jq -e . "$cfg" >/dev/null 2>&1; then
    local t
    t=$(jq -r '.claude_timeout_seconds // empty' "$cfg" 2>/dev/null || true)
    case "$t" in
      ''|*[!0-9]*) : ;;  # absent or non-numeric: fall through to default
      *)
        RUN_ISSUES_CLAUDE_TIMEOUT="$t"
        export RUN_ISSUES_CLAUDE_TIMEOUT
        log "using repo claude_timeout_seconds=$t from $cfg"
        ;;
    esac
  fi
}

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
CURRENT_STATE=""
RESTART_CONTEXT=""

# Retry budget: how many auto-restarts a single timed-out run may receive.
RUN_ISSUES_MAX_RETRIES="${RUN_ISSUES_MAX_RETRIES:-1}"

# enter_state <state> — record the state both in a process global (cheap,
# used by the cleanup trap) and in run.json's current_state field (durable,
# survives a SIGKILL of the claude child). Before this, current_state was a
# dead field written only once as S0_Idle.
enter_state() {
  CURRENT_STATE="$1"
  [ -n "$RUN_DIR" ] && state_set "$RUN_DIR" current_state "$1" || true
}

# _status_is_terminal <run-dir> — returns 0 if run.json has a terminal
# status (anything other than initialized). Used to avoid double-finalizing
# from the trap when the rc-path already finalized.
# shellcheck disable=SC2329  # invoked indirectly from finalize_timeout / trap
_status_is_terminal() {
  local rd="$1"
  [ -f "$rd/run.json" ] || return 1
  local st
  st=$(jq -r '.status // "initialized"' "$rd/run.json" 2>/dev/null || echo "initialized")
  [ "$st" != "initialized" ]
}

# finalize_timeout <phase> [<reason>] — shared timeout finalization. Marks the
# run timed_out, records which phase was running, and emits an event. Idempotent
# guard lives in the callers (rc-path checks imp_rc=124; trap checks status).
#
# When the timed-out run has already spent its retry budget, hand it to a human
# here. This is the load-bearing path for the poller flow: a restarted run that
# times out AGAIN finalizes via this function, but the poller's scan_timed_out
# gate (retry_count < MAX) means restart_load_state's own budget branch never
# runs in autoflow. Without this check the issue would wedge silently with no
# needs-human signal. _hand_to_human is best-effort (all gh calls `|| true`), so
# a GitHub hiccup never breaks finalization — run.json is already terminal.
finalize_timeout() {
  local phase="$1"
  local reason="${2:-implementer_timeout}"
  log "implementer timed out in $phase — finalizing run as timed_out"
  state_set "$RUN_DIR" timeout_phase "$phase"
  state_finalize "$RUN_DIR" "timed_out" "$reason"
  state_event "$RUN_DIR" "implementer_timed_out" "phase=$phase" "reason=$reason"

  # Re-read retry_count from run.json (not a global): finalize_timeout is reached
  # from both the rc-path and the EXIT trap, where globals may be stale.
  local rc_now
  rc_now=$(jq -r '.retry_count // 0' "$RUN_DIR/run.json" 2>/dev/null || echo 0)
  if [ -n "$ISSUE_NUM" ] && [ "$rc_now" -ge "$RUN_ISSUES_MAX_RETRIES" ]; then
    log "timed_out run has exhausted its retry budget (retry_count=$rc_now >= max=$RUN_ISSUES_MAX_RETRIES) — handing to human"
    state_finalize "$RUN_DIR" "timed_out" "timeout_budget_exhausted"
    _hand_to_human "auto-restart-budgetti loppui ($rc_now/$RUN_ISSUES_MAX_RETRIES). Implementer-vaihe aikakatkesi toistuvasti." || true
    state_event "$RUN_DIR" "handed_to_human" "reason=timeout_budget_exhausted" "retry_count=$rc_now"
  fi
}

# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap
cleanup_on_exit() {
  local rc=$?
  # Safety net: if S8 killed the claude child hard enough that the rc-path
  # never ran (e.g. the whole subshell was signalled), the run could be left
  # non-terminal. Detect that here and finalize as timed_out so the issue is
  # eligible for auto-restart instead of wedging forever. We trust run.json
  # (re-read via jq) over the CURRENT_STATE global because the global may be
  # stale if a deeper failure occurred.
  if [ "$rc" != "10" ] && [ "$CURRENT_STATE" = "S8_Implementer" ] \
     && [ -n "$RUN_DIR" ] && ! _status_is_terminal "$RUN_DIR"; then
    finalize_timeout "S8_Implementer" "implementer_killed_in_S8" || true
  fi
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
  load_repo_timeout "$REPO_ROOT"
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
  enter_state "S1_PickIssue"
  state_event "$RUN_DIR" "issue_picked" "issue_number=$ISSUE_NUM" "title=$ISSUE_TITLE"

  BRANCH="auto-run/issue-${ISSUE_NUM}-${slug}"
  state_set "$RUN_DIR" "branch" "$BRANCH"

  # ---------- S2: lock ----------
  enter_state "S2_Lock"
  log "S2_Lock issue=$ISSUE_NUM"
  if ! lock_issue "$ISSUE_NUM"; then
    log "lock held by another runner; exiting"
    state_finalize "$RUN_DIR" "lost_race" "lock_held"
    exit 3
  fi
  LOCK_HELD=1
  state_event "$RUN_DIR" "lock_acquired"

  # ---------- S3: claim ----------
  enter_state "S3_Claim"
  log "S3_Claim issue=$ISSUE_NUM"
  claim_issue "$REPO_ROOT" "$ISSUE_NUM"
  state_event "$RUN_DIR" "claim_attempted"
  sleep 5
  if ! verify_claim "$REPO_ROOT" "$ISSUE_NUM"; then
    log "claim race lost after verification — unclaiming and exiting"
    unclaim_issue "$REPO_ROOT" "$ISSUE_NUM"
    state_finalize "$RUN_DIR" "lost_race" "claim_lost"
    exit 3
  fi
  CLAIMED=1
  state_event "$RUN_DIR" "claim_verified"

  # ---------- S4: worktree ----------
  enter_state "S4_Worktree"
  log "S4_Worktree run_id=$RUN_ID branch=$BRANCH"
  WORKTREE_PATH=$(create_worktree "$REPO_ROOT" "$RUN_ID" "$BRANCH")
  state_set "$RUN_DIR" "worktree_path" "$WORKTREE_PATH"
  state_event "$RUN_DIR" "worktree_created" "path=$WORKTREE_PATH"

  # ---------- S5: db clone (opt-in) ----------
  enter_state "S5_DBClone"
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
  enter_state "S6_CycleReview"
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
  enter_state "S7_ReviewGate"
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

# ===========================================================================
# Restart: resume a timed-out run with a higher budget (no re-pick/re-claim)
# ===========================================================================
# restart_load_state — validates a timed_out run, takes the lock, increments the
# retry counter, validates the worktree, ramps the timeout, and prepares globals
# so phase_b can run again. Exhausted budget or a corrupt worktree finalize and
# exit cleanly (the issue is handed to a human via the needs-human label).
restart_load_state() {
  RUN_DIR="$RESTART_RUN_DIR"
  RUN_ID="$(basename "$RUN_DIR")"
  local rj="$RUN_DIR/run.json"
  [ -f "$rj" ] || { echo "orchestrate: no run.json in $RUN_DIR" >&2; exit 1; }

  REPO_ROOT=$(jq -r '.repo // ""' "$rj")
  ISSUE_NUM=$(jq -r '.issue_number // empty | tostring' "$rj")
  BRANCH=$(jq -r '.branch // ""' "$rj")
  WORKTREE_PATH=$(jq -r '.worktree_path // ""' "$rj")
  CR_DECISION=$(jq -r '.cycle_review_decision // ""' "$rj")
  DB_CLONE_VALUE=$(jq -r '.db_clone // ""' "$rj")
  local prior_status retry_count
  prior_status=$(jq -r '.status // ""' "$rj")
  retry_count=$(jq -r '.retry_count // 0' "$rj")

  if [ -z "$REPO_ROOT" ] || [ -z "$ISSUE_NUM" ] || [ -z "$WORKTREE_PATH" ]; then
    echo "orchestrate: incomplete run.json (missing repo/issue_number/worktree_path)" >&2
    exit 1
  fi

  # Only timed_out runs are restartable. Anything else is a usage error.
  if [ "$prior_status" != "timed_out" ]; then
    echo "orchestrate: --restart only applies to timed_out runs (status='$prior_status')" >&2
    exit 1
  fi

  # Take the per-issue lock for the duration of the restart.
  if ! lock_issue "$ISSUE_NUM"; then
    log "restart: lock held by another runner for issue #$ISSUE_NUM — skipping"
    exit 3
  fi
  LOCK_HELD=1
  CLAIMED=1

  # Budget check. Exhausted -> hand to a human, exit 0 (terminal, not an error).
  if [ "$retry_count" -ge "$RUN_ISSUES_MAX_RETRIES" ]; then
    log "restart: retry budget exhausted (retry_count=$retry_count >= max=$RUN_ISSUES_MAX_RETRIES) — handing to human"
    state_finalize "$RUN_DIR" "timed_out" "timeout_budget_exhausted"
    _hand_to_human "auto-restart-budgetti loppui ($retry_count/$RUN_ISSUES_MAX_RETRIES). Implementer-vaihe aikakatkesi toistuvasti."
    exit 0
  fi

  # Worktree validation. Clear a stale index.lock first (best effort), then a
  # plain `git status` proves the worktree is usable. Corruption -> human.
  rm -f "$WORKTREE_PATH/.git/index.lock" 2>/dev/null || true
  if [ -z "$WORKTREE_PATH" ] || [ ! -d "$WORKTREE_PATH" ] \
     || ! git -C "$WORKTREE_PATH" status >/dev/null 2>&1; then
    log "restart: worktree unusable at '$WORKTREE_PATH' — handing to human"
    state_finalize "$RUN_DIR" "blocked" "restart_worktree_corrupt"
    _hand_to_human "Restart epäonnistui: worktree \`$WORKTREE_PATH\` on rikki tai puuttuu. Siivoa ajo ja aja issue uudelleen."
    exit 0
  fi

  # Increment the retry counter BEFORE the claude call so the spend is durable
  # under the lock even if this attempt times out again (idempotency).
  local new_retry
  new_retry=$(state_increment_retry "$RUN_DIR")
  state_event "$RUN_DIR" "restart_attempt" "retry_count=$new_retry"

  # Re-open the run as in-progress; phase_b will re-finalize on its own.
  state_set "$RUN_DIR" "status" "initialized"
  state_set "$RUN_DIR" "finished_at" ""

  # Restore issue payload (needed by phase_b's prompt rendering).
  local issue_json="$RUN_DIR/issue.json"
  if [ ! -f "$issue_json" ]; then
    log "issue.json missing in $RUN_DIR — re-fetching from GitHub"
    fetch_issue_json "$REPO_ROOT" "$ISSUE_NUM" > "$issue_json"
  fi
  ISSUE_TITLE=$(jq -r '.title // ""' "$issue_json")
  ISSUE_BODY=$(jq -r '.body // ""' "$issue_json")
  ISSUE_COMMENTS=$(jq -r '[.comments[]? | "--- @\(.author.login // "?") @ \(.createdAt // "?")\n\(.body)"] | join("\n\n")' "$issue_json")

  # Restart context: the commits already on the feature branch so the
  # implementer continues from verification instead of starting over.
  RESTART_CONTEXT=$(git -C "$WORKTREE_PATH" log --oneline origin/main..HEAD 2>/dev/null || true)
  [ -n "$RESTART_CONTEXT" ] || RESTART_CONTEXT="(ei committeja vielä haaralla — edellinen ajo katkesi ennen ensimmäistä committia)"

  # Ramped, capped timeout: base * (1 + retry_count). load_repo_timeout sets the
  # base (env override > repo config > claude-call default).
  load_repo_timeout "$REPO_ROOT"
  local base="${RUN_ISSUES_CLAUDE_TIMEOUT:-1800}"
  local ramped=$(( base * (1 + new_retry) ))
  if [ "$ramped" -gt "$RUN_ISSUES_CLAUDE_TIMEOUT_MAX" ]; then
    ramped="$RUN_ISSUES_CLAUDE_TIMEOUT_MAX"
  fi
  RUN_ISSUES_CLAUDE_TIMEOUT="$ramped"
  export RUN_ISSUES_CLAUDE_TIMEOUT
  log "restart: retry=$new_retry timeout=${RUN_ISSUES_CLAUDE_TIMEOUT}s (base=$base, cap=$RUN_ISSUES_CLAUDE_TIMEOUT_MAX)"

  state_event "$RUN_DIR" "restarted" "retry_count=$new_retry" "timeout=$RUN_ISSUES_CLAUDE_TIMEOUT"
}

# _hand_to_human <message> — best-effort: ensure a needs-human label exists,
# attach it to the issue, and post an explanatory comment. All failures are
# non-fatal (the run is already finalized in run.json regardless).
_hand_to_human() {
  local msg="$1"
  ( cd "$REPO_ROOT" && gh label create needs-human --color B60205 \
      --description "Vaatii ihmisen — automaattinen ajo ei onnistunut" >/dev/null 2>&1 ) || true
  ( cd "$REPO_ROOT" && gh issue edit "$ISSUE_NUM" --add-label needs-human >/dev/null 2>&1 ) || true
  comment_issue "$REPO_ROOT" "$ISSUE_NUM" \
    "/run-issues: $msg Run-kansio: \`$RUN_DIR\`. Lisätty label \`needs-human\`." || true
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
  enter_state "S8_Implementer"
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
    "CYCLE_REVIEW_OUTPUT=$cr_full" \
    "RESTART_CONTEXT=$RESTART_CONTEXT"

  # rc-preserving: timeout(1) returns 124 when the claude child overruns its
  # budget. The Phase 0 probe (tests/test-timeout-detection.sh) confirms the
  # subshell survives the child's SIGKILL, so imp_rc=124 is the load-bearing
  # signal here; the cleanup trap is a belt-and-suspenders safety net.
  set +e
  (
    cd "$WORKTREE_PATH"
    call_claude "$RUN_DIR" "02-implementer" "$imp_prompt"
  )
  local imp_rc=$?
  set -e

  if [ "$imp_rc" = "124" ]; then
    finalize_timeout "S8_Implementer" "implementer_timeout"
    exit 7
  fi

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
  enter_state "S9_Evolution"
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
  enter_state "S10_PR"
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
  enter_state "S12_Finalize"
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
  restart)
    restart_load_state   # exits 0/3 on budget/lock/worktree problems
    phase_b
    ;;
esac

exit 0
