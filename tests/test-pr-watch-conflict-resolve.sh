#!/usr/bin/env bash
# test-pr-watch-conflict-resolve.sh — P5 AI conflict resolution SUCCESS path.
#
# Same diverged repo as the abort test, but here the mocked claude agent
# RESOLVES the conflict in the worktree and completes the rebase. pr-watch must
# then: verify the worktree is clean + fully rebased, force-push the branch,
# revalidate CI (mocked green), and proceed to merge (mocked) — exit 0.
#
# The run uses a FOREIGN host so P9 local cleanup is skipped and the run-dir +
# state.jsonl survive for assertions (the merge itself is unaffected — the host
# gate only governs local cleanup, decision 4).
#
# Run: bash tests/test-pr-watch-conflict-resolve.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRWATCH="$HERE/../pr-watch.sh"
STATE_LIB="$HERE/../lib/state.sh"

WORK=$(mktemp -d -t prwatch-resolve.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# --- remote (origin) + feature worktree, real divergence -----------------
ORIGIN="$WORK/origin.git"
REPO="$WORK/repo"
git init -q --bare "$ORIGIN"
# Force `main` regardless of the machine's init.defaultBranch.
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q "$REPO"
git -C "$REPO" symbolic-ref HEAD refs/heads/main
(
  cd "$REPO"
  git config user.email t@t.t; git config user.name t
  git remote add origin "$ORIGIN"
  echo "line v0" > f.txt
  git add f.txt; git commit -qm init
  git push -q origin main
  git checkout -q -b feature/x
  echo "line FEATURE" > f.txt
  git commit -qam feature
  git push -q origin feature/x
  git checkout -q main
  echo "line MAIN" > f.txt
  git commit -qam mainmove
  git push -q origin main
)

WT="$WORK/wt-feature"
( cd "$REPO" && git worktree add -q "$WT" feature/x )

# --- gh mock (records merge; reports CI green) ---------------------------
BIN="$WORK/bin"; mkdir -p "$BIN"
MERGE_FLAG="$WORK/merge_called"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
case "\$1 \$2" in
  "pr view")
    cat <<'JSON'
{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"BEHIND",
 "labels":[{"name":"auto-merge"}],"statusCheckRollup":[],"headRefName":"feature/x"}
JSON
    ;;
  "pr checks")
    exit 0   # all checks green
    ;;
  "pr merge")
    touch "$MERGE_FLAG"
    echo "merged (mock)"
    ;;
  "pr comment")
    cat > /dev/null
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN/gh"

# --- claude mock that RESOLVES the conflict and finishes the rebase ------
# Runs with the worktree as CWD (call_claude is invoked from inside it).
CLAUDE_MOCK="$WORK/bin/claude-mock"
cat > "$CLAUDE_MOCK" <<'SH'
#!/usr/bin/env bash
set -e
# Merge intent of both sides into a durable resolution, then complete rebase.
echo "line RESOLVED (feature + main)" > f.txt
git add f.txt
GIT_EDITOR=true git rebase --continue
echo "CONFLICT_RESOLUTION_RESULT: RESOLVED"
SH
chmod +x "$CLAUDE_MOCK"

# --- completed run.json, FOREIGN host so cleanup is skipped --------------
RID="20260521-1400-issue-99"
RD="$REPO/.claude/run-issues/$RID"
# shellcheck source=../lib/state.sh
. "$STATE_LIB"
state_init "$RD" "$RID" "$REPO" "99"
state_set "$RD" "pr_url" "https://github.com/Silon-Oy/dotfiles/pull/999"
state_set "$RD" "worktree_path" "$WT"
state_set "$RD" "branch" "feature/x"
tmp=$(mktemp); jq '.host = "some-other-host"' "$RD/run.json" > "$tmp"; mv "$tmp" "$RD/run.json"
state_finalize "$RD" "completed"

export PATH="$BIN:$PATH"
export RUN_ISSUES_LOCK_ROOT="$WORK/locks"
export PR_WATCH_ENABLE_CONFLICT_RESOLUTION=1
export RUN_ISSUES_CLAUDE_CMD="$CLAUDE_MOCK"
export PR_WATCH_CONFLICT_TIMEOUT=30

set +e
OUT=$( "$PRWATCH" "$REPO" 999 2>&1 )
RC=$?
set -e
echo "--- pr-watch output ---"; echo "$OUT"; echo "--- (rc=$RC) ---"

FAIL=0
[ "$RC" = "0" ] || { echo "FAIL expected rc 0, got $RC"; FAIL=1; }
[ -f "$MERGE_FLAG" ] || { echo "FAIL gh pr merge was not called"; FAIL=1; }
# The AI resolution must have been published to origin (force-pushed).
PUSHED=$( git --git-dir="$ORIGIN" show feature/x:f.txt 2>/dev/null || echo "" )
[ "$PUSHED" = "line RESOLVED (feature + main)" ] || { echo "FAIL origin feature/x not the resolved content (got: '$PUSHED')"; FAIL=1; }
# The rebased branch tip must descend from origin/main (rebase landed).
if ( cd "$WT" && git merge-base --is-ancestor origin/main HEAD ); then
  echo "PASS rebase landed on origin/main"
else
  echo "FAIL rebase did not land on origin/main"; FAIL=1
fi
grep -q '"event":"pr_conflict_resolution_started"' "$RD/state.jsonl" || { echo "FAIL no pr_conflict_resolution_started event"; FAIL=1; }
grep -q '"event":"pr_conflict_resolved"' "$RD/state.jsonl" || { echo "FAIL no pr_conflict_resolved event"; FAIL=1; }
grep -q '"event":"pr_rebased"' "$RD/state.jsonl" || { echo "FAIL no pr_rebased event"; FAIL=1; }
grep -q '"event":"pr_merged"' "$RD/state.jsonl" || { echo "FAIL no pr_merged event"; FAIL=1; }
[ "$(jq -r '.status' "$RD/run.json")" = "merged" ] || { echo "FAIL status not merged"; FAIL=1; }

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "pr-watch-conflict-resolve: all passed" || echo "pr-watch-conflict-resolve: FAILURES"
[ "$FAIL" -eq 0 ]
