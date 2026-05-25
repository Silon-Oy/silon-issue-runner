#!/usr/bin/env bash
# lib/worktree.sh — manage per-run git worktrees in the TARGET repo.
#
# Worktrees live under <repo-root>/.claude/worktrees/<run-id>/. They are
# intentionally kept after the run so maintainer can inspect what happened —
# only the rollback path (cleanup_worktree) removes them.

set -euo pipefail

# create_worktree <repo-root> <run-id> <branch> [<base-branch>]
# Creates a worktree at <repo-root>/.claude/worktrees/<run-id>/ on a NEW
# branch <branch>. The base is resolved in this order:
#   1. origin/<base-branch> when <base-branch> is given — a repo's opt-in
#      base_branch (e.g. a long-lived integration branch like "twenty")
#   2. the repo's default remote HEAD (origin/main unless the symbolic ref
#      points elsewhere)
#   3. local HEAD (brand-new repo with no origin symbolic ref)
# Prints the worktree path. Returns non-zero if an explicit base branch does
# not resolve after fetch.
create_worktree() {
  local repo="$1"
  local run_id="$2"
  local branch="$3"
  local base_branch="${4:-}"

  local base_path="$repo/.claude/worktrees"
  mkdir -p "$base_path"
  local wt_path="$base_path/$run_id"

  # Resolve the base ref. An explicit base branch wins; otherwise fall back to
  # the upstream default branch, then to local HEAD (brand-new repo).
  local base_ref
  if [ -n "$base_branch" ]; then
    base_ref="origin/$base_branch"
  elif base_ref=$(cd "$repo" && git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null); then
    : # got something like origin/main
  else
    base_ref="HEAD"
  fi

  # `set -e` does not propagate a subshell's failure to the caller via the
  # trailing `printf`, so guard the subshell explicitly with `|| return 1`.
  (
    cd "$repo"
    git fetch origin --quiet 2>/dev/null || true
    # Validate an explicit base branch resolves after fetch; a clear error
    # here beats a cryptic `git worktree add` failure downstream.
    if [ -n "$base_branch" ] \
       && ! git rev-parse --verify --quiet "refs/remotes/origin/$base_branch" >/dev/null; then
      echo "create_worktree: base branch 'origin/$base_branch' not found after fetch" >&2
      exit 1
    fi
    git worktree add -b "$branch" "$wt_path" "$base_ref" >/dev/null
  ) || return 1

  printf '%s' "$wt_path"
}

# cleanup_worktree <path>
# Removes the worktree dir AND its tracking entry. Best-effort; only
# called in rollback paths.
cleanup_worktree() {
  local wt_path="$1"
  [ -d "$wt_path" ] || return 0

  # `git worktree remove` requires the repo it belongs to; derive it.
  local repo_top
  if repo_top=$(git -C "$wt_path" rev-parse --show-toplevel 2>/dev/null); then
    git -C "$repo_top" worktree remove --force "$wt_path" 2>/dev/null || rm -rf "$wt_path"
  else
    rm -rf "$wt_path"
  fi
}
