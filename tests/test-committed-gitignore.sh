#!/usr/bin/env bash
# test-committed-gitignore.sh — this repo IS a /run-issues target repo, so the
# orchestrator runs ensure_run_issues_gitignore against its own .gitignore on
# every run. If the committed file does not match the managed block byte for
# byte, every run reports a change and rewrites the file (dirty tree, spurious
# commits). The invariant guarded here: ensure_run_issues_gitignore must report
# "unchanged" (return 1) for the committed .gitignore.
#
# Cases:
#   1. Repo root carries a .gitignore
#   2. ensure_run_issues_gitignore on a copy -> return 1, byte-identical
#   3. Preamble keeps '.DS_Store' (outside the managed block)
#   4. Every managed .claude/ path appears exactly once (no duplicates)
#
# Run: bash tests/test-committed-gitignore.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITIGNORE_LIB="$HERE/../lib/gitignore.sh"

# shellcheck source=lib/gitignore.sh
. "$GITIGNORE_LIB"

ROOT="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$ROOT" ]; then
  echo "SKIP: not inside a git work tree"
  exit 0
fi

GI="$ROOT/.gitignore"
FAIL=0

# ---- Case 1: the file exists at the repo root ----
if [ -f "$GI" ]; then
  echo "PASS: repo root has a .gitignore"
else
  echo "FAIL: repo root has no .gitignore at $GI"
  echo "----------------------------------------"
  echo "committed-gitignore: FAILURES"
  exit 1
fi

WORK=$(mktemp -d -t committed-gitignore.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ---- Case 2: the managed block is already current (never rewritten) ----
# Operate on a copy so a mismatch cannot mutate the working tree.
COPY="$WORK/.gitignore"
cp "$GI" "$COPY"
if ensure_run_issues_gitignore "$COPY"; then
  echo "FAIL: committed .gitignore is stale — ensure_run_issues_gitignore rewrote it"
  FAIL=1
else
  echo "PASS: ensure_run_issues_gitignore reports no change"
fi
if cmp -s "$GI" "$COPY"; then
  echo "PASS: committed .gitignore is byte-identical after ensure_run_issues_gitignore"
else
  echo "FAIL: committed .gitignore differs from the managed output"
  diff -u "$GI" "$COPY" || true
  FAIL=1
fi

# ---- Case 3: preamble entries survive outside the managed block ----
if grep -qxF -- '.DS_Store' "$GI"; then
  echo "PASS: '.DS_Store' present in the preamble"
else
  echo "FAIL: '.DS_Store' missing from .gitignore"
  FAIL=1
fi

# ---- Case 4: no duplicated managed paths ----
for p in ".claude/run-issues/" ".claude/run-issues-archive/" ".claude/worktrees/"; do
  n=$(grep -cxF -- "$p" "$GI")
  if [ "$n" -eq 1 ]; then
    echo "PASS: '$p' appears exactly once"
  else
    echo "FAIL: '$p' appears $n times (expected 1)"
    FAIL=1
  fi
done

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "committed-gitignore: all passed" || echo "committed-gitignore: FAILURES"
[ "$FAIL" -eq 0 ]
