#!/usr/bin/env bash
# action-dispatch.sh — the five Ohjaamo actions, each a thin shell over an
# existing script or label (issue #77).
#
# The action SERVICE (lib/action-service.py) never touches gh, labels or the
# orchestrator itself: it authenticates the caller and then execve's THIS script
# with the resolved run identifiers. That split is what makes security model
# rule 5 ("always delegate to an existing script or label") STRUCTURAL rather
# than a convention — Python cannot fake a delegation it has no code path to.
#
#   stop         -> stop-run.sh --run-dir <dir> --yes         (worktree/branch kept)
#   clean        -> auto-clean label on the issue; the poller tears it down
#   reset        -> auto-reset label on the issue; the poller tears it down and
#                   leaves the issue OPEN, so pickup starts the run over
#   allow-merge  -> auto-merge label on the PR; pr-watch does the rest
#   resume       -> timed_out run: orchestrate.sh --restart <dir> (detached tmux)
#                   otherwise:     remove the needs-human label (un-hold the run)
#
# No new teardown / merge / restart logic lives here: every branch is a call to
# a script or the REST label helpers, and a delegate that is missing or fails is
# reported verbatim (rule 5) — this script never "fixes it up" itself.
#
# Usage:
#   action-dispatch.sh <action> [selectors]
#     stop         --run-dir <dir>
#     clean        --repo <path> --issue <N> [--owner <o/r>]
#     reset        --repo <path> --issue <N> [--owner <o/r>]
#     allow-merge  --repo <path> --pr <N>    [--owner <o/r>]
#     resume       --repo <path> --issue <N> [--owner <o/r>] [--run-dir <dir>]
#                  [--remote <name>] [--repo-slug <slug>]
#
# Exit codes (own space — not the orchestrator's, not stop-run's):
#   0  delegated command succeeded
#   1  usage error (unknown action / missing or malformed selector)
#   2  delegated command FAILED — its output is on stdout/stderr for the caller
#      to surface as-is (rule 5: show the error, do not retry)
#   3  a delegate is unavailable (script not found, tmux missing for a restart)
#
# Run: action-dispatch.sh stop --run-dir <dir>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/labels.sh
. "$SCRIPT_DIR/lib/labels.sh"
# shellcheck source=lib/git-remote.sh
. "$SCRIPT_DIR/lib/git-remote.sh"

# git-remote.sh enables errexit (`set -euo pipefail`) at source time; re-disable
# it so a delegate exiting non-zero reaches our own `|| exit 2` handling (rule 5:
# surface the failure) instead of aborting the script with the delegate's code.
set +e

die_usage() { printf 'action-dispatch: %s\n' "$1" >&2; exit 1; }

CLEAN_LABEL="${RUN_ISSUES_CLEAN_LABEL:-auto-clean}"
RESET_LABEL="${RUN_ISSUES_RESET_LABEL:-auto-reset}"
MERGE_LABEL="${PR_WATCH_MERGE_LABEL:-auto-merge}"

# ---- parse: <action> then flag/value pairs ----
[ "$#" -ge 1 ] || die_usage "no action given"
ACTION="$1"; shift

RUN_DIR=""
REPO_ROOT=""
OWNER_REPO=""
ISSUE=""
PR=""
REMOTE=""
REPO_SLUG=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-dir)   RUN_DIR="${2:-}"; shift 2 ;;
    --repo)      REPO_ROOT="${2:-}"; shift 2 ;;
    --owner)     OWNER_REPO="${2:-}"; shift 2 ;;
    --issue)     ISSUE="${2:-}"; shift 2 ;;
    --pr)        PR="${2:-}"; shift 2 ;;
    --remote)    REMOTE="${2:-}"; shift 2 ;;
    --repo-slug) REPO_SLUG="${2:-}"; shift 2 ;;
    *) die_usage "unknown flag '$1'" ;;
  esac
done

# A positive-integer guard shared by --issue / --pr.
_require_number() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# ---- action: stop ----
# stop-run.sh owns every safety gate (host, terminal status, exact tmux kill)
# and leaves worktree/branch/run-dir intact. We only pass --run-dir and --yes.
action_stop() {
  [ -n "$RUN_DIR" ] || die_usage "stop needs --run-dir"
  local stop="$SCRIPT_DIR/stop-run.sh"
  [ -x "$stop" ] || { printf 'action-dispatch: stop-run.sh not found or not executable\n' >&2; exit 3; }
  "$stop" --run-dir "$RUN_DIR" --yes
  local rc=$?
  [ "$rc" -eq 0 ] || exit 2
  exit 0
}

