#!/usr/bin/env bash
# test-audit-schedule.sh — unit tests for lib/audit-schedule.sh (issue #340):
# the kind table, interval precedence (repo > watchlist > machine, unset = not
# scheduled), the due check, the atomic start record and the last outcome
# status.sh shows (#373). No network, no tmux.
#
# Run: bash tests/test-audit-schedule.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available"
  exit 0
fi

# shellcheck source=../lib/jq-binary.sh
. "$ROOT/lib/jq-binary.sh"
# shellcheck source=../lib/audit-schedule.sh
. "$ROOT/lib/audit-schedule.sh"

FAIL=0
check() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 — got '$2', want '$3'"; FAIL=1; fi
}
rc_of() { "$@" >/dev/null 2>&1; printf '%s' "$?"; }

WORK=$(mktemp -d -t audit-schedule.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ---- kind table -----------------------------------------------------------------
check "security and coherence are the scheduled kinds" "$(audit_kinds)" "security coherence"
check "security runs security-audit.sh" "$(audit_kind_script security)" "security-audit.sh"
check "the script exists in the package root" "$([ -x "$ROOT/$(audit_kind_script security)" ] && echo y)" "y"
check "security interval variable" "$(audit_kind_env_var security)" "RUN_ISSUES_SECURITY_AUDIT_INTERVAL_DAYS"
check "coherence runs coherence-audit.sh" "$(audit_kind_script coherence)" "coherence-audit.sh"
check "coherence interval variable" "$(audit_kind_env_var coherence)" "RUN_ISSUES_COHERENCE_AUDIT_INTERVAL_DAYS"
check "unknown kind has no script" "$(audit_kind_script nosuch)" ""
check "unknown kind fails" "$(rc_of audit_kind_script nosuch)" "1"
check "unknown kind has no variable" "$(rc_of audit_kind_env_var nosuch)" "1"
check "a path-like kind is unknown" "$(audit_kind_script ../security)" ""
for k in $(audit_kinds); do
  check "every scheduled kind ($k) resolves to an executable script" \
    "$([ -x "$ROOT/$(audit_kind_script "$k")" ] && echo y)" "y"
done

# ---- interval precedence --------------------------------------------------------
check "unset everywhere: not scheduled" "$(audit_interval_days '' security '')" ""
check "machine only" "$(audit_interval_days '' security 7)" "7"
check "config without the key: machine" "$(audit_interval_days '{"security":{"hold_min_severity":"low"}}' security 7)" "7"
check "repo wins over machine" "$(audit_interval_days '{"security":{"audit_interval_days":30}}' security 7)" "30"
check "repo schedules what the machine does not" "$(audit_interval_days '{"security":{"audit_interval_days":14}}' security '')" "14"
check "repo 0 switches the machine's schedule off" "$(audit_interval_days '{"security":{"audit_interval_days":0}}' security 7)" ""
check "repo string number accepted" "$(audit_interval_days '{"security":{"audit_interval_days":"10"}}' security '')" "10"
check "repo null falls back to machine" "$(audit_interval_days '{"security":{"audit_interval_days":null}}' security 3)" "3"
check "machine 0 is off" "$(audit_interval_days '' security 0)" ""
check "machine junk is off" "$(audit_interval_days '' security weekly)" ""
check "fraction is off" "$(audit_interval_days '{"security":{"audit_interval_days":1.5}}' security 7)" ""
check "negative is off" "$(audit_interval_days '{"security":{"audit_interval_days":-1}}' security 7)" ""
check "leading zero is decimal, not octal" "$(audit_interval_days '' security 08)" "8"
check "absurdly large is off" "$(audit_interval_days '' security 99999999)" ""
check "invalid JSON is off, even with a machine value" "$(audit_interval_days '{not json' security 7)" ""
check "non-object config is off" "$(audit_interval_days '[1,2]' security 7)" ""
check "another kind's key does not apply" "$(audit_interval_days '{"coherence":{"audit_interval_days":1}}' security '')" ""
check "coherence reads its own key" "$(audit_interval_days '{"coherence":{"audit_interval_days":3}}' coherence 7)" "3"
check "security's key does not apply to coherence" "$(audit_interval_days '{"security":{"audit_interval_days":1}}' coherence '')" ""
check "coherence 0 switches the machine's schedule off" "$(audit_interval_days '{"coherence":{"audit_interval_days":0}}' coherence 7)" ""
check "unknown kind is never scheduled" "$(audit_interval_days '{"nosuch":{"audit_interval_days":1}}' nosuch 1)" ""

# ---- state file -------------------------------------------------------------------
check "state file path" "$(audit_state_file /logs security org-repo)" "/logs/.audit-last-security-org-repo"

NOW=1800000000
DAY=86400
F="$WORK/.audit-last-security-x"
check "never audited is due" "$(rc_of audit_due "$F" 7 "$NOW")" "0"
check "record succeeds" "$(rc_of audit_record "$F" "$NOW" security)" "0"
# The interval checks below are about a start that ended well.
printf '%s 0\n' "$NOW" > "$(audit_result_file "$F")"
check "record content" "$(cat "$F")" "$NOW security"
check "just recorded is not due" "$(rc_of audit_due "$F" 7 "$NOW")" "1"
check "one second before the interval is not due" "$(rc_of audit_due "$F" 7 $((NOW + 7 * DAY - 1)))" "1"
check "exactly the interval is due" "$(rc_of audit_due "$F" 7 $((NOW + 7 * DAY)))" "0"
check "an empty interval is never due" "$(rc_of audit_due "$F" '' $((NOW + 100 * DAY)))" "1"
echo garbage > "$F"
check "a corrupt state file is due" "$(rc_of audit_due "$F" 7 "$NOW")" "0"
echo "$((NOW + 10 * DAY)) security" > "$F"
check "a recorded time in the future is due" "$(rc_of audit_due "$F" 7 "$NOW")" "0"
# ---- outcome and retry --------------------------------------------------------------
G="$WORK/.audit-last-security-retry"
audit_record "$G" "$NOW" security
check "result file sits next to the state file" "$(audit_result_file "$G")" "$G.result"
check "no outcome yet: not due within the retry delay" "$(rc_of audit_due "$G" 30 $((NOW + DAY - 1)))" "1"
check "no outcome after the retry delay: due (killed session)" "$(rc_of audit_due "$G" 30 $((NOW + DAY)))" "0"
printf '%s 3\n' "$NOW" > "$G.result"
check "failed audit: due again after the retry delay, not the interval" "$(rc_of audit_due "$G" 30 $((NOW + DAY)))" "0"
check "failed audit: not due before the retry delay" "$(rc_of audit_due "$G" 30 $((NOW + 3600)))" "1"
check "retry delay follows RUN_ISSUES_AUDIT_RETRY_HOURS" "$(RUN_ISSUES_AUDIT_RETRY_HOURS=2 rc_of audit_due "$G" 30 $((NOW + 7200)))" "0"
check "junk retry hours read as the default" "$(RUN_ISSUES_AUDIT_RETRY_HOURS=soon audit_retry_secs)" "86400"
printf '%s 5\n' "$NOW" > "$G.result"
check "exit 5 (a scanner failed, the review ran) counts as done" "$(rc_of audit_due "$G" 30 $((NOW + DAY)))" "1"
printf '%s 0\n' "$((NOW - 99))" > "$G.result"
check "an outcome of an earlier start does not count" "$(rc_of audit_due "$G" 30 $((NOW + DAY)))" "0"
H="$WORK/.audit-last-security-run"
check "audit_run returns the script's code" "$(rc_of audit_run "$H" "$NOW" sh -c 'exit 4')" "4"
check "audit_run records it against the start" "$(cat "$H.result")" "$NOW 4"
audit_run "$H" "$NOW" true
check "audit_run records success" "$(cat "$H.result")" "$NOW 0"

check "record into a missing directory fails" "$(rc_of audit_record "$WORK/no/such/dir/f" "$NOW" security)" "1"
check "no temp files are left behind" "$(find "$WORK" -name '.audit-last-security-x.*' ! -name '*.result' | wc -l | tr -d ' ')" "0"

# ---- interval diagnostics (#360) -------------------------------------------------
check "no config: no problem" "$(audit_interval_problem '' security 7)" ""
check "absent key: no problem" "$(audit_interval_problem '{}' security 7)" ""
check "null: no problem" "$(audit_interval_problem '{"security":{"audit_interval_days":null}}' security 7)" ""
check "0 is deliberate: no problem" "$(audit_interval_problem '{"security":{"audit_interval_days":0}}' security 7)" ""
check "positive: no problem" "$(audit_interval_problem '{"security":{"audit_interval_days":30}}' security '')" ""
case "$(audit_interval_problem '{"security":{"audit_interval_days":1.5}}' security '')" in
  *"invalid .security.audit_interval_days 1.5"*) echo "PASS: 1.5 is reported even without a machine value" ;;
  *) echo "FAIL: 1.5 not reported"; FAIL=1 ;;
