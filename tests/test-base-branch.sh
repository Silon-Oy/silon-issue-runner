#!/usr/bin/env bash
# test-base-branch.sh — configurable per-repo base branch (run-issues.json
# base_branch). Covers the two β-surfaces the config flows into: the worktree
# base ref and (indirectly, via pr-watch) the rebase target.
#
# Cases:
#   (a) load_repo_base_branch: config present -> echoes the branch name.
#   (b) load_repo_base_branch: file absent / no field / broken JSON -> empty
#       (the backward-compatible fallback signal).
#   (c) load_repo_base_branch: RUN_ISSUES_BASE_BRANCH env overrides config.
#   (d) create_worktree with base -> branch cut from origin/<base> (twenty).
#   (e) create_worktree without base -> falls back to origin/HEAD (main).
#   (f) create_worktree with a non-existent base -> rc 2, no worktree dir.
#   (g) pr-watch P5 rebases onto the PR's OWN base (origin/twenty), not main.
#   (h) create_worktree, no base, remote has refs but no <remote>/HEAD (the
#       `git remote add` multi-remote case) -> rc 2, no worktree, error
#       names `git remote set-head <remote> -a` (issue #27, no silent HEAD).
#   (i) create_worktree in a repo with NO remote refs at all -> local HEAD
#       fallback (the one legitimate HEAD case: a brand-new repo).
#   (j) create_worktree when the target branch already exists locally (a
#       leftover from a previous run of the same issue) -> rc 3, error says
#       "already exists" — distinct cause, NOT a base-ref failure (issue #34).
#   (k) create_worktree when the base resolves but `git worktree add` fails for
#       another reason (target worktree dir already registered) -> rc 4, the
#       generic-failure code the caller must not misread as base-unresolved.
#
# Real local git repos (bare origin + clones); no network. orchestrate.sh has
# no main-guard, so load_repo_base_branch is extracted with sed+eval rather
# than sourced.
#
# Run: bash tests/test-base-branch.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$HERE/../orchestrate.sh"
WORKTREE_LIB="$HERE/../lib/worktree.sh"
PRWATCH="$HERE/../pr-watch.sh"
STATE_LIB="$HERE/../lib/state.sh"

