#!/usr/bin/env bash
# lib/claude-profiles.sh — an ordered list of Claude subscriptions to fall over
# between when one hits its usage limit (issue #295).
#
# WHY THIS EXISTS. lib/usage-limit.sh (issue #294) treats the limit as a property
# of the MACHINE'S subscription and pauses all claude work until it resets. A
# machine configured with several subscriptions has no such single property:
# one subscription being full says nothing about the next. So the limit is
# tracked PER PROFILE, the step is re-run at once on the next free profile, and
# the machine-wide gate trips only when every profile is full — at the EARLIEST
# profile reset, because that is when claude work becomes possible again.
#
# CONFIGURATION. RUN_ISSUES_CLAUDE_PROFILES is a whitespace-separated, ordered
# list of `name=path` entries; the first entry is the preferred profile:
#
#   RUN_ISSUES_CLAUDE_PROFILES="main=$HOME/.config/run-issues/claude-main.token
#                               spare=$HOME/.config/run-issues/claude-spare.token"
#
# Each path is a file holding one `claude setup-token` OAuth token, mode 600.
# Only the PATH lives in the env file, never the token — the same split as the
# GitHub App private key. The token is handed to the claude process as
# CLAUDE_CODE_OAUTH_TOKEN and to nothing else: logs and state carry the profile
# NAME only. Paths may not contain whitespace (it is the list separator).
#
# Unset or empty = off: call_claude runs on the CLI's own login, as before.
#
# FAIL-CLOSED ON A BROKEN PROFILE. A missing, unreadable or empty token file
# skips that profile with a log line; it never falls through to the CLI's
# default login, for the same reason App mode never silently degrades to the
# personal gh identity: a configured identity that quietly turns into a
# different one is worse than a step that does not run.
#
# STATE. One lib/deadline-file.sh file per profile, through usage_limit_trip, so
# the per-profile state has exactly the shape, atomicity and fail-soft reading of
# the machine-wide gate — and is shared by every run on the machine the same way.
# The file is never cleared: it expires, after which the profile is picked again
# in list order, so the preferred profile returns by itself after its reset.
#
# Defines functions only; no top-level work and no `set`. Sourcing is
# side-effect-free.

_CLAUDE_PROFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=usage-limit.sh
. "$_CLAUDE_PROFILES_DIR/usage-limit.sh"

# _claude_profiles_log <message> — the caller's `log` when it has one, else
# stderr. Same discovery pattern as lib/claude-call.sh's _claude_call_log.
_claude_profiles_log() {
  if declare -F log >/dev/null 2>&1; then
    log "claude-profiles: $1"
  else
    printf '[claude-profiles %s] %s\n' "$(date -u +%FT%TZ)" "$1" >&2
  fi
}

# claude_profiles_configured — 0 when a profile list is set (non-blank).
claude_profiles_configured() {
  case "${RUN_ISSUES_CLAUDE_PROFILES:-}" in
    *[![:space:]]*) return 0 ;;
  esac
  return 1
}

# claude_profiles_list — print one "<name> <path>" line per well-formed entry,
# in configured order. A malformed entry (no `=`, empty path, or a name outside
# [A-Za-z0-9_-] — the name becomes part of a state-file path) is skipped with a
# log line, never guessed at. A repeated name keeps its first position.
claude_profiles_list() {
  local entry name path seen=" "
  # Whitespace (newlines included) IS the list syntax. `read -a` splits without
  # pathname expansion, which an unquoted `for … in $VAR` would also apply.
  local -a entries=()
  IFS=$' \t\n' read -r -d '' -a entries <<<"${RUN_ISSUES_CLAUDE_PROFILES:-}" || true
  for entry in ${entries[@]+"${entries[@]}"}; do
    name="${entry%%=*}"
    path="${entry#*=}"
    if [ "$name" = "$entry" ] || [ -z "$name" ] || [ -z "$path" ]; then
      _claude_profiles_log "WARNING: ignoring malformed RUN_ISSUES_CLAUDE_PROFILES entry (expected name=path)"
      continue
    fi
    case "$name" in
      *[!A-Za-z0-9_-]*)
        _claude_profiles_log "WARNING: ignoring Claude profile with invalid name '$name' (allowed: A-Z a-z 0-9 _ -)"
        continue ;;
    esac
    case "$seen" in *" $name "*) continue ;; esac
    seen="$seen$name "
    printf '%s %s\n' "$name" "$path"
  done
}

