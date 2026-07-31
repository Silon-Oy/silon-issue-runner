#!/usr/bin/env bash
# test-truncate-marker.sh — pure lib functions build_marker + truncate_for_github.
#
# These are side-effect-free helpers in lib/issue.sh, so we source the lib and
# call them directly. No gh, no network.
#
# Run: bash tests/test-truncate-marker.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISSUE_LIB="$HERE/../lib/issue.sh"
# shellcheck source=lib/issue.sh
. "$ISSUE_LIB"

FAIL=0

# === build_marker round-trip =============================================
M=$(build_marker "20260521-1500-issue-99" "99" "2026-05-21T15:00:00Z")
echo "--- build_marker (default round) ---"; echo "$M"
echo "$M" | grep -q 'run=20260521-1500-issue-99' || { echo "FAIL: marker missing run field"; FAIL=1; }
echo "$M" | grep -q 'issue=99'                   || { echo "FAIL: marker missing issue field"; FAIL=1; }
echo "$M" | grep -q 'ts=2026-05-21T15:00:00Z'    || { echo "FAIL: marker missing ts field"; FAIL=1; }
echo "$M" | grep -q 'round=0'                    || { echo "FAIL: marker round should default to 0"; FAIL=1; }
echo "$M" | grep -q '^<!-- run-issues:awaiting-answer ' || { echo "FAIL: marker prefix wrong"; FAIL=1; }
echo "$M" | grep -q ' -->$'                       || { echo "FAIL: marker suffix wrong"; FAIL=1; }

M3=$(build_marker "rid" "7" "2026-01-01T00:00:00Z" "3")
echo "$M3" | grep -q 'round=3' || { echo "FAIL: explicit round not honoured"; FAIL=1; }

[ "$FAIL" = "0" ] && echo "PASS build_marker round-trip"

# === truncate_for_github: short input passes through unchanged ============
SHORT="line1
line2
IMPLEMENTER_RESULT: SUCCESS"
OUT=$(printf '%s' "$SHORT" | truncate_for_github 60000)
[ "$OUT" = "$SHORT" ] || { echo "FAIL: short input was altered"; FAIL=1; }
echo "$OUT" | grep -q 'typistetty' && { echo "FAIL: short input got a truncation notice"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS truncate: short input unchanged"

# === truncate_for_github: long input keeps tail + notice, stays under cap =
# Build an input larger than the cap whose LAST line is the decision line.
BIG=$(head -c 5000 /dev/zero | tr '\0' 'x')
LONG="$BIG
$BIG
CYCLE_REVIEW_DECISION: PROCEED"
MAX=2000
TOUT=$(printf '%s' "$LONG" | truncate_for_github "$MAX")
TBYTES=$(printf '%s' "$TOUT" | wc -c | tr -d ' ')
echo "--- truncate long: $TBYTES bytes (cap $MAX) ---"
[ "$TBYTES" -le "$MAX" ] || { echo "FAIL: truncated output $TBYTES > cap $MAX"; FAIL=1; }
echo "$TOUT" | grep -q 'typistetty' || { echo "FAIL: long input missing truncation notice"; FAIL=1; }
echo "$TOUT" | grep -q 'CYCLE_REVIEW_DECISION: PROCEED' || { echo "FAIL: decision line (tail) was dropped"; FAIL=1; }
# The HEAD (first xxxx block start) should be gone — notice should be first line.
FIRSTLINE=$(printf '%s' "$TOUT" | head -1)
echo "$FIRSTLINE" | grep -q 'typistetty' || { echo "FAIL: notice not on first line"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS truncate: long input keeps tail + notice under cap"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "truncate-marker: all passed" || echo "truncate-marker: FAILURES"
[ "$FAIL" -eq 0 ]
