#!/usr/bin/env bash
# lib/worktree.sh — manage per-run git worktrees in the TARGET repo.
#
# Worktrees live under <repo-root>/.claude/worktrees/<run-id>/. They are
# intentionally kept after the run so maintainer can inspect what happened —
# only the rollback path (cleanup_worktree) removes them.

set -euo pipefail

# create_worktree <repo-root> <run-id> <branch>
# Creates a worktree at <repo-root>/.claude/worktrees/<run-id>/ on a NEW
# branch <branch> based on the repo's default remote HEAD (origin/main
# unless the symbolic ref points elsewhere). Prints the worktree path.
create_worktree() {
  local repo="$1"
  local run_id="$2"
  local branch="$3"

  local base_path="$repo/.claude/worktrees"
  mkdir -p "$base_path"
  local wt_path="$base_path/$run_id"

  # Resolve the upstream default branch ref. Falls back to local HEAD
  # if no origin symbolic ref is present (e.g. brand-new repo).
  local base_ref
  if base_ref=$(cd "$repo" && git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null); then
    : # got something like origin/main
  else
    base_ref="HEAD"
  fi

  (
    cd "$repo"
    git fetch origin --quiet 2>/dev/null || true
    git worktree add -b "$branch" "$wt_path" "$base_ref" >/dev/null
  )

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
