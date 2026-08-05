#!/usr/bin/env bash
# test-pr-watch-ci-repair.sh — P5b AI CI-repair path (issue #25).
#
# Mirrors the conflict-resolution tests but for a RED CI: a labelled, mergeable
# PR whose required check failed (mergeStateStatus BLOCKED) => pr_decide returns
# FIX_CI when repair is ON. Three scenarios, each with a mocked `gh` payload and
# a mocked claude agent — no network, SKIP if jq is unavailable:
#
#   A) success   — agent commits a fix, CI revalidates GREEN => merge, exit 0.
#   B) cap       — the run-dir already records one pr_ci_repair_attempted and
#                  PR_WATCH_MAX_CI_REPAIRS=1, so the attempt cap is spent: the PR
#                  is handed to a human WITHOUT invoking the agent, exit 8.
#   C) handover  — agent commits a fix but CI stays RED on revalidation => PR
#                  handed to a human (needs-human label + comment), exit 8.
#
# Runs use a FOREIGN host so P9 local cleanup is skipped and the run-dir +
# state.jsonl survive for assertions (the merge itself is host-independent).
#
# Run: bash tests/test-pr-watch-ci-repair.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRWATCH="$HERE/../pr-watch.sh"
STATE_LIB="$HERE/../lib/state.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available"
  exit 0
fi

FAIL=0

# build_repo <work> — origin + repo + feature worktree; echoes "REPO WT ORIGIN".
build_repo() {
  local work="$1"
  local origin="$work/origin.git" repo="$work/repo"
  git init -q --bare "$origin"
  git init -q "$repo"
  (
    cd "$repo"
    git config user.email t@t.t; git config user.name t
    git remote add origin "$origin"
    echo "v0" > f.txt
    git add f.txt; git commit -qm init
    git branch -M main
    git push -q origin main
    git checkout -q -b feature/x
    echo "feature (buggy)" > f.txt
    git commit -qam feature
    git push -q origin feature/x
    git checkout -q main   # leave the repo off feature/x so the worktree can claim it
  )
  local wt="$work/wt-feature"
  ( cd "$repo" && git worktree add -q "$wt" feature/x )
  printf '%s %s %s' "$repo" "$wt" "$origin"
}

# seed_run <repo> <wt> <rid> <issue> <pr> — completed run.json, FOREIGN host.
seed_run() {
  local repo="$1" wt="$2" rid="$3" issue="$4" pr="$5"
  local rd="$repo/.claude/run-issues/$rid"
  # shellcheck source=../lib/state.sh
  . "$STATE_LIB"
  state_init "$rd" "$rid" "$repo" "$issue"
  state_set "$rd" "pr_url" "https://github.com/Silon-Oy/x/pull/$pr"
  state_set "$rd" "worktree_path" "$wt"
  state_set "$rd" "branch" "feature/x"
  local tmp; tmp=$(mktemp); jq '.host = "some-other-host"' "$rd/run.json" > "$tmp"; mv "$tmp" "$rd/run.json"
  state_finalize "$rd" "completed"
  printf '%s' "$rd"
}

# A red, BLOCKED, labelled PR payload (=> FIX_CI when repair is ON).
PR_VIEW_RED='{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED",
 "labels":[{"name":"auto-merge"}],
 "statusCheckRollup":[{"__typename":"CheckRun","name":"e2e","status":"COMPLETED","conclusion":"FAILURE"}],
 "headRefName":"feature/x","baseRefName":"main"}'

# ===========================================================================
# Scenario A — success: agent commits a fix, CI revalidates green, PR merges.
# ===========================================================================
echo "=== scenario A: success ==="
WORK_A=$(mktemp -d -t prwatch-cirepair-A.XXXXXX)
read -r REPO WT ORIGIN <<<"$(build_repo "$WORK_A")"
RD=$(seed_run "$REPO" "$WT" "20260521-1500-issue-77" "77" "777")

