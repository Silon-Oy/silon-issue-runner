#!/usr/bin/env bash
# test-pr-watch-conflict-abort.sh — P5 rebase conflict path.
#
# Builds a real local git repo where the feature branch and main diverge on
# the same line, so `git rebase origin/main` conflicts. With conflict
# resolution ON, pr-watch must: abort the rebase, leave the worktree clean,
# record status=pr_conflicted, comment the PR (mocked gh), and exit 6.
#
# `gh` is mocked: pr view reports a labelled BEHIND PR (=> REBASE decision);
# pr comment just records that it was called.
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
git init -q "$REPO"
(
  cd "$REPO"
  git config user.email t@t.t; git config user.name t
  git remote add origin "$ORIGIN"
  echo "line v0" > f.txt
  git add f.txt; git commit -qm init
  git branch -M main
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
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
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

set +e
OUT=$( "$PRWATCH" "$REPO" 888 2>&1 )
RC=$?
set -e
echo "--- pr-watch output ---"; echo "$OUT"; echo "--- (rc=$RC) ---"

FAIL=0
[ "$RC" = "6" ] || { echo "FAIL expected rc 6, got $RC"; FAIL=1; }
# Worktree must be clean (no rebase in progress, no merge markers).
if [ -d "$WT/.git" ] || git -C "$REPO" -C "$WT" rev-parse --git-dir >/dev/null 2>&1; then :; fi
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
[ "$(jq -r '.status' "$RD/run.json")" = "pr_conflicted" ] || { echo "FAIL status not pr_conflicted"; FAIL=1; }
grep -q '"event":"pr_conflicted"' "$RD/state.jsonl" || { echo "FAIL no pr_conflicted event"; FAIL=1; }
[ -f "$COMMENT_FLAG" ] || { echo "FAIL gh pr comment was not called"; FAIL=1; }

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "pr-watch-conflict-abort: all passed" || echo "pr-watch-conflict-abort: FAILURES"
[ "$FAIL" -eq 0 ]
