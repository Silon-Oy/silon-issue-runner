#!/usr/bin/env bash
# lib/audit-schedule.sh — when the poller starts a whole-repo audit (issue #340).
#
# A one-off audit goes stale the day a dependency gains a new vulnerability, so
# the poller repeats it per (repo × remote) once its interval has passed. This
# file holds the decision; poller.sh's _dispatch_audit_pass holds the spawn.
#
# The audit KIND is a parameter, not a copy (the same rule as teardown_run,
# CLAUDE.md §7): a second audit kind adds one row to audit_kind_script and to
# audit_kind_env_var and one word to audit_kinds, and goes through the same
# interval, state and cap logic.
#
# Cost (CLAUDE.md §5.3, §5.4): the last audit time is a one-line state file per
# (kind, repo × remote), read in O(1). Nothing here reads run-dirs, state.jsonl,
# logs or GitHub.
#
# Kinds: security (security-audit.sh, #339) and coherence (coherence-audit.sh,
# #342).
#
# CALLING CONTRACT — every kind's script MUST accept exactly this form, because
# the spawn has no per-kind branch (#360, for #342 and any later kind):
#
#   <script> <repo-path> --remote <r> --watchlist <wl>
#
# and MUST read the rest of its configuration from the environment it inherits
# (RUN_ISSUES_LOG_DIR, RUN_ISSUES_POLLER_ENV_FILE, RUN_ISSUES_AUTO=1). Its exit
# code is the outcome audit_run records: 0 = done, 5 = done but one scanner
# failed (the review itself ran) — _audit_succeeded treats both as an audit
# that happened; anything else is retried after RUN_ISSUES_AUDIT_RETRY_HOURS.
# A kind whose script needs another argument changes this contract and the
# spawn in poller.sh together, never one of them.
#
# Visibility (#360): the session is named audit_session_name, under
# audit_session_prefix, so status.sh lists running audits from one `tmux ls`
# through audit_session_parse instead of deriving the name a second time.
#
# The time is recorded when the audit STARTS, not when it ends: an audit that
# fails every time (no remote HEAD, agent cannot launch) then costs a bounded
# number of attempts instead of one agent call per tick. Its OUTCOME is recorded
# next to it when the audit ends (audit_run): a start without a successful
# outcome — a failure, or a session that never got to write one — is retried
# after RUN_ISSUES_AUDIT_RETRY_HOURS instead of waiting a whole interval.
#
# Defines functions only; no top-level work and no `set`.

_AUDIT_SCHEDULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/deadline-file.sh
. "$_AUDIT_SCHEDULE_DIR/deadline-file.sh"

# audit_kinds — the audit kinds the poller schedules, space-separated.
audit_kinds() {
  printf 'security coherence'
}

# audit_kind_script <kind> — the package-root script that runs <kind>. An
# explicit table rather than a derived file name, so an unknown kind can never
# launch a guessed path. rc 1 (and no output) for an unknown kind.
audit_kind_script() {
  case "${1:-}" in
    security)  printf 'security-audit.sh' ;;
    coherence) printf 'coherence-audit.sh' ;;
    *) return 1 ;;
  esac
}

# audit_kind_env_var <kind> — the machine-level interval variable of <kind>,
# named RUN_ISSUES_<KIND>_AUDIT_INTERVAL_DAYS. Spelled out per kind rather than
# derived, so the name stays greppable: tests/test-poller-config.sh flags an
# example variable that no reader names. rc 1 for an unknown kind.
audit_kind_env_var() {
  case "${1:-}" in
    security)  printf 'RUN_ISSUES_SECURITY_AUDIT_INTERVAL_DAYS' ;;
    coherence) printf 'RUN_ISSUES_COHERENCE_AUDIT_INTERVAL_DAYS' ;;
    *) return 1 ;;
  esac
}