# ---- action: clean ----
# Add the auto-clean label; the poller's scan_clean tears the run down with all
# its safety gates. We do not clean anything here (rule 5).
action_clean() {
  _require_number "$ISSUE" || die_usage "clean needs --issue <N>"
  ( [ -n "$REPO_ROOT" ] && cd "$REPO_ROOT" 2>/dev/null || cd "$SCRIPT_DIR"
    labels_add "$OWNER_REPO" "$ISSUE" "$CLEAN_LABEL" )
  local rc=$?
  [ "$rc" -eq 0 ] || exit 2
  exit 0
}

# ---- action: reset ----
# Add the auto-reset label; the poller's reset scan tears the run down with the
# SAME safety gates as clean and leaves the issue open. Sibling of action_clean
# down to the line, and for the same reason (rule 5): nothing is torn down here.
action_reset() {
  _require_number "$ISSUE" || die_usage "reset needs --issue <N>"
  ( [ -n "$REPO_ROOT" ] && cd "$REPO_ROOT" 2>/dev/null || cd "$SCRIPT_DIR"
    labels_add "$OWNER_REPO" "$ISSUE" "$RESET_LABEL" )
  local rc=$?
  [ "$rc" -eq 0 ] || exit 2
  exit 0
}

# ---- action: allow-merge ----
# Add the auto-merge label to the PR; pr-watch does the merge (and, if enabled,
# conflict/CI repair). REST treats a PR as an issue for labelling.
action_allow_merge() {
  _require_number "$PR" || die_usage "allow-merge needs --pr <N>"
  ( [ -n "$REPO_ROOT" ] && cd "$REPO_ROOT" 2>/dev/null || cd "$SCRIPT_DIR"
    labels_add "$OWNER_REPO" "$PR" "$MERGE_LABEL" )
  local rc=$?
  [ "$rc" -eq 0 ] || exit 2
  exit 0
}

# ---- action: resume ----
# Two delegations, chosen by the run's own recorded status:
#   timed_out -> orchestrate.sh --restart <run-dir>, launched DETACHED in a tmux
#                session named exactly as the poller names its restart sessions
#                (session_suffix), so the orchestrator's lock and status.sh's
#                session_alive probe both recognise it. The HTTP request returns
#                as soon as tmux detaches.
#   otherwise -> remove the needs-human label, un-holding a blocked/ci-repair run
#                so the poller/watcher re-arms it on the next tick.
action_resume() {
  local status=""
  if [ -n "$RUN_DIR" ] && [ -f "$RUN_DIR/run.json" ]; then
    status="$(jq -r '.status // empty' "$RUN_DIR/run.json" 2>/dev/null || echo "")"
  fi

  if [ "$status" = "timed_out" ]; then
    local orch="$SCRIPT_DIR/orchestrate.sh"
    [ -x "$orch" ] || { printf 'action-dispatch: orchestrate.sh not found\n' >&2; exit 3; }
    command -v tmux >/dev/null 2>&1 || { printf 'action-dispatch: tmux not available — cannot launch a detached restart\n' >&2; exit 3; }
    _require_number "$ISSUE" || die_usage "resume of a timed_out run needs --issue <N>"
    local suffix session
    suffix="$(session_suffix "${REMOTE:-origin}" "$ISSUE" "$REPO_SLUG")"
    session="run-issues-restart-${suffix}"
    # Pass the command as SEPARATE argv elements, not a single shell string:
    # given multiple arguments tmux execvp's them directly instead of running
    # `sh -c`, so RUN_DIR (which originates from the HTTP request body) cannot
    # break out of quoting into a command. `env` sets the variable without a
    # shell. -d detaches immediately; the orchestrator's own per-issue lock
    # prevents a double-run, and a duplicate session name makes tmux fail fast.
    if tmux new-session -d -s "$session" \
        env RUN_ISSUES_AUTO=1 "$orch" --restart "$RUN_DIR"; then
      printf 'restart launched (tmux session %s)\n' "$session"
      exit 0
    fi
    printf 'action-dispatch: could not start restart session %s (already running?)\n' "$session" >&2
    exit 2
  fi

  # Non-timed_out: remove the needs-human hold label.
  _require_number "$ISSUE" || die_usage "resume needs --issue <N>"
  ( [ -n "$REPO_ROOT" ] && cd "$REPO_ROOT" 2>/dev/null || cd "$SCRIPT_DIR"
    labels_remove "$OWNER_REPO" "$ISSUE" "needs-human" )
  local rc=$?
  [ "$rc" -eq 0 ] || exit 2
  exit 0
}

case "$ACTION" in
  stop)        action_stop ;;
  clean)       action_clean ;;
  reset)       action_reset ;;
  allow-merge) action_allow_merge ;;
  resume)      action_resume ;;
  *) die_usage "unknown action '$ACTION' (want: stop|clean|reset|allow-merge|resume)" ;;
esac
