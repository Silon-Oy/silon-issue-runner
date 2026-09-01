#!/usr/bin/env bash
# test-issue-pick.sh — pick_oldest_candidate: REST query shape, local exclusion
# filters, and blocked-issue skipping.
#
# WHY THIS IS REST (issue #133). `gh issue list` routes any FILTERED query
# through GitHub's GraphQL `search` connection. On 2026-08-28/29 that connection
# was blocked for 27 hours while REST and unfiltered listing answered normally,
# so pickup could not run at all. Measured on one repo, interleaved with an
# unfiltered control four seconds apart:
#
#   gh issue list --limit 1 --json number    OK  (x3)
#   gh issue list --label X --state all      REJECTED
#   gh issue list --search "…"               REJECTED
#   gh api repos/…/issues?labels=…           OK
#
# Case 6 pins that: pickup must speak REST and must never reach for a search.
#
# WHAT REPLACED THE QUERY QUALIFIERS. The standing `-label:…` exclusions are now
# a jq membership test over the label array. That is strictly SAFER than what it
# replaced: an unknown negative qualifier does not error on GitHub, it silently
# matches everything, so a typo like `-label:wpi` used to leak excluded issues
# into pickup. A typo in a jq index() yields no match instead. The mock therefore
# runs the REAL --jq filter over fixture JSON rather than returning canned
# numbers — otherwise these cases would assert the mock, not the filter.
#
# `-is:blocked` has NO REST equivalent, so it is a real behaviour change and gets
# the most coverage here (cases 2-5). Dropping it outright would spin: S2b
# rejects a blocked issue BEFORE the claim, so the same issue would be re-picked
# every tick forever. Instead candidates are walked oldest-first and probed with
# count_open_blockers — the same authoritative read S2b uses — stopping at the
# first unblocked one.
#
# Run: bash tests/test-issue-pick.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISSUE_LIB="$HERE/../lib/issue.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

