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
THIS_HOST=$(hostname -s)
RUN_ISSUES_MAX_RETRIES="${RUN_ISSUES_MAX_RETRIES:-1}"
RUN_ISSUES_MAX_CLARIFICATIONS="${RUN_ISSUES_MAX_CLARIFICATIONS:-3}"

# parse_marker / detect_answer / fetch_issue_json live in lib/issue.sh; the
# poller needs them for scan_answered. Sourcing is safe — lib/issue.sh only
# defines functions, no top-level work.
LIB_ISSUE="${DOTFILES}/claude/scripts/run-issues/lib/issue.sh"
# shellcheck source=lib/issue.sh
[ -f "$LIB_ISSUE" ] && . "$LIB_ISSUE"

# scan_timed_out <repo-path> — prints "<issue-number> <run-dir>" lines for
# timed_out runs on THIS host that still have retry budget. Modelled on
# pr-watch.sh's scan_candidates: iterate run.json files, gate on host so we
# never restart a worktree that lives on another machine.
scan_timed_out() {
  local repo_path="$1"
  local runs_dir="$repo_path/.claude/run-issues"
  [ -d "$runs_dir" ] || return 0
  local rj status host retry inum
  shopt -s nullglob
  for rj in "$runs_dir"/*/run.json; do
    status=$(jq -r '.status // ""' "$rj" 2>/dev/null || echo "")
    [ "$status" = "timed_out" ] || continue
    host=$(jq -r '.host // ""' "$rj" 2>/dev/null || echo "")
    # Empty host = pre-host-field run.json; treat as local (best effort).
    if [ -n "$host" ] && [ "$host" != "$THIS_HOST" ]; then
      continue
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

# scan_answered <repo-path> — prints "<issue-number> <run-dir>" lines for
# awaiting_clarification runs on THIS host that (a) still have clarification
# budget and (b) have a fresh human reply on the issue. Sibling of
# scan_timed_out with the same host gate. Kept cheap: it only hits the network
# (fetch_issue_json + parse_marker + detect_answer) for LOCAL runs that are
# actually parked — never a blanket scan of all issues.
scan_answered() {
  local repo_path="$1"
  local runs_dir="$repo_path/.claude/run-issues"
  [ -d "$runs_dir" ] || return 0
  local rj status host round inum repo marker_ts answer
  shopt -s nullglob
  for rj in "$runs_dir"/*/run.json; do
    status=$(jq -r '.status // ""' "$rj" 2>/dev/null || echo "")
    [ "$status" = "awaiting_clarification" ] || continue
    host=$(jq -r '.host // ""' "$rj" 2>/dev/null || echo "")
    # Empty host = pre-host-field run.json; treat as local (best effort).
    if [ -n "$host" ] && [ "$host" != "$THIS_HOST" ]; then
      continue
    fi
    round=$(jq -r '.clarification_round // 0' "$rj" 2>/dev/null || echo 0)
    [ "$round" -lt "$RUN_ISSUES_MAX_CLARIFICATIONS" ] || continue
    inum=$(jq -r '.issue_number // empty' "$rj" 2>/dev/null || echo "")
    [ -n "$inum" ] || continue
    repo=$(jq -r '.repo // empty' "$rj" 2>/dev/null || echo "")
    [ -n "$repo" ] || repo="$repo_path"

    # Network: only for this local, parked run. Find the marker, then a reply.
    local issue_json
    issue_json=$(fetch_issue_json "$repo" "$inum" 2>/dev/null || true)
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

  # ----- Restart timed-out runs FIRST (before picking new issues) ----------
  # A timed_out run on this host with retry budget left gets a higher timeout
  # and continues from where it left off. Restarts count against GLOBAL_MAX.
  while IFS= read -r restart_line; do
    [ -n "$restart_line" ] || continue
    RESTART_ISSUE="${restart_line%% *}"
    RESTART_DIR="${restart_line#* }"

    R_SESSION="run-issues-restart-${RESTART_ISSUE}"
    if tmux has-session -t "$R_SESSION" 2>/dev/null; then
      echo "$(date -u +%FT%TZ) poller: restart session $R_SESSION already running" >> "$LOG"
      continue
    fi

    ACTIVE=$(tmux ls 2>/dev/null | grep -c '^run-issues-') || ACTIVE=0
    if [ "$ACTIVE" -ge "$GLOBAL_MAX" ]; then
      echo "$(date -u +%FT%TZ) poller: at cap ($ACTIVE/$GLOBAL_MAX), deferring restart of issue $RESTART_ISSUE" >> "$LOG"
      break
    fi

    echo "$(date -u +%FT%TZ) poller: restarting $R_SESSION for run=$RESTART_DIR" >> "$LOG"
    tmux new-session -d -s "$R_SESSION" \
      "RUN_ISSUES_AUTO=1 '$ORCH' --restart '$RESTART_DIR' 2>&1 | tee -a '${HOME}/Library/Logs/run-issues-poller.runs.log'"
  done < <(scan_timed_out "$REPO_PATH")

  # ----- Continue answered clarifications (after restarts, before new picks) --
  # An awaiting_clarification run on this host with a fresh reply and budget left
  # re-runs cycle-review with the answer as context. Continues count against
  # GLOBAL_MAX like restarts and new picks.
  while IFS= read -r continue_line; do
    [ -n "$continue_line" ] || continue
    CONTINUE_ISSUE="${continue_line%% *}"
    CONTINUE_DIR="${continue_line#* }"

    C_SESSION="run-issues-continue-${CONTINUE_ISSUE}"
    if tmux has-session -t "$C_SESSION" 2>/dev/null; then
      echo "$(date -u +%FT%TZ) poller: continue session $C_SESSION already running" >> "$LOG"
      continue
    fi

    ACTIVE=$(tmux ls 2>/dev/null | grep -c '^run-issues-') || ACTIVE=0
    if [ "$ACTIVE" -ge "$GLOBAL_MAX" ]; then
      echo "$(date -u +%FT%TZ) poller: at cap ($ACTIVE/$GLOBAL_MAX), deferring continue of issue $CONTINUE_ISSUE" >> "$LOG"
      break
    fi

    echo "$(date -u +%FT%TZ) poller: continuing $C_SESSION for run=$CONTINUE_DIR" >> "$LOG"
    tmux new-session -d -s "$C_SESSION" \
      "RUN_ISSUES_AUTO=1 '$ORCH' --continue '$CONTINUE_DIR' 2>&1 | tee -a '${HOME}/Library/Logs/run-issues-poller.runs.log'"
  done < <(scan_answered "$REPO_PATH")

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