WORK=$(mktemp -d -t base-branch.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0

# Extract just the helper (no main-guard in orchestrate.sh to source safely).
eval "$(sed -n '/^load_repo_base_branch() {/,/^}/p' "$ORCH")"

# ===========================================================================
# (a)(b)(c) load_repo_base_branch
# ===========================================================================
CFGREPO="$WORK/cfgrepo"
mkdir -p "$CFGREPO/.claude"

echo '{"base_branch":"twenty"}' > "$CFGREPO/.claude/run-issues.json"
OUT_A=$(load_repo_base_branch "$CFGREPO")
[ "$OUT_A" = "twenty" ] || { echo "FAIL (a): got '$OUT_A' (want twenty)"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (a) config base_branch -> twenty"

# no file
rm -f "$CFGREPO/.claude/run-issues.json"
[ -z "$(load_repo_base_branch "$CFGREPO")" ] || { echo "FAIL (b1): expected empty when file absent"; FAIL=1; }
# file without the field
echo '{"claude_timeout_seconds":2700}' > "$CFGREPO/.claude/run-issues.json"
[ -z "$(load_repo_base_branch "$CFGREPO")" ] || { echo "FAIL (b2): expected empty when field absent"; FAIL=1; }
# broken JSON
echo '{not json' > "$CFGREPO/.claude/run-issues.json"
[ -z "$(load_repo_base_branch "$CFGREPO")" ] || { echo "FAIL (b3): expected empty on broken JSON"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (b) absent / no-field / broken JSON -> empty (fallback)"

# env override wins over config
echo '{"base_branch":"twenty"}' > "$CFGREPO/.claude/run-issues.json"
OUT_C=$(RUN_ISSUES_BASE_BRANCH=other load_repo_base_branch "$CFGREPO")
[ "$OUT_C" = "other" ] || { echo "FAIL (c): got '$OUT_C' (want other)"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (c) RUN_ISSUES_BASE_BRANCH overrides config"

# ===========================================================================
# (d)(e)(f) create_worktree base resolution — real bare origin + clone
# ===========================================================================
ORIGIN="$WORK/origin.git"
SRC="$WORK/src"
git init -q --bare "$ORIGIN"
git init -q "$SRC"
(
  cd "$SRC"
  git config user.email t@t.t; git config user.name t
  git remote add origin "$ORIGIN"
  echo "v0" > f.txt; git add f.txt; git commit -qm init
  git branch -M main
  git push -q origin main
  git checkout -q -b twenty
  echo "twenty" > f.txt; git commit -qam "twenty work"
  git push -q origin twenty
)

# Fresh clone is what create_worktree operates on (mirrors a Studio clone).
REPO="$WORK/repo"
git clone -q "$ORIGIN" "$REPO"
git -C "$REPO" remote set-head origin main   # origin/HEAD -> main for the fallback case

MAIN_SHA=$(git -C "$REPO" rev-parse origin/main)
TWENTY_SHA=$(git -C "$REPO" rev-parse origin/twenty)

# Source the lib (turns on set -e); neutralize for the test driver so we can
# assert non-zero returns ourselves.
# shellcheck source=../lib/worktree.sh
. "$WORKTREE_LIB"
set +e

# (d) explicit base -> origin/twenty
WT_D=$(create_worktree "$REPO" "run-d" "feat/d" "twenty")
RC_D=$?
[ "$RC_D" = "0" ] || { echo "FAIL (d): create_worktree rc=$RC_D"; FAIL=1; }
GOT_D=$(git -C "$WT_D" rev-parse HEAD 2>/dev/null)
[ "$GOT_D" = "$TWENTY_SHA" ] || { echo "FAIL (d): worktree HEAD '$GOT_D' != origin/twenty '$TWENTY_SHA'"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (d) base=twenty -> branch cut from origin/twenty"

# (e) no base -> origin/HEAD (main)
WT_E=$(create_worktree "$REPO" "run-e" "feat/e")
RC_E=$?
[ "$RC_E" = "0" ] || { echo "FAIL (e): create_worktree rc=$RC_E"; FAIL=1; }
GOT_E=$(git -C "$WT_E" rev-parse HEAD 2>/dev/null)
[ "$GOT_E" = "$MAIN_SHA" ] || { echo "FAIL (e): worktree HEAD '$GOT_E' != origin/main '$MAIN_SHA'"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (e) no base -> origin/HEAD fallback (main)"

# (f) non-existent base -> rc 2 (base-ref unresolved), no worktree dir created
WT_F=$(create_worktree "$REPO" "run-f" "feat/f" "does-not-exist")
RC_F=$?
[ "$RC_F" = "2" ] || { echo "FAIL (f): expected rc 2 for absent base, got $RC_F"; FAIL=1; }
[ ! -d "$REPO/.claude/worktrees/run-f" ] || { echo "FAIL (f): worktree dir created despite absent base"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (f) absent base -> rc 2, no worktree"

# ===========================================================================
# (h) no base, remote has refs but no <remote>/HEAD -> fail-fast (issue #27)
# ===========================================================================
# Mirror the multi-remote repro: `git remote add` + fetch populates
# refs/remotes/other/* but NEVER refs/remotes/other/HEAD (only clone/set-head
# do). Point `other` at the same bare origin — content is irrelevant; all we
# need is a fetched remote that has refs but no symbolic HEAD.
git -C "$REPO" remote add other "$ORIGIN"
# followRemoteHEAD=never is REQUIRED from git 2.50 on: its default (`create`)
# makes `git fetch` write refs/remotes/<name>/HEAD itself, which would destroy
# this repro — the fixture would have the very ref whose absence is under test.
# Older git ignores the unknown key, so the line is version-safe. The production
# case survives regardless: pre-2.50 clones and remotes added before the upgrade
# still carry no <remote>/HEAD.
git -C "$REPO" -c remote.other.followRemoteHEAD=never fetch -q other
# Sanity: the setup actually reproduces the missing-HEAD condition.
if git -C "$REPO" symbolic-ref --short refs/remotes/other/HEAD >/dev/null 2>&1; then
  echo "FAIL (h setup): other/HEAD unexpectedly resolves — repro invalid"; FAIL=1
fi
[ -n "$(git -C "$REPO" for-each-ref --count=1 refs/remotes/other/)" ] \
  || { echo "FAIL (h setup): other has no refs — repro invalid"; FAIL=1; }

H_ERR="$WORK/h.err"
WT_H=$(create_worktree "$REPO" "run-h" "feat/h" "" "other" 2>"$H_ERR")
RC_H=$?
[ "$RC_H" = "2" ] || { echo "FAIL (h): expected rc 2 when other/HEAD missing, got $RC_H"; FAIL=1; }
[ ! -d "$REPO/.claude/worktrees/run-h" ] || { echo "FAIL (h): worktree dir created despite unresolved base"; FAIL=1; }
grep -q "git remote set-head other -a" "$H_ERR" || { echo "FAIL (h): error did not name the fix command; got: $(cat "$H_ERR")"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (h) remote refs but no <remote>/HEAD -> rc 2, names fix"

# ===========================================================================
# (i) repo with NO remote refs at all -> local HEAD fallback (new repo)
# ===========================================================================
NLREPO="$WORK/nolocal-remote"
git init -q "$NLREPO"
(
  cd "$NLREPO"
  git config user.email t@t.t; git config user.name t
  echo "solo" > f.txt; git add f.txt; git commit -qm init
)
NL_HEAD=$(git -C "$NLREPO" rev-parse HEAD)
WT_I=$(create_worktree "$NLREPO" "run-i" "feat/i")
RC_I=$?
[ "$RC_I" = "0" ] || { echo "FAIL (i): create_worktree rc=$RC_I (want 0 for new repo)"; FAIL=1; }
GOT_I=$(git -C "$WT_I" rev-parse HEAD 2>/dev/null)
[ "$GOT_I" = "$NL_HEAD" ] || { echo "FAIL (i): worktree HEAD '$GOT_I' != local HEAD '$NL_HEAD'"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (i) no remote refs -> local HEAD fallback (new repo)"

# ===========================================================================
# (j) leftover local branch from a previous run -> rc 3, distinct from base-ref
# ===========================================================================
# The issue #34 repro: a prior run of the same issue left refs/heads/<branch>
# behind (its remote branch was deleted by `gh pr close --delete-branch`, but
# the local one survived). The base ref (origin/main) resolves perfectly here —
# the ONLY problem is the pre-existing branch. Must report rc 3, not rc 2.
git -C "$REPO" branch leftover/j origin/main   # simulate the surviving branch
J_ERR="$WORK/j.err"
WT_J=$(create_worktree "$REPO" "run-j" "leftover/j" 2>"$J_ERR")
RC_J=$?
[ "$RC_J" = "3" ] || { echo "FAIL (j): expected rc 3 for leftover branch, got $RC_J"; FAIL=1; }
[ ! -d "$REPO/.claude/worktrees/run-j" ] || { echo "FAIL (j): worktree dir created despite leftover branch"; FAIL=1; }
grep -q "already exists" "$J_ERR" || { echo "FAIL (j): error did not name the leftover branch; got: $(cat "$J_ERR")"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (j) leftover branch -> rc 3, not base-ref"

# ===========================================================================
# (k) base resolves but `git worktree add` fails otherwise -> rc 4 (generic)
# ===========================================================================
# Create a worktree at run-k successfully, then ask for the SAME run-id (same
# target path) with a FRESH branch: the branch check (rc 3) passes but
# `git worktree add` fails because the path is already a registered worktree.
# Cause is not base-ref (rc 2) and not a leftover branch (rc 3) — it is the
# generic rc 4 the caller must surface via the log, not guess.
WT_K1=$(create_worktree "$REPO" "run-k" "feat/k1")
[ -d "$REPO/.claude/worktrees/run-k" ] || { echo "FAIL (k setup): first worktree not created"; FAIL=1; }
K_ERR="$WORK/k.err"
WT_K2=$(create_worktree "$REPO" "run-k" "feat/k2" 2>"$K_ERR")
RC_K=$?
[ "$RC_K" = "4" ] || { echo "FAIL (k): expected rc 4 for generic worktree-add failure, got $RC_K"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (k) base resolves, worktree add fails -> rc 4 (generic)"

# ===========================================================================
# (g) pr-watch P5 rebases onto the PR's own base (origin/twenty), not main
# ===========================================================================
G_ORIGIN="$WORK/g-origin.git"
G_REPO="$WORK/g-repo"
git init -q --bare "$G_ORIGIN"
git init -q "$G_REPO"
(
  cd "$G_REPO"
  git config user.email t@t.t; git config user.name t
  git remote add origin "$G_ORIGIN"
  echo "v0" > f.txt; git add f.txt; git commit -qm init
  git branch -M main
  git push -q origin main
  # integration branch "twenty"
  git checkout -q -b twenty
  echo "twenty v1" > f.txt; git commit -qam "twenty base"
  git push -q origin twenty
  # feature off twenty, diverging on the SAME line
  git checkout -q -b feature/g
  echo "line FEATURE" > f.txt; git commit -qam feature
  git push -q origin feature/g
  # twenty moves on the SAME line -> guaranteed rebase conflict against twenty
  git checkout -q twenty
  echo "line TWENTY-MOVED" > f.txt; git commit -qam twentymove
  git push -q origin twenty
)
G_WT="$WORK/g-wt"
( cd "$G_REPO" && git worktree add -q "$G_WT" feature/g )

BIN="$WORK/bin"; mkdir -p "$BIN"
COMMENT_BODY="$WORK/comment_body.txt"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
case "\$1 \$2" in
  "pr view")
    cat <<'JSON'
{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"BEHIND",
 "labels":[{"name":"auto-merge"}],"statusCheckRollup":[],
 "headRefName":"feature/g","baseRefName":"twenty"}
JSON
    ;;
  "pr comment")
    cat > "$COMMENT_BODY"   # capture --body-file - stdin
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN/gh"

# --- claude mock that CANNOT resolve the conflict -------------------------
# This case is about the rebase TARGET (origin/twenty vs origin/main), not
# about conflict resolution; the conflict is only the vehicle that makes the
# target observable in the output and the PR comment. So the agent must fail
# deterministically. Without this mock the test invoked the REAL Claude CLI:
# when the agent happened to resolve the conflict the run ended rc=0 and the
# case failed, making it flaky AND slow AND token-burning on every suite run.
# Same shape as test-pr-watch-conflict-abort.sh's mock.
CLAUDE_MOCK="$BIN/claude-mock"
cat > "$CLAUDE_MOCK" <<'SH'
#!/usr/bin/env bash
# Give up without touching the conflicted files or continuing the rebase —
# the watcher must detect the unclean state, abort, and report rc=6.
echo "CONFLICT_RESOLUTION_RESULT: UNRESOLVED — mock cannot resolve"
exit 0
SH
chmod +x "$CLAUDE_MOCK"

# shellcheck source=../lib/state.sh
. "$STATE_LIB"
set +e   # state.sh re-enables -e
RID_G="20260525-1200-issue-99"
RD_G="$G_REPO/.claude/run-issues/$RID_G"
state_init "$RD_G" "$RID_G" "$G_REPO" "99"
state_set "$RD_G" "pr_url" "https://github.com/Silon-Oy/x/pull/999"
state_set "$RD_G" "worktree_path" "$G_WT"
state_set "$RD_G" "branch" "feature/g"
state_finalize "$RD_G" "completed"

OUT_G=$(
  PATH="$BIN:$PATH" \
  RUN_ISSUES_LOCK_ROOT="$WORK/locks-g" \
  PR_WATCH_ENABLE_CONFLICT_RESOLUTION=1 \
  RUN_ISSUES_CLAUDE_CMD="$CLAUDE_MOCK" \
  "$PRWATCH" "$G_REPO" 999 2>&1
)
RC_G=$?
echo "--- (g) pr-watch output (rc=$RC_G) ---"; echo "$OUT_G" | grep -i "rebas" | head -3

[ "$RC_G" = "6" ] || { echo "FAIL (g): expected rc 6 (conflict), got $RC_G"; FAIL=1; }
echo "$OUT_G" | grep -q "onto origin/twenty" || { echo "FAIL (g): did not rebase onto origin/twenty"; FAIL=1; }
if echo "$OUT_G" | grep -q "onto origin/main"; then echo "FAIL (g): rebased onto origin/main (wrong base)"; FAIL=1; fi
[ -f "$COMMENT_BODY" ] && grep -q 'origin/twenty' "$COMMENT_BODY" || { echo "FAIL (g): conflict comment did not mention origin/twenty"; FAIL=1; }
[ "$(jq -r '.status' "$RD_G/run.json")" = "pr_conflicted" ] || { echo "FAIL (g): status not pr_conflicted"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (g) pr-watch rebases onto PR base origin/twenty, not main"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "base-branch: all passed" || echo "base-branch: FAILURES"
[ "$FAIL" -eq 0 ]
