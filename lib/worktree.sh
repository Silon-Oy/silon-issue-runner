#!/usr/bin/env bash
# lib/worktree.sh — manage per-run git worktrees in the TARGET repo.
#
# Worktrees live under <repo-root>/.claude/worktrees/<run-id>/. They are
# intentionally kept after the run so a human can inspect what happened —
# only the rollback path (cleanup_worktree) removes them.
#
# Multi-remote: every function takes an optional <remote> argument (default
# "origin"). It is used to resolve the base ref and, in refresh_origin, which
# remote to fetch. Passing "origin" explicitly is identical to the legacy
# behaviour; non-origin remotes route fetch + base resolution to the right
# org so a single clone can branch off `partner/main` as well as `origin/main`.

set -euo pipefail

# Source the two pure leaves refresh_origin needs: preflight.sh for the GNU
# timeout binary selection (preflight_timeout_bin) and git-remote.sh for the
# shared bounded-fetch primitive (runner_git_fetch_bounded). Resolved from this
# file's own dir so a test that sources worktree.sh alone still gets them.
_WORKTREE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/preflight.sh
. "$_WORKTREE_LIB_DIR/preflight.sh"
# shellcheck source=lib/git-remote.sh
. "$_WORKTREE_LIB_DIR/git-remote.sh"

# Seconds before a hung `git fetch` in refresh_origin is killed and reported as
# an ordinary fetch failure. Only enforced when a GNU timeout binary is present
# (preflight_timeout_bin); without one the fetch runs unbounded, the same
# contract claude-call.sh and runner_fetch_throttled document for a machine
# without coreutils. 120s is generous for a slow network yet turns the
# hang-for-an-hour failure of issue #298 into a prompt, diagnosable block.
RUN_ISSUES_FETCH_TIMEOUT="${RUN_ISSUES_FETCH_TIMEOUT:-120}"

# refresh_origin <repo-root> [<remote>]
# Fetches the named remote (default "origin") so the local <remote>/* refs
# reflect the remote tip before a worktree is branched off them. Despite the
# legacy name, this works for any remote — the name is kept for backward
# compatibility with existing callers and tests. The return code carries the
# outcome so the caller can decide policy (fail-fast on a new run, soft on
# restart/continue):
#   0  fetch succeeded
#   1  fetch ran but failed (network/auth OR timed out) — <remote>/* refs may be
#      stale. A timeout maps to this same 1 so the three call sites' existing
#      policy handles a hung connection exactly like any other fetch failure
#      (issue #298); the stderr line distinguishes the cause for a human.
#   2  the named remote does not exist on the clone — benign no-op
# The fetch is bounded by RUN_ISSUES_FETCH_TIMEOUT when a GNU timeout binary is
# available, so a hung connection becomes a prompt rc=1 instead of stalling the
# run in S4 until the poller's hour-long liveness limit trips it (issue #298).
# Prints nothing to stdout; the caller may capture stderr for diagnostics.
refresh_origin() {
  local repo="$1"
  local remote="${2:-origin}"

  # No such remote -> nothing to refresh. Benign; not an error.
  git -C "$repo" remote get-url "$remote" >/dev/null 2>&1 || return 2

  local tbin fetch_rc=0
  tbin=$(preflight_timeout_bin)
  runner_git_fetch_bounded "$tbin" "$RUN_ISSUES_FETCH_TIMEOUT" "$repo" "$remote" --quiet \
    || fetch_rc=$?
  [ "$fetch_rc" -eq 0 ] && return 0

  # GNU timeout exits 124 when it had to kill the fetch. Name that in the log the
  # caller captures so a hung connection is told apart from an auth/network
  # failure, then collapse to the generic fetch-failure rc 1 the callers handle.
  if [ -n "$tbin" ] && [ "$fetch_rc" -eq 124 ]; then
    echo "refresh_origin: 'git fetch $remote' timed out after ${RUN_ISSUES_FETCH_TIMEOUT}s (killed by $tbin) — treating as a fetch failure" >&2
  fi
  return 1
}

