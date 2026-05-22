#!/usr/bin/env bash
# test-env-bootstrap.sh — S7b fail-fast env bootstrap before the implementer.
#
# Covers the three cases required by issue #33:
#   (a) detect_package_manager: pure lockfile-based detection, incl. the no-op
#       (no package.json -> empty) case.
#   (b) no-op safety: a worktree without package.json passes the gate untouched
#       and the run proceeds to the implementer (env_bootstrap_skipped event).
#   (c) install failure: a non-zero `pnpm install` finalizes the run as
#       blocked / env_bootstrap_failed, attaches needs-human, posts the install
#       log to the issue, and exits 5 — WITHOUT ever invoking the implementer
#       (no timeout budget spent).
#
# Everything external (claude, gh, pnpm) is mocked via PATH shims — no network,
# no real installs. The full-orchestrator cases drive orchestrate.sh in resume
# mode (PROCEED) so they jump straight to phase_b without pick/claim.
#
# Run: bash tests/test-env-bootstrap.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$HERE/../orchestrate.sh"
STATE_LIB="$HERE/../lib/state.sh"
BOOTSTRAP_LIB="$HERE/../lib/env-bootstrap.sh"

WORK=$(mktemp -d -t env-bootstrap.XXXXXX)
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

# shellcheck source=lib/state.sh
. "$STATE_LIB"

FAIL=0

# ===========================================================================
# (a) detect_package_manager — pure, lockfile-based detection
# ===========================================================================
# shellcheck source=lib/env-bootstrap.sh
. "$BOOTSTRAP_LIB"

mk() { mkdir -p "$1"; }

D="$WORK/det"
mk "$D/none"                                                   # no package.json
mk "$D/pnpm";  : > "$D/pnpm/package.json";  : > "$D/pnpm/pnpm-lock.yaml"
mk "$D/yarn";  : > "$D/yarn/package.json";  : > "$D/yarn/yarn.lock"
mk "$D/npm";   : > "$D/npm/package.json";   : > "$D/npm/package-lock.json"
mk "$D/nolock";: > "$D/nolock/package.json"                    # pkg, no lockfile
# Monorepo precedence: pnpm wins when several lockfiles coexist at the root.
mk "$D/multi"; : > "$D/multi/package.json"
: > "$D/multi/pnpm-lock.yaml"; : > "$D/multi/yarn.lock"; : > "$D/multi/package-lock.json"

assert_pm() {
  local got want="$2"
  got=$(detect_package_manager "$1")
  if [ "$got" != "$want" ]; then
    echo "FAIL (a): detect_package_manager('$1') = '$got' (want '$want')"; FAIL=1
  fi
}
assert_pm "$D/none"   ""
assert_pm "$D/pnpm"   "pnpm"
assert_pm "$D/yarn"   "yarn"
assert_pm "$D/npm"    "npm"
assert_pm "$D/nolock" "npm"
assert_pm "$D/multi"  "pnpm"
[ "$FAIL" = "0" ] && echo "PASS (a) detect_package_manager: lockfile detection + no-op"

# Helper to drive the orchestrator in resume/PROCEED mode.
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
# (b) no-op: worktree without package.json proceeds to the implementer
# ===========================================================================
# claude mock writes a sentinel (proves the implementer was reached) and returns
# BLOCKED so phase_b stops cleanly at S8 without needing the full PR flow.
SENTINEL="$WORK/claude-ran"
cat > "$BIN/claude" <<SH
#!/usr/bin/env bash
touch "$SENTINEL"
echo "IMPLEMENTER_RESULT: BLOCKED — test stop after gate"
SH
chmod +x "$BIN/claude"

RID_B="20260522-1700-issue-60"
RD_B="$REPO/.claude/run-issues/$RID_B"
WT_B="$WORK/wt-b"; mkdir -p "$WT_B"   # no package.json -> bootstrap no-op
state_init "$RD_B" "$RID_B" "$REPO" "60"
state_set "$RD_B" "branch" "auto-run/issue-60-x"
state_set "$RD_B" "worktree_path" "$WT_B"
state_set "$RD_B" "cycle_review_decision" "PROCEED"
echo '{"title":"t","body":"b","comments":[]}' > "$RD_B/issue.json"
echo "CYCLE_REVIEW_DECISION: PROCEED" > "$RD_B/01-cycle-review.out"
rm -f "$SENTINEL"

