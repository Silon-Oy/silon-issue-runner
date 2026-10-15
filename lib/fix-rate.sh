#!/usr/bin/env bash
# lib/fix-rate.sh — after-fix meter for merged auto-run PRs (issue #314).
#
# The merge rate says a PR got in; it does not say the change held. This module
# answers the second question per repo over a window (default 14 days): of the
# auto-run PRs merged in the window, how many were later REVERTED and how many
# needed an AFTER-FIX. It only reports — nothing here acts on a finding.
#
# Cost (CLAUDE.md §5.4, "ask about work, not history"): per repo exactly three
# REST listings, each paged only as far as the window reaches —
#   pulls?state=closed&sort=updated   stop once a page ends before the window
#   commits?since=<window start>      default branch; GitHub bounds it
#   issues?state=all&since=…&sort=created  issues AND PRs (§5.2); stop once a
#                                          page ends before the window
# so the call count grows with repos × pages-in-window and never with the number
# of historical run-dirs (none are read at all). A page cap bounds a runaway
# listing; hitting it marks the repo `truncated` so a cut list never reads as
# "0 after-fixes". No `gh issue list --label/--search` (§5.2).
#
# Classification heuristic (documented in the issue #314 PR; one class per PR,
# reverted beats fixed). For a PR P merged at time M:
#   reverted — a default-branch commit after M whose message carries
#              "This reverts commit <P.merge_commit_sha>", or starts with
#              `Revert "<P.title>"`, or starts with "Revert" and references P;
#              or a PR created after M whose title starts with "Revert" and
#              either is `Revert "<P.title>"` or references P.
#   fixed    — any other issue or PR created after M whose title or body
#              references P.
# "References P" = `#N` not glued to a word or path (so `other/repo#N` does not
# match), `owner/repo#N`, or a github.com …/owner/repo/(pull|issues)/N URL. P
# itself never counts, and P's own issue is excluded by construction: it was
# created before the merge.
#
# Fail-soft by contract: a gh failure marks that repo `error: "failed"` (or
# "rate_limited", which also stops the sweep — the remaining repos would be
# refused too) and never changes the caller's exit code. The backoff state file
# is NOT written: like status.sh, the digest is a read-only view (§5.1).
#
# Sourced by status-digest.sh, which sources rate-limit.sh, github-app-auth.sh
# and git-remote.sh first. Function-only; no top-level work.