# create_worktree <repo-root> <run-id> <branch> [<base-branch>] [<remote>]
# Creates a worktree at <repo-root>/.claude/worktrees/<run-id>/ on a NEW
# branch <branch>. The base is resolved in this order:
#   1. <remote>/<base-branch> when <base-branch> is given — a repo's opt-in
#      base_branch (e.g. a long-lived integration branch like "twenty")
#   2. the named remote's default HEAD (<remote>/main unless the symbolic ref
#      points elsewhere)
#   3. local HEAD — ONLY for a genuinely new repo that has no <remote>/* refs
#      at all. A remote that HAS refs but no symbolic HEAD is a hard error, not
#      a fall-through to local HEAD (issue #27): `git remote add` never sets
#      <remote>/HEAD (only `git clone` does), so a multi-remote clone hits this
#      routinely, and silently branching off local HEAD produces PRs cut from a
#      stale commit with no error. Refuse instead, naming the one-line fix.
# Prints the worktree path on success.
#
# Return codes carry the FAILURE CAUSE so the caller attributes the block
# correctly (issue #34 — a single `1` made the orchestrator misdiagnose every
# failure as a missing <remote>/HEAD and print the wrong fix):
#   0  worktree created
#   2  base ref could not be resolved — an explicit base branch that does not
#      exist, or a named remote with refs but no <remote>/HEAD and no base
#      branch. Fix: `git remote set-head` or set base_branch.
#   3  the local branch <branch> already exists — a leftover from a previous run
#      of the SAME issue (a closed PR with --delete-branch removes only the
#      remote branch). Fix: cleanup-run.sh, NOT `git remote set-head`.
#   4  `git worktree add` failed for some other reason (existing worktree dir,
#      disk space, permissions). Cause is not identified here — the caller must
#      point at the log rather than guess.
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

  # Resolve the base ref. An explicit base branch wins; otherwise use the named
  # remote's default HEAD. Local HEAD is a fallback ONLY when the remote has no
  # refs at all (brand-new repo) — never a silent catch-all (issue #27).
  local base_ref
  if [ -n "$base_branch" ]; then
    base_ref="$remote/$base_branch"
  elif base_ref=$(cd "$repo" && git symbolic-ref --short "refs/remotes/$remote/HEAD" 2>/dev/null); then
    : # got something like <remote>/main
  elif [ -n "$(git -C "$repo" for-each-ref --count=1 "refs/remotes/$remote/")" ]; then
    # The remote is fetched (it has refs) but carries no symbolic HEAD to name
    # its default branch. Falling back to local HEAD here would branch off
    # whatever commit the working copy happens to sit on — the silent stale-base
    # bug of issue #27. Fail fast, naming the fix, before any side effect.
    echo "create_worktree: '$remote/HEAD' does not resolve and no base branch was given." >&2
    echo "create_worktree: run 'git remote set-head $remote -a' in the repo (or set base_branch in .claude/run-issues.json), then retry." >&2
    return 2
  else
    base_ref="HEAD" # genuinely new repo: no <remote>/* refs exist yet
  fi

  # Validate an explicit base branch resolves (the remote is already fresh via
  # the caller's refresh_origin); a clear error here beats a cryptic
  # `git worktree add` failure downstream. Same cause as the missing-HEAD
  # branch above: the base ref does not resolve (rc 2).
  if [ -n "$base_branch" ] \
     && ! git -C "$repo" rev-parse --verify --quiet "refs/remotes/$remote/$base_branch" >/dev/null; then
    echo "create_worktree: base branch '$remote/$base_branch' not found (remote fresh)" >&2
    return 2
  fi

  # A local branch left behind by a previous run of the SAME issue makes
  # `git worktree add -b` fail with "already exists" — but that is NOT a base-ref
  # problem, so detect it explicitly and report a distinct cause (rc 3). Without
  # this, the generic failure below would be misread as an unresolved base and
  # the caller would print the wrong fix (issue #34).
  if git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    echo "create_worktree: local branch '$branch' already exists (leftover from a previous run of this issue)." >&2
    return 3
  fi

  # Any remaining `git worktree add` failure (existing worktree dir, disk,
  # permissions) is genuinely unclassified here — surface it as rc 4 so the
  # caller points at the log instead of guessing a cause. Let git's own stderr
  # flow through (the caller captures it into worktree-create.log): the real
  # error is what the log must show (issue #34), so only stdout is silenced.
  if ! git -C "$repo" worktree add -b "$branch" "$wt_path" "$base_ref" >/dev/null; then
    echo "create_worktree: 'git worktree add' failed for branch '$branch' (see log)." >&2
    return 4
  fi

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
