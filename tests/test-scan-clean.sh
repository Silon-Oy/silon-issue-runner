#!/usr/bin/env bash
# test-scan-clean.sh — poller teardown-scan selection gates, dedup, and API cost.
#
# scan_teardown must emit UNIQUE "<issue> <repo>" lines only for issues that:
#   - have at least one LOCAL run-dir on THIS host (host empty = local)
#   - carry the verb's trigger label
#   - do NOT carry the verb's OWN skipped label
# and it must dedup multiple run-dirs of the same issue into one line.
#
# Since issue #202 there are two verbs over that one scan — scan_clean
# (auto-clean / auto-clean-skipped) and scan_reset (auto-reset /
# auto-reset-skipped). Case 5 asserts the second verb selects on its own label
# pair, does not select the first verb's issues, and costs ONE list call.
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

# scan_clean builds its REST paths with _rest_issues_path / _rest_issue_path
# (lib/issue.sh, issue #133), so that file must be loaded for the extracted
# function to run. It defines functions only, so sourcing is side-effect-free.
# shellcheck source=lib/issue.sh
. "$HERE/../lib/issue.sh"

# Extract scan_teardown + its two verb wrappers from poller.sh and source them
# (issue #202 parametrised the one scan over both teardown labels).
FN=$(awk '/^scan_teardown\(\) \{/{p=1} p{print} p&&/^scan_reset\(\)/{exit}' "$POLLER")
eval "$FN"

# Pin globals scan_clean reads.
# shellcheck disable=SC2034
THIS_HOST="test-host"
# shellcheck disable=SC2034
RUN_ISSUES_CLEAN_LABEL="auto-clean"
# shellcheck disable=SC2034
RUN_ISSUES_RESET_LABEL="auto-reset"

# Per-issue label fixture: $LABELDIR/<n> contains the CSV label string GitHub
# would report for that issue. It drives BOTH mocked gh paths, so the list and
# the per-issue fallback can never disagree about the same issue.
LABELDIR="$WORK/labels"; mkdir -p "$LABELDIR"
# Issue numbers the list mock omits, simulating rows lost past the page limit.
# Without this the truncation case could only prove the fallback runs, not that
# it RESCUES a clean target the truncated list failed to mention — which is the
# entire reason the fallback exists.
HIDDEN="$WORK/hidden"; : > "$HIDDEN"

# Call ledgers. scan_clean calls gh inside a subshell, so counters must be files.
LIST_CALLS="$WORK/calls-list"; VIEW_CALLS="$WORK/calls-view"; LIST_ARGS="$WORK/args-list"
: > "$LIST_CALLS"; : > "$VIEW_CALLS"; : > "$LIST_ARGS"
reset_ledgers() { : > "$LIST_CALLS"; : > "$VIEW_CALLS"; : > "$LIST_ARGS"; }
n_list() { wc -l < "$LIST_CALLS" | tr -d ' '; }
n_view() { wc -l < "$VIEW_CALLS" | tr -d ' '; }

# Mock gh: dispatches on the REST path (issue #133 moved both calls off the
# GraphQL search connection and onto `gh api`).
#   repos/O/R/issues?labels=…&page=N  — the repo-wide label list, paginated
#   repos/O/R/issues/<n>              — the truncation fallback, one issue
# The mock emits POST-jq output, exactly as the real gh --jq would.
gh() {
  [ "${1:-}" = "api" ] || return 0
  local path="$2"
  case "$path" in
    */issues/[0-9]*)
      echo "call" >> "$VIEW_CALLS"
      local num="${path##*/}" csv=""
      [ -f "$LABELDIR/$num" ] && csv=$(cat "$LABELDIR/$num")
      printf '%s' "$csv"
      ;;
    */issues\?*)
      echo "call" >> "$LIST_CALLS"
      printf '%s\n' "$path" >> "$LIST_ARGS"
      # Honour page= so the bounded pagination loop is exercised for real.
      local page="${path##*page=}"; page="${page%%&*}"
      case "$page" in ''|*[!0-9]*) page=1 ;; esac
      [ "$page" = "1" ] || return 0     # fixtures never fill a page
      # Honour labels= too: the same mock serves BOTH teardown verbs' scans, so
      # a reset scan can never accidentally be answered with clean's rows.
      local want="${path##*labels=}"; want="${want%%&*}"
      local f n csv
      for f in $(ls "$LABELDIR" | sort -n); do
        n="$f"; csv=$(cat "$LABELDIR/$n")
        case ",$csv," in *,"$want",*) ;; *) continue ;; esac
        grep -qx "$n" "$HIDDEN" 2>/dev/null && continue
        printf '%s\t%s\n' "$n" "$csv"
      done
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
# Issue 60: local + auto-clean, but dropped by the truncated list in case 2. It
# must still be selected there, via the per-issue fallback.
mk_run 60 "test-host"; set_labels 60 "auto-clean"

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
check "candidate count" "$COUNT" "4"

# THE regression guard (issue #124): 7 unique local issues, ONE list call and
# ZERO per-issue views. If this goes back to 6 views the gates above still pass.
check "gh issue list calls" "$(n_list)" "1"
check "gh issue view calls" "$(n_view)" "0"

