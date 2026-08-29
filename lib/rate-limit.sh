#!/usr/bin/env bash
# lib/rate-limit.sh — GitHub rate-limit detection and backoff (issue #126).
#
# WHY THIS EXISTS. Nothing in the package noticed when GitHub started rejecting
# calls. Every tick re-ran the full sweep, and each rejected request fed the
# secondary limit that caused the rejection — the system actively prolonged its
# own outage. On 2026-08-28 that outage lasted over ten hours and produced 1754
# identical stderr lines while no signal reached anyone.
#
# WHY NOT ASK GitHub HOW MUCH QUOTA IS LEFT. Because the meter lies. Measured on
# 2026-08-29: `gh api rate_limit` was read, three calls were made
# (`gh issue list --search`, `gh issue view`, `gh issue list --label`), and the
# meter was read again — the search, graphql and core counters had NOT MOVED.
# During the outage the same endpoint reported `graphql 5000/5000, used 0` while
# every call failed. The blocking limit is secondary and simply is not exposed.
#
# THE BINDING CONSEQUENCE: never gate a call on a quota reading. The only honest
# signal is the rejection itself, so detection is textual and after the fact.
#
# STATE. One line, "<deadline-epoch> <step>", in a file next to the poller logs —
# the same shape and the same fail-soft rules as pr-watch-poller's rotation
# cursor: a missing or unparseable file means "no backoff, start from step 0",
# never an error and never a permanent block. The file is SHARED by both pollers
# on purpose: they spend the same quota, so one backing off while the other keeps
# firing would not help.
#
# Defines functions only; no top-level work. Sourcing is side-effect-free.

# Backoff ladder in seconds. Doubling from one poller interval up to an hour;
# the cap matters because a deadline further out than the outage would idle the
# factory long after GitHub recovered.
RATE_LIMIT_STEPS_DEFAULT="300 600 1200 2400 3600"

# rate_limit_enabled — 1 unless RUN_ISSUES_RATE_LIMIT_BACKOFF is exactly "0".
# The kill switch exists for the same reason RUN_ISSUES_SKIP_PREFLIGHT does: a
# new gate must never become the reason a healthy machine will not run.
rate_limit_enabled() {
  [ "${RUN_ISSUES_RATE_LIMIT_BACKOFF:-1}" != "0" ]
}

# rate_limit_matches <text> — 0 when the text carries a GitHub rate-limit
# rejection. Pure; no I/O.
#
# Matching is deliberately NARROW. A false positive is worse than a false
# negative here: it would idle the whole factory on an ordinary 404. Only
# phrases GitHub itself uses for throttling are accepted, and an ordinary error
# ("Could not resolve to an Issue", "HTTP 422") must not match — that case is
# pinned in tests/test-rate-limit-backoff.sh.
rate_limit_matches() {
  local lower
  lower=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *"api rate limit"*)       return 0 ;;
    *"secondary rate limit"*) return 0 ;;
    *"abuse detection"*)      return 0 ;;
    *"rate limit exceeded"*)  return 0 ;;
  esac
  return 1
}

# rate_limit_file_matches <path> — 0 when the file exists and contains a
# rejection. Missing or unreadable file => 1 (no detection), never an error.
rate_limit_file_matches() {
  local f="${1:-}"
  [ -n "$f" ] && [ -s "$f" ] || return 1
  rate_limit_matches "$(cat "$f" 2>/dev/null || printf '')"
}

# rate_limit_state_file — path of the shared backoff state file.
rate_limit_state_file() {
  printf '%s/.rate-limit-backoff' "${RUN_ISSUES_LOG_DIR:-${HOME}/Library/Logs}"
}

