#!/usr/bin/env bash
# test-finding-issues.sh — unit tests for lib/finding-issues.sh (issue #339),
# the audit-agnostic finding → issue mechanism: fingerprint, marker, index,
# plan and the auto-run policy; the ids of a finding (update) and the close of
# a replaced issue (supersede), the dependency merge policy and the grouping of
# dependency findings by package version (#397, lib/dependency-findings.sh).
# gh is a function stub; no network.
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
 {"number":6,"state":"closed","state_reason":"completed","title":"six","body":"<!-- run-issues:finding kind=coherence fp=aaaa000000000001 -->"},
 {"number":7,"state":"open","title":"pkg","body":"<!-- run-issues:finding kind=security fp=bbbb000000000001 -->\n<!-- run-issues:finding-ids fp=bbbb000000000001 ids=GHSA-a,CVE-1 -->"}]
JSON
}
IDX="$WORK/index.tsv"
finding_issues_index o/r security "$IDX"; rc=$?
check "index rc" "$rc" 0
check "index rows (PR and marker-less issue dropped)" "$(wc -l < "$IDX" | tr -d ' ')" 5
grep -q 'labels=security&state=all' "$GH_CALLS" && echo "PASS: index is a REST label listing over all states" || { echo "FAIL: listing call: $(cat "$GH_CALLS")"; FAIL=1; }
grep -q -- '--paginate' "$GH_CALLS" && echo "PASS: listing is paginated" || { echo "FAIL: listing not paginated"; FAIL=1; }
check "title tabs flattened" "$(awk -F'\t' '$3 == 2 { print NF }' "$IDX")" 6
check "ids marker read into the index" "$(awk -F'\t' '$3 == 7 { print $6 }' "$IDX")" "GHSA-a,CVE-1"

check "plan: unknown" "$(finding_issue_plan "$IDX" security ffff000000000000)" "create"
check "plan: open" "$(finding_issue_plan "$IDX" security aaaa000000000001)" "exists 1"
check "plan: closed completed" "$(finding_issue_plan "$IDX" security aaaa000000000002)" "reopen 2"
check "plan: not planned" "$(finding_issue_plan "$IDX" security aaaa000000000004)" "dismissed 4"
check "plan: another kind's marker does not match" "$(finding_issue_plan "$IDX" coherence aaaa000000000001)" "reopen 6"
finding_issue_note "$IDX" security ffff000000000000 9 "new"
check "plan: noted in this audit" "$(finding_issue_plan "$IDX" security ffff000000000000)" "exists 9"

# ---- ids: update (#397) ------------------------------------------------------------
check "plan: ids covered" "$(finding_issue_plan "$IDX" security bbbb000000000001 CVE-1,GHSA-a)" "exists 7"
check "plan: a new id" "$(finding_issue_plan "$IDX" security bbbb000000000001 GHSA-a,CVE-1,GHSA-b)" "update 7"
check "plan: no ids given" "$(finding_issue_plan "$IDX" security bbbb000000000001)" "exists 7"
check "plan: ids never update a closed issue" "$(finding_issue_plan "$IDX" security aaaa000000000002 X)" "reopen 2"
check "missing ids" "$(finding_ids_missing GHSA-a,GHSA-b,CVE-2 GHSA-a,CVE-1)" "GHSA-b,CVE-2"
check "no id is a prefix match" "$(finding_ids_missing GHSA-a GHSA-ab)" "GHSA-a"
check "ids marker" "$(finding_ids_marker abc A,B)" "<!-- run-issues:finding-ids fp=abc ids=A,B -->"

# Writes go through a recording stub from here on.
WRITES="$WORK/writes"
labels_gh() { printf '%s\n' "$*" >> "$WRITES"; [ -f "$WORK/fail" ] && return 1; echo '{"number":7,"assignees":[]}'; }
labels_ensure() { return 0; }
labels_add() { printf 'labels_add %s\n' "$*" >> "$WRITES"; }
res=$(finding_issue_apply o/r "$IDX" security bbbb000000000001 "t" "new body" "security,auto-run" "c" "" "GHSA-a,CVE-1,GHSA-b")
check "update result" "$res" "updated #7"
grep -q -- '--method PATCH repos/o/r/issues/7 -f body=new body' "$WRITES" && echo "PASS: update rewrites the body" || { echo "FAIL: no body PATCH: $(cat "$WRITES")"; FAIL=1; }
grep -q 'state=' "$WRITES" && { echo "FAIL: update changed the state"; FAIL=1; } || echo "PASS: update leaves the state"
grep -q 'comments -f body=.*uusia tunnisteita: GHSA-b\.' "$WRITES" && echo "PASS: comment names only the new id" || { echo "FAIL: comment: $(cat "$WRITES")"; FAIL=1; }
grep -q '^labels_add o/r 7 security,auto-run' "$WRITES" && echo "PASS: labels added on update" || { echo "FAIL: labels not added"; FAIL=1; }
check "update noted: covered now" "$(finding_issue_plan "$IDX" security bbbb000000000001 GHSA-b)" "exists 7"