esac
case "$(audit_interval_problem '{"coherence":{"audit_interval_days":"x"}}' coherence 7)" in
  *"invalid .coherence.audit_interval_days x"*) echo "PASS: a string value is reported under its kind" ;;
  *) echo "FAIL: string value not reported"; FAIL=1 ;;
esac
case "$(audit_interval_problem '{"security":' security 7)" in
  *"not a valid JSON object"*) echo "PASS: unparseable config is reported when the machine schedules the kind" ;;
  *) echo "FAIL: unparseable config not reported"; FAIL=1 ;;
esac
check "unparseable config without a machine value: silent" "$(audit_interval_problem '{"security":' security '')" ""
check "a problem is one line" "$(audit_interval_problem '{"security":{"audit_interval_days":"a\nb"}}' security 7 | wc -l | tr -d ' ')" "0"

# ---- once-only notices (#360) ----------------------------------------------------
NL="$WORK/notice.log"; NS="$WORK/.audit-last-security-n"
: > "$NL"
audit_notice "$NS" "$NL" script "msg one"
audit_notice "$NS" "$NL" script "msg one"
check "a repeated notice is logged once" "$(grep -c 'msg one' "$NL")" "1"
audit_notice "$NS" "$NL" record "msg one"
check "another tag is its own notice" "$(grep -c 'msg one' "$NL")" "2"
audit_notice "$NS" "$NL" script "msg two"
check "a changed message is logged" "$(grep -c 'msg two' "$NL")" "1"
audit_notice_clear "$NS" script
audit_notice "$NS" "$NL" script "msg two"
check "a cleared notice is logged again" "$(grep -c 'msg two' "$NL")" "2"
check "notice lines carry the poller prefix" "$(grep -c ' poller: msg ' "$NL")" "4"
# Unwritable notice file: the log tail stands in for it.
NL2="$WORK/notice2.log"; : > "$NL2"
audit_notice "$WORK/no/such/dir/s" "$NL2" record "cannot write"
audit_notice "$WORK/no/such/dir/s" "$NL2" record "cannot write"
check "unwritable notice file: the log tail suppresses the repeat" "$(grep -c 'cannot write' "$NL2")" "1"

