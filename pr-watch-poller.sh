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

# Host gate. Bail out silently on a machine that was never configured to run
# the pollers, before any path is created — an unknown host must not so much as
# make a log directory.
HOST=$(hostname -s)
poller_host_allowed "$HOST" "${RUN_ISSUES_POLLER_HOSTS:-$POLLER_HOSTS_LEGACY_DEFAULT}" || exit 0

LOG_DIR="${RUN_ISSUES_LOG_DIR:-${HOME}/Library/Logs}"
mkdir -p "$LOG_DIR"
LOG="${LOG_DIR}/pr-watch-poller.log"
RUNS_LOG="${LOG_DIR}/pr-watch-poller.runs.log"

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

GLOBAL_MAX=$(jq -r '.global_max_concurrent // 2' "$WATCHLIST")

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

# Count active pr-watch tmux sessions to respect the cap. The `|| ACTIVE=0`
# fallback lives OUTSIDE the command substitution on purpose (see poller.sh
# and issue #2): grep -c always prints a count but exits 1 on zero matches,
# and pipefail would propagate that. Out here, the fallback only fires when
# the substitution exits non-zero, keeping ACTIVE a clean integer.
ACTIVE=$(tmux ls 2>/dev/null | grep -c '^pr-watch-') || ACTIVE=0
if [ "$ACTIVE" -ge "$GLOBAL_MAX" ]; then
  echo "$(date -u +%FT%TZ) pr-watch-poller: at cap ($ACTIVE/$GLOBAL_MAX), skipping" >> "$LOG"
  exit 0
fi

# Iterate repos. while-read (not mapfile) for bash 3.2 compatibility.
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
while IFS= read -r repo_json; do
  [ -n "$repo_json" ] || continue

  REPO_PATH=$(jq -r '.path // empty' <<<"$repo_json")
  if [ -z "$REPO_PATH" ] || [ ! -d "$REPO_PATH/.git" ]; then
    echo "$(date -u +%FT%TZ) pr-watch-poller: skip invalid repo entry: $repo_json" >> "$LOG"
    continue
  fi

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

    # `=` forces an exact tmux target match; without it e.g. `pr-watch-customer-c`
    # prefix-matches `pr-watch-customer-c_erp` and one repo blocks the other.
    if tmux has-session -t "=$SESSION" 2>/dev/null; then
      echo "$(date -u +%FT%TZ) pr-watch-poller: session $SESSION already running" >> "$LOG"
      continue
    fi

    # Re-check cap before spawning (another iteration may have started one).
    ACTIVE=$(tmux ls 2>/dev/null | grep -c '^pr-watch-') || ACTIVE=0
    if [ "$ACTIVE" -ge "$GLOBAL_MAX" ]; then
      echo "$(date -u +%FT%TZ) pr-watch-poller: hit cap during loop ($ACTIVE/$GLOBAL_MAX)" >> "$LOG"
      break 2  # break out of both the for-remote loop and the while-repos loop
    fi

    echo "$(date -u +%FT%TZ) pr-watch-poller: launching $SESSION for repo=$REPO_PATH remote=$REMOTE" >> "$LOG"

    tmux new-session -d -s "$SESSION" \
      "PR_WATCH_ENABLE_CONFLICT_RESOLUTION='$CONFLICT_RESOLUTION' PR_WATCH_ENABLE_CI_REPAIR='$CI_REPAIR' '$PRWATCH' --remote '$REMOTE' '$REPO_PATH' scan 2>&1 | tee -a '$RUNS_LOG'"
  done
done < <(jq -c '.repos[]?' "$WATCHLIST")
