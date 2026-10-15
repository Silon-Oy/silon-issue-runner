#!/usr/bin/env bash
# test-heavy-run.sh — the heavy-run path (issue #313).
#
# A heavy-run bug must not be fixed before its cause is confirmed: the
# implementer runs the cycle review's diagnostic experiment first, records the
# raw result and prints a DIAGNOSIS_RESULT line, and the orchestrator stops the
# run for a human unless exactly one hypothesis was confirmed. Every heavy-run
# PR — bug or not — is withheld from auto-merge and labelled manual-merge.
#
# Same harness as test-pr-label-propagation.sh: orchestrate.sh in resume mode
# (PROCEED) jumps straight to Phase B; claude, git and gh are PATH shims.
#
# Cases:
#   (u) issue_run_path: heavy / light / standard, heavy wins over light
#   (a) heavy bug, CONFIRMED + raw record  -> PR, manual-merge not auto-merge,
#       diagnosis in the PR body, run_path + confirmed_hypothesis in run.json
#   (b) heavy bug, REFUTED                 -> blocked diagnosis_unconfirmed,
#       exit 5, needs-human, no PR
#   (c) heavy, no HEAVY_RUN_KIND, no result line -> fail-closed as a bug: blocked
#   (d) heavy bug, CONFIRMED but no raw record   -> blocked
#   (e) heavy NOT_BUG                      -> PR without the gate, manual-merge
#   (f) standard issue                     -> auto-merge propagated, no sections
#
# Run: bash tests/test-heavy-run.sh   (exit 0 = all pass)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$HERE/../orchestrate.sh"
STATE_LIB="$HERE/../lib/state.sh"
ISSUE_LIB="$HERE/../lib/issue.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

