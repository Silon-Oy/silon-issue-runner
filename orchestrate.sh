#!/usr/bin/env bash
# orchestrate.sh — /run-issues orchestrator with resume support.
#
# Usage:
#   orchestrate.sh <repo-root> <issue-number>
#   orchestrate.sh --resume <run-dir> --decision PROCEED|CANCEL
#
# The state machine runs in two phases:
#   Phase A (S1..S6)  pick → claim → worktree → db-clone → cycle-review
#   Review gate (S7)  auto-mode: in-process; interactive: exit 10
#   Phase B (S7b..S12) env-bootstrap → provision-test-env → implementer →
#                     evolution → push → PR
#
# S7b (env bootstrap) is a fail-fast dependency-install gate before the
# implementer: a failed install (e.g. missing GITHUB_TOKEN for private deps)
# finalizes the run as blocked/env_bootstrap_failed and hands it to a human
# instead of letting the implementer burn its whole timeout budget silently.
#
# S0 (preflight gate) runs before the MODE dispatch, so all four entry paths
# (start, --resume, --restart, --continue) are guarded alike. Its position is
# forced by three constraints: it must run AFTER ensure_node_runtime (a poller
# launches this script in a tmux server without the interactive nvm PATH, so an
# earlier npx check would report a false negative on every poller run) and AFTER
# source_machine_env (which may supply GITHUB_TOKEN and RUN_ISSUES_CLAUDE_CMD),
# but BEFORE phase_a — which creates the run dir before taking the lock, so any
# later gate would leave state behind on a failure.
#
# S7c (provision-test-env) is an opt-in, target-repo-owned hook that provisions
# whatever external resources a run's tests need (a migrated test database,
# Redis, …) with run-id isolation, and injects their addresses as KEY=VALUE env
# vars into the implementer. Missing hook -> no-op; a failed hook fail-fasts as
# blocked/provision_test_env_failed (same hand-off as S7b).
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
#   RUN_ISSUES_PR_LABELS_CSV  labels to propagate from the source issue to the
#                           created PR, if present on the issue (default
#                           "auto-merge"). Enables the autoflow chain
#                           issue -> PR -> pr-watch auto-merge.
#   RUN_ISSUES_SKIP_PREFLIGHT  "1" = skip the S0 dependency gate (escape hatch;
#                           the gate must never be the reason a run cannot start)
#
# Exit codes:
#   0   success — PR opened, or resume cancelled cleanly
#   1   fatal — invalid usage / missing run.json on resume / `poll` argument
#       (automatic pickup is the poller's job, not the orchestrator's — issue #99)
#   3   lock/claim race lost
#   4   cycle review blocked the run (auto mode only)
#   5   blocked before/at the implementer — db-clone failed, env bootstrap
#       (S7b dependency install) failed or timed out, the test-env provisioning
#       hook (S7c) failed, or implementer returned BLOCKED
#   6   PR open failed
#   7   implementer (S8) timed out — run finalized as timed_out, eligible for
#       auto-restart via --restart (or budget-exhausted handed to a human)
#   8   missing required dependency — the S0 preflight gate refused to start the
#       run; nothing was locked, claimed or created. The stderr message names
#       the missing tool AND its fix command.
#   9   issue is blocked by an open dependency — refused between the lock and the
#       claim (S2b), before the issue is assigned to us. The run dir is finalized
#       blocked/blocked_by_dependency and the lock released; nothing is claimed.
#       The pickup search's `-is:blocked` reads GitHub's eventually-consistent
#       SEARCH index, so a lagging index once leaked 25 blocked issues into
#       pickup (issue #28); this gate re-checks the strongly consistent
#       dependency GRAPH and is FAIL-CLOSED (an unreadable graph counts as
#       blocked). A named run can override with --force.
#  10   awaiting human review — invoke --resume to continue
#  11   awaiting clarification — cycle review returned NEEDS_CLARIFICATION; the
#       run is finalized as awaiting_clarification with the waiting label and an
#       answerable situation comment. Poller's scan_answered restarts it via
#       --continue once the issue author replies.
#  12   issue carries the epic label — refused between the lock and the claim
#       (S2c, issue #81), before the issue is assigned to us. An epic collects
#       runnable sub-issues but is never itself runnable; the pickup search's
#       `-label:epic` reads GitHub's eventually-consistent SEARCH index, so this
#       gate re-checks the label authoritatively and is FAIL-CLOSED (unreadable
#       labels count as epic). The run dir is finalized blocked/is_epic_not_runnable
#       (or blocked/epic_check_failed when unreadable) and the lock released;
#       nothing is claimed and NO needs-human label is added (a pre-claim gate,
#       like S2b). A named run can override with --force.
#
# --restart <run-dir> resumes a timed_out run with a ramped, capped timeout
# (base*(1+retry_count), cap RUN_ISSUES_CLAUDE_TIMEOUT_MAX). It skips pick/claim
# and re-enters Phase B. Budget is RUN_ISSUES_MAX_RETRIES (default 1).
#
# --continue <run-dir> resumes an awaiting_clarification run after the issue
# author has replied: it re-takes the lock, increments clarification_round, re-runs S6
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
# Multi-remote (issue #53): the git remote name in the local clone that this
# run targets. Default "origin" preserves the legacy single-remote path. The
# poller passes --remote <name> per (repo × remote) iteration; resume/restart/
# continue read it from run.json (set in phase_a or via state_set).
REMOTE_NAME="origin"
# --force overrides the S2b blocked-by gate for a named run (issue #28): running
# an issue with an open dependency is almost always a mistake, so it must be a
# visible, deliberate act rather than a silent default. Never set by the poller.
FORCE=0

usage() {
  cat >&2 <<'USAGE'
usage:
  orchestrate.sh [--remote <name>] [--force] <repo-root> <issue-number>
  orchestrate.sh --resume <run-dir> --decision PROCEED|CANCEL
  orchestrate.sh --restart <run-dir>
  orchestrate.sh --continue <run-dir>
  orchestrate.sh --version
USAGE
  exit 1
}

# --version (issue #32): the first thing a diagnosis reaches for. Report which
# runner version is executing and how far it has drifted, then exit — before any
# mode dispatch, lock, or run-dir. Self-contained so it works even with no repo
# or issue argument. SCRIPT_DIR is redefined identically in the library-loading
# section below; that path is never reached here because we exit.
if [ "${1:-}" = "--version" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=lib/version.sh
  . "$SCRIPT_DIR/lib/version.sh"
  printf 'run-issues %s\n' "$(runner_version_summary "$SCRIPT_DIR")"
  exit 0
fi

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
  # Optional `--remote <name>` flag before the two positional args. Default
  # "origin" preserves the legacy invocation shape used by the slash command
  # (`orchestrate.sh <repo> <issue>`). Use a case-based glob match so the
  # `--remote=<name>` and `--remote <name>` shapes are both accepted.
  while :; do
    case "${1:-}" in
      --remote)
        REMOTE_NAME="${2:-origin}"
        shift 2 || true
        ;;
      --remote=*)
        REMOTE_NAME="${1#*=}"
        shift
        ;;
      --force)
        FORCE=1
        shift
        ;;
      *) break ;;
    esac
  done
  [ -n "$REMOTE_NAME" ] || REMOTE_NAME="origin"
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
# Merge-relevant labels copied from the source issue onto the created PR.
PR_LABELS_CSV="${RUN_ISSUES_PR_LABELS_CSV:-auto-merge}"

# ---------- library loading ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-remote.sh
source "$SCRIPT_DIR/lib/git-remote.sh"
# shellcheck source=lib/locking.sh
source "$SCRIPT_DIR/lib/locking.sh"
# shellcheck source=lib/issue.sh
source "$SCRIPT_DIR/lib/issue.sh"
# shellcheck source=lib/issue-images.sh
source "$SCRIPT_DIR/lib/issue-images.sh"
# shellcheck source=lib/worktree.sh
source "$SCRIPT_DIR/lib/worktree.sh"
# shellcheck source=lib/gitignore.sh
source "$SCRIPT_DIR/lib/gitignore.sh"
# shellcheck source=lib/state.sh
source "$SCRIPT_DIR/lib/state.sh"
# shellcheck source=lib/claude-call.sh
source "$SCRIPT_DIR/lib/claude-call.sh"
# shellcheck source=lib/preflight.sh
source "$SCRIPT_DIR/lib/preflight.sh"
# shellcheck source=lib/hook-runner.sh
source "$SCRIPT_DIR/lib/hook-runner.sh"
# shellcheck source=lib/env-bootstrap.sh
source "$SCRIPT_DIR/lib/env-bootstrap.sh"
# shellcheck source=lib/labels.sh
source "$SCRIPT_DIR/lib/labels.sh"
# shellcheck source=lib/version.sh
# Runner-version visibility (issue #32): read by _post_situation_to_issue so a
# hand-off report names the code version that produced it, and by --version.
source "$SCRIPT_DIR/lib/version.sh"
# shellcheck source=lib/machine-env.sh
# source_machine_env with CALLER PRECEDENCE (issue #144). Shared with pr-watch.sh
# so the precedence rule exists once; the copy that used to live here silently
# overwrote a caller's RUN_ISSUES_* choice, which let the test suite run the real
# claude CLI against its own stub.
source "$SCRIPT_DIR/lib/machine-env.sh"
# shellcheck source=lib/github-app-auth.sh
# Sourced AFTER source_machine_env (below) populates env vars. We require the
# file to exist; the helper guards every side effect on gha_enabled, so loading
# it is a no-op when the App env vars are not set.
source "$SCRIPT_DIR/lib/github-app-auth.sh"

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

