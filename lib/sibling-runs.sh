#!/usr/bin/env bash
# lib/sibling-runs.sh — the other runs working on the same repo right now
# (issue #337).
#
# Runs do not know about each other, so two parallel runs can implement the same
# thing twice. This module lists a run's SIBLINGS so the cycle review (S6) can
# name an overlap and tell the Implementer what not to build. It is advisory: an
# optimisation, not a gate. A read failure therefore never blocks a run — it is
# reported in the prompt as such, never as an empty list (an empty list would
# claim "no siblings", which is a statement the run cannot make).
#
# Two sources:
#   remote — open runner PRs (`auto-run/` head branches) from ONE REST listing
#            per repo (CLAUDE.md §5.2: REST, never the search connection). The
#            changed files come from the local remote-tracking refs S4's fetch
#            already brought in, so the gh cost stays exactly one call (§5.4).
#   local  — this machine's live runs from the run-dirs: status=initialized and
#            host == runner_host, the same predicate as self-update.sh's
#            has_live_run. Only the `status`/`host`/`remote` fields of a run.json
#            are read before the predicate; git and issue.json work is done for
#            live runs only, so terminal run-dirs cost one local file read and
#            nothing else. Another machine's live runs become visible as PRs.
#
# A run that appears in both sources (a live local run that already has a PR) is
# listed once, and the local entry wins: its worktree diff is the fresher view.
#
# Functions only, no top-level work — safe to source from orchestrate.sh and
# from tests in isolation. Pulls in its own deps.

set -euo pipefail

_SIBLING_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=issue.sh
. "$_SIBLING_LIB_DIR/issue.sh"
# shellcheck source=host.sh
. "$_SIBLING_LIB_DIR/host.sh"

# Files listed per sibling before the rest is summarised as a count, so a
# sibling with a sweeping diff does not bloat the review prompt.
SIBLING_RUNS_MAX_FILES=30

# _sibling_changed_files <git-dir> <base-ref> <head-ref>
# Prints a JSON array of the paths changed on <head-ref> since it forked from
# <base-ref>, or `null` when either ref does not resolve (files unavailable is a
# different statement from "no files changed").
_sibling_changed_files() {
  local dir="$1" base="$2" head="$3" out
  if ! out=$(git -C "$dir" diff --name-only "$base...$head" 2>/dev/null); then
    printf 'null'
    return 0
  fi
  printf '%s' "$out" | jq -R -s -c 'split("\n") | map(select(. != ""))'
}

# _sibling_remote_base <git-dir> <remote> <base-branch>
# The ref a branch forked from: <remote>/<base-branch>, or the remote's default
# HEAD when no base branch was recorded — the same resolution create_worktree
# uses.
_sibling_remote_base() {
  local dir="$1" remote="$2" base="${3:-}"
  if [ -n "$base" ]; then
    printf '%s/%s' "$remote" "$base"
  else
    git -C "$dir" symbolic-ref --short "refs/remotes/$remote/HEAD" 2>/dev/null \
      || printf '%s/HEAD' "$remote"
  fi
}