# ---- supersede (#397) ------------------------------------------------------------
: > "$WRITES"
check "supersede result" "$(finding_issue_supersede o/r "$IDX" 1 "see #7")" "superseded #1"
grep -q 'issues/1/comments -f body=see #7' "$WRITES" && echo "PASS: supersede comments" || { echo "FAIL: no comment"; FAIL=1; }
grep -q 'PATCH repos/o/r/issues/1 -f state=closed -f state_reason=completed' "$WRITES" && echo "PASS: supersede closes as completed" || { echo "FAIL: close: $(cat "$WRITES")"; FAIL=1; }
check "superseded issue no longer open in the index" "$(finding_issue_plan "$IDX" security aaaa000000000001)" "reopen 1"
: > "$WRITES"
finding_issue_supersede o/r "$IDX" 1 "x" not_planned >/dev/null
grep -q 'state_reason=not_planned' "$WRITES" && echo "PASS: supersede takes a state reason" || { echo "FAIL: reason ignored"; FAIL=1; }
touch "$WORK/fail"
finding_issue_supersede o/r "$IDX" 7 "x" >/dev/null 2>&1; rc=$?
check "failed supersede is rc 1" "$rc" 1
rm -f "$WORK/fail"

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

dam() { finding_issues_dependency_auto_merge "$1" security "$2" 2>/dev/null; }
check "dependency merge: default on" "$(dam "" "")" 1
check "dependency merge: machine off" "$(dam "" false)" 0
check "dependency merge: repo off beats machine on" "$(dam '{"security":{"dependency_auto_merge":false}}' true)" 0
check "dependency merge: repo on beats machine off" "$(dam '{"security":{"dependency_auto_merge":true}}' 0)" 1
check "dependency merge: other section ignored" "$(dam '{"coherence":{"dependency_auto_merge":false}}' "")" 1
check "dependency merge: unknown => off" "$(dam "" maybe)" 0
check "dependency merge: invalid JSON => off" "$(dam '{not json' 1)" 0

runs() { finding_issues_auto_runs "$1" "$2" && echo yes || echo no; }
check "high reaches high" "$(runs high high)" yes
check "critical reaches high" "$(runs high critical)" yes
check "medium does not reach high" "$(runs high medium)" no
check "none stops critical" "$(runs none critical)" no
check "unknown severity never runs" "$(runs low bogus)" no

# ---- grouping by package version (#397) -------------------------------------------
# shellcheck source=../lib/dependency-findings.sh
. "$HERE/../lib/dependency-findings.sh"
check "fix: lowest above installed" "$(dependency_fix_version 3.1.5 2.4.1,3.2.0,3.10.0)" 3.2.0
check "fix: none above installed" "$(dependency_fix_version 3.1.5 2.4.1)" ""
check "fix: none known" "$(dependency_fix_version 3.1.5 "")" ""
T=$'\t'
{
  printf 'package-lock.json%snpm%sfast-uri%s3.1.5%shigh%sGHSA-a,CVE-1%s3.1.7%sone%sd1\n' "$T" "$T" "$T" "$T" "$T" "$T" "$T" "$T"
  printf 'package-lock.json%snpm%sfast-uri%s3.1.5%scritical%sGHSA-b%s2.4.1,3.2.0%s%sd2\n' "$T" "$T" "$T" "$T" "$T" "$T" "$T" "$T"
  printf 'sub/package-lock.json%snpm%sfast-uri%s3.1.5%smedium%sGHSA-c%s3.1.6%sthree%sd3\n' "$T" "$T" "$T" "$T" "$T" "$T" "$T" "$T"
  printf 'package-lock.json%snpm%sflatted%s3.2.0%slow%sGHSA-z%s%s%sd4\n' "$T" "$T" "$T" "$T" "$T" "$T" "$T" "$T"
} > "$WORK/osv.tsv"
G=$(dependency_findings_group "$WORK/osv.tsv" "$WORK/deps.tsv")
check "group: one finding per package version" "$(printf '%s\n' "$G" | grep -c .)" 2
check "group: worst severity, every id, across lockfiles" "$(printf '%s\n' "$G" | head -n 1)" \
  "scanner|critical|high|npm/fast-uri@3.1.5|osv-scanner-pkg: npm/fast-uri@3.1.5: GHSA-a,CVE-1,GHSA-b,GHSA-c"
check "group: an empty column stays empty" "$(dependency_details_of "$WORK/deps.tsv" npm/fast-uri@3.1.5 | sed -n 2p | cut -f9,10)" "${T}d2"
check "fix all: the highest of the fixes" "$(dependency_fix_all "$WORK/deps.tsv" npm/fast-uri@3.1.5)" 3.2.0
check "fix all: unknown when one advisory has none" "$(dependency_fix_all "$WORK/deps.tsv" npm/flatted@3.2.0)" ""
check "parse: key and ids" "$(dependency_finding_parse 'osv-scanner-pkg: Maven/g:a@1.0: X,Y')" "Maven/g:a@1.0${T}X,Y"
dependency_finding_parse 'osv-scanner: x@1 (npm): X' >/dev/null && { echo "FAIL: per-advisory row parsed as grouped"; FAIL=1; } || echo "PASS: per-advisory row is not a grouped one"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "finding-issues: all passed" || echo "finding-issues: FAILURES"
[ "$FAIL" -eq 0 ]