# load_repo_base_branch <repo-root> — prints the base branch name (or empty).
# Resolution order:
#   1. RUN_ISSUES_BASE_BRANCH from the environment (explicit override)
#   2. base_branch in the target repo's .claude/run-issues.json (opt-in, same
#      file/convention as claude_timeout_seconds)
#   3. empty -> caller treats it as "use the repo default" (origin/HEAD for the
#      worktree base, no --base for the PR) — fully backward compatible.
# Unlike load_repo_timeout this does NOT export: the base branch is only needed
# in this process (worktree base + `gh pr create --base`), so it prints to
# stdout for $(...) capture, keeping the function pure and testable.
load_repo_base_branch() {
  local repo="$1"
  if [ -n "${RUN_ISSUES_BASE_BRANCH:-}" ]; then
    printf '%s' "$RUN_ISSUES_BASE_BRANCH"
    return 0
  fi
  local cfg="$repo/.claude/run-issues.json"
  if [ -f "$cfg" ] && jq -e . "$cfg" >/dev/null 2>&1; then
    jq -r '.base_branch // empty' "$cfg" 2>/dev/null || true
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
# lib/machine-env.sh owns the sourcing and the precedence rule: inside the
# package's own RUN_ISSUES_*/PR_WATCH_* namespaces the caller's already-set value
# WINS over the file; everything else (secrets) keeps file-wins. Running this once
# at top level, before the MODE dispatch, covers start / --resume / --restart /
# --continue uniformly.
source_machine_env

# ---------- S0: preflight dependency gate (issue #7) ----------
# A missing external dependency used to be diagnosed as something else entirely:
# an absent claude CLI made npx exit 127, which left an empty cycle-review output,
# which became an UNKNOWN decision, which finally posted "the implementer got
# stuck" on the issue — after the run had already taken a lock, claimed the issue
# and created a worktree. This gate moves the observation forward in time to the
# last moment at which nothing has happened yet.
#
# Placement is forced (see the header): after ensure_node_runtime and
# source_machine_env, before the MODE dispatch and therefore before phase_a
# creates the run dir.
#
# All output goes through log() to stderr. The poller pipes this script through
# `tee`, so stderr is the only channel that reaches the runs log — and `tee`
# swallows the exit code, which makes the message itself the diagnosis.
preflight_gate() {
  if [ "${RUN_ISSUES_SKIP_PREFLIGHT:-0}" = "1" ]; then
    log "S0_Preflight skipped (RUN_ISSUES_SKIP_PREFLIGHT=1)"
    return 0
  fi

  # Probing only the default invocation is what keeps the gate honest: an
  # overridden RUN_ISSUES_CLAUDE_CMD is the user's own driver, and running
  # `--version` on it would both guess its flags and fire a call the caller
  # never asked for.
  local mode="have"
  if [ "$RUN_ISSUES_CLAUDE_CMD" = "$RUN_ISSUES_CLAUDE_CMD_DEFAULT" ]; then
    mode="probe"
  fi

  local findings="" rc=0
  # shellcheck disable=SC2086
  findings=$(preflight_gate_report "$mode" $RUN_ISSUES_CLAUDE_CMD) || rc=$?

  # gh authentication is policy, not a fact about a tool, so it lives here
  # rather than in the pure module. `gh auth token` is deliberate: `gh auth
  # status` calls the API, which would make a network outage a new way for a
  # run to fail to start. Token validity and scopes are a deeper check that
  # belongs to an explicit doctor command, not to a per-run gate.
  if preflight_have gh && ! gh auth token >/dev/null 2>&1; then
    local auth_hint
    auth_hint="$(preflight_install_hint gh-auth)"
    if gha_enabled; then
      # In App mode the runs authenticate with an installation token, so a
      # missing personal login only affects remotes the App does not cover.
      findings="${findings}${findings:+$'\n'}MISSING (optional): gh auth — ${auth_hint} (GitHub App mode is enabled; personal login is only needed for non-App remotes)"
    else
      findings="${findings}${findings:+$'\n'}MISSING (required): gh auth — ${auth_hint}"
      rc=2
    fi
  fi

  local line
  if [ "$rc" -eq 2 ]; then
    log "S0_Preflight FAILED — required dependencies missing; nothing was locked, claimed or created:"
    while IFS= read -r line; do
      [ -n "$line" ] && log "  $line"
    done <<< "$findings"
    log "fix the above and re-run (exit 8)"
    exit 8
  fi

  if [ -n "$findings" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && log "WARNING: $line"
    done <<< "$findings"
  fi
  log "S0_Preflight ok (claude check: $mode)"
  return 0
}
preflight_gate

# ---------- globals (populated as we progress; also restored on resume) ----------
ISSUE_NUM=""
ISSUE_TITLE=""
ISSUE_BODY=""
ISSUE_COMMENTS=""
# ISSUE_IMAGES holds the rendered {{ISSUE_IMAGES}} prompt block (a list of
# locally downloaded image paths + a Read-tool instruction), or empty when the
# issue references no images. Computed once per process (see
# prepare_issue_images) and reused by both the cycle-review and implementer
# renders, so it is never persisted to run.json.
ISSUE_IMAGES=""
# Once-per-process guard for prepare_issue_images: the start/continue paths call
# it at S6 and again at S8, but a single process must download only once. A fresh
# --continue/--restart/--resume process starts with this reset to 0, so it
# re-downloads from the freshest issue.json (picking up a clarification reply's
# new image).
ISSUE_IMAGES_PREPARED=0
RUN_ID=""
RUN_DIR=""
BRANCH=""
WORKTREE_PATH=""
BASE_BRANCH=""
CR_DECISION=""
DB_CLONE_VALUE=""
# PROVISION_TEST_ENV_PAIRS holds the KEY=VALUE lines emitted by the opt-in
# per-run test-env provisioning hook (S7c). It is repopulated on every path that
# reaches the implementer (the hook is re-run idempotently), so it is exported
# into the implementer's environment without needing to be persisted/restored.
PROVISION_TEST_ENV_PAIRS=""
LOCK_HELD=0
CLAIMED=0
CURRENT_STATE=""
RESTART_CONTEXT=""
# CLARIFICATION_CONTEXT is rendered into the cycle-review prompt. Empty on a
# normal first pass (the prompt section collapses); the --continue path fills
# it with the prior clarification headline + the issue author's reply.
CLARIFICATION_CONTEXT=""
# IS_CONTINUE distinguishes a first NEEDS_CLARIFICATION (exit 11, post marker)
# from a re-evaluation after a reply (still NEEDS_CLARIFICATION -> new marker,
# round+1, exit 11; BLOCKER -> hand to human, no loop).
IS_CONTINUE=0
# OWNER_REPO is the "owner/repo" string derived from `git remote get-url
# $REMOTE_NAME` (issue #53). When non-empty it is passed to every `gh issue …`
# / `gh pr create` call so the gh routes to the right org instead of inferring
# from cwd (which is wrong for non-origin remotes). Empty -> gh's legacy
# cwd-based resolution (origin); full backward compatibility.
OWNER_REPO=""
# REPO_SLUG is the repo component of this run's identity (issue #67): the
# filename-safe slug of `owner/repo` (fallback: repo dir basename). It is part
# of the lock name, run-id, branch and tmux session so two repos' issue #42
# cannot collide in the global lock/tmux namespaces. Persisted to run.json as
# `repo_slug`, and read back verbatim by --resume/--restart/--continue: a run
# created before #67 has no such field, keeps REPO_SLUG empty, and therefore
# keeps the legacy names it was started with for its whole life.
REPO_SLUG=""

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
    unlock_issue "$ISSUE_NUM" "$REMOTE_NAME" "$REPO_SLUG" || true
  fi
  exit "$rc"
}
trap cleanup_on_exit EXIT

# resolve_owner_repo — derive OWNER_REPO from REPO_ROOT + REMOTE_NAME so every
# subsequent gh call can route via `gh --repo owner/repo` instead of relying on
# the cwd-based remote inference (which only picks up origin). For the legacy
# "origin" remote we leave OWNER_REPO EMPTY on purpose: the existing tests
# stub gh in repos that lack a github.com URL, and the empty value preserves
# the historical cwd-based gh path. A non-origin remote that does not resolve
# is fail-fast — the WHOLE point of opting in was to route to it.
resolve_owner_repo() {
  case "$REMOTE_NAME" in
    ""|origin)
      OWNER_REPO=""
      return 0
      ;;
  esac
  if ! OWNER_REPO=$(resolve_remote_to_owner_repo "$REPO_ROOT" "$REMOTE_NAME"); then
    log "ERROR: remote '$REMOTE_NAME' not found in $REPO_ROOT or URL not parseable — cannot continue"
    exit 1
  fi
  log "remote: routing gh via --repo $OWNER_REPO (remote=$REMOTE_NAME)"
}

# resolve_repo_slug — derive REPO_SLUG from REPO_ROOT + REMOTE_NAME (issue #67).
# Called only on the NEW-run path: resume/restart/continue read the slug from
# run.json instead, so a run's identity never changes under it (a remote URL
# edit mid-run must not rename the lock the run is holding).
#
# Unlike resolve_owner_repo this is never fatal: repo_slug falls back to the repo
# dir basename, and an empty result simply means legacy naming.
resolve_repo_slug() {
  REPO_SLUG=$(repo_slug "$REPO_ROOT" "$REMOTE_NAME")
  if [ -n "$REPO_SLUG" ]; then
    log "repo: identity namespaced as '$REPO_SLUG' (remote=$REMOTE_NAME)"
  else
    log "WARNING: could not derive a repo slug for $REPO_ROOT — falling back to legacy (repo-agnostic) naming"
  fi
}

