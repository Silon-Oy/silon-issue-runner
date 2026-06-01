#!/usr/bin/env bash
# lib/locking.sh — per-issue lock directory, atomic via mkdir(2).
#
# Lock root lives under ~/Library/Application Support/run-issues/locks/
# (macOS convention; survives reboot, not synced to iCloud by default).
# Each lock is a directory named `<label>.lock` (where <label> is
# "issue-<N>" for the origin remote and "<remote>-issue-<N>" otherwise)
# containing a `pid` file and an `acquired_at` file with an ISO-8601 timestamp.
#
# Multi-remote namespacing: the same clone can poll multiple GitHub orgs at
# once (issue #53). `Silon-Oy/...#5` and `customer-d-oy/...#5` are different
# issues with the same number, so the lock name must include the remote
# whenever it is not the legacy `origin` — otherwise they would collide on
# the same lock. Origin keeps the legacy `issue-<N>.lock` shape so existing
# locks are not orphaned by the upgrade.
#
# This file is sourced by orchestrate.sh; do not execute top-level work.

set -euo pipefail

# Source git-remote.sh for the shared remote_label helper. The path is
# resolved relative to this file so callers that have already cd'd elsewhere
# still get the right library. Safe to source repeatedly (the file is
# function-only with no top-level work).
_LOCKING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=git-remote.sh
. "$_LOCKING_DIR/git-remote.sh"

RUN_ISSUES_LOCK_ROOT="${RUN_ISSUES_LOCK_ROOT:-${HOME}/Library/Application Support/run-issues/locks}"
RUN_ISSUES_LOCK_STALE_SECS="${RUN_ISSUES_LOCK_STALE_SECS:-86400}" # 24h

# _lock_dir <issue-num> [<remote>]
# Prints the absolute lock directory path. The remote argument is optional and
# defaults to "origin" so legacy single-arg callers continue to produce the
# `issue-<N>.lock` path (full backward compatibility — existing locks are not
# orphaned and one-arg test fixtures keep working unchanged).
_lock_dir() {
  local n="$1"
  local remote="${2:-origin}"
  local label
  label=$(remote_label "$remote" "$n")
  printf '%s/%s.lock' "$RUN_ISSUES_LOCK_ROOT" "$label"
}

# lock_issue <N> [<remote>] — returns 0 if lock acquired, 1 if held by another run.
lock_issue() {
  local n="$1"
  local remote="${2:-origin}"
  local dir
  dir="$(_lock_dir "$n" "$remote")"
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

# unlock_issue <N> [<remote>] — idempotent; ignores missing locks.
unlock_issue() {
  local n="$1"
  local remote="${2:-origin}"
  rm -rf "$(_lock_dir "$n" "$remote")"
}