BIN="$WORK_A/bin"; mkdir -p "$BIN"
MERGE_FLAG="$WORK_A/merge_called"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
case "\$1" in
  api) exit 0 ;;                       # label writes — not expected here
esac
case "\$1 \$2" in
  "pr view")   cat <<'JSON'
$PR_VIEW_RED
JSON
    ;;
  "run list")  echo '[{"databaseId":9001,"conclusion":"failure"}]' ;;
  "run view")  echo "e2e failed: expected visible, got hidden" ;;
  "pr checks") exit 0 ;;               # GREEN after the fix
  "pr merge")  touch "$MERGE_FLAG"; echo "merged (mock)" ;;
  "pr comment") cat > /dev/null ;;
  "issue view") echo '{"state":"CLOSED"}' ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN/gh"

# claude mock: fix the bug and COMMIT (runs with the worktree as CWD).
CLAUDE_A="$WORK_A/bin/claude-mock"
cat > "$CLAUDE_A" <<'SH'
#!/usr/bin/env bash
set -e
echo "fixed (real change)" > f.txt
git add f.txt
git -c user.email=ci@t.t -c user.name=ci commit -qm "fix: make e2e pass"
echo "CI_REPAIR_RESULT: FIXED"
SH
chmod +x "$CLAUDE_A"

set +e
OUT=$( PATH="$BIN:$PATH" \
  RUN_ISSUES_LOCK_ROOT="$WORK_A/locks" \
  PR_WATCH_ENABLE_CI_REPAIR=1 \
  PR_WATCH_MAX_CI_REPAIRS=1 \
  RUN_ISSUES_CLAUDE_CMD="$CLAUDE_A" \
  PR_WATCH_CI_REPAIR_TIMEOUT=30 \
  "$PRWATCH" "$REPO" 777 2>&1 )
RC=$?
set -e
echo "$OUT" | sed 's/^/A| /'
echo "A| (rc=$RC)"

[ "$RC" = "0" ] || { echo "FAIL A: expected rc 0, got $RC"; FAIL=1; }
[ -f "$MERGE_FLAG" ] || { echo "FAIL A: gh pr merge not called"; FAIL=1; }
PUSHED=$( git --git-dir="$ORIGIN" show feature/x:f.txt 2>/dev/null || echo "" )
[ "$PUSHED" = "fixed (real change)" ] || { echo "FAIL A: origin not the fixed content (got '$PUSHED')"; FAIL=1; }
grep -q '"event":"pr_ci_repair_attempted"' "$RD/state.jsonl" || { echo "FAIL A: no pr_ci_repair_attempted"; FAIL=1; }
grep -q '"event":"pr_ci_repair_committed"' "$RD/state.jsonl" || { echo "FAIL A: no pr_ci_repair_committed"; FAIL=1; }
grep -q '"event":"pr_ci_repaired"' "$RD/state.jsonl" || { echo "FAIL A: no pr_ci_repaired"; FAIL=1; }
grep -q '"event":"pr_ci_repair_handover"' "$RD/state.jsonl" && { echo "FAIL A: unexpected handover"; FAIL=1; }
[ "$(jq -r '.status' "$RD/run.json")" = "merged" ] || { echo "FAIL A: status not merged"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS A: success path merged"
rm -rf "$WORK_A"

# ===========================================================================
# Scenario B — attempt cap already spent: hand to human, do NOT run the agent.
# ===========================================================================
echo "=== scenario B: attempt cap ==="
FAIL_B=0
WORK_B=$(mktemp -d -t prwatch-cirepair-B.XXXXXX)
read -r REPO WT ORIGIN <<<"$(build_repo "$WORK_B")"
RD=$(seed_run "$REPO" "$WT" "20260521-1600-issue-88" "88" "888")
# Pre-seed one prior attempt so attempts(1) >= max(1).
. "$STATE_LIB"
state_event "$RD" "pr_ci_repair_attempted" "pr=888" "attempt=1"

BIN="$WORK_B/bin"; mkdir -p "$BIN"
LABELS_LOG="$WORK_B/labels.log"; : > "$LABELS_LOG"
COMMENT_FLAG="$WORK_B/comment_called"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
case "\$1" in
  api) printf '%s\n' "\$*" >> "$LABELS_LOG"; exit 0 ;;
