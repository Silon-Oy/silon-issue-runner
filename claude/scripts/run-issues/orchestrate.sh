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
#   Phase B (S7b..S12) env-bootstrap → implementer → evolution → push → PR
#
# S7b (env bootstrap) is a fail-fast dependency-install gate before the
# implementer: a failed install (e.g. missing GITHUB_TOKEN for private deps)
# finalizes the run as blocked/env_bootstrap_failed and hands it to a human
# instead of letting the implementer burn its whole timeout budget silently.
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
#   RUN_ISSUES_PR_LABELS_CSV  labels to propagate from the source issue to the
#                           created PR, if present on the issue (default
#                           "auto-merge"). Enables the autoflow chain
#                           issue -> PR -> pr-watch auto-merge.
#
# Exit codes:
#   0   success — PR opened, or resume cancelled cleanly
#   1   fatal — invalid usage / missing run.json on resume
#   2   no candidate issue (poll mode, nothing to do)
#   3   lock/claim race lost
#   4   cycle review blocked the run (auto mode only)
#   5   blocked before/at the implementer — db-clone failed, env bootstrap
#       (S7b dependency install) failed, or implementer returned BLOCKED
#   6   PR open failed
#   7   implementer (S8) timed out — run finalized as timed_out, eligible for
#       auto-restart via --restart (or budget-exhausted handed to a human)
#  10   awaiting human review — invoke --resume to continue
#  11   awaiting clarification — cycle review returned NEEDS_CLARIFICATION; the
#       run is finalized as awaiting_clarification with the waiting label and an
#       answerable situation comment. Poller's scan_answered restarts it via
#       --continue once maintainer replies.
#
# --restart <run-dir> resumes a timed_out run with a ramped, capped timeout
# (base*(1+retry_count), cap RUN_ISSUES_CLAUDE_TIMEOUT_MAX). It skips pick/claim
# and re-enters Phase B. Budget is RUN_ISSUES_MAX_RETRIES (default 1).
#
# --continue <run-dir> resumes an awaiting_clarification run after maintainer has
# replied: it re-takes the lock, increments clarification_round, re-runs S6
# cycle-review with the reply as context, and falls through the review gate.
# Loop cap is RUN_ISSUES_MAX_CLARIFICATIONS (default 3).

set -euo pipefail

# ---------- argument parsing ----------
MODE="start"
RESUME_RUN_DIR=""
RESUME_DECISION=""
RESTART_RUN_DIR=""
CONTINUE_RUN_DIR=""
REPO_ROOT=""
ISSUE_ARG=""

usage() {
  cat >&2 <<'USAGE'
usage:
  orchestrate.sh <repo-root> <issue-number-or-"poll">
  orchestrate.sh --resume <run-dir> --decision PROCEED|CANCEL
  orchestrate.sh --restart <run-dir>
  orchestrate.sh --continue <run-dir>
USAGE
  exit 1
}

if [ "${1:-}" = "--restart" ]; then
  MODE="restart"
  shift
  RESTART_RUN_DIR="${1:-}"
  [ -n "$RESTART_RUN_DIR" ] || usage
  [ -d "$RESTART_RUN_DIR" ] || { echo "orchestrate: run-dir not found: $RESTART_RUN_DIR" >&2; exit 1; }
elif [ "${1:-}" = "--continue" ]; then
  MODE="continue"
  shift
  CONTINUE_RUN_DIR="${1:-}"
  [ -n "$CONTINUE_RUN_DIR" ] || usage
  [ -d "$CONTINUE_RUN_DIR" ] || { echo "orchestrate: run-dir not found: $CONTINUE_RUN_DIR" >&2; exit 1; }
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
# Merge-relevant labels copied from the source issue onto the created PR.
PR_LABELS_CSV="${RUN_ISSUES_PR_LABELS_CSV:-auto-merge}"

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
# shellcheck source=lib/env-bootstrap.sh
source "$SCRIPT_DIR/lib/env-bootstrap.sh"

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

