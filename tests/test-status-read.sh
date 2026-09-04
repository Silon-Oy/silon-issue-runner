#!/usr/bin/env bash
# test-status-read.sh — end-to-end read tests for status.sh against a synthetic
# fixture tree built in a mktemp dir with a redirected HOME, so the real
# ~/.claude (which the poller drives on the same machine) is never touched.
#
# Covers: the bulk fast path; a truncated run.json falling back to the per-file
# read with a read_errors entry and exit 3; schema_gaps for missing fields;
# idle_seconds present only for initialized runs; a 50 000-line noise
# state.jsonl read in under a second (tail, never whole-file); and a watchlist
# repo absent on disk landing in repos_absent.
#
# Run: bash tests/test-status-read.sh   (exit 0 = all pass)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# The host name comes from the SAME primitive the code under test uses.
# `hostname -s` is not portable — Windows' hostname has no -s — and issue #213
# moved the four-step fallback into runner_host for exactly that reason. A test
# that re-derives it by hand disagrees with the code on any machine where the
# short flag fails, and then reports a host mismatch that does not exist.
# shellcheck source=../lib/host.sh
. "$HERE/../lib/host.sh"
STATUS="$ROOT/status.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed"
  exit 0
fi

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got=[$2] expected=[$3]"; fi; }

FX="$(mktemp -d "${TMPDIR:-/tmp}/status-read-test.XXXXXX")"
trap 'rm -rf "$FX"' EXIT
HOST="$(runner_host)"

REPO="$FX/repo-a"
RUNS="$REPO/.claude/run-issues"
mkdir -p "$RUNS"

# run 1: completed, full schema, SKIP_CLOSED verdict in state.jsonl.
mkdir -p "$RUNS/20260601-100000-issue-1"
cat > "$RUNS/20260601-100000-issue-1/run.json" <<JSON
{"run_id":"r1","repo":"$REPO","issue_number":1,"status":"completed","started_at":"2026-06-01T10:00:00Z","finished_at":"2026-06-01T10:30:00Z","host":"$HOST","current_state":"S12_Finalize","remote":"origin","repo_slug":"repo-a","base_branch":"main","pr_url":"https://github.com/o/r/pull/7"}
JSON
printf '{"event":"pr_classified","ts":"2026-06-01T10:31:00Z","data":{"decision":"SKIP_CLOSED"}}\n' \
  > "$RUNS/20260601-100000-issue-1/state.jsonl"

# run 2: run.json missing remote/repo_slug/base_branch -> schema_gaps.
mkdir -p "$RUNS/20260601-110000-issue-2"
cat > "$RUNS/20260601-110000-issue-2/run.json" <<JSON
{"run_id":"r2","repo":"$REPO","issue_number":2,"status":"completed","started_at":"2026-06-01T11:00:00Z","finished_at":"2026-06-01T11:30:00Z","host":"$HOST","current_state":"S12_Finalize"}
JSON

# run 3: initialized, recent event -> idle_seconds present + small.
mkdir -p "$RUNS/20260811-000000-issue-3"
NOW_ISO="$(date -u +%FT%TZ)"
cat > "$RUNS/20260811-000000-issue-3/run.json" <<JSON
{"run_id":"r3","repo":"$REPO","issue_number":3,"status":"initialized","started_at":"$NOW_ISO","finished_at":null,"host":"$HOST","current_state":"S8_Implementer","remote":"origin","repo_slug":"repo-a","base_branch":"main"}
JSON
printf '{"event":"claude_started","ts":"%s","data":{}}\n' "$NOW_ISO" \
  > "$RUNS/20260811-000000-issue-3/state.jsonl"

# archive dir: counted, never scanned as a run.
mkdir -p "$REPO/.claude/run-issues-archive/old1" "$REPO/.claude/run-issues-archive/old2"

# watchlist: one present repo + one absent repo.
WL="$FX/watchlist.json"
cat > "$WL" <<JSON
{"global_max_concurrent":2,"default_labels":["auto-run"],"repos":[{"path":"$REPO","labels":["auto-run"],"remotes":["origin"]},{"path":"$FX/absent","labels":["auto-run"],"remotes":["origin"]}]}
JSON

run_status() { HOME="$FX/home" RUN_ISSUES_WATCHLIST="$WL" bash "$STATUS" "$@"; }