# claude_profile_state_file <name> — the profile's usage-limit deadline file,
# next to the machine-wide one.
claude_profile_state_file() {
  printf '%s.profile-%s' "$(usage_limit_state_file)" "$1"
}

# claude_profile_token_usable <name> <path> — 0 when the token file exists, is
# readable and non-empty. Group/world-readable permissions only warn, like the
# GitHub App key: permission models differ across hosts.
claude_profile_token_usable() {
  local name="$1" path="$2" perm=""
  if [ ! -f "$path" ]; then
    _claude_profiles_log "ERROR: token file for Claude profile '$name' not found at $path — skipping the profile (create it with 'claude setup-token', chmod 600)"
    return 1
  fi
  if [ ! -r "$path" ]; then
    _claude_profiles_log "ERROR: token file for Claude profile '$name' not readable: $path — skipping the profile"
    return 1
  fi
  if [ ! -s "$path" ]; then
    _claude_profiles_log "ERROR: token file for Claude profile '$name' is empty: $path — skipping the profile"
    return 1
  fi
  if [ "$(uname -s)" = "Darwin" ]; then
    perm=$(stat -f '%Lp' "$path" 2>/dev/null || echo "")
  else
    perm=$(stat -c '%a' "$path" 2>/dev/null || echo "")
  fi
  case "$perm" in
    600|400|"") : ;;
    *) _claude_profiles_log "WARNING: token file for Claude profile '$name' has permissions $perm — recommend 'chmod 600 $path'" ;;
  esac
  return 0
}

# claude_profile_token <path> — print the token with all whitespace removed
# (setup-token output pasted into a file usually ends in a newline). The
# caller must hand it straight to the child process and nowhere else.
claude_profile_token() {
  tr -d '[:space:]' < "$1" 2>/dev/null
}

# claude_profile_pick [<exclude-names>] [<now-epoch>] — print "<name> <path>" of
# the first profile, in configured order, that is not at its limit, has a usable
# token file and is not listed in <exclude-names> (space-separated: the profiles
# this call has already tried, so an unwritable state file cannot loop a step
# forever on the same full profile). 1 when none qualifies.
claude_profile_pick() {
  local exclude=" ${1:-} " now="${2:-$(date +%s)}" name path
  while read -r name path; do
    [ -n "$name" ] || continue
    case "$exclude" in *" $name "*) continue ;; esac
    usage_limit_active "$(claude_profile_state_file "$name")" "$now" && continue
    claude_profile_token_usable "$name" "$path" || continue
    printf '%s %s' "$name" "$path"
    return 0
  done < <(claude_profiles_list)
  return 1
}

# claude_profile_trip <name> <deadline-epoch> <source> — mark the profile full
# until <deadline>. Later deadline wins, exactly as for the machine-wide gate.
claude_profile_trip() {
  usage_limit_trip "$(claude_profile_state_file "$1")" "$2" "$3"
}

# claude_profiles_earliest_reset [<now-epoch>] — print "<deadline-epoch> <source>"
# of the profile that frees up first among those at their limit, or nothing when
# none is. This is when the machine-wide gate should lift once all are full.
claude_profiles_earliest_reset() {
  local now="${1:-$(date +%s)}" name path pair d best="" best_src=""
  while read -r name path; do
    [ -n "$name" ] || continue
    pair=$(deadline_file_read "$(claude_profile_state_file "$name")")
    d="${pair%% *}"
    [ "$d" -gt "$now" ] 2>/dev/null || continue
    if [ -z "$best" ] || [ "$d" -lt "$best" ]; then
      best="$d"
      best_src="${pair#* }"
    fi
  done < <(claude_profiles_list 2>/dev/null)
  [ -n "$best" ] && printf '%s %s' "$best" "${best_src:-reset}"
  return 0
}
