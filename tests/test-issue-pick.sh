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
# 18 sits out of numeric order on purpose: the list is in CREATION order, and it
# has to precede 17 for its exclusion (auto-reset, issue #202) to be provable —
# a term that fails open would return 18, not 17. That exclusion is a correctness
# condition, not an optimisation: pickup must stay off a reset target until the
# teardown has run and the label is gone.
cat > "$ISSUES" <<'JSON'
[
 {"number":10,"labels":[{"name":"auto-run"}]},
 {"number":11,"labels":[{"name":"auto-run"},{"name":"auto-claimed"}]},
 {"number":12,"labels":[{"name":"auto-run"},{"name":"waiting"}]},
 {"number":13,"labels":[{"name":"auto-run"},{"name":"wip"}]},
 {"number":14,"labels":[{"name":"auto-run"},{"name":"epic"}]},
 {"number":15,"labels":[{"name":"auto-run"},{"name":"auto-clean"}]},
 {"number":16,"labels":[{"name":"auto-run"}],"pull_request":{"url":"x"}},
 {"number":18,"labels":[{"name":"auto-run"},{"name":"auto-reset"}]},
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

# --- 9b. the optional assignee allow-list (issue #238) ---------------------
# The one filter here that NARROWS pickup, so every case below is about a way
# it could narrow too much. The fixture keeps ONE variable per issue:
#
#   20  assigned to a listed login              -> picked
#   21  no assignee, author listed              -> picked (the author fallback)
#   22  no assignee, author NOT listed          -> not picked
#   23  assigned OUTSIDE the list, author listed -> not picked (human opt-out)
#
# 23 is the case that proves the fallback's direction: it applies only to an
# unassigned issue, so an explicit assignment wins over authorship.
cat > "$ISSUES" <<'JSON'
[
 {"number":20,"labels":[{"name":"auto-run"}],"assignees":[{"login":"runner-a"}],"user":{"login":"outsider"}},
 {"number":21,"labels":[{"name":"auto-run"}],"assignees":[],"user":{"login":"author-x"}},
 {"number":22,"labels":[{"name":"auto-run"}],"assignees":[],"user":{"login":"outsider"}},
 {"number":23,"labels":[{"name":"auto-run"}],"assignees":[{"login":"outsider"}],"user":{"login":"author-x"}}
]
JSON

# Absent and empty must both mean "do not filter": the alternative reading of an
# empty allow-list ("allow nobody") would make a repo stop picking up silently
# and forever — the same failure class as listing auto-clean as a pickup label.
check "no assignee list => unchanged pickup" \
  "$(pick_oldest_candidate "$REPO" "auto-run" "o/r")" "20"
check "empty assignee list => no filtering" \
  "$(pick_oldest_candidate "$REPO" "auto-run" "o/r" "" "")" "20"
check "whitespace-only assignee list => no filtering" \
  "$(pick_oldest_candidate "$REPO" "auto-run" "o/r" "" " , ")" "20"

check "an assignee on the list is picked" \
  "$(pick_oldest_candidate "$REPO" "auto-run" "o/r" "" "runner-a")" "20"

# Hide 20: the next match must be 21 (author fallback), never 22 or 23.
jq 'map(select(.number != 20))' "$ISSUES" > "$WORK/no20.json" && mv "$WORK/no20.json" "$ISSUES"
check "an unassigned issue falls back to its author" \
  "$(pick_oldest_candidate "$REPO" "auto-run" "o/r" "" "author-x")" "21"
check "an unassigned issue by an unlisted author is skipped" \
  "$(pick_oldest_candidate "$REPO" "auto-run" "o/r" "" "runner-a")" ""
check "an assignee outside the list wins over a listed author" \
  "$(pick_oldest_candidate "$REPO" "auto-run" "o/r" "" "author-x,runner-a")" "21"

# Surrounding whitespace in the CSV must not turn a login into a non-match:
# the watchlist is hand-edited JSON.
check "logins are trimmed before matching" \
  "$(pick_oldest_candidate "$REPO" "auto-run" "o/r" "" " author-x , runner-a ")" "21"

# The list must not cost an extra call or change the query: .assignees and
# .user.login are already in the REST payload.
: > "$ARGV"
pick_oldest_candidate "$REPO" "auto-run" "o/r" "" "author-x" >/dev/null
check "assignee filtering issues exactly one listing call" \
  "$(grep -c 'repos/o/r/issues?' "$ARGV")" "1"
# The allow-list belongs in the LOCAL jq filter, never in the query string:
# a server-side assignee term would change the query shape #133 pinned to REST,
# and REST has no way to express "unassigned OR assigned to one of these".
if grep -E '^repos/.*(assignee|creator)' "$ARGV" >/dev/null; then
  fail "the assignee list leaked into the REST query string"
fi
ok "assignee filtering is local: same query, same call count"

# --- 9c. the negation form of the assignee list (issue #246) ---------------
# A `not:<login>` entry denies a target instead of allowing it, so two machines
# can split work as ["runner-a"] on one and ["not:runner-a"] on the other with
# no second repo-authorised account. The fixture keeps ONE variable per issue:
#
#   30  assigned to runner-a                       -> DENY-listed
#   31  assigned to runner-b                        -> not denied
#   32  no assignee, author runner-a                -> DENY reaches the author
#   33  two assignees, one of them runner-a          -> one DENY hit rejects
#   34  assigned to a login that only PREFIXES "not" -> ordinary login, allowed
cat > "$ISSUES" <<'JSON'
[
 {"number":30,"labels":[{"name":"auto-run"}],"assignees":[{"login":"runner-a"}],"user":{"login":"outsider"}},
 {"number":31,"labels":[{"name":"auto-run"}],"assignees":[{"login":"runner-b"}],"user":{"login":"outsider"}},
 {"number":32,"labels":[{"name":"auto-run"}],"assignees":[],"user":{"login":"runner-a"}},
 {"number":33,"labels":[{"name":"auto-run"}],"assignees":[{"login":"runner-b"},{"login":"runner-a"}],"user":{"login":"outsider"}},
 {"number":34,"labels":[{"name":"auto-run"}],"assignees":[{"login":"notrunner"}],"user":{"login":"outsider"}}
]
JSON

# A pure DENY list ("not:runner-a") must leave everyone else runnable: an empty
# ALLOW means "any login", not "no match". The oldest non-denied issue is 31.
check "pure DENY list => others still pick up" \
  "$(pick_oldest_candidate "$REPO" "auto-run" "o/r" "" "not:runner-a")" "31"
# A DENY hit rejects the assigned issue (30) and the DENY reaches the author of
# an unassigned one (32); the two-assignee issue 33 is rejected on one hit.
check "a DENY assignee is skipped" \
  "$(pick_oldest_candidate "$REPO" "auto-run" "o/r" "" "not:runner-b,not:runner-a")" "34"
# not: without the colon is an ordinary login: `notrunner` on the ALLOW list
# matches issue 34, and nothing is denied.
check "not without a colon is an ordinary login" \
  "$(pick_oldest_candidate "$REPO" "auto-run" "o/r" "" "notrunner")" "34"

# ALLOW and DENY together: BOTH conditions are required. Allow runner-a and
# runner-b, deny runner-a -> only 31 (runner-b) survives; 30 is denied, 33 has a
# DENY hit, 32's author is denied, 34's login is not allowed.
check "ALLOW+DENY require both conditions" \
  "$(pick_oldest_candidate "$REPO" "auto-run" "o/r" "" "runner-a,runner-b,not:runner-a")" "31"
# The same login in both lists: DENY beats ALLOW. Allowing runner-a and denying
# it must reject 30, not pick it.
check "same login in ALLOW and DENY => DENY wins" \
  "$(pick_oldest_candidate "$REPO" "auto-run" "o/r" "" "runner-a,not:runner-a")" ""

# The author fallback reaches the negation too: an unassigned issue whose author
# is denied stays out even though nothing else disqualifies it.
cat > "$ISSUES" <<'JSON'
[
 {"number":40,"labels":[{"name":"auto-run"}],"assignees":[],"user":{"login":"runner-a"}}
]
JSON
check "unassigned issue by a DENY author is skipped" \
  "$(pick_oldest_candidate "$REPO" "auto-run" "o/r" "" "not:runner-a")" ""

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
