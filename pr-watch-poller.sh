#!/usr/bin/env bash
# pr-watch-poller.sh — host-gated auto-poller for the Phase 2 PR watcher.
#
# Iterates the watchlist (RUN_ISSUES_WATCHLIST, else
# $HOME/.config/run-issues/watchlist.json, else the legacy dotfiles path) and,
# for each repo, runs pr-watch.sh in scan mode inside a DETACHED tmux session.
# scan mode is itself idempotent and per-issue locked, so spawning is cheap
# and safe to repeat.
#
# Mirrors poller.sh: hostname guard, global concurrency cap, crash-safe
# ACTIVE counting (issue #2 fix). tmux session prefix is `pr-watch-`.
#
# StartInterval in the LaunchAgent: 300s.

set -euo pipefail

# --- Configuration resolution ------------------------------------------------
# Mirrors poller.sh; the order is documented in
# docs/diagrams/poller-config-resolution.mmd.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The package root. Read from the environment ONLY (never from poller.env),
# because it must be known before any file is sourced. A test injection point,
# not user configuration — in normal use SCRIPT_DIR is already correct.
RUN_ISSUES_HOME="${RUN_ISSUES_HOME:-$SCRIPT_DIR}"

# shellcheck source=lib/poller-config.sh
. "${RUN_ISSUES_HOME}/lib/poller-config.sh"

# rotate_log_if_big (issue #65). Sourced before the exec redirect below — see
# poller.sh for why rotating an already-open fd's file would be a no-op. Defines
# one function; no top-level work.
# shellcheck source=lib/log-rotate.sh
. "${RUN_ISSUES_HOME}/lib/log-rotate.sh"

# rate_limit_* (issue #126). Functions only; the gate itself runs below, once the
# log path is known.
# shellcheck source=lib/rate-limit.sh
. "${RUN_ISSUES_HOME}/lib/rate-limit.sh"

# host_gate_notice (issue #152 follow-up). See poller.sh: the gate below runs
# before any log path is opened and must still be able to report itself.
# shellcheck source=lib/host-gate-notice.sh
. "${RUN_ISSUES_HOME}/lib/host-gate-notice.sh"

# Machine configuration; the pollers' only channel under launchd, which hands
# an agent no environment of its own. Sourced, so the FILE WINS over an
# inherited environment variable. Deliberately not ~/.config/run-issues/env:
# that file holds secrets a poller has no use for.
POLLER_ENV_FILE="${RUN_ISSUES_POLLER_ENV_FILE:-${HOME}/.config/run-issues/poller.env}"
if [ -f "$POLLER_ENV_FILE" ]; then
  set +eu
  # shellcheck disable=SC1090
  . "$POLLER_ENV_FILE"
  set -eu
fi

# Resolved above the gate, created below it — see poller.sh.
LOG_DIR="${RUN_ISSUES_LOG_DIR:-${HOME}/Library/Logs}"

# Host gate. Bail out silently on a machine that was never configured to run
# the pollers, before any path is created — an unknown host must not so much as
# make a log directory. No default list (#152); see poller.sh for why an unset
# variable is loud, a non-matching one is not, and why the loud branch reports
# through host_gate_notice instead of a bare `>&2`.
HOST=$(hostname -s)
if [ -z "${RUN_ISSUES_POLLER_HOSTS:-}" ]; then
  host_gate_notice \
    "$(poller_host_unset_message RUN_ISSUES_POLLER_HOSTS "$POLLER_ENV_FILE" "$HOST")" \
    "${LOG_DIR}/pr-watch-poller.log"
  exit 0
fi
poller_host_allowed "$HOST" "$RUN_ISSUES_POLLER_HOSTS" || exit 0

mkdir -p "$LOG_DIR"
LOG="${LOG_DIR}/pr-watch-poller.log"
RUNS_LOG="${LOG_DIR}/pr-watch-poller.runs.log"

# Size-based log rotation (issue #65). At tick start, before the first write and
# before the exec redirect below, rotate any of the four log files past
# RUN_ISSUES_LOG_MAX_BYTES (default 10 MB; 0 disables). One .1 generation kept.
# pr-watch-poller.runs.log was the 190 MB file that motivated this. The
# .stdout/.stderr rotation MUST precede the exec below.
RUN_ISSUES_LOG_MAX_BYTES="${RUN_ISSUES_LOG_MAX_BYTES:-10485760}"
rotate_log_if_big "$LOG"                                   "$RUN_ISSUES_LOG_MAX_BYTES"
rotate_log_if_big "$RUNS_LOG"                              "$RUN_ISSUES_LOG_MAX_BYTES"
rotate_log_if_big "${LOG_DIR}/pr-watch-poller.stdout.log"  "$RUN_ISSUES_LOG_MAX_BYTES"
rotate_log_if_big "${LOG_DIR}/pr-watch-poller.stderr.log"  "$RUN_ISSUES_LOG_MAX_BYTES"