set +e
OUT_B=$(run_orch "$ORCH" --resume "$RD_B" --decision PROCEED 2>&1)
RC_B=$?
set -e
echo "--- (b) no-op proceed (rc=$RC_B) ---"; echo "$OUT_B" | tail -4
grep -q '"event":"env_bootstrap_skipped"' "$RD_B/state.jsonl" \
  || { echo "FAIL (b): no env_bootstrap_skipped event"; FAIL=1; }
[ -f "$SENTINEL" ] || { echo "FAIL (b): implementer was not reached (sentinel missing)"; FAIL=1; }
RE_B=$(jq -r '.blocked_reason' "$RD_B/run.json")
[ "$RE_B" = "implementer_BLOCKED — test stop after gate" ] \
  || { echo "FAIL (b): blocked_reason='$RE_B' (expected implementer BLOCKED, not env_bootstrap)"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (b) no package.json -> bootstrap no-op, implementer reached"

# ===========================================================================
# (c) install failure -> blocked / env_bootstrap_failed, no implementer
# ===========================================================================
# pnpm mock that fails the install (simulates e.g. a missing GITHUB_TOKEN).
cat > "$BIN/pnpm" <<'SH'
#!/usr/bin/env bash
echo "ERR_PNPM_FETCH_401  GET https://npm.pkg.github.com/@silon-oy%2ffoo - 401"
echo "  This is most likely a problem with the @silon-oy/foo package."
exit 1
SH
chmod +x "$BIN/pnpm"

RID_C="20260522-1701-issue-61"
RD_C="$REPO/.claude/run-issues/$RID_C"
WT_C="$WORK/wt-c"; mkdir -p "$WT_C"
: > "$WT_C/package.json"; : > "$WT_C/pnpm-lock.yaml"   # -> pnpm install (fails)
state_init "$RD_C" "$RID_C" "$REPO" "61"
state_set "$RD_C" "branch" "auto-run/issue-61-x"
state_set "$RD_C" "worktree_path" "$WT_C"
state_set "$RD_C" "cycle_review_decision" "PROCEED"
echo '{"title":"t","body":"b","comments":[]}' > "$RD_C/issue.json"
echo "CYCLE_REVIEW_DECISION: PROCEED" > "$RD_C/01-cycle-review.out"
rm -f "$SENTINEL"
: > "$GH_LOG"

set +e
OUT_C=$(run_orch "$ORCH" --resume "$RD_C" --decision PROCEED 2>&1)
RC_C=$?
set -e
echo "--- (c) install failure (rc=$RC_C) ---"; echo "$OUT_C" | tail -5
[ "$RC_C" = "5" ] || { echo "FAIL (c): expected exit 5, got $RC_C"; FAIL=1; }
ST_C=$(jq -r '.status' "$RD_C/run.json")
RE_C=$(jq -r '.blocked_reason' "$RD_C/run.json")
[ "$ST_C" = "blocked" ] || { echo "FAIL (c): status='$ST_C' (want blocked)"; FAIL=1; }
[ "$RE_C" = "env_bootstrap_failed" ] || { echo "FAIL (c): blocked_reason='$RE_C'"; FAIL=1; }
[ ! -f "$SENTINEL" ] || { echo "FAIL (c): implementer was invoked despite bootstrap failure (budget spent)"; FAIL=1; }
[ -f "$RD_C/env-bootstrap.log" ] || { echo "FAIL (c): env-bootstrap.log not written"; FAIL=1; }
grep -q 'add-label needs-human' "$GH_LOG" || { echo "FAIL (c): needs-human label not attempted"; FAIL=1; }
grep -q 'issue comment' "$GH_LOG" || { echo "FAIL (c): situation comment not posted to issue"; FAIL=1; }
grep -q '"event":"env_bootstrap_failed"' "$RD_C/state.jsonl" \
  || { echo "FAIL (c): no env_bootstrap_failed event"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (c) install failure -> blocked/env_bootstrap_failed + needs-human + exit 5"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "env-bootstrap: all passed" || echo "env-bootstrap: FAILURES"
[ "$FAIL" -eq 0 ]
