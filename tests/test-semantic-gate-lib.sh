#!/usr/bin/env bash
# test-semantic-gate-lib.sh — the semantic gate's pure parts
# (lib/semantic-gate.sh, issue #341): directory sets and their overlap, the
# merged-sibling filter of a REST closed-PR listing, and the attribution of the
# base's first-parent commits to sibling PRs.
#
# Run: bash tests/test-semantic-gate-lib.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available"
  exit 0
fi

# shellcheck source=../lib/semantic-gate.sh
. "$HERE/../lib/semantic-gate.sh"

FAIL=0
check() { # <name> <want> <got>
  if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 — want '$2', got '$3'"; FAIL=1; fi
}
NL=$'\n'
TAB=$'\t'

# ----- directories ---------------------------------------------------------
check "dirs: root file is ." "." "$(printf 'README.md\n' | semantic_dirs_of)"
check "dirs: sorted, unique, nested" "lib${NL}lib/sub${NL}tests" \
  "$(printf 'tests/t.sh\nlib/a.sh\nlib/sub/b.sh\nlib/c.sh\n\n' | semantic_dirs_of)"
check "dirs: empty input" "" "$(printf '' | semantic_dirs_of)"

check "overlap: shared dirs" "." "$(semantic_dirs_overlap ".${NL}lib" ".${NL}docs")"
check "overlap: none" "" "$(semantic_dirs_overlap "lib" "docs")"
check "overlap: parent is not child" "" "$(semantic_dirs_overlap "lib" "lib/sub")"
check "overlap: empty side" "" "$(semantic_dirs_overlap "" "lib")"

# ----- merged siblings -----------------------------------------------------
PULLS='[
  {"number":55,"merged_at":"2026-07-01T00:00:00Z","merge_commit_sha":"s55","head":{"ref":"auto-run/me"}},
  {"number":56,"merged_at":"2026-07-01T00:00:00Z","merge_commit_sha":"s56","head":{"ref":"auto-run/a"}},
  {"number":57,"merged_at":null,"merge_commit_sha":"s57","head":{"ref":"auto-run/closed"}},
  {"number":58,"merged_at":"2026-07-01T00:00:00Z","merge_commit_sha":"s58","head":{"ref":"feature/human"}},
  {"number":59,"merged_at":"2026-07-01T00:00:00Z","merge_commit_sha":null,"head":{"ref":"auto-run/nosha"}}
]'
check "siblings: merged runner PRs other than this one" "56${TAB}auto-run/a${TAB}s56" \
  "$(semantic_merged_siblings "$PULLS" 55)"
check "siblings: empty listing" "" "$(semantic_merged_siblings '[]' 55)"
semantic_merged_siblings '{"message":"Bad credentials"}' 55 >/dev/null; rc=$?
check "siblings: non-array listing is an error, not 'none'" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
semantic_merged_siblings 'not json' 55 >/dev/null; rc=$?
check "siblings: unparseable listing is an error" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

# ----- spans -----------------------------------------------------------------
# Base window: boundary b0, then c1 c2 (sibling 61 rebase-merged as two commits,
# tip c2), h3 (a human commit), c4 (sibling 62), c5 (nobody's).
RANGE="b0${NL}c1${NL}c2${NL}h3${NL}c4${NL}c5"
SIBS="61${TAB}auto-run/x${TAB}c2${NL}62${TAB}auto-run/y${TAB}c4${NL}63${TAB}auto-run/z${TAB}elsewhere"
check "spans: multi-commit sibling, then the next from its tip" \
  "61${TAB}auto-run/x${TAB}b0${TAB}c2${NL}62${TAB}auto-run/y${TAB}c2${TAB}c4" \
  "$(semantic_sibling_spans "$RANGE" "$SIBS")"
check "spans: sibling outside the window ignored" "" \
  "$(semantic_sibling_spans "b0${NL}c1" "63${TAB}auto-run/z${TAB}elsewhere")"
check "spans: empty siblings" "" "$(semantic_sibling_spans "$RANGE" "")"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "semantic-gate-lib: all passed" || echo "semantic-gate-lib: FAILURES"
[ "$FAIL" -eq 0 ]
