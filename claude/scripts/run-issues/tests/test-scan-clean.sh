#!/usr/bin/env bash
# test-scan-clean.sh — poller scan_clean selection gates + dedup.
#
# scan_clean must emit UNIQUE "<issue> <repo>" lines only for issues that:
#   - have at least one LOCAL run-dir on THIS host (host empty = local)
#   - carry RUN_ISSUES_CLEAN_LABEL (auto-clean)
#   - do NOT carry auto-clean-skipped
# and it must dedup multiple run-dirs of the same issue into one line.
#
# poller.sh exits at source time on non-Studio hosts, so we extract just the
# scan_clean function and run it with a MOCKED `gh issue view --json labels`.
#
# Run: bash tests/test-scan-clean.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLLER="$HERE/../poller.sh"
STATE_LIB="$HERE/../lib/state.sh"

WORK=$(mktemp -d -t scan-clean.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
mkdir -p "$REPO/.git"

# shellcheck source=lib/state.sh
. "$STATE_LIB"

# Extract scan_clean from poller.sh and source it.
FN=$(awk '/^scan_clean\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$POLLER")
eval "$FN"

# Pin globals scan_clean reads.
# shellcheck disable=SC2034
THIS_HOST="test-host"
# shellcheck disable=SC2034
RUN_ISSUES_CLEAN_LABEL="auto-clean"

# Per-issue label fixture: $LABELDIR/<n> contains the CSV label string the
# mocked `gh issue view` should return for that issue.
LABELDIR="$WORK/labels"; mkdir -p "$LABELDIR"

# Mock gh: only handles `issue view <n> --json labels --jq ...`. We cd into the
# repo in scan_clean before calling gh, so $1=issue is positional after `view`.
gh() {
  # args: issue view <n> --json labels --jq '...'
  local n="$3"
  local csv=""
  [ -f "$LABELDIR/$n" ] && csv=$(cat "$LABELDIR/$n")
  printf '%s' "$csv"
}

mk_run() {  # <issue> <host> [<suffix>]
  local n="$1" host="$2" suffix="${3:-a}"
  local rid="20260521-00${n}${suffix}-issue-$n"
  local rd="$REPO/.claude/run-issues/$rid"
  state_init "$rd" "$rid" "$REPO" "$n"
  local tmp; tmp=$(mktemp)
  jq --arg h "$host" '.host=$h' "$rd/run.json" > "$tmp"; mv "$tmp" "$rd/run.json"
  state_finalize "$rd" "completed"
}
set_labels() { printf '%s' "$2" > "$LABELDIR/$1"; }

# Issue 10: local + auto-clean → SELECT.
mk_run 10 "test-host"; set_labels 10 "auto-clean,bug"
# Issue 11: local, TWO run-dirs, auto-clean → SELECT once (dedup).
mk_run 11 "test-host" "a"; mk_run 11 "test-host" "b"; set_labels 11 "auto-clean"
# Issue 12: empty host (= local) + auto-clean → SELECT.
mk_run 12 ""; set_labels 12 "auto-clean"
# Issue 20: foreign host + auto-clean → SKIP (no local run-dir → no gh call).
mk_run 20 "other-host"; set_labels 20 "auto-clean"
# Issue 30: local but NO auto-clean label → SKIP.
mk_run 30 "test-host"; set_labels 30 "bug,enhancement"
# Issue 40: local + auto-clean BUT also auto-clean-skipped → SKIP.
mk_run 40 "test-host"; set_labels 40 "auto-clean,auto-clean-skipped"

OUT=$(scan_clean "$REPO" | sort)
echo "--- scan_clean output ---"; echo "$OUT"

FAIL=0
echo "$OUT" | grep -q "^10 " || { echo "FAIL: issue 10 (local+labelled) not selected"; FAIL=1; }
echo "$OUT" | grep -q "^11 " || { echo "FAIL: issue 11 (dedup) not selected"; FAIL=1; }
echo "$OUT" | grep -q "^12 " || { echo "FAIL: issue 12 (empty host) not selected"; FAIL=1; }
echo "$OUT" | grep -q "^20 " && { echo "FAIL: issue 20 (foreign host) WAS selected"; FAIL=1; }
echo "$OUT" | grep -q "^30 " && { echo "FAIL: issue 30 (no label) WAS selected"; FAIL=1; }
echo "$OUT" | grep -q "^40 " && { echo "FAIL: issue 40 (skipped) WAS selected"; FAIL=1; }

# Dedup: issue 11 must appear exactly once.
C11=$(echo "$OUT" | grep -c "^11 ")
[ "$C11" = "1" ] || { echo "FAIL: issue 11 emitted $C11 times, want 1 (dedup)"; FAIL=1; }

COUNT=$(printf '%s\n' "$OUT" | grep -c '^[0-9]')
[ "$COUNT" = "3" ] || { echo "FAIL: expected exactly 3 candidates, got $COUNT"; FAIL=1; }

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "scan-clean: all passed" || echo "scan-clean: FAILURES"
[ "$FAIL" -eq 0 ]
