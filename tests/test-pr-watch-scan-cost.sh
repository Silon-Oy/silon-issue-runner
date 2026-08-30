#!/usr/bin/env bash
# test-pr-watch-scan-cost.sh — pr-watch scan_candidates cost gate (issue #130).
#
# scan_candidates walks every local run-dir and emits "<pr> <run-id>" lines for
# runs watch_one should fetch and re-classify. Before #130 it emitted EVERY
# completed run with a pr_url — including PRs closed/merged months ago. Since a
# SKIP_CLOSED classification requires a `gh pr view` BEFORE the decision, each
# such run cost one GraphQL call per tick forever (measured 798 fetches/h on the
# Studio watchlist, ~all of them re-checking already-closed PRs).
#
# This is the same fault class as #124 (scan_clean) and #125 (status detail):
# cost O(historical run-dirs) instead of O(work). The fix reads finality from
# LOCAL state — the last recorded pr_classified decision in state.jsonl's tail,
# via pr_last_decision (the reader #65 built) — and does NOT emit a run whose
# last decision was SKIP_CLOSED, so watch_one never fetches it.
#
# scan_candidates itself makes ZERO gh calls (the fetch is downstream in
# watch_one), so "not emitted" == "not fetched". The gh mock here therefore both
# proves scan_candidates stays network-free AND lets the assertions read as a
# call-count guard in the spirit of tests/test-scan-clean.sh: a SKIP_CLOSED run
# yields zero downstream fetches precisely because it is filtered out here.
#
# pr-watch.sh exits/does real work at source time, so we extract just the three
# functions scan_candidates needs (run_field, pr_number_from_url, itself) and run
# them with a mocked gh and controlled globals — the same extraction pattern as
# tests/test-scan-clean.sh.
#
# Run: bash tests/test-pr-watch-scan-cost.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_WATCH="$HERE/../pr-watch.sh"
STATE_LIB="$HERE/../lib/state.sh"
PR_WATCH_LIB="$HERE/../lib/pr-watch-lib.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed"
  exit 0
fi