# ---- bulk path: clean tree, exit 0, all 3 runs read ----
OUT="$FX/out.json"
run_status --json > "$OUT"; rc=$?
check "bulk clean tree exit code" "$rc" "0"
check "run count" "$(jq '.runs | length' "$OUT")" "3"
check "schema_version" "$(jq '.schema_version' "$OUT")" "1"
check "not degraded" "$(jq '.totals.degraded' "$OUT")" "false"
check "read_errors empty" "$(jq '.read_errors | length' "$OUT")" "0"

# ---- archive counted, not scanned ----
check "archived_runs" "$(jq '.totals.archived_runs' "$OUT")" "2"

# ---- absent repo -> repos_absent + repos_scanned=1 ----
check "repos_configured" "$(jq '.sources.repos_configured' "$OUT")" "2"
check "repos_scanned" "$(jq '.sources.repos_scanned' "$OUT")" "1"
check "repos_absent count" "$(jq '.sources.repos_absent | length' "$OUT")" "1"

# ---- schema_gaps: run 2 lacks remote/repo_slug/base_branch ----
GAPS="$(jq -c '.runs[] | select(.issue_number==2) | .schema_gaps | sort' "$OUT")"
check "schema_gaps run2" "$GAPS" '["base_branch","remote","repo_slug"]'
GAPS1="$(jq -c '.runs[] | select(.issue_number==1) | .schema_gaps' "$OUT")"
check "schema_gaps run1 empty" "$GAPS1" '[]'

# ---- idle_seconds: present for initialized (run3), null otherwise ----
IDLE3="$(jq '.runs[] | select(.issue_number==3) | .idle_seconds' "$OUT")"
if [ "$IDLE3" != "null" ] && [ "$IDLE3" -ge 0 ] 2>/dev/null && [ "$IDLE3" -lt 600 ]; then
  ok "idle_seconds initialized run present + small ($IDLE3)"
else
  bad "idle_seconds initialized run: got [$IDLE3], expected a small non-null number"
fi
check "idle_seconds completed run null" \
  "$(jq '.runs[] | select(.issue_number==1) | .idle_seconds' "$OUT")" "null"
# run3 initialized + recent event, no live tmux session -> running/recent_progress.
check "run3 class" "$(jq -r '.runs[] | select(.issue_number==3) | .class' "$OUT")" "running"

# ---- two-tier fallback: truncated run.json -> read_errors + exit 3 ----
mkdir -p "$RUNS/20260601-999999-issue-9"
printf '{"run_id":"r9","status":"completed" TRUNCATED' > "$RUNS/20260601-999999-issue-9/run.json"
OUT2="$FX/out2.json"
run_status --json > "$OUT2"; rc=$?
check "truncated -> exit 3" "$rc" "3"
check "truncated -> degraded" "$(jq '.totals.degraded' "$OUT2")" "true"
check "truncated -> 1 read_error" "$(jq '.read_errors | length' "$OUT2")" "1"
check "truncated -> error kind" "$(jq -r '.read_errors[0].error' "$OUT2")" "invalid_json"
# The other 3 runs still read despite the one broken file.
check "fallback still reads good runs" "$(jq '.runs | length' "$OUT2")" "3"
rm -rf "$RUNS/20260601-999999-issue-9"

# ---- state.jsonl is read by its TAIL, never whole (CLAUDE.md 5.3) -----------
# This used to be a stopwatch: one status.sh run over a 50 000-line file had to
# finish in under three seconds. It measured the wrong thing in both directions.
# It reported a cost bug on a healthy tree under Git Bash, where starting that
# many processes exceeds three seconds by itself; and it passed a REAL whole-file
# regression on macOS, because reading 50 000 lines in a bash loop costs about a
# second — well inside the same threshold. Verified by breaking status.sh's
# `tail` on purpose: the stopwatch stayed green.
#
# So the property is asserted directly instead. Two runs with the same 50 000-line
# file differ only in WHERE the decisive pr_classified event sits:
#
#   issue 5  — the event is the LAST line          => a tail read finds it
#   issue 11 — the event is the FIRST line         => a tail read CANNOT find it
#
# A reader that takes the tail reports WAIT_CI for one and nothing for the other.
# A reader that takes the whole file reports a verdict for both, and issue 7 is
# what fails. No clock, no threshold, nothing that depends on how fast the
# machine is.
NOISE_RUN="$RUNS/20260601-120000-issue-5"
mkdir -p "$NOISE_RUN"
cat > "$NOISE_RUN/run.json" <<JSON
{"run_id":"r5","repo":"$REPO","issue_number":5,"status":"completed","started_at":"2026-06-01T12:00:00Z","finished_at":"2026-06-01T12:30:00Z","host":"$HOST","current_state":"S12_Finalize","remote":"origin","repo_slug":"repo-a","base_branch":"main"}
JSON
# 49 999 noise lines, then a final pr_classified the tail must surface.
awk 'BEGIN{for(i=0;i<49999;i++) print "{\"event\":\"pr_watch_skipped\",\"ts\":\"2026-06-01T12:00:00Z\",\"data\":{}}"}' \
  > "$NOISE_RUN/state.jsonl"
