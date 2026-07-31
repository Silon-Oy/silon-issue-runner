#!/usr/bin/env bash
# pr-watch-poller.sh — Studio-only auto-poller for the Phase 2 PR watcher.
#
# Iterates the watchlist (machine-studio/run-issues-watchlist.json) and, for
# each repo, runs pr-watch.sh in scan mode inside a DETACHED tmux session.
# scan mode is itself idempotent and per-issue locked, so spawning is cheap
# and safe to repeat.
#
# Mirrors poller.sh: hostname guard, global concurrency cap, crash-safe
# ACTIVE counting (issue #2 fix). tmux session prefix is `pr-watch-`.
#
# StartInterval in the LaunchAgent: 300s.

set -euo pipefail

# Studio-only guard. Bail out silently on any other host so that accidentally
# running the LaunchAgent on the laptop does nothing.
HOST=$(hostname -s)
case "$HOST" in
  *host-a*|*host-a*|maintainers-host-a*) : ;;
  *) exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES="${HOME}/dotfiles"
WATCHLIST="${DOTFILES}/machine-studio/run-issues-watchlist.json"
PRWATCH="${DOTFILES}/claude/scripts/run-issues/pr-watch.sh"
LOG="${HOME}/Library/Logs/pr-watch-poller.log"

# Hard requirements; bail fast if anything is missing.
[ -f "$WATCHLIST" ] || { echo "$(date -u +%FT%TZ) pr-watch-poller: watchlist missing at $WATCHLIST" >> "$LOG"; exit 0; }
[ -x "$PRWATCH" ]   || { echo "$(date -u +%FT%TZ) pr-watch-poller: pr-watch.sh not executable at $PRWATCH" >> "$LOG"; exit 0; }
command -v gh >/dev/null     || { echo "$(date -u +%FT%TZ) pr-watch-poller: gh not in PATH" >> "$LOG"; exit 0; }
command -v jq >/dev/null     || { echo "$(date -u +%FT%TZ) pr-watch-poller: jq not in PATH" >> "$LOG"; exit 0; }
command -v tmux >/dev/null   || { echo "$(date -u +%FT%TZ) pr-watch-poller: tmux not in PATH" >> "$LOG"; exit 0; }

if ! jq -e . "$WATCHLIST" >/dev/null 2>&1; then
  echo "$(date -u +%FT%TZ) pr-watch-poller: watchlist is not valid JSON" >> "$LOG"
  exit 0
fi

GLOBAL_MAX=$(jq -r '.global_max_concurrent // 2' "$WATCHLIST")

# --- Auto-unblock pass -------------------------------------------------------
# Before scanning for mergeable PRs, release any `blocked`-labelled issues whose
# native blocked_by dependencies have all closed, so run-issues-poller (which
# reads only the label, not native dependencies) picks them up next. Idempotent
# and orphan-safe: repos that don't use native deps leave `blocked` issues
# untouched. Runs every tick independently of the pr-watch spawn/cap logic, so a
# merge that closes a blocker is reflected within ~StartInterval. Non-fatal: a
# failure in one repo must not abort the poller.
#
# unblock-issues.sh ships inside this package (repo root), so prefer the
# package-local copy: it keeps working wherever the package is mounted. The
# legacy dotfiles sibling path stays as a fallback for installs still on the
# pre-package layout. A missing script remains a silent no-op via the guard
# below — which is exactly why the package-local path must come first: a wrong
# path here disables the unblock pass without any error surfacing.
UNBLOCK="${SCRIPT_DIR}/unblock-issues.sh"
[ -x "$UNBLOCK" ] || UNBLOCK="${DOTFILES}/claude/scripts/unblock-issues.sh"
if [ -x "$UNBLOCK" ]; then
  while IFS= read -r unblock_repo_json; do
    up=$(jq -r '.path // empty' <<<"$unblock_repo_json")
    [ -n "$up" ] && [ -d "$up/.git" ] || continue
    ( cd "$up" && "$UNBLOCK" >> "${HOME}/Library/Logs/pr-watch-poller.runs.log" 2>&1 ) || true
  done < <(jq -c '.repos[]?' "$WATCHLIST")
fi

# Enable AI conflict resolution for every watchlist repo by default. pr-watch.sh
# defaults this OFF (0); the poller flips it ON so that auto-merge can complete
# through a rebase conflict without a human. Still overridable: export
# PR_WATCH_ENABLE_CONFLICT_RESOLUTION=0 in the poller's environment to disable.
# The flag rides on the per-repo command below, so it reaches pr-watch.sh even
# though the LaunchAgent does not source the machine env file.
CONFLICT_RESOLUTION="${PR_WATCH_ENABLE_CONFLICT_RESOLUTION:-1}"

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
while IFS= read -r repo_json; do
  [ -n "$repo_json" ] || continue

  REPO_PATH=$(jq -r '.path // empty' <<<"$repo_json")
  if [ -z "$REPO_PATH" ] || [ ! -d "$REPO_PATH/.git" ]; then
    echo "$(date -u +%FT%TZ) pr-watch-poller: skip invalid repo entry: $repo_json" >> "$LOG"
    continue
  fi

  # One scan session per repo. Derive a tmux-safe suffix from the repo path's
  # basename so concurrent repos get distinct sessions.
  REPO_TAG=$(basename "$REPO_PATH" | tr -c '[:alnum:]_' '_')
  SESSION="pr-watch-${REPO_TAG}"

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
    break
  fi

  echo "$(date -u +%FT%TZ) pr-watch-poller: launching $SESSION for repo=$REPO_PATH" >> "$LOG"

  tmux new-session -d -s "$SESSION" \
    "PR_WATCH_ENABLE_CONFLICT_RESOLUTION='$CONFLICT_RESOLUTION' '$PRWATCH' '$REPO_PATH' scan 2>&1 | tee -a '${HOME}/Library/Logs/pr-watch-poller.runs.log'"
done < <(jq -c '.repos[]?' "$WATCHLIST")
