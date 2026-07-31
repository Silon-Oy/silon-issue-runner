#!/usr/bin/env bash
# test-provision-test-env.sh — S7c opt-in per-run test-env provisioning hook.
#
# Covers issue #37's acceptance criteria, deterministic and network-free
# (claude, gh and the hook are PATH/file mocks):
#   (a) no hook / not executable -> no-op (provision_test_env_skipped), the run
#       proceeds to the implementer.
#   (b) hook emits KEY=VALUE on stdout -> the orchestrator injects those vars
#       into the implementer's environment, ignores diagnostics, and records the
#       injected KEY NAMES (not values) in run.json. The injected value embeds
#       the run-id, so asserting it proves BOTH KEY=VALUE parsing AND that the
#       run-id was passed to the hook as the isolation key.
#   (c) hook fails (rc != 0) -> blocked / provision_test_env_failed, needs-human
#       label, situation comment posted, exit 5, implementer NOT reached (no
#       timeout budget spent).
#   (d) teardown via cleanup-run.sh: the hook is invoked as `cleanup <run-id>`
#       before the worktree is removed, and a FAILING cleanup hook is best-effort
#       (teardown still completes, run-dir removed).
#
# The orchestrator cases drive orchestrate.sh in resume mode (PROCEED) so they
# jump straight to phase_b (S7b -> S7c -> S8) without pick/claim. The worktree
# has no package.json, so S7b is a no-op and the test isolates S7c.
#
# Run: bash tests/test-provision-test-env.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$HERE/../orchestrate.sh"
CLEANUP="$HERE/../cleanup-run.sh"
STATE_LIB="$HERE/../lib/state.sh"

WORK=$(mktemp -d -t provision-test-env.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
git -C "$WORK" init -q "repo"

BIN="$WORK/bin"
mkdir -p "$BIN"

# gh mock: log every call so we can assert label/comment attempts. Drain any
# piped body (`issue comment --body-file -`) so the writer never gets SIGPIPE.
GH_LOG="$WORK/gh-calls.log"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"
case "\$*" in
  *"--body-file -"*) cat >/dev/null 2>&1 || true ;;
esac
exit 0
SH
chmod +x "$BIN/gh"

# claude mock: dump the test-env vars it can see (proves env injection), record
# that the implementer was reached, then return BLOCKED so phase_b stops cleanly
# at S8 without driving the full PR flow.
ENVDUMP="$WORK/claude-env"
SENTINEL="$WORK/claude-ran"
cat > "$BIN/claude" <<SH
#!/usr/bin/env bash
env | grep -E '^(DATABASE_URL_TEST|REDIS_URL)=' > "$ENVDUMP" 2>/dev/null || true
touch "$SENTINEL"
echo "IMPLEMENTER_RESULT: BLOCKED — test stop after gate"
SH
chmod +x "$BIN/claude"

# shellcheck source=lib/state.sh
. "$STATE_LIB"

FAIL=0

run_orch() {
  ( cd "$REPO" && \
    PATH="$BIN:$PATH" \
    RUN_ISSUES_AUTO=1 RUN_ISSUES_REVIEW_GATE=auto \
    RUN_ISSUES_CLAUDE_CMD="$BIN/claude" \
    RUN_ISSUES_LOCK_ROOT="$WORK/locks" \
    RUN_ISSUES_ENV_FILE="$WORK/no-such-env" \
    "$@" )
}

# seed_run <rid> <issue> <worktree> — minimal resume-ready run-dir at PROCEED.
seed_run() {
  local rid="$1" issue="$2" wt="$3"
  local rd="$REPO/.claude/run-issues/$rid"
  state_init "$rd" "$rid" "$REPO" "$issue"
  state_set "$rd" "branch" "auto-run/issue-$issue-x"
  state_set "$rd" "worktree_path" "$wt"
  state_set "$rd" "cycle_review_decision" "PROCEED"
  echo '{"title":"t","body":"b","comments":[]}' > "$rd/issue.json"
  echo "CYCLE_REVIEW_DECISION: PROCEED" > "$rd/01-cycle-review.out"
  printf '%s' "$rd"
}

