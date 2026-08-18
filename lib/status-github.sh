#!/usr/bin/env bash
# lib/status-github.sh — opt-in GitHub enrichment for status.sh (issue #60).
#
# status.sh reads the whole local picture from disk (issue #59), but run.json
# freezes at `completed` the moment the PR opens: the PR's later life (draft,
# mergeability, CI rollup, labels, review decision) lives only on GitHub, and the
# PR-watcher writes events to the run-dir ONLY while it acts — an open PR without
# the auto-merge label never gets fresh data. This module fills each run's
# `github` sub-object with the live PR state, behind the `--github` flag, with a
# TTL cache so the whole picture costs `gh pr list` ONCE per owner/repo, not once
# per run.
#
# Design invariants (issue #60):
#   - `ci` is pr_ci_state(), `pr_decide_verdict` is pr_decide() — this module owns
#     NO CI-rollup or merge-decision logic of its own, so status.sh and the
#     watcher never disagree on whether a PR is green. We ask `gh pr list` for the
#     SAME --json field set the watcher's `gh pr view` uses (plus number/isDraft/
#     reviewDecision, which the schema needs and pr_decide/pr_ci_state ignore), so
#     the payloads are interchangeable for those two functions.
#   - Auth flows through gha_with_token (lib/github-app-auth.sh), exactly as the
#     watcher — the App identity is honoured when configured.
#   - Enrichment NEVER crashes the output and NEVER changes the local
#     classification: a repo we cannot reach lands in enrichment.repos_failed and
#     its runs stay `github: null` with low confidence; exit code is unaffected.
#
# Sourced by status.sh. Function-only + a few constants; no top-level work, safe
# to source. It sources nothing itself — status.sh sources pr-watch-lib.sh and
# github-app-auth.sh (for pr_decide / pr_ci_state / gha_with_token) before this.

# _STATUS_GH_PR_FIELDS — the --json field set for `gh pr list`. The first seven
# are byte-identical to pr-watch.sh's `gh pr view --json` call, so a PR object
# from this list is a valid input to pr_decide() and pr_ci_state() with no
# reshaping. `number` keys the object back to a run's pr_url; `isDraft` and
# `reviewDecision` fill schema fields the watcher does not read.
_STATUS_GH_PR_FIELDS='number,state,mergeable,mergeStateStatus,labels,statusCheckRollup,headRefName,baseRefName,isDraft,reviewDecision'

# _STATUS_GH_ISSUE_FIELDS — the --json field set for `gh issue list` (issue #78).
# We fetch ONLY number+title: the title is the one gh-only datum the status page
# shows as a row's main text, and pulling nothing else keeps the payload small
# and the provenance obvious (gh data lives in the `github` sub-object, never at
# the run's top level).
_STATUS_GH_ISSUE_FIELDS='number,title'

# status_github_cache_file — resolve the cache path (env override, else the
# XDG/macOS caches dir). Pure: reads env, prints a path, creates nothing.
status_github_cache_file() {
  if [ -n "${RUN_ISSUES_STATUS_CACHE_FILE:-}" ]; then
    printf '%s' "$RUN_ISSUES_STATUS_CACHE_FILE"
  else
    printf '%s/run-issues/status-github.json' "${XDG_CACHE_HOME:-$HOME/Library/Caches}"
  fi
}

# status_github_load_cache <file> — print the cache object, or `{}` when the file
# is missing OR corrupt (issue #60 edge case: a corrupt cache is treated exactly
# like a missing one — skipped, then overwritten with a fresh write).
status_github_load_cache() {
  local f="$1"
  [ -f "$f" ] || { printf '{}'; return 0; }
  jq -c '.' "$f" 2>/dev/null || printf '{}'
}

# status_github_write_cache <file> <cache-json> — atomic write (mktemp + mv -f,
# the same idiom as lib/state.sh). Creates the parent dir. A write failure is
# non-fatal: enrichment already happened in memory, the cache is only a
# next-run optimisation, so we swallow the error and return 0.
status_github_write_cache() {
  local f="$1" json="$2" dir tmp
  dir="$(dirname "$f")"
  mkdir -p "$dir" 2>/dev/null || return 0
  tmp="$(mktemp "$dir/.status-github.XXXXXX" 2>/dev/null)" || return 0
  if printf '%s' "$json" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
  return 0
}

# status_github_fetch_open_prs <owner/repo> — the ONE network call per repo:
# every open PR with the shared field set. Auth via gha_with_token so the App
# identity is used when configured. Prints the JSON array on stdout; returns
# gh's exit code so the caller can route a failure to repos_failed.
status_github_fetch_open_prs() {
  local owner_repo="$1"
  gha_with_token gh pr list --repo "$owner_repo" --state open \
    --json "$_STATUS_GH_PR_FIELDS" --limit 100 2>/dev/null
}

# status_github_fetch_open_issues <owner/repo> — the ONE issue-title network call
# per repo (issue #78): every OPEN issue with number+title. Auth via
# gha_with_token, exactly like the PR fetch. Prints the JSON array on stdout;
# returns gh's exit code. Best-effort: the caller treats a failure as "no titles
# for this repo" WITHOUT marking the repo failed — the PR fetch is the primary
# enrichment and owns repos_failed; a missing title only drops a row's main text.
# `--state open` matches the spec example: a closed issue's title may be absent
# (documented edge case), and open issues are the cheap, common case.
status_github_fetch_open_issues() {
  local owner_repo="$1"
  gha_with_token gh issue list --repo "$owner_repo" --state open \
    --json "$_STATUS_GH_ISSUE_FIELDS" --limit 200 2>/dev/null
}