# ===========================================================================
# Phase A: pick → cycle-review
# ===========================================================================
phase_a() {
  load_repo_timeout "$REPO_ROOT"
  # Resolve OWNER_REPO from REMOTE_NAME up front so every subsequent gh call
  # can route via `gh --repo` for non-origin remotes (multi-org support), and
  # REPO_SLUG so lock / run-id / branch / tmux naming is repo-namespaced.
  resolve_owner_repo
  resolve_repo_slug

  # ---------- S1: pick issue ----------
  # A named issue number is REQUIRED (issue #99): the orchestrator no longer polls.
  # Automatic pickup is the poller's job — the package has exactly one pickup search
  # (pick_oldest_candidate, driven by the poller). A literal `poll` argument (or any
  # non-numeric value) falls through the numeric validation and exits 1 as a usage
  # error, naming the poller as the owner of automatic pickup.
  log "S1_PickIssue (remote=$REMOTE_NAME)"
  ISSUE_NUM=$(printf '%s' "$ISSUE_ARG" | sed 's/^#//')
  case "$ISSUE_NUM" in
    poll)        echo "orchestrate: automatic pickup is the poller's job — pass a concrete issue number" >&2; exit 1 ;;
    ''|*[!0-9]*) echo "orchestrate: invalid issue argument '$ISSUE_ARG' — expected an issue number" >&2; exit 1 ;;
  esac

  # Snapshot issue payload — used now for branch name and later (incl. resume).
  # Run-id is namespaced by repo AND remote so the same issue number in two
  # repos / two orgs gets distinct run-dirs, branches, locks and tmux sessions
  # (e.g. `<ts>-silon-oy-flow-issue-5` vs `<ts>-silon-oy-customer-a-report-issue-5`).
  # One label feeds all of them so the four derivations cannot drift apart.
  local id_label
  id_label=$(remote_label "$REMOTE_NAME" "$ISSUE_NUM" "$REPO_SLUG")
  RUN_ID="$(date +%Y%m%d-%H%M%S)-${id_label}"
  RUN_DIR="$REPO_ROOT/.claude/run-issues/$RUN_ID"
  mkdir -p "$RUN_DIR"
  local issue_json="$RUN_DIR/issue.json"
  fetch_issue_json "$REPO_ROOT" "$ISSUE_NUM" "$OWNER_REPO" "$REMOTE_NAME" > "$issue_json"
  ISSUE_TITLE=$(jq -r '.title // empty' "$issue_json")
  ISSUE_BODY=$(jq -r '.body // ""' "$issue_json")
  ISSUE_COMMENTS=$(jq -r '[.comments[]? | "--- @\(.author.login // "?") @ \(.createdAt // "?")\n\(.body)"] | join("\n\n")' "$issue_json")
  local slug
  slug=$(slugify_title "$ISSUE_TITLE")
  [ -n "$slug" ] || slug="issue_${ISSUE_NUM}"

  state_init "$RUN_DIR" "$RUN_ID" "$REPO_ROOT" "$ISSUE_NUM"
  state_set "$RUN_DIR" "remote" "$REMOTE_NAME"
  [ -n "$OWNER_REPO" ] && state_set "$RUN_DIR" "owner_repo" "$OWNER_REPO"
  # repo_slug is the durable record of this run's naming generation: present =>
  # repo-namespaced names (post-#67), absent => legacy names. Every teardown path
  # (poller finalize_stalled, cleanup-run.sh, auto-clean.sh) reads it back so it
  # releases the lock this run actually holds — and no other repo's.
  [ -n "$REPO_SLUG" ] && state_set "$RUN_DIR" "repo_slug" "$REPO_SLUG"
  enter_state "S1_PickIssue"
  state_event "$RUN_DIR" "issue_picked" "issue_number=$ISSUE_NUM" "title=$ISSUE_TITLE" "remote=$REMOTE_NAME"

  # Branch is also namespaced for non-origin so two orgs' issue #5 do not
  # collide on a single local branch name in the shared clone.
  BRANCH="auto-run/${id_label}-${slug}"
  state_set "$RUN_DIR" "branch" "$BRANCH"

  # ---------- S2: lock ----------
  enter_state "S2_Lock"
  log "S2_Lock issue=$ISSUE_NUM remote=$REMOTE_NAME"
  if ! lock_issue "$ISSUE_NUM" "$REMOTE_NAME" "$REPO_SLUG"; then
    log "lock held by another runner; exiting"
    state_finalize "$RUN_DIR" "lost_race" "lock_held"
    exit 3
  fi
  LOCK_HELD=1
  state_event "$RUN_DIR" "lock_acquired"

  # ---------- S2b: authoritative blocked-by gate (issue #28) ----------
  # The pickup search's `-is:blocked` reads GitHub's eventually-consistent SEARCH
  # index; a lag once leaked 25 blocked issues into pickup, launched one tick
  # apart in creation order. Re-check the strongly consistent dependency GRAPH
  # here — AFTER the lock (so only the runner that won the lock spends the API
  # call) and BEFORE the claim (so a blocked issue is never assigned to us). The
  # count is logged either way, so a bad pickup is visible in the log, not just
  # in colliding PRs. Fail-closed: an unreadable graph counts as blocked. --force
  # makes running a blocked issue a visible, deliberate act.
  local open_blockers=""
  if [ "$FORCE" = "1" ]; then
    log "S2b_BlockedCheck: --force set — bypassing blocked-by gate for issue=$ISSUE_NUM"
    state_event "$RUN_DIR" "blocked_check_forced"
  elif open_blockers=$(count_open_blockers "$REPO_ROOT" "$ISSUE_NUM" "$OWNER_REPO"); then
    log "S2b_BlockedCheck: issue=$ISSUE_NUM open_blockers=$open_blockers"
    state_event "$RUN_DIR" "blocked_check_done" "open_blockers=$open_blockers"
    if [ "$open_blockers" -gt 0 ]; then
      log "issue #$ISSUE_NUM is blocked by $open_blockers open dependency(ies) — refusing (pass --force to override)"
      state_finalize "$RUN_DIR" "blocked" "blocked_by_dependency"
      state_event "$RUN_DIR" "blocked_by_dependency" "open_blockers=$open_blockers"
      exit 9
    fi
  else
    log "issue #$ISSUE_NUM: blocked_by dependency graph unreadable — assuming blocked (fail-closed; pass --force to override)"
    state_finalize "$RUN_DIR" "blocked" "blocked_check_failed"
    state_event "$RUN_DIR" "blocked_check_failed"
    exit 9
  fi

  # ---------- S2c: authoritative epic gate (issue #81) ----------
  # The pickup search's `-label:epic` reads GitHub's eventually-consistent SEARCH
  # index, the same class of lag that once leaked 25 blocked issues past
  # `-is:blocked` (issue #28). An epic COLLECTS runnable sub-issues; it is never
  # itself runnable — running it launches the implementer against an aggregating
  # body and burns the whole timeout budget. Re-check the label authoritatively
  # here — AFTER the lock (only the lock winner pays the read) and BEFORE the
  # claim (an epic is never assigned to us). Same placement, cost and fail-closed
  # posture as S2b (docs/epic-orchestration.md §2.3). No needs-human label: like
  # S2b's pre-claim gates the issue is not ours, and an epic reaching here is a
  # rare index-lag artefact, not a human task. --force overrides (a named run may
  # deliberately target an epic). Lock is released by the EXIT trap (rc != 10).
  local is_epic_flag=""
  if [ "$FORCE" = "1" ]; then
    log "S2c_EpicCheck: --force set — bypassing epic gate for issue=$ISSUE_NUM"
    state_event "$RUN_DIR" "epic_check_forced"
  elif is_epic_flag=$(is_epic "$REPO_ROOT" "$ISSUE_NUM" "$OWNER_REPO"); then
    log "S2c_EpicCheck: issue=$ISSUE_NUM is_epic=$is_epic_flag"
    state_event "$RUN_DIR" "epic_check_done" "is_epic=$is_epic_flag"
    if [ "$is_epic_flag" = "1" ]; then
      log "issue #$ISSUE_NUM carries the epic label — not runnable; refusing (pass --force to override)"
      state_finalize "$RUN_DIR" "blocked" "is_epic_not_runnable"
      state_event "$RUN_DIR" "is_epic_not_runnable"
      exit 12
    fi
  else
    log "issue #$ISSUE_NUM: labels unreadable — assuming epic (fail-closed; pass --force to override)"
    state_finalize "$RUN_DIR" "blocked" "epic_check_failed"
    state_event "$RUN_DIR" "epic_check_failed"
    exit 12
  fi

  # ---------- S3: claim ----------
  enter_state "S3_Claim"
  log "S3_Claim issue=$ISSUE_NUM"
  # Snapshot the assignee set BEFORE claiming (issue #99): verify_claim now accepts
  # a pre-assigned issue (a human may have assigned themselves or a colleague), so
  # it checks the post-claim set equals this snapshot ∪ {@me} rather than "@me is
  # the sole assignee". A racing runner on another account still shows up as an
  # extra login and loses the race.
  local before_assignees
  before_assignees=$(issue_assignees "$REPO_ROOT" "$ISSUE_NUM" "$OWNER_REPO" "$REMOTE_NAME" || true)
  claim_issue "$REPO_ROOT" "$ISSUE_NUM" "$OWNER_REPO"
  state_event "$RUN_DIR" "claim_attempted"
  sleep 5
  if ! verify_claim "$REPO_ROOT" "$ISSUE_NUM" "$OWNER_REPO" "$before_assignees" "$REMOTE_NAME"; then
    log "claim race lost after verification — unclaiming and exiting"
    unclaim_issue "$REPO_ROOT" "$ISSUE_NUM" "$OWNER_REPO"
    state_finalize "$RUN_DIR" "lost_race" "claim_lost"
    exit 3
  fi
  CLAIMED=1
  state_event "$RUN_DIR" "claim_verified"

  # ---------- S4: worktree ----------
  enter_state "S4_Worktree"
  # Resolve the opt-in base branch once and persist it so the --resume,
  # --restart and --continue paths (which never re-enter phase_a) read the
  # SAME base from run.json instead of re-reading config that may have drifted.
  BASE_BRANCH=$(load_repo_base_branch "$REPO_ROOT")
  state_set "$RUN_DIR" "base_branch" "$BASE_BRANCH"
  log "S4_Worktree run_id=$RUN_ID branch=$BRANCH base=${BASE_BRANCH:-<default>}"

  # Refresh the chosen remote BEFORE branching so the worktree's base is the
  # real remote tip. On a new run a stale base is unrecoverable (the whole run
  # builds on the wrong commit), so a failed fetch is fail-fast: blocked +
  # needs-human. Never `git pull` into a checkout — only fetch and let
  # create_worktree branch off <remote>/HEAD (or <remote>/<base_branch>).
  local fetch_rc=0
  refresh_origin "$REPO_ROOT" "$REMOTE_NAME" 2>"$RUN_DIR/origin-fetch.log" || fetch_rc=$?
  case "$fetch_rc" in
    0) state_event "$RUN_DIR" "origin_fetched" "phase=S4" "remote=$REMOTE_NAME" ;;
    2) log "S4: no '$REMOTE_NAME' remote — skipping fetch (local repo)"
       state_event "$RUN_DIR" "origin_fetch_skipped" "phase=S4" "reason=no_origin" "remote=$REMOTE_NAME" ;;
    1) log "S4: 'git fetch $REMOTE_NAME' failed — base would be stale; blocking"
       state_finalize "$RUN_DIR" "blocked" "origin_fetch_failed"
       state_event "$RUN_DIR" "origin_fetch_failed" "phase=S4" "remote=$REMOTE_NAME"
       _post_situation_to_issue "origin_fetch_failed" \
         "Remote-haku (\`git fetch $REMOTE_NAME\`) epäonnistui ennen worktreen luontia — feature-haara haarautuisi vanhentuneesta \`$REMOTE_NAME/main\`:sta. Tyypillisesti verkkokatko tai auth-ongelma. Tarkista yhteys — ajo yritetään uudelleen kun kommentoit issueen." \
         "$RUN_DIR/origin-fetch.log" blocked log
       _add_needs_human_label
       exit 5 ;;
  esac

  # create_worktree fails fast rather than branching off a wrong base. Its exit
  # code identifies WHICH failure so we attribute the block correctly (issue
  # #34 — one code made every failure look like a missing <remote>/HEAD and
  # printed the wrong fix): 2 = base ref unresolved (issue #27), 3 = leftover
  # branch from a previous run of this issue, 4 = other `git worktree add`
  # failure whose cause we do not name. The stderr captured into worktree_log
  # carries git's real error for cases 3 and 4.
  local worktree_log="$RUN_DIR/worktree-create.log"
  local worktree_rc=0
  WORKTREE_PATH=$(create_worktree "$REPO_ROOT" "$RUN_ID" "$BRANCH" "$BASE_BRANCH" "$REMOTE_NAME" 2>"$worktree_log") || worktree_rc=$?
  if [ "$worktree_rc" -ne 0 ]; then
    case "$worktree_rc" in
      2)
        log "S4: create_worktree failed — base ref unresolved; see $worktree_log"
        state_finalize "$RUN_DIR" "blocked" "worktree_base_unresolved"
        state_event "$RUN_DIR" "worktree_create_failed" "phase=S4" "remote=$REMOTE_NAME" "reason=base_unresolved"
        _post_situation_to_issue "worktree_base_unresolved" \
          "Worktreen base-haaraa ei voitu ratkaista ennen worktreen luontia — feature-haara olisi haarautunut väärästä commitista. Yleisin syy: \`$REMOTE_NAME/HEAD\` puuttuu kloonista (\`git remote add\` ei aseta sitä, vain \`git clone\`). Korjaus on lokissa nimetyllä komennolla, tai aseta \`base_branch\` repon \`.claude/run-issues.json\`:iin. Kun korjaus on tehty, kommentoi issueen — ajo yritetään uudelleen." \
          "$worktree_log" blocked log
        ;;
      3)
        log "S4: create_worktree failed — leftover branch '$BRANCH' from a previous run; see $worktree_log"
        state_finalize "$RUN_DIR" "blocked" "worktree_leftover_branch"
        state_event "$RUN_DIR" "worktree_create_failed" "phase=S4" "remote=$REMOTE_NAME" "reason=leftover_branch"
        _post_situation_to_issue "worktree_leftover_branch" \
          "Worktreen luonti epäonnistui: paikallinen haara \`$BRANCH\` on jäänne saman issuen edellisestä ajosta. Suljettu PR (\`gh pr close --delete-branch\`) poistaa vain remote-haaran, joten paikallinen jää. Kommentoi issueen niin ajo siivotaan ja yritetään uudelleen automaattisesti — tai siivoa käsin \`cleanup-run.sh --repo $REPO_ROOT --issue $ISSUE_NUM\`. Älä aja \`git remote set-head\`, se ei liity tähän." \
          "$worktree_log" blocked log
        ;;
      *)
        log "S4: create_worktree failed (rc=$worktree_rc) — 'git worktree add' error; see $worktree_log"
        state_finalize "$RUN_DIR" "blocked" "worktree_create_failed"
        state_event "$RUN_DIR" "worktree_create_failed" "phase=S4" "remote=$REMOTE_NAME" "reason=create_failed"
        _post_situation_to_issue "worktree_create_failed" \
          "Worktreen luonti epäonnistui (\`git worktree add\`) — base-haara ratkesi, joten syy on itse luonnissa (esim. olemassa oleva worktree-hakemisto, levytila tai oikeudet). Todellinen virhe on liitetyssä lokissa; en arvaa syytä sen yli. Korjaa este ja kommentoi issueen — ajo yritetään uudelleen." \
          "$worktree_log" blocked log
        ;;
    esac
    _add_needs_human_label
    exit 5
  fi
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
        "Tietokannan kloonaus epäonnistui (rc=$db_rc) ennen toteutusvaihetta. Tarkista DB-klooni-konfiguraatio ja palvelut — ajo yritetään uudelleen kun kommentoit issueen." \
        "$db_clone_log" blocked
      _add_needs_human_label
      exit 5
      ;;
  esac

  # ---------- S6: cycle review ----------
  run_cycle_review
}

