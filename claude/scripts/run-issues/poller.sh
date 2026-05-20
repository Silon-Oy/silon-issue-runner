#!/usr/bin/env bash
# poller.sh — Studio-only auto-run poller for /run-issues.
#
# Iterates the watchlist (machine-studio/run-issues-watchlist.json), and
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

# Studio-only guard. Bail out silently on any other host so that
# accidentally pushing the LaunchAgent to the laptop does nothing.
HOST=$(hostname -s)
case "$HOST" in
  *host-a*|*host-a*|maintainers-host-a*) : ;;
  *) exit 0 ;;
esac

DOTFILES="${HOME}/dotfiles"
WATCHLIST="${DOTFILES}/machine-studio/run-issues-watchlist.json"
ORCH="${DOTFILES}/claude/scripts/run-issues/orchestrate.sh"
LOG="${HOME}/Library/Logs/run-issues-poller.log"

# Hard requirements; bail fast if anything is missing.
[ -f "$WATCHLIST" ] || { echo "$(date -u +%FT%TZ) poller: watchlist missing at $WATCHLIST" >> "$LOG"; exit 0; }
[ -x "$ORCH" ]      || { echo "$(date -u +%FT%TZ) poller: orchestrator not executable at $ORCH" >> "$LOG"; exit 0; }
command -v gh >/dev/null     || { echo "$(date -u +%FT%TZ) poller: gh not in PATH" >> "$LOG"; exit 0; }
command -v jq >/dev/null     || { echo "$(date -u +%FT%TZ) poller: jq not in PATH" >> "$LOG"; exit 0; }
command -v tmux >/dev/null   || { echo "$(date -u +%FT%TZ) poller: tmux not in PATH" >> "$LOG"; exit 0; }

if ! jq -e . "$WATCHLIST" >/dev/null 2>&1; then
  echo "$(date -u +%FT%TZ) poller: watchlist is not valid JSON" >> "$LOG"
  exit 0
fi

GLOBAL_MAX=$(jq -r '.global_max_concurrent // 2' "$WATCHLIST")
DEFAULT_LABELS=$(jq -r '(.default_labels // ["auto-run"]) | join(",")' "$WATCHLIST")

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

  # Find the candidate issue using gh inside the repo.
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
    gh issue list \
      --search "is:open no:assignee -label:blocked -label:waiting -label:wip sort:created-asc$extra" \
      --limit 1 \
      --json number \
      --jq '.[0].number // empty' 2>/dev/null || true
  )

  if [ -z "$ISSUE_NUM" ]; then
    continue
  fi

  SESSION="run-issues-${ISSUE_NUM}"
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "$(date -u +%FT%TZ) poller: session $SESSION already running" >> "$LOG"
    continue
  fi

  # Re-check cap before spawning (another iteration may have started one).
  # See the note at the first ACTIVE assignment for why the fallback is outside
  # the command substitution.
  ACTIVE=$(tmux ls 2>/dev/null | grep -c '^run-issues-') || ACTIVE=0
  if [ "$ACTIVE" -ge "$GLOBAL_MAX" ]; then
    echo "$(date -u +%FT%TZ) poller: hit cap during loop ($ACTIVE/$GLOBAL_MAX)" >> "$LOG"
    break
  fi

  echo "$(date -u +%FT%TZ) poller: launching $SESSION for repo=$REPO_PATH issue=$ISSUE_NUM" >> "$LOG"

  tmux new-session -d -s "$SESSION" \
    "RUN_ISSUES_AUTO=1 RUN_ISSUES_REVIEW_GATE=auto RUN_ISSUES_LABELS_CSV='$LABELS_CSV' '$ORCH' '$REPO_PATH' '$ISSUE_NUM' 2>&1 | tee -a '${HOME}/Library/Logs/run-issues-poller.runs.log'"
done < <(jq -c '.repos[]?' "$WATCHLIST")