WORK=$(mktemp -d -t pr-watch-scan-cost.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
mkdir -p "$REPO/.git"

# shellcheck source=lib/state.sh
. "$STATE_LIB"
# pr_last_decision + PR_LAST_DECISION_TAIL live here; the file defines functions
# only, so sourcing is side-effect-free.
# shellcheck source=lib/pr-watch-lib.sh
. "$PR_WATCH_LIB"

# Extract the three functions scan_candidates depends on from pr-watch.sh.
for fn in run_field pr_number_from_url scan_candidates; do
  body=$(awk -v f="^$fn\\\\(\\\\) \\\\{" '$0 ~ f {p=1} p{print} p&&/^\}/{exit}' "$PR_WATCH")
  [ -n "$body" ] || { echo "FAIL: could not extract $fn from pr-watch.sh"; exit 1; }
  eval "$body"
done

# Globals scan_candidates reads.
# shellcheck disable=SC2034
RUNS_DIR="$REPO/.claude/run-issues"
# shellcheck disable=SC2034
THIS_HOST="test-host"
# shellcheck disable=SC2034
REMOTE_FILTER=""

# gh call ledger. scan_candidates must make ZERO gh calls; the mock counts any.
GH_CALLS="$WORK/gh-calls"; : > "$GH_CALLS"
n_gh() { wc -l < "$GH_CALLS" | tr -d ' '; }
gh() { echo "call" >> "$GH_CALLS"; return 0; }

# mk_run <issue> <pr-num> <status> [<blocked-reason>] [<last-decision>]
# Creates a run-dir on THIS host with a pr_url, finalizes it to <status> (with an
# optional blocked reason), and — if a last decision is given — records it as the
# most recent pr_classified event, exactly the shape pr_last_decision reads.
mk_run() {
  local issue="$1" pr="$2" status="$3" reason="${4:-}" decision="${5:-}"
  local rid="20260829-00${pr}-issue-$issue"
  local rd="$RUNS_DIR/$rid"
  state_init "$rd" "$rid" "$REPO" "$issue"
  local tmp; tmp=$(mktemp)
  jq --arg h "test-host" --arg u "https://github.com/o/r/pull/$pr" \
    '.host=$h | .pr_url=$u' "$rd/run.json" > "$tmp"; mv "$tmp" "$rd/run.json"
  if [ -n "$reason" ]; then
    state_finalize "$rd" "$status" "$reason"
  else
    state_finalize "$rd" "$status"
  fi
  # Record earlier live decisions before the final one so pr_last_decision must
  # actually read the TAIL's LAST entry, not merely find any pr_classified.
  if [ -n "$decision" ]; then
    state_event "$rd" "pr_classified" "pr=$pr" "decision=MERGE"
    state_event "$rd" "pr_classified" "pr=$pr" "decision=$decision"
  fi
  printf '%s' "$rid"
}

FAIL=0
fail() { echo "FAIL: $1"; FAIL=1; }
check() { [ "$2" = "$3" ] || fail "$1 — got '$2', want '$3'"; }
emitted() { printf '%s\n' "$1" | grep -q " $2\$"; }

# ---- Fixtures --------------------------------------------------------------
# 100: completed, last decision SKIP_CLOSED  -> FILTERED (the whole point).
RID_CLOSED=$(mk_run 100 100 completed "" SKIP_CLOSED)
# 101: a SECOND permanently-closed run, to prove the filter scales (N -> 0).
RID_CLOSED2=$(mk_run 101 101 completed "" SKIP_CLOSED)
# 200: completed, last decision SKIP_NO_LABEL -> EMITTED (label may appear).
RID_NOLABEL=$(mk_run 200 200 completed "" SKIP_NO_LABEL)
# 300: completed, last decision MERGE (an open, mergeable PR) -> EMITTED.
RID_OPEN=$(mk_run 300 300 completed "" MERGE)
# 400: completed, NO recorded decision (legacy run) -> EMITTED once, converges.
RID_LEGACY=$(mk_run 400 400 completed "")
# 500: blocked/ci_repair_failed_pr_500, last decision SKIP_CLOSED -> EMITTED.
#      #45 re-arm path must NOT be caught by the new completed-branch filter,
#      even when a stale SKIP_CLOSED decision sits in its state.jsonl.
RID_CIREPAIR=$(mk_run 500 500 blocked "ci_repair_failed_pr_500" SKIP_CLOSED)
# 600: blocked with some other reason -> still filtered as before (#45-narrow).
RID_OTHERBLOCK=$(mk_run 600 600 blocked "stalled_in_S8" "")

OUT=$(scan_candidates)
echo "--- scan_candidates output ---"; echo "$OUT"

# AC: N SKIP_CLOSED runs => zero downstream fetches. They are not emitted, so
# watch_one never runs, so no gh pr view is ever issued for them.
emitted "$OUT" "$RID_CLOSED"  && fail "SKIP_CLOSED run #100 was emitted (would be re-fetched every tick)"
emitted "$OUT" "$RID_CLOSED2" && fail "SKIP_CLOSED run #101 was emitted"

# AC: open PR is fetched and handled normally.
emitted "$OUT" "$RID_OPEN"    || fail "open PR run #300 (MERGE) was NOT emitted"

# AC: SKIP_NO_LABEL is not filtered permanently — the label can still appear.
emitted "$OUT" "$RID_NOLABEL" || fail "SKIP_NO_LABEL run #200 was NOT emitted (label may appear)"

# AC: #45 ci_repair_failed re-arm path still emits, even with a stale SKIP_CLOSED.
emitted "$OUT" "$RID_CIREPAIR" || fail "ci_repair_failed run #500 was NOT emitted (#45 regression)"

# Edge: legacy run with no recorded decision is emitted (fail-open) and converges
# on the next tick once its first classification is written.
emitted "$OUT" "$RID_LEGACY"  || fail "legacy run #400 (no decision) was NOT emitted"

# Non-ci_repair blocked stays out of scan exactly as before the change.
emitted "$OUT" "$RID_OTHERBLOCK" && fail "blocked/stalled run #600 was emitted (should stay out)"

# THE cost guard: scan_candidates must make ZERO gh calls. Finality is read from
# local state only — if this goes non-zero the fix costs what it saves.
check "gh calls from scan_candidates" "$(n_gh)" "0"

# ---- Fail-closed: unreadable state.jsonl => emit (decision 5) ---------------
# A completed run whose state.jsonl is corrupt/unreadable must be emitted (behave
# as before): pr_last_decision returns empty, empty != SKIP_CLOSED.
RID_CORRUPT=$(mk_run 700 700 completed "" SKIP_CLOSED)
printf 'not json at all\n{bad' > "$RUNS_DIR/$RID_CORRUPT/state.jsonl"
OUT2=$(scan_candidates)
emitted "$OUT2" "$RID_CORRUPT" || fail "run with unreadable state.jsonl was NOT emitted (fail-closed violated)"

# ---- Fail-closed: missing state.jsonl => emit ------------------------------
RID_NOFILE=$(mk_run 800 800 completed "" SKIP_CLOSED)
rm -f "$RUNS_DIR/$RID_NOFILE/state.jsonl"
OUT3=$(scan_candidates)
emitted "$OUT3" "$RID_NOFILE" || fail "run with missing state.jsonl was NOT emitted (fail-closed violated)"

if [ "$FAIL" -eq 0 ]; then
  echo "PASS: scan_candidates filters permanently-closed runs, preserves #45 + fail-closed"
fi
[ "$FAIL" -eq 0 ]