# _rate_limit_read <path> — sets RATE_LIMIT_DEADLINE and RATE_LIMIT_STEP from the
# state file, defaulting to 0/0. Anything unparseable degrades to the defaults:
# a corrupt file must not be able to wedge the factory shut.
_rate_limit_read() {
  RATE_LIMIT_DEADLINE=0
  RATE_LIMIT_STEP=0
  local line d s
  line=$(cat "${1:-}" 2>/dev/null || printf '')
  [ -n "$line" ] || return 0
  d="${line%% *}"
  s="${line##* }"
  case "$d" in ''|*[!0-9]*) d=0 ;; esac
  case "$s" in ''|*[!0-9]*) s=0 ;; esac
  RATE_LIMIT_DEADLINE="$d"
  RATE_LIMIT_STEP="$s"
}

# rate_limit_active <path> [<now-epoch>] — 0 when a backoff deadline is still in
# the future, i.e. the caller must NOT make network calls this tick. Also sets
# RATE_LIMIT_DEADLINE so the caller can report when it expires.
#
# A deadline in the past, a missing file, or the kill switch all yield 1 (go
# ahead). A deadline absurdly far in the future (clock moved backwards while the
# file was written) is NOT special-cased: it is bounded by the ladder cap, so the
# worst case is one hour of idling, which self-heals.
rate_limit_active() {
  local f="${1:-}" now="${2:-$(date +%s)}"
  rate_limit_enabled || { RATE_LIMIT_DEADLINE=0; return 1; }
  _rate_limit_read "$f"
  [ "$RATE_LIMIT_DEADLINE" -gt "$now" ] 2>/dev/null
}

# rate_limit_trip <path> [<now-epoch>] — escalate one rung and write the new
# deadline. Prints "<deadline-epoch> <seconds>" so the caller can log it.
# No-op (prints nothing, returns 1) when the kill switch is off.
#
# The step index is remembered rather than derived from the deadline so a tick
# that trips again right after a deadline expires escalates instead of resetting
# — an outage that outlasts the ladder must not be re-probed every five minutes.
rate_limit_trip() {
  local f="${1:-}" now="${2:-$(date +%s)}"
  rate_limit_enabled || return 1
  _rate_limit_read "$f"
  local i=0 secs=0 s
  for s in ${RATE_LIMIT_STEPS_DEFAULT}; do
    secs="$s"
    [ "$i" -ge "$RATE_LIMIT_STEP" ] && break
    i=$((i + 1))
  done
  local next_step=$((RATE_LIMIT_STEP + 1))
  local deadline=$((now + secs))
  local tmp
  tmp=$(mktemp "${f}.XXXXXX" 2>/dev/null) || { printf '%s %s' "$deadline" "$secs"; return 0; }
  printf '%s %s\n' "$deadline" "$next_step" > "$tmp" 2>/dev/null
  mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  printf '%s %s' "$deadline" "$secs"
}

# rate_limit_clear <path> — forget the backoff after a tick that completed its
# network work without a rejection. Removing the file (rather than writing a
# zero) keeps "no file" the single representation of the healthy state.
rate_limit_clear() {
  local f="${1:-}"
  [ -n "$f" ] || return 0
  rm -f "$f" 2>/dev/null || true
  return 0
}

# rate_limit_status_json <path> [<now-epoch>] — the shape status.sh folds into
# its `runner` object: {rate_limited_until, rate_limit_backoff_seconds}.
# rate_limited_until is null when there is no ACTIVE backoff, so a stale file
# never makes a healthy runner look throttled.
rate_limit_status_json() {
  local f="${1:-}" now="${2:-$(date +%s)}"
  _rate_limit_read "$f"
  if [ "$RATE_LIMIT_DEADLINE" -gt "$now" ] 2>/dev/null; then
    printf '{"rate_limited_until":%s,"rate_limit_backoff_seconds":%s}' \
      "$RATE_LIMIT_DEADLINE" "$((RATE_LIMIT_DEADLINE - now))"
  else
    printf '{"rate_limited_until":null,"rate_limit_backoff_seconds":null}'
  fi
}
