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
# failure. The `stat` format flag is not portable and the two spellings are NOT
# safely chainable: BSD/macOS reads `-f` as the output format, GNU coreutils
# reads it as --file-system and answers a `stat -f %m <path>` call by printing a
# whole filesystem report on stdout AND failing — so a `||` fallback appends the
# real mtime to that report instead of replacing it, and the caller's arithmetic
# then dies on `File: unbound variable`. Branch on `uname -s` like every sibling
# call site (lib/locking.sh:_lock_mtime, lib/machine-env.sh, lib/paths.sh).
_runner_file_mtime() {
  local mtime
  if [ "$(uname -s)" = "Darwin" ]; then
    mtime=$(stat -f %m "$1" 2>/dev/null) || return 0
  else
    mtime=$(stat -c %Y "$1" 2>/dev/null) || return 0
  fi
  # A successful stat that yields non-numeric output is treated as a failure:
  # the callers feed this straight into $(( )).
  case "$mtime" in
    ''|*[!0-9]*) return 0 ;;
  esac
  printf '%s' "$mtime"
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

# _runner_pinned_full <dir> — full sha of the commit the SUPERPROJECT pins this
# working tree at, or "" when <dir> is not a submodule, or "?" when a superproject
# exists but its pin cannot be read. The maintainer install model (CLAUDE.md §3)
# mounts the package as a pinned dotfiles submodule; the default model (a symlinked
# clone) is not a submodule, so `--show-superproject-working-tree` is empty and the
# package falls back to the plain two-tier state with no special case (issue #105).
# The dotfiles path is NEVER hardcoded — the superproject is discovered generically.
_runner_pinned_full() {
  local dir="$1" super top rel sha
  super=$(git -C "$dir" rev-parse --show-superproject-working-tree 2>/dev/null) || super=""
  # Empty => not a submodule => no pin. This is the default install model.
  [ -n "$super" ] || { printf ''; return 0; }
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || { printf '?'; return 0; }
  # Canonicalise both so a symlinked tmp path (/tmp -> /private/tmp on macOS) does
  # not break the prefix match below.
  super=$(cd "$super" 2>/dev/null && pwd -P) || { printf '?'; return 0; }
  top=$(cd "$top" 2>/dev/null && pwd -P) || { printf '?'; return 0; }
  # rel = the submodule working tree's path relative to the superproject.
  case "$top" in
    "$super")   rel="" ;;
    "$super"/*) rel="${top#"$super"/}" ;;
    *)          printf '?'; return 0 ;;
  esac
  [ -n "$rel" ] || { printf '?'; return 0; }
  # The gitlink records the pinned commit sha; `HEAD:<rel>` resolves it WITHOUT
  # the commit object needing to be present locally (a fetch may be pending).
  sha=$(git -C "$super" rev-parse "HEAD:$rel" 2>/dev/null) || { printf '?'; return 0; }
  printf '%s' "$sha"
}

# runner_pinned_version <dir> — short sha of the superproject's pin for this
# working tree, "" when not a submodule, "?" when unreadable. Fail-soft like
# runner_version. The abbreviation uses <dir>'s own object db when the commit is
# present, else the full sha is returned (a pin can reference a not-yet-fetched
# commit — issue #105 edge case).
runner_pinned_version() {
  local dir="$1" full
  full=$(_runner_pinned_full "$dir")
  case "$full" in
    ''|'?') printf '%s' "$full"; return 0 ;;
  esac
  git -C "$dir" rev-parse --short "$full" 2>/dev/null || printf '%s' "$full"
}

# runner_update_state <dir> — one of four words describing the runner's version
# state, DERIVED from the existing pieces (no new network call, issue #105):
#   pin_pending      the superproject pins a commit DIFFERENT from this working
#                    tree's HEAD. The parent-repo sync is deferring the pin bump
#                    (typically because a run is live); it self-corrects on the
#                    next idle. This is NEUTRAL, not a warning.
#   behind_upstream  pin == HEAD, but HEAD is behind origin — upstream advanced and
#                    the pin has not been bumped yet.
#   up_to_date       pin == HEAD (or no submodule) and behind == 0.
#   unknown          the drift cannot be computed (no origin ref / never fetched)
#                    or the superproject pin is unreadable. NEVER shown as OK.
# The pin comparison uses FULL shas so it does not depend on two repos abbreviating
# the same commit to the same length; the sha compare needs no local object.
runner_update_state() {
  local dir="$1" pinned_full head_full behind
  pinned_full=$(_runner_pinned_full "$dir")
  [ "$pinned_full" = "?" ] && { printf 'unknown'; return 0; }
  if [ -n "$pinned_full" ]; then
    head_full=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || head_full=""
    [ -n "$head_full" ] || { printf 'unknown'; return 0; }
    if [ "$pinned_full" != "$head_full" ]; then printf 'pin_pending'; return 0; fi
  fi
  behind=$(runner_behind_origin "$dir")
  case "$behind" in
    '?') printf 'unknown' ;;
    0)   printf 'up_to_date' ;;
    *)   printf 'behind_upstream' ;;
  esac
}

# runner_pin_commit_epoch <dir> — committer epoch of the pinned commit, IF that
# object is present in <dir>'s own object db, else "" (a pin can reference a commit
# not yet fetched locally — issue #105 edge case). Lets a caller show HOW LONG a
# pin has waited, but only when the age can actually be measured.
runner_pin_commit_epoch() {
  local dir="$1" full
  full=$(_runner_pinned_full "$dir")
  case "$full" in ''|'?') printf ''; return 0 ;; esac
  git -C "$dir" show -s --format=%ct "$full" 2>/dev/null || printf ''
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
