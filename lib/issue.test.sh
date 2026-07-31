#!/usr/bin/env bash
# Unit tests for verify_claim — guards against the S2/S3 race where two
# runners both successfully `gh issue edit --add-assignee @me` and both
# previously passed verification (issue #6). The fix: verify_claim returns 0
# only when @me is the SOLE assignee.
#
# Tests use a mock `gh` stub on PATH that replays canned JSON for
# `gh issue view --json assignees`.
#
# Run directly:
#   bash claude/scripts/run-issues/lib/issue.test.sh

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

# ── Summary ──────────────────────────────────────────────────────────
if [[ "$FAILED" -gt 0 ]]; then
  echo "$FAILED test(s) failed." >&2
  exit 1
fi
echo "All verify_claim tests passed."