# --state all is required: a clean target is frequently already closed (PR
# merged => issue auto-closed => run-dir still on disk). --state open would drop
# those silently, and no fixture can catch it because the mock cannot model a
# state it was never asked to filter on — so assert the flag itself.
grep -q -- "state=all" "$LIST_ARGS" || fail "REST call missing state=all (closed clean targets would be dropped)"
grep -q -- "labels=auto-clean" "$LIST_ARGS" || fail "REST call missing labels=auto-clean"
# The whole point of #133: this must NOT go through the search connection.
grep -q -- "issues?" "$LIST_ARGS" || fail "clean scan is not using the REST issues endpoint"

# ---- Case 2: truncated list falls back to per-issue reads ------------------
# limit=1 => the list returns only issue 10 and rows >= limit, so absence is no
# longer proof. Every uncovered local issue must be resolved individually, and
# the SELECTION must be identical to case 1.
reset_ledgers
printf '60\n' > "$HIDDEN"          # the truncated page loses issue 60
OUT2=$(RUN_ISSUES_CLEAN_SCAN_LIMIT=1 scan_clean "$REPO" 2>/dev/null | sort)
: > "$HIDDEN"
COUNT2=$(printf '%s\n' "$OUT2" | grep -c '^[0-9]')
check "truncated: candidate count unchanged" "$COUNT2" "4"
echo "$OUT2" | grep -q "^60 " \
  && ok_rescue=1 || { echo "FAIL: truncated: issue 60 lost — the fallback did not rescue a dropped clean target"; FAIL=1; }
echo "$OUT2" | grep -q "^11 " || fail "truncated: issue 11 lost (fallback did not run)"
echo "$OUT2" | grep -q "^12 " || fail "truncated: issue 12 lost (fallback did not run)"
echo "$OUT2" | grep -q "^40 " && fail "truncated: issue 40 (skipped) WAS selected"
check "truncated: list calls" "$(n_list)" "1"
# Only issues the list did not mention are read individually: 30 (unlabelled, so
# never listed) and 60 (dropped by the truncated page). Everything else came from
# the list, so the fallback stays proportional to what was actually missing.
check "truncated: view calls (uncovered only)" "$(n_view)" "2"

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

# --- reset-verb fixtures (issue #202) --------------------------------------
# Issue 80: local + auto-reset → selected by scan_reset, NOT by scan_clean.
mk_run 80 "test-host"; set_labels 80 "auto-reset"
# Issue 81: local + auto-reset BUT also auto-reset-skipped → SKIP.
mk_run 81 "test-host"; set_labels 81 "auto-reset,auto-reset-skipped"
# Issue 82: local + auto-reset but carrying the OTHER verb's skipped label. The
# two loop guards are deliberately separate, so auto-clean-skipped must NOT
# suppress a reset — that is the whole reason they are distinct labels.
mk_run 82 "test-host"; set_labels 82 "auto-reset,auto-clean-skipped"
# The fixtures are created HERE, after the clean cases, so their call-count
# assertions keep asserting the numbers they were written for.

# ---- Case 5: the reset verb selects on its OWN label pair ------------------
# Same scan (scan_teardown), a different label pair. Two things are asserted that
# the clean cases cannot reach: that the verbs do not select each other's issues,
# and that the second verb costs ONE list call per repo — not a second scan
# shape (CLAUDE.md §5.4).
reset_ledgers
OUTR=$(scan_reset "$REPO" | sort)
echo "--- scan_reset output ---"; echo "$OUTR"
echo "$OUTR" | grep -q "^80 " || fail "reset: issue 80 (local+auto-reset) not selected"
echo "$OUTR" | grep -q "^81 " && fail "reset: issue 81 (auto-reset-skipped) WAS selected"
echo "$OUTR" | grep -q "^82 " || fail "reset: issue 82 suppressed by the OTHER verb's skipped label"
echo "$OUTR" | grep -q "^10 " && fail "reset: issue 10 (auto-clean) WAS selected by the reset scan"
COUNTR=$(printf '%s\n' "$OUTR" | grep -c '^[0-9]')
check "reset: candidate count" "$COUNTR" "2"
check "reset: list calls" "$(n_list)" "1"
check "reset: view calls" "$(n_view)" "0"
grep -q -- "labels=auto-reset" "$LIST_ARGS" || fail "reset scan did not query labels=auto-reset"
grep -q -- "state=all" "$LIST_ARGS" || fail "reset scan missing state=all"

# And the clean scan must be unchanged by the reset fixtures: an auto-reset issue
# is not a clean target.
reset_ledgers
OUTC=$(scan_clean "$REPO" | sort)
echo "$OUTC" | grep -q "^80 " && fail "clean: issue 80 (auto-reset) WAS selected by the clean scan"
check "clean: candidate count unchanged by reset fixtures" "$(printf '%s\n' "$OUTC" | grep -c '^[0-9]')" "4"

# ---- Case 4: no run-dir directory at all => no network ---------------------
EMPTY="$WORK/empty"; mkdir -p "$EMPTY/.git"
reset_ledgers
OUT4=$(scan_clean "$EMPTY")
check "no run-dirs: no output" "$OUT4" ""
check "no run-dirs: list calls" "$(n_list)" "0"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "scan-clean: all passed" || echo "scan-clean: FAILURES"
[ "$FAIL" -eq 0 ]
