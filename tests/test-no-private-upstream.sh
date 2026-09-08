#!/usr/bin/env bash
# test-no-private-upstream.sh — the package's PRIVATE upstream lives at an
# org-specific owner/repo. #154 removed eight such pointers and required, as an
# acceptance criterion, that a one-off grep return zero — but left no guard, so
# the pointer regressed back into README.md three days later (commit a44fb14)
# with nothing to catch it. A reader of the PUBLISHED mirror who clones that
# pointer gets `remote: Repository not found`.
#
# This test pins that acceptance criterion permanently: the exact owner/repo
# pair must not appear anywhere in the package. Because the forbidden pointer is
# an EXACT literal, other legitimate Silon-Oy/<repo> test data (map-api,
# dotfiles, example-erp, ...) is allowed automatically — none of it forms this
# exact pair.
#
# This test WRITES NOTHING and needs no $HOME. It only reads repository files.
#
# Run: bash tests/test-no-private-upstream.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FAIL=0

# Build the forbidden needle from parts so this test file never contains the
# literal verbatim — otherwise the scan below would flag itself.
ORG="Silon-Oy"
PKG="claude-issue-runner"
FORBIDDEN="$ORG/$PKG"

# Authoritative package contents: every tracked file. Excludes .git and nested
# worktrees for free, and scans only what actually ships.
# Read into an array with a while-loop, not mapfile: mapfile is bash 4+ and the
# package still runs on macOS's bash 3.2.
FILES=()
while IFS= read -r f; do FILES+=("$f"); done < <(git -C "$ROOT" ls-files)
FILE_COUNT="${#FILES[@]}"

# FAIL-CLOSED: an empty or implausibly small file set (git unavailable, wrong
# cwd, ls-files silently returning nothing) would let the scan pass vacuously —
# the exact failure this guard exists to prevent. Require a floor and a known
# anchor before scanning, the same shape as test-skill-labels.sh's derivation.
if [ "$FILE_COUNT" -lt 20 ] || ! printf '%s\n' "${FILES[@]}" | grep -qx 'README.md'; then
  echo "FAIL: file set derivation broke — got $FILE_COUNT file(s), anchor 'README.md' missing?"
  echo "----------------------------------------"
  echo "no-private-upstream: FAILURES"
  exit 1
fi
echo "PASS: derived $FILE_COUNT tracked files (anchor README.md present)"

# -I skips binary files; -n line numbers; -H filename; -F fixed string.
HITS="$(cd "$ROOT" && grep -FInH -- "$FORBIDDEN" "${FILES[@]}" 2>/dev/null)"
if [ -n "$HITS" ]; then
  echo "FAIL: forbidden private-upstream pointer '$FORBIDDEN' present:"
  printf '%s\n' "$HITS" | sed 's/^/      /'
  FAIL=1
else
  echo "PASS: no '$FORBIDDEN' private-upstream pointer in the package"
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "no-private-upstream: all passed" || echo "no-private-upstream: FAILURES"
[ "$FAIL" -eq 0 ]
