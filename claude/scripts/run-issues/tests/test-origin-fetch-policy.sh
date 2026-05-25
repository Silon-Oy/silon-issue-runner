#!/usr/bin/env bash
# test-origin-fetch-policy.sh — origin-fetch policy branches in the orchestrator.
#
# refresh_origin's rc semantics are unit-tested in test-refresh-origin.sh. This
# test drives the *orchestrator policy* that consumes those rc values, which the
# unit test cannot reach:
#
#   (a) S4 fail-fast (phase_a/start): a failed `git fetch origin` BEFORE the
#       worktree is created finalizes the run blocked / origin_fetch_failed,
#       labels needs-human, posts a situation comment, writes origin-fetch.log,
#       and exits 5 — WITHOUT ever creating the worktree (a stale base on a new
#       run is unrecoverable, so we must not branch off it).
#
#   (b) restart soft-fetch: a failed `git fetch origin` on the --restart path is
#       NON-fatal. It emits origin_fetch_failed_soft (phase=restart) and the run
#       proceeds (retry_count increments, the implementer is reached). The fetch
#       failure must NOT finalize the run as origin_fetch_failed — commits
#       already exist and the base point is not re-decided. The --continue path
#       shares this exact soft-fetch code path (same case block, phase=continue).
#
# The fetch is made to fail deterministically and offline by pointing `origin`
# at a non-existent path (no git shim needed): `remote get-url origin` succeeds
# (origin is configured) but `git fetch origin` fails with rc!=0 -> refresh_origin
# returns 1. gh + claude are mocked via PATH shims; no network.
#
# Run: bash tests/test-origin-fetch-policy.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$HERE/../orchestrate.sh"
STATE_LIB="$HERE/../lib/state.sh"

WORK=$(mktemp -d -t origin-fetch-policy.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
git -C "$WORK" init -q "repo"
# A configured-but-broken origin: get-url succeeds, fetch fails (offline, rc=1).
git -C "$REPO" remote add origin "$WORK/nonexistent-remote.git"

BIN="$WORK/bin"
mkdir -p "$BIN"

# gh mock: serve issue lookups for phase_a (pick + claim verify) and record
# label/comment attempts. fetch_issue_json wants raw JSON; verify_claim and
# `api user` are reduced via --jq, so we emit the post-jq scalar directly.
GH_LOG="$WORK/gh-calls.log"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"
case "\$*" in
  *"issue view"*"--json assignees"*) echo "testbot" ;;            # verify_claim
  *"issue view"*) echo '{"title":"Fetch test","body":"b","labels":[],"author":{"login":"x"},"comments":[]}' ;;
  *"api user"*) echo "testbot" ;;                                  # me == assignee
  *"issue comment"*"--body-file -"*) cat >/dev/null 2>&1 || true ;;
  *) : ;;                                                          # edit/label/etc
esac
exit 0
SH
chmod +x "$BIN/gh"

# shellcheck source=lib/state.sh
. "$STATE_LIB"

run_orch() {
  ( cd "$REPO" && \
    PATH="$BIN:$PATH" \
    RUN_ISSUES_AUTO=1 RUN_ISSUES_REVIEW_GATE=auto \
    RUN_ISSUES_CLAUDE_CMD="$BIN/claude" \
    RUN_ISSUES_LOCK_ROOT="$WORK/locks" \
    RUN_ISSUES_ENV_FILE="$WORK/no-such-env" \
    "$@" )
}

FAIL=0

# ===========================================================================
# (a) S4 fail-fast: fetch failure on a NEW run -> blocked, no worktree, exit 5
# ===========================================================================
: > "$GH_LOG"
set +e
OUT_A=$(run_orch "$ORCH" "$REPO" 70 2>&1)
RC_A=$?
set -e
echo "--- (a) S4 fail-fast (rc=$RC_A) ---"; echo "$OUT_A" | tail -5

