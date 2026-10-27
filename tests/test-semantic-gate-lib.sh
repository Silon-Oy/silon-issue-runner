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

# ---- window ---------------------------------------------------------------
S="2026-10-23T10:00:00Z"
# Newest first, as git log prints them. c3 was committed before the run (a human
# pushed an old local commit) and sits between two siblings: it must not hide c1.
LOG="c4 2026-10-23T12:00:00Z${NL}c3 2026-10-22T09:00:00Z${NL}c2 2026-10-23T11:00:00Z${NL}c1 2026-10-23T10:30:00Z${NL}c0 2026-10-23T09:00:00Z"
check "window: filters, oldest first, past an older commit" "c1${NL}c2${NL}c4" \
  "$(printf '%s\n' "$LOG" | semantic_window "$S")"
check "window: the start instant is inside" "c0" \
  "$(printf 'c0 %s\n' "$S" | semantic_window "$S")"
check "window: nothing since the start" "" \
  "$(printf 'c0 2026-10-22T00:00:00Z\n' | semantic_window "$S")"
rc=0; out=$(printf 'c1 2026-10-23T11:00:00Z\nc0 2026-10-23T10:30:00Z\n' | SEMANTIC_WINDOW_MAX=2 semantic_window "$S") || rc=$?
check "window: every line inside at the cap is cut short (rc 2)" "2" "$rc"
rc=0; out=$(printf 'c1 2026-10-23T11:00:00Z\nc0 2026-10-23T10:30:00Z\n' | semantic_window "$S") || rc=$?
check "window: a short history all inside is complete (rc 0)" "0" "$rc"

# ----- listing error kinds (issue #370) ------------------------------------
check "error: 404 is permanent" permanent "$(semantic_list_error_kind 'gh: Not Found (HTTP 404)')"
check "error: 403 is permanent" permanent "$(semantic_list_error_kind 'gh: Resource not accessible by integration (HTTP 403)')"
check "error: 401 is permanent" permanent "$(semantic_list_error_kind 'gh: Bad credentials (HTTP 401)')"
check "error: 403 rate limit is transient" transient \
  "$(semantic_list_error_kind 'gh: You have exceeded a secondary rate limit. (HTTP 403)')"
check "error: 502 is transient" transient "$(semantic_list_error_kind 'gh: Bad Gateway (HTTP 502)')"
check "error: network is transient" transient "$(semantic_list_error_kind 'error connecting to api.github.com')"
check "error: empty is transient" transient "$(semantic_list_error_kind '')"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "semantic-gate-lib: all passed" || echo "semantic-gate-lib: FAILURES"
[ "$FAIL" -eq 0 ]
