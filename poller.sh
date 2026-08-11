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
DEFAULT_LABELS=$(jq -r '(.default_labels // ["auto-run"]) | join(",")' "$WATCHLIST")
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

# finalize_stalled <issue-number> <run-dir> — terminate a stalled run:
#   1. Kill any matching tmux session (run-issues-<N> / run-issues-restart-<N>
#      / run-issues-continue-<N>) so it stops consuming GLOBAL_MAX.
#   2. Finalize run.json as blocked/stalled_in_<current_state> via
#      state_finalize (lib/state.sh).
#   3. Best-effort: post a Finnish situation comment to the issue, add the
#      needs-human label, release the per-issue advisory lock.
#
# All gh calls are `|| true` — a GitHub hiccup must never wedge the poller's
# main loop. The lock teardown matches lib/locking.sh's path convention
# (RUN_ISSUES_LOCK_ROOT/issue-<N>.lock) and is idempotent.
#
# After finalization the run carries terminal status=blocked + label
# needs-human, so subsequent scan_timed_out/scan_answered/scan_stalled passes
# will NOT re-pick it (terminal status), and the issue's needs-human label
# blocks pick_oldest_unassigned from re-claiming it as new work.
finalize_stalled() {
  local issue="$1" run_dir="$2"
  local rj="$run_dir/run.json"
  [ -f "$rj" ] || return 0

  local current_state repo host_in_run remote_in_run slug_in_run run_id_in_run
  current_state=$(jq -r '.current_state // "unknown"' "$rj" 2>/dev/null || echo "unknown")
  repo=$(jq -r '.repo // empty' "$rj" 2>/dev/null || echo "")
  # run_id for the awaiting-answer marker (issue #57). Empty -> run-dir basename,
  # which IS the run-id by construction. Only the marker's ts matters downstream
  # (scan_blocked_answered reads ts=), but build_marker wants the run field too.
  run_id_in_run=$(jq -r '.run_id // empty' "$rj" 2>/dev/null || echo "")
  [ -n "$run_id_in_run" ] || run_id_in_run=$(basename "$run_dir")
  host_in_run=$(jq -r '.host // empty' "$rj" 2>/dev/null || echo "")
  # Multi-remote (issue #53): empty -> "origin" (legacy run.json predating the
  # field). The remote drives tmux session naming and lock teardown below.
  remote_in_run=$(jq -r '.remote // "origin"' "$rj" 2>/dev/null || echo "origin")
  # Repo namespacing (issue #67): the slug RECORDED BY THIS RUN, not one derived
  # here. That distinction is the whole fix for cross-repo lock theft — we
  # release exactly the lock this run holds. Empty = pre-#67 run holding the
  # legacy repo-agnostic lock.
  slug_in_run=$(jq -r '.repo_slug // ""' "$rj" 2>/dev/null || echo "")
  # Defense in depth: scan_stalled host-gates, but a misalignment between
  # caller and helper would otherwise let us tap a foreign session.
  if [ -n "$host_in_run" ] && [ "$host_in_run" != "$THIS_HOST" ]; then
    echo "$(date -u +%FT%TZ) poller: finalize_stalled refusing foreign host run (host=$host_in_run, this=$THIS_HOST)" >> "$LOG"
    return 0
  fi
  local reason="stalled_in_${current_state}"

  echo "$(date -u +%FT%TZ) poller: STALLED issue=#${issue} remote=${remote_in_run} state=${current_state} run_dir=${run_dir} — killing tmux sessions and finalizing blocked/${reason}" >> "$LOG"

  # Kill any tmux session for this run. There is exactly one orchestrator per
  # (repo, remote, issue) triple (the per-issue lock guarantees it), but it could
  # carry any of four prefixes depending on how it was launched. The suffix shape
  # depends on the remote and the repo slug, so derive it from session_suffix.
  #
  # A pre-#67 run gets a second suffix probed: its ORIGINAL session carries the
  # legacy repo-agnostic name, but if this poller version restarted/continued it,
  # the newer session carries the repo-namespaced one. Both must die or the run
  # keeps holding a GLOBAL_MAX slot. For a post-#67 run only its own name is
  # touched — that is what keeps another repo's identically-numbered session safe.
  local suffix suffix_alt sess
  suffix=$(session_suffix "$remote_in_run" "$issue" "$slug_in_run")
  suffix_alt=""
  if [ -z "$slug_in_run" ] && [ -n "$repo" ]; then
    suffix_alt=$(session_suffix "$remote_in_run" "$issue" "$(repo_slug "$repo" "$remote_in_run")")
    [ "$suffix_alt" = "$suffix" ] && suffix_alt=""
  fi
  for sess in "run-issues-${suffix}" "run-issues-restart-${suffix}" \
              "run-issues-continue-${suffix}" "run-issues-clean-${suffix}" \
              ${suffix_alt:+"run-issues-${suffix_alt}"} \
              ${suffix_alt:+"run-issues-restart-${suffix_alt}"} \
              ${suffix_alt:+"run-issues-continue-${suffix_alt}"} \
              ${suffix_alt:+"run-issues-clean-${suffix_alt}"}; do
    # `=` forces an exact tmux target match; without it `run-issues-3` prefix-
    # matches `run-issues-34` and we would kill an unrelated running session.
    if tmux has-session -t "=$sess" 2>/dev/null; then
      echo "$(date -u +%FT%TZ) poller: killing stalled tmux session $sess" >> "$LOG"
      tmux kill-session -t "=$sess" 2>/dev/null || true
    fi
  done

  # Finalize state. The orchestrator process is dead (or never had a chance to
  # write a terminal status), so we own the run.json transition here.
  state_finalize "$run_dir" "blocked" "$reason"
  state_event "$run_dir" "stalled_finalized" \
    "current_state=$current_state" \
    "host=$THIS_HOST" \
    "stale_after=${RUN_ISSUES_STALE_AFTER:-3600}"

  # Best-effort label + comment via gh. We change into the repo (from run.json)
  # so gh resolves the right repo even from the poller's cwd.
  if [ -n "$repo" ]; then
    # Diagnostics from the label helpers go to $LOG, not /dev/null: a silent
    # best-effort label write is how the read:project scope breakage stayed
    # invisible for five weeks. (poller.sh logs by appending to $LOG — there
    # is no log() function here, and `log` is a macOS binary.)
    ( cd "$repo" && labels_ensure "" needs-human B60205 \
        "Vaatii ihmisen — automaattinen ajo ei onnistunut" ) 2>&1 \
        | sed "s/^/$(date -u +%FT%TZ) poller: /" >> "$LOG" || true
    ( cd "$repo" && labels_add "" "$issue" needs-human ) 2>&1 \
        | sed "s/^/$(date -u +%FT%TZ) poller: /" >> "$LOG" || true

    # Write the comment body to a temp file (heredoc inside $(...) has fragile
    # parser interactions with bash's case-statement-aware tokenizer; the temp
    # file is simpler and verifiable). The comment intentionally mirrors
    # _post_situation_to_issue's headline + meta-list shape so an maintainer
    # scanning issues sees the same skeleton across all hand-off paths.
    local stale_after_log body_file stalled_marker
    stale_after_log="${RUN_ISSUES_STALE_AFTER:-3600}"
    # Answerable marker (issue #57): a human reply after this ts re-triggers a
    # fresh run via scan_blocked_answered. build_marker + parse_marker/detect_answer
    # are the SAME machinery the orchestrator uses, so the poller's stalled comment
    # participates identically. Marker first (top of body) — parse_marker takes the
    # newest by ts, and detect_answer skips this comment itself (it carries the
    # "run-issues:" token).
    stalled_marker=$(build_marker "$run_id_in_run" "$issue" "$(date -u +%FT%TZ)")
    body_file=$(mktemp -t poller-stalled-body.XXXXXX)
    {
      echo "$stalled_marker"
      echo "## /run-issues — Ajo jumitettu vaiheessa \`${current_state}\`"
      echo
      echo "- Issue: #${issue}"
      echo "- Status/syy: \`${reason}\`"
      echo "- Host: \`${THIS_HOST}\`"
      echo "- Run-dir: \`${run_dir}\`"
      echo
      echo "Pollerin liveness-tarkistus havaitsi että rakenteinen etenemistila (\`state.jsonl\`-aikaleima) ei ole liikahtanut yli ${stale_after_log}s. Tmux-sessio tapettiin ja ajo viimeisteltiin \`blocked\`-tilaan, jotta yksittäinen jumi-ajo ei tukkisi \`GLOBAL_MAX\`-kapasiteettia loputtomiin (issue #49)."
      echo
      echo "**Kun este on selvitetty, kommentoi tähän issueen — ajo siivotaan ja yritetään uudelleen automaattisesti (≤5 min).** Vaihtoehtoisesti siivoa käsin koneella \`${THIS_HOST}\`: \`~/.claude/scripts/run-issues/cleanup-run.sh --issue ${issue} --force --yes\`."
    } > "$body_file"
    ( cd "$repo" && gh issue comment "$issue" --body-file "$body_file" >/dev/null 2>&1 ) || true
    rm -f "$body_file"
  fi

  # Release the per-issue advisory lock (its owner is dead). Same path shape as
  # lib/locking.sh; idempotent — a missing lock is fine.
  #
  # The label is built from the run's OWN recorded identity (repo slug + remote),
  # so this removes exactly the lock this run holds. Deriving the label from the
  # issue number alone was cross-repo lock theft (issue #67): finalizing a
  # stalled run in repo A deleted repo B's LIVE lock for the same issue number,
  # after which the next poller cycle could start a second run for B.
  local lock_root="${RUN_ISSUES_LOCK_ROOT:-${HOME}/Library/Application Support/run-issues/locks}"
  local lock_label
  lock_label=$(remote_label "$remote_in_run" "$issue" "$slug_in_run")
  rm -rf "${lock_root}/${lock_label}.lock" 2>/dev/null || true

  return 0
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
    issue_json=$(fetch_issue_json "$repo" "$inum" "$owner_repo" "$effective_remote" 2>/dev/null || true)
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
    issue_json=$(fetch_issue_json "$repo" "$inum" "$owner_repo" "$effective_remote" 2>/dev/null || true)
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
#   Phase 2 — for each unique issue only, one `gh issue view --repo owner/repo`
#             to read its labels in the right org. When owner/repo is empty,
#             gh falls back to cwd-based resolution (legacy single-remote).
# bash 3.2 has no associative arrays, so the unique set is a temp file fed
# through `sort -u`.
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

  # Phase 2: per unique issue, read labels and decide. The label fetch is
  # routed via `gh --repo` when owner_repo is set so non-origin remotes hit
  # the right org's API.
  local n labels repo_args=""
  [ -n "$owner_repo" ] && repo_args="--repo $owner_repo"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    # shellcheck disable=SC2086  # intentional word-splitting on repo_args
    labels=$(
      cd "$repo_path"
      gh issue view "$n" $repo_args --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo ""
    )
    # auto-clean-skipped wins: already handed to a human, never re-emit.
    case ",$labels," in
      *,auto-clean-skipped,*) continue ;;
    esac
    case ",$labels," in
      *,"$RUN_ISSUES_CLEAN_LABEL",*) printf '%s %s\n' "$n" "$repo_path" ;;
    esac
  done < <(sort -u "$seen")

  rm -f "$seen"
  # Return 0 regardless: callers capture this in a command substitution under
  # `set -e`, where a trailing-false branch would otherwise abort the caller.
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
  REPO_LABELS=$(jq -r '(.labels // []) | join(",")' <<<"$repo_json")

  if [ -z "$REPO_PATH" ] || [ ! -d "$REPO_PATH/.git" ]; then
    echo "$(date -u +%FT%TZ) poller: skip invalid repo entry: $repo_json" >> "$LOG"
    continue
  fi

  LABELS_CSV="$REPO_LABELS"
  [ -z "$LABELS_CSV" ] && LABELS_CSV="$DEFAULT_LABELS"

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

    # ----- Pick a new candidate issue (per remote) -------------------------
    # gh issue list is routed via `--repo owner/repo` when known so a
    # non-origin remote sees its own org's issues. REPO_ARGS is an array so
    # the `--repo owner/repo` pair stays two distinct argv entries regardless
    # of $IFS — the label loop below sets IFS=',' to split LABELS_CSV, and an
    # unquoted string $REPO_ARGS would then fail to word-split on space,
    # passing "--repo owner/repo" as a single unknown flag (silently swallowed
    # by 2>/dev/null) and breaking pickup for every remote that resolves an
    # owner/repo.
    REPO_ARGS=()
    [ -n "$OWNER_REPO" ] && REPO_ARGS=(--repo "$OWNER_REPO")
    ISSUE_NUM=$(
      cd "$REPO_PATH"
      extra=""
      if [ -n "$LABELS_CSV" ]; then
        IFS=','
        for label in $LABELS_CSV; do
          [ -n "$label" ] || continue
          extra+=" label:\"$label\""
        done
      fi
      # Sort is encoded inside --search (sort:created-asc) because gh 2.83+
      # no longer accepts standalone --sort/--order flags on `issue list`.
      gh issue list "${REPO_ARGS[@]}" \
        --search "is:open no:assignee -is:blocked -label:waiting -label:wip -label:$RUN_ISSUES_CLEAN_LABEL sort:created-asc$extra" \
        --limit 1 \
        --json number \
        --jq '.[0].number // empty' 2>/dev/null || true
    )

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
      "RUN_ISSUES_AUTO=1 RUN_ISSUES_REVIEW_GATE=auto RUN_ISSUES_LABELS_CSV='$LABELS_CSV' '$ORCH' --remote '$REMOTE' '$REPO_PATH' '$ISSUE_NUM' 2>&1 | tee -a '$RUNS_LOG'"
  done
done < <(jq -c '.repos[]?' "$WATCHLIST")
