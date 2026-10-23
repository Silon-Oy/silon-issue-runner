#!/usr/bin/env bash
# lib/pr-surface.sh — the combined change surface of a set of PRs: every file
# the PRs changed, each naming the references that touched it.
#
# Shared by two readers that ask different questions of the same material
# (CLAUDE.md §7): the epic review (lib/epic-review.sh, #272) labels a file with
# the CHILD ISSUES whose PRs touched it, the coherence audit
# (coherence-audit.sh, #342) with the PRs themselves. The caller picks the
# reference; the reading, the fail-closed rule and the combined line format live
# here once.
#
# FAIL-CLOSED. One unreadable PR file list => rc 1 and EMPTY stdout: a partial
# surface would yield a confident review of missing material.
#
# Defines functions only; no top-level work and no `set`. Needs gh on PATH.

# pr_surface_files <owner/repo> <pr-N> — print the files changed by a PR, one
# per line. rc 1 on any read failure. REST, not search (CLAUDE.md §5.2).
pr_surface_files() {
  local owner_repo="$1" pr="$2"
  gh api --paginate "repos/$owner_repo/pulls/$pr/files" --jq '.[].filename' 2>/dev/null || return 1
}

# review_pr_surface — read lines `<owner/repo>\t<pr-N>\t<reference>` on stdin
# and print one line per changed file:
#
#   - `path/to/file` (<reference>, <reference>)
#
# sorted by file, references deduplicated and sorted. No input => no output,
# rc 0. rc 1 (and nothing on stdout) when any PR's file list is unreadable.
review_pr_surface() {
  local line owner_repo pr ref files f surface=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS=$'\t' read -r owner_repo pr ref <<<"$line"
    [ -n "$pr" ] || continue
    files=$(pr_surface_files "$owner_repo" "${pr#\#}") || return 1
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      surface+="${f}"$'\t'"${ref}"$'\n'
    done <<FILES
$files
FILES
  done
  [ -n "$surface" ] || return 0
  printf '%s' "$surface" | LC_ALL=C sort -u | awk -F'\t' '
    $1 != prev { if (NR > 1) print out ")"; out = "- `" $1 "` (" $2; prev = $1; next }
    { out = out ", " $2 }
    END { if (NR > 0) print out ")" }'
}