# _audit_positive_days <value> — prints <value> as a plain integer when it is a
# positive whole number of days (at most six digits), else nothing.
_audit_positive_days() {
  local v="${1:-}"
  case "$v" in ''|*[!0-9]*) return 0 ;; esac
  [ "${#v}" -le 6 ] || return 0
  v=$((10#$v))
  [ "$v" -gt 0 ] && printf '%s' "$v"
  return 0
}

# audit_interval_days <repo-config-json> <kind> <machine-value> — the interval
# in days, or nothing when <kind> is not scheduled for this repo.
#
# The repo's `.<kind>.audit_interval_days` in .claude/run-issues.json wins over
# the machine value when it is present at all — so a repo can switch off an
# audit the machine schedules (`0`) as well as schedule one the machine does
# not. How often an application is audited is a property of the application,
# the same reasoning as finding_issues_auto_run_min.
#
# Unset, `0`, a non-integer and an unparseable config all print nothing: the
# safe side of an unattended agent run is not to start it (CLAUDE.md §9).
audit_interval_days() {
  local cfg="${1:-}" kind="${2:-}" machine="${3:-}" repo_val="@absent"
  audit_kind_script "$kind" >/dev/null || return 0
  if [ -n "$cfg" ]; then
    repo_val=$(jq -r --arg k "$kind" '
      (if type == "object" then (.[$k] // {}) else error("not an object") end) as $s
      | if ($s | type) == "object" and ($s | has("audit_interval_days")) and $s.audit_interval_days != null
        then ($s.audit_interval_days | tostring) else "@absent" end
    ' <<<"$cfg" 2>/dev/null) || return 0
  fi
  if [ "$repo_val" = "@absent" ]; then
    _audit_positive_days "$machine"
  else
    _audit_positive_days "$repo_val"
  fi
}

# audit_interval_problem <repo-config-json> <kind> <machine-value> — one line
# saying why the repo's config leaves <kind> unscheduled, or nothing. The poller
# logs it (#360): audit_interval_days reads both an unparseable config and a bad
# value as "not scheduled", which is the safe side but was silent.
#
# A bad `.<kind>.audit_interval_days` (`1.5`, `"x"`, `-1`) is always reported —
# the repo asked for a schedule. Unparseable JSON is reported only when the
# machine schedules <kind> (<machine-value> set): otherwise a broken file says
# nothing about audits. Absent, null, `0` (deliberately off) and a positive
# whole number print nothing.
audit_interval_problem() {
  local cfg="${1:-}" kind="${2:-}" machine="${3:-}" val
  audit_kind_script "$kind" >/dev/null || return 0
  [ -n "$cfg" ] || return 0
  if ! val=$(jq -r --arg k "$kind" '
      (if type == "object" then (.[$k] // {}) else error("not an object") end) as $s
      | if ($s | type) == "object" and ($s | has("audit_interval_days")) and $s.audit_interval_days != null
        then ($s.audit_interval_days | tostring) else "@absent" end
    ' <<<"$cfg" 2>/dev/null); then
    [ -n "$machine" ] || return 0
    printf '.claude/run-issues.json on the default branch is not a valid JSON object — %s audit not scheduled' "$kind"
    return 0
  fi
  [ "$val" = "@absent" ] && return 0
  [ -n "$(_audit_positive_days "$val")" ] && return 0
  case "$val" in ''|*[!0-9]*) ;; *) [ "${#val}" -le 6 ] && [ "$((10#$val))" -eq 0 ] && return 0 ;; esac
  printf 'invalid .%s.audit_interval_days %s in .claude/run-issues.json (want 0 or a positive whole number of days) — %s audit not scheduled' \
    "$kind" "$(printf '%s' "$val" | tr -d '\n' | cut -c1-40)" "$kind"
}

# audit_notice <state-file> <log> <tag> <message> — append <message> to <log>
# once, not on every tick (CLAUDE.md §5.7). The last logged message per <tag> is
# kept in <state-file>.notice-<tag>; the line is written again only when the
# message changes or audit_notice_clear removed it, so a condition that goes
# away and comes back is reported again.
#
# When the notice file itself cannot be written (the "cannot record" case: the
# state directory refuses writes), the log's last 500 lines stand in for it —
# a tick writes far fewer, so the line still appears once per such window rather
# than once per tick. tail only (§5.3).
audit_notice() {
  local state="${1:-}" log="${2:-}" tag="${3:-}" msg="${4:-}" nf prev tmp
  [ -n "$state" ] && [ -n "$tag" ] && [ -n "$msg" ] || return 0
  nf="${state}.notice-${tag}"
  prev=$(head -n 1 "$nf" 2>/dev/null || true)
  [ "$prev" = "$msg" ] && return 0
  if tmp=$(mktemp "${nf}.XXXXXX" 2>/dev/null) \
     && printf '%s\n' "$msg" > "$tmp" 2>/dev/null && mv -f "$tmp" "$nf" 2>/dev/null; then
    :
  else
    [ -n "${tmp:-}" ] && rm -f "$tmp" 2>/dev/null
    tail -n 500 "$log" 2>/dev/null | grep -qF -- "$msg" && return 0
  fi
  printf '%s poller: %s\n' "$(date -u +%FT%TZ)" "$msg" >> "$log"
}

# audit_notice_clear <state-file> <tag> — the condition behind <tag> is gone.
audit_notice_clear() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 0
  rm -f "${1}.notice-${2}" 2>/dev/null
  return 0
}

# audit_session_prefix — every audit session's name starts with this. It begins
# with `run-issues-`, so the poller's cap count includes audits.
audit_session_prefix() {
  printf 'run-issues-audit-'
}

# audit_session_name <kind> <repo-slug> — the tmux session of one audit.
audit_session_name() {
  printf '%s%s-%s' "$(audit_session_prefix)" "${1:-}" "${2:-}"
}

# audit_session_parse <session-name> — prints "<kind> <repo-slug>" for an audit
# session, rc 1 otherwise. The kind is matched against audit_kinds (a kind has
# no dash, a slug may), so an unknown kind is not read as an audit.
audit_session_parse() {
  local name="${1:-}" pre rest k
  pre=$(audit_session_prefix)
  case "$name" in "$pre"*) ;; *) return 1 ;; esac
  rest="${name#"$pre"}"
  for k in $(audit_kinds); do
    case "$rest" in
      "$k"-?*) printf '%s %s' "$k" "${rest#"$k"-}"; return 0 ;;
    esac
  done
  return 1
}

# audit_state_file <log-dir> <kind> <repo-slug> — where the last start time of
# <kind> for one repo × remote is recorded.
audit_state_file() {
  printf '%s/.audit-last-%s-%s' "${1:-}" "${2:-}" "${3:-}"
}

# audit_result_file <state-file> — where the outcome of the recorded start is
# kept: "<start-epoch> <exit-code>".
audit_result_file() {
  printf '%s.result' "${1:-}"
}

# _audit_succeeded <state-file> <start-epoch> — rc 0 when the start at
# <start-epoch> ended in an audit that happened: exit 0, or 5 (done, one scanner
# failed — the agent review itself ran). Anything else, a result for another
# start, or no result at all is not a success.
_audit_succeeded() {
  local r start rc
  r=$(deadline_file_read "$(audit_result_file "${1:-}")")
  start="${r%% *}"
  rc="${r#* }"
  [ "$start" = "${2:-}" ] || return 1
  case "$rc" in 0|5) return 0 ;; esac
  return 1
}

