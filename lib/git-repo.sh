#!/usr/bin/env bash
# lib/git-repo.sh — is_git_repo_root: the package's one "is this a repo root?"
# predicate (issue #429).
#
# WHY NOT `[ -d "$p/.git" ]`. In a submodule checkout and in a linked worktree
# `.git` is a FILE (a gitlink), so the directory test rejected repositories git
# itself accepts — `/issue-runner:run-epic` failed on a machine where the runner
# package is a dotfiles submodule. Nine call sites carried the test in two
# drifting shapes (`-d` and `-e`); `-e` is no better: it accepts any file named
# `.git`, including a broken gitlink. Git is the authority, so ask git.
#
# WHY AN EMPTY PREFIX, NOT A PATH COMPARISON. The criterion is "`rev-parse
# --show-toplevel` is this same path". Comparing the strings breaks on symlinks,
# on macOS `/tmp` -> `/private/tmp`, and on MSYS where git prints `C:/...` for a
# POSIX path (CLAUDE.md §5.8). `--show-prefix` is empty exactly when the path is
# the top of its work tree, so the same question is answered without comparing
# paths. Inside a work tree is required first: a bare repo or a `.git` directory
# has an empty prefix too.
#
# WORKTREES ARE ACCEPTED ON PURPOSE. Every caller checks the operator's repo
# (`--repo` or a watchlist path), from which a run's worktree is created with
# `git worktree add` — which works from a submodule or a linked worktree as
# well. No caller needs to reject a worktree, so none carries an exception.
#
# GIT_DIR / GIT_WORK_TREE / GIT_COMMON_DIR leaking in from a hook context would
# make rev-parse answer for a different repository; they are unset in the
# subshell.
#
# Defines functions only; no top-level work and no `set`. Prints nothing.

# is_git_repo_root <path> -> 0 if <path> is the top-level of a git work tree
# (regular repo, submodule or linked worktree), 1 otherwise.
is_git_repo_root() {
  local p="${1:-}"
  [ -n "$p" ] && [ -d "$p" ] || return 1
  (
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_PREFIX
    [ "$(git -C "$p" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] || exit 1
    prefix="$(git -C "$p" rev-parse --show-prefix 2>/dev/null)" || exit 1
    [ -z "$prefix" ]
  )
}
