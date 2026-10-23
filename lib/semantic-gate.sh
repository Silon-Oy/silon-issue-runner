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
# Functions only, no top-level work.

# Byte cap on the sibling diffs fed to the review prompt (same order as the CI
# log excerpt): a sweeping sibling must not crowd the review out of its context.
PR_WATCH_SEMANTIC_CONTEXT_MAX="${PR_WATCH_SEMANTIC_CONTEXT_MAX:-60000}"

# The head-branch prefix of the runner's own PRs (orchestrate.sh's branch name).
SEMANTIC_SIBLING_PREFIX="auto-run/"

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
  jq -r --arg p "$SEMANTIC_SIBLING_PREFIX" --argjson me "${this:-0}" '
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
