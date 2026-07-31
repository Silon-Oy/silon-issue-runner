#!/usr/bin/env bash
# test-scan-answered.sh — poller scan_answered selection gates.
#
# scan_answered must emit "<issue> <run-dir>" only for runs that are:
#   - status == awaiting_clarification
#   - on THIS host (or host empty = pre-host-field, treated as local)
#   - clarification_round < RUN_ISSUES_MAX_CLARIFICATIONS
#   - have a fresh human reply on the issue (marker found + detect_answer != "")
#
# poller.sh has a Studio-only host gate that `exit 0`s at source time on any
# other machine, so we cannot source it directly. We extract just the
# scan_answered function and run it with parse_marker/detect_answer from
# lib/issue.sh and a MOCKED fetch_issue_json (per-issue fixtures, no network).
#
# Run: bash tests/test-scan-answered.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLLER="$HERE/../poller.sh"
STATE_LIB="$HERE/../lib/state.sh"
ISSUE_LIB="$HERE/../lib/issue.sh"

WORK=$(mktemp -d -t scan-answered.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
mkdir -p "$REPO/.git"

# shellcheck source=lib/state.sh
. "$STATE_LIB"
# shellcheck source=lib/issue.sh
. "$ISSUE_LIB"   # provides parse_marker + detect_answer

# Extract scan_answered from poller.sh and source it.
FN=$(awk '/^scan_answered\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$POLLER")
eval "$FN"

# Pin globals scan_answered reads.
# shellcheck disable=SC2034
THIS_HOST="test-host"
# shellcheck disable=SC2034
RUN_ISSUES_MAX_CLARIFICATIONS=3

# Mock fetch_issue_json: returns a per-issue fixture keyed by issue number.
# Overrides the lib/issue.sh definition (sourced earlier) so no network.
MARKER_TS="2026-05-21T10:00:00Z"
FIXDIR="$WORK/fixtures"; mkdir -p "$FIXDIR"
fetch_issue_json() {  # <repo> <issue>
  local n="$2"
  [ -f "$FIXDIR/$n.json" ] && cat "$FIXDIR/$n.json"
}

mk_fixture() {  # <issue> <with-reply: yes|no>
  local n="$1" reply="$2"
  local marker; marker=$(build_marker "rid-$n" "$n" "$MARKER_TS" 1)
  if [ "$reply" = "yes" ]; then
    jq -n --arg m "$marker" '{title:"t",body:"b",comments:[
      {author:{login:"maintainer"},createdAt:"2026-05-21T10:00:00Z",body:($m+"\n## ask")},
      {author:{login:"maintainer"},createdAt:"2026-05-21T10:05:00Z",body:"maintainer vastasi"}
    ]}' > "$FIXDIR/$n.json"
  else
    jq -n --arg m "$marker" '{title:"t",body:"b",comments:[
      {author:{login:"maintainer"},createdAt:"2026-05-21T10:00:00Z",body:($m+"\n## ask")}
    ]}' > "$FIXDIR/$n.json"
  fi
}

mk_run() {  # <issue> <status> <host> <round>
  local n="$1" status="$2" host="$3" round="$4"
  local rid="20260521-00$n-issue-$n"
  local rd="$REPO/.claude/run-issues/$rid"
  state_init "$rd" "$rid" "$REPO" "$n"
  local tmp; tmp=$(mktemp)
  jq --arg h "$host" --argjson r "$round" '.host=$h | .clarification_round=$r' \
    "$rd/run.json" > "$tmp"; mv "$tmp" "$rd/run.json"
  state_finalize "$rd" "$status"
}

# Eligible: awaiting, this host, under cap, has reply.
mk_run 10 "awaiting_clarification" "test-host" 1; mk_fixture 10 yes
# Eligible: empty host treated as local, has reply.
mk_run 50 "awaiting_clarification" "" 0; mk_fixture 50 yes
# Not eligible: wrong host.
mk_run 20 "awaiting_clarification" "other-host" 0; mk_fixture 20 yes
# Not eligible: at cap (round == MAX).
mk_run 30 "awaiting_clarification" "test-host" 3; mk_fixture 30 yes
# Not eligible: not awaiting_clarification.
mk_run 40 "completed" "test-host" 0; mk_fixture 40 yes
# Not eligible: awaiting + under cap + this host, but NO reply yet.
mk_run 60 "awaiting_clarification" "test-host" 0; mk_fixture 60 no

OUT=$(scan_answered "$REPO" | sort)
echo "--- scan_answered output ---"; echo "$OUT"

FAIL=0
echo "$OUT" | grep -q "^10 " || { echo "FAIL: issue 10 (eligible) not selected"; FAIL=1; }
echo "$OUT" | grep -q "^50 " || { echo "FAIL: issue 50 (empty host) not selected"; FAIL=1; }
echo "$OUT" | grep -q "^20 " && { echo "FAIL: issue 20 (foreign host) WAS selected"; FAIL=1; }
echo "$OUT" | grep -q "^30 " && { echo "FAIL: issue 30 (at cap) WAS selected"; FAIL=1; }
echo "$OUT" | grep -q "^40 " && { echo "FAIL: issue 40 (completed) WAS selected"; FAIL=1; }
echo "$OUT" | grep -q "^60 " && { echo "FAIL: issue 60 (no reply) WAS selected"; FAIL=1; }
COUNT=$(printf '%s\n' "$OUT" | grep -c '^[0-9]')
[ "$COUNT" = "2" ] || { echo "FAIL: expected exactly 2 candidates, got $COUNT"; FAIL=1; }

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "scan-answered: all passed" || echo "scan-answered: FAILURES"
[ "$FAIL" -eq 0 ]
