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

# create_worktree <repo-root> <run-id> <branch> [<base-branch>]
# Creates a worktree at <repo-root>/.claude/worktrees/<run-id>/ on a NEW
# branch <branch>. The base is resolved in this order:
#   1. origin/<base-branch> when <base-branch> is given — a repo's opt-in
#      base_branch (e.g. a long-lived integration branch like "twenty")
#   2. the repo's default remote HEAD (origin/main unless the symbolic ref
#      points elsewhere)
#   3. local HEAD (brand-new repo with no origin symbolic ref)
# Prints the worktree path. Returns non-zero if an explicit base branch does
# not resolve.
#
# The base ref is assumed already fresh: fetching origin is the caller's
# responsibility (orchestrate.sh calls refresh_origin before this), so a stale
# base can be turned into an explicit, diagnosable block instead of being
# silently swallowed here.
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
    # Validate an explicit base branch resolves (origin is already fresh via the
    # caller's refresh_origin); a clear error here beats a cryptic
    # `git worktree add` failure downstream.
    if [ -n "$base_branch" ] \
       && ! git rev-parse --verify --quiet "refs/remotes/origin/$base_branch" >/dev/null; then
      echo "create_worktree: base branch 'origin/$base_branch' not found (origin fresh)" >&2
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