WORK=$(mktemp -d -t issuepick.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
fail() { echo "FAIL $1"; FAIL=1; }
ok()   { echo "PASS $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else fail "$1: got=[$2] want=[$3]"; fi; }

BIN="$WORK/bin"; mkdir -p "$BIN"
ARGV="$WORK/argv.txt"; : > "$ARGV"
ISSUES="$WORK/issues.json"
BLOCKDIR="$WORK/blockers"; mkdir -p "$BLOCKDIR"

# --- gh shim ---------------------------------------------------------------
# Answers the two REST paths pickup uses and applies the caller's own --jq
# filter, so the filter under test really runs. A blockers file containing the
# word "error" makes the call fail, exercising the fail-closed path.
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$ARGV"
[ "\${1:-}" = "api" ] || exit 0
path="\$2"; filter="cat"
while [ \$# -gt 0 ]; do
  if [ "\$1" = "--jq" ]; then filter="\$2"; fi
  shift
done
case "\$path" in
  */dependencies/blocked_by)
    rest="\${path%/dependencies/blocked_by}"; n="\${rest##*/}"
    f="$BLOCKDIR/\$n"
    [ -f "\$f" ] || f=/dev/null
    grep -q error "\$f" 2>/dev/null && exit 1
    { [ -s "\$f" ] && cat "\$f" || echo '[]'; } | jq -r "\$filter"
    ;;
  */issues\?*) jq -r "\$filter" < "$ISSUES" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN/gh"
PATH="$BIN:$PATH"

# shellcheck source=lib/issue.sh
. "$ISSUE_LIB"

REPO="$WORK/repo"; mkdir -p "$REPO"

# --- fixture: ascending by creation, i.e. pickup order ----------------------
# 10 and 17 are runnable; everything between carries exactly one disqualifier,
# so a filter that drops the wrong term is caught by WHICH number comes back.
cat > "$ISSUES" <<'JSON'
[
 {"number":10,"labels":[{"name":"auto-run"}]},
 {"number":11,"labels":[{"name":"auto-run"},{"name":"auto-claimed"}]},
 {"number":12,"labels":[{"name":"auto-run"},{"name":"waiting"}]},
 {"number":13,"labels":[{"name":"auto-run"},{"name":"wip"}]},
 {"number":14,"labels":[{"name":"auto-run"},{"name":"epic"}]},
 {"number":15,"labels":[{"name":"auto-run"},{"name":"auto-clean"}]},
 {"number":16,"labels":[{"name":"auto-run"}],"pull_request":{"url":"x"}},
 {"number":17,"labels":[{"name":"auto-run"}]}
]
JSON

# --- 1. exclusions + PR filtering ------------------------------------------
: > "$ARGV"
check "oldest runnable candidate" "$(pick_oldest_candidate "$REPO" "auto-run" "o/r")" "10"

# Prove each disqualifier individually: hide 10, and the answer must skip the
# whole excluded block and land on 17 rather than on 11-16.
jq 'map(select(.number != 10))' "$ISSUES" > "$WORK/no10.json" && mv "$WORK/no10.json" "$ISSUES"
check "every disqualifier drops its issue" "$(pick_oldest_candidate "$REPO" "auto-run" "o/r")" "17"
# A pull request must never be handed over as an issue: REST /issues returns
# both, and 16 sits before 17 in the list.
: > "$ARGV"

# restore 10
cat > "$ISSUES" <<'JSON'
[
 {"number":10,"labels":[{"name":"auto-run"}]},
 {"number":16,"labels":[{"name":"auto-run"}],"pull_request":{"url":"x"}},
 {"number":17,"labels":[{"name":"auto-run"}]}
]
JSON

# --- 2. blocked issues are skipped -----------------------------------------
printf '[{"state":"open"}]\n' > "$BLOCKDIR/10"
check "blocked oldest is skipped" "$(pick_oldest_candidate "$REPO" "auto-run" "o/r")" "17"

# A CLOSED blocker does not block (count_open_blockers filters on state).
printf '[{"state":"closed"}]\n' > "$BLOCKDIR/10"
check "closed blocker does not block" "$(pick_oldest_candidate "$REPO" "auto-run" "o/r")" "10"

# --- 3. everything blocked => no candidate ---------------------------------
printf '[{"state":"open"}]\n' > "$BLOCKDIR/10"
printf '[{"state":"open"}]\n' > "$BLOCKDIR/17"
check "all blocked => empty" "$(pick_oldest_candidate "$REPO" "auto-run" "o/r")" ""

# --- 4. unreadable dependency graph is fail-closed -------------------------
# S2b treats an unreadable graph as blocked; pickup must agree, or it would hand
# over an issue S2b will then refuse — the spin this design exists to avoid.
printf 'error\n' > "$BLOCKDIR/10"
rm -f "$BLOCKDIR/17"
check "unreadable graph is treated as blocked" "$(pick_oldest_candidate "$REPO" "auto-run" "o/r")" "17"

# --- 5. probe budget -------------------------------------------------------
# A backlog that is entirely blocked must not spend a tick walking it.
printf '[{"state":"open"}]\n' > "$BLOCKDIR/10"
rm -f "$BLOCKDIR/17"
check "probe cap yields no candidate" \
  "$(RUN_ISSUES_PICK_BLOCKED_PROBES=1 pick_oldest_candidate "$REPO" "auto-run" "o/r")" ""
check "probe cap of 2 reaches the second candidate" \
  "$(RUN_ISSUES_PICK_BLOCKED_PROBES=2 pick_oldest_candidate "$REPO" "auto-run" "o/r")" "17"
rm -f "$BLOCKDIR/10"

# --- 6. THE #133 guard: REST, never the search connection ------------------
: > "$ARGV"
pick_oldest_candidate "$REPO" "auto-run" "o/r" >/dev/null
grep -qxF -- "api" "$ARGV"           || fail "pickup did not call 'gh api' (REST)"
grep -q "repos/o/r/issues?" "$ARGV"  || fail "pickup did not target the REST issues endpoint"
grep -q -- "--search" "$ARGV"        && fail "pickup used --search: back on the blocked GraphQL search connection"
grep -qxF -- "issue" "$ARGV"         && fail "pickup used 'gh issue …': filtered issue list is search-routed"
grep -q "state=open" "$ARGV"         || fail "pickup did not restrict to open issues"
grep -q "sort=created&direction=asc" "$ARGV" || fail "pickup lost its oldest-first ordering"
grep -q "labels=auto-run" "$ARGV"    || fail "pickup did not pass the run labels"
ok "pickup speaks REST and never reaches for search"

# --- 7. multi-label CSV is ANDed in one labels= parameter ------------------
# REST ANDs a comma list (measured 2026-08-29: labels=auto-run,epic returned 0
# while labels=auto-run returned 5) — the same semantics the separate
# label:"x" search terms had.
check "labels CSV joins into one AND list" "$(_labels_query_csv "auto-run,enhancement")" "auto-run,enhancement"
check "extra required labels come first" "$(_labels_query_csv "auto-run" "epic")" "epic,auto-run"
check "empty CSV yields no labels term" "$(_labels_query_csv "")" ""
: > "$ARGV"
pick_oldest_candidate "$REPO" "auto-run,enhancement" "o/r" >/dev/null
grep -q "labels=auto-run,enhancement" "$ARGV" || fail "multi-label CSV did not reach the labels= parameter"
ok "multi-label CSV reaches labels="

# --- 8. owner/repo must not be word-split by the IFS=',' label loop --------
# _labels_query_csv sets IFS=',' to split the CSV. If that leaked, the owner/repo
# would be mangled into the path and every non-origin repo would silently stop
# being polled.
: > "$ARGV"
pick_oldest_candidate "$REPO" "a,b" "partner-org/app" >/dev/null
grep -q "repos/partner-org/app/issues?" "$ARGV" \
  || fail "owner/repo mangled — IFF=',' leaked out of the label loop"
ok "owner/repo survives the IFS=',' label split"

# Empty owner/repo falls back to gh's {owner}/{repo} placeholders.
: > "$ARGV"
pick_oldest_candidate "$REPO" "auto-run" >/dev/null
grep -q "repos/{owner}/{repo}/issues?" "$ARGV" \
  || fail "empty owner/repo did not fall back to gh's placeholders"
ok "empty owner/repo uses gh's cwd placeholders"

# --- 9. zero matches is a clean "no candidate" -----------------------------
echo '[]' > "$ISSUES"
out="$(pick_oldest_candidate "$REPO" "auto-run" "o/r")"; rc=$?
check "no matches => empty stdout" "$out" ""
check "no matches => rc 0" "$rc" "0"

# --- 10. poller.sh still delegates; no second pickup query ------------------
# Issue #99 converged the two pickup searches into one. This guards that
# convergence AND the #133 move: an inline pickup in poller.sh would be both a
# drift hazard and, if written as a filtered gh issue list, search-routed again.
POLLER_SH="$HERE/../poller.sh"
if grep -vE '^\s*#' "$POLLER_SH" | grep -qE 'gh issue list.*(--search|--label)'; then
  fail "poller.sh has a filtered 'gh issue list' — that is search-routed (issue #133)"
fi
if ! grep -q 'pick_oldest_candidate' "$POLLER_SH"; then
  fail "poller.sh no longer calls pick_oldest_candidate — the single pickup query was lost"
fi
ok "poller.sh delegates pickup and has no search-routed listing"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "issue-pick: all passed" || echo "issue-pick: FAILURES"
[ "$FAIL" -eq 0 ]
