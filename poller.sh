#!/usr/bin/env bash
# poller.sh — host-gated auto-run poller for /run-issues.
#
# Iterates the watchlist (RUN_ISSUES_WATCHLIST, else
# $HOME/.config/run-issues/watchlist.json, else the legacy dotfiles path), and
# for each repo with at least one unclaimed issue that matches the
# configured labels, launches a DETACHED tmux session running
# `orchestrate.sh` in auto mode.
#
# This script must be safe to run multiple times in parallel — the
# per-issue lock in lib/locking.sh prevents double-runs, and tmux
# session names are unique per issue (so the second one fails fast).
#
# StartInterval in the LaunchAgent: 300s.

set -euo pipefail

# --- Configuration resolution ------------------------------------------------
# The order below is load-bearing and documented in
# docs/diagrams/poller-config-resolution.mmd.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The package root. Read from the environment ONLY (never from poller.env),
# because it must be known before any file is sourced. It exists as a test
# injection point, the way RUN_ISSUES_CLAUDE_HOME does for install.sh — in
# normal use SCRIPT_DIR is already correct and nobody needs to set this.
RUN_ISSUES_HOME="${RUN_ISSUES_HOME:-$SCRIPT_DIR}"

# shellcheck source=lib/poller-config.sh
. "${RUN_ISSUES_HOME}/lib/poller-config.sh"

# rotate_log_if_big (issue #65). Sourced here — before the exec redirect below —
# because rotating .stdout.log/.stderr.log AFTER their fds are opened would leave
# the fd writing to the moved inode. Defines one function; no top-level work.
# shellcheck source=lib/log-rotate.sh
. "${RUN_ISSUES_HOME}/lib/log-rotate.sh"

# rate_limit_* (issue #126). Sourced here so the backoff gate below can run
# before the first gh call of the tick. Defines functions only; no top-level work.
# shellcheck source=lib/rate-limit.sh
. "${RUN_ISSUES_HOME}/lib/rate-limit.sh"

# Machine configuration. launchd hands an agent no environment of its own and
# the login files hold nothing run-issues-specific, so this file is the only
# channel through which a machine can configure its pollers. It is sourced, so
# the FILE WINS over an inherited environment variable — the same idiom
# pr-watch.sh uses for its own env file.
#
# Deliberately not ~/.config/run-issues/env: that file holds secrets, which the
# orchestrator and the watcher source themselves. A poller needs none of them,
# and it logs copiously.
POLLER_ENV_FILE="${RUN_ISSUES_POLLER_ENV_FILE:-${HOME}/.config/run-issues/poller.env}"
if [ -f "$POLLER_ENV_FILE" ]; then
  set +eu
  # shellcheck disable=SC1090
  . "$POLLER_ENV_FILE"
  set -eu
fi

# Host gate. Bail out silently on a machine that was never configured to run
# the pollers, so that deploying the LaunchAgent somewhere else does nothing.
# This runs BEFORE any path is created: an unknown host must not so much as
# make a log directory.
HOST=$(hostname -s)
THIS_HOST="$HOST"
poller_host_allowed "$HOST" "${RUN_ISSUES_POLLER_HOSTS:-$POLLER_HOSTS_LEGACY_DEFAULT}" || exit 0

LOG_DIR="${RUN_ISSUES_LOG_DIR:-${HOME}/Library/Logs}"
mkdir -p "$LOG_DIR"
LOG="${LOG_DIR}/run-issues-poller.log"
RUNS_LOG="${LOG_DIR}/run-issues-poller.runs.log"

# Size-based log rotation (issue #65). At the start of the tick, before the first
# write and before the exec redirect below, rotate any of the four log files that
# has grown past RUN_ISSUES_LOG_MAX_BYTES (default 10 MB; 0 disables). One .1
# generation is kept. The .stdout/.stderr rotation MUST precede the exec below.
RUN_ISSUES_LOG_MAX_BYTES="${RUN_ISSUES_LOG_MAX_BYTES:-10485760}"
rotate_log_if_big "$LOG"                                    "$RUN_ISSUES_LOG_MAX_BYTES"
rotate_log_if_big "$RUNS_LOG"                               "$RUN_ISSUES_LOG_MAX_BYTES"
rotate_log_if_big "${LOG_DIR}/run-issues-poller.stdout.log" "$RUN_ISSUES_LOG_MAX_BYTES"
rotate_log_if_big "${LOG_DIR}/run-issues-poller.stderr.log" "$RUN_ISSUES_LOG_MAX_BYTES"

# The plists carry no StandardOutPath/StandardErrorPath keys, because launchd
# performs no variable expansion in them. The poller therefore owns all four of
# its log paths itself. Not on a TTY: a manual run must still print.
if [ ! -t 1 ]; then
  exec >>"${LOG_DIR}/run-issues-poller.stdout.log" 2>>"${LOG_DIR}/run-issues-poller.stderr.log"
fi

# The pre-package layout. A fallback only — never a primary path — so that a
# machine whose watchlist still lives in the dotfiles tree keeps working.
LEGACY_DOTFILES_DIR="${HOME}/dotfiles"

ORCH="${RUN_ISSUES_HOME}/orchestrate.sh"

WATCHLIST_CONFIG="${HOME}/.config/run-issues/watchlist.json"
WATCHLIST_LEGACY="${LEGACY_DOTFILES_DIR}/machine-studio/run-issues-watchlist.json"
WATCHLIST_TRIED="${RUN_ISSUES_WATCHLIST:-${WATCHLIST_CONFIG}, ${WATCHLIST_LEGACY}}"

# preflight_have is the shared command-presence probe (lib/preflight.sh) behind
# the gh/jq/tmux checks below, so tool detection lives in one place. Sourced
# here — after the host gate, right before its first use — and unguarded like
# the poller's other libs: a lib that failed to resolve must fail loudly, not
# limp on with `command not found` deep inside a scan. Pure functions, no
# top-level work.
# shellcheck source=lib/preflight.sh
. "${RUN_ISSUES_HOME}/lib/preflight.sh"

# Hard requirements; bail fast if anything is missing.
WATCHLIST=$(poller_resolve_watchlist "${RUN_ISSUES_WATCHLIST:-}" "$WATCHLIST_CONFIG" "$WATCHLIST_LEGACY") \
  || { echo "$(date -u +%FT%TZ) poller: watchlist missing, tried: $WATCHLIST_TRIED" >> "$LOG"; exit 0; }
[ -x "$ORCH" ]      || { echo "$(date -u +%FT%TZ) poller: orchestrator not executable at $ORCH" >> "$LOG"; exit 0; }
preflight_have gh     || { echo "$(date -u +%FT%TZ) poller: gh not in PATH" >> "$LOG"; exit 0; }
preflight_have jq     || { echo "$(date -u +%FT%TZ) poller: jq not in PATH" >> "$LOG"; exit 0; }
preflight_have tmux   || { echo "$(date -u +%FT%TZ) poller: tmux not in PATH" >> "$LOG"; exit 0; }

if ! jq -e . "$WATCHLIST" >/dev/null 2>&1; then
  echo "$(date -u +%FT%TZ) poller: watchlist is not valid JSON" >> "$LOG"
  exit 0
fi

GLOBAL_MAX=$(jq -r '.global_max_concurrent // 2' "$WATCHLIST")
# The raw watchlist-wide default. The fallback chain that turns it (and the per
# repo `labels`) into the pickup label set lives in poller_pick_labels, so the
# built-in `auto-run` default is not spelled out a second time here.
DEFAULT_LABELS=$(jq -r '(.default_labels // []) | map(select(type == "string" and length > 0)) | join(",")' "$WATCHLIST")
RUN_ISSUES_MAX_RETRIES="${RUN_ISSUES_MAX_RETRIES:-1}"
RUN_ISSUES_MAX_CLARIFICATIONS="${RUN_ISSUES_MAX_CLARIFICATIONS:-3}"
RUN_ISSUES_CLEAN_LABEL="${RUN_ISSUES_CLEAN_LABEL:-auto-clean}"
# Liveness threshold for scan_stalled: if state.jsonl's last event timestamp
# (or run.json.started_at as fallback) is older than this, the run is treated
# as stalled — its tmux session is killed and the run finalized as
# blocked/stalled_in_<current_state>. The bound MUST exceed the longest
# legitimate single-phase claude call so a slow-but-progressing run is not
# killed mid-flight; the default 3600s aligns with claude-call.sh's own
# timeout (after which it finalizes via finalize_timeout and writes an event,
# resetting the staleness clock).
RUN_ISSUES_STALE_AFTER="${RUN_ISSUES_STALE_AFTER:-3600}"
AUTO_CLEAN="${RUN_ISSUES_HOME}/auto-clean.sh"
# cleanup-run.sh tears down a run WITHOUT closing the issue — the retry path for
# an answered blocked run (issue #57) uses it, not auto-clean.sh (which closes).
CLEANUP="${RUN_ISSUES_HOME}/cleanup-run.sh"

# The four libs below are sourced UNGUARDED on purpose. A `[ -f ] && .` guard
# does not abort under `set -e`, so a lib that failed to resolve used to make
# the poller run on without parse_marker, state_finalize, session_suffix or
# labels_add, and surface as `command not found` deep inside a scan. Sourcing
# unguarded fails where the fault actually is.