# The plists carry no StandardOutPath/StandardErrorPath keys, because launchd
# performs no variable expansion in them. The poller therefore owns all four of
# its log paths itself. Not on a TTY: a manual run must still print.
if [ ! -t 1 ]; then
  exec >>"${LOG_DIR}/pr-watch-poller.stdout.log" 2>>"${LOG_DIR}/pr-watch-poller.stderr.log"
fi

# The pre-package layout. A fallback only — never a primary path.
LEGACY_DOTFILES_DIR="${HOME}/dotfiles"

PRWATCH="${RUN_ISSUES_HOME}/pr-watch.sh"

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

# resolve_remote_to_owner_repo lives in lib/git-remote.sh. Used by the
# (repo × remote) iteration below to validate each remote (skip a misconfigured
# non-origin remote) and warn on an archived one (issue #33). Sourced unguarded
# like the poller's other libs; pure functions, no top-level work.
# shellcheck source=lib/git-remote.sh
. "${RUN_ISSUES_HOME}/lib/git-remote.sh"

# runner_version / runner_behind_origin / runner_fetch_throttled report which
# runner version is actually executing (issue #32). Pure functions; safe to
# source. Used by the tick-start version banner below.
# shellcheck source=lib/version.sh
. "${RUN_ISSUES_HOME}/lib/version.sh"

# Hard requirements; bail fast if anything is missing.
WATCHLIST=$(poller_resolve_watchlist "${RUN_ISSUES_WATCHLIST:-}" "$WATCHLIST_CONFIG" "$WATCHLIST_LEGACY") \
  || { echo "$(date -u +%FT%TZ) pr-watch-poller: watchlist missing, tried: $WATCHLIST_TRIED" >> "$LOG"; exit 0; }
[ -x "$PRWATCH" ]   || { echo "$(date -u +%FT%TZ) pr-watch-poller: pr-watch.sh not executable at $PRWATCH" >> "$LOG"; exit 0; }
preflight_have gh     || { echo "$(date -u +%FT%TZ) pr-watch-poller: gh not in PATH" >> "$LOG"; exit 0; }
preflight_have jq     || { echo "$(date -u +%FT%TZ) pr-watch-poller: jq not in PATH" >> "$LOG"; exit 0; }
preflight_have tmux   || { echo "$(date -u +%FT%TZ) pr-watch-poller: tmux not in PATH" >> "$LOG"; exit 0; }

if ! jq -e . "$WATCHLIST" >/dev/null 2>&1; then
  echo "$(date -u +%FT%TZ) pr-watch-poller: watchlist is not valid JSON" >> "$LOG"
  exit 0
fi

# ----- Tick-start version banner (issue #32) -------------------------------
# Log which runner version is actually executing, every tick — see poller.sh for
# the rationale (a pinned dotfiles submodule drifts silently behind origin/main).
# Same throttled fetch + WARNING; the watcher's own stamp file so the two pollers
# do not share throttle state.
runner_fetch_throttled "$RUN_ISSUES_HOME" "${LOG_DIR}/pr-watch-poller.fetch-stamp" 3600 "$(preflight_timeout_bin)"
RUNNER_VER=$(runner_version "$RUN_ISSUES_HOME")
RUNNER_BEHIND=$(runner_behind_origin "$RUN_ISSUES_HOME")
echo "$(date -u +%FT%TZ) pr-watch-poller: version=$RUNNER_VER behind_origin=$RUNNER_BEHIND" >> "$LOG"
if [ "$RUNNER_BEHIND" != "?" ] && [ "$RUNNER_BEHIND" -gt 0 ] 2>/dev/null; then
  echo "$(date -u +%FT%TZ) pr-watch-poller: WARNING running $RUNNER_BEHIND commits behind origin/main (pinned submodule?)" >> "$LOG"
fi

