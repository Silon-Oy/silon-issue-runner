#!/usr/bin/env bash
# lib/locking.sh — per-issue lock directory, atomic via mkdir(2).
#
# Lock root lives under ~/Library/Application Support/run-issues/locks/
# (macOS convention; survives reboot, not synced to iCloud by default).
# Each lock is a directory named `issue-<N>.lock` containing a `pid` file
# and an `acquired_at` file with an ISO-8601 timestamp.
#
# This file is sourced by orchestrate.sh; do not execute top-level work.

set -euo pipefail

RUN_ISSUES_LOCK_ROOT="${RUN_ISSUES_LOCK_ROOT:-${HOME}/Library/Application Support/run-issues/locks}"
RUN_ISSUES_LOCK_STALE_SECS="${RUN_ISSUES_LOCK_STALE_SECS:-86400}" # 24h

# _lock_dir <issue-num>: prints the absolute lock directory path.
_lock_dir() {
  printf '%s/issue-%s.lock' "$RUN_ISSUES_LOCK_ROOT" "$1"
}

# lock_issue <N> — returns 0 if lock acquired, 1 if held by another run.
lock_issue() {
  local n="$1"
  local dir
  dir="$(_lock_dir "$n")"
  mkdir -p "$RUN_ISSUES_LOCK_ROOT"

  if mkdir "$dir" 2>/dev/null; then
    printf '%s' "$$" > "$dir/pid"
    date -u +%FT%TZ > "$dir/acquired_at"
    return 0
  fi

  # Lock exists — check staleness via directory mtime.
  if [ -d "$dir" ]; then
    local mtime now age
    mtime=$(stat -f %m "$dir" 2>/dev/null || echo 0)
    now=$(date +%s)
    age=$(( now - mtime ))
    if [ "$age" -gt "$RUN_ISSUES_LOCK_STALE_SECS" ]; then
      rm -rf "$dir"
      if mkdir "$dir" 2>/dev/null; then
        printf '%s' "$$" > "$dir/pid"
        date -u +%FT%TZ > "$dir/acquired_at"
        return 0
      fi
    fi
  fi
  return 1
}

# unlock_issue <N> — idempotent; ignores missing locks.
unlock_issue() {
  local n="$1"
  rm -rf "$(_lock_dir "$n")"
}