# fix_rate_repos_from_watchlist <watchlist> — print the distinct owner/repo of
# every watchlist checkout on disk, one per line, across each entry's `remotes`
# (default origin). An unresolvable remote is skipped, not an error.
fix_rate_repos_from_watchlist() {
  local wl="${1-}" rp rem owner
  [ -n "$wl" ] && [ -f "$wl" ] || return 0
  jq -r '.repos[]? | (.path // empty) as $p
         | ((.remotes // ["origin"]) | if length == 0 then ["origin"] else . end)[]
         | [$p, .] | @tsv' "$wl" 2>/dev/null \
    | while IFS=$'\t' read -r rp rem; do
        [ -n "$rp" ] && [ -d "$rp" ] || continue
        owner="$(resolve_remote_to_owner_repo "$rp" "$rem" 2>/dev/null || true)"
        [ -n "$owner" ] && printf '%s\n' "$owner"
      done | sort -u
}

# _fix_rate_list <path?query> <stop-jq> <max-pages> <out-file> <err-file> —
# page a REST listing into <out-file> as ONE JSON array. Stops on a short page or
# when <stop-jq> (evaluated on the page array) is true. Returns 0 complete,
# 1 gh failure / unparseable page (stderr kept in <err-file>), 2 page cap hit.
_fix_rate_list() {
  local path="$1" stop="$2" max="$3" out="$4" err="$5" page=1 n
  # Pages go to files, never through argv: a REST page of 100 PR objects is
  # megabytes, past ARG_MAX for `--argjson`.
  rm -f "$out".page.*
  while [ "$page" -le "$max" ]; do
    gha_with_token gh api "${path}&per_page=100&page=${page}" >"$out.page.$page" 2>"$err" \
      || { rm -f "$out".page.*; return 1; }
    n="$(jq 'if type == "array" then length else error end' "$out.page.$page" 2>/dev/null)" \
      || { rm -f "$out".page.*; return 1; }
    if [ "$n" -lt 100 ] || [ "$(jq -r "$stop" "$out.page.$page" 2>/dev/null)" = "true" ]; then
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

# fix_rate_classify — pure: read {repo, since, pulls, commits, items} on stdin,
# print {repo, merged, fixed, reverted, merged_prs, fixed_prs, reverted_prs}.
# Kept separate from the fetch so the heuristic is testable without gh.
fix_rate_classify() {
  jq -c '
    .repo as $repo | .since as $since
    | ($repo | gsub("(?<c>[.\\-])"; "\\\(.c)")) as $rre
    | def refs($n): (. // "") | test("(^|[^A-Za-z0-9_/&.-])#\($n)(?![0-9])")
                    or test("(?i)\($rre)(#|/pull/|/issues/)\($n)(?![0-9])");
    [ .pulls[]?
      | select(.merged_at != null and .merged_at >= $since
               and ((.head.ref // "") | startswith("auto-run/"))) ] as $merged
    | (.commits // []) as $commits
    | (.items // []) as $items
    | [ $merged[]
        | . as $p
        | ($p.number | tostring) as $n
        | ("Revert \"" + ($p.title // "") + "\"") as $rt
        | ( any($commits[];
              ((.commit.committer.date // .commit.author.date // "") >= $p.merged_at)
              and .sha != $p.merge_commit_sha
              and ((.commit.message // "") as $m
                   | (($p.merge_commit_sha // "") != ""
                      and ($m | contains("This reverts commit " + $p.merge_commit_sha)))
                     or ($m | startswith($rt))
                     or (($m | startswith("Revert")) and ($m | refs($n)))))
            or any($items[];
              .pull_request != null and .number != $p.number
              and (.created_at // "") >= $p.merged_at
              and ((.title // "") | startswith("Revert"))
              and ((.title == $rt) or ((.title // "") + "\n" + (.body // "") | refs($n))))
          ) as $rev
        | ( (if $rev then false else
               any($items[];
                 .number != $p.number
                 and (.created_at // "") > $p.merged_at
                 and ((.title // "") + "\n" + (.body // "") | refs($n)))
             end) ) as $fix
        | {number: $p.number, reverted: $rev, fixed: $fix} ] as $cls
    | { repo: $repo,
        merged: ($cls | length),
        fixed: ([$cls[] | select(.fixed)] | length),
        reverted: ([$cls[] | select(.reverted)] | length),
        merged_prs: [$cls[].number],
        fixed_prs: [$cls[] | select(.fixed) | .number],
        reverted_prs: [$cls[] | select(.reverted) | .number] }'
}

# fix_rate_scan <since-iso> <max-pages> <owner/repo>... — print a JSON array, one
# object per repo: fix_rate_classify's output plus `truncated` (bool) and
# `error` (null | "failed" | "rate_limited"). After a rate-limit rejection the
# remaining repos are reported as "rate_limited" without being asked.
fix_rate_scan() {
  local since="$1" max="$2"; shift 2
  local tmp repo rc trunc err spec limited=0 results='[]' obj
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/fix-rate.XXXXXX")" || { printf '[]'; return 0; }
  for repo in "$@"; do
    if [ "$limited" -eq 1 ]; then
      obj="$(jq -nc --arg r "$repo" '{repo: $r, error: "rate_limited", truncated: false}')"
      results="$(jq -c --argjson o "$obj" '. + [$o]' <<<"$results")"
      continue
    fi
    trunc=false err=""
    for spec in \
      "pulls|repos/$repo/pulls?state=closed&sort=updated&direction=desc|.[-1].updated_at < \"$since\"" \
      "commits|repos/$repo/commits?since=$since|false" \
      "items|repos/$repo/issues?state=all&since=$since&sort=created&direction=desc|.[-1].created_at < \"$since\""; do
      _fix_rate_list "$(printf '%s' "$spec" | cut -d'|' -f2)" "$(printf '%s' "$spec" | cut -d'|' -f3)" \
        "$max" "$tmp/$(printf '%s' "$spec" | cut -d'|' -f1).json" "$tmp/err"
      rc=$?
      if [ "$rc" -eq 1 ]; then
        if rate_limit_file_matches "$tmp/err"; then err="rate_limited"; limited=1
        else err="failed"; fi
        break
      fi
      [ "$rc" -eq 2 ] && trunc=true
    done
    if [ -n "$err" ]; then
      obj="$(jq -nc --arg r "$repo" --arg e "$err" '{repo: $r, error: $e, truncated: false}')"
    else
      obj="$(jq -n --arg r "$repo" --arg s "$since" \
               --slurpfile p "$tmp/pulls.json" --slurpfile c "$tmp/commits.json" \
               --slurpfile i "$tmp/items.json" \
               '{repo: $r, since: $s, pulls: $p[0], commits: $c[0], items: $i[0]}' \
             | fix_rate_classify)" || obj=""
      if [ -n "$obj" ]; then
        obj="$(jq -c --argjson t "$trunc" '. + {truncated: $t, error: null}' <<<"$obj")"
      else
        obj="$(jq -nc --arg r "$repo" '{repo: $r, error: "failed", truncated: false}')"
      fi
    fi
    results="$(jq -c --argjson o "$obj" '. + [$o]' <<<"$results")"
    rm -f "$tmp"/*.json "$tmp/err"
  done
  rm -rf "$tmp"
  printf '%s' "$results"
}
