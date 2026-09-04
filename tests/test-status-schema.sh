#!/usr/bin/env bash
# test-status-schema.sh — contract guard for the status.sh --json document.
#
# Later increments (gh enrichment, an email digest, a static HTML page) consume
# this JSON, so the schema is the real interface. This test asserts the shape,
# not the values: valid JSON; every top-level key present; every run carries the
# required fields; github is ALWAYS null in local mode (gh data lives only in
# that sub-object, so a consumer cannot read a missing gh field as
# authoritative); the issue TITLE never leaks to a run's top level — it lives
# only in github.issue_title (issue #78), so with github null it is simply absent;
# totals.by_class sums to totals.runs; and every class / class_reason is a
# documented enum member.
#
# Run: bash tests/test-status-schema.sh   (exit 0 = all pass)

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
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got=[$2] expected=[$3]"; fi; }

FX="$(mktemp -d "${TMPDIR:-/tmp}/status-schema-test.XXXXXX")"
trap 'rm -rf "$FX"' EXIT
HOST="$(runner_host)"
REPO="$FX/repo-a"
RUNS="$REPO/.claude/run-issues"
mkdir -p "$RUNS"

# Plant one run per class so by_class and the enum checks exercise every branch.
# attention/blocked
mkdir -p "$RUNS/20260601-100000-issue-1"
cat > "$RUNS/20260601-100000-issue-1/run.json" <<JSON
{"run_id":"r1","repo":"$REPO","issue_number":1,"status":"blocked","started_at":"2026-06-01T10:00:00Z","finished_at":"2026-06-01T10:05:00Z","host":"$HOST","current_state":"S6_CycleReview","blocked_reason":"cycle_review_blocker","remote":"origin","repo_slug":"repo-a","base_branch":"main"}
JSON
# pr_in_flight/pr_open_waiting (completed + WAIT_CI)
mkdir -p "$RUNS/20260601-110000-issue-2"
cat > "$RUNS/20260601-110000-issue-2/run.json" <<JSON
{"run_id":"r2","repo":"$REPO","issue_number":2,"status":"completed","started_at":"2026-06-01T11:00:00Z","finished_at":"2026-06-01T11:30:00Z","host":"$HOST","current_state":"S12_Finalize","remote":"origin","repo_slug":"repo-a","base_branch":"main","pr_url":"https://github.com/o/r/pull/2"}
JSON
printf '{"event":"pr_classified","ts":"2026-06-01T11:31:00Z","data":{"decision":"WAIT_CI"}}\n' \
  > "$RUNS/20260601-110000-issue-2/state.jsonl"
# cleanup/pr_not_open (completed + SKIP_CLOSED)
mkdir -p "$RUNS/20260601-120000-issue-3"
cat > "$RUNS/20260601-120000-issue-3/run.json" <<JSON
{"run_id":"r3","repo":"$REPO","issue_number":3,"status":"completed","started_at":"2026-06-01T12:00:00Z","finished_at":"2026-06-01T12:30:00Z","host":"$HOST","current_state":"S12_Finalize","remote":"origin","repo_slug":"repo-a","base_branch":"main"}
JSON
printf '{"event":"pr_classified","ts":"2026-06-01T12:31:00Z","data":{"decision":"SKIP_CLOSED"}}\n' \
  > "$RUNS/20260601-120000-issue-3/state.jsonl"
# cleanup/lost_race
mkdir -p "$RUNS/20260601-130000-issue-4"
cat > "$RUNS/20260601-130000-issue-4/run.json" <<JSON
{"run_id":"r4","repo":"$REPO","issue_number":4,"status":"lost_race","started_at":"2026-06-01T13:00:00Z","finished_at":"2026-06-01T13:01:00Z","host":"$HOST","current_state":"S3_Claim","remote":"origin","repo_slug":"repo-a","base_branch":"main"}
JSON
# stalled/orphaned (initialized, old event, session dead)
mkdir -p "$RUNS/20260101-000000-issue-6"
cat > "$RUNS/20260101-000000-issue-6/run.json" <<JSON
{"run_id":"r6","repo":"$REPO","issue_number":6,"status":"initialized","started_at":"2026-01-01T00:00:00Z","finished_at":null,"host":"$HOST","current_state":"S8_Implementer","remote":"origin","repo_slug":"repo-a","base_branch":"main"}
JSON
printf '{"event":"claude_started","ts":"2026-01-01T00:01:00Z","data":{}}\n' \
  > "$RUNS/20260101-000000-issue-6/state.jsonl"

