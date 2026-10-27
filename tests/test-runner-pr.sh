#!/usr/bin/env bash
# test-runner-pr.sh — lib/runner-pr.sh (issue #375): the ONE definition of the
# runner's head-branch prefix and the ONE listing of merged runner PRs.
#
#   pages     runner_pr_page_needs_more: full page inside the window -> more,
#             short / older / empty -> done, not an array -> rc 2
#   listing   runner_merged_prs against a gh stub: prefix + merged filter, the
#             stop rules (short page, page ending before the window), the page
#             cap (rc 3), a gh failure (rc 1, stderr in the err-file), a
#             non-array page (rc 2), owner/repo default and base URI-encoding
#   literal   no `auto-run/` literal in executable shell code outside
#             lib/runner-pr.sh — derived from disk, fail-closed
#
# Run: bash tests/test-runner-pr.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available"
  exit 0
fi

# shellcheck source=../lib/runner-pr.sh
. "$ROOT/lib/runner-pr.sh"

WORK=$(mktemp -d -t runner-pr.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
check() { # <name> <want> <got>
  if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 — want '$2', got '$3'"; FAIL=1; fi
}

S="2026-10-23T10:00:00Z"
IN="2026-10-23T11:00:00Z"
OLD="2026-10-22T00:00:00Z"

# ----- pages ---------------------------------------------------------------
# page <n> <last-updated_at> — a JSON array of n rows, the last one updated then.
page() {
  jq -nc --argjson n "$1" --arg u "$2" '[range(0; $n) | {number: ., updated_at: "2026-10-24T00:00:00Z"}] | .[-1].updated_at = $u'
}
pg_rc() { local rc=0; RUNNER_PR_PER_PAGE=3 runner_pr_page_needs_more "$1" "$S" || rc=$?; printf '%s' "$rc"; }
check "page: full, oldest row inside the window -> more (0)" 0 "$(pg_rc "$(page 3 "$IN")")"
check "page: full, oldest row at the start instant -> more (0)" 0 "$(pg_rc "$(page 3 "$S")")"
check "page: full, oldest row before the window -> done (1)" 1 "$(pg_rc "$(page 3 "$OLD")")"
check "page: short page -> done (1)" 1 "$(pg_rc "$(page 2 "$IN")")"
check "page: empty page -> done (1)" 1 "$(pg_rc '[]')"
check "page: not an array -> rc 2" 2 "$(pg_rc '{"message":"Not Found"}')"
check "page: not JSON -> rc 2" 2 "$(pg_rc 'garbage')"

# ----- listing -------------------------------------------------------------
# A gh stub as a function (runner_merged_prs takes the runner as a word): pages
# come from $WORK/page-<n>.json, every call is logged, $WORK/fail fails it.
stub_gh() {
  local path="$2"
  printf '%s\n' "$path" >> "$WORK/calls"
  if [ -f "$WORK/fail" ]; then cat "$WORK/fail" >&2; return 1; fi
  local n="${path##*page=}"
  if [ -f "$WORK/page-$n.json" ]; then cat "$WORK/page-$n.json"; else echo '[]'; fi
}
reset() { rm -f "$WORK"/page-*.json "$WORK/calls" "$WORK/fail" "$WORK/err"; }
calls() { grep -c . "$WORK/calls" 2>/dev/null || echo 0; }
# pr <number> <merged_at|null> <head-ref> <updated_at>
pr() {
  jq -nc --argjson n "$1" --argjson m "$( [ "$2" = null ] && echo null || printf '"%s"' "$2")" \
    --arg r "$3" --arg u "$4" '{number: $n, merged_at: $m, head: {ref: $r}, updated_at: $u}'
}
# filler <file> <count> <updated_at> — unmerged non-runner rows.
filler() {
  jq -nc --argjson c "$2" --arg u "$3" \
    '[range(0; $c) | {number: (1000 + .), merged_at: null, head: {ref: "feature/x"}, updated_at: $u}]' > "$1"
}
list() { # <max-pages> [owner/repo] [base] — sets OUT and RC
  RC=0
  OUT=$(RUNNER_PR_PER_PAGE=3 runner_merged_prs stub_gh "${2-acme/repo}" "${3-main}" "$S" "$1" "$WORK/err") || RC=$?
}
numbers() { jq -r '[.[].number] | map(tostring) | join(",")' <<<"$OUT"; }

reset
printf '[%s,%s,%s]\n' "$(pr 1 "$IN" auto-run/a "$IN")" "$(pr 2 "$IN" feature/human "$IN")" \
  "$(pr 3 null auto-run/closed "$IN")" > "$WORK/page-1.json"
printf '[%s]\n' "$(pr 4 "$IN" auto-run/b "$IN")" > "$WORK/page-2.json"
list 5
check "listing: full page inside the window reads the next one" 2 "$(calls)"
check "listing: only merged runner PRs, across pages" "1,4" "$(numbers)"
check "listing: complete -> rc 0" 0 "$RC"
check "listing: REST closed-PR path, updated-desc" \
  "repos/acme/repo/pulls?state=closed&base=main&sort=updated&direction=desc&per_page=3&page=1" \
  "$(head -n 1 "$WORK/calls")"

reset
filler "$WORK/page-1.json" 3 "$OLD"
printf '[%s]\n' "$(pr 4 "$IN" auto-run/b "$IN")" > "$WORK/page-2.json"
list 5
check "listing: a page ending before the window stops the walk" "1 0" "$(calls) $RC"

reset
filler "$WORK/page-1.json" 3 "$IN"; filler "$WORK/page-2.json" 3 "$IN"
printf '[%s]\n' "$(pr 4 "$IN" auto-run/never-read "$IN")" > "$WORK/page-3.json"
list 2
check "listing: cap reached while still inside the window -> rc 3" 3 "$RC"
check "listing: cap bounds the calls" 2 "$(calls)"

reset
echo 'gh: Not Found (HTTP 404)' > "$WORK/fail"
list 5
check "listing: gh failure -> rc 1" 1 "$RC"
check "listing: gh stderr kept in the err-file" "gh: Not Found (HTTP 404)" "$(cat "$WORK/err")"

reset
echo '{"message":"Not Found"}' > "$WORK/page-1.json"
list 5
check "listing: a page that is not an array -> rc 2" 2 "$RC"

reset
echo '[]' > "$WORK/page-1.json"
list 5 "" "release/1.x"
check "listing: empty owner/repo -> {owner}/{repo}, base URI-encoded" \
  "repos/{owner}/{repo}/pulls?state=closed&base=release%2F1.x&sort=updated&direction=desc&per_page=3&page=1" \
  "$(head -n 1 "$WORK/calls")"
check "listing: empty listing -> [] rc 0" "[] 0" "$OUT $RC"

# ----- literal -------------------------------------------------------------
# The prefix is defined once. Every executable shell line outside the module
# and the tests is searched for the literal; comments are prose and may name it.
DEF=$(grep -c '^RUNNER_BRANCH_PREFIX="auto-run/"$' "$ROOT/lib/runner-pr.sh")
check "literal: lib/runner-pr.sh defines the prefix (fail-closed anchor)" 1 "$DEF"
STRAYS=$(cd "$ROOT" && find . -name '*.sh' -not -path './tests/*' -not -path './.git/*' \
           -not -path './lib/runner-pr.sh' -not -path './.claude/*' -print0 \
         | xargs -0 grep -nE 'auto-run/' 2>/dev/null \
         | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
check "literal: no auto-run/ in shell code outside lib/runner-pr.sh" "" "$STRAYS"
SCANNED=$(cd "$ROOT" && find . -name '*.sh' -not -path './tests/*' -not -path './.git/*' -not -path './.claude/*' | grep -c .)
if [ "$SCANNED" -lt 20 ]; then
  echo "FAIL: literal scan saw only $SCANNED shell file(s) — derivation broke"; FAIL=1
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "runner-pr: all passed" || echo "runner-pr: FAILURES"
[ "$FAIL" -eq 0 ]