# prepare_issue_images — download images embedded in the issue (body + comments)
# into <run-dir>/attachments/ and populate the ISSUE_IMAGES prompt block. Pure
# best-effort: any failure (auth/network/404/non-image) leaves ISSUE_IMAGES empty
# and the run proceeds in text mode, exactly like an issue with no images.
#
# The run dir is already gitignored (ensure_run_issues_gitignore covers
# .claude/run-issues/), so attachments never leak into the target repo. The gh
# token used for the download stays inside download_issue_images and is never
# logged or persisted. Called on every path that renders a prompt; the download
# is idempotent (reuses already-downloaded files), so the S6->S8 chain and the
# --resume/--restart/--continue re-runs do not re-fetch.
prepare_issue_images() {
  # Once per process: S6 (cycle-review) and S8 (implementer) both call this, but
  # the download must happen once. A separate --continue/--restart/--resume
  # process has this reset, so it re-evaluates the freshest issue.json.
  [ "$ISSUE_IMAGES_PREPARED" = "1" ] && return 0
  ISSUE_IMAGES_PREPARED=1

  ISSUE_IMAGES=""
  local issue_json="$RUN_DIR/issue.json"
  [ -f "$issue_json" ] || return 0
  local dest="$RUN_DIR/attachments"

  local paths
  paths=$(download_issue_images "$issue_json" "$dest" 2>>"$RUN_DIR/issue-images.log") || true
  [ -n "$paths" ] || return 0

  local -a arr=()
  while IFS= read -r p; do
    [ -n "$p" ] && arr+=("$p")
  done <<EOF
$paths
EOF
  [ "${#arr[@]}" -gt 0 ] || return 0

  ISSUE_IMAGES=$(build_issue_images_block "${arr[@]}")
  log "issue-images: prepared ${#arr[@]} image(s) for the prompt"
  state_event "$RUN_DIR" "issue_images_prepared" "count=${#arr[@]}" || true
}

