#!/usr/bin/env bash
# test-invariant-classes.sh — the invariant classes of the coding standard stay
# wired end to end (issue #408): principles/coding.md defines each identifier,
# cycle review names the touched ones in τ and verifies them in Ω, and
# Evolution checks them from the diff. The prompts refer to the chapter and its
# identifiers instead of copying the rules, so a dropped reference silently
# turns the guard off.
#
# The identifier set is derived from the chapter itself, fail-closed: fewer
# than six identifiers means the chapter or its format broke.
#
# Run: bash tests/test-invariant-classes.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
CODING="$ROOT/principles/coding.md"

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

chapter="$(awk '/^## Invarianttiluokat$/{on=1; next} on && /^## /{exit} on' "$CODING")"
[ -n "$chapter" ] && pass "coding.md has the Invarianttiluokat chapter" \
  || fail "coding.md lost the '## Invarianttiluokat' chapter"

ids=()
while IFS= read -r id; do
  [ -n "$id" ] && ids+=("$id")
done < <(printf '%s\n' "$chapter" | sed -n 's/^- \*\*`\([a-z-]*\)`\*\*.*/\1/p')
if [ "${#ids[@]}" -lt 6 ]; then
  fail "derived only ${#ids[@]} invariant identifiers (expected >= 6)"
else
  pass "derived ${#ids[@]} invariant identifiers"
fi
for want in allowlist-output idempotent-retry atomic-write server-state-guard external-timeout single-rule; do
  printf '%s\n' "${ids[@]}" | grep -qxF "$want" && pass "chapter defines '$want'" \
    || fail "chapter lost '$want'"
done

# Every prompt that applies the classes points at the chapter by name.
for p in prompts/01-cycle-review.md prompts/heavy-run/01-cycle-review.md \
         prompts/03-evolution.md prompts/heavy-run/03-evolution.md; do
  grep -qF 'Invarianttiluokat' "$ROOT/$p" && pass "$p refers to the chapter" \
    || fail "$p lost the Invarianttiluokat reference"
  # single-rule: the prompts refer to the rules, they do not restate them.
  for id in "${ids[@]}"; do
    grep -qF "\`$id\`" "$ROOT/$p" && fail "$p restates rule '$id' instead of referring to it"
  done
done

# Cycle review: the τ item names the invariants, Ω asks one row per invariant.
CR="$ROOT/prompts/01-cycle-review.md"
sed -n '/τ — integraatiopinnat/,/π — lähestymistapa/p' "$CR" | grep -qF 'Invarianttiluokat' \
  && pass "cycle review τ names the invariants" || fail "cycle review τ lost the invariant naming"
sed -n '/^Kirjoita lopuksi oma osionsa otsikolla/,/^## Perityt viat/p' "$CR" | grep -qF 'nimetty invariantti' \
  && pass "cycle review Ω asks a row per invariant" || fail "cycle review Ω lost the invariant row"

# The light path is a separate prompt and does not carry the check.
grep -qF 'Invarianttiluokat' "$ROOT/prompts/01-cycle-review-light.md" \
  && fail "light cycle review should not carry the invariant check" \
  || pass "light cycle review unchanged"

# Evolution: a violation is fixed or leads to NEEDS_FOLLOWUP.
for p in prompts/03-evolution.md prompts/heavy-run/03-evolution.md; do
  awk '/Invarianttiluokat/{on=1} on' "$ROOT/$p" | grep -qF 'NEEDS_FOLLOWUP' \
    && pass "$p routes a violation to NEEDS_FOLLOWUP" \
    || fail "$p does not route a violation to NEEDS_FOLLOWUP"
done

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "invariant-classes: all passed" || echo "invariant-classes: FAILURES"
[ "$FAIL" -eq 0 ]