# ---------- node runtime ----------
# The poller launches this script via a fresh tmux server whose environment
# lacks the interactive shell's nvm PATH (nvm is sourced in zsh/shared.zsh,
# interactive only). The cycle-review and implementer phases shell out to
# `npx`, so a missing node bin makes every claude call die with exit 127 and
# the run stalls at S6. Source nvm (mirroring zsh/shared.zsh) so npx resolves
# regardless of launch context — poller/tmux, manual --restart, or --continue.
# No-op when npx is already on PATH (the common interactive case).
ensure_node_runtime() {
  command -v npx >/dev/null 2>&1 && return 0
  local nvm_dir="${NVM_DIR:-$HOME/.nvm}"
  # nvm.sh is not written for `set -euo pipefail`; relax while sourcing, then
  # restore. pipefail is unaffected by `set +eu`.
  set +eu
  if [ -s "$nvm_dir/nvm.sh" ]; then
    # shellcheck disable=SC1090
    . "$nvm_dir/nvm.sh"
    nvm use default >/dev/null 2>&1 || true
  elif [ -s "/opt/homebrew/opt/nvm/nvm.sh" ]; then
    # shellcheck disable=SC1091
    . "/opt/homebrew/opt/nvm/nvm.sh"
    nvm use default >/dev/null 2>&1 || true
  fi
  set -eu
  command -v npx >/dev/null 2>&1 \
    || log "WARNING: npx not found after sourcing nvm ($nvm_dir); claude calls will fail (exit 127)"
}
ensure_node_runtime

# ---------- machine-local secret provisioning ----------
# The Studio poller runs as a LaunchAgent, which does NOT inherit the
# interactive shell's environment. Secrets that the implementer needs to install
# private dependencies — most importantly GITHUB_TOKEN (read:packages) for
# @scope/* packages on GitHub Packages — are therefore absent, and a silent
# dependency-install failure used to burn the whole implementer timeout budget.
#
# Source a machine-local, gitignored env file (default ~/.config/run-issues/env,
# override via RUN_ISSUES_ENV_FILE) so those secrets reach EVERY path that ends
# in the implementer: normal start, --resume, --restart and --continue. Running
# this once at top level (before the MODE dispatch) covers all four uniformly.
#
# The file lives OUTSIDE any repo and MUST NOT be committed or baked into a
# plist (plists are deployed from the repo → forbidden for secrets). It is shell
# code that gets sourced, so it must be user-owned with chmod 600 — we warn (but
# do not fail) on laxer permissions. When the file is absent the behaviour is
# unchanged from before (one log line, no secrets injected) — no regression.
RUN_ISSUES_ENV_FILE="${RUN_ISSUES_ENV_FILE:-$HOME/.config/run-issues/env}"
source_machine_env() {
  local f="$RUN_ISSUES_ENV_FILE"
  if [ ! -f "$f" ]; then
    log "no machine-local env file at $f — proceeding without it (no secrets injected)"
    return 0
  fi
  local perm=""
  if [ "$(uname -s)" = "Darwin" ]; then
    perm=$(stat -f '%Lp' "$f" 2>/dev/null || echo "")
  else
    perm=$(stat -c '%a' "$f" 2>/dev/null || echo "")
  fi
  case "$perm" in
    600|400|"") : ;;
    *) log "WARNING: env file $f has permissions $perm — recommend 'chmod 600 $f' (it holds secrets)" ;;
  esac
  log "sourcing machine-local env file: $f"
  # The env file is plain shell that exports variables; it is not written for
  # `set -euo pipefail`, so relax while sourcing and restore afterwards (mirrors
  # the nvm source above). Exported vars are inherited by the claude child and
  # the bootstrap install.
  set +eu
  # shellcheck disable=SC1090
  . "$f"
  set -eu
}
source_machine_env

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
# CLARIFICATION_CONTEXT is rendered into the cycle-review prompt. Empty on a
# normal first pass (the prompt section collapses); the --continue path fills
# it with the prior clarification headline + maintainer's reply.
CLARIFICATION_CONTEXT=""
# IS_CONTINUE distinguishes a first NEEDS_CLARIFICATION (exit 11, post marker)
# from a re-evaluation after a reply (still NEEDS_CLARIFICATION -> new marker,
# round+1, exit 11; BLOCKER -> hand to human, no loop).
IS_CONTINUE=0