# ---- session names (#360) --------------------------------------------------------
check "session name" "$(audit_session_name security example-org-repo-a)" "run-issues-audit-security-example-org-repo-a"
_pre=$(audit_session_prefix)
check "the prefix counts against the run-issues- cap" "${_pre%%audit-}" "run-issues-"
check "parse: kind and a dashed slug" "$(audit_session_parse run-issues-audit-coherence-example-org-repo-a)" "coherence example-org-repo-a"
check "parse round-trips every kind" \
  "$(for k in $(audit_kinds); do audit_session_parse "$(audit_session_name "$k" o-r)"; echo; done | tr '\n' '|')" \
  "security o-r|coherence o-r|"
check "parse: an unknown kind is not an audit" "$(rc_of audit_session_parse run-issues-audit-nosuch-o-r)" "1"
check "parse: a run session is not an audit" "$(rc_of audit_session_parse run-issues-o-r-issue-5)" "1"
check "parse: no slug is not an audit" "$(rc_of audit_session_parse run-issues-audit-security-)" "1"

# ---- watchlist precedence (#373) -------------------------------------------------
check "security watchlist key" "$(audit_kind_watchlist_key security)" "security_audit_interval_days"
check "coherence watchlist key" "$(audit_kind_watchlist_key coherence)" "coherence_audit_interval_days"
check "unknown kind has no watchlist key" "$(rc_of audit_kind_watchlist_key nosuch)" "1"
# The chain as the poller composes it: machine = watchlist ?: environment, then
# audit_interval_days with the repo config.
eff() { # <repo-config> <watchlist-value> <env-value>
  audit_interval_days "$1" security "$(audit_machine_interval "$2" "$3")"
}
check "watchlist wins over the environment" "$(eff '' 30 7)" "30"
check "watchlist 0 switches the environment's value off" "$(eff '' 0 7)" ""
check "absent watchlist key falls back to the environment" "$(eff '' @absent 7)" "7"
check "absent key and no environment value: not scheduled" "$(eff '' @absent '')" ""
check "repo wins over the watchlist" "$(eff '{"security":{"audit_interval_days":2}}' 30 7)" "2"
check "repo wins over the watchlist's 0" "$(eff '{"security":{"audit_interval_days":2}}' 0 '')" "2"
check "repo 0 wins over the watchlist" "$(eff '{"security":{"audit_interval_days":0}}' 30 7)" ""
for bad_v in 1.5 x -1 '' true; do
  check "bad watchlist value '$bad_v' is not scheduled" "$(eff '' "$bad_v" 7)" ""
  case "$(audit_watchlist_interval_problem "$bad_v" security)" in
    *"invalid security_audit_interval_days"*"in the watchlist"*) echo "PASS: bad watchlist value '$bad_v' is reported" ;;
    *) echo "FAIL: bad watchlist value '$bad_v' not reported"; FAIL=1 ;;
  esac
