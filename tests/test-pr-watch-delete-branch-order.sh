#!/usr/bin/env bash
# test-pr-watch-delete-branch-order.sh — a merged PR must not be reported as
# failed because a branch could not be deleted yet (issue #123).
#
# THE BUG THIS PINS
# -----------------
# P6 merged with `gh pr merge --delete-branch`. That flag deletes the LOCAL
# branch too, and at P6 the run's own worktree still holds it — the teardown
# that frees it is P9, three phases later. git refused, gh exited non-zero, and
# a merge that HAD succeeded was read as a failure: rc=5, the run labelled
# needs-human with nothing for a human to do, and P7 (post-merge migration),
# P8 (finalize + pr_merged), P8b (close the linked issue) and P9 (cleanup) all
# skipped. The worktree that caused the refusal was therefore never removed, so
# every auto-merge run left another one behind — 309 worktrees and 166.9 GB on
# one machine before this was traced.
#
# Two cases, and neither asserts a log line: they assert the outcome the bug
# destroyed, so they fail if the flag comes back under any wording.
#
#   (a) The gh mock refuses ANY `pr merge` carrying --delete-branch, exactly as
#       git refuses a branch a worktree holds. A watcher that still passes the
#       flag gets rc=5 and no teardown; the fixed one merges, deletes the REMOTE
#       branch on its own, finalizes merged and cleans the worktree away.
#   (b) The merge call errors AFTER the PR is already merged. The --merge
#       fallback exists for a branch GitHub will not rebase (issue #41), and
#       firing it here only produces "was already merged" — a second wrong
#       diagnosis. The watcher must ask what the PR is and continue.
#
# Case (a) runs on THIS host so P9 actually tears down (the host gate is what
# the sibling tests dodge with a foreign host); the assertion is that the
# worktree is gone afterwards.
#
# Run: bash tests/test-pr-watch-delete-branch-order.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRWATCH="$HERE/../pr-watch.sh"
STATE_LIB="$HERE/../lib/state.sh"
# The host recorded in run.json must come from the same primitive the watcher
# compares against, or the P9 gate reads this run as another machine's.
# shellcheck source=../lib/host.sh
. "$HERE/../lib/host.sh"

command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not installed";  exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

WORK=$(mktemp -d -t prwatch-delbranch.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; FAIL=1; }

# `set +e` before every watcher call, and it is not belt-and-braces: seed_run
# sources lib/state.sh, which sets -euo pipefail in THIS shell. A failing watcher
# would then exit the test at the call site with the watcher's own code — red,
# but with no output at all, which is the one thing a regression test must not
# do when it catches something.

# ---------------------------------------------------------------------------
# Fixture: a repo whose feature branch is held by a worktree, exactly as a run
# leaves it between S10 (push) and P9 (cleanup).
# ---------------------------------------------------------------------------
make_repo() {
  local dir="$1"
  local repo="$dir/repo" origin="$dir/origin.git" wt="$dir/wt"
  git init -q --bare "$origin"
  git init -q "$repo"
  (
    cd "$repo"
    git config user.email t@t.t; git config user.name t
    git remote add origin "$origin"
    echo v0 > f.txt
    git add f.txt; git commit -qm init
    git branch -M main
    git push -q origin main
    git branch feature/x
    git checkout -q main
  )
  ( cd "$repo" && git worktree add -q "$wt" feature/x )
}

seed_run() {
  local repo="$1" wt="$2" rid="$3" pr="$4" host="$5"
  local rd="$repo/.claude/run-issues/$rid"
  # shellcheck source=../lib/state.sh
  . "$STATE_LIB"
  state_init "$rd" "$rid" "$repo" "99"
  state_set "$rd" "pr_url" "https://github.com/o/repo/pull/$pr"
  state_set "$rd" "branch" "feature/x"
  state_set "$rd" "worktree_path" "$wt"
  local tmp; tmp=$(mktemp)
  jq --arg h "$host" '.host = $h' "$rd/run.json" > "$tmp" && mv "$tmp" "$rd/run.json"
  state_finalize "$rd" "completed"
}

# ---------------------------------------------------------------------------
# (a) --delete-branch is refused the way git refuses it
# ---------------------------------------------------------------------------
A="$WORK/a"; mkdir -p "$A"
make_repo "$A"
REPO_A="$A/repo"; WT_A="$A/wt"
seed_run "$REPO_A" "$WT_A" "20260521-1400-issue-99" 999 "$(runner_host)"

BIN_A="$A/bin"; mkdir -p "$BIN_A"
CALLS_A="$A/gh-calls.log"; : > "$CALLS_A"
cat > "$BIN_A/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS_A"
case "\$1 \$2" in
  "pr view")
    cat <<'JSON'
{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN",
 "labels":[{"name":"auto-merge"}],"statusCheckRollup":[],
 "headRefName":"feature/x","baseRefName":"main"}