# Retry budget: how many auto-restarts a single timed-out run may receive.
RUN_ISSUES_MAX_RETRIES="${RUN_ISSUES_MAX_RETRIES:-1}"
# Clarification loop cap: how many answer-and-re-review rounds before the run
# is handed to a human (the clarification loop does not converge).
RUN_ISSUES_MAX_CLARIFICATIONS="${RUN_ISSUES_MAX_CLARIFICATIONS:-3}"

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
    _hand_to_human "auto-restart-budgetti loppui ($rc_now/$RUN_ISSUES_MAX_RETRIES). Implementer-vaihe aikakatkesi toistuvasti." "$RUN_DIR/02-implementer.out" || true
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
  # the issue. Any other exit releases it — including awaiting_clarification
  # (exit 11): that state is parked across machines via the GitHub waiting
  # label + assignee, not the per-machine advisory lock, so --continue re-takes
  # the lock cleanly. The GitHub assignee remains in place as the durable claim.
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
      _post_situation_to_issue "db_clone_failed" \
        "Tietokannan kloonaus epäonnistui (rc=$db_rc) ennen toteutusvaihetta. Tarkista DB-klooni-konfiguraatio ja palvelut." \
        "$db_clone_log" 0
      exit 5
      ;;
  esac

  # ---------- S6: cycle review ----------
  run_cycle_review
}