WORK=$(mktemp -d -t heavy-run.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
git -C "$WORK" init -q "repo"
WORKTREE="$WORK/worktree"
mkdir -p "$WORKTREE"

BIN="$WORK/bin"
mkdir -p "$BIN"
GH_LOG="$WORK/gh-calls.log"

cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"
if [ "\$1" = "pr" ] && [ "\$2" = "create" ]; then
  echo "https://github.com/acme/widgets/pull/42"
fi
exit 0
SH
chmod +x "$BIN/gh"

cat > "$BIN/git" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$BIN/git"

# claude mock: MOCK_DIAG (when set) becomes the DIAGNOSIS_RESULT line, and
# MOCK_DIAG_RAW (when set) is written to MOCK_DIAG_FILE as the raw record.
cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
if [ -n "${MOCK_DIAG_RAW:-}" ] && [ -n "${MOCK_DIAG_FILE:-}" ]; then
  printf '%s\n' "$MOCK_DIAG_RAW" > "$MOCK_DIAG_FILE"
fi
[ -n "${MOCK_DIAG:-}" ] && echo "DIAGNOSIS_RESULT: $MOCK_DIAG"
echo "IMPLEMENTER_RESULT: SUCCESS"
echo "EVOLUTION_RESULT: CLEAN"
SH
chmod +x "$BIN/claude"

# shellcheck source=lib/state.sh
. "$STATE_LIB"
# state.sh turns on errexit; this test collects failures instead (CLAUDE.md §12).
set +e

FAIL=0
fail() { echo "FAIL $*"; FAIL=1; }

# === (u) issue_run_path =====================================================
U="$WORK/u.json"
check_path() {
  local labels="$1" want="$2" got
  printf '{"labels":%s}\n' "$labels" > "$U"
  got=$(bash -c '. "$1"; issue_run_path "$2"' _ "$ISSUE_LIB" "$U")
  [ "$got" = "$want" ] || fail "(u): labels=$labels -> '$got' (want $want)"
}
check_path '[{"name":"heavy-run"}]' heavy
check_path '[{"name":"light-run"}]' light
check_path '[{"name":"auto-run"}]' standard
check_path '[]' standard
check_path '[{"name":"light-run"},{"name":"heavy-run"}]' heavy
got=$(bash -c '. "$1"; issue_run_path "$2"' _ "$ISSUE_LIB" "$WORK/missing.json")
[ "$got" = "standard" ] || fail "(u): missing issue.json -> '$got' (want standard)"
[ "$FAIL" = "0" ] && echo "PASS (u): issue_run_path classifies labels, heavy wins"

RID="20261015-1600-issue-313"
RD="$REPO/.claude/run-issues/$RID"

# setup_run <issue-labels-json> <cycle-review-extra-line>
setup_run() {
  rm -rf "$RD"
  state_init "$RD" "$RID" "$REPO" "313"
  state_set "$RD" "branch" "auto-run/issue-313-x"
  state_set "$RD" "worktree_path" "$WORKTREE"
  state_set "$RD" "cycle_review_decision" "PROCEED"
  printf '{"title":"t","body":"b","comments":[],"labels":%s}\n' "$1" > "$RD/issue.json"
  { [ -n "$2" ] && echo "$2"; echo "CYCLE_REVIEW_DECISION: PROCEED"; } > "$RD/01-cycle-review.out"
  : > "$GH_LOG"
}

run_orch() {
  ( cd "$REPO" && \
    PATH="$BIN:$PATH" \
    RUN_ISSUES_AUTO=1 RUN_ISSUES_REVIEW_GATE=auto \
    RUN_ISSUES_CLAUDE_CMD="$BIN/claude" \
    RUN_ISSUES_LOCK_ROOT="$WORK/locks" \
    MOCK_DIAG_FILE="$RD/diagnosis.md" \
    "$@" "$ORCH" --resume "$RD" --decision PROCEED 2>&1 )
}

HEAVY='[{"name":"auto-run"},{"name":"auto-merge"},{"name":"heavy-run"}]'

# expect_blocked <case>
expect_blocked() {
  local c="$1" rc="$2"
  [ "$rc" = "5" ] || fail "($c): expected exit 5, got $rc"
  [ "$(jq -r '.status' "$RD/run.json")" = "blocked" ] || fail "($c): status not blocked"
  [ "$(jq -r '.blocked_reason' "$RD/run.json")" = "diagnosis_unconfirmed" ] \
    || fail "($c): blocked_reason=$(jq -r '.blocked_reason' "$RD/run.json")"
  grep -q 'needs-human' "$GH_LOG" || fail "($c): needs-human label not added"
  grep -q 'pr create' "$GH_LOG" && fail "($c): a PR was opened despite the gate"
  return 0
}

# === (a) heavy bug, confirmed ==============================================
P=$FAIL
setup_run "$HEAVY" "HEAVY_RUN_KIND: BUG"
OUT=$(run_orch env MOCK_DIAG="CONFIRMED H2" MOCK_DIAG_RAW="raw-output-xyz")
RC=$?
[ "$RC" = "0" ] || { fail "(a): expected exit 0, got $RC"; echo "$OUT" | tail -5; }
[ "$(jq -r '.status' "$RD/run.json")" = "completed" ] || fail "(a): status not completed"
[ "$(jq -r '.run_path' "$RD/run.json")" = "heavy" ] || fail "(a): run_path not heavy"
[ "$(jq -r '.confirmed_hypothesis' "$RD/run.json")" = "H2" ] || fail "(a): confirmed_hypothesis not H2"
grep -qF 'labels[]=manual-merge' "$GH_LOG" || fail "(a): manual-merge not added to PR"
grep -qF 'labels[]=auto-merge' "$GH_LOG" && fail "(a): auto-merge reached a heavy-run PR"
grep -qF '## Diagnosis (heavy-run)' "$RD/pr-body.md" || fail "(a): no diagnosis section in PR body"
grep -qF 'raw-output-xyz' "$RD/pr-body.md" || fail "(a): raw result missing from PR body"
grep -qF 'Confirmed hypothesis: H2' "$RD/pr-body.md" || fail "(a): confirmed hypothesis missing from PR body"
grep -qF 'Raskas polku' "$RD/02-implementer.prompt" || fail "(a): implementer prompt lacks heavy-run section"
grep -qF "$RD/diagnosis.md" "$RD/02-implementer.prompt" || fail "(a): implementer prompt lacks the diagnosis path"
grep -qF 'Raskas polku' "$RD/03-evolution.prompt" || fail "(a): evolution prompt lacks heavy-run section"
[ "$FAIL" = "$P" ] && echo "PASS (a): confirmed diagnosis -> PR with manual-merge and diagnosis section"

# === (b) heavy bug, refuted ================================================
P=$FAIL
setup_run "$HEAVY" "HEAVY_RUN_KIND: BUG"
OUT=$(run_orch env MOCK_DIAG="REFUTED — nothing matched" MOCK_DIAG_RAW="raw")
expect_blocked b $?
[ "$FAIL" = "$P" ] && echo "PASS (b): refuted diagnosis -> blocked for a human, no PR"

# === (c) heavy, unclassified, no result line ===============================
P=$FAIL
setup_run "$HEAVY" ""
OUT=$(run_orch env)
expect_blocked c $?
[ "$FAIL" = "$P" ] && echo "PASS (c): missing classification is a bug; missing result line blocks"

# === (d) heavy bug, confirmed but no raw record ============================
P=$FAIL
setup_run "$HEAVY" "HEAVY_RUN_KIND: BUG"
OUT=$(run_orch env MOCK_DIAG="CONFIRMED H1")
expect_blocked d $?
[ "$FAIL" = "$P" ] && echo "PASS (d): confirmation without a raw record blocks"

# === (e) heavy, not a bug ==================================================
P=$FAIL
setup_run "$HEAVY" "HEAVY_RUN_KIND: NOT_BUG"
OUT=$(run_orch env)
RC=$?
[ "$RC" = "0" ] || { fail "(e): expected exit 0, got $RC"; echo "$OUT" | tail -5; }
grep -qF 'labels[]=manual-merge' "$GH_LOG" || fail "(e): manual-merge not added"
grep -qF 'labels[]=auto-merge' "$GH_LOG" && fail "(e): auto-merge reached a heavy-run PR"
grep -qF '## Diagnosis' "$RD/pr-body.md" && fail "(e): diagnosis section on a non-bug"
grep -qF 'heavy-run:** this PR is not merged automatically' "$RD/pr-body.md" || fail "(e): no manual-merge note in PR body"
grep -qF 'Raskas polku' "$RD/02-implementer.prompt" && fail "(e): non-bug implementer got the gate section"
[ "$FAIL" = "$P" ] && echo "PASS (e): heavy non-bug -> normal path without auto-merge"

# === (f) standard issue ====================================================
P=$FAIL
setup_run '[{"name":"auto-run"},{"name":"auto-merge"}]' ""
OUT=$(run_orch env)
RC=$?
[ "$RC" = "0" ] || { fail "(f): expected exit 0, got $RC"; echo "$OUT" | tail -5; }
[ "$(jq -r '.run_path' "$RD/run.json")" = "standard" ] || fail "(f): run_path not standard"
grep -qF 'labels[]=auto-merge' "$GH_LOG" || fail "(f): auto-merge not propagated"
grep -qF 'manual-merge' "$GH_LOG" && fail "(f): manual-merge on a standard PR"
grep -qF 'Raskas polku' "$RD/02-implementer.prompt" && fail "(f): standard implementer got a heavy-run section"
grep -qF '{{RUN_PATH_SECTION}}' "$RD/02-implementer.prompt" && fail "(f): placeholder left unrendered"
[ "$FAIL" = "$P" ] && echo "PASS (f): standard path unchanged"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "heavy-run: all passed" || echo "heavy-run: FAILURES"
[ "$FAIL" -eq 0 ]
