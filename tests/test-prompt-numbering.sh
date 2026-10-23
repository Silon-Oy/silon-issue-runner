#!/usr/bin/env bash
# test-prompt-numbering.sh — every numbered prompt (prompts/NN-*.md) has a number
# of its own (issue #370). Two runs written in parallel once both took 09, and a
# shared number makes the step id ambiguous: lib/claude-call.sh maps step ids to
# phases by prefix.
#
# One deliberate exception: a VARIANT of a step keeps the step's number, its
# name being the step's whole name plus a `-` suffix (01-cycle-review-light of
# 01-cycle-review). _claude_step_phase orders its prefix patterns for exactly
# that pair, and renumbering it would rename the LIGHT_REVIEW step id.
#
# The set is derived from disk, fail-closed: fewer than five numbered prompts
# means the glob or the layout broke, not that there is nothing to check.
#
# Run: bash tests/test-prompt-numbering.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPTS="$HERE/../prompts"

FAIL=0
bad() { echo "FAIL: $1"; FAIL=1; }

names=()
for f in "$PROMPTS"/[0-9][0-9]-*.md; do
  [ -f "$f" ] || continue
  names+=("$(basename "$f" .md)")
done
if [ "${#names[@]}" -lt 5 ]; then
  bad "only ${#names[@]} numbered prompt(s) under $PROMPTS — the set is derived wrong"
fi

# is_variant <rest-a> <rest-b> — a is b plus a `-` suffix, or the other way round.
is_variant() {
  case "$1" in "$2"-*) return 0 ;; esac
  case "$2" in "$1"-*) return 0 ;; esac
  return 1
}

i=0
while [ "$i" -lt "${#names[@]}" ]; do
  a="${names[$i]}"
  j=$((i + 1))
  while [ "$j" -lt "${#names[@]}" ]; do
    b="${names[$j]}"
    if [ "${a%%-*}" = "${b%%-*}" ] && ! is_variant "${a#*-}" "${b#*-}"; then
      bad "prompts $a.md and $b.md share the number ${a%%-*}"
    fi
    j=$((j + 1))
  done
  i=$((i + 1))
done

echo "----------------------------------------"
if [ "$FAIL" -eq 0 ]; then
  echo "prompt-numbering: all passed (${#names[@]} numbered prompts)"
else
  echo "prompt-numbering: FAILURES"
fi
[ "$FAIL" -eq 0 ]
