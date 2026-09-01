#!/usr/bin/env bash
# lib/git-remote.sh — multi-remote (multi-org) helpers for /run-issues.
#
# One local clone can poll multiple GitHub orgs at once when a repo entry in
# the watchlist lists more than one git remote in its `remotes` array. The
# orchestrator and poller must then namespace per-run identity by the remote so
# `Silon-Oy/...#5` and `partner-org/...#5` do not collide on the same lock / tmux
# session / branch / run-dir, and must route every gh call to the issue's own
# org via `gh --repo owner/repo`.
#
# This file is purposely small and pure (no side effects beyond calling
# `git remote get-url`), so the parsing functions can be unit-tested offline.
# Sourced by orchestrate.sh, poller.sh, and the test harness; no top-level work.
#
# Repo component (issue #67):
#   The isolation key of a run is (repo, remote, issue) — NOT (remote, issue).
#   Studio's watchlist carries a dozen repos, so two repos' issue #42 used to
#   collide on the same lock (`issue-42.lock`) and the same tmux session
#   (`run-issues-42`): the poller starved the second repo silently, and
#   finalize_stalled could delete a live run's lock in a DIFFERENT repo. The
#   repo component is therefore part of every derived identifier, and it is
#   derived here so lock / run-id / branch / tmux naming cannot drift apart.
#
# Backward compatibility (two layers, both deliberate):
#   - Remote: when the remote is "origin", the remote part of every identifier
#     collapses to the legacy shape; only non-origin remotes get the <remote>-
#     infix (issue #53).
#   - Repo: the repo component is an OPTIONAL third argument. Omit it and the
#     function returns exactly the pre-#67 name. Callers that own a run pass the
#     slug recorded in run.json — which is empty for runs created before #67, so
#     an in-flight run keeps the names it was started with for its whole life
#     (its lock and tmux session stay reachable; nothing is orphaned).

set -euo pipefail

# Upper bound for the repo component. Repo names are short in practice; the cap
# only bounds pathological input so lock dirs, tmux session names and git branch
# names stay readable and well inside filesystem / git ref limits.
RUN_ISSUES_REPO_SLUG_MAX="${RUN_ISSUES_REPO_SLUG_MAX:-40}"

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

# slugify_repo_component <string>
# Normalises an arbitrary string into a filename-, tmux- and git-ref-safe token:
# lowercase, every run of non-alphanumerics collapsed to a single `-`, no
# leading/trailing `-`, capped at RUN_ISSUES_REPO_SLUG_MAX characters.
#
# Why each rule is load-bearing:
#   - `owner/repo` contains `/`, which cannot go into a directory name.
#   - tmux rejects `.` and `:` in session names, and repo names contain dots in
#     practice (`foo.dev`), so the whitelist approach is safer than a blocklist.
#   - lowercase: macOS filesystems are case-insensitive by default while Linux
#     is not, so `Silon-Oy-x` vs `silon-oy-x` would be one lock dir on one
#     platform and two on the other. Folding removes the divergence.
# Uses `tr`/`sed`/`cut` rather than bash 4 `${x,,}` — macOS ships bash 3.2.
slugify_repo_component() {
  printf '%s' "${1:-}" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9][^a-z0-9]*/-/g' -e 's/^-*//' -e 's/-*$//' \
    | cut -c "1-${RUN_ISSUES_REPO_SLUG_MAX}" \
    | sed -e 's/-*$//'
}

# repo_slug <repo-root> [<remote>]
# Prints the deterministic repo component for a run's identity, or empty when
# neither source is available. Never fails (rc=0) — callers treat an empty slug
# as "legacy naming", which is a valid state, not an error.
#
# Source preference:
#   1. `owner/repo` from the remote URL — this is the identity of the GitHub
#      issue namespace, so it is the semantically correct key: two clones of the
#      same owner/repo SHOULD share a lock, and two different repos never should.
#   2. basename of the repo root — fallback for a clone with no (parseable)
#      remote, e.g. the test fixtures and purely local repos.
repo_slug() {
  local repo="${1:-}"
  local remote="${2:-origin}"
  [ -n "$repo" ] || { printf ''; return 0; }
  local owner_repo=""
  owner_repo=$(resolve_remote_to_owner_repo "$repo" "$remote" 2>/dev/null) || owner_repo=""
  local raw="$owner_repo"
  [ -n "$raw" ] || raw="$(basename "$repo")"
  slugify_repo_component "$raw"
}

# remote_label <remote> <issue-number> [<repo-slug>]
# The canonical "namespaced issue label" used to derive lock dirs, run-ids and
# branches. Centralising the rule here is what makes backward compatibility for
# the origin remote and for pre-#67 runs a one-line invariant.
#   no slug, origin: "issue-<N>"                     (legacy, pre-#53)
#   no slug, other:  "<remote>-issue-<N>"            (legacy, pre-#67)
#   slug, origin:    "<repo-slug>-issue-<N>"
#   slug, other:     "<repo-slug>-<remote>-issue-<N>"
remote_label() {
  local remote="$1"
  local n="$2"
  local slug="${3:-}"
  local base
  case "$remote" in
    origin|"") base="issue-$n" ;;
    *)         base="$remote-issue-$n" ;;
  esac
  if [ -n "$slug" ]; then
    printf '%s-%s' "$slug" "$base"
  else
    printf '%s' "$base"
  fi
}

# session_suffix <remote> <issue-number> [<repo-slug>]
# Tmux session name suffix. UNLIKE remote_label, the no-slug origin case emits
# just "<N>" so the legacy session names (`run-issues-<N>`,
# `run-issues-restart-<N>`, …) are reproducible exactly — the poller checks for
# them during the transition window so a session started by the previous poller
# version is still recognised as running. The poller's
# `tmux ls | grep '^run-issues-'` cap counter matches every shape, so capacity
# accounting is unaffected.
#   no slug, origin: "<N>"                      -> `run-issues-<N>`
#   no slug, other:  "<remote>-issue-<N>"       -> `run-issues-<remote>-issue-<N>`
#   slug, origin:    "<repo-slug>-<N>"          -> `run-issues-<repo-slug>-<N>`
#   slug, other:     "<repo-slug>-<remote>-issue-<N>"
session_suffix() {
  local remote="$1"
  local n="$2"
  local slug="${3:-}"
  local base
  case "$remote" in
    origin|"") base="$n" ;;
    *)         base="$remote-issue-$n" ;;
  esac
  if [ -n "$slug" ]; then
    printf '%s-%s' "$slug" "$base"
  else
    printf '%s' "$base"
  fi
}