# _sibling_remote_prs <repo-root> <owner/repo> <remote>
# One REST listing; prints one compact JSON object per open runner PR:
# {issue, title, started_at, source:"pr", pr, branch, base}. rc 2 when the
# listing fails or does not return a JSON array.
_sibling_remote_prs() {
  local repo_root="$1" owner_repo="$2" remote="$3" raw
  raw=$(cd "$repo_root" && _issue_gh --remote "$remote" -- api \
    "$(_rest_pulls_path "$owner_repo" "state=open&per_page=100")") || return 2
  printf '%s' "$raw" | jq -e 'type == "array"' >/dev/null 2>&1 || return 2
  printf '%s' "$raw" | jq -c '
    .[]
    | select((.head.ref // "") | startswith("auto-run/"))
    | {
        issue: ((.body // "")
                | [match("(?i)\\b(?:closes|fixes|resolves)\\s+#([0-9]+)"; "g")
                   | .captures[0].string | tonumber] | first),
        title: (.title // ""),
        started_at: (.created_at // ""),
        source: "pr",
        pr: .number,
        branch: .head.ref,
        base: (.base.ref // "")
      }'
}

# _sibling_run_is_live_here <run.json> <this-host>
# The live-run predicate of self-update.sh's has_live_run: status=initialized
# (a missing status reads as initialized) and the host is this machine (an empty
# host is a pre-host-field run.json, read as local).
_sibling_run_is_live_here() {
  local rj="$1" this_host="$2" status host
  status=$(jq -r '.status // "initialized"' "$rj" 2>/dev/null) || return 1
  [ "$status" = "initialized" ] || return 1
  host=$(jq -r '.host // ""' "$rj" 2>/dev/null) || return 1
  [ -z "$host" ] || [ "$host" = "$this_host" ]
}

# _sibling_local_runs <repo-root> <remote> <self-run-dir>
# Prints one compact JSON object per live local run of the same remote other
# than <self-run-dir>: {issue, title, started_at, source:"local", branch, files}.
_sibling_local_runs() {
  local repo_root="$1" remote="$2" self_run_dir="${3:-}"
  local this_host rj rd self_real="" rd_real run_remote meta wt base_branch base title files
  this_host=$(runner_host)
  [ -n "$self_run_dir" ] && self_real=$(cd "$self_run_dir" 2>/dev/null && pwd -P || printf '%s' "$self_run_dir")
  local -a rjs=()
  local nullglob_was=0
  shopt -q nullglob && nullglob_was=1
  shopt -s nullglob
  rjs=("$repo_root"/.claude/run-issues/*/run.json)
  [ "$nullglob_was" = 1 ] || shopt -u nullglob

  for rj in ${rjs[@]+"${rjs[@]}"}; do
    rd=$(dirname "$rj")
    rd_real=$(cd "$rd" && pwd -P)
    [ "$rd_real" = "$self_real" ] && continue
    _sibling_run_is_live_here "$rj" "$this_host" || continue
    run_remote=$(jq -r '.remote // "origin"' "$rj" 2>/dev/null) || continue
    [ "$run_remote" = "$remote" ] || continue

    meta=$(jq -c '{issue: .issue_number, started_at: (.started_at // ""),
                   branch: (.branch // ""), worktree: (.worktree_path // ""),
                   base: (.base_branch // "")}' "$rj" 2>/dev/null) || continue
    wt=$(printf '%s' "$meta" | jq -r '.worktree')
    base_branch=$(printf '%s' "$meta" | jq -r '.base')
    title=""
    [ -f "$rd/issue.json" ] && title=$(jq -r '.title // ""' "$rd/issue.json" 2>/dev/null || true)
    files=null
    if [ -n "$wt" ] && [ -d "$wt" ]; then
      base=$(_sibling_remote_base "$wt" "$remote" "$base_branch")
      files=$(_sibling_changed_files "$wt" "$base" HEAD)
    fi
    printf '%s' "$meta" | jq -c --arg title "$title" --argjson files "$files" \
      '{issue, title: $title, started_at, source: "local", branch, files: $files}'
  done
}

# list_sibling_runs <repo-root> <owner/repo> <remote> <self-run-dir> <self-issue>
# Prints one compact JSON object per sibling run, local entries first:
#   {issue, title, started_at, source: "local"|"pr", pr?, branch, files}
# `files` is an array of paths, or null when they could not be resolved.
# <owner/repo> empty = gh's cwd-based {owner}/{repo}, like the issue.sh helpers.
# rc 0 = the list is complete (possibly empty); rc 2 = the PR listing failed,
# and nothing is printed: a partial list would read as a complete one.
list_sibling_runs() {
  local repo_root="$1" owner_repo="${2:-}" remote="${3:-origin}"
  local self_run_dir="${4:-}" self_issue="${5:-}"
  local prs local_runs pr base files seen
  prs=$(_sibling_remote_prs "$repo_root" "$owner_repo" "$remote") || return 2
  local_runs=$(_sibling_local_runs "$repo_root" "$remote" "$self_run_dir")

  seen=$(printf '%s\n' "$local_runs" | jq -s -c '[.[] | .issue]')
  if [ -n "$local_runs" ]; then
    printf '%s\n' "$local_runs" \
      | jq -c --arg self "$self_issue" 'select((.issue | tostring) != $self)'
  fi
  [ -n "$prs" ] || return 0
  while IFS= read -r pr; do
    [ -n "$pr" ] || continue
    if printf '%s' "$pr" | jq -e --arg self "$self_issue" --argjson seen "$seen" \
         '.issue != null and (((.issue | tostring) == $self) or (.issue as $i | $seen | index($i)))' \
         >/dev/null; then
      continue
    fi
    base=$(_sibling_remote_base "$repo_root" "$remote" "$(printf '%s' "$pr" | jq -r '.base')")
    files=$(_sibling_changed_files "$repo_root" "$base" \
      "$remote/$(printf '%s' "$pr" | jq -r '.branch')")
    printf '%s' "$pr" | jq -c --argjson files "$files" 'del(.base) + {files: $files}'
  done <<EOF
$prs
EOF
}

# sibling_runs_section <repo-root> <owner/repo> <remote> <self-run-dir> <self-issue>
# Renders the prompt section body in one of three states: the list, the empty
# list said out loud, or the read failure said out loud. Always rc 0 — the
# section is an optimisation, never a reason for the caller to stop.
sibling_runs_section() {
  local rows rc=0
  rows=$(list_sibling_runs "$@" 2>/dev/null) || rc=$?
  if [ "$rc" != 0 ]; then
    printf '_Sisarajoja ei voitu lukea (avoimien PR:ien listaus epäonnistui). Rinnakkaisten ajojen tilaa ei tiedetä — tämä ei tarkoita, ettei niitä ole._\n'
    return 0
  fi
  if [ -z "$rows" ]; then
    printf '_Ei rinnakkaisia ajoja: tässä repossa ei ole muita käynnissä olevia ajoja eikä avoimia runnerin PR:iä._\n'
    return 0
  fi
  printf '%s\n' "$rows" | jq -r --argjson max "$SIBLING_RUNS_MAX_FILES" '
    (if .issue == null then "(issue tuntematon)" else "#\(.issue)" end) as $id
    | (if .source == "pr" then "PR #\(.pr)" else "paikallinen ajo" end) as $src
    | "- **\($id) \(.title)** · aloitettu \(.started_at) · lähde: \($src) · haara `\(.branch)`",
      (if .files == null then "  - _muuttuneita tiedostoja ei saatavilla_"
       elif (.files | length) == 0 then "  - _ei muuttuneita tiedostoja vielä_"
       else (.files[:$max][] | "  - `\(.)`"),
            (if (.files | length) > $max
             then "  - _… ja \((.files | length) - $max) muuta tiedostoa_" else empty end)
       end)'
}
