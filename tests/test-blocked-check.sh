#!/usr/bin/env bash
# test-blocked-check.sh — count_open_blockers (lib/issue.sh), the authoritative
# blocked-by read behind orchestrate.sh's S2b gate (issue #28).
#
# WHY THIS EXISTS:
#   The pickup search excludes blocked issues with `-is:blocked`, which reads
#   GitHub's eventually-consistent SEARCH index. A lagging index once leaked 25
#   blocked issues into pickup. count_open_blockers reads the strongly consistent
#   dependency GRAPH directly (GET .../issues/{n}/dependencies/blocked_by) as a
#   second line of defence. Its CONTRACT is what makes the gate safe:
#     - success  → prints the open-blocker count, returns 0
#     - ANY read failure (network/auth/endpoint-absent/garbage body) → returns
#       non-zero, prints nothing → the caller MUST assume blocked (FAIL-CLOSED).
#   The fail-closed direction is the whole point: a false positive costs one
#   skipped tick, a false negative costs a whole out-of-order run. This test pins
#   both the counting AND the fail-closed direction so a future refactor that
#   flips to `|| echo 0` (fail-open) turns the test red.
#
# `gh` is mocked via a PATH shim. For the counting cases the shim runs the REAL
# jq with the expression count_open_blockers passes, so the jq filter
# ([.[] | select(.state=="open")] | length) is genuinely exercised, not faked.
#
# Run: bash tests/test-blocked-check.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISSUE_LIB="$HERE/../lib/issue.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed — count_open_blockers exercises a real jq filter"
  exit 0
fi

WORK=$(mktemp -d -t blockedchk.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
fail() { echo "FAIL: $*"; FAIL=1; }
pass() { echo "PASS: $*"; }

# --- gh mock -------------------------------------------------------------
# Emulates `gh api <path> --jq <expr>`. The path encodes the issue number
# (…/issues/<N>/dependencies/blocked_by), which selects a canned fixture:
#   1 → two open + one closed blocker   → real jq → "2"
#   2 → no dependencies ([])            → real jq → "0"
#   3 → only closed blockers           → real jq → "0"
#   4 → simulate an API/network error  → exit 22, no output (fail-closed)
#   5 → unexpected non-numeric body     → prints "garbage", exit 0 (guard)
# The full path is recorded so we can assert non-origin owner/repo targeting.
BIN="$WORK/bin"
mkdir -p "$BIN"
PATHLOG="$WORK/pathlog.txt"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
# Record the API path and locate the --jq expression.
path=""
expr=""
prev=""
for a in "\$@"; do
  case "\$prev" in
    api)   path="\$a" ;;
    --jq)  expr="\$a" ;;
  esac
  prev="\$a"
done
printf '%s\n' "\$path" >> "$PATHLOG"

# Issue number is the path segment before /dependencies/blocked_by.
n="\${path#*/issues/}"; n="\${n%%/*}"

emit_jq() {  # \$1 = fixture JSON
  printf '%s' "\$1" | jq -r "\$expr"
}

case "\$n" in
  1) emit_jq '[{"state":"open"},{"state":"open"},{"state":"closed"}]' ;;
  2) emit_jq '[]' ;;
  3) emit_jq '[{"state":"closed"},{"state":"closed"}]' ;;
  4) exit 22 ;;                    # HTTP/network failure surface
  5) printf 'garbage\n'; exit 0 ;; # rc 0 but non-numeric body
  6) emit_jq '[{"state":"open"}]' ;;
  # Cross-repo blocker (issue #92): the dependencies API returns a blocker that
  # lives in ANOTHER repo. count_open_blockers must still count it (a cross-repo
  # blocker must not be lost — the issue stays blocked). AC4.
  10) emit_jq '[{"state":"open","repository_url":"https://api.github.com/repos/other/repo"}]' ;;
  *) echo "mock gh: unexpected issue '\$n' (path=\$path)" >&2; exit 99 ;;
esac
SH
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# shellcheck source=../lib/issue.sh
. "$ISSUE_LIB"

REPO="$WORK"  # any dir; gh is mocked so cwd is irrelevant

# --- 1. open blockers → prints count, rc 0 -------------------------------
set +e
out=$(count_open_blockers "$REPO" 1); rc=$?
set -e
[ "$rc" = "0" ]  || fail "open blockers: expected rc 0, got $rc"
[ "$out" = "2" ] || fail "open blockers: expected count 2, got [$out]"
[ "$rc" = "0" ] && [ "$out" = "2" ] && pass "two open blockers → prints 2, rc 0"