# The run-dir name is timestamped; resolve the single issue-70 run.
RD_A=$(ls -d "$REPO"/.claude/run-issues/*-issue-70 2>/dev/null | tail -1)
if [ -z "$RD_A" ] || [ ! -f "$RD_A/run.json" ]; then
  echo "FAIL (a): issue-70 run-dir not found"; FAIL=1
else
  [ "$RC_A" = "5" ] || { echo "FAIL (a): expected exit 5, got $RC_A"; FAIL=1; }
  ST_A=$(jq -r '.status' "$RD_A/run.json")
  RE_A=$(jq -r '.blocked_reason' "$RD_A/run.json")
  [ "$ST_A" = "blocked" ] || { echo "FAIL (a): status='$ST_A' (want blocked)"; FAIL=1; }
  [ "$RE_A" = "origin_fetch_failed" ] || { echo "FAIL (a): blocked_reason='$RE_A'"; FAIL=1; }
  grep -q '"event":"origin_fetch_failed"' "$RD_A/state.jsonl" \
    || { echo "FAIL (a): no origin_fetch_failed event"; FAIL=1; }
  # The worktree must NOT have been created — we block before branching.
  if grep -q '"event":"worktree_created"' "$RD_A/state.jsonl"; then
    echo "FAIL (a): worktree was created despite stale-base block"; FAIL=1
  fi
  [ -f "$RD_A/origin-fetch.log" ] || { echo "FAIL (a): origin-fetch.log not written"; FAIL=1; }
  grep -q 'add-label needs-human' "$GH_LOG" || { echo "FAIL (a): needs-human label not attempted"; FAIL=1; }
  grep -q 'issue comment' "$GH_LOG" || { echo "FAIL (a): situation comment not posted"; FAIL=1; }
fi
[ "$FAIL" = "0" ] && echo "PASS (a) S4 fetch fail -> blocked/origin_fetch_failed + needs-human + no worktree + exit 5"

# ===========================================================================
# (b) restart soft-fetch: fetch failure is non-fatal, run proceeds
# ===========================================================================
# A timed_out run with an intact worktree and retry budget available. The
# restart path runs refresh_origin (soft) before building RESTART_CONTEXT.
make_worktree() {
  local wt="$1"
  git -C "$WORK" init -q "$(basename "$wt")"
  ( cd "$wt"
    git config user.email t@t; git config user.name t
    git commit -q --allow-empty -m base
    git update-ref refs/remotes/origin/main HEAD
    git commit -q --allow-empty -m "feat: partial work from prior run"
  )
}

# claude mock returns BLOCKED so phase_b stops cleanly at S8 after the soft
# fetch. The retry increment + soft-fetch event happen BEFORE this is reached.
cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
echo "IMPLEMENTER_RESULT: BLOCKED — stop after soft fetch"
SH
chmod +x "$BIN/claude"

RID_B="20260523-1200-issue-71"
RD_B="$REPO/.claude/run-issues/$RID_B"
WT_B="$WORK/wt-b"
make_worktree "$WT_B"
state_init "$RD_B" "$RID_B" "$REPO" "71"
state_set "$RD_B" "branch" "auto-run/issue-71-x"
state_set "$RD_B" "worktree_path" "$WT_B"
echo '{"title":"t","body":"b","comments":[]}' > "$RD_B/issue.json"
echo "ok" > "$RD_B/01-cycle-review.out"
state_finalize "$RD_B" "timed_out" "implementer_timeout"
: > "$GH_LOG"

set +e
OUT_B=$(run_orch env RUN_ISSUES_MAX_RETRIES=1 "$ORCH" --restart "$RD_B" 2>&1)
RC_B=$?
set -e
echo "--- (b) restart soft-fetch (rc=$RC_B) ---"; echo "$OUT_B" | tail -5

# Soft event recorded with the restart phase tag.
grep -q '"event":"origin_fetch_failed_soft"' "$RD_B/state.jsonl" \
  || { echo "FAIL (b): no origin_fetch_failed_soft event"; FAIL=1; }
grep '"event":"origin_fetch_failed_soft"' "$RD_B/state.jsonl" | grep -q '"phase":"restart"' \
  || { echo "FAIL (b): soft event missing phase=restart"; FAIL=1; }
# The run proceeded PAST the soft fetch: retry incremented, implementer reached.
[ "$(jq -r '.retry_count' "$RD_B/run.json")" = "1" ] \
  || { echo "FAIL (b): retry_count != 1 — run did not proceed past soft fetch"; FAIL=1; }
# The fetch failure must NOT be the blocking reason (it is non-fatal here).
RE_B=$(jq -r '.blocked_reason' "$RD_B/run.json")
[ "$RE_B" != "origin_fetch_failed" ] \
  || { echo "FAIL (b): restart finalized as origin_fetch_failed (should be non-fatal)"; FAIL=1; }
# No hard fail-fast event on the restart path.
if grep -q '"event":"origin_fetch_failed"' "$RD_B/state.jsonl"; then
  echo "FAIL (b): hard origin_fetch_failed event on restart (should be soft)"; FAIL=1
fi
[ "$FAIL" = "0" ] && echo "PASS (b) restart fetch fail -> soft (non-fatal), run proceeds, retry incremented"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "origin-fetch-policy: all passed" || echo "origin-fetch-policy: FAILURES"
[ "$FAIL" -eq 0 ]