# run_cycle_review — S6. Renders and runs the cycle-review prompt, parses the
# decision into CR_DECISION, and records it. Reads the optional global
# CLARIFICATION_CONTEXT: phase_a leaves it empty (the prompt section collapses);
# the --continue path fills it with the prior headline + the reply so the
# review is re-evaluated in light of the answer. This is the single cycle-review
# code path — there is no second one.
run_cycle_review() {
  enter_state "S6_CycleReview"
  log "S6_CycleReview"
  local repo_claude_md=""
  [ -f "$REPO_ROOT/CLAUDE.md" ] && repo_claude_md=$(cat "$REPO_ROOT/CLAUDE.md")

  # Download any embedded issue images so the cycle-review agent can Read them.
  prepare_issue_images

  local cr_prompt="$RUN_DIR/01-cycle-review.prompt"
  render_prompt \
    "$SCRIPT_DIR/prompts/01-cycle-review.md" \
    "$cr_prompt" \
    "ISSUE_BODY=$ISSUE_BODY" \
    "ISSUE_COMMENTS=$ISSUE_COMMENTS" \
    "ISSUE_IMAGES=$ISSUE_IMAGES" \
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
        # round) — the issue author answers again, the poller continues again, up to the cap.
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
          "Cycle review esti ajon tarkennuksen jälkeen (\`$reason\`). Tarkista issue ja korjaa este — ajo yritetään uudelleen kun kommentoit issueen." \
          "$cr_out" blocked
        exit 4
      fi
      _post_situation_to_issue "cycle_review_blocker" \
        "Cycle review esti ajon (\`$reason\`). Tarkista issue ja korjaa este — ajo yritetään uudelleen kun kommentoit issueen." \
        "$cr_out" blocked prose
      _add_needs_human_label
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
  BASE_BRANCH=$(jq -r '.base_branch // ""' "$rj")
  # Multi-remote: empty -> "origin" (legacy run.json predating the field).
  REMOTE_NAME=$(jq -r '.remote // "origin"' "$rj")
  OWNER_REPO=$(jq -r '.owner_repo // ""' "$rj")
  # Repo namespacing (issue #67): read the slug back verbatim and do NOT
  # re-derive it. Absent field = a run created before #67, whose lock, branch
  # and tmux session all carry the legacy repo-agnostic names; keeping the slug
  # empty means we address exactly those names instead of orphaning them.
  REPO_SLUG=$(jq -r '.repo_slug // ""' "$rj")

  if [ -z "$REPO_ROOT" ] || [ -z "$ISSUE_NUM" ] || [ -z "$WORKTREE_PATH" ]; then
    echo "orchestrate: incomplete run.json (missing repo/issue_number/worktree_path)" >&2
    exit 1
  fi

  # Re-derive OWNER_REPO if missing from a legacy run.json (best-effort: an
  # unparseable URL leaves it empty, which is the correct legacy fallback).
  if [ -z "$OWNER_REPO" ] && [ "$REMOTE_NAME" != "origin" ]; then
    resolve_owner_repo
  fi

  local issue_json="$RUN_DIR/issue.json"
  if [ ! -f "$issue_json" ]; then
    log "issue.json missing in $RUN_DIR — re-fetching from GitHub"
    fetch_issue_json "$REPO_ROOT" "$ISSUE_NUM" "$OWNER_REPO" "$REMOTE_NAME" > "$issue_json"
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
  BASE_BRANCH=$(jq -r '.base_branch // ""' "$rj")
  REMOTE_NAME=$(jq -r '.remote // "origin"' "$rj")
  OWNER_REPO=$(jq -r '.owner_repo // ""' "$rj")
  # Repo namespacing (issue #67): read the slug back verbatim and do NOT
  # re-derive it. Absent field = a run created before #67, whose lock, branch
  # and tmux session all carry the legacy repo-agnostic names; keeping the slug
  # empty means we address exactly those names instead of orphaning them.
  REPO_SLUG=$(jq -r '.repo_slug // ""' "$rj")
  local prior_status retry_count
  prior_status=$(jq -r '.status // ""' "$rj")
  retry_count=$(jq -r '.retry_count // 0' "$rj")

  if [ -z "$REPO_ROOT" ] || [ -z "$ISSUE_NUM" ] || [ -z "$WORKTREE_PATH" ]; then
    echo "orchestrate: incomplete run.json (missing repo/issue_number/worktree_path)" >&2
    exit 1
  fi

  # Backfill OWNER_REPO from REMOTE_NAME when a legacy run.json predates it.
  if [ -z "$OWNER_REPO" ] && [ "$REMOTE_NAME" != "origin" ]; then
    resolve_owner_repo
  fi

  # Only timed_out runs are restartable. Anything else is a usage error.
  if [ "$prior_status" != "timed_out" ]; then
    echo "orchestrate: --restart only applies to timed_out runs (status='$prior_status')" >&2
    exit 1
  fi

  # Take the per-issue lock for the duration of the restart.
  if ! lock_issue "$ISSUE_NUM" "$REMOTE_NAME" "$REPO_SLUG"; then
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
    _hand_to_human "Restart epäonnistui: worktree \`$WORKTREE_PATH\` on rikki tai puuttuu. Kommentoi issueen, niin ajo siivotaan ja yritetään uudelleen automaattisesti." "" blocked
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
    fetch_issue_json "$REPO_ROOT" "$ISSUE_NUM" "$OWNER_REPO" "$REMOTE_NAME" > "$issue_json"
  fi
  ISSUE_TITLE=$(jq -r '.title // ""' "$issue_json")
  ISSUE_BODY=$(jq -r '.body // ""' "$issue_json")
  ISSUE_COMMENTS=$(jq -r '[.comments[]? | "--- @\(.author.login // "?") @ \(.createdAt // "?")\n\(.body)"] | join("\n\n")' "$issue_json")

  # Refresh the chosen remote so RESTART_CONTEXT (git log <remote>/<base>..HEAD)
  # compares the branch against the real remote tip. Soft: a failed fetch only
  # risks a slightly stale comparison base — not worth blocking an in-flight run.
  local rfrc=0
  refresh_origin "$REPO_ROOT" "$REMOTE_NAME" 2>>"$RUN_DIR/origin-fetch.log" || rfrc=$?
  case "$rfrc" in
    0) state_event "$RUN_DIR" "origin_fetched" "phase=restart" "remote=$REMOTE_NAME" ;;
    2) state_event "$RUN_DIR" "origin_fetch_skipped" "phase=restart" "reason=no_origin" "remote=$REMOTE_NAME" ;;
    1) log "restart: 'git fetch $REMOTE_NAME' failed — RESTART_CONTEXT may use a stale $REMOTE_NAME/main (non-fatal)"
       state_event "$RUN_DIR" "origin_fetch_failed_soft" "phase=restart" "remote=$REMOTE_NAME" ;;
  esac

  # Restart context: the commits already on the feature branch so the
  # implementer continues from verification instead of starting over.
  # Diff against the SAME base the branch was cut from, so the restart context
  # lists only this run's own commits (not commits that diverged on the base).
  RESTART_CONTEXT=$(git -C "$WORKTREE_PATH" log --oneline "${REMOTE_NAME}/${BASE_BRANCH:-main}..HEAD" 2>/dev/null || true)
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
# Continue: resume an awaiting_clarification run after the issue author replied
# ===========================================================================
# continue_load_state — validates an awaiting_clarification run, takes the lock,
# checks the loop cap, validates the worktree, fetches the reply, increments
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
  BASE_BRANCH=$(jq -r '.base_branch // ""' "$rj")
  REMOTE_NAME=$(jq -r '.remote // "origin"' "$rj")
  OWNER_REPO=$(jq -r '.owner_repo // ""' "$rj")
  # Repo namespacing (issue #67): read the slug back verbatim and do NOT
  # re-derive it. Absent field = a run created before #67, whose lock, branch
  # and tmux session all carry the legacy repo-agnostic names; keeping the slug
  # empty means we address exactly those names instead of orphaning them.
  REPO_SLUG=$(jq -r '.repo_slug // ""' "$rj")
  local prior_status round
  prior_status=$(jq -r '.status // ""' "$rj")
  round=$(jq -r '.clarification_round // 0' "$rj")

  if [ -z "$REPO_ROOT" ] || [ -z "$ISSUE_NUM" ] || [ -z "$WORKTREE_PATH" ]; then
    echo "orchestrate: incomplete run.json (missing repo/issue_number/worktree_path)" >&2
    exit 1
  fi

  # Backfill OWNER_REPO from REMOTE_NAME when a legacy run.json predates it.
  if [ -z "$OWNER_REPO" ] && [ "$REMOTE_NAME" != "origin" ]; then
    resolve_owner_repo
  fi

  # Only awaiting_clarification runs are continuable. Anything else is a usage error.
  if [ "$prior_status" != "awaiting_clarification" ]; then
    echo "orchestrate: --continue only applies to awaiting_clarification runs (status='$prior_status')" >&2
    exit 1
  fi

  # Take the per-issue lock for the duration of the continue.
  if ! lock_issue "$ISSUE_NUM" "$REMOTE_NAME" "$REPO_SLUG"; then
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
    _hand_to_human "clarification-silmukka ei suppene $round kierroksen jälkeen. Cycle review tarvitsee yhä tarkennusta — tarkenna issue ja kommentoi, niin ajo yritetään uudelleen." \
      "$RUN_DIR/01-cycle-review.out" blocked
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
    _hand_to_human "Continue epäonnistui: worktree \`$WORKTREE_PATH\` on rikki tai puuttuu. Kommentoi issueen, niin ajo siivotaan ja yritetään uudelleen automaattisesti." "" blocked
    exit 0
  fi

  # Fetch the freshest issue payload and locate the human reply via the marker.
  local issue_json="$RUN_DIR/issue.json"
  fetch_issue_json "$REPO_ROOT" "$ISSUE_NUM" "$OWNER_REPO" "$REMOTE_NAME" > "$issue_json"

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

  # Refresh the chosen remote so the re-run cycle-review reasons against the
  # real remote tip. Soft: a failed fetch only means cycle-review sees a
  # possibly stale <remote>/main — not worth blocking a parked clarification run.
  local rfrc=0
  refresh_origin "$REPO_ROOT" "$REMOTE_NAME" 2>>"$RUN_DIR/origin-fetch.log" || rfrc=$?
  case "$rfrc" in
    0) state_event "$RUN_DIR" "origin_fetched" "phase=continue" "remote=$REMOTE_NAME" ;;
    2) state_event "$RUN_DIR" "origin_fetch_skipped" "phase=continue" "reason=no_origin" "remote=$REMOTE_NAME" ;;
    1) log "continue: 'git fetch $REMOTE_NAME' failed — cycle-review sees possibly stale $REMOTE_NAME/main (non-fatal)"
       state_event "$RUN_DIR" "origin_fetch_failed_soft" "phase=continue" "remote=$REMOTE_NAME" ;;
  esac

  # Build the clarification context fed into the re-run cycle-review prompt.
  # render_prompt substitutes in a single pass, so any {{...}} inside the
  # reply passes through verbatim (no placeholder injection).
  CLARIFICATION_CONTEXT="Aiempi tarkennuspyyntö (kierros $((new_round - 1))): cycle review palautti NEEDS_CLARIFICATION."$'\n\n'
  CLARIFICATION_CONTEXT+="Issuen kirjoittajan vastaus:"$'\n'"$answer"

  load_repo_timeout "$REPO_ROOT"
  log "continue: round=$new_round — re-running cycle review with the reply as context"
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
#   <headline>      1–3 Finnish sentences: WHAT happened + WHAT the human should do
#   <artifact-file> optional absolute path to attach
#   <awaitable>     answerability flavour; default "0" (not answerable). Any
#                   answerable flavour embeds a marker (build_marker) so a human
#                   reply can be tied back to this run by its timestamp:
#                     "clarification" (alias "1") — clarification loop: the reply
#                       resumes THIS run via --continue (poller scan_answered).
#                     "blocked"       — terminal blocked run (issue #57): the
#                       reply tears the run down and lets normal pickup retry it
#                       fresh (poller scan_blocked_answered). Different reply
#                       instruction because there is no --continue, a whole new
#                       run starts.
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
  # Runner-version (issue #32): the code version that produced this report. When
  # the running runner is a pinned submodule drifting behind origin/main, this
  # is the line that reveals it to whoever reads the report — not just to whoever
  # can ssh into the host. SCRIPT_DIR is the package root, not the target repo.
  body+="- Runner-version: \`$(runner_version_summary "$SCRIPT_DIR")\`"$'\n'

  case "$awaitable" in
    1|clarification|blocked)
      local marker
      marker=$(build_marker "$RUN_ID" "$ISSUE_NUM" "$(date -u +%FT%TZ)")
      # Marker first so the poller's scanner finds it deterministically at the top.
      body="${marker}"$'\n'"${body}"
      if [ "$awaitable" = "blocked" ]; then
        # Terminal block: a reply does NOT resume this run — it triggers a fresh
        # pickup after the poller tears this run down. Say so, so the human's
        # mental model matches ("comment when the blocker is gone → bot retries").
        body+=$'\n'"**Kun este on poistettu, kommentoi tähän issueen — ajo yritetään uudelleen automaattisesti (≤5 min).**"$'\n'
      else
        body+=$'\n'"**Vastaa tähän issueen kommentilla — Studio jatkaa automaattisesti (≤5 min).**"$'\n'
      fi
      ;;
  esac

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

  comment_issue "$REPO_ROOT" "$ISSUE_NUM" "$body" "$OWNER_REPO" "$REMOTE_NAME" || true
  state_event "$RUN_DIR" "situation_posted" "kind=${kind}" "awaitable=${awaitable}" || true
  return 0
}