JSON
    ;;
  "pr merge")
    for a in "\$@"; do
      if [ "\$a" = "--delete-branch" ]; then
        # git's own refusal, routed through gh exactly as it reaches the watcher.
        echo "failed to delete local branch feature/x: cannot delete branch 'feature/x' used by worktree at '$WT_A'" >&2
        exit 1
      fi
    done
    echo "merged (mock)"
    ;;
  "issue view") echo '{"state":"CLOSED"}' ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN_A/gh"

RD_A="$REPO_A/.claude/run-issues/20260521-1400-issue-99"
set +e
OUT_A=$(PATH="$BIN_A:$PATH" RUN_ISSUES_LOCK_ROOT="$A/locks" "$PRWATCH" "$REPO_A" 999 2>&1)
RC_A=$?
echo "--- (a) pr-watch rc=$RC_A ---"; printf '%s\n' "$OUT_A" | tail -8

[ "$RC_A" = "0" ] && ok "(a) merge with a held branch is not reported as a failure (rc 0)" \
  || bad "(a) rc=$RC_A — a successful merge was read as a failure"

grep -q -- '--delete-branch' "$CALLS_A" \
  && bad "(a) the merge still passes --delete-branch (the local branch is P9's to remove)" \
  || ok "(a) no --delete-branch on the merge call"

grep -q '^api --method DELETE repos/.*/git/refs/heads/feature/x' "$CALLS_A" \
  && ok "(a) the REMOTE branch is deleted on its own after the merge" \
  || bad "(a) the remote branch was never deleted — --delete-branch's other half went missing"

# P8: the run reaches finalize, which rc=5 used to skip.
if [ -d "$RD_A" ]; then
  bad "(a) run-dir survived — P9 cleanup did not run"
else
  ok "(a) P9 ran: the run-dir is gone"
fi

# P9's whole point: the worktree that held the branch is released.
[ -d "$WT_A" ] && bad "(a) worktree still on disk — this is the 166.9 GB leak" \
  || ok "(a) worktree removed"
( cd "$REPO_A" && git rev-parse --verify -q feature/x >/dev/null 2>&1 ) \
  && bad "(a) local branch feature/x still exists after cleanup" \
  || ok "(a) local branch deleted, after the worktree and not before"

# ---------------------------------------------------------------------------
# (b) the merge errors, but the PR is merged: no fallback, no failure
# ---------------------------------------------------------------------------
B="$WORK/b"; mkdir -p "$B"
make_repo "$B"
REPO_B="$B/repo"; WT_B="$B/wt"
# Foreign host: P9 is skipped, so the run-dir survives for the state assertions.
seed_run "$REPO_B" "$WT_B" "20260521-1400-issue-98" 998 "some-other-host"

BIN_B="$B/bin"; mkdir -p "$BIN_B"
CALLS_B="$B/gh-calls.log"; : > "$CALLS_B"
FLAG_B="$B/merged.flag"
cat > "$BIN_B/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS_B"
case "\$1 \$2" in
  "pr view")
    # The state-only probe the watcher makes after a failed merge call; the
    # classification read earlier asks for many fields and must still get them.
    for a in "\$@"; do
      if [ "\$a" = "--jq" ] && [ -f "$FLAG_B" ]; then echo "MERGED"; exit 0; fi
    done
    cat <<'JSON'
{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN",
 "labels":[{"name":"auto-merge"}],"statusCheckRollup":[],
 "headRefName":"feature/x","baseRefName":"main"}
JSON
    ;;
  "pr merge")
    # The merge lands, then gh fails on something after it.
    : > "$FLAG_B"
    echo "! Pull request o/repo#998 was already merged" >&2
    exit 1
    ;;
  "issue view") echo '{"state":"CLOSED"}' ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN_B/gh"

RD_B="$REPO_B/.claude/run-issues/20260521-1400-issue-98"
set +e
OUT_B=$(PATH="$BIN_B:$PATH" RUN_ISSUES_LOCK_ROOT="$B/locks" "$PRWATCH" "$REPO_B" 998 2>&1)
RC_B=$?
echo "--- (b) pr-watch rc=$RC_B ---"; printf '%s\n' "$OUT_B" | tail -6

[ "$RC_B" = "0" ] && ok "(b) an already-merged PR is not reported as a failed merge (rc 0)" \
  || bad "(b) rc=$RC_B — the PR was merged and the watcher said otherwise"

[ "$(grep -c '^pr merge' "$CALLS_B")" = "1" ] \
  && ok "(b) the --merge fallback did not fire on an already-merged PR" \
  || bad "(b) merge attempted $(grep -c '^pr merge' "$CALLS_B") times — the fallback fired at a merged PR"

grep -q '"event":"pr_merged"' "$RD_B/state.jsonl" 2>/dev/null \
  && ok "(b) P8 ran: pr_merged recorded" \
  || bad "(b) no pr_merged event — the phases after the merge were skipped"
[ "$(jq -r '.status' "$RD_B/run.json" 2>/dev/null)" = "merged" ] \
  && ok "(b) run finalized merged" \
  || bad "(b) run status is '$(jq -r '.status' "$RD_B/run.json" 2>/dev/null)', expected merged"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "pr-watch-delete-branch-order: all passed" \
                  || echo "pr-watch-delete-branch-order: FAILURES"
exit "$FAIL"