esac
case "\$1 \$2" in
  "pr view")   cat <<'JSON'
$PR_VIEW_RED
JSON
    ;;
  "pr comment") cat > /dev/null; touch "$COMMENT_FLAG" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN/gh"

# The agent must never be called; make it fail loudly if it is.
CLAUDE_B="$WORK_B/bin/claude-mock"
cat > "$CLAUDE_B" <<'SH'
#!/usr/bin/env bash
echo "AGENT-SHOULD-NOT-RUN" > "$(dirname "$0")/../agent_ran"
git -c user.email=x@x.x -c user.name=x commit --allow-empty -qm nope
exit 0
SH
chmod +x "$CLAUDE_B"

HEAD_BEFORE=$( cd "$WT" && git rev-parse HEAD )
set +e
OUT=$( PATH="$BIN:$PATH" \
  RUN_ISSUES_LOCK_ROOT="$WORK_B/locks" \
  PR_WATCH_ENABLE_CI_REPAIR=1 \
  PR_WATCH_MAX_CI_REPAIRS=1 \
  RUN_ISSUES_CLAUDE_CMD="$CLAUDE_B" \
  "$PRWATCH" "$REPO" 888 2>&1 )
RC=$?
set -e
echo "$OUT" | sed 's/^/B| /'
echo "B| (rc=$RC)"

[ "$RC" = "8" ] || { echo "FAIL B: expected rc 8, got $RC"; FAIL_B=1; }
[ ! -f "$WORK_B/agent_ran" ] || { echo "FAIL B: agent ran despite cap"; FAIL_B=1; }
[ "$( cd "$WT" && git rev-parse HEAD )" = "$HEAD_BEFORE" ] || { echo "FAIL B: branch moved despite cap"; FAIL_B=1; }
grep -q 'labels\[\]=needs-human' "$LABELS_LOG" || { echo "FAIL B: needs-human label not attempted"; FAIL_B=1; }
[ -f "$COMMENT_FLAG" ] || { echo "FAIL B: PR not commented"; FAIL_B=1; }
grep -q '"event":"pr_ci_repair_handover"' "$RD/state.jsonl" || { echo "FAIL B: no handover event"; FAIL_B=1; }
[ "$(jq -r '.status' "$RD/run.json")" = "blocked" ] || { echo "FAIL B: status not blocked"; FAIL_B=1; }
# Exactly one attempt event (the pre-seeded one) — the capped call must not add another.
[ "$(grep -c '"event":"pr_ci_repair_attempted"' "$RD/state.jsonl")" = "1" ] || { echo "FAIL B: attempt count changed under cap"; FAIL_B=1; }
[ "$FAIL_B" = "0" ] && echo "PASS B: cap handed to human without an agent run"
[ "$FAIL_B" = "0" ] || FAIL=1
rm -rf "$WORK_B"

# ===========================================================================
# Scenario C — agent commits a fix but CI stays RED => hand to human, exit 8.
# ===========================================================================
echo "=== scenario C: CI red after fix ==="
FAIL_C=0
WORK_C=$(mktemp -d -t prwatch-cirepair-C.XXXXXX)
read -r REPO WT ORIGIN <<<"$(build_repo "$WORK_C")"
RD=$(seed_run "$REPO" "$WT" "20260521-1700-issue-99" "99" "999")