# parse_marker / detect_answer / fetch_issue_json live in lib/issue.sh; the
# poller needs them for scan_answered. Sourcing is safe — lib/issue.sh only
# defines functions, no top-level work.
LIB_ISSUE="${RUN_ISSUES_HOME}/lib/issue.sh"
# shellcheck source=lib/issue.sh
. "$LIB_ISSUE"

# gha_with_token / gha_enabled live in lib/github-app-auth.sh. Sourcing this
# DEFINES the App-identity wrapper so pick_oldest_candidate, epic_list_open and
# scan_clean's label read route their per-tick LIST reads through the App's rate
# limit instead of maintainer's personal one (issue #127) — the whole reason the runner
# gets its own quota. It is a benign no-op without App config: gha_enabled reads
# the RUN_ISSUES_GITHUB_APP_* env vars at CALL time (not source time, so this
# reads no secret), and returns 1 unless they are set AND the private key is
# readable, in which case gha_with_token passes straight through to bare gh —
# bit-for-bit the pre-#127 behaviour. The App identity vars reach the poller via
# poller.env (identity config, NOT the key itself — the .pem stays a 0600 file
# referenced by path; see examples/run-issues-poller.env.example). Function-only,
# no top-level work; safe to source.
LIB_GHA="${RUN_ISSUES_HOME}/lib/github-app-auth.sh"
# shellcheck source=lib/github-app-auth.sh
. "$LIB_GHA"

# state_finalize / state_event are sourced from lib/state.sh — finalize_stalled
# writes run.json + state.jsonl directly (the orchestrator process is dead by
# the time we tap the session, so there is no other code path to delegate to).
# Pure functions, no top-level work, safe to source.
LIB_STATE="${RUN_ISSUES_HOME}/lib/state.sh"
# shellcheck source=lib/state.sh
. "$LIB_STATE"

# remote_label / session_suffix / repo_slug / resolve_remote_to_owner_repo live
# in lib/git-remote.sh. Used by the (repo × remote) iteration to derive owner/repo
# for `gh --repo` routing and the repo-namespaced tmux session / lock names.
# Pure functions; safe to source.
LIB_GIT_REMOTE="${RUN_ISSUES_HOME}/lib/git-remote.sh"
# shellcheck source=lib/git-remote.sh
. "$LIB_GIT_REMOTE"

# labels_add / labels_ensure live in lib/labels.sh — REST-based label writes
# that do not need the read:project OAuth scope `gh issue edit` demands.
# Pure functions; safe to source.
LIB_LABELS="${RUN_ISSUES_HOME}/lib/labels.sh"
# shellcheck source=lib/labels.sh
. "$LIB_LABELS"

# runner_version / runner_behind_origin / runner_fetch_throttled report which
# runner version is actually executing (issue #32). Pure functions; safe to
# source. Used by the tick-start version banner below.
LIB_VERSION="${RUN_ISSUES_HOME}/lib/version.sh"
# shellcheck source=lib/version.sh
. "$LIB_VERSION"

# _iso_to_epoch lives in lib/status-read.sh (issue #59): status.sh and the
# poller must agree bit-for-bit on how a timestamp becomes epoch seconds, so
# scan_stalled's liveness clock and status.sh's idle_seconds share one
# definition. Pure function + jq-program constants; no top-level work.
LIB_STATUS_READ="${RUN_ISSUES_HOME}/lib/status-read.sh"
# shellcheck source=lib/status-read.sh
. "$LIB_STATUS_READ"

# run_terminate is the safe live-run teardown extracted from finalize_stalled
# (issue #63) so a future stop-run.sh can reuse it without duplicating a
# safety-critical path. finalize_stalled below is now a thin caller. The lib is
# function-only and pulls in its own deps, so sourcing it is safe.
LIB_RUN_TERMINATE="${RUN_ISSUES_HOME}/lib/run-terminate.sh"
# shellcheck source=lib/run-terminate.sh
. "$LIB_RUN_TERMINATE"

# epic_list_open / epic_process_one live in lib/epic.sh (issue #81): the epic
# scan phase below propagates auto-run to an epic's children, escalates stalled
# children to the epic, and announces completion — all idempotently. Pure
# functions (pulls in its own issue.sh/labels.sh deps); safe to source.
LIB_EPIC="${RUN_ISSUES_HOME}/lib/epic.sh"
# shellcheck source=lib/epic.sh
. "$LIB_EPIC"

# _running_session_name <prefix> <remote> <repo-slug> <issue>
# Prints the name of an existing tmux session for this (repo, remote, issue) and
# returns 0, or returns 1 when none is running.
#
# Two names are probed (issue #67): the repo-namespaced one this poller version
# spawns, and the legacy repo-agnostic one a session started by the PREVIOUS
# version still carries. Missing the legacy name would be the worst possible
# failure of the rollout — the poller would consider the issue free, take a
# repo-namespaced lock nobody else holds, and run a SECOND orchestrator against
# a live run. `=` forces an exact tmux target match so `run-issues-3` cannot
# prefix-match `run-issues-34`.
_running_session_name() {
  local prefix="$1" remote="$2" slug="$3" issue="$4"
  local s name
  for s in "$(session_suffix "$remote" "$issue" "$slug")" "$(session_suffix "$remote" "$issue")"; do
    name="${prefix}${s}"
    if tmux has-session -t "=$name" 2>/dev/null; then
      printf '%s' "$name"
      return 0
    fi
  done
  return 1
}

# scan_stalled <repo-path> — prints "<issue-number> <run-dir>" lines for runs
# on THIS host whose structural progress has stopped advancing for more than
# RUN_ISSUES_STALE_AFTER seconds. "Structural progress" = state.jsonl's last
# event timestamp; falls back to run.json.started_at when state.jsonl is empty
# (so a run that crashed before its first event is still detectable).
#
# Only the in-progress (status=initialized) runs are stallable. Terminal
# statuses are already finalized; awaiting_review and awaiting_clarification
# wait for documented human action by contract and must NOT be killed under the
# human's feet. Host-gated (same convention as scan_timed_out/scan_answered/
# scan_clean) — a foreign machine's live session is never touched. Pure: no
# tmux kill, no gh call — just selection. The caller (finalize_stalled) does
# the side effects under its own log line.
#
# Multi-remote: scan_stalled does NOT filter by remote — a stalled run on ANY
# remote should be finalized regardless. The run.json .remote field is read by
# finalize_stalled to build the right namespaced tmux session names to kill.
scan_stalled() {
  local repo_path="$1"
  local runs_dir="$repo_path/.claude/run-issues"
  [ -d "$runs_dir" ] || return 0
  local now stale_after rj status host inum rd jsonl last_ts last_epoch age
  now=$(date -u +%s)
  stale_after="${RUN_ISSUES_STALE_AFTER:-3600}"
  shopt -s nullglob
  for rj in "$runs_dir"/*/run.json; do
    # jq's `// "initialized"` default treats a stray null/missing as in-progress
    # — defensive, but only the explicit initialized case proceeds (everything
    # else falls into the catch-all skip).
    status=$(jq -r '.status // "initialized"' "$rj" 2>/dev/null || echo "")
    case "$status" in
      initialized) ;;
      *) continue ;;
    esac
    host=$(jq -r '.host // ""' "$rj" 2>/dev/null || echo "")
    # Empty host = pre-host-field run.json; treat as local (best effort).
    if [ -n "$host" ] && [ "$host" != "$THIS_HOST" ]; then
      continue
    fi
    rd=$(dirname "$rj")
    jsonl="$rd/state.jsonl"
    # Prefer the last state.jsonl event ts (structural progress). Empty file ->
    # fall back to run.json.started_at so a crash-on-init run is still caught.
    last_ts=""
    if [ -s "$jsonl" ]; then
      last_ts=$(tail -n 1 "$jsonl" 2>/dev/null | jq -r '.ts // empty' 2>/dev/null || echo "")
    fi
    [ -n "$last_ts" ] || last_ts=$(jq -r '.started_at // empty' "$rj" 2>/dev/null || echo "")
    [ -n "$last_ts" ] || continue   # nothing comparable — leave it alone
    last_epoch=$(_iso_to_epoch "$last_ts")
    [ -n "$last_epoch" ] || continue
    age=$(( now - last_epoch ))
    [ "$age" -gt "$stale_after" ] || continue
    inum=$(jq -r '.issue_number // empty' "$rj" 2>/dev/null || echo "")
    [ -n "$inum" ] && printf '%s %s\n' "$inum" "$rd"
  done
  # Return 0 regardless: callers capture this in a command substitution under
  # `set -e`, where a trailing-false branch would otherwise abort the caller.
  return 0
}

# finalize_stalled <issue-number> <run-dir> — terminate a stalled run.
#
# Thin wrapper over run_terminate (lib/run-terminate.sh, issue #63): the actual
# teardown — host gate, exact tmux kill, blocked/<reason> finalize + event,
# best-effort needs-human label + situation comment, lock release from the run's
# own recorded identity — lives there so a future stop-run.sh can reuse it. Here
# we only compute the stalled reason (`stalled_in_<current_state>`) and delegate.
# run_terminate reads the issue number from run.json itself, so $1 is unused.
#
# After finalization the run carries terminal status=blocked + label
# needs-human, so subsequent scan_timed_out/scan_answered/scan_stalled passes
# will NOT re-pick it (terminal status). run_terminate deliberately leaves the
# assignment AND the auto-claimed reservation label in place (issue #99), so
# pick_oldest_candidate keeps skipping the issue (-label:auto-claimed) until a
# cleanup releases the reservation — a stalled run stays reserved, exactly as it
# did under the old no:assignee reservation.
finalize_stalled() {
  local run_dir="$2"
  # run_terminate is sourced at the top of poller.sh; the guard here is for the
  # stale-detection test, which extracts this function in isolation and evals it
  # without sourcing the lib. In the poller the guard is always a no-op.
  if ! declare -F run_terminate >/dev/null 2>&1; then
    # shellcheck source=lib/run-terminate.sh
    . "${RUN_ISSUES_HOME:-.}/lib/run-terminate.sh"
  fi
  local current_state
  current_state=$(jq -r '.current_state // "unknown"' "$run_dir/run.json" 2>/dev/null || echo "unknown")
  run_terminate "$run_dir" "stalled_in_${current_state}" "stalled"
}

# scan_timed_out <repo-path> [<remote>] — prints "<issue-number> <run-dir>"
# lines for timed_out runs on THIS host that still have retry budget. Modelled
# on pr-watch.sh's scan_candidates: iterate run.json files, gate on host so we
# never restart a worktree that lives on another machine.
#
# Multi-remote: when <remote> is provided, only emit runs whose run.json
# .remote field matches (empty remote in run.json is treated as "origin", so
# legacy runs are picked up by the default origin iteration). When <remote> is
# omitted (legacy single-arg call), no remote filter is applied — every local
# timed-out run is emitted regardless of remote.
scan_timed_out() {
  local repo_path="$1"
  local want_remote="${2:-}"
  local runs_dir="$repo_path/.claude/run-issues"
  [ -d "$runs_dir" ] || return 0
  local rj status host retry inum rem
  shopt -s nullglob
  for rj in "$runs_dir"/*/run.json; do
    status=$(jq -r '.status // ""' "$rj" 2>/dev/null || echo "")
    [ "$status" = "timed_out" ] || continue
    host=$(jq -r '.host // ""' "$rj" 2>/dev/null || echo "")
    # Empty host = pre-host-field run.json; treat as local (best effort).
    if [ -n "$host" ] && [ "$host" != "$THIS_HOST" ]; then
      continue
    fi
    if [ -n "$want_remote" ]; then
      rem=$(jq -r '.remote // "origin"' "$rj" 2>/dev/null || echo "origin")
      [ "$rem" = "$want_remote" ] || continue
    fi
    retry=$(jq -r '.retry_count // 0' "$rj" 2>/dev/null || echo 0)
    [ "$retry" -lt "$RUN_ISSUES_MAX_RETRIES" ] || continue
    inum=$(jq -r '.issue_number // empty' "$rj" 2>/dev/null || echo "")
    [ -n "$inum" ] && printf '%s %s\n' "$inum" "$(dirname "$rj")"
  done
  # See scan_answered: return 0 so a trailing-false `&&` cannot abort a caller
  # that captures the output in a command substitution under `set -e`.
  return 0
}

