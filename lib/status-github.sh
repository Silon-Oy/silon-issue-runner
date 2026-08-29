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
# to source. It sources nothing itself — status.sh sources pr-watch-lib.sh,
# github-app-auth.sh (for pr_decide / pr_ci_state / gha_with_token) and issue.sh
# (for the shared epic resolver list_epic_children, issue #91) before this.

# _STATUS_GH_PR_FIELDS — the --json field set for `gh pr list`. The first seven
# are byte-identical to pr-watch.sh's `gh pr view --json` call, so a PR object
# from this list is a valid input to pr_decide() and pr_ci_state() with no
# reshaping. `number` keys the object back to a run's pr_url; `isDraft` and
# `reviewDecision` fill schema fields the watcher does not read.
_STATUS_GH_PR_FIELDS='number,state,mergeable,mergeStateStatus,labels,statusCheckRollup,headRefName,baseRefName,isDraft,reviewDecision'

# _STATUS_GH_ISSUE_FIELDS — the --json field set for `gh issue list` (issue #78,
# #106). number+title is the title the status page shows as a row's main text;
# labels (issue #106) carry the three state labels below so the Ohjaamo can show a
# run's reservation/cleanup/attention state as a chip. We pull nothing else, so
# the payload stays small and the provenance stays obvious (gh data lives in the
# `github` sub-object, never at the run's top level).
_STATUS_GH_ISSUE_FIELDS='number,title,labels'

# _STATUS_GH_STATE_LABELS — the ONLY issue labels the Ohjaamo surfaces (issue
# #106): the reservation (auto-clean), failed-cleanup (auto-clean-skipped) and
# attention (needs-human) signals a run's issue carries. These three pass into the
# github payload as github.issue_labels; the issue's FULL label set is NEVER
# carried (scope-out: not a general label view, and a tight whitelist keeps the
# leak surface the same as the title in #78). A jq array and the SINGLE source of
# truth for which labels surface: both places that extract labels (the map builder
# below and the detail read) filter against it with the same `index($n)` idiom.
_STATUS_GH_STATE_LABELS='["auto-clean","auto-clean-skipped","needs-human"]'

# status_github_build_issue_labels_map <issues-json> — map every OPEN issue to the
# whitelisted subset of its labels (issue #106), keyed by issue number as a string:
# { "42": ["auto-clean"], "43": [] }. status.sh merges this into the per-owner
# issue-meta map so each run's github object carries issue_labels. Only the three
# named labels pass; the issue's full label set never reaches the payload.
# Empty/invalid array => {}.
status_github_build_issue_labels_map() {
  local issues="$1"
  jq -c --argjson wl "$_STATUS_GH_STATE_LABELS" '
    if type == "array"
    then (reduce .[] as $i ({};
            .[($i.number|tostring)] =
              ([$i.labels[]?.name] | map(select(. as $n | $wl | index($n))))))
    else {} end' <<<"$issues" 2>/dev/null || printf '{}'
}

# _STATUS_GH_EPIC_FIELDS — the --json field set for `gh issue list --label epic`
# (issue #79). number + title feed the epic lane header; body is only used for the
# task-list fallback when the native sub-issues API returns nothing.
_STATUS_GH_EPIC_FIELDS='number,title,body'

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

