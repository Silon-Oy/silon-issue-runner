#!/usr/bin/env bash
# test-readme-size.sh — gives README.md a size budget, the way
# test-claude-md-size.sh gives CLAUDE.md one.
#
# README.md grew to 129 KB for exactly one reason: nothing guarded it. CLAUDE.md
# sits at ~40 KB for exactly one reason: something does. The difference is not
# discipline -- it is which growth shows up as a test result. Without this guard,
# the one-time cleanup done by this epic's sub-issues 1 and 2 (exit-code tables
# -> docs/troubleshooting.md, the tool-specific reference -> docs/usage-reference.md)
# would silently regrow issue by issue.
#
# Cases:
#   1. README.md is within the size budget
#   2. README.md contains no exit-code tables (they belong in
#      docs/troubleshooting.md, sub-issue 1)
#   3. The files README.md delegates to actually exist -- fail-closed: a
#      dangling promise is a red test, not a skip
#
# Raising MAX_BYTES is a DECISION, not a FIX. If README legitimately needs to
# grow, that is a deliberate call about the human-facing surface -- but first move
# reference material out (exit codes -> docs/troubleshooting.md, env vars ->
# docs/env-reference.md, tool-specific detail -> docs/usage-reference.md) and
# confirm the growth is not something that belongs in one of those mirrors. Only
# then raise the number, and say why in the commit.
#
# Run: bash tests/test-readme-size.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
README="$ROOT/README.md"
FAIL=0

# README measured 81538 B after issue #268 moved the pick-mechanism reference
# (the internals of README section 6.2 -- REST rationale, label resolution,
# assignee routing, poller ordering) out to docs/usage-reference.md. The budget
# sits just above that -- ~1 KB of headroom for minor edits, not a round number
# with room for a whole section to sneak back in.
MAX_BYTES=82500
MAX_CODE_TABLES=0      # exit-code tables: docs/troubleshooting.md is the mirror

if [ ! -f "$README" ]; then
  echo "SKIP: README.md not found at repo root"
  exit 0
fi

# ---- Case 1: size budget ----
BYTES="$(wc -c < "$README" | tr -d ' ')"
if [ "$BYTES" -le "$MAX_BYTES" ]; then
  echo "PASS: README.md is $BYTES B (budget $MAX_BYTES B)"
else
  echo "FAIL: README.md is $BYTES B, over the $MAX_BYTES B budget"
  echo "      README is the human-facing surface, and it grew to 129 KB once"
  echo "      because nothing guarded it. Before raising the budget, move"
  echo "      reference material out: exit codes -> docs/troubleshooting.md,"
  echo "      env vars -> docs/env-reference.md, tool-specific detail ->"
  echo "      docs/usage-reference.md. Raising MAX_BYTES is a decision, not a fix."
  FAIL=1
fi

# ---- Case 2: exit-code tables have not crept back ----
# The header row is the fingerprint; a stray mention of a code is fine.
CODE_TABLES="$(grep -c '^| Koodi | Merkitys |' "$README")"
if [ "$CODE_TABLES" -le "$MAX_CODE_TABLES" ]; then
  echo "PASS: no exit-code tables in README.md ($CODE_TABLES found)"
else
  echo "FAIL: $CODE_TABLES exit-code table(s) in README.md"
  echo "      Source is each script's own '# Exit codes:' header;"
  echo "      docs/troubleshooting.md is the mirror that tests/test-readme.sh"
  echo "      derives and guards. README §9 is a symptom map, not a table."
  FAIL=1
fi

# ---- Case 3: delegated targets exist ----
# README points readers at these instead of carrying the material inline. A
# dangling pointer is worse than none: the reader stops looking.
for target in docs/troubleshooting.md docs/usage-reference.md docs/env-reference.md; do
  if [ -f "$ROOT/$target" ]; then
    echo "PASS: delegated target exists: $target"
  else
    echo "FAIL: README.md points at $target, which does not exist"
    FAIL=1
  fi
done

[ "$FAIL" -eq 0 ]