# ----- Rate-limit backoff gate (issue #126) --------------------------------
# The two pollers spend ONE GitHub quota, so they share one backoff deadline:
# a watcher that kept scanning while the issue poller backed off would keep the
# secondary limit alive for both. The deadline is checked before any gh call and
# the tick exits 0 with a single log line — pr-watch.sh itself trips the ladder
# (see gh_route), so a rejection seen by either side stops both.
RATE_LIMIT_FILE="$(rate_limit_state_file)"
if rate_limit_active "$RATE_LIMIT_FILE"; then
  echo "$(date -u +%FT%TZ) pr-watch-poller: backing off after GitHub rate limit — skipping tick until $(date -u -r "$RATE_LIMIT_DEADLINE" +%FT%TZ 2>/dev/null || echo "$RATE_LIMIT_DEADLINE")" >> "$LOG"
  exit 0
fi

GLOBAL_MAX=$(jq -r '.global_max_concurrent // 2' "$WATCHLIST")

# Separate concurrency cap for the PR watcher (issue #47). A PR scan is a few
# seconds of `gh` calls — an entirely different weight class from the tens of
# minutes an orchestrator run takes — yet both pollers share
# global_max_concurrent, deliberately kept low for those long orchestrator runs.
# The watcher inherited that too-tight cap. Left unset, PR_WATCH_MAX falls back
# to global_max_concurrent so an UNEDITED watchlist behaves exactly as before.
# Two overrides in precedence order: the optional watchlist key
# pr_watch_max_concurrent, then the PR_WATCH_GLOBAL_MAX environment variable
# (poller.env channel), which wins so an operator can raise the watcher's cap
# without touching the shared watchlist or poller.sh's orchestrator concurrency.
PR_WATCH_MAX=$(jq -r ".pr_watch_max_concurrent // ${GLOBAL_MAX}" "$WATCHLIST")
if [ -n "${PR_WATCH_GLOBAL_MAX:-}" ]; then
  PR_WATCH_MAX="$PR_WATCH_GLOBAL_MAX"
fi

# Enable AI conflict resolution for every watchlist repo by default. pr-watch.sh
# defaults this OFF (0); the poller flips it ON so that auto-merge can complete
# through a rebase conflict without a human. Still overridable: export
# PR_WATCH_ENABLE_CONFLICT_RESOLUTION=0 in the poller's environment to disable.
# The flag rides on the per-repo command below, so it reaches pr-watch.sh even
# though the LaunchAgent does not source the machine env file.
CONFLICT_RESOLUTION="${PR_WATCH_ENABLE_CONFLICT_RESOLUTION:-1}"

# Likewise enable AI CI-repair for every watchlist repo by default (issue #25).
# pr-watch.sh defaults this OFF (0); the poller flips it ON so that a red required
# check on an auto-merge PR is fixed by an agent instead of stalling forever.
# Same override contract: export PR_WATCH_ENABLE_CI_REPAIR=0 in poller.env to
# disable. Rides on the per-repo command below like the conflict flag.
CI_REPAIR="${PR_WATCH_ENABLE_CI_REPAIR:-1}"

# Materialise the watchlist repos into an array so the rotation cursor below can
# resume iteration from an arbitrary offset. while-read (not mapfile) for bash
# 3.2 compatibility.
REPOS=()
while IFS= read -r repo_json; do
  [ -n "$repo_json" ] || continue
  REPOS+=("$repo_json")
