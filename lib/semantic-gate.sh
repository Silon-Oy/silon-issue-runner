#!/usr/bin/env bash
# lib/semantic-gate.sh — the semantic-conflict merge gate's pure parts (issue #341).
#
# A semantic conflict is two runner branches that merge without a textual
# conflict but together leave two implementations of the same thing, a shadowing
# abstraction or contradicting conventions. pr-watch.sh runs the `semantic` gate
# through the generic merge-gate mechanism (lib/merge-gate.sh); this module only
# decides, deterministically and without an agent, whether there is anything to
# look at: a sibling runner PR (`auto-run/` head) merged into the base while this
# run was in flight, whose changes touch a directory this PR also touches.
#
# Siblings are found from the PR listing, not from merge commits: the watcher
# merges with --rebase first, so most sibling PRs leave no merge commit on the
# base. GitHub's merge_commit_sha is the commit the base was updated to, for every
# merge method, and it lies on the base's first-parent chain.
#
# Functions only, no top-level work — except loading lib/rate-limit.sh when the
# caller has not (semantic_list_error_kind needs rate_limit_matches; pr-watch.sh
# loads it itself).

if ! command -v rate_limit_matches >/dev/null 2>&1; then
  # shellcheck source=rate-limit.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rate-limit.sh"
fi
# shellcheck source=runner-pr.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/runner-pr.sh"

# Byte cap on the sibling diffs fed to the review prompt (same order as the CI
# log excerpt): a sweeping sibling must not crowd the review out of its context.
PR_WATCH_SEMANTIC_CONTEXT_MAX="${PR_WATCH_SEMANTIC_CONTEXT_MAX:-60000}"

# How many of the base's newest first-parent commits the window looks at. A
# bound, so the walk is O(work) (CLAUDE.md §5.4); a window that fills it is
# reported as cut short, never as complete.
SEMANTIC_WINDOW_MAX=500

# The closed-PR listing (runner_merged_prs, lib/runner-pr.sh) is read page by
# page, newest update first, and only as far as the window reaches. A bound, not
# --paginate (CLAUDE.md §5.4) — a listing that still reaches into the window on
# its last page is "could not decide", never a pass.
SEMANTIC_LIST_MAX_PAGES=3

# semantic_window <since-iso> — reads "<sha> <committer-time>" lines of the base's
# first-parent chain on stdin, newest first, the time as YYYY-MM-DDTHH:MM:SSZ in
# UTC (comparable as a string with run.json's started_at). Prints the shas
# committed at or after <since-iso>, oldest first.
#
# Every line is filtered; the walk does not stop at the first older commit.
# `git rev-list --since` does stop there, so a commit a human made before the
# run and pushed during it hid every sibling merged before it — a silent pass.
# (`--since-as-filter` would do this in git, but needs git 2.42.)
#
# rc 2 when all SEMANTIC_WINDOW_MAX lines are in the window: the walk may have
# cut it short, and a partial window is not a pass.
semantic_window() {
  local since="${1:-}"
  awk -v since="$since" -v max="$SEMANTIC_WINDOW_MAX" '
    NF >= 2 { n++; if ($2 >= since) { keep[++k] = $1 } else { older = 1 } }
    END {
      for (i = k; i >= 1; i--) print keep[i]
      if (n >= max && !older) exit 2
    }'
}

# semantic_dirs_of — paths on stdin, their directories on stdout, sorted and
# unique. A root-level file is `.`.
semantic_dirs_of() {
  awk 'NF { p = $0; if (sub(/\/[^\/]*$/, "", p) == 0) p = "."; print p }' | LC_ALL=C sort -u
}

# semantic_dirs_overlap <dirs-a> <dirs-b> — the directories (newline lists, as
# semantic_dirs_of prints them) present in both, one per line.
semantic_dirs_overlap() {
  local a="$1" b="$2"
  [ -n "$a" ] && [ -n "$b" ] || return 0
  printf '%s\n' "$b" | awk 'NR == FNR { if (NF) want[$0] = 1; next } NF && ($0 in want)' \
    <(printf '%s\n' "$a") - | LC_ALL=C sort -u
}

# semantic_merged_siblings <pulls-json> <this-pr> — the merged runner PRs of a
# REST `pulls?state=closed` listing, other than <this-pr>, as
# "<number>\t<head-ref>\t<merge_commit_sha>" lines. rc 1 if the JSON is not an
# array: an unreadable listing is not "no siblings".
semantic_merged_siblings() {
  local json="$1" this="$2"
  jq -r --arg p "$RUNNER_BRANCH_PREFIX" --argjson me "${this:-0}" '
    if type != "array" then error("not an array") else . end
    | .[]
    | select(.merged_at != null and (.merge_commit_sha // "") != "")
    | select(((.head.ref // "") | startswith($p)) and .number != $me)
    | "\(.number)\t\(.head.ref)\t\(.merge_commit_sha)"' <<<"$json" 2>/dev/null
}

# semantic_sibling_spans <range> <siblings> — attribute the base's first-parent
# commits to the sibling PRs merged among them.
#   <range>    first-parent commits of the base, OLDEST first, one sha per line;
#              the first line is the boundary (the commit before the range)
#   <siblings> semantic_merged_siblings lines
# Prints "<number>\t<head-ref>\t<from-sha>\t<to-sha>" for each sibling whose
# merge_commit_sha is in the range: its span runs from the previous sibling's
# commit (or the boundary) to its own. A rebase-merged PR is several commits, and
# the span covers them all. A commit of nobody's PR between two siblings is
# attributed to the later one: that can only add a review, never skip one.
semantic_sibling_spans() {
  local range="$1" siblings="$2"
  [ -n "$range" ] && [ -n "$siblings" ] || return 0
  awk -F'\t' '
    NR == FNR { if (NF >= 3) { num[$3] = $1; ref[$3] = $2 } next }
    NF {
      if (prev == "") { prev = $1; next }
      if ($1 in num) { printf "%s\t%s\t%s\t%s\n", num[$1], ref[$1], prev, $1; prev = $1 }
    }' <(printf '%s\n' "$siblings") <(printf '%s\n' "$range")
}

# semantic_list_error_kind <stderr-text> — "permanent" or "transient" for a
# failed listing. Permanent is an authorization / not-found answer (HTTP 401,
# 403, 404) that is not a rate-limit rejection: GitHub throttles with 403 too, and
# the match is textual (CLAUDE.md §5.1). Everything else — network, 5xx, an
# unknown message — is transient: a retry next poll may succeed.
semantic_list_error_kind() {
  local err="${1:-}"
  if rate_limit_matches "$err"; then printf 'transient'; return 0; fi
  case "$err" in
    *"HTTP 401"*|*"HTTP 403"*|*"HTTP 404"*) printf 'permanent' ;;
    *) printf 'transient' ;;
  esac
}
