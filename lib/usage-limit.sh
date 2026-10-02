#!/usr/bin/env bash
# lib/usage-limit.sh — the machine-wide Claude usage-limit gate (issue #294).
#
# WHY THIS EXISTS. A claude call that hits the subscription's usage limit used to
# end like any other failure: the cycle review produced no decision line, the
# orchestrator died silently under `set -e`, and every later tick picked the
# next issue straight into the same limit. The limit is a property of the
# MACHINE'S subscription, not of the run or the issue, so the honest response is
# machine-wide: stop starting claude work here until the limit resets.
#
# DETECTION lives in lib/claude-call.sh (claude_usage_limit_check), next to the
# call whose output it reads — the same "textual, after the fact" stance
# lib/rate-limit.sh takes for GitHub, for the same reason: nothing reliable can
# be asked in advance. This module only stores and answers the deadline.
#
# STATE. One line, "<deadline-epoch> <source>", where source is `reset` (the
# deadline was parsed from the limit message) or `backoff` (it was not, and
# RUN_ISSUES_USAGE_LIMIT_BACKOFF was used). Same file shape and same fail-soft
# rules as the rate-limit backoff (lib/deadline-file.sh): a missing or corrupt
# file means "no limit", never an error and never a permanent block.
#
# Deliberately a DIFFERENT file from the rate-limit backoff. That one is shared
# by both pollers because they spend one GitHub quota; this one gates claude
# work only — teardown, reconciliation and epic propagation make no claude call
# and keep running while the limit is in force.
#
# Defines functions only; no top-level work. Sourcing is side-effect-free.

_USAGE_LIMIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=paths.sh
. "$_USAGE_LIMIT_DIR/paths.sh"
# shellcheck source=deadline-file.sh
. "$_USAGE_LIMIT_DIR/deadline-file.sh"

# Fallback wait when the limit message carries no parseable reset time. One
# hour: the subscription windows are hours long, and a too-short guess only
# costs one more limited call, while a too-long one idles a recovered machine.
USAGE_LIMIT_BACKOFF_DEFAULT=3600

# usage_limit_enabled — 1 unless RUN_ISSUES_USAGE_LIMIT_DETECTION is exactly
# "0". The kill switch exists for the same reason RUN_ISSUES_RATE_LIMIT_BACKOFF
# does: a new gate must never become the reason a healthy machine will not run.
# Off means BOTH halves are off — nothing is detected and nothing is gated.
usage_limit_enabled() {
  [ "${RUN_ISSUES_USAGE_LIMIT_DETECTION:-1}" != "0" ]
}

# usage_limit_backoff_seconds — the effective fallback wait. A non-numeric or
# zero override degrades to the default rather than to "no wait".
usage_limit_backoff_seconds() {
  local v="${RUN_ISSUES_USAGE_LIMIT_BACKOFF:-$USAGE_LIMIT_BACKOFF_DEFAULT}"
  case "$v" in ''|*[!0-9]*|0) v="$USAGE_LIMIT_BACKOFF_DEFAULT" ;; esac
  printf '%s' "$v"
}

# usage_limit_state_file — path of the machine's usage-limit state file.
usage_limit_state_file() {
  printf '%s/.claude-usage-limit' "${RUN_ISSUES_LOG_DIR:-$(default_log_dir)}"
}

# usage_limit_trip <path> <deadline-epoch> <source> — record the limit. Keeps
# the LATER of the stored and the new deadline: two runs hitting the limit in
# one window must not let the second (say, a backoff guess) shorten a reset time
# the first one actually read. Returns 1 when the kill switch is off.
usage_limit_trip() {
  local f="${1:-}" d="${2:-0}" src="${3:-}"
  usage_limit_enabled || return 1
  case "$d" in ''|*[!0-9]*) return 1 ;; esac
  local pair cur
  pair=$(deadline_file_read "$f")
  cur="${pair%% *}"
  if [ "$cur" -ge "$d" ] 2>/dev/null; then
    return 0
  fi
  deadline_file_write "$f" "$d" "$src" || true
  return 0
}

# usage_limit_active <path> [<now-epoch>] — 0 while a recorded deadline is in
# the future, i.e. the caller must NOT start claude work this tick. Sets
# USAGE_LIMIT_DEADLINE so the caller can report when it expires. A past
# deadline, a missing file or the kill switch all yield 1 (go ahead) — the file
# never needs clearing, it simply expires.
usage_limit_active() {
  local f="${1:-}" now="${2:-$(date +%s)}" pair
  USAGE_LIMIT_DEADLINE=0
  usage_limit_enabled || return 1
  pair=$(deadline_file_read "$f")
  USAGE_LIMIT_DEADLINE="${pair%% *}"
  [ "$USAGE_LIMIT_DEADLINE" -gt "$now" ] 2>/dev/null
}

# usage_limit_status_json <path> [<now-epoch>] — the shape status.sh folds into
# its `runner` object: {usage_limited_until, usage_limit_wait_seconds}. Both are
# null when no limit is ACTIVE, so a stale file never makes a healthy machine
# look limited. Read-only: status.sh must never write this file.
usage_limit_status_json() {
  local f="${1:-}" now="${2:-$(date +%s)}" pair d
  pair=$(deadline_file_read "$f")
  d="${pair%% *}"
  if usage_limit_enabled && [ "$d" -gt "$now" ] 2>/dev/null; then
    printf '{"usage_limited_until":%s,"usage_limit_wait_seconds":%s}' "$d" "$((d - now))"
  else
    printf '{"usage_limited_until":null,"usage_limit_wait_seconds":null}'
  fi
}
