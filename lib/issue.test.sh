#!/usr/bin/env bash
# Unit tests for verify_claim — guards against the S2/S3 race where two
# runners both successfully `gh issue edit --add-assignee @me` and both
# previously passed verification (issue #6).
#
# Issue #99 changed the rule from "@me is the SOLE assignee" to "the assignee set
# AFTER the claim equals the set BEFORE the claim ∪ {@me}". The before-set is the
# 4th argument (empty when nobody was assigned, which reduces to the old rule).
# This lets a hand-assigned issue run — a human who assigned themselves or a
# colleague no longer fails verification — while a racing runner on another
# account still shows up as an extra login and loses. Cases 1–5 keep the empty
# before-set (old semantics still hold); cases 6–8 exercise the new before-set.
#
# Tests use a mock `gh` stub on PATH that replays canned JSON for
# `gh issue view --json assignees`.
#
# Run directly:
#   bash lib/issue.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=issue.sh
source "$SCRIPT_DIR/issue.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=$((FAILED + 1)); }
pass() { echo "PASS: $*"; }

# install_gh_stub <assignees-csv>
# Creates a `gh` executable in $TMP/bin that returns the given CSV as
# the joined-assignees jq output for `gh issue view --json assignees`,
# and a fixed login for `gh api user`. Other gh calls fail loudly so
# tests don't silently regress.
install_gh_stub() {
  local assignees_csv="$1"
  local stub="$TMP/bin/gh"
  mkdir -p "$TMP/bin"
  cat > "$stub" <<EOF
#!/usr/bin/env bash
# Mock gh — minimal surface for verify_claim tests.
case "\$1 \$2" in
  "api user")
    # gh api user --jq .login
    echo "maintainer"
    ;;
  "issue view")
    # gh issue view N --json assignees --jq '[.assignees[].login] | join(",")'
    echo "$assignees_csv"
    ;;
  *)
    echo "mock gh: unexpected invocation: \$*" >&2
    exit 99
    ;;
esac
EOF
  chmod +x "$stub"
  export PATH="$TMP/bin:$PATH"
}

reset_path() {
  export PATH="${ORIG_PATH:-$PATH}"
}

ORIG_PATH="$PATH"

# ── Test 1: sole assignee → verify_claim succeeds ────────────────────
install_gh_stub "maintainer"
if verify_claim "$TMP" 1; then
  pass "sole assignee (me) → verify_claim returns 0"
else
  fail "sole assignee (me) → verify_claim should return 0"
fi
reset_path

# ── Test 2: race — two assignees including me → verify_claim fails ────
install_gh_stub "maintainer,other-runner"
if verify_claim "$TMP" 2; then
  fail "two assignees (me + other) → verify_claim should return non-zero"
else
  pass "two assignees (me + other) → verify_claim returns non-zero"
fi
reset_path

# ── Test 3: race — same set but listed in opposite order ─────────────
install_gh_stub "other-runner,maintainer"
if verify_claim "$TMP" 3; then
  fail "two assignees (other + me) → verify_claim should return non-zero"
else
  pass "two assignees (other + me) → verify_claim returns non-zero (order-independent)"
fi
reset_path

# ── Test 4: only the other runner is assigned → verify_claim fails ───
install_gh_stub "other-runner"
if verify_claim "$TMP" 4; then
  fail "only other is assignee → verify_claim should return non-zero"
else
  pass "only other is assignee → verify_claim returns non-zero"
fi
reset_path

# ── Test 5: empty assignees → verify_claim fails ─────────────────────
install_gh_stub ""
if verify_claim "$TMP" 5; then
  fail "empty assignees → verify_claim should return non-zero"
else
  pass "empty assignees → verify_claim returns non-zero"
fi
reset_path

# ── Test 6: human pre-assigned THEMSELVES (== @me account) → passes ──
# The bot and the human share an account, so a human who assigned themselves looks
# identical to @me. before={me}, after={me} → before ∪ {me} == after → pass.
install_gh_stub "maintainer"
if verify_claim "$TMP" 6 "" "maintainer"; then
  pass "pre-assigned self → verify_claim returns 0 (before ∪ {me} == after)"
else
  fail "pre-assigned self → verify_claim should return 0"
fi
reset_path

# ── Test 7: human pre-assigned a COLLEAGUE → passes (the #99 fix) ────
# A different person was assigned before the claim; after the claim the set is
# {colleague, me} == {colleague} ∪ {me}. This is the whole point of issue #99: a
# hand-assigned issue must no longer crash the run at exit 3.
install_gh_stub "coworker,maintainer"
if verify_claim "$TMP" 7 "" "coworker"; then
  pass "pre-assigned colleague → verify_claim returns 0 (hand-assigned issue runs)"
else
  fail "pre-assigned colleague → verify_claim should return 0"
fi
reset_path

# ── Test 8: racing runner (another account) during the window → fails ─
# before={coworker}, but after gained BOTH me AND a third login from a competing
# runner: {coworker, me, other-runner} != {coworker} ∪ {me}. The extra login is
# the race signal → verify_claim fails, the run backs off with exit 3 as before.
install_gh_stub "coworker,maintainer,other-runner"
if verify_claim "$TMP" 8 "" "coworker"; then
  fail "racing runner during window → verify_claim should return non-zero"
else
  pass "racing runner during window → verify_claim returns non-zero (extra login caught)"
fi
reset_path

# ── Summary ──────────────────────────────────────────────────────────
if [[ "$FAILED" -gt 0 ]]; then
  echo "$FAILED test(s) failed." >&2
  exit 1
fi
echo "All verify_claim tests passed."
