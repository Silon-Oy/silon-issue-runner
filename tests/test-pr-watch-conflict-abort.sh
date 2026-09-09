#!/usr/bin/env bash
# test-pr-watch-conflict-abort.sh — P5 AI conflict resolution FAILURE path.
#
# Builds a real local git repo where the feature branch and main diverge on
# the same line, so `git rebase origin/main` conflicts. With conflict
# resolution ON, pr-watch hands the conflict to the AI agent (mocked claude).
# Here the agent FAILS to resolve — it leaves the rebase in progress. pr-watch
# must then: abort the rebase, leave the worktree clean, record
# status=pr_conflicted, comment the PR (mocked gh), and exit 6.
#
# `gh` is mocked: pr view reports a labelled BEHIND PR (=> REBASE decision);
# pr comment just records that it was called. `claude` is mocked via
# RUN_ISSUES_CLAUDE_CMD to a script that does NOT resolve the conflict.
#
# Run: bash tests/test-pr-watch-conflict-abort.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRWATCH="$HERE/../pr-watch.sh"
STATE_LIB="$HERE/../lib/state.sh"

WORK=$(mktemp -d -t prwatch-conflict.XXXXXX)
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
  # feature branch diverges on the SAME line
  git checkout -q -b feature/x
  echo "line FEATURE" > f.txt
  git commit -qam feature
  git push -q origin feature/x
  # main moves on the SAME line -> guaranteed rebase conflict
  git checkout -q main
  echo "line MAIN" > f.txt
  git commit -qam mainmove
  git push -q origin main
)

# Feature worktree (this is what pr-watch operates in).
WT="$WORK/wt-feature"
( cd "$REPO" && git worktree add -q "$WT" feature/x )

# --- gh mock -------------------------------------------------------------
BIN="$WORK/bin"; mkdir -p "$BIN"
COMMENT_FLAG="$WORK/comment_called"
LABELS_LOG="$WORK/labels.log"; : > "$LABELS_LOG"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
case "\$1" in
  api) printf '%s\n' "\$*" >> "$LABELS_LOG"; exit 0 ;;   # label writes
esac
case "\$1 \$2" in
  "pr view")
    cat <<'JSON'
{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"BEHIND",
 "labels":[{"name":"auto-merge"}],"statusCheckRollup":[],"headRefName":"feature/x"}
JSON
    ;;
  "pr comment")
    cat > /dev/null   # consume --body-file - stdin
    touch "$COMMENT_FLAG"
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN/gh"

# --- claude mock that CANNOT resolve (leaves the rebase in progress) -----
CLAUDE_MOCK="$WORK/bin/claude-mock"
cat > "$CLAUDE_MOCK" <<'SH'
#!/usr/bin/env bash
# Pretend the agent gave up: do not touch the conflicted files, do not
# continue the rebase. The watcher must detect the unclean state and abort.
echo "CONFLICT_RESOLUTION_RESULT: UNRESOLVED — mock cannot resolve"
exit 0
SH
chmod +x "$CLAUDE_MOCK"

# --- completed run.json pointing at the feature worktree -----------------
RID="20260521-1300-issue-88"
RD="$REPO/.claude/run-issues/$RID"
# shellcheck source=../lib/state.sh
. "$STATE_LIB"
state_init "$RD" "$RID" "$REPO" "88"
state_set "$RD" "pr_url" "https://github.com/Silon-Oy/dotfiles/pull/888"
state_set "$RD" "worktree_path" "$WT"
state_set "$RD" "branch" "feature/x"
state_finalize "$RD" "completed"

export PATH="$BIN:$PATH"
export RUN_ISSUES_LOCK_ROOT="$WORK/locks"
export PR_WATCH_ENABLE_CONFLICT_RESOLUTION=1
export RUN_ISSUES_CLAUDE_CMD="$CLAUDE_MOCK"
export PR_WATCH_CONFLICT_TIMEOUT=30

set +e
OUT=$( "$PRWATCH" "$REPO" 888 2>&1 )
RC=$?
set -e
echo "--- pr-watch output ---"; echo "$OUT"; echo "--- (rc=$RC) ---"

FAIL=0
[ "$RC" = "6" ] || { echo "FAIL expected rc 6, got $RC"; FAIL=1; }
# Worktree must be clean (no rebase in progress, no merge markers).
if ( cd "$WT" && git status --porcelain | grep -q '^UU' ); then
  echo "FAIL worktree still has conflict markers (abort failed)"; FAIL=1
else
  echo "PASS worktree clean after abort"
fi
if ( cd "$WT" && test -d "$(git rev-parse --git-path rebase-merge 2>/dev/null)" -o -d "$(git rev-parse --git-path rebase-apply 2>/dev/null)" ); then
  echo "FAIL rebase still in progress"; FAIL=1
else
  echo "PASS no rebase in progress"
fi
# Branch must be unchanged (still the original feature commit, base unchanged).
if ( cd "$WT" && git merge-base --is-ancestor origin/main HEAD ); then
  echo "FAIL branch was rebased despite unresolved conflict (base moved)"; FAIL=1
else
  echo "PASS branch left untouched (rebase aborted)"
fi
[ "$(jq -r '.status' "$RD/run.json")" = "pr_conflicted" ] || { echo "FAIL status not pr_conflicted"; FAIL=1; }
grep -q '"event":"pr_conflicted"' "$RD/state.jsonl" || { echo "FAIL no pr_conflicted event"; FAIL=1; }
grep -q '"event":"pr_conflict_resolution_started"' "$RD/state.jsonl" || { echo "FAIL no pr_conflict_resolution_started event"; FAIL=1; }
[ -f "$COMMENT_FLAG" ] || { echo "FAIL gh pr comment was not called"; FAIL=1; }
# Issue #276 symptom D: the conflict handover must be filterable — the same
# needs-human label the CI-repair path uses (shared _pr_mark_needs_human).
grep -q 'labels\[\]=needs-human' "$LABELS_LOG" || { echo "FAIL needs-human label not attached on conflict abort"; FAIL=1; }

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "pr-watch-conflict-abort: all passed" || echo "pr-watch-conflict-abort: FAILURES"
[ "$FAIL" -eq 0 ]