# status_github_issue_detail <owner/repo> <issue-number> — the explicit per-issue
# read for an issue ABSENT from the open-issue map (issue #96 read #103, broadened):
# a run whose issue the cheap per-owner open list does not cover, so it is either
# closed OR the best-effort open fetch missed it. That absence is only a HINT —
# the open-issue fetch is best-effort (issue #78) — so we confirm the state with
# one `gh issue view`, and in the SAME call pull stateReason + title (issue #103)
# + labels (issue #106): the closed issue's title/labels are otherwise unavailable
# (the open list is --state open), stateReason distinguishes "not planned" from
# "completed", and labels carry the state chips (auto-clean lingers on CLOSED
# issues most of all — the very rows this read reaches). Prints a compact object
# {state, state_reason, title, labels} on stdout, or EMPTY on any failure (a 404 on
# a moved/deleted issue, a network error) — empty means "not confirmed", and the
# caller leaves the local class in place (fail-soft). state/state_reason are
# upper-cased so the payload is normalised regardless of gh's casing; labels are
# whitelisted to the three state labels; an unknown state (not OPEN/CLOSED) yields
# empty (unconfirmed). Modelled on status_github_closed_state — one `gh issue view`
# per absent issue, cached in the same TTL entry so the read runs at most once per
# issue per window.
status_github_issue_detail() {
  local owner_repo="$1" num="$2" json
  json="$(gha_with_token gh issue view "$num" --repo "$owner_repo" \
    --json state,stateReason,title,labels 2>/dev/null)" || { printf ''; return 0; }
  [ -n "$json" ] || { printf ''; return 0; }
  printf '%s' "$json" | jq -c --argjson wl "$_STATUS_GH_STATE_LABELS" '
    ((.state // "") | ascii_upcase) as $st
    | if ($st == "OPEN" or $st == "CLOSED")
      then {state: $st,
            state_reason: (if (.stateReason // "") == "" then null
                           else (.stateReason | ascii_upcase) end),
            title: (.title // null),
            labels: ([.labels[]?.name] | map(select(. as $n | $wl | index($n))))}
      else empty end' 2>/dev/null || printf ''
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
      issue_title: null,
      issue_state: null,
      issue_state_reason: null,
      issue_labels: []
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
      issue_title: null,
      issue_state: null,
      issue_state_reason: null,
      issue_labels: []
    }'
}

# ---------------------------------------------------------------------------
# Epic membership collection (issue #79).
#
# Making an epic's run VISIBLE means knowing which issues belong to it. The
# canonical epic form is an `epic`-labelled issue + GitHub's native sub-issues
# (model: customer-c-erp #2); a body task-list (`- [ ] … #N`) is the fallback for
# legacy epics (model: customer-c-erp #101). The result is a NEW top-level list
# `epics[]` — runs[] is NOT touched (scope-out). The status page renders an epic
# lane per epic inside its repo group; blocker/queue ordering is derived on the
# render side from the sub-issue LIST ORDER (dependency order), so this side keeps
# the spec's exact sub_issue shape: { number, state }.
# ---------------------------------------------------------------------------

# status_github_fetch_epics <owner/repo> — the open `epic`-labelled issues for a
# repo, fetched ONCE per repo into the same TTL cache as PRs + issue titles. We
# pull number+title+body (body only for the task-list fallback). Best-effort: the
# caller treats a failure as "no epics for this repo" WITHOUT marking it failed —
# the PR fetch is the primary enrichment and owns repos_failed.
# REST, not `gh issue list --label` (issue #133). A `--label` filter is what
# routes gh's issue list through GitHub's GraphQL search connection; `--state`
# alone does not. Measured 2026-08-29 on one repo, interleaved with an
# unfiltered control:
#
#   gh issue list --limit 1                     OK
#   gh pr list --state open                     OK
#   gh issue list --state open                  OK
#   gh issue list --label epic --state open     REJECTED
#   gh issue view <n> --json state              OK
#
# So of this module's four calls only the epic fetch sat on the blocked
# connection, and its failure is quiet by design (best-effort => epics simply
# vanish from the Ohjaamo while everything else keeps working). The REST shape
# returns the same three fields; `.body` is null-safe for the task-list fallback.
status_github_fetch_epics() {
  local owner_repo="$1"
  gha_with_token gh api \
    "repos/${owner_repo}/issues?labels=epic&state=open&per_page=100" \
    --jq '[ .[] | select(.pull_request == null)
            | {number, title, body: (.body // "")} ]' 2>/dev/null
}

# status_github_build_epics <owner/repo> <epics-json> <open-issue-map>
# For each epic {number,title,body}, resolve its sub-issues through the SHARED
# resolver lib/issue.sh:list_epic_children (issue #91: the view no longer owns a
# second resolution — no direct /sub_issues call, no task-list parsing here) and
# return the resolved epic array:
#   [{epic_number, epic_title, epic_url, sub_issues:[{number,state,repo}], source}]
# where sub_issues[].repo is the child's home owner/repo (issue #92) so a
# cross-repo child is distinguishable; status.sh maps it to a local repo_slug at
# emit time (repo_slug stays a LOCAL concept, out of the cached GitHub payload).
# `source` is "sub_issues", "task_list", or "unreadable". The last is the view's
# FAIL-CLOSED marker (issue #91 AC4): when the native sub-issues read fails,
# list_epic_children returns rc 2 and we surface an unreadable epic with an empty
# sub_issues set rather than silently falling back to the task list and drawing
# false progress. repo_slug is NOT added here — it is a LOCAL (watchlist) concept,
# injected by status.sh at assembly so the cached github payload stays purely
# GitHub-derived. Sub-issue state is used verbatim ("open"/"closed"); a nested
# epic is treated as an ordinary sub-issue (no recursion — spec edge).
#
# The view passes the resolver everything it already has so no extra gh call is
# spent per epic (issue #91 perf edge): --body (the batch-fetched epic body, so
# the fallback never re-fetches it) and --open-map (the open-issue map, the
# authoritative fallback state source). --gh-runner gha_with_token keeps the App
# identity (edge case: the view's auth path must not break). The repo-root arg is
# "." — every gh call targets an explicit --repo/owner path, so cwd is irrelevant.
status_github_build_epics() {
  local owner_repo="$1" epics="$2" openmap="$3"
  local n i epic num title body sub source out='[]' obj lines rc sf
  n="$(jq 'if type == "array" then length else 0 end' <<<"$epics" 2>/dev/null || echo 0)"
  i=0
  while [ "$i" -lt "$n" ]; do
    epic="$(jq -c ".[$i]" <<<"$epics")"
    i=$((i + 1))
    num="$(jq -r '.number // empty' <<<"$epic")"
    [ -n "$num" ] || continue
    title="$(jq -r '.title // ""' <<<"$epic")"
    body="$(jq -r '.body // ""' <<<"$epic")"
    sf="$(mktemp "${TMPDIR:-/tmp}/status-epic-src.XXXXXX" 2>/dev/null)" || sf=""
    lines="$(list_epic_children "." "$num" "$owner_repo" \
      --gh-runner gha_with_token --body "$body" --open-map "$openmap" \
      --source-file "$sf" 2>/dev/null)"
    rc=$?
    source=""
    [ -n "$sf" ] && { source="$(cat "$sf" 2>/dev/null || true)"; rm -f "$sf" 2>/dev/null; }
    if [ "$rc" -ne 0 ]; then
      # Fail-closed: an unreadable native graph does NOT degrade to the task list.
      sub='[]'; source="unreadable"
    else
      # TSV (<number>\t<state>\t<labels>\t<owner/repo>\t<title>) → [{number,state,repo}]
      # only, so no label/title leaks into the payload (the schema carries
      # number+state+repo; repo is the child's home owner/repo, issue #92 — a
      # cross-repo child is distinguishable in the view). The jq program is ONE
      # line on purpose: a multi-line single-quoted program inside "$(…)" is
      # mis-parsed by bash 3.2 (macOS).
      sub="$(printf '%s' "$lines" | jq -R -s -c '[ split("\n")[] | select(length > 0) | split("\t") | select(length >= 5 and (.[0] | test("^[0-9]+$"))) | {number: (.[0] | tonumber), state: .[1], repo: .[3]} ]' 2>/dev/null || printf '[]')"
      [ -n "$sub" ] || sub='[]'
    fi
    obj="$(jq -nc --argjson num "$num" --arg title "$title" \
      --arg url "https://github.com/$owner_repo/issues/$num" \
      --argjson sub "$sub" --arg src "$source" '
      {epic_number: $num, epic_title: $title, epic_url: $url,
       sub_issues: $sub, source: $src}')"
    out="$(jq -c --argjson o "$obj" '. + [$o]' <<<"$out")"
  done
  printf '%s' "$out"
}

# status_github_issue_only_object <fetched_at> <cache_age>
# The `github` sub-object for a run that has an issue but NO PR yet (issue #78:
# a running/blocked/stalled run). It carries the same key set as the PR objects
# with every PR field null and pr_state null (so the view shows a title but no CI
# chips — chips are for OPEN-PR rows only), plus issue_title which status.sh
# fills from the issue map. This is what lets titles reach attention/running rows,
# not just PR rows. issue_state (issue #96) / issue_state_reason (issue #103) are
# null by default and set by status.sh from the per-owner issue map: "OPEN" when the
# issue is in the open list, or "CLOSED" + a stateReason when an explicit read
# confirmed the closure (a moved/deleted/unread issue stays null — fail-soft).
# pr_state null + issue_state "CLOSED" is what the reclassifier turns into
# cleanup/issue_closed; the reason (COMPLETED/NOT_PLANNED/DUPLICATE) is view-only.
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
      issue_title: null,
      issue_state: null,
      issue_state_reason: null,
      issue_labels: []
    }'
}
