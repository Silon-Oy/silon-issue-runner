#!/usr/bin/env bash
# test-pr-watch-conflict-ci-red.sh — P5 conflict path, ci_red_after_resolution.
#
# Issue #276, symptom D: when a rebase lands cleanly but CI stays RED on the
# revalidation, _pr_publish_and_revalidate hands the PR to a human. That handover
# used to post ONLY a PR comment — not filterable (CLAUDE.md §4). It must now
# attach the needs-human label through the SAME shared mechanism the CI-repair
# path uses (_pr_mark_needs_human), so the run is filterable and re-armable.
#
# Repo layout: the feature branch touches a DIFFERENT file than main's later
# move, so `git rebase origin/main` is conflict-free (rebase_rc=0) and takes the
# _pr_publish_and_revalidate branch directly. The revalidation `gh pr view
# --json statusCheckRollup` is mocked RED, so the merge is refused.
#
# Run: bash tests/test-pr-watch-conflict-ci-red.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRWATCH="$HERE/../pr-watch.sh"
STATE_LIB="$HERE/../lib/state.sh"

WORK=$(mktemp -d -t prwatch-ci-red.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

ORIGIN="$WORK/origin.git"
REPO="$WORK/repo"
git init -q --bare "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q "$REPO"
git -C "$REPO" symbolic-ref HEAD refs/heads/main
(
  cd "$REPO"
  git config user.email t@t.t; git config user.name t
  git remote add origin "$ORIGIN"
  echo "base" > f.txt
  git add f.txt; git commit -qm init
  git push -q origin main
  # feature branch touches a DIFFERENT file -> clean rebase onto a moved main.
  git checkout -q -b feature/x
  echo "feature work" > g.txt
  git add g.txt; git commit -qm feature
  git push -q origin feature/x
  # main moves on f.txt (a different file than g.txt) -> no conflict.
  git checkout -q main
  echo "main moved" > f.txt
  git commit -qam mainmove
  git push -q origin main
)

WT="$WORK/wt-feature"
( cd "$REPO" && git worktree add -q "$WT" feature/x )

# --- gh mock: classification BEHIND (=> REBASE); revalidation RED; label log ---
BIN="$WORK/bin"; mkdir -p "$BIN"
COMMENT_FLAG="$WORK/comment_called"
MERGE_FLAG="$WORK/merge_called"
LABELS_LOG="$WORK/labels.log"; : > "$LABELS_LOG"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
case "\$1" in
  api) printf '%s\n' "\$*" >> "$LABELS_LOG"; exit 0 ;;   # label writes
esac
case "\$1 \$2" in
  "pr view")
    # Classification (asks for mergeable) => BEHIND, triggers REBASE. Revalidation
    # (statusCheckRollup only) => RED, so the merge is refused after the rebase.
    if printf '%s' "\$*" | grep -q mergeable; then
      cat <<'JSON'
{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"BEHIND",
 "labels":[{"name":"auto-merge"}],"statusCheckRollup":[],"headRefName":"feature/x","baseRefName":"main"}
JSON
    else
      echo '{"statusCheckRollup":[{"__typename":"CheckRun","name":"e2e","status":"COMPLETED","conclusion":"FAILURE"}]}'
    fi
    ;;
  "pr comment") cat > /dev/null; touch "$COMMENT_FLAG" ;;
  "pr merge")   touch "$MERGE_FLAG" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN/gh"

RID="20260521-1900-issue-77"
RD="$REPO/.claude/run-issues/$RID"
# shellcheck source=../lib/state.sh
. "$STATE_LIB"
state_init "$RD" "$RID" "$REPO" "77"
state_set "$RD" "pr_url" "https://github.com/Silon-Oy/dotfiles/pull/777"
state_set "$RD" "worktree_path" "$WT"
state_set "$RD" "branch" "feature/x"
state_finalize "$RD" "completed"

export PATH="$BIN:$PATH"
export RUN_ISSUES_LOCK_ROOT="$WORK/locks"
export PR_WATCH_ENABLE_CONFLICT_RESOLUTION=1
export PR_WATCH_CI_MAX_POLLS=1 PR_WATCH_CI_POLL_SECS=1

set +e
OUT=$( "$PRWATCH" "$REPO" 777 2>&1 )
RC=$?
set -e
echo "--- pr-watch output ---"; echo "$OUT"; echo "--- (rc=$RC) ---"

FAIL=0
[ "$RC" = "6" ] || { echo "FAIL expected rc 6, got $RC"; FAIL=1; }
[ ! -f "$MERGE_FLAG" ] || { echo "FAIL merged despite red CI after rebase"; FAIL=1; }
[ -f "$COMMENT_FLAG" ] || { echo "FAIL PR not commented"; FAIL=1; }
# Symptom D: the ci_red_after_resolution handover must attach needs-human via the
# shared _pr_mark_needs_human (same mechanism as the CI-repair path).
grep -q 'labels\[\]=needs-human' "$LABELS_LOG" || { echo "FAIL needs-human label not attached on ci-red handover"; FAIL=1; }
[ "$(jq -r '.status' "$RD/run.json")" = "pr_conflicted" ] || { echo "FAIL status not pr_conflicted"; FAIL=1; }
[ "$(jq -r '.blocked_reason' "$RD/run.json")" = "ci_red_after_resolution_pr_777" ] || { echo "FAIL blocked_reason not ci_red_after_resolution_pr_777"; FAIL=1; }

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "pr-watch-conflict-ci-red: all passed" || echo "pr-watch-conflict-ci-red: FAILURES"
[ "$FAIL" -eq 0 ]
