#!/usr/bin/env bash
# test-scan-clean.sh — poller scan_clean selection gates, dedup, and API cost.
#
# scan_clean must emit UNIQUE "<issue> <repo>" lines only for issues that:
#   - have at least one LOCAL run-dir on THIS host (host empty = local)
#   - carry RUN_ISSUES_CLEAN_LABEL (auto-clean)
#   - do NOT carry auto-clean-skipped
# and it must dedup multiple run-dirs of the same issue into one line.
#
# Since issue #124 the label is read with ONE repo-wide `gh issue list`, not one
# `gh issue view` per local issue — the old shape cost 337 GraphQL calls per tick
# on the Studio watchlist and exhausted the shared quota. The call-count
# assertions below are the point of this file: the selection gates could stay
# green while the cost silently went back to linear, so cost is asserted
# explicitly rather than inferred.
#
# poller.sh exits at source time on non-Studio hosts, so we extract just the
# scan_clean function and run it with a MOCKED `gh`.
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

# Per-issue label fixture: $LABELDIR/<n> contains the CSV label string GitHub
# would report for that issue. It drives BOTH mocked gh paths, so the list and
# the per-issue fallback can never disagree about the same issue.
LABELDIR="$WORK/labels"; mkdir -p "$LABELDIR"

# Call ledgers. scan_clean calls gh inside a subshell, so counters must be files.
LIST_CALLS="$WORK/calls-list"; VIEW_CALLS="$WORK/calls-view"; LIST_ARGS="$WORK/args-list"
: > "$LIST_CALLS"; : > "$VIEW_CALLS"; : > "$LIST_ARGS"
reset_ledgers() { : > "$LIST_CALLS"; : > "$VIEW_CALLS"; : > "$LIST_ARGS"; }
n_list() { wc -l < "$LIST_CALLS" | tr -d ' '; }
n_view() { wc -l < "$VIEW_CALLS" | tr -d ' '; }

# Mock gh: dispatches on `issue list` vs `issue view`.
#   list — emits "<number>\t<labels-csv>" for every fixture issue carrying the
#          clean label, honouring --limit so truncation is testable.
#   view — emits the CSV for one issue (the truncation fallback path).
gh() {
  case "${1:-} ${2:-}" in
    "issue list")
      echo "call" >> "$LIST_CALLS"
      printf '%s\n' "$*" >> "$LIST_ARGS"
      local limit=0 prev="" a
      for a in "$@"; do
        [ "$prev" = "--limit" ] && limit="$a"
        prev="$a"
      done
      local emitted=0 f n csv
      for f in $(ls "$LABELDIR" | sort -n); do
        n="$f"; csv=$(cat "$LABELDIR/$n")
        case ",$csv," in *,auto-clean,*) ;; *) continue ;; esac
        [ "$limit" -gt 0 ] && [ "$emitted" -ge "$limit" ] && break
        printf '%s\t%s\n' "$n" "$csv"
        emitted=$((emitted + 1))
      done
      ;;
    "issue view")
      echo "call" >> "$VIEW_CALLS"
      local num="$3" csv=""
      [ -f "$LABELDIR/$num" ] && csv=$(cat "$LABELDIR/$num")
      printf '%s' "$csv"
      ;;
  esac
}

mk_run() {  # <issue> <host> [<suffix>] [<repo-root>]
  local n="$1" host="$2" suffix="${3:-a}" root="${4:-$REPO}"
  local rid="20260521-00${n}${suffix}-issue-$n"
  local rd="$root/.claude/run-issues/$rid"
  state_init "$rd" "$rid" "$root" "$n"
  local tmp; tmp=$(mktemp)
  jq --arg h "$host" '.host=$h' "$rd/run.json" > "$tmp"; mv "$tmp" "$rd/run.json"
  state_finalize "$rd" "completed"
}
set_labels() { printf '%s' "$2" > "$LABELDIR/$1"; }

FAIL=0
fail() { echo "FAIL: $1"; FAIL=1; }
check() { [ "$2" = "$3" ] || fail "$1 — got '$2', want '$3'"; }

# Issue 10: local + auto-clean → SELECT.
mk_run 10 "test-host"; set_labels 10 "auto-clean,bug"
# Issue 11: local, TWO run-dirs, auto-clean → SELECT once (dedup).
mk_run 11 "test-host" "a"; mk_run 11 "test-host" "b"; set_labels 11 "auto-clean"
# Issue 12: empty host (= local) + auto-clean → SELECT.
mk_run 12 ""; set_labels 12 "auto-clean"
# Issue 20: foreign host + auto-clean → SKIP.
mk_run 20 "other-host"; set_labels 20 "auto-clean"
# Issue 30: local but NO auto-clean label → SKIP.
mk_run 30 "test-host"; set_labels 30 "bug,enhancement"
# Issue 40: local + auto-clean BUT also auto-clean-skipped → SKIP.
mk_run 40 "test-host"; set_labels 40 "auto-clean,auto-clean-skipped"
# Issue 50: auto-clean but NO local run-dir → SKIP. Guards the intersection
# DIRECTION: the repo-wide list is a superset of what we may act on, and only
# issues with a local run-dir are ours to clean.
set_labels 50 "auto-clean"