BIN="$WORK_C/bin"; mkdir -p "$BIN"
LABELS_LOG="$WORK_C/labels.log"; : > "$LABELS_LOG"
COMMENT_FLAG="$WORK_C/comment_called"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
case "\$1" in
  api) printf '%s\n' "\$*" >> "$LABELS_LOG"; exit 0 ;;
esac
case "\$1 \$2" in
  "pr view")   cat <<'JSON'
$PR_VIEW_RED
JSON
    ;;
  "run list")  echo '[{"databaseId":9002,"conclusion":"failure"}]' ;;
  "run view")  echo "e2e still failing" ;;
  "pr checks") echo "e2e   fail"; exit 1 ;;    # stays RED on revalidation
  "pr comment") cat > /dev/null; touch "$COMMENT_FLAG" ;;
  "pr merge")  touch "$WORK_C/merge_called" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN/gh"

CLAUDE_C="$WORK_C/bin/claude-mock"
cat > "$CLAUDE_C" <<'SH'
#!/usr/bin/env bash
set -e
echo "attempted fix" > f.txt
git add f.txt
git -c user.email=ci@t.t -c user.name=ci commit -qm "fix attempt"
echo "CI_REPAIR_RESULT: FIXED"
SH
chmod +x "$CLAUDE_C"

set +e
OUT=$( PATH="$BIN:$PATH" \
  RUN_ISSUES_LOCK_ROOT="$WORK_C/locks" \
  PR_WATCH_ENABLE_CI_REPAIR=1 \
  PR_WATCH_MAX_CI_REPAIRS=1 \
  RUN_ISSUES_CLAUDE_CMD="$CLAUDE_C" \
  PR_WATCH_CI_REPAIR_TIMEOUT=30 \
  PR_WATCH_CI_MAX_POLLS=1 PR_WATCH_CI_POLL_SECS=1 \
  "$PRWATCH" "$REPO" 999 2>&1 )
RC=$?
set -e
echo "$OUT" | sed 's/^/C| /'
echo "C| (rc=$RC)"

[ "$RC" = "8" ] || { echo "FAIL C: expected rc 8, got $RC"; FAIL_C=1; }
[ ! -f "$WORK_C/merge_called" ] || { echo "FAIL C: merged despite red CI"; FAIL_C=1; }
grep -q '"event":"pr_ci_repair_committed"' "$RD/state.jsonl" || { echo "FAIL C: no committed event"; FAIL_C=1; }
grep -q '"event":"pr_ci_repaired"' "$RD/state.jsonl" && { echo "FAIL C: unexpected pr_ci_repaired on red CI"; FAIL_C=1; }
grep -q '"event":"pr_ci_repair_handover"' "$RD/state.jsonl" || { echo "FAIL C: no handover event"; FAIL_C=1; }
grep -q 'labels\[\]=needs-human' "$LABELS_LOG" || { echo "FAIL C: needs-human label not attempted"; FAIL_C=1; }
[ -f "$COMMENT_FLAG" ] || { echo "FAIL C: PR not commented"; FAIL_C=1; }
[ "$(jq -r '.status' "$RD/run.json")" = "blocked" ] || { echo "FAIL C: status not blocked"; FAIL_C=1; }
[ "$FAIL_C" = "0" ] && echo "PASS C: red-after-fix handed to human"
[ "$FAIL_C" = "0" ] || FAIL=1
rm -rf "$WORK_C"

# ===========================================================================
# Scenario D — agent makes NO commit: a failed attempt that consumes the cap
# and hands to a human WITHOUT pushing or looping (edge case "korjaus ei muuta
# mitään"). The next invocation would hit the cap; here we assert one attempt
# was recorded, the branch was not pushed, and CI was never revalidated.
# ===========================================================================
echo "=== scenario D: agent made no commit ==="
FAIL_D=0
WORK_D=$(mktemp -d -t prwatch-cirepair-D.XXXXXX)
read -r REPO WT ORIGIN <<<"$(build_repo "$WORK_D")"
RD=$(seed_run "$REPO" "$WT" "20260521-1800-issue-66" "66" "666")

