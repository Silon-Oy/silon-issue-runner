#!/usr/bin/env bash
# test-gitignore-ensure.sh — ensure_run_issues_gitignore (lib/gitignore.sh) keeps
# the target repo's .gitignore ignoring /run-issues runtime artefacts, and is
# idempotent: a second invocation makes no change (no duplicate lines).
#
# Cases:
#   1. Missing file       -> created with the managed block (return 0)
#   2. Second run         -> no change (return 1), file byte-identical
#   3. Existing unrelated -> block appended, prior content preserved (return 0)
#   4. Stale block        -> block rewritten to current paths (return 0)
#   5. No-trailing-newline -> appended cleanly, all paths present (return 0)
#
# Run: bash tests/test-gitignore-ensure.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITIGNORE_LIB="$HERE/../lib/gitignore.sh"

# shellcheck source=lib/gitignore.sh
. "$GITIGNORE_LIB"

WORK=$(mktemp -d -t gitignore-ensure.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
PATHS=(".claude/run-issues/" ".claude/run-issues-archive/" ".claude/worktrees/")

assert_has_all_paths() {
  local file="$1" label="$2" p
  for p in "${PATHS[@]}"; do
    if ! grep -qxF -- "$p" "$file"; then
      echo "FAIL: $label — missing path '$p'"
      FAIL=1
    fi
  done
}

# ---- Case 1: missing file -> created, return 0 ----
GI="$WORK/case1/.gitignore"
mkdir -p "$WORK/case1"
if ensure_run_issues_gitignore "$GI"; then
  echo "PASS: case1 reports change (file created)"
else
  echo "FAIL: case1 should report change on creation"; FAIL=1
fi
[ -f "$GI" ] || { echo "FAIL: case1 — file not created"; FAIL=1; }
assert_has_all_paths "$GI" "case1"

# ---- Case 2: second run is a no-op (idempotent) ----
BEFORE="$(cat "$GI")"
if ensure_run_issues_gitignore "$GI"; then
  echo "FAIL: case2 should report NO change on second run"; FAIL=1
else
  echo "PASS: case2 reports no change (idempotent)"
fi
AFTER="$(cat "$GI")"
if [ "$BEFORE" = "$AFTER" ]; then
  echo "PASS: case2 file byte-identical after second run"
else
  echo "FAIL: case2 file changed on idempotent re-run"; FAIL=1
fi
# No duplicate path lines.
for p in "${PATHS[@]}"; do
  n=$(grep -cxF -- "$p" "$GI")
  if [ "$n" -ne 1 ]; then
    echo "FAIL: case2 — path '$p' appears $n times (expected 1)"; FAIL=1
  fi
done

# ---- Case 3: existing unrelated content -> block appended, preserved ----
GI3="$WORK/case3/.gitignore"
mkdir -p "$WORK/case3"
printf '%s\n' "node_modules/" "*.log" > "$GI3"
if ensure_run_issues_gitignore "$GI3"; then
  echo "PASS: case3 reports change (block appended)"
else
  echo "FAIL: case3 should report change"; FAIL=1
fi
grep -qxF -- "node_modules/" "$GI3" || { echo "FAIL: case3 — lost prior 'node_modules/'"; FAIL=1; }
grep -qxF -- "*.log" "$GI3" || { echo "FAIL: case3 — lost prior '*.log'"; FAIL=1; }
assert_has_all_paths "$GI3" "case3"

# ---- Case 4: stale block (extra/old path) -> rewritten to current set ----
GI4="$WORK/case4/.gitignore"
mkdir -p "$WORK/case4"
{
  printf '%s\n' "# >>> /run-issues orchestrator runtime state (managed — do not edit) >>>"
  printf '%s\n' ".claude/run-issues/"
  printf '%s\n' ".claude/obsolete-old-path/"
  printf '%s\n' "# <<< /run-issues orchestrator runtime state <<<"
} > "$GI4"
if ensure_run_issues_gitignore "$GI4"; then
  echo "PASS: case4 reports change (stale block rewritten)"
else
  echo "FAIL: case4 should report change on stale block"; FAIL=1
fi
assert_has_all_paths "$GI4" "case4"
if grep -qxF -- ".claude/obsolete-old-path/" "$GI4"; then
  echo "FAIL: case4 — stale path not removed"; FAIL=1
else
  echo "PASS: case4 stale path removed"
fi
# And idempotent afterwards.
if ensure_run_issues_gitignore "$GI4"; then
  echo "FAIL: case4 should be idempotent after rewrite"; FAIL=1
else
  echo "PASS: case4 idempotent after rewrite"
fi

# ---- Case 5: file without trailing newline -> clean append ----
GI5="$WORK/case5/.gitignore"
mkdir -p "$WORK/case5"
printf '%s' "dist/" > "$GI5"   # no trailing newline
if ensure_run_issues_gitignore "$GI5"; then
  echo "PASS: case5 reports change (append to newline-less file)"
else
  echo "FAIL: case5 should report change"; FAIL=1
fi
grep -qxF -- "dist/" "$GI5" || { echo "FAIL: case5 — lost prior 'dist/'"; FAIL=1; }
assert_has_all_paths "$GI5" "case5"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "gitignore-ensure: all passed" || echo "gitignore-ensure: FAILURES"
[ "$FAIL" -eq 0 ]
