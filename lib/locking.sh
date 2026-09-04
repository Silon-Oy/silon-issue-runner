#!/usr/bin/env bash
# lib/locking.sh — per-issue lock directory, atomic via mkdir(2).
#
# The lock root default is platform-dependent — lib/paths.sh:default_lock_root
# owns both branches. It survives reboot and is not synced to iCloud.
# Each lock is a directory named `<label>.lock` (see remote_label in
# git-remote.sh for the label shapes) containing a `pid` file and an
# `acquired_at` file with an ISO-8601 timestamp.
#
# Multi-remote namespacing: the same clone can poll multiple GitHub orgs at
# once (issue #53). `Silon-Oy/...#5` and `partner-org/...#5` are different
# issues with the same number, so the lock name must include the remote
# whenever it is not the legacy `origin` — otherwise they would collide on
# the same lock. Origin keeps the legacy `issue-<N>.lock` shape so existing
# locks are not orphaned by the upgrade.
#
# Repo namespacing (issue #67): the lock root is a single flat, GLOBAL
# namespace, so the remote alone was not enough — `report#42` and
# `app#42` both hashed to `issue-42.lock`. Every caller that owns a run now
# passes the run's repo slug as the third argument, which makes the lock name
# `<repo-slug>-issue-<N>.lock`. During the transition window an in-flight run
# started by the previous version still holds an unqualified `issue-<N>.lock`;
# lock_issue therefore treats a FRESH unqualified lock as held (see
# _legacy_lock_is_live) so the upgrade cannot spawn a second run for an issue
# whose old-style lock is still live.
#
# Portability: the mtime read is done through the portable `_lock_mtime` helper
# (uname-branched `stat`, mirroring orchestrate.sh and github-app-auth.sh)
# rather than left latent — a bare `stat -f` would misbehave under GNU
# coreutils. The lock root itself branches on the same `uname -s` test, one
# level up, in lib/paths.sh.
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
# default_lock_root — the platform default for the lock root. Function-only.
# shellcheck source=paths.sh
. "$_LOCKING_DIR/paths.sh"

RUN_ISSUES_LOCK_ROOT="${RUN_ISSUES_LOCK_ROOT:-$(default_lock_root)}"
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

# _lock_dir <issue-num> [<remote>] [<repo-slug>]
# Prints the absolute lock directory path. Both trailing arguments are optional:
# the remote defaults to "origin" and an omitted repo slug reproduces the
# pre-#67 name. That is what keeps legacy callers, legacy locks and one-arg test
# fixtures working unchanged — and it is also how callers ASK for the legacy
# name on purpose (see _legacy_lock_is_live and cleanup-run.sh).
_lock_dir() {
  local n="$1"
  local remote="${2:-origin}"
  local slug="${3:-}"
  local label
  label=$(remote_label "$remote" "$n" "$slug")
  printf '%s/%s.lock' "$RUN_ISSUES_LOCK_ROOT" "$label"
}

# _legacy_lock_is_live <issue-num> <remote>
# Transition guard (issue #67). Returns 0 when an unqualified (pre-repo-slug)
# lock for this issue exists and is still fresh, i.e. some run started by the
# previous version of this package holds it and we must NOT start a second run.
# Returns 1 when there is no such lock or it is stale — a stale one is removed
# as garbage, since no live run can be behind it.
#
# The unqualified name is ambiguous across repos by construction (that is the
# bug being fixed), so this guard is deliberately CONSERVATIVE: the worst case
# is one skipped pickup that the next poller cycle retries, never a stolen lock.
# The window closes on its own — the last legacy lock disappears when the last
# pre-upgrade run finishes.
_legacy_lock_is_live() {
  local n="$1"
  local remote="${2:-origin}"
  local legacy
  legacy="$(_lock_dir "$n" "$remote")"
  [ -d "$legacy" ] || return 1

  local mtime now age
  if ! mtime=$(_lock_mtime "$legacy"); then
    _locking_log "WARNING: cannot read mtime of legacy lock $legacy — treating as held (not stealing)"
    return 0
  fi
  now=$(date +%s)
  age=$(( now - mtime ))
  if [ "$age" -gt "$RUN_ISSUES_LOCK_STALE_SECS" ]; then
    _locking_log "legacy lock $legacy is stale (${age}s) — removing"
    rm -rf "$legacy"
    return 1
  fi
  _locking_log "legacy (pre-repo-slug) lock held at $legacy — refusing to start a second run for issue #$n"
  return 0
}

# lock_issue <N> [<remote>] [<repo-slug>] — returns 0 if lock acquired, 1 if
# held by another run (either under the same repo-namespaced name, or under the
# legacy unqualified name during the transition window).
lock_issue() {
  local n="$1"
  local remote="${2:-origin}"
  local slug="${3:-}"
  local dir
  dir="$(_lock_dir "$n" "$remote" "$slug")"
  mkdir -p "$RUN_ISSUES_LOCK_ROOT"

  if mkdir "$dir" 2>/dev/null; then
    printf '%s' "$$" > "$dir/pid"
    date -u +%FT%TZ > "$dir/acquired_at"
    # Transition check runs only for repo-namespaced callers: a caller that
    # asked for the legacy name IS the legacy shape and just took it above.
    if [ -n "$slug" ] && _legacy_lock_is_live "$n" "$remote"; then
      rm -rf "$dir"
      return 1
    fi
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
        # Same transition check as the fresh-acquire path above: stealing our
        # own repo's stale lock says nothing about a live legacy-named run.
        if [ -n "$slug" ] && _legacy_lock_is_live "$n" "$remote"; then
          rm -rf "$dir"
          return 1
        fi
        return 0
      fi
    fi
  fi
  return 1
}

# unlock_issue <N> [<remote>] [<repo-slug>] — idempotent; ignores missing locks.
# Removes exactly the name the caller acquired. It deliberately does NOT also
# remove the legacy unqualified name: that name may belong to another repo's
# live run (the #67 bug), and a caller that got here past _legacy_lock_is_live
# knows the legacy lock was either absent or already garbage-collected.
unlock_issue() {
  local n="$1"
  local remote="${2:-origin}"
  local slug="${3:-}"
  rm -rf "$(_lock_dir "$n" "$remote" "$slug")"
}
