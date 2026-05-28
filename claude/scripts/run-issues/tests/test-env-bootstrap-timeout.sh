#!/usr/bin/env bash
# test-env-bootstrap-timeout.sh — S7b fail-fast on install timeout (issue #49).
#
# Covers the path that issue #49 stuck on for 48+ hours: a composer/pnpm install
# that hangs forever used to silently burn the entire implementer timeout
# budget. After the fix, _run_env_install wraps the install in
# `timeout --kill-after=60 ${RUN_ISSUES_ENV_BOOTSTRAP_TIMEOUT:-1200}` and a
# rc=124 finalizes the run distinctly as blocked/env_bootstrap_timeout
# (separate diagnosis path from the existing rc!=0 env_bootstrap_failed).
#
# (a) timeout fires: pnpm install hangs past a tiny RUN_ISSUES_ENV_BOOTSTRAP_TIMEOUT
#     -> rc=124 path: status=blocked, blocked_reason=env_bootstrap_timeout,
#     needs-human + situation comment, exit 5, implementer NEVER invoked.
# (b) success under budget: pnpm install completes quickly and the implementer
#     IS reached (the timeout wrapper must preserve the success exit code; rc=0
#     wins over rc=124 when the child finishes in time — same semantics as
#     claude-call.sh).
# (c) composer timeout follows the same path (proves the wrapper applies to
#     every ecosystem branch, not just pnpm).
#
# Everything external (claude, gh, pnpm, composer) is mocked via PATH shims.
# RUN_ISSUES_ENV_BOOTSTRAP_TIMEOUT=1 keeps tests fast (the kill-after grace
# adds ~60s in the worst case, so we use a sleeping mock that should be killed
# well before that grace expires).
#
# Run: bash tests/test-env-bootstrap-timeout.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$HERE/../orchestrate.sh"
STATE_LIB="$HERE/../lib/state.sh"

# The test relies on a working `timeout`/`gtimeout`. Skip if neither is present
# (e.g. minimal CI image) — the orchestrator's WARNING handles this case in
# production and there is nothing for the test to verify.
if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
  echo "SKIP: no timeout/gtimeout binary on PATH"
  exit 0
fi

