#!/usr/bin/env bash
# test-audit-schedule.sh — unit tests for lib/audit-schedule.sh (issue #340):
# the kind table, interval precedence (repo > machine, unset = not scheduled),
# the due check and the atomic start record. No network, no tmux.
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
check "security is a scheduled kind" "$(audit_kinds)" "security"
check "security runs security-audit.sh" "$(audit_kind_script security)" "security-audit.sh"
check "the script exists in the package root" "$([ -x "$ROOT/$(audit_kind_script security)" ] && echo y)" "y"
check "security interval variable" "$(audit_kind_env_var security)" "RUN_ISSUES_SECURITY_AUDIT_INTERVAL_DAYS"
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
check "unknown kind is never scheduled" "$(audit_interval_days '{"nosuch":{"audit_interval_days":1}}' nosuch 1)" ""

# ---- state file -------------------------------------------------------------------
check "state file path" "$(audit_state_file /logs security org-repo)" "/logs/.audit-last-security-org-repo"

NOW=1800000000
DAY=86400
F="$WORK/.audit-last-security-x"
check "never audited is due" "$(rc_of audit_due "$F" 7 "$NOW")" "0"
check "record succeeds" "$(rc_of audit_record "$F" "$NOW" security)" "0"
check "record content" "$(cat "$F")" "$NOW security"
check "just recorded is not due" "$(rc_of audit_due "$F" 7 "$NOW")" "1"
check "one second before the interval is not due" "$(rc_of audit_due "$F" 7 $((NOW + 7 * DAY - 1)))" "1"
check "exactly the interval is due" "$(rc_of audit_due "$F" 7 $((NOW + 7 * DAY)))" "0"
check "an empty interval is never due" "$(rc_of audit_due "$F" '' $((NOW + 100 * DAY)))" "1"
echo garbage > "$F"
check "a corrupt state file is due" "$(rc_of audit_due "$F" 7 "$NOW")" "0"
echo "$((NOW + 10 * DAY)) security" > "$F"
check "a recorded time in the future is due" "$(rc_of audit_due "$F" 7 "$NOW")" "0"
check "record into a missing directory fails" "$(rc_of audit_record "$WORK/no/such/dir/f" "$NOW" security)" "1"
check "no temp files are left behind" "$(find "$WORK" -name '.audit-last-security-x.*' | wc -l | tr -d ' ')" "0"

# ---- cost guard (CLAUDE.md §5.3, §5.4) ------------------------------------------
if grep -nE 'state\.jsonl|runs\.log|gh ' "$ROOT/lib/audit-schedule.sh" | grep -v '^[0-9]*:#' >/dev/null; then
  echo "FAIL: lib/audit-schedule.sh reads history or GitHub"; FAIL=1
else
  echo "PASS: lib/audit-schedule.sh reads no history and no GitHub"
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "audit-schedule: all passed" || echo "audit-schedule: FAILURES"
[ "$FAIL" -eq 0 ]
