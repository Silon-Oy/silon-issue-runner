#!/usr/bin/env bash
# test-poller-scan-timeout.sh — poller scan_timed_out selection + host gate.
#
# scan_timed_out must emit "<issue> <run-dir>" only for runs that are:
#   - status == timed_out
#   - on THIS host (or host empty = pre-host-field, treated as local)
#   - retry_count < RUN_ISSUES_MAX_RETRIES
#
# poller.sh has a Studio-only host gate that `exit 0`s at source time on any
# other machine, so we cannot source it directly. Instead we extract just the
# scan_timed_out function definition and evaluate it in a controlled harness
# with THIS_HOST / RUN_ISSUES_MAX_RETRIES pinned.
#
# Run: bash tests/test-poller-scan-timeout.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLLER="$HERE/../poller.sh"
STATE_LIB="$HERE/../lib/state.sh"

WORK=$(mktemp -d -t poller-scan.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
mkdir -p "$REPO/.git"  # scan_timed_out only needs the run-issues dir
# shellcheck source=lib/state.sh
. "$STATE_LIB"

# Extract the scan_timed_out function body from poller.sh (def line to its
# closing brace at column 0) and source it into this shell.
FN=$(awk '/^scan_timed_out\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$POLLER")
eval "$FN"

# Pin the globals the function reads (referenced inside the eval'd function,
# which shellcheck cannot see — hence the disable).
# shellcheck disable=SC2034
THIS_HOST="test-host"
# shellcheck disable=SC2034
RUN_ISSUES_MAX_RETRIES=1

mk_run() {  # <rid> <status> <host> <retry>
  local rid="$1" status="$2" host="$3" retry="$4"
  local rd="$REPO/.claude/run-issues/$rid"
  local inum="${rid##*-}"
  state_init "$rd" "$rid" "$REPO" "$inum"
  local tmp; tmp=$(mktemp)
  jq --arg h "$host" --argjson r "$retry" '.host = $h | .retry_count = $r' \
    "$rd/run.json" > "$tmp"; mv "$tmp" "$rd/run.json"
  state_finalize "$rd" "$status"
}

# Eligible: timed_out, this host, retry under budget.
mk_run "20260521-0001-issue-10" "timed_out" "test-host" 0
# Not eligible: wrong host.
mk_run "20260521-0002-issue-20" "timed_out" "other-host" 0
# Not eligible: budget exhausted.
mk_run "20260521-0003-issue-30" "timed_out" "test-host" 1
# Not eligible: not timed_out.
mk_run "20260521-0004-issue-40" "completed" "test-host" 0
# Eligible: empty host treated as local.
mk_run "20260521-0005-issue-50" "timed_out" "" 0

OUT=$(scan_timed_out "$REPO" | sort)
echo "--- scan_timed_out output ---"; echo "$OUT"

FAIL=0
echo "$OUT" | grep -q "^10 " || { echo "FAIL: issue 10 (eligible) not selected"; FAIL=1; }
echo "$OUT" | grep -q "^50 " || { echo "FAIL: issue 50 (empty host) not selected"; FAIL=1; }
echo "$OUT" | grep -q "^20 " && { echo "FAIL: issue 20 (foreign host) WAS selected"; FAIL=1; }
echo "$OUT" | grep -q "^30 " && { echo "FAIL: issue 30 (budget exhausted) WAS selected"; FAIL=1; }
echo "$OUT" | grep -q "^40 " && { echo "FAIL: issue 40 (completed) WAS selected"; FAIL=1; }
COUNT=$(printf '%s\n' "$OUT" | grep -c '^[0-9]')
[ "$COUNT" = "2" ] || { echo "FAIL: expected exactly 2 candidates, got $COUNT"; FAIL=1; }

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "poller-scan-timeout: all passed" || echo "poller-scan-timeout: FAILURES"
[ "$FAIL" -eq 0 ]
