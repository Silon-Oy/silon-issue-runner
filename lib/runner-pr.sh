#!/usr/bin/env bash
# lib/runner-pr.sh — what makes a branch or a PR the runner's own (issue #375).
#
# RUNNER_BRANCH_PREFIX is the ONE definition of the runner's head-branch prefix:
# orchestrate.sh names branches with it, and every reader that tells a runner PR
# or branch from a human's (pick-up gates, merge gates, audits, teardown) asks
# it. A second literal would let naming and recognition drift apart silently.
#
# runner_merged_prs is the ONE listing of merged runner PRs: the semantic merge
# gate (pr-watch.sh) and the coherence audit both page the same REST listing,
# and two pagers had two different stop rules.
#
# runner_rest_list is the generic REST pager behind the read-only views: the
# digest's fix-rate meter and status.sh's human queue (#414) page through it.
#
# Functions and constants only, no top-level work, no dependencies.

RUNNER_BRANCH_PREFIX="auto-run/"

# Rows per listing page. The stop rule below compares a page's length with it.
RUNNER_PR_PER_PAGE=100

# runner_pr_page_needs_more <pulls-json> <since-iso> — whether the next page of
# an updated-desc listing may still hold a PR updated at or after <since-iso>:
# rc 0 when the page is full (RUNNER_PR_PER_PAGE rows) and its last row's
# updated_at is not older than <since-iso>; rc 1 otherwise. rc 2 if the page is
# not a JSON array. A PR's updated_at is never older than its merge, so a page
# that ends before the window has listed every PR merged in it.
runner_pr_page_needs_more() {
  local json="$1" since="$2" out
  out=$(jq -r --argjson n "$RUNNER_PR_PER_PAGE" --arg s "$since" '
    if type != "array" then error("not an array") else . end
    | if length >= $n and ((last.updated_at // "") >= $s) then "more" else "done" end' \
    <<<"$json" 2>/dev/null) || return 2
  [ "$out" = more ]
}

# runner_merged_prs <gh-runner> <owner/repo> <base> <since-iso> <max-pages> <err-file>
# The runner's PRs (RUNNER_BRANCH_PREFIX head) merged into <base>, as ONE JSON
# array of the listing's PR objects on stdout, read page by page newest update
# first and only as far as <since-iso> reaches (runner_pr_page_needs_more) — the
# cost is the work in the window, not the repo's PR history (CLAUDE.md §5.4).
# REST, never search (§5.2).
#
#   <gh-runner>   the command that runs `gh` for the caller (`gh_route`,
#                 `labels_gh`, …) — the caller picks identity and rate-limit route
#   <owner/repo>  empty = `{owner}/{repo}` (gh resolves it from the cwd)
#   <base>        the base branch, raw; it is URI-encoded here
#   <err-file>    a failed page's stderr is written here for the caller to classify
#
# The window and "not this PR" are the caller's: the listing filters only on
# merged_at != null and the prefix.
#
# rc 0 complete · 1 a page could not be read (stderr in <err-file>) · 2 a page was
# not a JSON array · 3 <max-pages> pages read and the last one still reaches
# into the window: the list may be cut short, so it is never a complete answer.
runner_merged_prs() {
  local gh_runner="$1" owner_repo="$2" base="$3" since="$4" max="$5" errf="$6"
  local base_q page=1 json picked all="" more=0
  [ -n "$owner_repo" ] || owner_repo='{owner}/{repo}'
  base_q=$(jq -rn --arg s "$base" '$s|@uri') || return 2
  while :; do
    : > "$errf"
    json=$("$gh_runner" api "repos/$owner_repo/pulls?state=closed&base=$base_q&sort=updated&direction=desc&per_page=$RUNNER_PR_PER_PAGE&page=$page" 2>"$errf") \
      || return 1
    picked=$(jq -c --arg p "$RUNNER_BRANCH_PREFIX" '
      if type != "array" then error("not an array") else . end
      | [ .[] | select(.merged_at != null and ((.head.ref // "") | startswith($p))) ]' \
      <<<"$json" 2>/dev/null) || return 2
    all="${all:+$all$'\n'}$picked"
    more=0
    runner_pr_page_needs_more "$json" "$since" && more=1
    [ "$more" = 1 ] && [ "$page" -lt "$max" ] || break
    page=$((page + 1))
  done
  jq -cs 'add // []' <<<"$all" 2>/dev/null || return 2
  [ "$more" = 1 ] && return 3
  return 0
}

# runner_rest_list <gh-runner> <path[?query]> <stop-jq> <max-pages> <out-file> <err-file>
# Page a REST listing into <out-file> as ONE JSON array. Stops on a short page or
# when <stop-jq> (evaluated on the page array) is true. REST, never search
# (CLAUDE.md §5.2); the cost is pages read, bounded by <max-pages> (§5.4).
# <gh-runner> is as in runner_merged_prs (e.g. gha_gh for the App identity);
# <path> may carry its own query, the paging parameters are appended to it.
#
# rc 0 complete · 1 gh failure or a page that is not a JSON array (stderr kept in
# <err-file>) · 2 <max-pages> pages read and the last was full: the list may be
# cut short, so it is never a complete answer.
runner_rest_list() {
  local gh_runner="$1" path="$2" stop="$3" max="$4" out="$5" err="$6" page=1 n sep='?'
  case "$path" in *\?*) sep='&' ;; esac
  # Pages go to files, never through argv: a REST page of 100 PR objects is
  # megabytes, past ARG_MAX for `--argjson`.
  rm -f "$out".page.*
  while [ "$page" -le "$max" ]; do
    "$gh_runner" api "${path}${sep}per_page=${RUNNER_PR_PER_PAGE}&page=${page}" >"$out.page.$page" 2>"$err" \
      || { rm -f "$out".page.*; return 1; }
    n="$(jq 'if type == "array" then length else error end' "$out.page.$page" 2>/dev/null)" \
      || { rm -f "$out".page.*; return 1; }
    if [ "$n" -lt "$RUNNER_PR_PER_PAGE" ] || [ "$(jq -r "$stop" "$out.page.$page" 2>/dev/null)" = "true" ]; then
      break
    fi
    page=$((page + 1))
  done
  local last="$page" i=1 rc=0
  [ "$page" -le "$max" ] || { last="$max"; rc=2; }
  local -a files=()
  while [ "$i" -le "$last" ]; do files+=("$out.page.$i"); i=$((i + 1)); done
  jq -s 'add // []' "${files[@]}" > "$out" 2>/dev/null || rc=1
  rm -f "$out".page.*
  return "$rc"
}