printf '{"event":"pr_classified","ts":"2026-06-01T12:31:00Z","data":{"decision":"WAIT_CI"}}\n' \
  >> "$NOISE_RUN/state.jsonl"
# The out-of-tail twin: same size, same noise, but its only pr_classified event
# is line 1 — 50 000 lines above the tail window.
BURIED_RUN="$RUNS/20260601-130000-issue-11"
mkdir -p "$BURIED_RUN"
cat > "$BURIED_RUN/run.json" <<JSON
{"run_id":"r11","repo":"$REPO","issue_number":11,"status":"completed","started_at":"2026-06-01T13:00:00Z","finished_at":"2026-06-01T13:30:00Z","host":"$HOST","current_state":"S12_Finalize","remote":"origin","repo_slug":"repo-a","base_branch":"main"}
JSON
printf '{"event":"pr_classified","ts":"2026-06-01T13:00:01Z","data":{"decision":"MERGED"}}\n' \
  > "$BURIED_RUN/state.jsonl"
awk 'BEGIN{for(i=0;i<50000;i++) print "{\"event\":\"pr_watch_skipped\",\"ts\":\"2026-06-01T13:00:00Z\",\"data\":{}}"}' \
  >> "$BURIED_RUN/state.jsonl"

OUT3="$FX/out3.json"
run_status --json > "$OUT3"; rc=$?
check "noise run exit 0" "$rc" "0"

# In the tail window -> found.
check "verdict on the last line is read" \
  "$(jq -r '.runs[] | select(.issue_number==5) | .pr_local_verdict' "$OUT3")" "WAIT_CI"

# Above the tail window -> must NOT be found. This is the assertion that fails
# when someone replaces the tail with a whole-file read.
check "verdict 50k lines above the tail is NOT read" \
  "$(jq -r '.runs[] | select(.issue_number==11) | .pr_local_verdict' "$OUT3")" "null"

# ---- foreign-host run-dir: included, is_local:false ----
mkdir -p "$RUNS/20260601-160000-issue-7"
cat > "$RUNS/20260601-160000-issue-7/run.json" <<JSON
{"run_id":"r7","repo":"$REPO","issue_number":7,"status":"completed","started_at":"2026-06-01T16:00:00Z","finished_at":"2026-06-01T16:30:00Z","host":"Some-Other-Host","current_state":"S12_Finalize","remote":"origin","repo_slug":"repo-a","base_branch":"main"}
JSON
OUT4="$FX/out4.json"
run_status --json > "$OUT4"; rc=$?
check "foreign-host included, exit 0" "$rc" "0"
check "foreign-host is_local false" \
  "$(jq -r '.runs[] | select(.issue_number==7) | .is_local' "$OUT4")" "false"
check "local run is_local true" \
  "$(jq -r '.runs[] | select(.issue_number==1) | .is_local' "$OUT4")" "true"
rm -rf "$RUNS/20260601-160000-issue-7"

# ---- empty watchlist (no repos) -> exit 2 ----
EWL="$FX/empty-watchlist.json"
printf '{"repos":[]}\n' > "$EWL"
HOME="$FX/home" RUN_ISSUES_WATCHLIST="$EWL" bash "$STATUS" --json >/dev/null 2>&1; rc=$?
check "empty watchlist -> exit 2" "$rc" "2"

# ---- missing watchlist override -> exit 2 ----
HOME="$FX/home" RUN_ISSUES_WATCHLIST="$FX/nope.json" bash "$STATUS" --json >/dev/null 2>&1; rc=$?
check "missing watchlist override -> exit 2" "$rc" "2"

echo "----------------------------------------"
echo "status-read: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
