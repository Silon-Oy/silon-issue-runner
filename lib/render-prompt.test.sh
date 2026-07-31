#!/usr/bin/env bash
# Unit tests for render_prompt — guards against recursive placeholder
# substitution (issue #1) and verifies multi-line / glob / undefined-key
# behaviour. Run directly:
#   bash lib/render-prompt.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=claude-call.sh
source "$SCRIPT_DIR/claude-call.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=$((FAILED + 1)); }
pass() { echo "PASS: $*"; }

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$name"
  else
    fail "$name"
    printf '  expected: %q\n' "$expected" >&2
    printf '  actual:   %q\n' "$actual" >&2
  fi
}

# ── Test 1: literal {{KEY}} inside a value is NOT recursively substituted ──
tpl="$TMP/tpl1.md"
out="$TMP/out1.md"
cat > "$tpl" <<'EOF'
ISSUE: {{ISSUE_BODY}}
CLAUDE_MD: {{REPO_CLAUDE_MD}}
EOF

render_prompt "$tpl" "$out" \
  "ISSUE_BODY=Body contains {{REPO_CLAUDE_MD}} literal" \
  "REPO_CLAUDE_MD=should_not_be_injected"

expected="ISSUE: Body contains {{REPO_CLAUDE_MD}} literal
CLAUDE_MD: should_not_be_injected"
actual=$(cat "$out")
assert_eq "literal {{KEY}} inside value is preserved (no recursive substitution)" \
  "$expected" "$actual"

# ── Test 2: multi-line values preserve interior newlines ─────────────
tpl="$TMP/tpl2.md"
out="$TMP/out2.md"
cat > "$tpl" <<'EOF'
START
{{BODY}}
END
EOF

multi="line1
line2
line3"
render_prompt "$tpl" "$out" "BODY=$multi"

expected="START
line1
line2
line3
END"
actual=$(cat "$out")
assert_eq "multi-line values preserve newlines" "$expected" "$actual"

# ── Test 3: glob metacharacters and backslash pass through ───────────
tpl="$TMP/tpl3.md"
out="$TMP/out3.md"
cat > "$tpl" <<'EOF'
{{VAL}}
EOF

render_prompt "$tpl" "$out" 'VAL=* ? [abc] \backslash'
actual=$(cat "$out")
assert_eq "glob metacharacters & backslash preserved byte-for-byte" \
  '* ? [abc] \backslash' "$actual"

# ── Test 4: undefined placeholder is left as-is ──────────────────────
tpl="$TMP/tpl4.md"
out="$TMP/out4.md"
cat > "$tpl" <<'EOF'
{{DEFINED}} {{UNDEFINED}}
EOF

render_prompt "$tpl" "$out" "DEFINED=ok"
actual=$(cat "$out")
assert_eq "undefined placeholder is left as-is" \
  'ok {{UNDEFINED}}' "$actual"

# ── Test 5: order of key=value pairs is irrelevant ───────────────────
tpl="$TMP/tpl5.md"
out_a="$TMP/out5a.md"
out_b="$TMP/out5b.md"
cat > "$tpl" <<'EOF'
A={{A}} B={{B}}
EOF

render_prompt "$tpl" "$out_a" "A=val_a refers to {{B}}" "B=val_b"
render_prompt "$tpl" "$out_b" "B=val_b" "A=val_a refers to {{B}}"
assert_eq "result is independent of argument order" \
  "$(cat "$out_a")" "$(cat "$out_b")"

# Additionally verify the actual content for the order-independent case
assert_eq "order-independent content matches single-pass spec" \
  'A=val_a refers to {{B}} B=val_b' "$(cat "$out_a")"

# ── Test 6: empty value substitutes to empty string ──────────────────
tpl="$TMP/tpl6.md"
out="$TMP/out6.md"
cat > "$tpl" <<'EOF'
before>{{EMPTY}}<after
EOF

render_prompt "$tpl" "$out" "EMPTY="
actual=$(cat "$out")
assert_eq "empty value substitutes cleanly" 'before><after' "$actual"

# ── Summary ───────────────────────────────────────────────────────────
if [[ "$FAILED" -gt 0 ]]; then
  echo "$FAILED test(s) failed." >&2
  exit 1
fi
echo "All render_prompt tests passed."