WL="$FX/watchlist.json"
cat > "$WL" <<JSON
{"global_max_concurrent":2,"default_labels":["auto-run"],"repos":[{"path":"$REPO","labels":["auto-run"],"remotes":["origin"]}]}
JSON

OUT="$FX/out.json"
HOME="$FX/home" RUN_ISSUES_WATCHLIST="$WL" bash "$STATUS" --json > "$OUT"; rc=$?
check "exit code clean" "$rc" "0"

# ---- valid JSON ----
if jq -e . "$OUT" >/dev/null 2>&1; then ok "output is valid JSON"; else bad "output is not valid JSON"; fi

# ---- top-level required keys ----
for k in schema_version generated_at host stale_after_seconds runner enrichment sources totals runs epics read_errors; do
  if jq -e "has(\"$k\")" "$OUT" >/dev/null 2>&1; then ok "top-level key: $k"; else bad "missing top-level key: $k"; fi
done

# ---- runner object (issue #105): present WITHOUT --github, five named fields.
# The info is local git metadata, so it is emitted in plain (local) mode too. ----
check "runner is an object" "$(jq -r '.runner | type' "$OUT")" "object"
RUNNER_MISSING="$(jq -r '
  (["version","behind_origin","pinned_version","update_state","pin_age_seconds",
    "rate_limited_until","rate_limit_backoff_seconds"]) as $req
  | ($req - (.runner | keys)) | join(",")' "$OUT")"
check "runner has all seven fields" "$RUNNER_MISSING" ""
# Rate-limit fields (issue #126) are ADDITIVE to the #105 object and, like the
# rest of it, local — present without --github. They are null unless a backoff
# deadline is actually in the future, so a stale state file from a past outage
# can never make a healthy runner look throttled.
check "runner.rate_limited_until null when healthy" \
  "$(jq -r '.runner.rate_limited_until' "$OUT")" "null"
check "runner.rate_limit_backoff_seconds null when healthy" \
  "$(jq -r '.runner.rate_limit_backoff_seconds' "$OUT")" "null"
# update_state is one of the four documented words.
BAD_STATE="$(jq -r '.runner.update_state | select(. != "up_to_date" and . != "pin_pending" and . != "behind_upstream" and . != "unknown")' "$OUT")"
check "runner.update_state in enum" "$BAD_STATE" ""

# ---- epics[] is an array, and EMPTY in local mode (issue #79). Epic membership
# is a gh-enrichment product; without --github there are no epics, exactly as
# github is null. ----
check "epics is an array" "$(jq -r '.epics | type' "$OUT")" "array"
check "epics empty in local mode" "$(jq '.epics | length' "$OUT")" "0"

# ---- every run carries the required fields ----
REQUIRED_FIELDS='["run_id","run_dir","repo_path","repo_slug","owner_repo","remote","issue_number","issue_url","host","is_local","status","blocked_reason","current_state","cycle_review_decision","started_at","finished_at","awaiting_answer_since","age_seconds","idle_seconds","retry_count","clarification_round","branch","worktree_path","worktree_exists","pr_url","pr_number","pr_local_verdict","pr_local_verdict_at","session_alive","lock_held","class","class_reason","class_confidence","schema_gaps","github"]'
MISSING="$(jq -r --argjson req "$REQUIRED_FIELDS" '
  [ .runs[] | keys as $k | ($req - $k) ] | add // [] | unique | join(",")' "$OUT")"
check "every run has all required fields" "$MISSING" ""

# ---- github is ALWAYS null in local mode ----
NON_NULL_GH="$(jq '[.runs[] | select(.github != null)] | length' "$OUT")"
check "github always null" "$NON_NULL_GH" "0"

# ---- provenance: the issue title never lands at a run's top level (issue #78).
# It lives only in github.issue_title; with github null it is simply absent. ----
TOP_TITLE="$(jq '[.runs[] | select(has("issue_title"))] | length' "$OUT")"
check "no top-level issue_title on any run" "$TOP_TITLE" "0"