done < <(jq -c '.repos[]?' "$WATCHLIST")
N=${#REPOS[@]}
if [ "$N" -eq 0 ]; then
  echo "$(date -u +%FT%TZ) pr-watch-poller: watchlist has no repos, nothing to do" >> "$LOG"
  exit 0
fi

# Parallel array of repo paths — the rotation cursor's identity. Binding the
# cursor to the PATH (not a numeric index) is what lets it survive a watchlist
# edit: an entry inserted or removed elsewhere does not shift where we resume,
# and a removed cursor target simply restarts from the top instead of pointing
# at the wrong repo.
REPOS_PATHS=()
for (( i=0; i<N; i++ )); do
  REPOS_PATHS+=("$(jq -r '.path // empty' <<<"${REPOS[$i]}")")
done

# --- Rotation cursor (issue #47) --------------------------------------------
# Without it, iteration restarts from index 0 every tick; because scans are
# short the cap is empty again by the next tick, so only the first PR_WATCH_MAX
# repos are ever visited and the watchlist tail starves forever — its auto-merge
# PRs stay open with no error anywhere. The cursor records the repo to RESUME AT
# next tick, so every repo gets its turn within ceil(N / PR_WATCH_MAX) ticks.
# State is a single line (the resume repo path) in a file next to the logs; a
# missing, empty or corrupt file is not an error — it just restarts from index 0.
CURSOR_FILE="${LOG_DIR}/.pr-watch-cursor"

START_IDX=0
if [ -f "$CURSOR_FILE" ]; then
  SAVED_PATH=$(head -n 1 "$CURSOR_FILE" 2>/dev/null || true)
  if [ -n "$SAVED_PATH" ]; then
    for (( i=0; i<N; i++ )); do
      if [ "${REPOS_PATHS[$i]}" = "$SAVED_PATH" ]; then
        START_IDX=$i
        break
      fi
    done
  fi
fi

# Count active pr-watch tmux sessions to respect the cap. The `|| ACTIVE=0`
# fallback lives OUTSIDE the command substitution on purpose (see poller.sh
# and issue #2): grep -c always prints a count but exits 1 on zero matches,
# and pipefail would propagate that. Out here, the fallback only fires when
# the substitution exits non-zero, keeping ACTIVE a clean integer.
ACTIVE=$(tmux ls 2>/dev/null | grep -c '^pr-watch-') || ACTIVE=0
if [ "$ACTIVE" -ge "$PR_WATCH_MAX" ]; then
  echo "$(date -u +%FT%TZ) pr-watch-poller: at cap ($ACTIVE/$PR_WATCH_MAX), skipping" >> "$LOG"
  exit 0
fi

# Iterate repos starting from the rotation cursor, wrapping around the whole
# list so the tail is reached within a bounded number of ticks (issue #47).
# NEXT_IDX tracks the repo to resume at: it advances past each fully-serviced
# repo, but on a cap hit it is pinned to the repo we stopped at so the next tick
# starts there.
#
# Multi-remote (issue #33): each repo entry may carry a `remotes` array of
# git-remote names (default `["origin"]`), exactly as poller.sh reads it (#53).
# The watcher jumped this fix, so a clone whose PRs live in a non-origin remote
# was scanned as `origin` and silently did nothing. We iterate (repo × remote),
# spawn one scan session per remote (remote in the session name so the two are
# not collapsed by duplicate suppression), and pass --remote to pr-watch.sh so
# it scopes its scan + candidate count to that remote. gh routing inside
# pr-watch.sh is per-run from run.json — the poller only validates each remote
# here so a misconfigured one is skipped instead of spawning a useless scan.
NEXT_IDX=$START_IDX
CAP_HIT=0
for (( i=0; i<N; i++ )); do
  idx=$(( (START_IDX + i) % N ))
  repo_json="${REPOS[$idx]}"
  REPO_PATH="${REPOS_PATHS[$idx]}"

  if [ -z "$REPO_PATH" ] || [ ! -d "$REPO_PATH/.git" ]; then
    echo "$(date -u +%FT%TZ) pr-watch-poller: skip invalid repo entry: $repo_json" >> "$LOG"
  else
    # tmux-safe suffix from the repo path's basename so concurrent repos get
    # distinct sessions.
    REPO_TAG=$(basename "$REPO_PATH" | tr -c '[:alnum:]_' '_')

    # remotes array (default ["origin"]) — mirror poller.sh. A bad/empty array
    # (missing field, non-array, empty) collapses to ["origin"] so a malformed
    # watchlist edit keeps the entry working on its origin remote.
    REMOTES_LIST=$(jq -r '
      (.remotes // ["origin"])
      | if type == "array" then . else ["origin"] end
      | map(select(type == "string" and length > 0))
      | if length == 0 then ["origin"] else . end
      | join("\n")
    ' <<<"$repo_json")

    for REMOTE in $REMOTES_LIST; do
      # Validate the remote: resolve owner/repo so a misconfigured non-origin
      # remote is skipped with a WARNING instead of spawning a scan that would
      # find nothing. origin keeps legacy behaviour — an un-parseable URL is
      # non-fatal (pr-watch.sh + gh fall back to cwd inference).
      OWNER_REPO=""
      if ! OWNER_REPO=$(resolve_remote_to_owner_repo "$REPO_PATH" "$REMOTE" 2>/dev/null); then
        if [ "$REMOTE" = "origin" ]; then
          OWNER_REPO=""
        else
          echo "$(date -u +%FT%TZ) pr-watch-poller: WARNING remote '$REMOTE' missing or URL un-parseable in $REPO_PATH — skipping" >> "$LOG"
          continue
        fi
      fi

      # Best-effort archived-remote warning (issue #33, proposal 3). An archived
      # repo cannot be merged into, so operating a watcher against one is almost
      # always the configuration error behind this bug (origin was archived in the
      # observed case). One cheap gh call per remote; any failure (offline, auth,
      # no such repo) is ignored — this is a diagnostic, never a gate.
      if [ -n "$OWNER_REPO" ]; then
        if ARCHIVED=$( cd "$REPO_PATH" && gh repo view "$OWNER_REPO" --json isArchived --jq '.isArchived' 2>/dev/null ) \
           && [ "$ARCHIVED" = "true" ]; then
          echo "$(date -u +%FT%TZ) pr-watch-poller: WARNING remote '$REMOTE' ($OWNER_REPO) is ARCHIVED — PRs there cannot be merged; check the watchlist for $REPO_PATH" >> "$LOG"
        fi
      fi

      # Remote-namespaced tmux session name (issue #33). origin collapses to the
      # legacy `pr-watch-<repo>` shape so single-remote repos are unchanged; a
      # non-origin remote gets a `-<remote>` infix so two remotes of the same
      # clone are not collapsed by the exact-match duplicate suppression below —
      # the silent-starvation failure mode poller.sh fixed in #53.
      if [ "$REMOTE" = "origin" ]; then
        SESSION="pr-watch-${REPO_TAG}"
      else
        REMOTE_TAG=$(printf '%s' "$REMOTE" | tr -c '[:alnum:]_' '_')
        SESSION="pr-watch-${REPO_TAG}-${REMOTE_TAG}"
      fi

      # `=` forces an exact tmux target match; without it e.g. `pr-watch-acme`
      # prefix-matches `pr-watch-acme_erp` and one repo blocks the other.
      if tmux has-session -t "=$SESSION" 2>/dev/null; then
        echo "$(date -u +%FT%TZ) pr-watch-poller: session $SESSION already running" >> "$LOG"
        continue
      fi

      # Re-check cap before spawning (another iteration may have started one).
      # On a hit we do NOT lose the tail: NEXT_IDX is pinned below to the repo we
      # stopped at, so the next tick resumes here. The log names how many repos
      # were left unvisited this tick — a plain "hit cap" line looked like normal
      # congestion and hid the starvation for a day (issue #47).
      ACTIVE=$(tmux ls 2>/dev/null | grep -c '^pr-watch-') || ACTIVE=0
      if [ "$ACTIVE" -ge "$PR_WATCH_MAX" ]; then
        NOT_VISITED=$(( N - i ))
        echo "$(date -u +%FT%TZ) pr-watch-poller: hit cap during loop ($ACTIVE/$PR_WATCH_MAX) — ${NOT_VISITED} repo(s) not visited this tick, resuming there next tick" >> "$LOG"
        CAP_HIT=1
        break  # leave the for-remote loop; the for-repo loop breaks on CAP_HIT below
      fi

      echo "$(date -u +%FT%TZ) pr-watch-poller: launching $SESSION for repo=$REPO_PATH remote=$REMOTE" >> "$LOG"

      tmux new-session -d -s "$SESSION" \
        "PR_WATCH_ENABLE_CONFLICT_RESOLUTION='$CONFLICT_RESOLUTION' PR_WATCH_ENABLE_CI_REPAIR='$CI_REPAIR' '$PRWATCH' --remote '$REMOTE' '$REPO_PATH' scan 2>&1 | tee -a '$RUNS_LOG'"
    done
  fi

  # Cursor bookkeeping. On a cap hit, pin NEXT_IDX to the repo we stopped at so
  # the next tick resumes exactly there; otherwise advance past this fully
  # serviced repo (wrapping) so the following tick continues down the list.
  if [ "$CAP_HIT" -eq 1 ]; then
    NEXT_IDX=$idx
    break
  fi
  NEXT_IDX=$(( (idx + 1) % N ))
done

# Persist the cursor for the next tick. Atomic (temp + rename) so a mid-write
# kill cannot leave a torn file. A torn or otherwise unreadable file is harmless
# anyway — the resolver above treats an unmatched path as "start from index 0".
CURSOR_TMP=$(mktemp "${LOG_DIR}/.pr-watch-cursor.XXXXXX")
printf '%s\n' "${REPOS_PATHS[$NEXT_IDX]}" > "$CURSOR_TMP" && mv "$CURSOR_TMP" "$CURSOR_FILE"
