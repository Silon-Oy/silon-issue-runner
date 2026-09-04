#!/usr/bin/env bash
# test-claude-md-size.sh — keeps CLAUDE.md a context budget, not a reference manual.
#
# CLAUDE.md is loaded into EVERY agent session in this repo, so its size is a
# per-session tax that no other file pays. It grew 16.6 KB -> 128 KB in one
# month (2026-07-31 .. 2026-08-31, 7.7x) because the post-commit doc agent only
# ever appended: every issue added its own rationale and nothing pruned. At
# 128 KB it cost ~34k tokens per session.
#
# The regrowth is silent — no test guarded the file's content, and the biggest
# copy was also the least authoritative one (exit codes and env vars are derived
# from the scripts by test-readme.sh, so CLAUDE.md was a third, unguarded copy).
# This test makes the drift loud instead.
#
# Cases:
#   1. CLAUDE.md is within the size budget
#   2. The files CLAUDE.md delegates to actually exist
#   3. Exit-code tables have not crept back in (they belong in
#      docs/troubleshooting.md)
#   4. Env-var tables have not crept back in (they belong in docs/env-reference.md)
#
# Raising MAX_BYTES is a decision, not a fix: if the file legitimately needs to
# grow, something else in it has become stale and should go first.
#
# Run: bash tests/test-claude-md-size.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLAUDE_MD="$ROOT/CLAUDE.md"
FAIL=0

MAX_BYTES=40000        # ~10k tokens; the file sat at 29 KB after the 2026-09-01 compaction
MAX_CODE_TABLES=0      # exit-code tables: docs/troubleshooting.md is the mirror
MAX_ENV_TABLES=0       # env-var tables: docs/env-reference.md is the mirror

if [ ! -f "$CLAUDE_MD" ]; then
  echo "FAIL: CLAUDE.md missing at repo root"
  exit 1
fi

# ---- Case 1: size budget ----
BYTES="$(wc -c < "$CLAUDE_MD" | tr -d ' ')"
if [ "$BYTES" -le "$MAX_BYTES" ]; then
  echo "PASS: CLAUDE.md is $BYTES B (budget $MAX_BYTES B)"
else
  echo "FAIL: CLAUDE.md is $BYTES B, over the $MAX_BYTES B budget"
  echo "      It is loaded into every session. Before raising the budget, move"
  echo "      reference material out: exit codes -> docs/troubleshooting.md,"
  echo "      env vars -> docs/env-reference.md, per-issue rationale -> the"
  echo "      issue's PR."
  FAIL=1
fi

# ---- Case 2: delegated targets exist ----
# CLAUDE.md §0 promises these files. A dangling promise is worse than no
# promise: the agent stops looking instead of reading the code.
for target in README.md docs/env-reference.md docs/design-history.md \
               docs/epic-orchestration.md docs/troubleshooting.md; do
  if grep -q "$(basename "$target")" "$CLAUDE_MD"; then
    if [ -f "$ROOT/$target" ]; then
      echo "PASS: delegated target exists: $target"
    else
      echo "FAIL: CLAUDE.md points at $target, which does not exist"; FAIL=1
    fi
  fi
done

# ---- Case 3: exit-code tables have not crept back ----
# The header row is the fingerprint; a stray mention of a code is fine.
CODE_TABLES="$(grep -c '^| Koodi | Merkitys |' "$CLAUDE_MD")"
if [ "$CODE_TABLES" -le "$MAX_CODE_TABLES" ]; then
  echo "PASS: no exit-code tables in CLAUDE.md ($CODE_TABLES found)"
else
  echo "FAIL: $CODE_TABLES exit-code table(s) in CLAUDE.md"
  echo "      Source is the script's own '# Exit codes:' header;"
  echo "      docs/troubleshooting.md is the mirror that tests/test-readme.sh"
  echo "      derives and guards. A third copy drifts."
  FAIL=1
fi

# ---- Case 4: env-var tables have not crept back ----
ENV_TABLES="$(grep -c '^| Muuttuja | Oletus | Vaikutus |' "$CLAUDE_MD")"
if [ "$ENV_TABLES" -le "$MAX_ENV_TABLES" ]; then
  echo "PASS: no env-var tables in CLAUDE.md ($ENV_TABLES found)"
else
  echo "FAIL: $ENV_TABLES env-var table(s) in CLAUDE.md"
  echo "      Source is the code's \${VAR:-default} and the script's '# Env:' header;"
  echo "      docs/env-reference.md is the mirror. Keep rules here, not listings."
  FAIL=1
fi

[ "$FAIL" -eq 0 ]