# run_cycle_review — S6. Renders and runs the cycle-review prompt, parses the
# decision into CR_DECISION, and records it. Reads the optional global
# CLARIFICATION_CONTEXT: phase_a leaves it empty (the prompt section collapses);
# the --continue path fills it with the prior headline + maintainer's reply so the
# review is re-evaluated in light of the answer. This is the single cycle-review
# code path — there is no second one.
run_cycle_review() {
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
    "REPO_CLAUDE_MD=$repo_claude_md" \
    "CLARIFICATION_CONTEXT=$CLARIFICATION_CONTEXT"

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
        # A continue that now PROCEEDs clears the waiting label so the issue is
        # no longer parked; phase_b takes it from here.
        [ "$IS_CONTINUE" = "1" ] && _remove_waiting_label
        return 0
      fi
      log "auto review-gate did not PROCEED (decision=$CR_DECISION)"
      local cr_out="$RUN_DIR/01-cycle-review.out"
      if [ "$CR_DECISION" = "NEEDS_CLARIFICATION" ]; then
        # Answer-and-continue (α2): finalize awaiting_clarification, attach the
        # waiting label, and post an answerable marker. On a re-review that is
        # STILL unclear (IS_CONTINUE=1) the round was already incremented in
        # continue_load_state, so this posts a NEW marker (newer ts, higher
        # round) — maintainer answers again, the poller continues again, up to the cap.
        _finalize_awaiting_clarification
        exit 11
      fi
      # BLOCKER (or empty/unknown): a technical obstacle, not a spec gap. There
      # is no loop here — hand to a human in both first-pass and continue mode.
      local reason="cycle_review_${CR_DECISION:-empty}"
      state_finalize "$RUN_DIR" "blocked" "$reason"
      if [ "$IS_CONTINUE" = "1" ]; then
        _remove_waiting_label
        _hand_to_human \
          "Cycle review esti ajon tarkennuksen jälkeen (\`$reason\`). Tarkista issue ja korjaa este." \
          "$cr_out"
        exit 4
      fi
      _post_situation_to_issue "cycle_review_blocker" \
        "Cycle review esti ajon (\`$reason\`). Tarkista issue ja korjaa este." \
        "$cr_out" 0 prose
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
    _hand_to_human "auto-restart-budgetti loppui ($retry_count/$RUN_ISSUES_MAX_RETRIES). Implementer-vaihe aikakatkesi toistuvasti." "$RUN_DIR/02-implementer.out"
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

# ===========================================================================
# Continue: resume an awaiting_clarification run after maintainer has replied
# ===========================================================================
# continue_load_state — validates an awaiting_clarification run, takes the lock,
# checks the loop cap, validates the worktree, fetches maintainer's reply, increments
# clarification_round, builds CLARIFICATION_CONTEXT, and re-opens the run so the
# main flow can re-run S6 cycle-review. Cap exhaustion or a corrupt worktree
# hand to a human (exit 0). A missing reply (race: poller saw it, it's gone now)
# re-parks the run as awaiting_clarification and exits 0 — not an error.
continue_load_state() {
  RUN_DIR="$CONTINUE_RUN_DIR"
  RUN_ID="$(basename "$RUN_DIR")"
  local rj="$RUN_DIR/run.json"
  [ -f "$rj" ] || { echo "orchestrate: no run.json in $RUN_DIR" >&2; exit 1; }

  REPO_ROOT=$(jq -r '.repo // ""' "$rj")
  ISSUE_NUM=$(jq -r '.issue_number // empty | tostring' "$rj")
  BRANCH=$(jq -r '.branch // ""' "$rj")
  WORKTREE_PATH=$(jq -r '.worktree_path // ""' "$rj")
  DB_CLONE_VALUE=$(jq -r '.db_clone // ""' "$rj")
  local prior_status round
  prior_status=$(jq -r '.status // ""' "$rj")
  round=$(jq -r '.clarification_round // 0' "$rj")

  if [ -z "$REPO_ROOT" ] || [ -z "$ISSUE_NUM" ] || [ -z "$WORKTREE_PATH" ]; then
    echo "orchestrate: incomplete run.json (missing repo/issue_number/worktree_path)" >&2
    exit 1
  fi

  # Only awaiting_clarification runs are continuable. Anything else is a usage error.
  if [ "$prior_status" != "awaiting_clarification" ]; then
    echo "orchestrate: --continue only applies to awaiting_clarification runs (status='$prior_status')" >&2
    exit 1
  fi

  # Take the per-issue lock for the duration of the continue.
  if ! lock_issue "$ISSUE_NUM"; then
    log "continue: lock held by another runner for issue #$ISSUE_NUM — skipping"
    exit 3
  fi
  LOCK_HELD=1
  CLAIMED=1
  IS_CONTINUE=1

  # Loop cap. Exhausted -> hand to a human, exit 0 (terminal, not an error).
  if [ "$round" -ge "$RUN_ISSUES_MAX_CLARIFICATIONS" ]; then
    log "continue: clarification budget exhausted (round=$round >= max=$RUN_ISSUES_MAX_CLARIFICATIONS) — handing to human"
    state_finalize "$RUN_DIR" "blocked" "clarification_loop_exhausted"
    _remove_waiting_label
    _hand_to_human "clarification-silmukka ei suppene $round kierroksen jälkeen. Cycle review tarvitsee yhä tarkennusta — tarkista issue käsin." \
      "$RUN_DIR/01-cycle-review.out"
    exit 0
  fi

  # Worktree validation (restart model): clear a stale index.lock, then prove
  # the worktree is usable. Corruption -> human.
  rm -f "$WORKTREE_PATH/.git/index.lock" 2>/dev/null || true
  if [ -z "$WORKTREE_PATH" ] || [ ! -d "$WORKTREE_PATH" ] \
     || ! git -C "$WORKTREE_PATH" status >/dev/null 2>&1; then
    log "continue: worktree unusable at '$WORKTREE_PATH' — handing to human"
    state_finalize "$RUN_DIR" "blocked" "continue_worktree_corrupt"
    _remove_waiting_label
    _hand_to_human "Continue epäonnistui: worktree \`$WORKTREE_PATH\` on rikki tai puuttuu. Siivoa ajo ja aja issue uudelleen."
    exit 0
  fi

  # Fetch the freshest issue payload and locate maintainer's reply via the marker.
  local issue_json="$RUN_DIR/issue.json"
  fetch_issue_json "$REPO_ROOT" "$ISSUE_NUM" > "$issue_json"

  local marker_line marker_ts answer
  marker_line=$(parse_marker "$issue_json")
  marker_ts=$(printf '%s' "$marker_line" | sed -n 's/.*ts=\([^ ]*\).*/\1/p')
  if [ -z "$marker_ts" ]; then
    log "continue: no awaiting-answer marker found on issue #$ISSUE_NUM — re-parking"
    state_finalize "$RUN_DIR" "awaiting_clarification" "no_marker_on_continue"
    exit 0
  fi
  answer=$(detect_answer "$issue_json" "$marker_ts")
  if [ -z "$answer" ]; then
    # Race: scan_answered saw a reply, but it's gone now (deleted/edited). Park
    # the run again so the next poll re-checks. Not an error.
    log "continue: no reply detected after marker — re-parking as awaiting_clarification"
    state_finalize "$RUN_DIR" "awaiting_clarification" "no_reply_on_continue"
    exit 0
  fi

  # Increment the clarification round BEFORE the claude call so the loop-cap
  # spend is durable under the lock even if this attempt dies (idempotency).
  local new_round
  new_round=$(state_increment_clarification "$RUN_DIR")
  state_event "$RUN_DIR" "continue_attempt" "clarification_round=$new_round"

  # Re-open the run as in-progress; the gate will re-finalize on its own.
  state_set "$RUN_DIR" "status" "initialized"
  state_set "$RUN_DIR" "finished_at" ""

  # Restore issue text fields for the cycle-review prompt.
  ISSUE_TITLE=$(jq -r '.title // ""' "$issue_json")
  ISSUE_BODY=$(jq -r '.body // ""' "$issue_json")
  ISSUE_COMMENTS=$(jq -r '[.comments[]? | "--- @\(.author.login // "?") @ \(.createdAt // "?")\n\(.body)"] | join("\n\n")' "$issue_json")

  # Build the clarification context fed into the re-run cycle-review prompt.
  # render_prompt substitutes in a single pass, so any {{...}} inside maintainer's
  # reply passes through verbatim (no placeholder injection).
  CLARIFICATION_CONTEXT="Aiempi tarkennuspyyntö (kierros $((new_round - 1))): cycle review palautti NEEDS_CLARIFICATION."$'\n\n'
  CLARIFICATION_CONTEXT+="maintainern vastaus:"$'\n'"$answer"

  load_repo_timeout "$REPO_ROOT"
  log "continue: round=$new_round — re-running cycle review with maintainer's reply as context"
}

# Byte budget for an artifact embedded in a situation comment. GitHub caps a
# comment body at ~65536 bytes; we leave headroom for the headline, meta lines,
# code fences, marker, and human instructions.
RUN_ISSUES_SITUATION_ARTIFACT_MAX="${RUN_ISSUES_SITUATION_ARTIFACT_MAX:-60000}"

# _post_situation_to_issue <kind> <headline> [<artifact-file>] [<awaitable>]
# Builds a full Finnish situation report and posts it as an issue comment.
# Best-effort: always returns 0 — the run's terminal status already lives in
# run.json, so a GitHub hiccup must never break finalization. Does NOT mutate
# run.json status; the caller finalizes first.
#
#   <kind>          slug for logging/event (e.g. cycle_review_clarification)
#   <headline>      1–3 Finnish sentences: WHAT happened + WHAT maintainer should do
#   <artifact-file> optional absolute path to attach
#   <awaitable>     1 = answerable -> embed marker + reply instruction; default 0
#   <artifact-mode> "prose" renders the artifact as Markdown (wraps on GitHub —
#                   right for cycle-review/implementer output); "log" (default)
#                   wraps it in a code fence to keep monospace log formatting.
_post_situation_to_issue() {
  local kind="$1"
  local headline="$2"
  local artifact_file="${3:-}"
  local awaitable="${4:-0}"
  local artifact_mode="${5:-log}"

  local host
  host=$(hostname -s)

  local body
  body="## /run-issues — ${headline}"$'\n\n'
  body+="- Issue: #${ISSUE_NUM}"$'\n'
  body+="- Branch: \`${BRANCH}\`"$'\n'
  body+="- Status/syy: \`${kind}\`"$'\n'
  body+="- Host: \`${host}\`"$'\n'
  body+="- Run-id: \`${RUN_ID}\`"$'\n'

  if [ "$awaitable" = "1" ]; then
    local marker
    marker=$(build_marker "$RUN_ID" "$ISSUE_NUM" "$(date -u +%FT%TZ)")
    # Marker first so α2's scanner finds it deterministically at the top.
    body="${marker}"$'\n'"${body}"
    body+=$'\n'"**Vastaa tähän issueen kommentilla — Studio jatkaa automaattisesti (≤5 min).**"$'\n'
  fi

  if [ -n "$artifact_file" ] && [ -f "$artifact_file" ]; then
    local raw raw_bytes rendered
    raw=$(cat "$artifact_file")
    raw_bytes=$(printf '%s' "$raw" | wc -c | tr -d ' ')
    rendered=$(printf '%s' "$raw" | truncate_for_github "$RUN_ISSUES_SITUATION_ARTIFACT_MAX")
    if [ "$artifact_mode" = "prose" ]; then
      # Prose (Markdown) artifacts like cycle-review output render as text so
      # long lines wrap on GitHub — a code fence would force horizontal scroll.
      # A blank line after <summary> is required for GitHub to render Markdown
      # inside <details>.
      body+=$'\n'"<details open>"$'\n'"<summary>$(basename "$artifact_file")</summary>"$'\n\n'
      body+="${rendered}"$'\n\n'
      body+="</details>"$'\n'
    else
      # Log/plain artifacts keep monospace formatting in a code fence.
      body+=$'\n'"### $(basename "$artifact_file")"$'\n'
      body+='```'$'\n'
      body+="${rendered}"$'\n'
      body+='```'$'\n'
    fi
    if [ "$raw_bytes" -gt "$RUN_ISSUES_SITUATION_ARTIFACT_MAX" ]; then
      body+=$'\n'"Täysi loki Studiolla: \`${RUN_DIR}\` (host \`${host}\`)."$'\n'
    fi
  fi

  comment_issue "$REPO_ROOT" "$ISSUE_NUM" "$body" || true
  state_event "$RUN_DIR" "situation_posted" "kind=${kind}" "awaitable=${awaitable}" || true
  return 0
}

# _add_waiting_label / _remove_waiting_label — best-effort label management for
# the awaiting_clarification state. The `waiting` label keeps pick_oldest_unassigned
# and the poller from re-picking the issue while it waits for maintainer's reply (both
# exclude -label:waiting). Failures are non-fatal.
_add_waiting_label() {
  ( cd "$REPO_ROOT" && gh label create waiting --color FBCA04 \
      --description "Odottaa ihmisen vastausta — automaattinen ajo jatkaa kommentista" >/dev/null 2>&1 ) || true
  ( cd "$REPO_ROOT" && gh issue edit "$ISSUE_NUM" --add-label waiting >/dev/null 2>&1 ) || true
}
_remove_waiting_label() {
  ( cd "$REPO_ROOT" && gh issue edit "$ISSUE_NUM" --remove-label waiting >/dev/null 2>&1 ) || true
}

# _finalize_awaiting_clarification — shared NEEDS_CLARIFICATION terminal path.
# Finalizes the run as awaiting_clarification, records the round + timestamp,
# attaches the waiting label, and posts an answerable situation comment (marker
# + reply prompt). The poller's scan_answered restarts via --continue once maintainer
# replies. Used by both the first NEEDS_CLARIFICATION (review_gate, IS_CONTINUE=0)
# and a re-review that is still unclear (IS_CONTINUE=1).
_finalize_awaiting_clarification() {
  local cr_out="$RUN_DIR/01-cycle-review.out"
  local round
  round=$(jq -r '.clarification_round // 0' "$RUN_DIR/run.json" 2>/dev/null || echo 0)
  state_finalize "$RUN_DIR" "awaiting_clarification" "cycle_review_needs_clarification"
  state_set "$RUN_DIR" "awaiting_answer_since" "$(date -u +%FT%TZ)"
  _add_waiting_label
  _post_situation_to_issue "cycle_review_clarification" \
    "Cycle review tarvitsee tarkennusta (kierros $round) ennen kuin toteutus voi jatkua. Kerro puuttuvat tiedot kommentissa." \
    "$cr_out" 1 prose
  state_event "$RUN_DIR" "awaiting_clarification" "round=$round"
}

# _add_needs_human_label — best-effort: ensure the needs-human label exists in
# the repo and is attached to the issue. Failures are non-fatal (the run is
# already finalized in run.json regardless). Shared by _hand_to_human and the
# env-bootstrap gate, which posts its own log-mode situation comment but still
# needs the same hand-off signal.
_add_needs_human_label() {
  ( cd "$REPO_ROOT" && gh label create needs-human --color B60205 \
      --description "Vaatii ihmisen — automaattinen ajo ei onnistunut" >/dev/null 2>&1 ) || true
  ( cd "$REPO_ROOT" && gh issue edit "$ISSUE_NUM" --add-label needs-human >/dev/null 2>&1 ) || true
}

# _hand_to_human <message> [<artifact-file>] — best-effort: post a full
# situation report and ensure the needs-human label is attached. All failures
# are non-fatal (the run is already finalized in run.json regardless). The
# artifact (when present) is implementer output, so render it as prose.
_hand_to_human() {
  local msg="$1"
  local artifact_file="${2:-}"
  _post_situation_to_issue "needs_human" "$msg" "$artifact_file" 0 prose
  _add_needs_human_label
}

# propagate_pr_labels <pr-url> — best-effort: copy merge-relevant labels from
# the source issue onto the freshly created PR. GitHub does not copy issue
# labels to PRs automatically, so without this the pr-watch merge-policy
# (auto-merge label + CI + mergeable) never fires and the autoflow chain
# (issue -> PR -> auto-merge) stalls on the last step.
#
# The propagate-list is configurable via RUN_ISSUES_PR_LABELS_CSV (default
# "auto-merge"); only labels actually present on the source issue are added.
# Labels are added even on draft PRs: a draft is never CLEAN/mergeable, so
# pr-watch will not merge it before it is marked ready anyway, and the label is
# then already in place. Reads labels from the cached issue.json (populated in
# both normal and --restart paths). All failures are non-fatal — the PR already
# exists, so a label error must not flip a completed run to blocked.
propagate_pr_labels() {
  local pr="$1"
  local issue_json="$RUN_DIR/issue.json"
  [ -f "$issue_json" ] || { log "propagate_pr_labels: issue.json missing — skipping"; return 0; }

  local issue_labels matched="" want
  issue_labels=$(jq -r '[.labels[]?.name] | join("\n")' "$issue_json")

  # Intersect the configured propagate-list with labels actually on the issue.
  while IFS= read -r want; do
    want="$(printf '%s' "$want" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$want" ] || continue
    if printf '%s\n' "$issue_labels" | grep -qxF -- "$want"; then
      matched="${matched:+$matched,}$want"
    fi
  done <<EOF
$(printf '%s' "$PR_LABELS_CSV" | tr ',' '\n')
EOF

  if [ -z "$matched" ]; then
    log "propagate_pr_labels: no propagatable labels on issue #$ISSUE_NUM (configured: $PR_LABELS_CSV)"
    return 0
  fi

  # Best-effort: ensure each label exists in the target repo before adding it.
  local lbl
  while IFS= read -r lbl; do
    [ -n "$lbl" ] || continue
    ( cd "$REPO_ROOT" && gh label create "$lbl" >/dev/null 2>&1 ) || true
  done <<EOF
$(printf '%s' "$matched" | tr ',' '\n')
EOF

  if ( cd "$REPO_ROOT" && gh pr edit "$pr" --add-label "$matched" >/dev/null 2>&1 ); then
    log "propagate_pr_labels: added [$matched] to PR (issue #$ISSUE_NUM)"
    state_event "$RUN_DIR" "pr_labels_propagated" "labels=$matched"
  else
    log "propagate_pr_labels: 'gh pr edit --add-label $matched' failed (non-fatal — PR already created)"
  fi
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
# S7b: env bootstrap — fail-fast dependency install before the implementer
# ===========================================================================
# run_env_bootstrap — install the worktree's dependencies BEFORE the implementer
# so an environment obstacle (e.g. a missing GITHUB_TOKEN that breaks private
# @scope/* installs) surfaces as an immediate, diagnosable blocked run instead
# of a silent implementer timeout that burns the whole budget.
#
#   no package.json   -> no-op (the dotfiles repo itself hits this); proceed.
#   install succeeds   -> proceed to the implementer normally.
#   install fails      -> finalize blocked / env_bootstrap_failed, attach the
#                         needs-human label, post the install log to the issue,
#                         and exit 5 WITHOUT spending any implementer timeout.
#
# Runs on every path that reaches phase_b (start, --resume, --restart,
# --continue), so it is the single chokepoint before S8. Idempotent: a restart
# re-installs harmlessly.
run_env_bootstrap() {
  enter_state "S7b_EnvBootstrap"
  log "S7b_EnvBootstrap"
  local pm
  pm=$(detect_package_manager "$WORKTREE_PATH")
  if [ -z "$pm" ]; then
    log "env-bootstrap: no package.json in $WORKTREE_PATH — no-op"
    state_event "$RUN_DIR" "env_bootstrap_skipped" "reason=no_package_json"
    return 0
  fi

  log "env-bootstrap: detected $pm — installing dependencies"
  local boot_log="$RUN_DIR/env-bootstrap.log"
  set +e
  (
    cd "$WORKTREE_PATH"
    case "$pm" in
      pnpm) pnpm install ;;
      yarn) yarn install ;;
      npm)  npm install ;;
    esac
  ) > "$boot_log" 2>&1
  local boot_rc=$?
  set -e

  if [ "$boot_rc" -ne 0 ]; then
    log "env-bootstrap: '$pm install' failed (rc=$boot_rc) — finalizing blocked (no implementer budget spent)"
    state_finalize "$RUN_DIR" "blocked" "env_bootstrap_failed"
    state_event "$RUN_DIR" "env_bootstrap_failed" "pm=$pm" "rc=$boot_rc"
    # Post the install log in log-mode (monospace) — it is tool output, not prose.
    _post_situation_to_issue "env_bootstrap_failed" \
      "Riippuvuuksien asennus ($pm) epäonnistui ennen toteutusvaihetta (rc=$boot_rc). Yleisin syy on puuttuva GITHUB_TOKEN yksityisille @scope/*-paketeille — tarkista koneellinen env-tiedosto. Asennusvirhe alla." \
      "$boot_log" 0 log
    _add_needs_human_label
    exit 5
  fi

  log "env-bootstrap: '$pm install' succeeded"
  state_event "$RUN_DIR" "env_bootstrap_ok" "pm=$pm"
}