done
check "watchlist 0 is deliberate: no problem" "$(audit_watchlist_interval_problem 0 security)" ""
check "watchlist positive: no problem" "$(audit_watchlist_interval_problem 30 coherence)" ""
check "absent watchlist key: no problem" "$(audit_watchlist_interval_problem @absent security)" ""
# The watchlist read itself: through poller-config.sh when the caller sourced it,
# `@absent` otherwise (sourcing it here would flip the caller's `set` options).
printf '{"repos":[{"path":"%s/r","security_audit_interval_days":14}]}\n' "$WORK" > "$WORK/wl.json"
check "without poller-config.sh the watchlist reads as absent" \
  "$(audit_watchlist_interval "$WORK/wl.json" "$WORK/r" security)" "@absent"
check "with poller-config.sh the entry's value is read" \
  "$( . "$ROOT/lib/poller-config.sh"; set +e; audit_watchlist_interval "$WORK/wl.json" "$WORK/r" security)" "14"
check "with poller-config.sh an unset kind reads as absent" \
  "$( . "$ROOT/lib/poller-config.sh"; set +e; audit_watchlist_interval "$WORK/wl.json" "$WORK/r" coherence)" "@absent"

# ---- last outcome (#373) ----------------------------------------------------------
check "rc 0 is ok" "$(audit_rc_outcome 0)" "ok"
check "rc 5 is scanner_failed" "$(audit_rc_outcome 5)" "scanner_failed"
check "rc 3 is failed" "$(audit_rc_outcome 3)" "failed"
LO="$WORK/lo"
check "no state file: nothing" "$(audit_last_outcome "$LO")" ""
printf '1700000000 security\n' > "$LO"
check "a start without a result is pending" "$(audit_last_outcome "$LO")" "$(printf '1700000000\tsecurity\t\tpending')"
printf '1700000000 0\n' > "$LO.result"
check "rc 0 for this start" "$(audit_last_outcome "$LO")" "$(printf '1700000000\tsecurity\t0\tok')"
printf '1700000000 5\n' > "$LO.result"
check "rc 5 for this start" "$(audit_last_outcome "$LO")" "$(printf '1700000000\tsecurity\t5\tscanner_failed')"
printf '1700000000 3\n' > "$LO.result"
check "rc 3 for this start" "$(audit_last_outcome "$LO")" "$(printf '1700000000\tsecurity\t3\tfailed')"
printf '1699999999 0\n' > "$LO.result"
check "a result of an earlier start is pending" "$(audit_last_outcome "$LO")" "$(printf '1700000000\tsecurity\t\tpending')"
printf 'junk\n' > "$LO"
check "an unreadable state file: nothing" "$(audit_last_outcome "$LO")" ""
# The retry decision and the view read exit codes the same way.
printf '1700000000 security\n' > "$LO"; printf '1700000000 5\n' > "$LO.result"
check "rc 5 counts as an audit that happened" "$(rc_of _audit_succeeded "$LO" 1700000000)" "0"
printf '1700000000 4\n' > "$LO.result"
check "rc 4 does not" "$(rc_of _audit_succeeded "$LO" 1700000000)" "1"

# ---- calling contract (#360, for #342) -------------------------------------------
grep -qF -- '<script> <repo-path> --remote <r> --watchlist <wl>' "$ROOT/lib/audit-schedule.sh" \
  && echo "PASS: the calling contract is written down" || { echo "FAIL: calling contract missing"; FAIL=1; }

# ---- cost guard (CLAUDE.md §5.3, §5.4) ------------------------------------------
if grep -nE 'state\.jsonl|runs\.log|gh ' "$ROOT/lib/audit-schedule.sh" | grep -v '^[0-9]*:#' >/dev/null; then
  echo "FAIL: lib/audit-schedule.sh reads history or GitHub"; FAIL=1
else
  echo "PASS: lib/audit-schedule.sh reads no history and no GitHub"
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "audit-schedule: all passed" || echo "audit-schedule: FAILURES"
[ "$FAIL" -eq 0 ]