# status_github_build_issue_map <issues-json> — map every issue to its title,
# keyed by issue number as a string: { "42": "Fix the thing", … }. status.sh
# joins this against each run's issue_number. Empty/invalid array => `{}`.
status_github_build_issue_map() {
  local issues="$1"
  jq -c 'if type == "array"
         then (reduce .[] as $i ({}; .[($i.number|tostring)] = ($i.title // null)))
         else {} end' <<<"$issues" 2>/dev/null || printf '{}'
}

# status_github_closed_state <owner/repo> <pr-number> — used ONLY under
# --github-full to split a NOT_OPEN PR into MERGED vs CLOSED (one `gh pr view`
# per closed PR). Prints "MERGED", "CLOSED", or empty on any failure. Both values
# lead to the same action (cleanup), which is why this lives behind its own flag.
status_github_closed_state() {
  local owner_repo="$1" num="$2" merged_at
  merged_at="$(gha_with_token gh pr view "$num" --repo "$owner_repo" \
    --json mergedAt --jq '.mergedAt // ""' 2>/dev/null)" || { printf ''; return 0; }
  if [ -n "$merged_at" ] && [ "$merged_at" != "null" ]; then
    printf 'MERGED'
  else
    printf 'CLOSED'
  fi
}

# status_github_pr_object <pr-json> <fetched_at> <cache_age> <label> <res> <repair>
# Build ONE `github` sub-object for an OPEN PR. `ci` and `pr_decide_verdict` come
# from pr_ci_state / pr_decide — this function computes neither itself. `res` and
# `repair` are pr_decide's conflict-resolution / CI-repair toggles: status.sh
# defaults them to the pollers' production values so the verdict reflects what the
# watcher that actually tends these repos would decide right now.
status_github_pr_object() {
  local pr="$1" fetched_at="$2" age="$3" label="${4:-auto-merge}" res="${5:-1}" repair="${6:-1}"
  local ci verdict
  ci="$(pr_ci_state "$pr")"
  verdict="$(pr_decide "$pr" "$res" "$label" "$repair")"
  jq -c --arg fa "$fetched_at" --argjson age "$age" --arg ci "$ci" --arg v "$verdict" '
    {
      fetched_at: $fa,
      cache_age_seconds: $age,
      pr_state: "OPEN",
      is_draft: (.isDraft // false),
      mergeable: (.mergeable // "UNKNOWN"),
      merge_state_status: (.mergeStateStatus // "UNKNOWN"),
      ci: $ci,
      labels: [.labels[]?.name],
      review_decision: (if (.reviewDecision // "") == "" then null else .reviewDecision end),
      pr_decide_verdict: $v,
      issue_title: null
    }' <<<"$pr"
}

# status_github_build_pr_map <prs-json> <fetched_at> <cache_age> <label> <res> <repair>
# Map every open PR to its `github` sub-object, keyed by PR number as a string:
# { "42": {…}, "43": {…} }. status.sh joins this against each run's pr_number.
# Empty array => `{}`. This is the only place per-PR ci/verdict is computed, so it
# runs once per open PR regardless of how many runs reference it.
status_github_build_pr_map() {
  local prs="$1" fetched_at="$2" age="$3" label="${4:-auto-merge}" res="${5:-1}" repair="${6:-1}"
  local n i pr num obj out='{}'
  n="$(jq 'length' <<<"$prs" 2>/dev/null || echo 0)"
  i=0
  while [ "$i" -lt "$n" ]; do
    pr="$(jq -c ".[$i]" <<<"$prs")"
    num="$(jq -r '.number // empty' <<<"$pr")"
    if [ -n "$num" ]; then
      obj="$(status_github_pr_object "$pr" "$fetched_at" "$age" "$label" "$res" "$repair")"
      out="$(jq -c --arg k "$num" --argjson o "$obj" '. + {($k): $o}' <<<"$out")"
    fi
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# status_github_not_open_object <fetched_at> <cache_age> [<closed_as>]
# The `github` sub-object for a run whose PR is not in the open set. Honest about
# what was measured: open-vs-closed is known, merged-vs-closed is null unless
# --github-full supplied <closed_as> (MERGED/CLOSED).
status_github_not_open_object() {
  local fetched_at="$1" age="$2" closed_as="${3:-}"
  jq -nc --arg fa "$fetched_at" --argjson age "$age" \
    --arg ca "$closed_as" '
    {
      fetched_at: $fa,
      cache_age_seconds: $age,
      pr_state: "NOT_OPEN",
      is_draft: null,
      mergeable: null,
      merge_state_status: null,
      ci: null,
      labels: null,
      review_decision: null,
      pr_decide_verdict: null,
      closed_as: (if $ca == "" then null else $ca end),
      issue_title: null
    }'
}

# status_github_issue_only_object <fetched_at> <cache_age>
# The `github` sub-object for a run that has an issue but NO PR yet (issue #78:
# a running/blocked/stalled run). It carries the same key set as the PR objects
# with every PR field null and pr_state null (so the view shows a title but no CI
# chips — chips are for OPEN-PR rows only), plus issue_title which status.sh
# fills from the issue map. This is what lets titles reach attention/running rows,
# not just PR rows.
status_github_issue_only_object() {
  local fetched_at="$1" age="$2"
  jq -nc --arg fa "$fetched_at" --argjson age "$age" '
    {
      fetched_at: $fa,
      cache_age_seconds: $age,
      pr_state: null,
      is_draft: null,
      mergeable: null,
      merge_state_status: null,
      ci: null,
      labels: null,
      review_decision: null,
      pr_decide_verdict: null,
      closed_as: null,
      issue_title: null
    }'
}
