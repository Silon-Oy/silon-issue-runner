#!/usr/bin/env bash
# lib/version.sh — make the ACTUALLY-RUNNING runner version visible.
#
# The package installs two ways (CLAUDE.md §3), and only one drifts:
#   * default    — a symlink to a dev clone; advances on `git pull`.
#   * maintainer — a pinned dotfiles submodule; advances only on an explicit
#                  bump, and nothing used to reveal when it had fallen behind.
#
# That blind spot produced three consecutive wrong diagnoses in one incident
# (issue #32): the running submodule sat 14 commits behind origin/main, so every
# fix the runner merged into main changed nothing — yet no log line, situation
# report, or `git pull` in the dev clone (`Already up to date`) could show it.
#
# These helpers read the git metadata of a given directory (the package root,
# resolved from each caller's SCRIPT_DIR / RUN_ISSUES_HOME) so the running
# version is visible in poller logs, the orchestrator's --version flag, and
# situation comments. Every function is FAIL-SOFT: a missing .git, a detached
# worktree, or no network yields "?" rather than an error, because visibility
# must never gate a run. Pure functions, no top-level work — safe to source.

# _runner_file_mtime <path> — file mtime as Unix epoch seconds, or empty on
# failure. macOS `stat -f %m`; GNU `stat -c %Y` is the Linux fallback (the
# tests run on either).
_runner_file_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || printf ''
}

# runner_version <dir> — short HEAD sha of <dir>'s git repo, or "?".
runner_version() {
  local dir="$1"
  git -C "$dir" rev-parse --short HEAD 2>/dev/null || printf '?'
}

# _runner_base_ref <dir> — the upstream ref to measure drift against. Prefers
# the remote's own default branch (origin/HEAD -> origin/main on most repos),
# falling back to origin/main when the symbolic ref is unset (common on clones
# added with `git remote add`, which carry no origin/HEAD). Empty on failure.
_runner_base_ref() {
  local dir="$1" ref
  ref=$(git -C "$dir" rev-parse --abbrev-ref origin/HEAD 2>/dev/null) || ref=""
  if [ -z "$ref" ] || [ "$ref" = "origin/HEAD" ]; then
    ref="origin/main"
  fi
  printf '%s' "$ref"
}

# runner_behind_origin <dir> — number of commits <dir>'s HEAD is behind its
# upstream default branch, or "?" when it cannot be computed (no .git, no
# upstream ref, no fetch ever run). "0" means up to date. The count is only as
# fresh as the last fetch — see runner_fetch_throttled.
runner_behind_origin() {
  local dir="$1" base count
  base=$(_runner_base_ref "$dir")
  [ -n "$base" ] || { printf '?'; return 0; }
  count=$(git -C "$dir" rev-list --count "HEAD..$base" 2>/dev/null) || { printf '?'; return 0; }
  printf '%s' "$count"
}

# runner_version_summary <dir> — one-line human string for reports and the
# --version flag: "<sha> (N commits behind origin/main)" when drifted,
# "<sha> (up to date)" when even, or bare "<sha>" when the drift is unknown.
runner_version_summary() {
  local dir="$1" ver behind
  ver=$(runner_version "$dir")
  behind=$(runner_behind_origin "$dir")
  case "$behind" in
    '?') printf '%s' "$ver" ;;
    0)   printf '%s (up to date)' "$ver" ;;
    *)   printf '%s (%s commits behind origin/main)' "$ver" "$behind" ;;
  esac
}

# runner_fetch_throttled <dir> <stamp-file> [<interval-secs>] [<timeout-bin>]
# Best-effort `git fetch origin` of <dir>, at most once per <interval-secs>
# (default 3600). The behind-count is only as fresh as the last fetch; a pinned
# submodule that never fetches would otherwise compare against a stale
# origin/main and under-report its own drift — the exact way issue #32 stayed
# invisible. The pollers run every 300s, so an unthrottled fetch would hit the
# network twelve times an hour for a number that changes at merge cadence.
#
# The stamp file's mtime is the throttle, so no long-lived state is needed. It
# is touched BEFORE the fetch, so a slow or hung fetch is attempted at most once
# per interval rather than every tick. <timeout-bin> (from preflight_timeout_bin)
# caps a hung fetch when available; without it the fetch runs unbounded, the same
# contract claude-call.sh documents for a machine without coreutils. Always
# returns 0 — a fetch is a diagnostic aid, never a gate.
runner_fetch_throttled() {
  local dir="$1" stamp="$2" interval="${3:-3600}" tbin="${4:-}"
  local now mt age
  if [ -f "$stamp" ]; then
    now=$(date -u +%s)
    mt=$(_runner_file_mtime "$stamp")
    if [ -n "$mt" ]; then
      age=$(( now - mt ))
      [ "$age" -ge "$interval" ] || return 0
    fi
  fi
  : > "$stamp" 2>/dev/null || true
  if [ -n "$tbin" ]; then
    "$tbin" 30 git -C "$dir" fetch --quiet origin 2>/dev/null || true
  else
    git -C "$dir" fetch --quiet origin 2>/dev/null || true
  fi
  return 0
}