# scan_answered <repo-path> [<remote>] [<owner/repo>] — prints
# "<issue-number> <run-dir>" lines for awaiting_clarification runs on THIS host
# that (a) still have clarification budget and (b) have a fresh human reply on
# the issue. Sibling of scan_timed_out with the same host gate. Kept cheap: it
# only hits the network (fetch_issue_json + parse_marker + detect_answer) for
# LOCAL runs that are actually parked — never a blanket scan of all issues.
#
# Multi-remote: when <remote> is provided, only emit runs whose run.json
# .remote field matches, and route the gh fetch through `gh --repo owner/repo`
# so the right org's API is queried. When omitted, behaves like the legacy
# single-arg version (no remote filter, gh inferred from cwd).
scan_answered() {
  local repo_path="$1"
  local want_remote="${2:-}"
  local owner_repo="${3:-}"
  local runs_dir="$repo_path/.claude/run-issues"
  [ -d "$runs_dir" ] || return 0
  local rj status host round inum repo marker_ts answer rem effective_remote
  shopt -s nullglob
  for rj in "$runs_dir"/*/run.json; do
    status=$(jq -r '.status // ""' "$rj" 2>/dev/null || echo "")
    [ "$status" = "awaiting_clarification" ] || continue
    host=$(jq -r '.host // ""' "$rj" 2>/dev/null || echo "")
    # Empty host = pre-host-field run.json; treat as local (best effort).
    if [ -n "$host" ] && [ "$host" != "$THIS_HOST" ]; then
      continue
    fi
    if [ -n "$want_remote" ]; then
      rem=$(jq -r '.remote // "origin"' "$rj" 2>/dev/null || echo "origin")
      [ "$rem" = "$want_remote" ] || continue
      effective_remote="$want_remote"
    else
      effective_remote="origin"
    fi
    round=$(jq -r '.clarification_round // 0' "$rj" 2>/dev/null || echo 0)
    [ "$round" -lt "$RUN_ISSUES_MAX_CLARIFICATIONS" ] || continue
    inum=$(jq -r '.issue_number // empty' "$rj" 2>/dev/null || echo "")
    [ -n "$inum" ] || continue
    repo=$(jq -r '.repo // empty' "$rj" 2>/dev/null || echo "")
    [ -n "$repo" ] || repo="$repo_path"

    # Network: only for this local, parked run. Find the marker, then a reply.
    local issue_json
    issue_json=$(fetch_issue_json "$repo" "$inum" "$owner_repo" "$effective_remote" 2>>"${RUN_ISSUES_GH_ERR:-/dev/null}" || true)
    [ -n "$issue_json" ] || continue
    local tmp_json
    tmp_json=$(mktemp)
    printf '%s' "$issue_json" > "$tmp_json"
    marker_ts=$(parse_marker "$tmp_json" | sed -n 's/.*ts=\([^ ]*\).*/\1/p')
    if [ -z "$marker_ts" ]; then rm -f "$tmp_json"; continue; fi
    answer=$(detect_answer "$tmp_json" "$marker_ts")
    rm -f "$tmp_json"
    [ -n "$answer" ] && printf '%s %s\n' "$inum" "$(dirname "$rj")"
  done
  # Return 0 regardless of the last iteration's test: callers may capture this
  # in a command substitution under `set -e`, where a trailing-false `&&` would
  # otherwise abort the caller.
  return 0
}

# scan_blocked_answered <repo-path> [<remote>] [<owner/repo>] — sibling of
# scan_answered for TERMINAL blocked runs (issue #57). Prints
# "<issue-number> <run-dir>" for blocked runs on THIS host whose issue is still
# OPEN and carries a human reply AFTER the run's awaiting-answer marker.
#
# The difference from scan_answered is the mental model, not the plumbing:
#   - status == "blocked" (not awaiting_clarification), and no round cap — the
#     loop guard is structural, not a counter. A reply tears the run down and
#     lets normal pickup start a WHOLE NEW run from a fresh base (a blocked run's
#     worktree is typically branched before the merge that cleared the blocker,
#     so resuming it would build on stale work). If the blocker is still there
#     the new run blocks again and posts a NEW marker, so one reply => at most
#     one retry.
#   - the issue must be OPEN. A blocked run whose issue was closed is done — we
#     never resurrect it. State comes from the SAME fetch used for the marker.
#
# Same host/remote gate and the same parse_marker/detect_answer pair as
# scan_answered. A legacy blocked run finalized before this change carries no
# marker, so parse_marker returns empty and it is skipped silently — never a
# per-tick error or log line.
scan_blocked_answered() {
  local repo_path="$1"
  local want_remote="${2:-}"
  local owner_repo="${3:-}"
  local runs_dir="$repo_path/.claude/run-issues"
  [ -d "$runs_dir" ] || return 0
  local rj status host inum repo marker_ts answer rem effective_remote issue_state
  shopt -s nullglob
  for rj in "$runs_dir"/*/run.json; do
    status=$(jq -r '.status // ""' "$rj" 2>/dev/null || echo "")
    [ "$status" = "blocked" ] || continue
    host=$(jq -r '.host // ""' "$rj" 2>/dev/null || echo "")
    # Empty host = pre-host-field run.json; treat as local (best effort).
    if [ -n "$host" ] && [ "$host" != "$THIS_HOST" ]; then
      continue
    fi
    if [ -n "$want_remote" ]; then
      rem=$(jq -r '.remote // "origin"' "$rj" 2>/dev/null || echo "origin")
      [ "$rem" = "$want_remote" ] || continue
      effective_remote="$want_remote"
    else
      effective_remote="origin"
    fi
    inum=$(jq -r '.issue_number // empty' "$rj" 2>/dev/null || echo "")
    [ -n "$inum" ] || continue
    repo=$(jq -r '.repo // empty' "$rj" 2>/dev/null || echo "")
    [ -n "$repo" ] || repo="$repo_path"

    # Network: only for this local, blocked run. One fetch yields state + comments.
    local issue_json
    issue_json=$(fetch_issue_json "$repo" "$inum" "$owner_repo" "$effective_remote" 2>>"${RUN_ISSUES_GH_ERR:-/dev/null}" || true)
    [ -n "$issue_json" ] || continue
    local tmp_json
    tmp_json=$(mktemp)
    printf '%s' "$issue_json" > "$tmp_json"
    # Closed issue -> the run is done for good; never resurrect it. `state` from
    # fetch_issue_json is "OPEN"/"CLOSED"; a missing field (mocked/old gh) is
    # treated as OPEN so the marker/answer gate still decides.
    issue_state=$(jq -r '.state // "OPEN"' "$tmp_json" 2>/dev/null || echo "OPEN")
    if [ "$issue_state" != "OPEN" ]; then rm -f "$tmp_json"; continue; fi
    marker_ts=$(parse_marker "$tmp_json" | sed -n 's/.*ts=\([^ ]*\).*/\1/p')
    if [ -z "$marker_ts" ]; then rm -f "$tmp_json"; continue; fi
    answer=$(detect_answer "$tmp_json" "$marker_ts")
    rm -f "$tmp_json"
    [ -n "$answer" ] && printf '%s %s\n' "$inum" "$(dirname "$rj")"
  done
  # Return 0 regardless (see scan_answered): callers capture this under `set -e`.
  return 0
}