WORK=$(mktemp -d -t env-bootstrap-timeout.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
git -C "$WORK" init -q "repo"

BIN="$WORK/bin"
mkdir -p "$BIN"

# gh mock: log every call so we can assert label/comment attempts. Drain any
# piped/--body-file body so the writer never gets SIGPIPE.
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

# claude sentinel: proves the implementer was reached (case b) and proves it
# was NOT reached (cases a/c) — touched file is the signal.
SENTINEL="$WORK/claude-ran"
cat > "$BIN/claude" <<SH
#!/usr/bin/env bash
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

# ===========================================================================
# (a) pnpm install hangs past timeout -> blocked/env_bootstrap_timeout
# ===========================================================================
# Mock that sleeps far past the 1s budget. timeout(1) will SIGTERM it at ~1s
# and the kill-after=60 grace gives the wrapper plenty of time to reap. We
# never actually wait the full grace — `sleep 600` is just bigger than both.
cat > "$BIN/pnpm" <<'SH'
#!/usr/bin/env bash
echo "fetching @silon-oy/foo ..."
# Simulate a network-stuck install that ignores SIGTERM gracefully (sleep
# DOES handle TERM, so timeout's 1s + kill-after=60 grace can reap it fast).
sleep 600
SH
chmod +x "$BIN/pnpm"

RID_A="20260528-1500-issue-70"
RD_A="$REPO/.claude/run-issues/$RID_A"
WT_A="$WORK/wt-a"; mkdir -p "$WT_A"
: > "$WT_A/package.json"; : > "$WT_A/pnpm-lock.yaml"
state_init "$RD_A" "$RID_A" "$REPO" "70"
state_set "$RD_A" "branch" "auto-run/issue-70-x"
state_set "$RD_A" "worktree_path" "$WT_A"
state_set "$RD_A" "cycle_review_decision" "PROCEED"
echo '{"title":"t","body":"b","comments":[]}' > "$RD_A/issue.json"
echo "CYCLE_REVIEW_DECISION: PROCEED" > "$RD_A/01-cycle-review.out"
rm -f "$SENTINEL"
: > "$GH_LOG"

# Time the run to prove the wrapper actually fires (the timeout MUST cap the
# wait far below `sleep 600`). The hard ceiling is timeout + kill-after grace
# (~61s) plus orchestrator overhead — anything north of ~80s would mean the
# wrapper failed to install. We give a generous 90s envelope.
START_A=$(date +%s)
set +e
OUT_A=$(run_orch env RUN_ISSUES_ENV_BOOTSTRAP_TIMEOUT=1 \
  "$ORCH" --resume "$RD_A" --decision PROCEED 2>&1)
RC_A=$?
set -e
END_A=$(date +%s)
ELAPSED_A=$(( END_A - START_A ))
echo "--- (a) pnpm timeout (rc=$RC_A elapsed=${ELAPSED_A}s) ---"
echo "$OUT_A" | tail -6

[ "$RC_A" = "5" ] || { echo "FAIL (a): expected exit 5, got $RC_A"; FAIL=1; }
ST_A=$(jq -r '.status' "$RD_A/run.json")
RE_A=$(jq -r '.blocked_reason' "$RD_A/run.json")
[ "$ST_A" = "blocked" ] || { echo "FAIL (a): status='$ST_A' (want blocked)"; FAIL=1; }
[ "$RE_A" = "env_bootstrap_timeout" ] \
  || { echo "FAIL (a): blocked_reason='$RE_A' (want env_bootstrap_timeout)"; FAIL=1; }
[ ! -f "$SENTINEL" ] \
  || { echo "FAIL (a): implementer invoked despite bootstrap timeout (budget spent)"; FAIL=1; }
[ -f "$RD_A/env-bootstrap.log" ] \
  || { echo "FAIL (a): env-bootstrap.log not written"; FAIL=1; }
grep -q 'add-label needs-human' "$GH_LOG" \
  || { echo "FAIL (a): needs-human label not attempted"; FAIL=1; }
grep -q 'issue comment' "$GH_LOG" \
  || { echo "FAIL (a): situation comment not posted to issue"; FAIL=1; }
grep -q '"event":"env_bootstrap_timeout"' "$RD_A/state.jsonl" \
  || { echo "FAIL (a): no env_bootstrap_timeout event"; FAIL=1; }
[ "$ELAPSED_A" -lt 90 ] \
  || { echo "FAIL (a): elapsed ${ELAPSED_A}s — wrapper did not enforce timeout"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (a) pnpm hang -> env_bootstrap_timeout + exit 5 + within wrapper budget"

# ===========================================================================
# (b) pnpm install succeeds quickly -> implementer reached (no false positive)
# ===========================================================================
# A clean, fast install must NOT trigger the timeout path. Same wrapper, but
# the mock returns immediately so rc=0 wins over rc=124.
cat > "$BIN/pnpm" <<'SH'
#!/usr/bin/env bash
echo "Lockfile is up to date, resolution step is skipped"
echo "Already up to date"
exit 0
SH
chmod +x "$BIN/pnpm"

RID_B="20260528-1501-issue-71"
RD_B="$REPO/.claude/run-issues/$RID_B"
WT_B="$WORK/wt-b"; mkdir -p "$WT_B"
: > "$WT_B/package.json"; : > "$WT_B/pnpm-lock.yaml"
state_init "$RD_B" "$RID_B" "$REPO" "71"
state_set "$RD_B" "branch" "auto-run/issue-71-x"
state_set "$RD_B" "worktree_path" "$WT_B"
state_set "$RD_B" "cycle_review_decision" "PROCEED"
echo '{"title":"t","body":"b","comments":[]}' > "$RD_B/issue.json"
echo "CYCLE_REVIEW_DECISION: PROCEED" > "$RD_B/01-cycle-review.out"
rm -f "$SENTINEL"

set +e
OUT_B=$(run_orch env RUN_ISSUES_ENV_BOOTSTRAP_TIMEOUT=1 \
  "$ORCH" --resume "$RD_B" --decision PROCEED 2>&1)
RC_B=$?
set -e
echo "--- (b) pnpm fast success (rc=$RC_B) ---"; echo "$OUT_B" | tail -4

grep -q '"event":"env_bootstrap_ok"' "$RD_B/state.jsonl" \
  || { echo "FAIL (b): no env_bootstrap_ok event"; FAIL=1; }
[ -f "$SENTINEL" ] \
  || { echo "FAIL (b): implementer was not reached (sentinel missing)"; FAIL=1; }
RE_B=$(jq -r '.blocked_reason // ""' "$RD_B/run.json")
case "$RE_B" in
  env_bootstrap_*) echo "FAIL (b): bootstrap path was hit (blocked_reason='$RE_B')"; FAIL=1 ;;
esac
[ "$FAIL" = "0" ] && echo "PASS (b) fast pnpm install -> implementer reached, no timeout false positive"

# ===========================================================================
# (c) composer install hangs past timeout -> same blocked/env_bootstrap_timeout
# ===========================================================================
cat > "$BIN/composer" <<'SH'
#!/usr/bin/env bash
echo "Loading composer repositories with package information"
sleep 600
SH
chmod +x "$BIN/composer"

RID_C="20260528-1502-issue-72"
RD_C="$REPO/.claude/run-issues/$RID_C"
WT_C="$WORK/wt-c"; mkdir -p "$WT_C"
: > "$WT_C/composer.lock"                                  # -> composer install (hangs)
state_init "$RD_C" "$RID_C" "$REPO" "72"
state_set "$RD_C" "branch" "auto-run/issue-72-x"
state_set "$RD_C" "worktree_path" "$WT_C"
state_set "$RD_C" "cycle_review_decision" "PROCEED"
echo '{"title":"t","body":"b","comments":[]}' > "$RD_C/issue.json"
echo "CYCLE_REVIEW_DECISION: PROCEED" > "$RD_C/01-cycle-review.out"
rm -f "$SENTINEL"
: > "$GH_LOG"

START_C=$(date +%s)
set +e
OUT_C=$(run_orch env RUN_ISSUES_ENV_BOOTSTRAP_TIMEOUT=1 \
  "$ORCH" --resume "$RD_C" --decision PROCEED 2>&1)
RC_C=$?
set -e
END_C=$(date +%s)
ELAPSED_C=$(( END_C - START_C ))
echo "--- (c) composer timeout (rc=$RC_C elapsed=${ELAPSED_C}s) ---"
echo "$OUT_C" | tail -5

[ "$RC_C" = "5" ] || { echo "FAIL (c): expected exit 5, got $RC_C"; FAIL=1; }
ST_C=$(jq -r '.status' "$RD_C/run.json")
RE_C=$(jq -r '.blocked_reason' "$RD_C/run.json")
[ "$ST_C" = "blocked" ] || { echo "FAIL (c): status='$ST_C' (want blocked)"; FAIL=1; }
[ "$RE_C" = "env_bootstrap_timeout" ] \
  || { echo "FAIL (c): blocked_reason='$RE_C' (want env_bootstrap_timeout)"; FAIL=1; }
[ ! -f "$SENTINEL" ] \
  || { echo "FAIL (c): implementer invoked despite composer hang (budget spent)"; FAIL=1; }
[ -f "$RD_C/env-bootstrap-composer.log" ] \
  || { echo "FAIL (c): composer bootstrap log not written"; FAIL=1; }
grep -q '"event":"env_bootstrap_timeout"' "$RD_C/state.jsonl" \
  || { echo "FAIL (c): no env_bootstrap_timeout event"; FAIL=1; }
[ "$ELAPSED_C" -lt 90 ] \
  || { echo "FAIL (c): elapsed ${ELAPSED_C}s — composer wrapper did not enforce timeout"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (c) composer hang -> env_bootstrap_timeout (same fail-fast path)"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "env-bootstrap-timeout: all passed" || echo "env-bootstrap-timeout: FAILURES"
[ "$FAIL" -eq 0 ]
