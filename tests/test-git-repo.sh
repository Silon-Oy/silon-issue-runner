#!/usr/bin/env bash
# test-git-repo.sh — lib/git-repo.sh is_git_repo_root (issue #429).
#
# Pins the predicate every `--repo` / watchlist check goes through: a regular
# repo, a submodule checkout and a linked worktree (both with a `.git` FILE) are
# accepted; a repo subdirectory, a plain directory, a missing path and a `.git`
# directory itself are refused; a leaked GIT_DIR does not change the answer.
#
# Run: bash tests/test-git-repo.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/git-repo.sh
. "$HERE/../lib/git-repo.sh"

WORK=$(mktemp -d -t gitrepotest.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
fail() { echo "FAIL: $*"; FAIL=1; }
pass() { echo "PASS: $*"; }
accepts() { is_git_repo_root "$2" && pass "accepts $1" || fail "should accept $1 ($2)"; }
refuses() { is_git_repo_root "$2" && fail "should refuse $1 ($2)" || pass "refuses $1"; }

GITC=(-c user.name=t -c user.email=t@example.invalid -c protocol.file.allow=always -c init.defaultBranch=main)

REPO="$WORK/repo"; git init -q "$REPO"
git -C "$REPO" "${GITC[@]}" commit -q --allow-empty -m init
mkdir -p "$REPO/sub/dir"

SUPER="$WORK/super"; git init -q "$SUPER"
git -C "$SUPER" "${GITC[@]}" submodule add -q "$REPO" pkg >/dev/null 2>&1
WT="$WORK/wt"; git -C "$REPO" worktree add -q "$WT" -b wt >/dev/null 2>&1

accepts "a regular repo" "$REPO"
accepts "a regular repo with a trailing slash" "$REPO/"
if [ -f "$SUPER/pkg/.git" ]; then accepts "a submodule checkout (.git is a file)" "$SUPER/pkg"
else fail "fixture: submodule has no .git file"; fi
if [ -f "$WT/.git" ]; then accepts "a linked worktree (.git is a file)" "$WT"
else fail "fixture: worktree has no .git file"; fi

refuses "a repo subdirectory" "$REPO/sub"
refuses "a nested repo subdirectory" "$REPO/sub/dir"
refuses "the .git directory itself" "$REPO/.git"
mkdir -p "$WORK/plain"; refuses "a plain directory" "$WORK/plain"
refuses "a missing path" "$WORK/missing"
refuses "an empty argument" ""
mkdir -p "$WORK/fake"; printf 'gitdir: %s\n' "$WORK/nowhere" > "$WORK/fake/.git"
refuses "a directory with a broken gitlink" "$WORK/fake"

# A GIT_DIR leaked from a hook context must not redirect the question.
GIT_DIR="$REPO/.git" refuses "a plain directory under a leaked GIT_DIR" "$WORK/plain"
GIT_DIR="$WORK/plain" GIT_WORK_TREE="$WORK/plain" accepts "a repo under a foreign GIT_DIR" "$REPO"

[ -z "$(is_git_repo_root "$REPO" 2>&1; is_git_repo_root "$WORK/plain" 2>&1)" ] \
  && pass "prints nothing" || fail "is_git_repo_root printed output"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "git-repo: all passed" || echo "git-repo: FAILURES"
[ "$FAIL" -eq 0 ]