# --- 2. no dependencies → prints 0, rc 0 (NOT an error) ------------------
set +e
out=$(count_open_blockers "$REPO" 2); rc=$?
set -e
{ [ "$rc" = "0" ] && [ "$out" = "0" ]; } \
  && pass "no dependencies → prints 0, rc 0" \
  || fail "no dependencies: expected 0/rc0, got [$out]/rc$rc"

# --- 3. only closed blockers → prints 0, rc 0 (closed ones don't block) --
set +e
out=$(count_open_blockers "$REPO" 3); rc=$?
set -e
{ [ "$rc" = "0" ] && [ "$out" = "0" ]; } \
  && pass "only closed blockers → prints 0, rc 0" \
  || fail "closed blockers: expected 0/rc0, got [$out]/rc$rc"

# --- 4. API/network error → non-zero rc, empty stdout (FAIL-CLOSED) ------
set +e
out=$(count_open_blockers "$REPO" 4); rc=$?
set -e
[ "$rc" != "0" ] || fail "API error: expected non-zero rc (fail-closed), got rc 0"
[ -z "$out" ]    || fail "API error: expected empty stdout, got [$out]"
{ [ "$rc" != "0" ] && [ -z "$out" ]; } && pass "API error → non-zero rc, empty stdout (fail-closed)"

# --- 5. non-numeric body with rc 0 → non-zero rc (guard, FAIL-CLOSED) ----
# Defends the caller's `[ "$n" -gt 0 ]`: a body gh somehow returned with rc 0
# but that is not a number must be treated as blocked, not silently as "0".
set +e
out=$(count_open_blockers "$REPO" 5); rc=$?
set -e
[ "$rc" != "0" ] || fail "non-numeric body: expected non-zero rc (fail-closed), got rc 0"
[ -z "$out" ]    || fail "non-numeric body: expected empty stdout, got [$out]"
{ [ "$rc" != "0" ] && [ -z "$out" ]; } && pass "non-numeric body → non-zero rc (guard, fail-closed)"

# --- 6. non-origin owner/repo → explicit path targeting ------------------
# Multi-org (issue #53): when an owner/repo is passed, the API path must target
# it explicitly instead of relying on gh's {owner}/{repo} cwd substitution.
: > "$PATHLOG"
set +e
out=$(count_open_blockers "$REPO" 6 "partner-org/app"); rc=$?
set -e
[ "$rc" = "0" ]  || fail "owner/repo: expected rc 0, got $rc"
[ "$out" = "1" ] || fail "owner/repo: expected count 1, got [$out]"
if grep -qF 'repos/partner-org/app/issues/6/dependencies/blocked_by' "$PATHLOG"; then
  pass "non-origin owner/repo targets explicit dependency path"
else
  fail "owner/repo: path did not target partner-org/app explicitly: $(cat "$PATHLOG")"
fi

# --- 7. origin (no owner/repo) → {owner}/{repo} placeholder path ----------
# The empty-owner_repo case must keep the gh placeholder so gh resolves it from
# the cwd remote — the legacy single-remote path every existing test relies on.
: > "$PATHLOG"
set +e
count_open_blockers "$REPO" 2 >/dev/null; rc=$?
set -e
if grep -qF 'repos/{owner}/{repo}/issues/2/dependencies/blocked_by' "$PATHLOG"; then
  pass "empty owner/repo keeps {owner}/{repo} placeholder path"
else
  fail "empty owner/repo: expected placeholder path, got: $(cat "$PATHLOG")"
fi

# --- 8. cross-repo blocker → still counted, issue stays blocked (issue #92) ---
# The blocked_by dependency graph can point at a blocker in ANOTHER repo. S2b must
# not lose it: count_open_blockers counts every OPEN blocker regardless of repo,
# so the dependent issue is held back exactly as for a same-repo blocker (AC4).
set +e
out=$(count_open_blockers "$REPO" 10); rc=$?
set -e
{ [ "$rc" = "0" ] && [ "$out" = "1" ]; } \
  && pass "cross-repo blocker counted → issue stays blocked (AC4, #92)" \
  || fail "cross-repo blocker: expected 1/rc0 (still blocked), got [$out]/rc$rc"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "blocked-check: all passed" || echo "blocked-check: FAILURES"
[ "$FAIL" -eq 0 ]