# audit_retry_secs — how long after an unsuccessful start the audit is retried:
# RUN_ISSUES_AUDIT_RETRY_HOURS (default 24). Junk reads as the default.
audit_retry_secs() {
  local h="${RUN_ISSUES_AUDIT_RETRY_HOURS:-24}"
  case "$h" in ''|*[!0-9]*) h=24 ;; esac
  h=$((10#$h))
  [ "$h" -gt 0 ] || h=24
  printf '%s' "$((h * 3600))"
}

# audit_due <state-file> <interval-days> <now-epoch> — rc 0 when the audit is
# due. A missing or unreadable file means "never audited", i.e. due; so does a
# recorded time in the future, which a clock jump or a bad write could leave
# behind and which must not postpone the audit forever. A start without a
# successful outcome is due again after audit_retry_secs (a running audit is
# not restarted: the caller checks its session first).
audit_due() {
  local f="${1:-}" days="${2:-}" now="${3:-0}" last age
  days=$(_audit_positive_days "$days")
  [ -n "$days" ] || return 1
  last=$(deadline_file_read "$f")
  last="${last%% *}"
  [ "$last" -gt 0 ] || return 0
  [ "$last" -le "$now" ] || return 0
  age=$((now - last))
  [ "$age" -ge $((days * 86400)) ] && return 0
  _audit_succeeded "$f" "$last" && return 1
  [ "$age" -ge "$(audit_retry_secs)" ]
}

# audit_run <state-file> <start-epoch> <script> [args...] — run one audit and
# record its outcome against <start-epoch>. The poller's tmux session runs this,
# so the outcome is written by the audit's own process and never by the tick.
# Returns the script's exit code.
audit_run() {
  local f="${1:-}" start="${2:-0}" rc=0
  shift 2
  "$@" || rc=$?
  deadline_file_write "$(audit_result_file "$f")" "$start" "$rc" || true
  return "$rc"
}

# audit_record <state-file> <now-epoch> <kind> — atomically record a start.
# rc 1 when the file could not be written; the caller then does NOT start the
# audit, since an unrecordable start would repeat on every tick.
audit_record() {
  deadline_file_write "${1:-}" "${2:-0}" "${3:-}"
}
