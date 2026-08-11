#!/usr/bin/env bash
# test-scan-blocked-answered.sh — poller scan_blocked_answered selection gates
# (issue #57).
#
# scan_blocked_answered must emit "<issue> <run-dir>" only for runs that are:
#   - status == blocked
#   - on THIS host (or host empty = pre-host-field, treated as local)
#   - issue still OPEN
#   - carry an awaiting-answer marker AND a human reply strictly after it
#
# There is NO round cap (unlike scan_answered): the loop guard is structural —
# one reply => at most one retry, because a re-blocked run posts a NEW marker.
#
# poller.sh has a Studio-only host gate that `exit 0`s at source time on any
# other machine, so we cannot source it directly. We extract just the
# scan_blocked_answered function and run it with parse_marker/detect_answer from
# lib/issue.sh and a MOCKED fetch_issue_json (per-issue fixtures, no network).
#
# Run: bash tests/test-scan-blocked-answered.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLLER="$HERE/../poller.sh"
STATE_LIB="$HERE/../lib/state.sh"
ISSUE_LIB="$HERE/../lib/issue.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

WORK=$(mktemp -d -t scan-blocked-answered.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
mkdir -p "$REPO/.git"

# shellcheck source=lib/state.sh
. "$STATE_LIB"
# shellcheck source=lib/issue.sh
. "$ISSUE_LIB"   # provides build_marker + parse_marker + detect_answer

# Extract scan_blocked_answered from poller.sh and source it.
FN=$(awk '/^scan_blocked_answered\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$POLLER")
eval "$FN"

# Pin the one global scan_blocked_answered reads (no round cap here).
# shellcheck disable=SC2034
THIS_HOST="test-host"

# Mock fetch_issue_json: returns a per-issue fixture keyed by issue number.
# Overrides the lib/issue.sh definition (sourced earlier) so no network.
MARKER_TS="2026-05-21T10:00:00Z"
FIXDIR="$WORK/fixtures"; mkdir -p "$FIXDIR"
fetch_issue_json() {  # <repo> <issue>
  local n="$2"
  [ -f "$FIXDIR/$n.json" ] && cat "$FIXDIR/$n.json"
}

# mk_fixture <issue> <reply: yes|no|nomarker> <state: OPEN|CLOSED>
mk_fixture() {
  local n="$1" reply="$2" state="$3"
  local marker; marker=$(build_marker "rid-$n" "$n" "$MARKER_TS")
  case "$reply" in
    yes)
      jq -n --arg m "$marker" --arg s "$state" '{title:"t",body:"b",state:$s,comments:[
        {author:{login:"maintainer"},createdAt:"2026-05-21T10:00:00Z",body:($m+"\n## blocked")},
        {author:{login:"maintainer"},createdAt:"2026-05-21T10:05:00Z",body:"Este poistettu"}
      ]}' > "$FIXDIR/$n.json" ;;
    no)
      jq -n --arg m "$marker" --arg s "$state" '{title:"t",body:"b",state:$s,comments:[
        {author:{login:"maintainer"},createdAt:"2026-05-21T10:00:00Z",body:($m+"\n## blocked")}
      ]}' > "$FIXDIR/$n.json" ;;
    nomarker)
      # A legacy blocked run finalized before this change: no marker at all.
      jq -n --arg s "$state" '{title:"t",body:"b",state:$s,comments:[
        {author:{login:"maintainer"},createdAt:"2026-05-21T10:05:00Z",body:"Este poistettu"}
      ]}' > "$FIXDIR/$n.json" ;;
  esac
}

# mk_run <issue> <status> <host>
mk_run() {
  local n="$1" status="$2" host="$3"
  local rid="20260521-00$n-issue-$n"
  local rd="$REPO/.claude/run-issues/$rid"
  state_init "$rd" "$rid" "$REPO" "$n"
  local tmp; tmp=$(mktemp)
  jq --arg h "$host" '.host=$h' "$rd/run.json" > "$tmp"; mv "$tmp" "$rd/run.json"
  state_finalize "$rd" "$status"
}

# Eligible: blocked, this host, open, has reply after marker.
mk_run 10 "blocked" "test-host"; mk_fixture 10 yes OPEN
# Eligible: empty host treated as local, open, has reply.
mk_run 50 "blocked" ""; mk_fixture 50 yes OPEN
# Not eligible: wrong host.
mk_run 20 "blocked" "other-host"; mk_fixture 20 yes OPEN
# Not eligible: not blocked (awaiting_clarification handled by scan_answered).
mk_run 30 "awaiting_clarification" "test-host"; mk_fixture 30 yes OPEN
# Not eligible: blocked + reply but issue CLOSED — run is done for good.
mk_run 40 "blocked" "test-host"; mk_fixture 40 yes CLOSED
# Not eligible: blocked, open, but NO reply after marker yet.
mk_run 60 "blocked" "test-host"; mk_fixture 60 no OPEN
# Not eligible: legacy blocked run with NO marker — skipped silently.
mk_run 70 "blocked" "test-host"; mk_fixture 70 nomarker OPEN

OUT=$(scan_blocked_answered "$REPO" | sort)
echo "--- scan_blocked_answered output ---"; echo "$OUT"

FAIL=0
echo "$OUT" | grep -q "^10 " || { echo "FAIL: issue 10 (eligible) not selected"; FAIL=1; }
echo "$OUT" | grep -q "^50 " || { echo "FAIL: issue 50 (empty host) not selected"; FAIL=1; }
echo "$OUT" | grep -q "^20 " && { echo "FAIL: issue 20 (foreign host) WAS selected"; FAIL=1; }
echo "$OUT" | grep -q "^30 " && { echo "FAIL: issue 30 (awaiting_clarification) WAS selected"; FAIL=1; }
echo "$OUT" | grep -q "^40 " && { echo "FAIL: issue 40 (closed issue) WAS selected"; FAIL=1; }
echo "$OUT" | grep -q "^60 " && { echo "FAIL: issue 60 (no reply) WAS selected"; FAIL=1; }
echo "$OUT" | grep -q "^70 " && { echo "FAIL: issue 70 (no marker) WAS selected"; FAIL=1; }
COUNT=$(printf '%s\n' "$OUT" | grep -c '^[0-9]')
[ "$COUNT" = "2" ] || { echo "FAIL: expected exactly 2 candidates, got $COUNT"; FAIL=1; }

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "scan-blocked-answered: all passed" || echo "scan-blocked-answered: FAILURES"
[ "$FAIL" -eq 0 ]