# _gh_for_labels — choose the gh-invocation flavour for label management.
# Mirrors _issue_gh's per-org App scope-out: when REMOTE_NAME is origin we go
# through gha_with_token so labels are attributed to <app>[bot]; otherwise we
# fall back to plain gh (the App's installation token is per-org and would be
# the wrong credential for a non-origin remote). Keeps the label helpers tight.
_gh_for_labels() {
  case "$REMOTE_NAME" in
    ""|origin) gha_with_token gh "$@" ;;
    *)         gh "$@" ;;
  esac
}

# lib/labels.sh routes every label write through this same App-aware wrapper.
# Label mutations go via the REST API rather than `gh issue/pr edit`, which
# demands the read:project OAuth scope and failed silently for weeks — see the
# header of lib/labels.sh.
LABELS_GH_FN=_gh_for_labels

# _log_label_err — pipe target for label helpers: forward their diagnostics
# into the run log instead of /dev/null. Label management stays best-effort
# (every call site ends in `|| true`, since set -e + pipefail would otherwise
# turn a cosmetic label failure into a dead run), but "best-effort" must not
# mean "silent" — that is exactly how the read:project breakage hid for five
# weeks across 16 runs.
_log_label_err() {
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    log "$line"
  done
}

# _add_waiting_label / _remove_waiting_label — best-effort label management for
# the awaiting_clarification state. The `waiting` label keeps pick_oldest_candidate
# and the poller from re-picking the issue while it waits for a reply (both
# exclude -label:waiting). Failures are non-fatal.
_add_waiting_label() {
  ( cd "$REPO_ROOT" && labels_ensure "$OWNER_REPO" waiting FBCA04 \
      "Odottaa ihmisen vastausta — automaattinen ajo jatkaa kommentista" ) 2>&1 | _log_label_err || true
  ( cd "$REPO_ROOT" && labels_add "$OWNER_REPO" "$ISSUE_NUM" waiting ) 2>&1 | _log_label_err || true
}
_remove_waiting_label() {
  ( cd "$REPO_ROOT" && labels_remove "$OWNER_REPO" "$ISSUE_NUM" waiting ) 2>&1 | _log_label_err || true
}

# _finalize_awaiting_clarification — shared NEEDS_CLARIFICATION terminal path.
# Finalizes the run as awaiting_clarification, records the round + timestamp,
# attaches the waiting label, and posts an answerable situation comment (marker
# + reply prompt). The poller's scan_answered restarts via --continue once the
# issue author replies. Used by both the first NEEDS_CLARIFICATION (review_gate, IS_CONTINUE=0)
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
    "$cr_out" clarification prose
  state_event "$RUN_DIR" "awaiting_clarification" "round=$round"
}

# _add_needs_human_label — best-effort: ensure the needs-human label exists in
# the repo and is attached to the issue. Failures are non-fatal (the run is
# already finalized in run.json regardless). Shared by _hand_to_human and the
# env-bootstrap gate, which posts its own log-mode situation comment but still
# needs the same hand-off signal.
_add_needs_human_label() {
  ( cd "$REPO_ROOT" && labels_ensure "$OWNER_REPO" needs-human B60205 \
      "Vaatii ihmisen — automaattinen ajo ei onnistunut" ) 2>&1 | _log_label_err || true
  ( cd "$REPO_ROOT" && labels_add "$OWNER_REPO" "$ISSUE_NUM" needs-human ) 2>&1 | _log_label_err || true
}

# _hand_to_human <message> [<artifact-file>] [<awaitable>] — best-effort: post a
# full situation report and ensure the needs-human label is attached. All
# failures are non-fatal (the run is already finalized in run.json regardless).
# The artifact (when present) is implementer output, so render it as prose.
#
# <awaitable> defaults to "0" (not answerable) so the timed_out hand-offs
# (finalize_timeout, restart budget) keep their non-answerable comment — that
# path resumes via --restart, not a human reply. A terminal BLOCKED hand-off
# passes "blocked" so the comment carries a marker and a human reply re-triggers
# a fresh run (issue #57, poller scan_blocked_answered).
_hand_to_human() {
  local msg="$1"
  local artifact_file="${2:-}"
  local awaitable="${3:-0}"
  _post_situation_to_issue "needs_human" "$msg" "$artifact_file" "$awaitable" prose
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

  # The PR URL names its own repo and number, which beats cwd inference: it is
  # correct even when OWNER_REPO is empty (origin runs leave it so on purpose).
  # If the URL is not parseable we fall back to OWNER_REPO / cwd inference.
  local pr_repo pr_num
  pr_repo=$(labels_owner_repo_from_url "$pr")
  pr_num=$(labels_number_from_url "$pr")
  [ -n "$pr_repo" ] || pr_repo="$OWNER_REPO"
  [ -n "$pr_num" ] || pr_num="$pr"

  # Best-effort: ensure each label exists in the target repo before adding it.
  local lbl
  while IFS= read -r lbl; do
    [ -n "$lbl" ] || continue
    ( cd "$REPO_ROOT" && labels_ensure "$pr_repo" "$lbl" ) 2>&1 | _log_label_err || true
  done <<EOF
$(printf '%s' "$matched" | tr ',' '\n')
EOF

  local add_err add_rc=0
  add_err=$( ( cd "$REPO_ROOT" && labels_add "$pr_repo" "$pr_num" "$matched" ) 2>&1 >/dev/null ) || add_rc=$?
  if [ "$add_rc" -eq 0 ]; then
    log "propagate_pr_labels: added [$matched] to PR (issue #$ISSUE_NUM)"
    state_event "$RUN_DIR" "pr_labels_propagated" "labels=$matched"
  else
    # Log the CAUSE, not just the fact. The silent-failure mode this replaces
    # cost five weeks of un-merged PRs.
    log "propagate_pr_labels: adding [$matched] to PR failed (non-fatal — PR already created): $add_err"
    state_event "$RUN_DIR" "pr_labels_propagation_failed" "labels=$matched" || true
  fi
}

resume_cancel() {
  log "Resume cancelled at review gate"
  state_finalize "$RUN_DIR" "cancelled" "cancelled_at_gate"
  comment_issue "$REPO_ROOT" "$ISSUE_NUM" \
    "/run-issues peruutettu review-gate-vaiheessa. Worktree ja branch jätettiin paikoilleen: \`$WORKTREE_PATH\` ja \`$BRANCH\`. Voit jatkaa manuaalisesti tai poistaa nuo." \
    "$OWNER_REPO" "$REMOTE_NAME" \
    || true
  unclaim_issue "$REPO_ROOT" "$ISSUE_NUM" "$OWNER_REPO" || true
  exit 0
}

# commit_run_issues_gitignore — ensure the target repo's .gitignore ignores the
# /run-issues runtime artefacts (run-issues/, run-issues-archive/, worktrees/),
# committing the change on the feature branch so it lands in the PR. Run before
# the implementer so the run-dir artefacts are already ignored when the
# implementer stages files. Idempotent: on a restart/resume where the block is
# already present (and current) the helper reports no change and we skip the
# commit entirely. Best-effort — a .gitignore hiccup must not block the run.
commit_run_issues_gitignore() {
  [ -n "$WORKTREE_PATH" ] && [ -d "$WORKTREE_PATH" ] || return 0
  if ensure_run_issues_gitignore "$WORKTREE_PATH/.gitignore"; then
    (
      cd "$WORKTREE_PATH"
      git add .gitignore
      # Defensive: only commit when there is a staged delta. The helper writes
      # only on a content change, so this is normally always true.
      if ! git diff --cached --quiet; then
        sync_commit "chore: gitignore /run-issues runtime artifacts"
      fi
    ) || log "commit_run_issues_gitignore: .gitignore update failed (non-fatal)"
    state_event "$RUN_DIR" "gitignore_updated" || true
  fi
}