# ===========================================================================
# (a) no hook -> no-op, implementer reached
# ===========================================================================
RID_A="20260523-1700-issue-70"
WT_A="$WORK/wt-a"; mkdir -p "$WT_A"   # no .claude/provision-test-env.sh
RD_A=$(seed_run "$RID_A" 70 "$WT_A")
rm -f "$SENTINEL" "$ENVDUMP"

set +e
OUT_A=$(run_orch "$ORCH" --resume "$RD_A" --decision PROCEED 2>&1)
RC_A=$?
set -e
echo "--- (a) no-op proceed (rc=$RC_A) ---"; echo "$OUT_A" | tail -3
grep -q '"event":"provision_test_env_skipped"' "$RD_A/state.jsonl" \
  || { echo "FAIL (a): no provision_test_env_skipped event"; FAIL=1; }
[ -f "$SENTINEL" ] || { echo "FAIL (a): implementer was not reached"; FAIL=1; }
PE_A=$(jq -r '.provision_test_env // "ABSENT"' "$RD_A/run.json")
[ "$PE_A" = "ABSENT" ] || { echo "FAIL (a): provision_test_env set to '$PE_A' on no-op"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (a) no hook -> no-op, implementer reached"

# Also assert a present-but-not-executable hook is treated as no-op.
RID_A2="20260523-1701-issue-71"
WT_A2="$WORK/wt-a2"; mkdir -p "$WT_A2/.claude"
echo '#!/usr/bin/env bash' > "$WT_A2/.claude/provision-test-env.sh"   # NOT chmod +x
RD_A2=$(seed_run "$RID_A2" 71 "$WT_A2")
rm -f "$SENTINEL"
set +e
run_orch "$ORCH" --resume "$RD_A2" --decision PROCEED >/dev/null 2>&1
set -e
grep -q '"event":"provision_test_env_skipped"' "$RD_A2/state.jsonl" \
  || { echo "FAIL (a2): non-executable hook not skipped"; FAIL=1; }
[ -f "$SENTINEL" ] || { echo "FAIL (a2): implementer not reached for non-exec hook"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (a2) present-but-not-executable hook -> no-op"

# ===========================================================================
# (b) hook emits KEY=VALUE -> injected into implementer env + run-id isolation
# ===========================================================================
RID_B="20260523-1702-issue-72"
WT_B="$WORK/wt-b"; mkdir -p "$WT_B/.claude"
# Hook: diagnostics to stderr AND a non-KEY=VALUE diagnostic line to stdout (must
# be ignored), plus two real KEY=VALUE lines. The DB url embeds the run-id ($2).
cat > "$WT_B/.claude/provision-test-env.sh" <<'SH'
#!/usr/bin/env bash
mode="$1"; runid="$2"
[ "$mode" = "provision" ] || { echo "unexpected mode $mode" >&2; exit 9; }
echo "provisioning test resources for run-id=$runid" >&2   # stderr diagnostic
echo "creating database test_$runid ..."                   # stdout diagnostic (ignored)
echo "DATABASE_URL_TEST=postgres://localhost:5432/test_$runid"
echo "REDIS_URL=redis://localhost:6379/1"
SH
chmod +x "$WT_B/.claude/provision-test-env.sh"
RD_B=$(seed_run "$RID_B" 72 "$WT_B")
rm -f "$SENTINEL" "$ENVDUMP"

set +e
OUT_B=$(run_orch "$ORCH" --resume "$RD_B" --decision PROCEED 2>&1)
RC_B=$?
set -e
echo "--- (b) provision + inject (rc=$RC_B) ---"; echo "$OUT_B" | tail -3
[ -f "$SENTINEL" ] || { echo "FAIL (b): implementer not reached"; FAIL=1; }
grep -q '"event":"provision_test_env_ok"' "$RD_B/state.jsonl" \
  || { echo "FAIL (b): no provision_test_env_ok event"; FAIL=1; }
# run-id isolation + KEY=VALUE parse: the injected value must embed the run-id.
if [ -f "$ENVDUMP" ]; then
  grep -qx "DATABASE_URL_TEST=postgres://localhost:5432/test_$RID_B" "$ENVDUMP" \
    || { echo "FAIL (b): DATABASE_URL_TEST not injected with run-id"; cat "$ENVDUMP"; FAIL=1; }
  grep -qx "REDIS_URL=redis://localhost:6379/1" "$ENVDUMP" \
    || { echo "FAIL (b): REDIS_URL not injected"; FAIL=1; }
else
  echo "FAIL (b): claude env dump missing — implementer env not captured"; FAIL=1
fi
# run.json stores the injected KEY NAMES (comma-separated), not the values.
PE_B=$(jq -r '.provision_test_env' "$RD_B/run.json")
[ "$PE_B" = "DATABASE_URL_TEST,REDIS_URL" ] \
  || { echo "FAIL (b): provision_test_env='$PE_B' (want 'DATABASE_URL_TEST,REDIS_URL')"; FAIL=1; }
# Secrets must NOT leak into run.json: no value (with the password) is stored.
if jq -r '.provision_test_env' "$RD_B/run.json" | grep -q 'postgres://'; then
  echo "FAIL (b): a connection-string VALUE leaked into run.json"; FAIL=1
fi
[ "$FAIL" = "0" ] && echo "PASS (b) KEY=VALUE injected with run-id isolation, key names persisted"

# ===========================================================================
# (c) hook fails -> blocked / provision_test_env_failed, no implementer
# ===========================================================================
RID_C="20260523-1703-issue-73"
WT_C="$WORK/wt-c"; mkdir -p "$WT_C/.claude"
cat > "$WT_C/.claude/provision-test-env.sh" <<'SH'
#!/usr/bin/env bash
echo "FATAL: could not connect to postgres (is the dev stack up?)" >&2
exit 1
SH
chmod +x "$WT_C/.claude/provision-test-env.sh"
RD_C=$(seed_run "$RID_C" 73 "$WT_C")
rm -f "$SENTINEL"
: > "$GH_LOG"

set +e
OUT_C=$(run_orch "$ORCH" --resume "$RD_C" --decision PROCEED 2>&1)
RC_C=$?
set -e
echo "--- (c) hook failure (rc=$RC_C) ---"; echo "$OUT_C" | tail -4
[ "$RC_C" = "5" ] || { echo "FAIL (c): expected exit 5, got $RC_C"; FAIL=1; }
ST_C=$(jq -r '.status' "$RD_C/run.json")
RE_C=$(jq -r '.blocked_reason' "$RD_C/run.json")
[ "$ST_C" = "blocked" ] || { echo "FAIL (c): status='$ST_C' (want blocked)"; FAIL=1; }
[ "$RE_C" = "provision_test_env_failed" ] || { echo "FAIL (c): blocked_reason='$RE_C'"; FAIL=1; }
[ ! -f "$SENTINEL" ] || { echo "FAIL (c): implementer invoked despite provision failure"; FAIL=1; }
[ -f "$RD_C/provision-test-env.log" ] || { echo "FAIL (c): provision-test-env.log not written"; FAIL=1; }
grep -qF 'labels[]=needs-human' "$GH_LOG" || { echo "FAIL (c): needs-human label not attempted"; FAIL=1; }
grep -q 'issue comment' "$GH_LOG" || { echo "FAIL (c): situation comment not posted"; FAIL=1; }
grep -q '"event":"provision_test_env_failed"' "$RD_C/state.jsonl" \
  || { echo "FAIL (c): no provision_test_env_failed event"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (c) hook failure -> blocked/provision_test_env_failed + needs-human + exit 5"

# ===========================================================================
# (d) teardown via cleanup-run.sh: hook called as `cleanup <run-id>`, best-effort
# ===========================================================================
# d1: a cleanup hook that records its args and succeeds.
RID_D="20260523-1704-issue-74"
WT_D="$WORK/wt-d"; mkdir -p "$WT_D/.claude"
CLEANUP_LOG="$WORK/provision-cleanup.log"
cat > "$WT_D/.claude/provision-test-env.sh" <<SH
#!/usr/bin/env bash
echo "\$1 \$2" >> "$CLEANUP_LOG"
# Idempotent teardown (DROP ... IF EXISTS): always succeeds even if absent.
exit 0
SH
chmod +x "$WT_D/.claude/provision-test-env.sh"
RD_D="$REPO/.claude/run-issues/$RID_D"
state_init "$RD_D" "$RID_D" "$REPO" 74
state_set "$RD_D" "branch" "auto-run/issue-74-x"
state_set "$RD_D" "worktree_path" "$WT_D"
state_set "$RD_D" "status" "blocked"
state_set "$RD_D" "provision_test_env" "DATABASE_URL_TEST"
: > "$CLEANUP_LOG"

set +e
OUT_D=$( cd "$REPO" && PATH="$BIN:$PATH" RUN_ISSUES_LOCK_ROOT="$WORK/locks" \
  bash "$CLEANUP" --repo "$REPO" --issue 74 --yes 2>&1 )
RC_D=$?
set -e
echo "--- (d1) teardown success (rc=$RC_D) ---"; echo "$OUT_D" | grep -i provision || true
grep -qx "cleanup $RID_D" "$CLEANUP_LOG" \
  || { echo "FAIL (d1): hook not called as 'cleanup $RID_D'"; cat "$CLEANUP_LOG"; FAIL=1; }
[ ! -d "$RD_D" ] || { echo "FAIL (d1): run-dir not removed after teardown"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (d1) cleanup-run.sh invokes hook as 'cleanup <run-id>'"

# d2: a FAILING cleanup hook must be best-effort — teardown still completes.
RID_E="20260523-1705-issue-75"
WT_E="$WORK/wt-e"; mkdir -p "$WT_E/.claude"
cat > "$WT_E/.claude/provision-test-env.sh" <<'SH'
#!/usr/bin/env bash
echo "cleanup failed: stack down" >&2
exit 1
SH
chmod +x "$WT_E/.claude/provision-test-env.sh"
RD_E="$REPO/.claude/run-issues/$RID_E"
state_init "$RD_E" "$RID_E" "$REPO" 75
state_set "$RD_E" "branch" "auto-run/issue-75-x"
state_set "$RD_E" "worktree_path" "$WT_E"
state_set "$RD_E" "status" "blocked"
state_set "$RD_E" "provision_test_env" "DATABASE_URL_TEST"

set +e
OUT_E=$( cd "$REPO" && PATH="$BIN:$PATH" RUN_ISSUES_LOCK_ROOT="$WORK/locks" \
  bash "$CLEANUP" --repo "$REPO" --issue 75 --yes 2>&1 )
RC_E=$?
set -e
echo "--- (d2) teardown w/ failing hook (rc=$RC_E) ---"; echo "$OUT_E" | grep -i provision || true
[ ! -d "$RD_E" ] || { echo "FAIL (d2): run-dir not removed despite best-effort cleanup"; FAIL=1; }
echo "$OUT_E" | grep -q 'provision-test-env cleanup failed' \
  || { echo "FAIL (d2): failing cleanup not reported"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (d2) failing cleanup hook is best-effort, teardown completes"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "provision-test-env: all passed" || echo "provision-test-env: FAILURES"
[ "$FAIL" -eq 0 ]
