#!/usr/bin/env bash
# lib/worktree.sh — manage per-run git worktrees in the TARGET repo.
#
# Worktrees live under <repo-root>/.claude/worktrees/<run-id>/. They are
# intentionally kept after the run so maintainer can inspect what happened —
# only the rollback path (cleanup_worktree) removes them.

set -euo pipefail

# refresh_origin <repo-root>
# Fetches origin so the local origin/* refs reflect the remote tip before a
# worktree is branched off them. The return code carries the outcome so the
# caller can decide policy (fail-fast on a new run, soft on restart/continue):
#   0  fetch succeeded
#   1  fetch ran but failed (network/auth) — origin/* refs may be stale
#   2  no origin remote (e.g. a brand-new or local-only repo) — benign no-op
# Prints nothing to stdout; the caller may capture stderr for diagnostics.
refresh_origin() {
  local repo="$1"

  # No origin remote -> nothing to refresh. Benign; not an error.
  git -C "$repo" remote get-url origin >/dev/null 2>&1 || return 2

  git -C "$repo" fetch origin --quiet || return 1
  return 0
}

# create_worktree <repo-root> <run-id> <branch>
# Creates a worktree at <repo-root>/.claude/worktrees/<run-id>/ on a NEW
# branch <branch> based on the repo's default remote HEAD (origin/main
# unless the symbolic ref points elsewhere). Prints the worktree path.
#
# The base ref is assumed already fresh: fetching origin is the caller's
# responsibility (orchestrate.sh calls refresh_origin before this), so a
# stale base can be turned into an explicit, diagnosable block instead of
# being silently swallowed here.
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