# ===========================================================================
# S7b: env bootstrap — fail-fast dependency install before the implementer
# ===========================================================================
# run_env_bootstrap — install the worktree's dependencies BEFORE the implementer
# so an environment obstacle (e.g. a missing GITHUB_TOKEN that breaks private
# @scope/* installs) surfaces as an immediate, diagnosable blocked run instead
# of a silent implementer timeout that burns the whole budget.
#
# Two ecosystems are handled INDEPENDENTLY, because a Bedrock-style WordPress
# repo carries both:
#   - PHP/Composer: a composer.lock at the worktree root -> `composer install`
#     (materializes vendor/ and the WP core under web/wp/).
#   - JS: a package.json (+ optional lockfile) -> pnpm/yarn/npm install.
# Neither precludes the other; whichever signals are present run.
#
#   neither present    -> no-op (the dotfiles repo itself hits this); proceed.
#   install succeeds   -> proceed to the implementer normally.
#   install fails      -> finalize blocked / env_bootstrap_failed, attach the
#                         needs-human label, post the install log to the issue,
#                         and exit 5 WITHOUT spending any implementer timeout.
#
# Runs on every path that reaches phase_b (start, --resume, --restart,
# --continue), so it is the single chokepoint before S8. Idempotent: both
# composer install and the JS install are safe to re-run on a restart.
run_env_bootstrap() {
  enter_state "S7b_EnvBootstrap"
  log "S7b_EnvBootstrap"

  local ran=0

  # PHP/Composer first: Bedrock-style repos need vendor/ and the WP core present
  # before anything else. Independent of the JS bootstrap below.
  if [ -n "$(detect_composer "$WORKTREE_PATH")" ]; then
    ran=1
    _run_env_install "composer" "$RUN_DIR/env-bootstrap-composer.log"
  fi

  # JS: pnpm/yarn/npm per the root lockfile (precedence pnpm > yarn > npm).
  local pm
  pm=$(detect_package_manager "$WORKTREE_PATH")
  if [ -n "$pm" ]; then
    ran=1
    _run_env_install "$pm" "$RUN_DIR/env-bootstrap.log"
  fi

  if [ "$ran" -eq 0 ]; then
    log "env-bootstrap: no package.json or composer.lock in $WORKTREE_PATH — no-op"
    state_event "$RUN_DIR" "env_bootstrap_skipped" "reason=nothing_to_install"
    return 0
  fi
}

# Wall-clock budget per env-bootstrap install (composer/pnpm/yarn/npm). A
# network/lock/auth hiccup used to hang the install forever and burn the whole
# implementer timeout budget silently (issue #49). With this budget the
# fail-fast gate actually fires: rc=124 -> env_bootstrap_timeout (distinct from
# rc!=0 env_bootstrap_failed so diagnosis stays separable in logs/issue
# comments). 1200s = 20 min is generous for cold pnpm/composer installs on a
# slow network but won't let a stuck process wedge the whole factory.
RUN_ISSUES_ENV_BOOTSTRAP_TIMEOUT="${RUN_ISSUES_ENV_BOOTSTRAP_TIMEOUT:-1200}"

# _resolve_env_bootstrap_timeout — same shape as claude-call.sh's
# _resolve_timeout. Prints the `timeout --kill-after=60 N` prefix, or empty if
# neither timeout nor gtimeout is available (then the install runs unbounded,
# which is the pre-fix behaviour — we WARN once to make the gap visible).
# Binary selection is delegated to preflight_timeout_bin (preflight.sh, sourced
# at the top of this script) so timeout/gtimeout detection lives in one place.
_resolve_env_bootstrap_timeout() {
  local tb
  tb=$(preflight_timeout_bin)
  if [ -n "$tb" ]; then
    printf '%s --kill-after=60 %s' "$tb" "$RUN_ISSUES_ENV_BOOTSTRAP_TIMEOUT"
  else
    printf ''
  fi
}

# _run_env_install <manager> <log-path> — run the dependency install for one
# ecosystem (composer | pnpm | yarn | npm), capturing all output to <log-path>.
# Shared by every branch of run_env_bootstrap so composer and JS get identical
# fail-fast semantics. Wrapped in timeout(1) with --kill-after=60 (same shape
# as claude-call.sh) so a hung install can't wedge the run forever.
#   rc == 0   -> emit env_bootstrap_ok and return.
#   rc == 124 -> finalize blocked / env_bootstrap_timeout, post the install log,
#                attach needs-human, exit 5 (no implementer budget spent).
#   rc != 0,124 -> finalize blocked / env_bootstrap_failed (same path; missing
#                  manager binary lands here as rc=127).
_run_env_install() {
  local manager="$1" boot_log="$2"
  log "env-bootstrap: detected $manager — installing dependencies (timeout=${RUN_ISSUES_ENV_BOOTSTRAP_TIMEOUT}s)"

  local timeout_prefix
  timeout_prefix=$(_resolve_env_bootstrap_timeout)
  [ -n "$timeout_prefix" ] \
    || log "WARNING: no timeout binary available (timeout/gtimeout) — env-bootstrap '$manager install' will run unbounded (install coreutils: brew install coreutils)"

  set +e
  (
    cd "$WORKTREE_PATH"
    # shellcheck disable=SC2086
    case "$manager" in
      composer) $timeout_prefix composer install ;;
      pnpm)     $timeout_prefix pnpm install ;;
      yarn)     $timeout_prefix yarn install ;;
      npm)      $timeout_prefix npm install ;;
    esac
  ) > "$boot_log" 2>&1
  local boot_rc=$?
  set -e

  if [ "$boot_rc" -eq 124 ]; then
    log "env-bootstrap: '$manager install' timed out after ${RUN_ISSUES_ENV_BOOTSTRAP_TIMEOUT}s — finalizing blocked (no implementer budget spent)"
    state_finalize "$RUN_DIR" "blocked" "env_bootstrap_timeout"
    state_event "$RUN_DIR" "env_bootstrap_timeout" "pm=$manager" "timeout=$RUN_ISSUES_ENV_BOOTSTRAP_TIMEOUT"
    local detail
    detail="Riippuvuuksien asennus ($manager) aikakatkesi (${RUN_ISSUES_ENV_BOOTSTRAP_TIMEOUT}s) ennen toteutusvaihetta. Yleisin syy on jumiutunut paketinhallinta-lukko, hidas/jumahtava verkkoyhteys (Packagist/npm-registry/GitHub Packages) tai vialliset auth-tokenit. Tarkista asennusloki ja koneellinen env-tiedosto — ajo yritetään uudelleen kun kommentoit issueen. Asennusloki (kesken jäänyt) alla."
    _post_situation_to_issue "env_bootstrap_timeout" "$detail" "$boot_log" blocked log
    _add_needs_human_label
    exit 5
  fi

  if [ "$boot_rc" -ne 0 ]; then
    log "env-bootstrap: '$manager install' failed (rc=$boot_rc) — finalizing blocked (no implementer budget spent)"
    state_finalize "$RUN_DIR" "blocked" "env_bootstrap_failed"
    state_event "$RUN_DIR" "env_bootstrap_failed" "pm=$manager" "rc=$boot_rc"
    local detail
    if [ "$manager" = "composer" ]; then
      detail="Composer-riippuvuuksien asennus epäonnistui ennen toteutusvaihetta (rc=$boot_rc). Bedrockin riippuvuudet ovat yleensä julkisia (Packagist), mutta jos kohderepossa on yksityisiä Composer-paketteja, tarvitaan GITHUB_TOKEN kuten JS-puolella — tarkista koneellinen env-tiedosto. Asennusvirhe alla."
    else
      detail="Riippuvuuksien asennus ($manager) epäonnistui ennen toteutusvaihetta (rc=$boot_rc). Yleisin syy on puuttuva GITHUB_TOKEN yksityisille @scope/*-paketeille — tarkista koneellinen env-tiedosto. Asennusvirhe alla."
    fi
    # Post the install log in log-mode (monospace) — it is tool output, not prose.
    detail+=" Korjaa este ja kommentoi issueen — ajo yritetään uudelleen automaattisesti."
    _post_situation_to_issue "env_bootstrap_failed" "$detail" "$boot_log" blocked log
    _add_needs_human_label
    exit 5
  fi

  log "env-bootstrap: '$manager install' succeeded"
  state_event "$RUN_DIR" "env_bootstrap_ok" "pm=$manager"
}

