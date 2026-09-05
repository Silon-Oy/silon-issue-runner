#!/usr/bin/env bash
# test-cycle-review-blocker-label.sh — the auto review-gate BLOCKER path leaves a
# filterable needs-human label (issue #43).
#
# Regression guard for the silent-blocker bug: a run that ends in
# cycle_review_blocker used to post only an issue COMMENT — no label — so the
# issue kept looking like a normal in-flight run and the stall was invisible to
# `gh issue list --search "label:needs-human"` and to the human. The fix attaches
# needs-human on this terminal path, exactly as origin_fetch_failed and
# worktree_base_unresolved already do.
#
# This drives a full `start` run through S0..S6 into the auto review gate:
#   - real bare origin + clone with origin/HEAD (so S4 create_worktree succeeds),
#   - gh mocked (issue lookup, S2b blocked_by=0, claim verify),
#   - claude mocked at S6 to return CYCLE_REVIEW_DECISION: BLOCKER.
# Then asserts: exit 4, status blocked / cycle_review_blocker, needs-human label
# attempted, and a situation comment posted. No network.
#
# Run: bash tests/test-cycle-review-blocker-label.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$HERE/../orchestrate.sh"

WORK=$(mktemp -d -t cycle-review-blocker.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0

# --- real bare origin + clone with origin/HEAD (so S4 worktree resolves) -----
ORIGIN="$WORK/origin.git"
SRC="$WORK/src"
git init -q --bare "$ORIGIN"
# Force `main` regardless of the machine's init.defaultBranch.
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q "$SRC"
git -C "$SRC" symbolic-ref HEAD refs/heads/main
(
  cd "$SRC"
  git config user.email t@t.t; git config user.name t
  git remote add origin "$ORIGIN"
  echo "v0" > f.txt; git add f.txt; git commit -qm init
  git push -q origin main
)
REPO="$WORK/repo"
git clone -q "$ORIGIN" "$REPO"
git -C "$REPO" remote set-head origin main   # origin/HEAD -> main

BIN="$WORK/bin"
mkdir -p "$BIN"

# gh mock: serve phase_a's issue lookups + claim verify, stub the S2b blocked-by
# gate as "0 open blockers", and record every call so we can assert the label +
# comment attempts. Mirrors test-origin-fetch-policy's shim.
GH_LOG="$WORK/gh-calls.log"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"
case "\$*" in
  *"dependencies/blocked_by"*) echo "0" ;;                        # S2b: no blockers
  *"issue view"*"--json labels"*) echo "0" ;;                     # S2c is_epic: not an epic (--jq reduces to "0")
  *"issue view"*"--json assignees"*) echo "testbot" ;;            # verify_claim
  *"issue view"*) echo '{"title":"Contradictory issue","body":"b","labels":[],"author":{"login":"x"},"comments":[]}' ;;
  *"api user"*) echo "testbot" ;;                                  # me == assignee
  *"issue comment"*"--body-file -"*) cat >/dev/null 2>&1 || true ;;
  *) : ;;                                                          # edit/label/api etc
esac
exit 0
SH
chmod +x "$BIN/gh"

# claude mock: the S6 cycle-review returns BLOCKER (a contradictory issue the
# implementer cannot resolve). run_cycle_review parses the second field, so the
# decision must be `CYCLE_REVIEW_DECISION: BLOCKER`.
cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
echo "some cycle review reasoning"
echo "CYCLE_REVIEW_DECISION: BLOCKER"
SH
chmod +x "$BIN/claude"

run_orch() {
  ( cd "$REPO" && \
    PATH="$BIN:$PATH" \
    RUN_ISSUES_AUTO=1 RUN_ISSUES_REVIEW_GATE=auto \
    RUN_ISSUES_CLAUDE_CMD="$BIN/claude" \
    RUN_ISSUES_LOCK_ROOT="$WORK/locks" \
    RUN_ISSUES_ENV_FILE="$WORK/no-such-env" \
    "$@" )
}

: > "$GH_LOG"
set +e
OUT=$(run_orch "$ORCH" "$REPO" 43 2>&1)
RC=$?
set -e
echo "--- cycle_review_blocker (rc=$RC) ---"; echo "$OUT" | tail -5

RD=$(ls -d "$REPO"/.claude/run-issues/*-issue-43 2>/dev/null | tail -1)
if [ -z "$RD" ] || [ ! -f "$RD/run.json" ]; then
  echo "FAIL: issue-43 run-dir not found"; FAIL=1
else
  [ "$RC" = "4" ] || { echo "FAIL: expected exit 4, got $RC"; FAIL=1; }
  ST=$(jq -r '.status' "$RD/run.json")
  RE=$(jq -r '.blocked_reason' "$RD/run.json")
  [ "$ST" = "blocked" ] || { echo "FAIL: status='$ST' (want blocked)"; FAIL=1; }
  # reason is cycle_review_<DECISION>; the comment kind is the lowercase literal.
  [ "$RE" = "cycle_review_BLOCKER" ] || { echo "FAIL: blocked_reason='$RE' (want cycle_review_BLOCKER)"; FAIL=1; }
  # The fix: the terminal blocker attaches a filterable needs-human label...
  grep -qF 'labels[]=needs-human' "$GH_LOG" \
    || { echo "FAIL: needs-human label not attempted (silent blocker regression)"; FAIL=1; }
  # ...alongside the situation comment that already existed.
  grep -q 'issue comment' "$GH_LOG" || { echo "FAIL: situation comment not posted"; FAIL=1; }
fi
[ "$FAIL" = "0" ] && echo "PASS: cycle_review_blocker -> blocked + needs-human label + comment + exit 4"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "cycle-review-blocker-label: all passed" || echo "cycle-review-blocker-label: FAILURES"
[ "$FAIL" -eq 0 ]