# ---- Case 1: selection gates + dedup + API cost (untruncated list) ---------
reset_ledgers
OUT=$(scan_clean "$REPO" | sort)
echo "--- scan_clean output ---"; echo "$OUT"

echo "$OUT" | grep -q "^10 " || fail "issue 10 (local+labelled) not selected"
echo "$OUT" | grep -q "^11 " || fail "issue 11 (dedup) not selected"
echo "$OUT" | grep -q "^12 " || fail "issue 12 (empty host) not selected"
echo "$OUT" | grep -q "^20 " && fail "issue 20 (foreign host) WAS selected"
echo "$OUT" | grep -q "^30 " && fail "issue 30 (no label) WAS selected"
echo "$OUT" | grep -q "^40 " && fail "issue 40 (skipped) WAS selected"
echo "$OUT" | grep -q "^50 " && fail "issue 50 (labelled, no local run-dir) WAS selected"

C11=$(echo "$OUT" | grep -c "^11 ")
check "issue 11 emitted once (dedup)" "$C11" "1"
COUNT=$(printf '%s\n' "$OUT" | grep -c '^[0-9]')
check "candidate count" "$COUNT" "3"

# THE regression guard (issue #124): 6 unique local issues, ONE list call and
# ZERO per-issue views. If this goes back to 6 views the gates above still pass.
check "gh issue list calls" "$(n_list)" "1"
check "gh issue view calls" "$(n_view)" "0"

# --state all is required: a clean target is frequently already closed (PR
# merged => issue auto-closed => run-dir still on disk). --state open would drop
# those silently, and no fixture can catch it because the mock cannot model a
# state it was never asked to filter on — so assert the flag itself.
grep -q -- "--state all" "$LIST_ARGS" || fail "list call missing --state all (closed clean targets would be dropped)"
grep -q -- "--label auto-clean" "$LIST_ARGS" || fail "list call missing --label auto-clean"

# ---- Case 2: truncated list falls back to per-issue reads ------------------
# limit=1 => the list returns only issue 10 and rows >= limit, so absence is no
# longer proof. Every uncovered local issue must be resolved individually, and
# the SELECTION must be identical to case 1.
reset_ledgers
OUT2=$(RUN_ISSUES_CLEAN_SCAN_LIMIT=1 scan_clean "$REPO" 2>/dev/null | sort)
COUNT2=$(printf '%s\n' "$OUT2" | grep -c '^[0-9]')
check "truncated: candidate count unchanged" "$COUNT2" "3"
echo "$OUT2" | grep -q "^11 " || fail "truncated: issue 11 lost (fallback did not run)"
echo "$OUT2" | grep -q "^12 " || fail "truncated: issue 12 lost (fallback did not run)"
echo "$OUT2" | grep -q "^40 " && fail "truncated: issue 40 (skipped) WAS selected"
check "truncated: list calls" "$(n_list)" "1"
# Uncovered local issues are 11, 12, 30, 40 (10 came from the truncated list).
check "truncated: view calls (uncovered only)" "$(n_view)" "4"

# ---- Case 3: no local run-dirs => no network at all ------------------------
# Every run-dir belongs to another host, so there is nothing to intersect. The
# repo-wide query must NOT be issued: before #124 such a repo made zero calls,
# and the new shape must not ADD one.
FOREIGN="$WORK/foreign"; mkdir -p "$FOREIGN/.git"
mk_run 70 "other-host" "a" "$FOREIGN"
reset_ledgers
OUT3=$(scan_clean "$FOREIGN")
check "foreign-only: no output" "$OUT3" ""
check "foreign-only: list calls" "$(n_list)" "0"
check "foreign-only: view calls" "$(n_view)" "0"

# ---- Case 4: no run-dir directory at all => no network ---------------------
EMPTY="$WORK/empty"; mkdir -p "$EMPTY/.git"
reset_ledgers
OUT4=$(scan_clean "$EMPTY")
check "no run-dirs: no output" "$OUT4" ""
check "no run-dirs: list calls" "$(n_list)" "0"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "scan-clean: all passed" || echo "scan-clean: FAILURES"
[ "$FAIL" -eq 0 ]
