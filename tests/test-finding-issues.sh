#!/usr/bin/env bash
# test-finding-issues.sh — unit tests for lib/finding-issues.sh (issue #339),
# the audit-agnostic finding → issue mechanism: fingerprint, marker, index,
# plan and the auto-run policy. gh is a function stub; no network.
#
# Run: bash tests/test-finding-issues.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available"
  exit 0
fi

# shellcheck source=../lib/finding-issues.sh
. "$HERE/../lib/finding-issues.sh"

FAIL=0
check() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 — got '$2', want '$3'"; FAIL=1; fi
}

WORK=$(mktemp -d -t finding-issues.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ---- fingerprint ---------------------------------------------------------------
a=$(finding_fingerprint agent src/a.php:12 sql-injection)
check "fingerprint is 16 hex" "$(printf '%s' "$a" | grep -cE '^[0-9a-f]{16}$')" 1
check "line number does not change the fingerprint" "$(finding_fingerprint agent src/a.php:99 sql-injection)" "$a"
check "line range and ./ do not either" "$(finding_fingerprint agent ./src/a.php:3-9 sql-injection)" "$a"
check "case of the key does not either" "$(finding_fingerprint AGENT src/a.php SQL-Injection)" "$a"
[ "$(finding_fingerprint agent src/b.php sql-injection)" != "$a" ] && echo "PASS: another file is another finding" || { echo "FAIL: file ignored"; FAIL=1; }
[ "$(finding_fingerprint agent src/a.php xss)" != "$a" ] && echo "PASS: another class is another finding" || { echo "FAIL: key ignored"; FAIL=1; }
[ "$(finding_fingerprint gitleaks src/a.php sql-injection)" != "$a" ] && echo "PASS: another source is another finding" || { echo "FAIL: source ignored"; FAIL=1; }

check "marker" "$(finding_marker security abc123)" "<!-- run-issues:finding kind=security fp=abc123 -->"

# ---- index -----------------------------------------------------------------------
GH_CALLS="$WORK/gh.calls"
labels_gh() {
  printf '%s\n' "$*" >> "$GH_CALLS"
  [ -f "$WORK/fail" ] && return 1
  # Two pages, as --paginate concatenates them; one PR to drop, one issue without a marker.
  cat <<'JSON'
[{"number":1,"state":"open","title":"one","body":"x <!-- run-issues:finding kind=security fp=aaaa000000000001 -->"},
 {"number":2,"state":"closed","state_reason":"completed","title":"two\tt","body":"<!-- run-issues:finding kind=security fp=aaaa000000000002 -->"},
 {"number":3,"state":"open","title":"pr","pull_request":{},"body":"<!-- run-issues:finding kind=security fp=aaaa000000000003 -->"}]
[{"number":4,"state":"closed","state_reason":"not_planned","title":"four","body":"<!-- run-issues:finding kind=security fp=aaaa000000000004 -->"},
 {"number":5,"state":"open","title":"plain","body":"no marker"},
 {"number":6,"state":"closed","state_reason":"completed","title":"six","body":"<!-- run-issues:finding kind=coherence fp=aaaa000000000001 -->"}]
JSON
}
IDX="$WORK/index.tsv"
finding_issues_index o/r security "$IDX"; rc=$?
check "index rc" "$rc" 0
check "index rows (PR and marker-less issue dropped)" "$(wc -l < "$IDX" | tr -d ' ')" 4
grep -q 'labels=security&state=all' "$GH_CALLS" && echo "PASS: index is a REST label listing over all states" || { echo "FAIL: listing call: $(cat "$GH_CALLS")"; FAIL=1; }
grep -q -- '--paginate' "$GH_CALLS" && echo "PASS: listing is paginated" || { echo "FAIL: listing not paginated"; FAIL=1; }
check "title tabs flattened" "$(awk -F'\t' '$3 == 2 { print NF }' "$IDX")" 5

check "plan: unknown" "$(finding_issue_plan "$IDX" security ffff000000000000)" "create"
check "plan: open" "$(finding_issue_plan "$IDX" security aaaa000000000001)" "exists 1"
check "plan: closed completed" "$(finding_issue_plan "$IDX" security aaaa000000000002)" "reopen 2"
check "plan: not planned" "$(finding_issue_plan "$IDX" security aaaa000000000004)" "dismissed 4"
check "plan: another kind's marker does not match" "$(finding_issue_plan "$IDX" coherence aaaa000000000001)" "reopen 6"
finding_issue_note "$IDX" security ffff000000000000 9 "new"
check "plan: noted in this audit" "$(finding_issue_plan "$IDX" security ffff000000000000)" "exists 9"

touch "$WORK/fail"
finding_issues_index o/r security "$WORK/index2.tsv"; rc=$?
check "failed listing is rc 1" "$rc" 1
rm -f "$WORK/fail"

# ---- policy ----------------------------------------------------------------------
pol() { finding_issues_auto_run_min "$1" security "$2" 2>/dev/null; }
check "default is high" "$(pol "" "")" high
check "machine value applies" "$(pol "" medium)" medium
check "repo beats machine" "$(pol '{"security":{"audit_auto_run_min_severity":"critical"}}' low)" critical
check "repo none" "$(pol '{"security":{"audit_auto_run_min_severity":"none"}}' low)" none
check "other section ignored" "$(pol '{"coherence":{"audit_auto_run_min_severity":"low"}}' "")" high
check "unknown value => none" "$(pol "" sometimes)" none
check "invalid JSON => none" "$(pol '{not json' high)" none
check "case-insensitive" "$(pol "" HIGH)" high

runs() { finding_issues_auto_runs "$1" "$2" && echo yes || echo no; }
check "high reaches high" "$(runs high high)" yes
check "critical reaches high" "$(runs high critical)" yes
check "medium does not reach high" "$(runs high medium)" no
check "none stops critical" "$(runs none critical)" no
check "unknown severity never runs" "$(runs low bogus)" no

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "finding-issues: all passed" || echo "finding-issues: FAILURES"
[ "$FAIL" -eq 0 ]
