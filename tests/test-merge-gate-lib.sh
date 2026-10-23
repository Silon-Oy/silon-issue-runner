#!/usr/bin/env bash
# test-merge-gate-lib.sh — the merge gate's pure parts (lib/merge-gate.sh,
# issue #334): result parsing, severity threshold resolution, and the head-SHA /
# attempt bookkeeping read from state.jsonl's tail.
#
# Run: bash tests/test-merge-gate-lib.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib/merge-gate.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available"
  exit 0
fi

# shellcheck source=../lib/merge-gate.sh
. "$LIB"

FAIL=0
WORK=$(mktemp -d -t merge-gate-lib.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

check() { # <name> <want> <got>
  if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 — want '$2', got '$3'"; FAIL=1; fi
}

# parse_of <exit-code|-> <content> — merge_gate_parse on a fresh out file.
parse_of() {
  local rc="$1" content="$2"
  printf '%s' "$content" > "$WORK/x.out"
  if [ "$rc" = "-" ]; then
    merge_gate_parse "$WORK/x.out"
  else
    printf '%s\n' "$rc" > "$WORK/x.exit"
    merge_gate_parse "$WORK/x.out" "$WORK/x.exit"
  fi
}

# ----- parse -------------------------------------------------------------
check "clean" clean "$(parse_of 0 $'Looked at the diff.\nMERGE_GATE_RESULT: CLEAN\n')"
check "clean inside a code fence" clean "$(parse_of 0 $'ok\n```\nMERGE_GATE_RESULT: CLEAN\n```\n\n')"
check "findings" findings "$(parse_of 0 $'FINDING: high | medium | a.php:3 | SQL built by concatenation\nMERGE_GATE_RESULT: FINDINGS\n')"
check "empty output -> launch_failed" launch_failed "$(parse_of 0 '')"
check "missing out file -> launch_failed" launch_failed "$(merge_gate_parse "$WORK/nope.out")"
check "no marker -> launch_failed" launch_failed "$(parse_of 0 $'I reviewed it, looks fine.\n')"
check "marker not last -> launch_failed" launch_failed "$(parse_of 0 $'MERGE_GATE_RESULT: CLEAN\nbut then more text\n')"
check "non-zero exit -> launch_failed" launch_failed "$(parse_of 124 $'MERGE_GATE_RESULT: CLEAN\n')"
check "rc 127 -> launch_failed" launch_failed "$(parse_of 127 '')"
check "FINDINGS without a finding -> launch_failed" launch_failed "$(parse_of 0 $'MERGE_GATE_RESULT: FINDINGS\n')"
check "CLEAN with a finding -> launch_failed" launch_failed "$(parse_of 0 $'FINDING: low | low | x | y\nMERGE_GATE_RESULT: CLEAN\n')"
check "unknown severity -> launch_failed" launch_failed "$(parse_of 0 $'FINDING: severe | high | x | y\nMERGE_GATE_RESULT: FINDINGS\n')"
check "too few fields -> launch_failed" launch_failed "$(parse_of 0 $'FINDING: high | high\nMERGE_GATE_RESULT: FINDINGS\n')"
check "parse works without an exit file" clean "$(parse_of - $'MERGE_GATE_RESULT: CLEAN\n')"

printf '%s\n' 'FINDING: HIGH | High | `a.php:3` | uses a | pipe' 'FINDING: low | low |  | nit' 'MERGE_GATE_RESULT: FINDINGS' > "$WORK/f.out"
check "findings normalised" $'high|high|a.php:3|uses a | pipe\nlow|low||nit' "$(merge_gate_findings "$WORK/f.out")"

# Under the caller's pipefail, a clean output (no FINDING line) is still clean.
check "clean under pipefail" clean "$( set -o pipefail; parse_of 0 $'MERGE_GATE_RESULT: CLEAN\n')"

# ----- threshold ---------------------------------------------------------
F=$'critical|high|a|x\nhigh|low|b|y\nmedium|high|c|z\nlow|high|d|w'
check "holding at high" 2 "$(merge_gate_holding high "$F" | grep -c .)"
check "holding at medium" 3 "$(merge_gate_holding medium "$F" | grep -c .)"
check "holding at critical" 1 "$(merge_gate_holding critical "$F" | grep -c .)"
check "holding at low" 4 "$(merge_gate_holding low "$F" | grep -c .)"

check "default threshold is high" high "$(merge_gate_hold_min '' security '')"
check "machine value used without repo value" medium "$(merge_gate_hold_min '{}' security medium)"
check "repo value wins over machine value" low "$(merge_gate_hold_min '{"security":{"hold_min_severity":"low"}}' security critical)"
check "other gate's key ignored" critical "$(merge_gate_hold_min '{"other":{"hold_min_severity":"low"}}' security critical)"
check "repo value case-insensitive" medium "$(merge_gate_hold_min '{"security":{"hold_min_severity":"MEDIUM"}}' security '')"
check "unknown value fails closed to low" low "$(merge_gate_hold_min '{"security":{"hold_min_severity":"none"}}' security high 2>/dev/null)"
check "unknown machine value fails closed to low" low "$(merge_gate_hold_min '' security bogus 2>/dev/null)"
check "invalid config JSON fails closed to low" low "$(merge_gate_hold_min '{not json' security critical 2>/dev/null)"

# ----- state.jsonl bookkeeping -------------------------------------------
J="$WORK/state.jsonl"
{
  echo '{"event":"merge_gate_reviewed","data":{"gate":"security","sha":"aaa","result":"launch_failed","holding":"0"}}'
  echo '{"event":"merge_gate_reviewed","data":{"gate":"security","sha":"aaa","result":"findings","holding":"2"}}'
  echo '{"event":"merge_gate_reviewed","data":{"gate":"other","sha":"bbb","result":"clean","holding":"0"}}'
  echo '{"event":"merge_gate_fix_attempted","data":{"gate":"security","sha":"aaa","attempt":"1"}}'
  echo '{"event":"merge_gate_fix_attempted","data":{"gate":"other","sha":"bbb","attempt":"1"}}'
} > "$J"
check "last result for the head" "findings 2" "$(merge_gate_last_result "$J" security aaa)"
check "no result for another gate's head" "" "$(merge_gate_last_result "$J" security bbb)"
check "result is per gate" "clean 0" "$(merge_gate_last_result "$J" other bbb)"
check "attempts per gate" 1 "$(merge_gate_attempts "$J" security)"
check "attempts on a missing file" 0 "$(merge_gate_attempts "$WORK/none.jsonl" security)"

# Only the tail is read (CLAUDE.md §5.3): a record outside the window is unseen,
# which fails safe (the head is reviewed again).
for _ in $(seq 1 30); do echo '{"event":"pr_watch_skipped","data":{}}' >> "$J"; done
check "record outside the tail window is not read" "" "$(PR_WATCH_GATE_TAIL_LINES=10 merge_gate_last_result "$J" security aaa)"
check "attempts outside the tail window are not read" 0 "$(PR_WATCH_GATE_TAIL_LINES=10 merge_gate_attempts "$J" security)"

# ----- comment formatting ------------------------------------------------
GOT=$(merge_gate_format_findings $'low|high|d|w\ncritical|high|a.php:1|x')
check "most severe first" '- **critical** (varmuus: high) `a.php:1` — x' "$(printf '%s\n' "$GOT" | head -n 1)"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "merge-gate-lib: all passed" || echo "merge-gate-lib: FAILURES"
[ "$FAIL" -eq 0 ]