# scan_clean <repo-path> [<remote>] [<owner/repo>] — prints UNIQUE
# "<issue-number> <repo-path>" lines for issues that (a) have at least one
# LOCAL run-dir on THIS host (filtered by remote when provided) and (b)
# currently carry the RUN_ISSUES_CLEAN_LABEL but NOT auto-clean-skipped.
#
# Two phases keep network use minimal (the same discipline as scan_answered):
#   Phase 1 — collect the unique set of issue numbers that have a local run-dir
#             matching the (host, remote) gate. No network.
#   Phase 2 — ONE REST label query for the whole repo, then intersect against
#             phase 1 locally (issue #124, moved to REST by issue #133). The query
#             routes through _issue_gh (issue #127): a per-tick per-repo LIST read
#             whose volume belongs on the App's rate limit, not maintainer's personal
#             one. Identity does not change the label set it returns.
#
# Phase 2 used to be one `gh issue view` PER unique local issue. That made the
# cost O(historical run-dirs) rather than O(work): measured at 337 GraphQL calls
# per tick across the Studio watchlist (~4000/hour from this function alone),
# which is what exhausted the shared GitHub quota on 2026-08-28 and stalled all
# 18 repos for over ten hours. Asking about the LABEL instead of about every
# issue makes it O(1) per repo while the answer stays identical: the label list
# comes from the issues connection (authoritative), NOT the eventually-consistent
# search index, and auto-clean-skipped is read from the same payload.
#
# `--state all` is REQUIRED. A clean target is frequently already closed (PR
# merged => issue auto-closed => run-dir still on disk; the Ohjaamo "Siivoa"
# button targets exactly those). `--state open` would drop them silently —
# measured 2026-08-29: every auto-clean-labelled issue in the org was closed.
#
# TRUNCATION. gh caps the list at --limit rows, and past that the list is no
# longer proof of ABSENCE. Every local issue the list did not cover is therefore
# resolved with the old targeted `gh issue view`, and a WARNING names the repo.
# Without that fallback the fast path would be a SILENT correctness regression:
# a truncated list would read as "nothing to clean" exactly when there is
# something to clean. The ceiling is real rather than theoretical because the
# label is never removed after a successful clean, so it accumulates on closed
# issues (measured 2026-08-29: a production repo 100, claude-issue-runner 29).
# bash 3.2 has no associative arrays, so both the unique set and the label map
# are temp files.
scan_clean() {
  local repo_path="$1"
  local want_remote="${2:-}"
  local owner_repo="${3:-}"
  local runs_dir="$repo_path/.claude/run-issues"
  [ -d "$runs_dir" ] || return 0

  local rj host inum rem
  local seen
  seen=$(mktemp)

  # Phase 1: collect unique LOCAL issue numbers (host-gated, remote-gated).
  shopt -s nullglob
  for rj in "$runs_dir"/*/run.json; do
    host=$(jq -r '.host // ""' "$rj" 2>/dev/null || echo "")
    # Empty host = pre-host-field run.json; treat as local (best effort).
    if [ -n "$host" ] && [ "$host" != "$THIS_HOST" ]; then
      continue
    fi
    if [ -n "$want_remote" ]; then
      rem=$(jq -r '.remote // "origin"' "$rj" 2>/dev/null || echo "origin")
      [ "$rem" = "$want_remote" ] || continue
    fi
    inum=$(jq -r '.issue_number // empty' "$rj" 2>/dev/null || echo "")
    [ -n "$inum" ] && printf '%s\n' "$inum" >> "$seen"
  done

  # Nothing local to intersect (every run-dir belongs to another host or to
  # another remote) => no network at all. Without this guard the repo-wide label
  # query below would ADD a call to repos that previously made none.
  if [ ! -s "$seen" ]; then
    rm -f "$seen"
    return 0
  fi

  # Phase 2: ONE label query for the whole repo. The owner/repo is baked into the
  # REST path (_rest_issues_path) so a non-origin remote hits the right org's API;
  # an empty owner/repo falls back to gh's {owner}/{repo} placeholders, which it
  # substitutes from the cwd's remote.
  local limit="${RUN_ISSUES_CLEAN_SCAN_LIMIT:-200}"
  local labelled rows truncated page chunk got
  truncated=0
  labelled=$(mktemp)
  # REST, not `gh issue list --label` (issue #133): a FILTERED gh issue list
  # routes through GitHub's GraphQL search connection, which was blocked for 27
  # hours on 2026-08-28/29 while REST answered normally. Issue #124 had moved
  # this query from `gh issue view` (unfiltered, unaffected) onto that blocked
  # path as a side effect of collapsing 337 calls into one — the call-count win
  # stands, but the one remaining call has to leave the search connection too.
  #
  # Pagination is explicit and BOUNDED rather than `gh api --paginate`: the
  # label is never removed after a successful clean, so it accumulates on closed
  # issues (measured 2026-08-29: a production repo carried 100 of them), and an
  # unbounded walk would grow without limit for a signal whose live set is
  # nearly always empty.
  page=1
  rows=0
  : > "$labelled"
  while [ "$rows" -lt "$limit" ]; do
    chunk=$(
      cd "$repo_path"
      _issue_gh --remote "$want_remote" -- api "$(_rest_issues_path "$owner_repo" "labels=${RUN_ISSUES_CLEAN_LABEL}&state=all&per_page=100&page=${page}")" \
        --jq '.[] | select(.pull_request == null) | "\(.number)\t\([.labels[].name] | join(","))"' \
        2>>"${RUN_ISSUES_GH_ERR:-/dev/null}"
    ) || break
    [ -n "$chunk" ] || break
    printf '%s\n' "$chunk" >> "$labelled"
    got=$(printf '%s\n' "$chunk" | grep -c .) || got=0
    rows=$((rows + got))
    [ "$got" -lt 100 ] && break
    page=$((page + 1))
  done
  if [ "$rows" -ge "$limit" ] 2>/dev/null; then
    truncated=1
    printf '%s scan_clean: WARNING %s carries >= %s "%s" issues — list truncated, falling back to per-issue reads for uncovered runs\n' \
      "$(date -u +%FT%TZ)" "${owner_repo:-$repo_path}" "$limit" "$RUN_ISSUES_CLEAN_LABEL" >&2
  fi

  local n labels tab
  tab=$(printf '\t')
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if grep -q "^${n}${tab}" "$labelled"; then
      labels=$(sed -n "s/^${n}${tab}//p" "$labelled" | head -1)
    elif [ "$truncated" -eq 1 ]; then
      # Absence is not proof while the list is truncated — ask about this one.
      labels=$(
        cd "$repo_path"
        _issue_gh --remote "$want_remote" -- api "$(_rest_issue_path "$owner_repo" "$n")" \
          --jq '[.labels[].name] | join(",")' 2>>"${RUN_ISSUES_GH_ERR:-/dev/null}" || echo ""
      )
    else
      # The list is complete and does not mention this issue => not labelled.
      continue
    fi
    # auto-clean-skipped wins: already handed to a human, never re-emit.
    case ",$labels," in
      *,auto-clean-skipped,*) continue ;;
    esac
    case ",$labels," in
      *,"$RUN_ISSUES_CLEAN_LABEL",*) printf '%s %s\n' "$n" "$repo_path" ;;
    esac
  done < <(sort -u "$seen")

  rm -f "$seen" "$labelled"
  # Return 0 regardless: callers capture this in a command substitution under
  # `set -e`, where a trailing-false branch would otherwise abort the caller.
  return 0
}

# _finished_log <message> — scan_finished's per-decision trace. Issue #107 AC7:
# every gate decision must be CHECKABLE from the log rather than inferred from a
# missing line, because "nothing was reconciled" and "the gate blocked it" look
# identical otherwise. Writes to $LOG (the tick log an operator actually reads)
# when the poller set one, and to stderr otherwise — the tests source the
# extracted function with no $LOG.
_finished_log() {
  local msg
  msg="$(date -u +%FT%TZ) scan_finished: $1"
  if [ -n "${LOG:-}" ]; then
    printf '%s\n' "$msg" >> "$LOG"
  else
    printf '%s\n' "$msg" >&2
  fi
}

# scan_finished <repo-path> [<remote>] [<owner/repo>] — prints
# "<issue-number> <run-dir>" lines for THIS HOST's runs whose issue is
# CONFIRMED closed on GitHub and which clear every safety gate (issue #107).
#
# WHY THIS EXISTS. pr-watch.sh ties teardown to the merge ACT, not the merge
# STATE: it runs cleanup only in the branch where the watcher itself performed
# the merge (P9). Every other route to a merge — the other machine's watcher,
# GitHub's web UI, a hand-run `gh pr merge`, a repo starved by the rotation
# cursor (#47) — leaves the run-dir, worktree and branch behind, and since #65
# leaves them behind SILENTLY (a repeated SKIP_CLOSED writes no event). A run
# that never got a PR at all is not even in the watcher's scan, which requires a
# non-empty pr_url. Measured on Studio 2026-08-24: 331 runs, 314 classified
# `cleanup`, 309 worktrees still on disk totalling 166.9 GB.
#
# The class was already correct — #96 and #103 made the situation READABLE. What
# was missing is an actuator wired to the diagnosis. This is that actuator, and
# it deliberately owns no teardown logic: it decides WHICH runs are finished and
# delegates the HOW to cleanup-run.sh, exactly as scan_clean delegates to
# auto-clean.sh.
#
# NOT auto-clean. Reconciliation is routine maintenance, not an event: it posts
# no comment, writes no label, and NEVER closes an issue — it reacts to a close,
# so causing one would make the signal self-fulfilling. 300+ comments would be
# worse than the problem they announce.
#
# GATES (all mandatory, all fail-closed — a gate that cannot be evaluated skips
# the run rather than tearing it down):
#   G1 live run        — status == "initialized" is an ACTIVE run. Covers "issue
#                        closed by hand while the run is still working".
#   G2 foreign host    — run.json.host != THIS_HOST. The system's clearest
#                        safety boundary; never crossed.
#   G3 issue not closed— open, or state unreadable.
#   G4 open PR         — the run's PR is still OPEN. The worktree is the PR
#                        watcher's tool; an issue can be closed by hand before
#                        its PR merges.
#   G5 unpushed work   — commits on the feature branch that never reached the
#                        remote. `git branch -D` is destructive, so this is the
#                        life insurance: measured 2026-08-24 no closed-issue run
#                        had any, i.e. the gate is a no-op today and a guarantee
#                        tomorrow.
#
# NETWORK DISCIPLINE (the same two-phase shape as scan_clean, and for the same
# reason — #124/#125/#133 all came from per-item reads):
#   Phase 1  local only. No candidates => not a single API call.
#   Phase 2a ONE paginated REST list of the repo's OPEN issues. Absence from a
#            COMPLETE enumeration of open issues is proof of closure; absence
#            from a TRUNCATED one is not, so uncovered candidates fall back to a
#            targeted per-issue read (same rescue as scan_clean's).
#   Phase 2b ONE paginated REST list of OPEN PRs — skipped entirely unless a
#            confirmed-closed candidate actually carries a PR.
#   Phase 3  local git only (G5).
scan_finished() {
  local repo_path="$1"
  local want_remote="${2:-}"
  local owner_repo="${3:-}"
  local runs_dir="$repo_path/.claude/run-issues"
  [ -d "$runs_dir" ] || return 0

  local cand
  cand=$(mktemp)

  # ---- Phase 1: local candidates (host, remote, liveness). No network. ----
  local rj host rem status inum pr_url pr_num branch
  shopt -s nullglob
  for rj in "$runs_dir"/*/run.json; do
    host=$(jq -r '.host // ""' "$rj" 2>/dev/null || echo "")
    # G2. An empty host is a pre-host-field run.json; scan_clean treats it as
    # local and so do we, but ONLY because the run-dir is physically here.
    if [ -n "$host" ] && [ "$host" != "$THIS_HOST" ]; then
      continue
    fi
    if [ -n "$want_remote" ]; then
      rem=$(jq -r '.remote // "origin"' "$rj" 2>/dev/null || echo "origin")
      [ "$rem" = "$want_remote" ] || continue
    fi
    inum=$(jq -r '.issue_number // empty' "$rj" 2>/dev/null || echo "")
    [ -n "$inum" ] || continue
    status=$(jq -r '.status // ""' "$rj" 2>/dev/null || echo "")
    # G1. A live run is always `initialized` (restart/continue reset it), so any
    # other status is a finalised run. An unreadable status is not "finalised".
    if [ -z "$status" ] || [ "$status" = "initialized" ]; then
      _finished_log "skip run=$(basename "$(dirname "$rj")") reason=live_run status=${status:-unreadable}"
      continue
    fi
    pr_url=$(jq -r '.pr_url // ""' "$rj" 2>/dev/null || echo "")
    pr_num=""
    case "$pr_url" in
      */pull/*) pr_num="${pr_url##*/pull/}"; pr_num="${pr_num%%/*}" ;;
    esac
    case "$pr_num" in ''|*[!0-9]*) pr_num="" ;; esac
    branch=$(jq -r '.branch // ""' "$rj" 2>/dev/null || echo "")
    printf '%s\t%s\t%s\t%s\n' "$inum" "$(dirname "$rj")" "$pr_num" "$branch" >> "$cand"
  done

  if [ ! -s "$cand" ]; then
    rm -f "$cand"
    return 0
  fi

  # ---- Phase 2a: ONE list of OPEN issues; absence from a complete list is ----
  # ---- proof of closure, absence from a truncated one is not.            ----
  local limit="${RUN_ISSUES_FINISHED_SCAN_LIMIT:-500}"
  local open_issues page rows chunk got truncated
  open_issues=$(mktemp)
  truncated=0
  page=1
  rows=0
  : > "$open_issues"
  while [ "$rows" -lt "$limit" ]; do
    chunk=$(
      cd "$repo_path"
      _issue_gh --remote "$want_remote" -- api "$(_rest_issues_path "$owner_repo" "state=open&per_page=100&page=${page}")" \
        --jq '.[] | select(.pull_request == null) | .number' \
        2>>"${RUN_ISSUES_GH_ERR:-/dev/null}"
    ) || { rm -f "$cand" "$open_issues"; return 0; }   # read failed => fail-closed, whole repo
    [ -n "$chunk" ] || break
    printf '%s\n' "$chunk" >> "$open_issues"
    got=$(printf '%s\n' "$chunk" | grep -c .) || got=0
    rows=$((rows + got))
    [ "$got" -lt 100 ] && break
    page=$((page + 1))
  done
  if [ "$rows" -ge "$limit" ] 2>/dev/null; then
    truncated=1
    printf '%s scan_finished: WARNING %s carries >= %s open issues — list truncated, falling back to per-issue reads\n' \
      "$(date -u +%FT%TZ)" "${owner_repo:-$repo_path}" "$limit" >&2
  fi

  local closed
  closed=$(mktemp)
  local line rd state
  while IFS=$'\t' read -r inum rd pr_num branch; do
    [ -n "$inum" ] || continue
    if grep -qx -- "$inum" "$open_issues"; then
      _finished_log "skip run=$(basename "$rd") reason=issue_open issue=$inum"
      continue
    fi
    if [ "$truncated" -eq 1 ]; then
      # Absence is not proof while the list is truncated — ask about this one.
      state=$(
        cd "$repo_path"
        _issue_gh --remote "$want_remote" -- api "$(_rest_issue_path "$owner_repo" "$inum")" \
          --jq '.state // ""' 2>>"${RUN_ISSUES_GH_ERR:-/dev/null}" || echo ""
      )
      if [ "$state" != "closed" ]; then
        _finished_log "skip run=$(basename "$rd") reason=issue_state_unconfirmed issue=$inum state=${state:-unreadable}"
        continue
      fi
    fi
    printf '%s\t%s\t%s\t%s\n' "$inum" "$rd" "$pr_num" "$branch" >> "$closed"
  done < "$cand"

  if [ ! -s "$closed" ]; then
    rm -f "$cand" "$open_issues" "$closed"
    return 0
  fi

  # ---- Phase 2b: ONE list of OPEN PRs — only if a candidate carries one. ----
  local open_prs need_prs
  open_prs=$(mktemp)
  : > "$open_prs"
  need_prs=0
  while IFS=$'\t' read -r inum rd pr_num branch; do
    [ -n "$pr_num" ] && { need_prs=1; break; }
  done < "$closed"

  local pr_truncated=0
  if [ "$need_prs" -eq 1 ]; then
    page=1
    rows=0
    while [ "$rows" -lt "$limit" ]; do
      chunk=$(
        cd "$repo_path"
        _issue_gh --remote "$want_remote" -- api "$(_rest_pulls_path "$owner_repo" "state=open&per_page=100&page=${page}")" \
          --jq '.[].number' 2>>"${RUN_ISSUES_GH_ERR:-/dev/null}"
      ) || { rm -f "$cand" "$open_issues" "$closed" "$open_prs"; return 0; }  # fail-closed
      [ -n "$chunk" ] || break
      printf '%s\n' "$chunk" >> "$open_prs"
      got=$(printf '%s\n' "$chunk" | grep -c .) || got=0
      rows=$((rows + got))
      [ "$got" -lt 100 ] && break
      page=$((page + 1))
    done
    [ "$rows" -ge "$limit" ] 2>/dev/null && pr_truncated=1
  fi

  # ---- Phase 3: G4 (open PR) and G5 (unpushed work). Local git only for G5. --
  local unpushed upstream pr_state
  while IFS=$'\t' read -r inum rd pr_num branch; do
    if [ -n "$pr_num" ]; then
      if grep -qx -- "$pr_num" "$open_prs"; then
        _finished_log "skip run=$(basename "$rd") reason=pr_open issue=$inum pr=$pr_num"
        continue
      fi
      if [ "$pr_truncated" -eq 1 ]; then
        # Absence is not proof while the list is truncated — ask about this one.
        # Symmetric with the issue-side rescue above: truncation must cost extra
        # CALLS, never extra SKIPS, or a busy repo would stop reconciling
        # entirely and the gap would be invisible.
        pr_state=$(
          cd "$repo_path"
          _issue_gh --remote "$want_remote" -- api "$(_rest_pull_path "$owner_repo" "$pr_num")" \
            --jq '.state // ""' 2>>"${RUN_ISSUES_GH_ERR:-/dev/null}" || echo ""
        )
        if [ "$pr_state" != "closed" ]; then
          _finished_log "skip run=$(basename "$rd") reason=pr_state_unconfirmed issue=$inum pr=$pr_num state=${pr_state:-unreadable}"
          continue
        fi
      fi
    fi

    # G5. `--set-upstream` on the orchestrator's push (S10) means a pushed
    # branch always has an upstream configured. No upstream => never pushed =>
    # every commit on it is unpushed. With an upstream, compare against the
    # remote-tracking ref; if that ref is gone the branch was pushed and then
    # deleted on merge, which is the normal end state, not unpushed work.
    if [ -n "$branch" ] && git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch"; then
      upstream=$(git -C "$repo_path" rev-parse --abbrev-ref --symbolic-full-name "$branch@{upstream}" 2>/dev/null || echo "")
      if [ -z "$upstream" ]; then
        _finished_log "skip run=$(basename "$rd") reason=branch_never_pushed issue=$inum branch=$branch"
        continue
      fi
      if git -C "$repo_path" show-ref --verify --quiet "refs/remotes/$upstream"; then
        unpushed=$(git -C "$repo_path" rev-list --count "$upstream..$branch" 2>/dev/null || echo "")
        case "$unpushed" in
          ''|*[!0-9]*)
            _finished_log "skip run=$(basename "$rd") reason=unpushed_check_failed issue=$inum branch=$branch"
            continue
            ;;
        esac
        if [ "$unpushed" -gt 0 ]; then
          _finished_log "skip run=$(basename "$rd") reason=unpushed_commits issue=$inum branch=$branch n=$unpushed"
          continue
        fi
      fi
    fi

    _finished_log "reconcile run=$(basename "$rd") issue=$inum pr=${pr_num:-none} status=closed_issue"
    printf '%s %s\n' "$inum" "$rd"
  done < "$closed"

  rm -f "$cand" "$open_issues" "$closed" "$open_prs"
  # Return 0 regardless (see scan_clean): callers capture this under `set -e`.
  return 0
}

# ----- Tick-start version banner (issue #32) -------------------------------
# Log which runner version is actually executing, every tick. A pinned dotfiles
# submodule (CLAUDE.md §3) advances only on an explicit bump, and nothing used
# to reveal when the running code had drifted behind origin/main — a blind spot
# that produced three wrong diagnoses in one incident. A throttled fetch keeps
# behind_origin honest (≤ once/hour) without a fetch on every 300s tick; the
# WARNING makes an out-of-date runner impossible to miss on a glance at the log.
runner_fetch_throttled "$RUN_ISSUES_HOME" "${LOG_DIR}/run-issues-poller.fetch-stamp" 3600 "$(preflight_timeout_bin)"
RUNNER_VER=$(runner_version "$RUN_ISSUES_HOME")
RUNNER_BEHIND=$(runner_behind_origin "$RUN_ISSUES_HOME")
echo "$(date -u +%FT%TZ) poller: version=$RUNNER_VER behind_origin=$RUNNER_BEHIND" >> "$LOG"
if [ "$RUNNER_BEHIND" != "?" ] && [ "$RUNNER_BEHIND" -gt 0 ] 2>/dev/null; then
  echo "$(date -u +%FT%TZ) poller: WARNING running $RUNNER_BEHIND commits behind origin/main (pinned submodule?)" >> "$LOG"
fi

# ----- Rate-limit backoff gate (issue #126) --------------------------------
# GitHub's blocking limit is secondary and invisible to `gh api rate_limit`
# (measured: the counters do not move, and during the outage the endpoint
# reported a full quota while every call failed). So the only signal is a
# rejection, and the only safe response is to stop asking for a while: each
# rejected request feeds the very limit that produced it, which is how one
# outage lasted ten hours and wrote 1754 identical stderr lines.
#
# The deadline is checked BEFORE any network work — including the liveness
# sweep, which posts situation comments — and the tick exits 0. One log line per
# skipped tick, not one per call: the suppression IS the feature (issue #65's
# lesson). State is shared with pr-watch-poller because they spend one quota.
RATE_LIMIT_FILE="$(rate_limit_state_file)"
if rate_limit_active "$RATE_LIMIT_FILE"; then
  echo "$(date -u +%FT%TZ) poller: backing off after GitHub rate limit — skipping tick until $(date -u -r "$RATE_LIMIT_DEADLINE" +%FT%TZ 2>/dev/null || echo "$RATE_LIMIT_DEADLINE")" >> "$LOG"
  exit 0
fi

# Every gh call this tick appends its stderr here as well as to its usual sink,
# so a rejection is detectable even on the paths that deliberately discard it
# (epic_list_open, the clean-label query, fetch_issue_json). Library helpers
# honour RUN_ISSUES_GH_ERR and fall back to /dev/null when it is unset, so no
# other caller changes behaviour.
GH_ERR=$(mktemp -t run-issues-gh-err.XXXXXX)
export RUN_ISSUES_GH_ERR="$GH_ERR"
trap 'rm -f "$GH_ERR"' EXIT
RATE_LIMIT_HIT=0

# _rl_hit — 0 when a rejection has appeared in this tick's captured stderr. On
# the first hit it escalates the backoff and logs once; callers break out of the
# repo loop. Runs already spawned into tmux are left alone: they are long-lived
# and can make progress without the listing calls that failed here.
_rl_hit() {
  [ "$RATE_LIMIT_HIT" -eq 0 ] || return 0
  rate_limit_file_matches "$GH_ERR" || return 1
  RATE_LIMIT_HIT=1
  local info
  info="$(rate_limit_trip "$RATE_LIMIT_FILE")"
  echo "$(date -u +%FT%TZ) poller: GitHub rate limit hit — aborting tick, backing off ${info##* }s" >> "$LOG"
  return 0
}

# ----- Pre-loop liveness sweep (across ALL watchlist repos) ----------------
# A wedged orchestrator can keep its tmux session alive forever (issue #49: a
# composer install hanging in S7b held a GLOBAL_MAX slot for 48+ hours and
# blocked the whole factory). This sweep walks the watchlist, kills the tmux
# session of every stalled run on THIS host, and finalizes it as
# blocked/stalled_in_<state> — BEFORE the ACTIVE-cap check below measures
# capacity. Without this, a single jammed repo could starve every other repo
# even with the cap check working as designed. finalize_stalled is best-effort
# and host-gated (defense in depth on top of scan_stalled's own gate). Empty
# REPO_PATH and missing .git get skipped silently (same guard as the main
# loop). Walking the same watchlist twice is cheap — scan_stalled does no
# network work, only filesystem reads.
while IFS= read -r stalled_repo_json; do
  [ -n "$stalled_repo_json" ] || continue
  STALLED_REPO_PATH=$(jq -r '.path // empty' <<<"$stalled_repo_json")
  [ -n "$STALLED_REPO_PATH" ] && [ -d "$STALLED_REPO_PATH/.git" ] || continue
  while IFS= read -r stalled_line; do
    [ -n "$stalled_line" ] || continue
    finalize_stalled "${stalled_line%% *}" "${stalled_line#* }" || true
  done < <(scan_stalled "$STALLED_REPO_PATH")
done < <(jq -c '.repos[]?' "$WATCHLIST")

# Count currently active run-issues tmux sessions to respect the cap.
# The `|| ACTIVE=0` fallback lives OUTSIDE the command substitution on purpose:
# grep -c always prints a count to stdout (0 on no matches) but exits 1 when the
# count is 0, and pipefail propagates that. Putting `|| echo 0` *inside* the
# substitution would append a second "0" to grep's own "0", yielding "0\n0" and
# crashing the numeric comparison below under set -e. Out here, the fallback only
# fires when the substitution exits non-zero, keeping ACTIVE a clean integer.
ACTIVE=$(tmux ls 2>/dev/null | grep -c '^run-issues-') || ACTIVE=0
if [ "$ACTIVE" -ge "$GLOBAL_MAX" ]; then
  echo "$(date -u +%FT%TZ) poller: at cap ($ACTIVE/$GLOBAL_MAX), skipping" >> "$LOG"
  exit 0
fi

# Iterate repos. We use a while-read loop instead of mapfile because
# macOS ships bash 3.2 by default, which lacks the mapfile builtin.
#
# Multi-remote (issue #53): each repo entry may carry a `remotes` array of
# git-remote names (default `["origin"]`). We iterate (repo × remote), routing
# scans + spawns per remote so a single clone can poll issues from multiple
# orgs at once without colliding their identities. owner/repo is derived
# per-remote from `git remote get-url`; an unresolvable remote is skipped with
# a WARNING (the other remotes still proceed).
while IFS= read -r repo_json; do
  [ -n "$repo_json" ] || continue

  REPO_PATH=$(jq -r '.path // empty' <<<"$repo_json")
  REPO_LABELS=$(jq -r '(.labels // []) | map(select(type == "string" and length > 0)) | join(",")' <<<"$repo_json")

  if [ -z "$REPO_PATH" ] || [ ! -d "$REPO_PATH/.git" ]; then
    echo "$(date -u +%FT%TZ) poller: skip invalid repo entry: $repo_json" >> "$LOG"
    continue
  fi

  # Pickup labels for this repo: entry `labels`, else `default_labels`, else the
  # built-in default. Shared with /new-epic via lib/poller-config.sh so the
  # command cannot label a new epic with a set this poller would never pick up.
  LABELS_CSV=$(poller_pick_labels "$REPO_LABELS" "$DEFAULT_LABELS")

  # remotes array (default ["origin"]) — newline-separated for the inner loop.
  # A bad/empty array (missing field, non-array, empty) is treated as ["origin"]
  # so the entry keeps working unchanged. We tolerate stringly-typed values to
  # protect against a human watchlist edit slip.
  REMOTES_LIST=$(jq -r '
    (.remotes // ["origin"])
    | if type == "array" then . else ["origin"] end
    | map(select(type == "string" and length > 0))
    | if length == 0 then ["origin"] else . end
    | join("\n")
  ' <<<"$repo_json")

  for REMOTE in $REMOTES_LIST; do
    # Resolve owner/repo via `git remote get-url <REMOTE>`. A missing or
    # un-parseable URL means we cannot route gh calls correctly — skip this
    # remote with a WARNING and let the other remotes proceed. Origin keeps
    # legacy behaviour: owner/repo MAY be empty (existing gh-CLI cwd default).
    OWNER_REPO=""
    if ! OWNER_REPO=$(resolve_remote_to_owner_repo "$REPO_PATH" "$REMOTE" 2>/dev/null); then
      if [ "$REMOTE" = "origin" ]; then
        # origin special case: an un-parseable URL is non-fatal at the poller
        # level — the orchestrator falls back to gh-CLI cwd resolution. Many
        # existing repos have github.com SSH/HTTPS URLs that DO parse, so this
        # is just defense in depth.
        OWNER_REPO=""
      else
        echo "$(date -u +%FT%TZ) poller: WARNING remote '$REMOTE' missing or URL un-parseable in $REPO_PATH — skipping" >> "$LOG"
        continue
      fi
    fi

    # Repo component of every name spawned below (issue #67). Derived per
    # (repo × remote) so two repos' issue #42 get distinct tmux sessions and
    # distinct locks, and can therefore run in parallel within GLOBAL_MAX
    # instead of the second one being skipped every cycle as a "duplicate".
    REPO_SLUG=$(repo_slug "$REPO_PATH" "$REMOTE")

    # ----- Clean labelled issues FIRST (before restart/continue/pick) --------
    while IFS= read -r clean_line; do
      [ -n "$clean_line" ] || continue
      CLEAN_ISSUE="${clean_line%% *}"
      CLEAN_REPO="${clean_line#* }"
      if EXISTING=$(_running_session_name "run-issues-clean-" "$REMOTE" "$REPO_SLUG" "$CLEAN_ISSUE"); then
        echo "$(date -u +%FT%TZ) poller: clean session $EXISTING already running" >> "$LOG"
        continue
      fi
      CL_SUFFIX=$(session_suffix "$REMOTE" "$CLEAN_ISSUE" "$REPO_SLUG")
      CL_SESSION="run-issues-clean-${CL_SUFFIX}"
      ACTIVE=$(tmux ls 2>/dev/null | grep -c '^run-issues-') || ACTIVE=0
      if [ "$ACTIVE" -ge "$GLOBAL_MAX" ]; then
        echo "$(date -u +%FT%TZ) poller: at cap ($ACTIVE/$GLOBAL_MAX), deferring clean of issue $CLEAN_ISSUE (remote=$REMOTE)" >> "$LOG"
        break
      fi
      echo "$(date -u +%FT%TZ) poller: cleaning $CL_SESSION for repo=$CLEAN_REPO issue=$CLEAN_ISSUE remote=$REMOTE" >> "$LOG"
      tmux new-session -d -s "$CL_SESSION" \
        "'$AUTO_CLEAN' --repo '$CLEAN_REPO' --issue '$CLEAN_ISSUE' --remote '$REMOTE' 2>&1 | tee -a '$RUNS_LOG'"
    done < <(scan_clean "$REPO_PATH" "$REMOTE" "$OWNER_REPO")

    # ----- Reconcile finished runs (issue #107) -----------------------------
    # Sibling of the clean pass above, but a different verb: auto-clean is a
    # human declaring an issue done (it closes the issue and comments);
    # reconciliation only tears down what a close already made dead. It runs
    # after scan_clean so an issue carrying auto-clean is handled by the
    # explicit channel first and never torn down twice in one tick — the
    # per-issue lock would serialise them anyway, but the ordering keeps the
    # human's verb authoritative.
    while IFS= read -r finished_line; do
      [ -n "$finished_line" ] || continue
      FIN_ISSUE="${finished_line%% *}"
      FIN_DIR="${finished_line#* }"
      if EXISTING=$(_running_session_name "run-issues-finished-" "$REMOTE" "$REPO_SLUG" "$FIN_ISSUE"); then
        echo "$(date -u +%FT%TZ) poller: reconcile session $EXISTING already running" >> "$LOG"
        continue
      fi
      FIN_SUFFIX=$(session_suffix "$REMOTE" "$FIN_ISSUE" "$REPO_SLUG")
      FIN_SESSION="run-issues-finished-${FIN_SUFFIX}"
      ACTIVE=$(tmux ls 2>/dev/null | grep -c '^run-issues-') || ACTIVE=0
      if [ "$ACTIVE" -ge "$GLOBAL_MAX" ]; then
        echo "$(date -u +%FT%TZ) poller: at cap ($ACTIVE/$GLOBAL_MAX), deferring reconcile of issue $FIN_ISSUE (remote=$REMOTE)" >> "$LOG"
        break
      fi
      echo "$(date -u +%FT%TZ) poller: reconciling $FIN_SESSION for run=$FIN_DIR issue=$FIN_ISSUE remote=$REMOTE" >> "$LOG"
      # cleanup-run.sh, NOT auto-clean.sh: no issue close, no comment, no label.
      # --force because a reconciled run is by definition `completed` in the
      # common case, which cleanup-run.sh's own local gate would otherwise skip
      # — scan_finished has already confirmed remotely that nothing is open.
      tmux new-session -d -s "$FIN_SESSION" \
        "'$CLEANUP' --repo '$REPO_PATH' --issue '$FIN_ISSUE' --remote '$REMOTE' --force --yes 2>&1 | tee -a '$RUNS_LOG'"
    done < <(scan_finished "$REPO_PATH" "$REMOTE" "$OWNER_REPO")

    # ----- Restart timed-out runs FIRST (before picking new issues) ----------
    while IFS= read -r restart_line; do
      [ -n "$restart_line" ] || continue
      RESTART_ISSUE="${restart_line%% *}"
      RESTART_DIR="${restart_line#* }"
      if EXISTING=$(_running_session_name "run-issues-restart-" "$REMOTE" "$REPO_SLUG" "$RESTART_ISSUE"); then
        echo "$(date -u +%FT%TZ) poller: restart session $EXISTING already running" >> "$LOG"
        continue
      fi
      R_SUFFIX=$(session_suffix "$REMOTE" "$RESTART_ISSUE" "$REPO_SLUG")
      R_SESSION="run-issues-restart-${R_SUFFIX}"
      ACTIVE=$(tmux ls 2>/dev/null | grep -c '^run-issues-') || ACTIVE=0
      if [ "$ACTIVE" -ge "$GLOBAL_MAX" ]; then
        echo "$(date -u +%FT%TZ) poller: at cap ($ACTIVE/$GLOBAL_MAX), deferring restart of issue $RESTART_ISSUE (remote=$REMOTE)" >> "$LOG"
        break
      fi
      echo "$(date -u +%FT%TZ) poller: restarting $R_SESSION for run=$RESTART_DIR remote=$REMOTE" >> "$LOG"
      tmux new-session -d -s "$R_SESSION" \
        "RUN_ISSUES_AUTO=1 '$ORCH' --restart '$RESTART_DIR' 2>&1 | tee -a '$RUNS_LOG'"
    done < <(scan_timed_out "$REPO_PATH" "$REMOTE")

    # ----- Continue answered clarifications --------------------------------
    while IFS= read -r continue_line; do
      [ -n "$continue_line" ] || continue
      CONTINUE_ISSUE="${continue_line%% *}"
      CONTINUE_DIR="${continue_line#* }"
      if EXISTING=$(_running_session_name "run-issues-continue-" "$REMOTE" "$REPO_SLUG" "$CONTINUE_ISSUE"); then
        echo "$(date -u +%FT%TZ) poller: continue session $EXISTING already running" >> "$LOG"
        continue
      fi
      C_SUFFIX=$(session_suffix "$REMOTE" "$CONTINUE_ISSUE" "$REPO_SLUG")
      C_SESSION="run-issues-continue-${C_SUFFIX}"
      ACTIVE=$(tmux ls 2>/dev/null | grep -c '^run-issues-') || ACTIVE=0
      if [ "$ACTIVE" -ge "$GLOBAL_MAX" ]; then
        echo "$(date -u +%FT%TZ) poller: at cap ($ACTIVE/$GLOBAL_MAX), deferring continue of issue $CONTINUE_ISSUE (remote=$REMOTE)" >> "$LOG"
        break
      fi
      echo "$(date -u +%FT%TZ) poller: continuing $C_SESSION for run=$CONTINUE_DIR remote=$REMOTE" >> "$LOG"
      tmux new-session -d -s "$C_SESSION" \
        "RUN_ISSUES_AUTO=1 '$ORCH' --continue '$CONTINUE_DIR' 2>&1 | tee -a '$RUNS_LOG'"
    done < <(scan_answered "$REPO_PATH" "$REMOTE" "$OWNER_REPO")

    # ----- Retry answered blocked runs (issue #57) -------------------------
    # A human reply on a blocked run's issue means the blocker is (claimed to be)
    # gone. Unlike a clarification, we do NOT resume the run: we tear it down via
    # cleanup-run.sh (worktree, branch, run-dir, GitHub assignment, needs-human
    # label, lock — issue NOT closed) so normal pickup starts a FRESH run from the
    # current base on a later tick. auto-clean.sh is deliberately NOT used here —
    # it closes the issue. cleanup-run.sh --issue cleans every run-dir for the
    # issue (so multiple blocked runs collapse to one retry) but skips completed
    # runs, protecting any open PR. --yes because there is no human at the prompt.
    #
    # Failure is logged (tee to RUNS_LOG) and non-fatal: the run-dir is gone after
    # a successful teardown, so the same reply cannot trigger a second retry; a
    # partial teardown leaves state for the next tick to notice. The duplicate-
    # session guard stops a slow cleanup from being respawned while it runs.
    while IFS= read -r blocked_line; do
      [ -n "$blocked_line" ] || continue
      BLOCKED_ISSUE="${blocked_line%% *}"
      BLOCKED_DIR="${blocked_line#* }"
      if EXISTING=$(_running_session_name "run-issues-blocked-clean-" "$REMOTE" "$REPO_SLUG" "$BLOCKED_ISSUE"); then
        echo "$(date -u +%FT%TZ) poller: blocked-clean session $EXISTING already running" >> "$LOG"
        continue
      fi
      BC_SUFFIX=$(session_suffix "$REMOTE" "$BLOCKED_ISSUE" "$REPO_SLUG")
      BC_SESSION="run-issues-blocked-clean-${BC_SUFFIX}"
      ACTIVE=$(tmux ls 2>/dev/null | grep -c '^run-issues-') || ACTIVE=0
      if [ "$ACTIVE" -ge "$GLOBAL_MAX" ]; then
        echo "$(date -u +%FT%TZ) poller: at cap ($ACTIVE/$GLOBAL_MAX), deferring blocked-retry cleanup of issue $BLOCKED_ISSUE (remote=$REMOTE)" >> "$LOG"
        break
      fi
      echo "$(date -u +%FT%TZ) poller: blocked run answered — cleaning $BC_SESSION for repo=$REPO_PATH issue=$BLOCKED_ISSUE run=$BLOCKED_DIR remote=$REMOTE (fresh pickup next tick)" >> "$LOG"
      tmux new-session -d -s "$BC_SESSION" \
        "'$CLEANUP' --repo '$REPO_PATH' --issue '$BLOCKED_ISSUE' --remote '$REMOTE' --yes 2>&1 | tee -a '$RUNS_LOG'"
    done < <(scan_blocked_answered "$REPO_PATH" "$REMOTE" "$OWNER_REPO")

    # ----- Scan epics: propagate auto-run + lifecycle markers (issue #81) ---
    # BEFORE pickup, so a child that just received auto-run in this same tick is
    # already pickable below. An epic is never spawned as a run (S2c + the pickup
    # search's -label:epic keep it out); this phase only PREPARES its children so
    # the normal dependency-run picks up the chain. epic_process_one is entirely
    # best-effort (always returns 0) — a single epic's GitHub hiccup must not
    # abort the tick — and idempotent, so repeating it every tick is safe.
    while IFS= read -r epic_num; do
      [ -n "$epic_num" ] || continue
      epic_process_one "$REPO_PATH" "$epic_num" "$LABELS_CSV" "$OWNER_REPO" "$REMOTE" \
        >> "$LOG" 2>&1 || true
    done < <(epic_list_open "$REPO_PATH" "$LABELS_CSV" "$OWNER_REPO" "$REMOTE")

    # Everything above this line touched the network. Stop the whole sweep on
    # the first rejection rather than repeating it for the remaining repos.
    if _rl_hit; then break 2; fi

    # ----- Pick a new candidate issue (per remote) -------------------------
    # The ONLY pickup search in the package lives in lib/issue.sh (issue #99): the
    # poller delegates to pick_oldest_candidate so there is a single query and a
    # single change point (label CSV encoding, standing filters, owner/repo routing,
    # and the IFS=',' word-split guard all live there). This converges the two
    # searches the way issue #91 converged the epic child resolver — the poller can
    # never drift from the library. pick_oldest_candidate is testable by sourcing;
    # this inline call site is not (the poller exits at source time on a foreign
    # host), which is the other half of the reason to move it into the library.
    ISSUE_NUM=$(pick_oldest_candidate "$REPO_PATH" "$LABELS_CSV" "$OWNER_REPO" "$REMOTE" 2>>"$GH_ERR" || true)

    if _rl_hit; then break 2; fi

    if [ -z "$ISSUE_NUM" ]; then
      continue
    fi

    # The duplicate-suppression check is repo-scoped (issue #67): before the fix
    # this compared `run-issues-<N>` across every repo, so repo B's issue #42 was
    # skipped with a log line that looked like normal duplicate suppression for
    # as long as repo A's issue #42 ran — silent starvation, invisible in the log.
    if EXISTING=$(_running_session_name "run-issues-" "$REMOTE" "$REPO_SLUG" "$ISSUE_NUM"); then
      echo "$(date -u +%FT%TZ) poller: session $EXISTING already running (repo=$REPO_PATH issue=$ISSUE_NUM)" >> "$LOG"
      continue
    fi
    NEW_SUFFIX=$(session_suffix "$REMOTE" "$ISSUE_NUM" "$REPO_SLUG")
    SESSION="run-issues-${NEW_SUFFIX}"

    # Re-check cap before spawning.
    ACTIVE=$(tmux ls 2>/dev/null | grep -c '^run-issues-') || ACTIVE=0
    if [ "$ACTIVE" -ge "$GLOBAL_MAX" ]; then
      echo "$(date -u +%FT%TZ) poller: hit cap during loop ($ACTIVE/$GLOBAL_MAX) — breaking remote iter" >> "$LOG"
      break 2  # break out of both the for-remote loop and the while-repos loop
    fi

    echo "$(date -u +%FT%TZ) poller: launching $SESSION for repo=$REPO_PATH issue=$ISSUE_NUM remote=$REMOTE" >> "$LOG"

    # Pass --remote to the orchestrator so it threads the right remote through
    # every gh call, git push, fetch, and lock — the entire (issue → PR) chain
    # routes to the source org.
    tmux new-session -d -s "$SESSION" \
      "RUN_ISSUES_AUTO=1 RUN_ISSUES_REVIEW_GATE=auto '$ORCH' --remote '$REMOTE' '$REPO_PATH' '$ISSUE_NUM' 2>&1 | tee -a '$RUNS_LOG'"
  done
done < <(jq -c '.repos[]?' "$WATCHLIST")

# A tick that got through every repo without a rejection means GitHub is serving
# us again — forget the ladder so the next outage starts from the first rung.
if [ "$RATE_LIMIT_HIT" -eq 0 ]; then
  rate_limit_clear "$RATE_LIMIT_FILE"
fi
