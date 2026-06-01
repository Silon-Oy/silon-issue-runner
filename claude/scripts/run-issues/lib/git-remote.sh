#!/usr/bin/env bash
# lib/git-remote.sh — multi-remote (multi-org) helpers for /run-issues.
#
# One local clone can poll multiple GitHub orgs at once when a repo entry in
# the watchlist lists more than one git remote in its `remotes` array. The
# orchestrator and poller must then namespace per-run identity by the remote so
# `Silon-Oy/...#5` and `customer-d-oy/...#5` do not collide on the same lock / tmux
# session / branch / run-dir, and must route every gh call to the issue's own
# org via `gh --repo owner/repo`.
#
# This file is purposely small and pure (no side effects beyond calling
# `git remote get-url`), so the parsing functions can be unit-tested offline.
# Sourced by orchestrate.sh, poller.sh, and the test harness; no top-level work.
#
# Backward compatibility:
#   - When the remote is "origin", every identifier collapses to the legacy
#     shape (issue-N.lock, run-issues-N tmux session, <ts>-issue-N run-id,
#     auto-run/issue-N-<slug> branch) so existing runs and locks are not
#     orphaned by the upgrade. Only non-origin remotes get the <remote>- prefix.

set -euo pipefail

# parse_owner_repo_from_remote_url <url>
# Prints "owner/repo" on stdout for a github.com remote URL, or empty on a
# parse failure. Pure — no network, no git invocation. Handles the four shapes
# `git remote get-url` produces in practice:
#   - git@github.com:owner/repo.git           (SSH, scp-like)
#   - git@github.com:owner/repo               (SSH, no .git)
#   - https://github.com/owner/repo.git       (HTTPS)
#   - https://github.com/owner/repo           (HTTPS, no .git)
#   - ssh://git@github.com/owner/repo(.git)   (full SSH URL)
# A non-github.com host returns empty so the caller can fall back / WARN.
parse_owner_repo_from_remote_url() {
  local url="$1"
  [ -n "$url" ] || { printf ''; return 0; }

  local stripped="$url"
  # ssh://git@github.com/owner/repo(.git)
  stripped="${stripped#ssh://git@github.com/}"
  # https://github.com/owner/repo(.git)
  stripped="${stripped#https://github.com/}"
  stripped="${stripped#http://github.com/}"
  # git@github.com:owner/repo(.git)
  stripped="${stripped#git@github.com:}"

  # If none of the prefixes matched, this is not a github.com URL.
  if [ "$stripped" = "$url" ]; then
    printf ''
    return 0
  fi

  # Trim a trailing .git if present.
  stripped="${stripped%.git}"
  # Trim trailing slashes.
  stripped="${stripped%/}"

  # We expect exactly owner/repo now — reject anything else (e.g. URLs with
  # extra path segments) so callers see a clean empty signal rather than a
  # malformed string.
  case "$stripped" in
    */*)
      # exactly one slash, both halves non-empty
      local owner="${stripped%%/*}"
      local repo="${stripped#*/}"
      case "$repo" in
        */*) printf '' ;;        # more than one slash -> reject
        *)
          if [ -n "$owner" ] && [ -n "$repo" ]; then
            printf '%s/%s' "$owner" "$repo"
          else
            printf ''
          fi
          ;;
      esac
      ;;
    *) printf '' ;;
  esac
}

# resolve_remote_to_owner_repo <repo-root> <remote-name>
# Returns 0 + prints "owner/repo" if the named remote exists in the clone and
# its URL parses; returns 1 + prints empty otherwise. Callers (the poller's
# (repo × remote) iteration; orchestrate.sh's `gh --repo` routing) use the
# return code to skip a missing/un-parseable remote with a WARNING instead of
# crashing the whole iteration.
resolve_remote_to_owner_repo() {
  local repo="$1"
  local remote="$2"
  local url
  if ! url=$(git -C "$repo" remote get-url "$remote" 2>/dev/null); then
    printf ''
    return 1
  fi
  local owner_repo
  owner_repo=$(parse_owner_repo_from_remote_url "$url")
  if [ -z "$owner_repo" ]; then
    printf ''
    return 1
  fi
  printf '%s' "$owner_repo"
}

# remote_label <remote> <issue-number>
# The canonical "namespaced issue label" used to derive lock dirs, run-ids and
# branches. Centralising the rule here is what makes backward compatibility for
# the origin remote a one-line invariant.
#   origin: "issue-<N>"
#   other:  "<remote>-issue-<N>"
remote_label() {
  local remote="$1"
  local n="$2"
  case "$remote" in
    origin|"") printf 'issue-%s' "$n" ;;
    *)         printf '%s-issue-%s' "$remote" "$n" ;;
  esac
}

# session_suffix <remote> <issue-number>
# Tmux session name suffix. UNLIKE remote_label, origin emits just "<N>" so the
# legacy session names (`run-issues-<N>`, `run-issues-restart-<N>`, …) are
# preserved exactly — changing them would orphan any session currently running
# on Studio. Non-origin remotes get the namespaced form. The poller's
# `tmux ls | grep '^run-issues-'` cap counter matches both shapes, so capacity
# accounting is unaffected.
#   origin: "<N>"               -> session `run-issues-<N>`
#   other:  "<remote>-issue-<N>" -> session `run-issues-<remote>-issue-<N>`
session_suffix() {
  local remote="$1"
  local n="$2"
  case "$remote" in
    origin|"") printf '%s' "$n" ;;
    *)         printf '%s-issue-%s' "$remote" "$n" ;;
  esac
}