# ===========================================================================
# Phase B: implementer → evolution → PR
# ===========================================================================
phase_b() {
  # ---------- S7b: env bootstrap (fail-fast dep install) ----------
  run_env_bootstrap

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
      _post_situation_to_issue "implementer_blocked" \
        "Toteutusvaihe (implementer) jäi jumiin eikä tuottanut valmista tulosta. Tarkista alla oleva tuloste ja issuen vaatimukset." \
        "$imp_out" 0 prose
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
    _post_situation_to_issue "git_push_failed" \
      "Toteutus valmistui, mutta haaran push GitHubiin epäonnistui (rc=$push_rc). Tarkista push-loki ja remote-oikeudet." \
      "$RUN_DIR/git-push.log" 0
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
    _post_situation_to_issue "pr_create_failed" \
      "Haara pushattiin, mutta pull requestin avaaminen epäonnistui. Tarkista alla oleva gh-loki ja avaa PR tarvittaessa käsin." \
      "$RUN_DIR/gh-pr-create.log" 0
    exit 6
  fi

  state_set "$RUN_DIR" "pr_url" "$pr_url"
  state_event "$RUN_DIR" "pr_opened" "url=$pr_url"

  # Propagate merge-relevant labels (e.g. auto-merge) from the issue to the PR
  # so the pr-watch merge-policy can fire. Best-effort; never fatal.
  propagate_pr_labels "$pr_url"

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
  continue)
    continue_load_state  # exits 0/1/3 on cap/usage/lock/worktree/no-reply
    run_cycle_review     # re-run S6 with maintainer's reply as context
    review_gate          # PROCEED -> phase_b; NEEDS_CLARIFICATION -> exit 11; BLOCKER -> human
    phase_b
    ;;
esac

exit 0
