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
# Portability: this package targets macOS in practice (the lock root defaults to
# ~/Library/Application Support and the pollers run as macOS LaunchAgents), so
# "macOS-only" would be a defensible scope. Even so, the mtime read is done
# through the portable `_lock_mtime` helper (uname-branched `stat`, mirroring
# orchestrate.sh and github-app-auth.sh) rather than left latent — a bare
# `stat -f` would misbehave under GNU coreutils, and the sibling call sites
# already handle both platforms, so this keeps the codebase internally
# consistent at no extra cost.
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

# Logger — best-effort: reuse the caller's `log` function when defined
# (orchestrate.sh), otherwise fall back to a date-prefixed stderr line so a
# silent stat failure still leaves a diagnostic trail. Same pattern as
# github-app-auth.sh's `_gha_log`.
_locking_log() {
  if declare -F log >/dev/null 2>&1; then
    log "locking: $*"
  else
    printf '[locking %s] %s\n' "$(date -u +%FT%TZ)" "$*" >&2
  fi
}

# _lock_mtime <dir> — prints the directory's mtime as epoch seconds on success,
# prints nothing and returns non-zero on failure. The `stat` format flag is not
# portable: BSD/macOS uses `stat -f <fmt>` while GNU coreutils uses
# `stat -c <fmt>` (and reads `-f` as --file-system, a different operation).
# Branch on `uname -s` like the sibling call sites (orchestrate.sh:325-329,
# github-app-auth.sh:126-129) so the read is correct on both platforms.
_lock_mtime() {
  local dir="$1" mtime
  if [ "$(uname -s)" = "Darwin" ]; then
    mtime=$(stat -f %m "$dir" 2>/dev/null) || return 1
  else
    mtime=$(stat -c %Y "$dir" 2>/dev/null) || return 1
  fi
  # Guard against a successful stat that somehow yields non-numeric output.
  case "$mtime" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$mtime"
}

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
    # Conservative fallback: if the mtime cannot be read for ANY reason (stat
    # error, permissions, directory removed in a race), do NOT treat the lock
    # as stale. A lock system must default to "someone else holds it" under
    # uncertainty — the aggressive `mtime=0` fallback made `age` enormous and
    # stole a live run's lock the moment `stat` hiccuped (issue #66). Refuse to
    # steal and leave a diagnostic line so the silent failure is visible.
    if ! mtime=$(_lock_mtime "$dir"); then
      _locking_log "WARNING: cannot read mtime of lock dir $dir — treating as held (not stealing)"
      return 1
    fi
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