# ===========================================================================
# S7c: per-run test-env provisioning hook (opt-in, target-repo owned)
# ===========================================================================
# run_provision_test_env — run the target repo's opt-in provisioning hook
# (<worktree>/.claude/provision-test-env.sh) so a run gets whatever external
# resources its tests need — a migrated test database, a Redis instance, an
# object-store stub — provisioned automatically, with run-id isolation so two
# concurrent runs never share state. This generalizes the db-clone pattern: the
# project owns the project-specific logic (migration command, connection-string
# shape); the orchestrator stays generic.
#
# Contract (see provision-test-env.README.md):
#   - invoked as `provision-test-env.sh provision <run-id>` with the worktree
#     root as CWD (so e.g. `pnpm prisma` resolves the schema path and the
#     node_modules S7b just installed);
#   - <run-id> is the MANDATORY isolation key — the hook derives resource names
#     from it (e.g. test_<run-id>) so concurrent runs do not collide;
#   - the hook prints `KEY=VALUE` lines to stdout; the orchestrator injects them
#     into the implementer's environment. Diagnostics go to stderr (or any
#     non-KEY=VALUE stdout line, which is ignored);
#   - static credentials (Postgres host/user/password) come from the existing
#     machine-local env file (source_machine_env), never from the committed hook.
#
#   no hook / not executable -> no-op (benign skip), proceed.
#   hook succeeds            -> collect KEY=VALUE, record keys in run.json,
#                               proceed to the implementer.
#   hook fails (rc != 0)     -> finalize blocked / provision_test_env_failed,
#                               attach needs-human, post the log to the issue,
#                               exit 5 WITHOUT spending any implementer budget.
#
# Runs on every path that reaches phase_b (start, --resume, --restart,
# --continue) right after S7b, so it is the single chokepoint where node_modules
# are present but the implementer has not yet started. Idempotent: a restart
# re-runs the hook, which (per contract) reuses or recreates the run-id-keyed
# resource rather than provisioning a second one.
run_provision_test_env() {
  enter_state "S7c_ProvisionTestEnv"
  log "S7c_ProvisionTestEnv"
  PROVISION_TEST_ENV_PAIRS=""

  local hook="$WORKTREE_PATH/.claude/provision-test-env.sh"
  if [ ! -x "$hook" ]; then
    log "provision-test-env: no executable hook at $hook — no-op"
    state_event "$RUN_DIR" "provision_test_env_skipped" "reason=no_hook"
    return 0
  fi

  log "provision-test-env: running hook with run-id $RUN_ID"
  local prov_stdout="$RUN_DIR/provision-test-env.stdout"
  local prov_stderr="$RUN_DIR/provision-test-env.stderr"
  local prov_log="$RUN_DIR/provision-test-env.log"
  set +e
  (
    cd "$WORKTREE_PATH"
    "$hook" provision "$RUN_ID"
  ) > "$prov_stdout" 2> "$prov_stderr"
  local prov_rc=$?
  set -e

  # Combined log for the failure comment: both streams, clearly separated.
  {
    echo "# provision-test-env.sh provision $RUN_ID (rc=$prov_rc)"
    echo "## stdout"
    cat "$prov_stdout"
    echo "## stderr"
    cat "$prov_stderr"
  } > "$prov_log"

  if [ "$prov_rc" -ne 0 ]; then
    log "provision-test-env: hook failed (rc=$prov_rc) — finalizing blocked (no implementer budget spent)"
    state_finalize "$RUN_DIR" "blocked" "provision_test_env_failed"
    state_event "$RUN_DIR" "provision_test_env_failed" "rc=$prov_rc"
    _post_situation_to_issue "provision_test_env_failed" \
      "Testiympäristön provisiointi (\`.claude/provision-test-env.sh\`) epäonnistui ennen toteutusvaihetta (rc=$prov_rc). Tyypillisesti puuttuva tai väärä tietokantayhteys/migraatio — tarkista koneellinen env-tiedosto ja hookin loki alla. Korjaa este ja kommentoi issueen — ajo yritetään uudelleen." \
      "$prov_log" blocked log
    _add_needs_human_label
    exit 5
  fi

  # Parse KEY=VALUE lines from stdout ONLY (stderr is diagnostics). A line counts
  # as an injection only when its key is a valid shell env-var name — anything
  # else (prose diagnostics that happened to land on stdout) is ignored.
  local injected_keys="" line key
  while IFS= read -r line; do
    case "$line" in
      [A-Za-z_]*=*)
        key="${line%%=*}"
        if printf '%s' "$key" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$'; then
          PROVISION_TEST_ENV_PAIRS+="${line}"$'\n'
          injected_keys="${injected_keys:+$injected_keys,}$key"
        fi
        ;;
    esac
  done < "$prov_stdout"

  # Persist the injected key NAMES (never the values — they may carry secrets such
  # as a connection-string password) so teardown knows provisioning ran and what
  # was injected. A non-empty value gates cleanup-run.sh's hook teardown; if the
  # hook provisioned a resource without emitting any keys we still mark it so the
  # resource gets torn down. The run-id is the teardown handle, not these keys.
  state_set "$RUN_DIR" "provision_test_env" "${injected_keys:-provisioned}"
  state_event "$RUN_DIR" "provision_test_env_ok" "keys=${injected_keys:-none}"
  log "provision-test-env: injected keys [${injected_keys:-none}]"
}

# ===========================================================================
# Phase B: implementer → evolution → PR
# ===========================================================================
phase_b() {
  # ---------- S7b: env bootstrap (fail-fast dep install) ----------
  run_env_bootstrap

  # ---------- S7c: per-run test-env provisioning (opt-in hook) ----------
  # After S7b so the hook can rely on installed node_modules (e.g. pnpm prisma).
  run_provision_test_env

  # ---------- S8: implementer ----------
  enter_state "S8_Implementer"
  commit_run_issues_gitignore
  log "S8_Implementer"
  local cr_out="$RUN_DIR/01-cycle-review.out"
  local cr_full=""
  [ -f "$cr_out" ] && cr_full=$(cat "$cr_out")

  # Download any embedded issue images so the implementer can Read them. On the
  # normal/continue path cycle-review already downloaded them; this reuses the
  # files. On --resume/--restart (cycle-review not re-run) this is the download.
  prepare_issue_images

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
    "ISSUE_IMAGES=$ISSUE_IMAGES" \
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
    # Inject the per-run provisioned test-env vars (run-id-isolated) so the
    # implementer's test run sees e.g. DATABASE_URL_TEST. Empty on the no-op path.
    if [ -n "$PROVISION_TEST_ENV_PAIRS" ]; then
      while IFS= read -r _kv; do
        [ -n "$_kv" ] && export "$_kv"
      done <<PROVISION_ENV
$PROVISION_TEST_ENV_PAIRS
PROVISION_ENV
    fi
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
        "Toteutusvaihe (implementer) jäi jumiin eikä tuottanut valmista tulosta. Tarkista alla oleva tuloste ja issuen vaatimukset — ajo yritetään uudelleen kun kommentoit issueen." \
        "$imp_out" blocked prose
      _add_needs_human_label
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

  # When App mode is on AND the remote is origin, push as the App via
  # `git -c http.extraheader=...` so the commit's pusher event (and any GitHub
  # Actions triggered by it) is attributed to <app>[bot]. The header value is
  # captured into a LOCAL variable that we never echo to stdout/stderr, and the
  # `git -c` flag keeps the token out of .git/config (unlike `git remote
  # set-url` with a tokenised URL, which would persist the secret). For
  # non-origin remotes we skip the App header (per-org App scope-out — the
  # token is minted for the wrong org) and let the credential helper handle
  # auth.
  local _push_auth_header=""
  local _gha_hdr=""
  if [ "$REMOTE_NAME" = "origin" ] && _gha_hdr=$(gha_git_push_header 2>/dev/null); then
    _push_auth_header="$_gha_hdr"
  fi
  _gha_hdr=""
  set +e
  if [ -n "$_push_auth_header" ]; then
    (
      cd "$WORKTREE_PATH"
      # Quoting matters: $_push_auth_header contains a space. Pass it as one
      # token via -c "http.extraheader=..."; do not let the shell split it.
      git -c "http.extraheader=$_push_auth_header" push --set-upstream "$REMOTE_NAME" "$BRANCH"
    ) >> "$RUN_DIR/git-push.log" 2>&1
  else
    (
      cd "$WORKTREE_PATH"
      git push --set-upstream "$REMOTE_NAME" "$BRANCH"
    ) >> "$RUN_DIR/git-push.log" 2>&1
  fi
  local push_rc=$?
  set -e
  # Belt-and-braces: scrub the header value from memory after the push.
  # The `git -c` invocation already kept it out of .git/config; this just
  # ensures no later `env`/`set` dump in this process can echo it.
  _push_auth_header=""
  if [ "$push_rc" -ne 0 ]; then
    log "git push failed (rc=$push_rc)"
    state_finalize "$RUN_DIR" "blocked" "git_push_failed"
    _post_situation_to_issue "git_push_failed" \
      "Toteutus valmistui, mutta haaran push GitHubiin epäonnistui (rc=$push_rc). Tarkista push-loki ja remote-oikeudet — ajo yritetään uudelleen kun kommentoit issueen." \
      "$RUN_DIR/git-push.log" blocked
    _add_needs_human_label
    exit 6
  fi

  # Target the opt-in base branch when set; empty -> repo default (backward
  # compatible). Unquoted on the command line so an empty flag disappears,
  # mirroring $pr_draft_flag.
  local base_flag=""
  [ -n "$BASE_BRANCH" ] && base_flag="--base $BASE_BRANCH"

  local pr_url=""
  set +e
  # `gh pr create` is routed via _gh_for_labels so the PR's author is the App
  # for origin and the personal account for non-origin (per-org App scope-out).
  # The repo flag pins it to the source remote's org so a non-origin remote
  # opens the PR there instead of in origin's repo.
  pr_url=$(
    cd "$REPO_ROOT"
    # shellcheck disable=SC2046
    _gh_for_labels pr create \
      $(_repo_args "$OWNER_REPO") \
      --head "$BRANCH" \
      $base_flag \
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
      "Haara pushattiin, mutta pull requestin avaaminen epäonnistui. Tarkista alla oleva gh-loki ja avaa PR tarvittaessa käsin — ajo yritetään uudelleen kun kommentoit issueen." \
      "$RUN_DIR/gh-pr-create.log" blocked
    _add_needs_human_label
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
    run_cycle_review     # re-run S6 with the reply as context
    review_gate          # PROCEED -> phase_b; NEEDS_CLARIFICATION -> exit 11; BLOCKER -> human
    phase_b
    ;;
esac

exit 0
