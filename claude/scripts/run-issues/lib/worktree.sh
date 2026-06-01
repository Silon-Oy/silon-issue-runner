#!/usr/bin/env bash
# lib/worktree.sh — manage per-run git worktrees in the TARGET repo.
#
# Worktrees live under <repo-root>/.claude/worktrees/<run-id>/. They are
# intentionally kept after the run so maintainer can inspect what happened —
# only the rollback path (cleanup_worktree) removes them.
#
# Multi-remote: every function takes an optional <remote> argument (default
# "origin"). It is used to resolve the base ref and, in refresh_origin, which
# remote to fetch. Passing "origin" explicitly is identical to the legacy
# behaviour; non-origin remotes route fetch + base resolution to the right
# org so a single clone can branch off `customer-d/main` as well as `origin/main`.

set -euo pipefail

# refresh_origin <repo-root> [<remote>]
# Fetches the named remote (default "origin") so the local <remote>/* refs
# reflect the remote tip before a worktree is branched off them. Despite the
# legacy name, this works for any remote — the name is kept for backward
# compatibility with existing callers and tests. The return code carries the
# outcome so the caller can decide policy (fail-fast on a new run, soft on
# restart/continue):
#   0  fetch succeeded
#   1  fetch ran but failed (network/auth) — <remote>/* refs may be stale
#   2  the named remote does not exist on the clone — benign no-op
# Prints nothing to stdout; the caller may capture stderr for diagnostics.
refresh_origin() {
  local repo="$1"
  local remote="${2:-origin}"

  # No such remote -> nothing to refresh. Benign; not an error.
  git -C "$repo" remote get-url "$remote" >/dev/null 2>&1 || return 2

  git -C "$repo" fetch "$remote" --quiet || return 1
  return 0
}

# create_worktree <repo-root> <run-id> <branch> [<base-branch>] [<remote>]
# Creates a worktree at <repo-root>/.claude/worktrees/<run-id>/ on a NEW
# branch <branch>. The base is resolved in this order:
#   1. <remote>/<base-branch> when <base-branch> is given — a repo's opt-in
#      base_branch (e.g. a long-lived integration branch like "twenty")
#   2. the named remote's default HEAD (<remote>/main unless the symbolic ref
#      points elsewhere); falls back to origin/HEAD if the named remote has
#      no symbolic HEAD ref locally
#   3. local HEAD (brand-new repo with no symbolic ref)
# Prints the worktree path. Returns non-zero if an explicit base branch does
# not resolve.
#
# The base ref is assumed already fresh: fetching the remote is the caller's
# responsibility (orchestrate.sh calls refresh_origin before this), so a stale
# base can be turned into an explicit, diagnosable block instead of being
# silently swallowed here.
create_worktree() {
  local repo="$1"
  local run_id="$2"
  local branch="$3"
  local base_branch="${4:-}"
  local remote="${5:-origin}"

  local base_path="$repo/.claude/worktrees"
  mkdir -p "$base_path"
  local wt_path="$base_path/$run_id"

  # Resolve the base ref. An explicit base branch wins; otherwise fall back to
  # the upstream default branch, then to local HEAD (brand-new repo).
  local base_ref
  if [ -n "$base_branch" ]; then
    base_ref="$remote/$base_branch"
  elif base_ref=$(cd "$repo" && git symbolic-ref --short "refs/remotes/$remote/HEAD" 2>/dev/null); then
    : # got something like <remote>/main
  else
    base_ref="HEAD"
  fi

  # `set -e` does not propagate a subshell's failure to the caller via the
  # trailing `printf`, so guard the subshell explicitly with `|| return 1`.
  (
    cd "$repo"
    # Validate an explicit base branch resolves (the remote is already fresh
    # via the caller's refresh_origin); a clear error here beats a cryptic
    # `git worktree add` failure downstream.
    if [ -n "$base_branch" ] \
       && ! git rev-parse --verify --quiet "refs/remotes/$remote/$base_branch" >/dev/null; then
      echo "create_worktree: base branch '$remote/$base_branch' not found (remote fresh)" >&2
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