BIN="$WORK_D/bin"; mkdir -p "$BIN"
LABELS_LOG="$WORK_D/labels.log"; : > "$LABELS_LOG"
COMMENT_FLAG="$WORK_D/comment_called"
CHECKS_FLAG="$WORK_D/checks_called"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
case "\$1" in
  api) printf '%s\n' "\$*" >> "$LABELS_LOG"; exit 0 ;;
esac
case "\$1 \$2" in
  "pr view")   cat <<'JSON'
$PR_VIEW_RED
JSON
    ;;
  "run list")  echo '[{"databaseId":9003,"conclusion":"failure"}]' ;;
  "run view")  echo "e2e failing" ;;
  "pr checks") touch "$CHECKS_FLAG"; exit 0 ;;   # must NOT be reached
  "pr comment") cat > /dev/null; touch "$COMMENT_FLAG" ;;
  "pr merge")  touch "$WORK_D/merge_called" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN/gh"

# claude mock that does nothing: no commit, clean worktree left as-is.
CLAUDE_D="$WORK_D/bin/claude-mock"
cat > "$CLAUDE_D" <<'SH'
#!/usr/bin/env bash
echo "CI_REPAIR_RESULT: UNRESOLVED — mock cannot fix"
exit 0
SH
chmod +x "$CLAUDE_D"

ORIGIN_TIP_BEFORE=$( git --git-dir="$ORIGIN" rev-parse feature/x )
set +e
OUT=$( PATH="$BIN:$PATH" \
  RUN_ISSUES_LOCK_ROOT="$WORK_D/locks" \
  PR_WATCH_ENABLE_CI_REPAIR=1 \
  PR_WATCH_MAX_CI_REPAIRS=1 \
  RUN_ISSUES_CLAUDE_CMD="$CLAUDE_D" \
  PR_WATCH_CI_REPAIR_TIMEOUT=30 \
  "$PRWATCH" "$REPO" 666 2>&1 )
RC=$?
set -e
echo "$OUT" | sed 's/^/D| /'
echo "D| (rc=$RC)"

[ "$RC" = "8" ] || { echo "FAIL D: expected rc 8, got $RC"; FAIL_D=1; }
[ ! -f "$WORK_D/merge_called" ] || { echo "FAIL D: merged despite no fix"; FAIL_D=1; }
[ ! -f "$CHECKS_FLAG" ] || { echo "FAIL D: CI revalidated despite no commit (should short-circuit)"; FAIL_D=1; }
[ "$( git --git-dir="$ORIGIN" rev-parse feature/x )" = "$ORIGIN_TIP_BEFORE" ] || { echo "FAIL D: origin branch moved despite no commit"; FAIL_D=1; }
# Exactly one attempt recorded — the cap is consumed so the next poll won't loop.
[ "$(grep -c '"event":"pr_ci_repair_attempted"' "$RD/state.jsonl")" = "1" ] || { echo "FAIL D: attempt not recorded exactly once"; FAIL_D=1; }
grep -q '"event":"pr_ci_repair_committed"' "$RD/state.jsonl" && { echo "FAIL D: unexpected committed event"; FAIL_D=1; }
grep -q '"event":"pr_ci_repair_handover"' "$RD/state.jsonl" || { echo "FAIL D: no handover event"; FAIL_D=1; }
[ -f "$COMMENT_FLAG" ] || { echo "FAIL D: PR not commented"; FAIL_D=1; }
[ "$FAIL_D" = "0" ] && echo "PASS D: no-commit consumed the cap, no push, no loop"
[ "$FAIL_D" = "0" ] || FAIL=1
rm -rf "$WORK_D"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "pr-watch-ci-repair: all passed" || echo "pr-watch-ci-repair: FAILURES"
[ "$FAIL" -eq 0 ]
