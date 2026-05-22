#!/usr/bin/env bash
# test-clarification-loop-cap.sh — the clarification loop terminates.
#
# When an awaiting_clarification run is continued but its clarification_round has
# already reached RUN_ISSUES_MAX_CLARIFICATIONS, continue_load_state must NOT
# re-run cycle-review. Instead it hands the issue to a human:
#   - status -> blocked, reason clarification_loop_exhausted
#   - waiting label removed
#   - needs-human label attempted
#   - exit 0 (terminal, not an error)
#
# This is the invariant that prevents an infinite ask/answer ping-pong.
#
# gh + claude + git mocked via PATH shims. No network.
#
# Run: bash tests/test-clarification-loop-cap.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$HERE/../orchestrate.sh"
STATE_LIB="$HERE/../lib/state.sh"
ISSUE_LIB="$HERE/../lib/issue.sh"

WORK=$(mktemp -d -t clar-cap.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
git -C "$WORK" init -q "repo"

BIN="$WORK/bin"
mkdir -p "$BIN"

GH_LOG="$WORK/gh-calls.log"
ISSUE_FIXTURE="$WORK/issue-fixture.json"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"
case "\$1 \$2" in
  "issue view") cat "$ISSUE_FIXTURE" ;;
  *) : ;;
esac
exit 0
SH
chmod +x "$BIN/gh"

# claude mock that, if ever called, would PROCEED — proving the cap branch runs
# BEFORE any cycle-review (the run must be handed off without invoking claude).
CLAUDE_LOG="$WORK/claude-calls.log"
cat > "$BIN/claude" <<SH
#!/usr/bin/env bash
echo "called" >> "$CLAUDE_LOG"
echo "CYCLE_REVIEW_DECISION: PROCEED"
SH
chmod +x "$BIN/claude"

# shellcheck source=lib/state.sh
. "$STATE_LIB"
# shellcheck source=lib/issue.sh
. "$ISSUE_LIB"

make_worktree() {
  local wt="$1"
  git -C "$WORK" init -q "$(basename "$wt")"
  ( cd "$wt"; git config user.email t@t; git config user.name t
    git commit -q --allow-empty -m base )
}

run_orch() {
  ( cd "$REPO" && PATH="$BIN:$PATH" RUN_ISSUES_AUTO=1 \
    RUN_ISSUES_REVIEW_GATE=auto \
    RUN_ISSUES_CLAUDE_CMD="$BIN/claude" \
    RUN_ISSUES_LOCK_ROOT="$WORK/locks" "$@" )
}

# Seed a run already AT the cap (round == MAX == 3).
RID="20260521-1800-issue-9"
RD="$REPO/.claude/run-issues/$RID"
WT="$WORK/wt"; make_worktree "$WT"
state_init "$RD" "$RID" "$REPO" "9"
state_set "$RD" "branch" "auto-run/issue-9-x"
state_set "$RD" "worktree_path" "$WT"
tmp=$(mktemp); jq '.clarification_round = 3' "$RD/run.json" > "$tmp"; mv "$tmp" "$RD/run.json"
echo '{"title":"t","body":"b","comments":[]}' > "$RD/issue.json"
echo "ok" > "$RD/01-cycle-review.out"
state_finalize "$RD" "awaiting_clarification"

# A fixture with a real reply, so the ONLY thing stopping a continue is the cap.
MARKER=$(build_marker "$RID" 9 "2026-05-21T10:00:00Z" 3)
jq -n --arg marker "$MARKER" '{
  title:"t", body:"b",
  comments:[
    { author:{login:"maintainer"}, createdAt:"2026-05-21T10:00:00Z", body:($marker+"\n## tarkennus") },
    { author:{login:"maintainer"}, createdAt:"2026-05-21T10:05:00Z", body:"vastaus joka ei silti riitä" }
  ]
}' > "$ISSUE_FIXTURE"

: > "$GH_LOG"; : > "$CLAUDE_LOG"

set +e
OUT=$(run_orch env RUN_ISSUES_MAX_CLARIFICATIONS=3 "$ORCH" --continue "$RD" 2>&1)
RC=$?
set -e
echo "--- loop cap (rc=$RC) ---"; echo "$OUT" | tail -4

FAIL=0
[ "$RC" = "0" ] || { echo "FAIL: expected exit 0, got $RC"; FAIL=1; }
ST=$(jq -r '.status' "$RD/run.json")
RE=$(jq -r '.blocked_reason' "$RD/run.json")
[ "$ST" = "blocked" ] || { echo "FAIL: status='$ST' (want blocked)"; FAIL=1; }
[ "$RE" = "clarification_loop_exhausted" ] || { echo "FAIL: reason='$RE'"; FAIL=1; }
grep -q 'add-label needs-human' "$GH_LOG" || { echo "FAIL: needs-human label not attempted"; FAIL=1; }
grep -q 'remove-label waiting' "$GH_LOG" || { echo "FAIL: waiting label not removed"; FAIL=1; }
[ ! -s "$CLAUDE_LOG" ] || { echo "FAIL: claude was invoked despite cap (loop not short-circuited)"; FAIL=1; }
[ "$(jq -r '.clarification_round' "$RD/run.json")" = "3" ] || { echo "FAIL: round changed at cap"; FAIL=1; }

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "clarification-loop-cap: all passed" || echo "clarification-loop-cap: FAILURES"
[ "$FAIL" -eq 0 ]