# ---- provenance: issue labels never land at a run's top level (issue #106). Like
# the title, they live only in github.issue_labels; with github null they are
# absent (gh data confined to the github sub-object). ----
TOP_LABELS="$(jq '[.runs[] | select(has("issue_labels"))] | length' "$OUT")"
check "no top-level issue_labels on any run" "$TOP_LABELS" "0"

# ---- totals.by_class sums to totals.runs ----
SUM="$(jq '.totals.by_class | to_entries | map(.value) | add' "$OUT")"
RUNS_TOTAL="$(jq '.totals.runs' "$OUT")"
check "by_class sum == totals.runs" "$SUM" "$RUNS_TOTAL"
check "totals.runs == runs length" "$RUNS_TOTAL" "$(jq '.runs | length' "$OUT")"

# ---- every class is in the documented enum ----
CLASS_ENUM='["running","stalled","attention","pr_in_flight","cleanup"]'
BAD_CLASS="$(jq -r --argjson e "$CLASS_ENUM" '[.runs[] | .class | select(. as $c | ($e | index($c)) | not)] | unique | join(",")' "$OUT")"
check "all classes in enum" "$BAD_CLASS" ""

# ---- every class_reason is in the documented enum ----
REASON_ENUM='["active_session","recent_progress","wedged_session","orphaned","awaiting_review","blocked","timed_out","pr_conflicted","awaiting_clarification","pr_unlabelled","pr_open_waiting","pr_state_unknown","pr_not_open","lost_race","cancelled"]'
BAD_REASON="$(jq -r --argjson e "$REASON_ENUM" '[.runs[] | .class_reason | select(. as $c | ($e | index($c)) | not)] | unique | join(",")' "$OUT")"
check "all class_reasons in enum" "$BAD_REASON" ""

# ---- class_confidence enum ----
BAD_CONF="$(jq -r '[.runs[] | .class_confidence | select(. != "high" and . != "low")] | unique | join(",")' "$OUT")"
check "all class_confidence in {high,low}" "$BAD_CONF" ""

# ---- enrichment provenance: mode local, gh fields inert ----
check "enrichment.mode local" "$(jq -r '.enrichment.mode' "$OUT")" "local"
check "enrichment.fetched_at null" "$(jq -r '.enrichment.fetched_at' "$OUT")" "null"

# ---- schema_version stays 1 (runner is ADDITIVE, issue #105) ----
check "schema_version still 1" "$(jq -r '.schema_version' "$OUT")" "1"

# ---- runner degrades cleanly outside a git repo (issue #105, criterion 5).
# Point RUN_ISSUES_HOME at a non-git dir (with lib/ symlinked so status.sh can
# still source its libraries): the document must stay valid and complete, with
# runner.update_state "unknown" — never an empty output or a non-zero exit. ----
NONGIT="$FX/nongit"
mkdir -p "$NONGIT"
ln -s "$ROOT/lib" "$NONGIT/lib"
OUT_NG="$FX/out-nongit.json"
HOME="$FX/home" RUN_ISSUES_HOME="$NONGIT" RUN_ISSUES_WATCHLIST="$WL" \
  bash "$STATUS" --json > "$OUT_NG"; rc_ng=$?
if [ "$rc_ng" -eq 0 ] || [ "$rc_ng" -eq 3 ]; then ok "non-git run exits 0/3 ($rc_ng)"; else bad "non-git run exit=$rc_ng"; fi
if jq -e . "$OUT_NG" >/dev/null 2>&1; then ok "non-git output is valid JSON"; else bad "non-git output not valid JSON"; fi
check "non-git runner.update_state unknown" "$(jq -r '.runner.update_state' "$OUT_NG")" "unknown"
check "non-git runner.version '?'" "$(jq -r '.runner.version' "$OUT_NG")" "?"
check "non-git runner.pinned_version null" "$(jq -r '.runner.pinned_version' "$OUT_NG")" "null"
check "non-git runner.rate_limited_until null" "$(jq -r '.runner.rate_limited_until' "$OUT_NG")" "null"

echo "----------------------------------------"
echo "status-schema: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
