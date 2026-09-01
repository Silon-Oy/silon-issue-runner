#!/usr/bin/env bash
# lib/issue.sh — GitHub issue interactions wrapped around the `gh` CLI.
#
# All commands operate against the repo passed as first argument; we cd
# into it for the duration of each call. Output is plain JSON / number / text
# on stdout; errors escape via gh's non-zero exit.
#
# Multi-remote: every wrapper that talks to GitHub accepts an OPTIONAL trailing
# <owner/repo> argument. When set, the gh call is targeted explicitly via
# `--repo owner/repo` so it goes to that org regardless of which remote `gh`
# would otherwise infer from cwd. This is the mechanism that lets one clone
# poll issues from multiple orgs (issue #53). When the argument is empty, gh
# falls back to its cwd-based resolution — fully backward compatible with
# single-remote callers and existing tests.
#
# GitHub App identity: when the caller has loaded lib/github-app-auth.sh and
# gha_enabled is true, the helpers below route their GitHub operations through
# gha_with_token so they run as <app>[bot] instead of the personal gh-CLI
# identity. This covers BOTH the write paths (comment / label — attributed to
# the App) AND the heavy LIST reads (pick_oldest_candidate, issue_assignees,
# epic_list_open — issue #127). Identity does not change what a read RETURNS, but
# it decides WHOSE rate limit pays for it. The whole automation used to share
# the maintainer's personal quota, so a busy pickup loop could exhaust it and
# stall human work (and vice versa); routing the pickup / scan volume through
# the App gives the runner its own 15k/h budget. That is why the reads follow
# the writes onto the App path even though attribution is irrelevant for a
# read (issue #127).
#
# claim_issue / verify_claim / unclaim_issue DELIBERATELY stay on the personal
# identity: GitHub Apps cannot be issue assignees, so the race-arbitration logic
# ("am I the sole assignee?") must continue to use a real user account —
# verify_claim's `gh api user` in particular MUST resolve to the personal login,
# not the App. count_open_blockers / list_blocked_by / is_epic likewise stay on
# the personal identity: they are low-volume PER-ISSUE reads (one per candidate /
# run), not the per_page=100 LIST reads whose volume issue #127 moved.
#
# Per-org App scope: the App identity is per-org (token is minted for one
# installation). When the active remote is NOT origin, the App-mode wrapper
# would route the call with a token minted for the WRONG org. Per-org App
# support is explicitly scope-out for issue #53, so we fall back to the
# personal gh-CLI identity for non-origin remotes. _issue_gh accepts an
# optional <remote> hint for this purpose.

set -euo pipefail

# AUTO_CLAIMED_LABEL — the automation-owned reservation label (issue #99). It is
# a FIXED name, not configurable — the same call as the epic labels
# (docs/epic-orchestration.md §6): only automation ever writes it. It replaces the
# reservation role `no:assignee` used to play in pickup. claim_issue adds it after
# a verified claim, unclaim_issue removes it, and cleanup-run.sh removes it beside
# its raw un-assign — so the label tracks the assignment structurally, never
# per-call. A human never adds it; assignment is left as pure bookkeeping.
AUTO_CLAIMED_LABEL="auto-claimed"

# _issue_gh [--remote <name>] -- <gh-args>...
# Runs `gh` either through gha_with_token (App identity) or as a pass-through.
# When the optional <remote> argument is "origin" or empty (the legacy
# single-remote case) and App mode is on, the call goes through gha_with_token
# so the comment / view / label is authored as <app>[bot]. When <remote> names
# a non-origin remote (multi-org mode), App mode is bypassed — the App
# installation token is minted for one org and would be the wrong credential
# for another. Per-org App support is intentionally scope-out for issue #53;
# non-origin remotes use the personal gh-CLI identity instead.
_issue_gh() {
  local remote=""
  if [ "${1:-}" = "--remote" ]; then
    remote="${2:-}"
    shift 2
  fi
  # Drop the optional `--` argument separator if present.
  if [ "${1:-}" = "--" ]; then
    shift
  fi

  if declare -F gha_with_token >/dev/null 2>&1; then
    case "$remote" in
      ""|origin) gha_with_token gh "$@" ;;
      *)         gh "$@" ;;  # App identity is per-org; bypass for non-origin.
    esac
  else
    gh "$@"
  fi
}

# _repo_args <owner/repo> — prints `--repo owner/repo` when the argument is
# non-empty, or nothing otherwise. Centralising this keeps every wrapper a
# one-liner that opts in to explicit repo targeting without sprinkling case
# statements across the file. The result is intended for an unquoted expansion
# in the gh call so an empty result disappears cleanly.
_repo_args() {
  local owner_repo="${1:-}"
  [ -n "$owner_repo" ] && printf -- '--repo %s' "$owner_repo"
}

# _rest_issues_path <owner/repo> <query-string>
# Builds the `gh api` path for the repo's issues endpoint. An empty owner/repo
# uses gh's {owner}/{repo} placeholders, which it substitutes from the cwd's
# remote — the same idiom count_open_blockers already relies on, so the legacy
# single-remote callers keep working without resolving anything themselves.
_rest_issues_path() {
  local owner_repo="${1:-}" qs="${2:-}"
  if [ -n "$owner_repo" ]; then
    printf 'repos/%s/issues?%s' "$owner_repo" "$qs"
  else
    printf 'repos/{owner}/{repo}/issues?%s' "$qs"
  fi
}

# _rest_issue_path <owner/repo> <issue-number>
# The single-issue REST path, same {owner}/{repo} placeholder rule as
# _rest_issues_path.
_rest_issue_path() {
  local owner_repo="${1:-}" n="${2:-}"
  if [ -n "$owner_repo" ]; then
    printf 'repos/%s/issues/%s' "$owner_repo" "$n"
  else
    printf 'repos/{owner}/{repo}/issues/%s' "$n"
  fi
}

# _rest_pulls_path <owner/repo> <query-string>
# The pull-request LIST REST path, same {owner}/{repo} placeholder rule as
# _rest_issues_path. Separate from the issues path because `repos/…/issues`
# returns PRs too but without `head.ref`/`state` in the shape a PR gate needs,
# and filtering them out of an issue list would cost the same call anyway.
_rest_pulls_path() {
  local owner_repo="${1:-}" qs="${2:-}"
  if [ -n "$owner_repo" ]; then
    printf 'repos/%s/pulls?%s' "$owner_repo" "$qs"
  else
    printf 'repos/{owner}/{repo}/pulls?%s' "$qs"
  fi
}

# _rest_pull_path <owner/repo> <pr-number>
# The single-PR REST path, same {owner}/{repo} placeholder rule as
# _rest_pulls_path. Used as the targeted rescue when a paginated PR list was
# truncated and absence from it therefore proves nothing.
_rest_pull_path() {
  local owner_repo="${1:-}" n="${2:-}"
  if [ -n "$owner_repo" ]; then
    printf 'repos/%s/pulls/%s' "$owner_repo" "$n"
  else
    printf 'repos/{owner}/{repo}/pulls/%s' "$n"
  fi
}

# _labels_query_csv <labels-csv> [<extra-label>...]
# Comma-joins the configured run labels with any extra required labels for the
# REST `labels=` parameter. REST ANDs them, exactly like the separate
# `label:"x"` terms the old search query used (measured 2026-08-29:
# labels=auto-run,epic returned 0 while labels=auto-run returned 5).
_labels_query_csv() {
  local csv="${1:-}"; shift
  local out="" label
  for label in "$@"; do
    [ -n "$label" ] || continue
    out="${out:+$out,}$label"
  done
  if [ -n "$csv" ]; then
    local IFS=','
    for label in $csv; do
      [ -n "$label" ] || continue
      out="${out:+$out,}$label"
    done
  fi
  printf '%s' "$out"
}

# pick_oldest_candidate <repo-root> <labels-csv> [<owner/repo>] [<remote>]
# Prints the issue number of the oldest runnable candidate, or nothing.
#
# The list read routes through _issue_gh (issue #127): with App mode on and an
# origin (or empty) <remote> it spends the App's rate limit, not the
# maintainer's personal one — the pickup search is the package's single hottest
# read, so its volume is exactly what must move off the shared personal quota.
# Without App wiring, or on a non-origin remote, _issue_gh is a pass-through to
# bare gh (unchanged). The per-candidate count_open_blockers probe stays on the
# personal identity (a low-volume per-issue read, not the per_page=100 list).
#
# WHY THIS IS REST AND NOT `gh issue list` (issue #133). `gh issue list` routes
# any FILTERED query through GitHub's GraphQL `search` connection, which carries
# its own limit and its own block. Measured 2026-08-29 with an interleaved
# control on one repo, four seconds apart:
#
#   gh issue list --limit 1 --json number          OK  (x3, unfiltered)
#   gh issue list --label X --state all            REJECTED
#   gh issue list --search "…"                     REJECTED
#   gh pr list --state open                        OK
#   gh api repos/…/issues?labels=…                 OK
#
# The account had been locked out of the search connection for 27 hours while
# REST and plain listing answered normally, so pickup could not run at all. The
# unfiltered control is what separates "the account is throttled" from "this
# query shape is blocked" — without it both arms fail and prove nothing.
#
# The standing exclusions move from query qualifiers to LOCAL filtering, which
# REST cannot express. That is a straight win for the negative label terms: the
# old `-label:x` qualifiers failed OPEN (an unknown negative qualifier silently
# matches everything, so a typo leaked excluded issues into pickup), whereas a
# jq membership test on the label array cannot silently pass.
#
# `-is:blocked` has no REST equivalent, so its replacement is a real change and
# not a translation. Dropping it outright would spin: S2b rejects a blocked issue
# BEFORE the claim, so the same issue would be re-picked every tick forever. So
# the candidates are walked oldest-first and each is probed with
# count_open_blockers — the SAME authoritative dependency read S2b uses, over
# REST, fail-closed — stopping at the first unblocked one. The usual cost is one
# probe: in a dependency chain the oldest child is the runnable one. The probe
# budget is capped so a repo whose backlog is entirely blocked cannot spend a
# tick walking it; the cap yields "no candidate" and the next tick retries.
# _pick_filter_jq — the local exclusion filter. These were query qualifiers
# (`-label:waiting` …) until issue #133 moved pickup to REST. As a jq membership
# test the set is strictly safer than it was: an unknown NEGATIVE qualifier does
# not error on GitHub, it silently matches everything, so a typo used to leak
# excluded issues into pickup. A typo here yields no match instead.
_pick_filter_jq() {
  printf '%s' '[ .[]
     | select(.pull_request == null)
     | select([.labels[].name] as $l
              | ($l | index("auto-claimed")) == null
              and ($l | index("waiting")) == null
              and ($l | index("wip")) == null
              and ($l | index("epic")) == null
              and ($l | index($ENV.RUN_ISSUES_PICK_CLEAN)) == null)
     | .number ] | .[]'
}

pick_oldest_candidate() {
  local repo="$1"
  local labels_csv="${2:-}"
  local owner_repo="${3:-}"
  local remote="${4:-}"
  # auto-clean issues are a teardown signal handled by the poller's scan_clean,
  # never a development candidate.
  local clean_label="${RUN_ISSUES_CLEAN_LABEL:-auto-clean}"
  local probe_cap="${RUN_ISSUES_PICK_BLOCKED_PROBES:-20}"

  local qs candidates
  qs="state=open&sort=created&direction=asc&per_page=100"
  local want
  want="$(_labels_query_csv "$labels_csv")"
  [ -n "$want" ] && qs="labels=${want}&${qs}"

  # REST /issues returns pull requests too (they are issues in GitHub's data
  # model), so .pull_request must be excluded or a PR number would be handed to
  # the orchestrator as an issue.
  if ! candidates=$(
    cd "$repo" || exit 1
    # `gh api --jq` runs jq WITHOUT exposing jq's own --arg, so the configurable
    # clean label is passed through the environment and read with jq's $ENV.
    export RUN_ISSUES_PICK_CLEAN="$clean_label"
    _issue_gh --remote "$remote" -- api "$(_rest_issues_path "$owner_repo" "$qs")" \
      --jq "$(_pick_filter_jq)" 2>>"${RUN_ISSUES_GH_ERR:-/dev/null}"
  ); then
    return 0   # unreachable / rejected => no candidate, same as an empty result
  fi

  local n probes=0 blockers
  for n in $candidates; do
    [ -n "$n" ] || continue
    if [ "$probes" -ge "$probe_cap" ]; then
      return 0
    fi
    probes=$((probes + 1))
    if blockers=$(count_open_blockers "$repo" "$n" "$owner_repo"); then
      if [ "$blockers" = "0" ]; then
        printf '%s' "$n"
        return 0
      fi
    fi
    # Non-zero blockers, or an unreadable graph (fail-closed): not this one.
  done
  return 0
}

# issue_assignees <repo-root> <N> [<owner/repo>] [<remote>]
# Prints the issue's current assignee logins as a comma-joined string (empty when
# none). The S3 caller snapshots this JUST BEFORE claim_issue so verify_claim can
# compare against the expected post-claim set (before ∪ {@me}); verify_claim reads
# it again after the claim.
#
# Routes through _issue_gh (issue #127): App identity does not change the assignee
# list it reads (assignees are the same data under either credential), but it puts
# this read on the App's rate limit. verify_claim runs this on every claim, so its
# volume belongs to the App, not a personal quota. The `me` login verify_claim
# compares against still comes from bare `gh api user`, so the personal identity
# remains the anchor of the sole-assignee check. Pass-through to bare gh without
# App wiring or on a non-origin remote.
issue_assignees() {
  local repo="$1"
  local n="$2"
  local owner_repo="${3:-}"
  local remote="${4:-}"
  (
    cd "$repo"
    # shellcheck disable=SC2046
    _issue_gh --remote "$remote" -- issue view "$n" $(_repo_args "$owner_repo") --json assignees --jq '[.assignees[].login] | join(",")'
  )
}

# _normalize_login_set <csv> — pure. Sorts a comma-separated login list, drops
# empties and duplicates, and re-joins with commas so two sets are comparable by
# string equality regardless of order or repetition.
_normalize_login_set() {
  printf '%s' "${1:-}" | tr ',' '\n' | sed '/^$/d' | sort -u | paste -sd, -
}

# _reserve_label_add <repo-root> <N> [<owner/repo>]
# Adds the automation-owned auto-claimed reservation label (issue #99). Best-effort:
# a transient GitHub error must not abort a claim — same-host tmux dedup and the S2
# lock still prevent a double run (issue #99 edge case 2), so a fail-closed here
# would let one GitHub hiccup stall every run. Guarded on labels.sh being loaded so
# the pure-function contract of this file survives if a caller has not sourced it.
_reserve_label_add() {
  local repo="$1" n="$2" owner_repo="${3:-}"
  declare -F labels_add >/dev/null 2>&1 || return 0
  (
    cd "$repo"
    labels_ensure "$owner_repo" "$AUTO_CLAIMED_LABEL" || true
    labels_add "$owner_repo" "$n" "$AUTO_CLAIMED_LABEL" || true
  ) || true
  return 0
}

# _reserve_label_remove <repo-root> <N> [<owner/repo>]
# Removes the auto-claimed label. Idempotent (labels_remove treats an absent label
# as success). Best-effort, same posture as _reserve_label_add.
_reserve_label_remove() {
  local repo="$1" n="$2" owner_repo="${3:-}"
  declare -F labels_remove >/dev/null 2>&1 || return 0
  (
    cd "$repo"
    labels_remove "$owner_repo" "$n" "$AUTO_CLAIMED_LABEL" || true
  ) || true
  return 0
}

# claim_issue <repo-root> <N> [<owner/repo>]
# Assigns the issue to @me AND adds the auto-claimed reservation label (issue #99).
# Returns 0 when the assignment succeeded (the label is best-effort and never
# changes the exit code). Binding the label add here — not at the call site — makes
# it track the assignment structurally: every unclaim path removes it too.
#
# Stays on the personal gh-CLI identity even when App mode is on: GitHub Apps
# CANNOT be issue assignees, so race-arbitration must remain a real-user
# operation. (App-mode automation is still attributable: comments / labels /
# PR are App-identified; only the "who is working on this" assignment retains
# the personal identity, which is acceptable since it is an internal signal.)
claim_issue() {
  local repo="$1"
  local n="$2"
  local owner_repo="${3:-}"
  (
    cd "$repo"
    # shellcheck disable=SC2046
    gh issue edit "$n" $(_repo_args "$owner_repo") --add-assignee "@me" >/dev/null
  ) || return 1
  # Reservation label follows the assignment. Best-effort — a transient label
  # error must not undo a good claim.
  _reserve_label_add "$repo" "$n" "$owner_repo"
  return 0
}

# verify_claim <repo-root> <N> [<owner/repo>] [<before-assignees-csv>] [<remote>]
# Returns 0 only if the assignee set after the claim equals the set BEFORE the
# claim plus @me (issue #99). The before-set is snapshotted by the caller just
# before claim_issue (issue_assignees) and passed as the 4th argument; empty (or
# omitted) means "nobody was assigned before", which reduces to the old
# sole-assignee rule.
#
# Why the set comparison replaces "am I the SOLE assignee": claim_issue assigns
# @me, which is the SAME account a human uses to hand-assign an issue, so a human
# who pre-assigned themselves must NOT fail verification (that was the whole point
# of issue #99). A racing runner on ANOTHER account still adds its own login, so
# the post-claim set gains an entry the (before ∪ {@me}) set lacks → mismatch →
# the caller backs off with exit 3, exactly as before. If a human assigns someone
# during the ~5 s verify window the run backs off needlessly — benign, since the
# issue is immediately pickable again (its reservation label was removed on unclaim).
#
# The `me` lookup stays on the personal identity for the same reason as
# claim_issue: @me only resolves to a user account, and `gh api user` under an
# App token would return the App, breaking the comparison. The assignee read is
# delegated to issue_assignees, which routes through the App for its rate limit
# (issue #127) — safe because both credentials see the same assignee logins.
verify_claim() {
  local repo="$1"
  local n="$2"
  local owner_repo="${3:-}"
  local before_csv="${4:-}"
  local remote="${5:-}"
  local me current expected_set current_set
  me=$(gh api user --jq .login)
  current=$(issue_assignees "$repo" "$n" "$owner_repo" "$remote")
  expected_set=$(_normalize_login_set "$before_csv,$me")
  current_set=$(_normalize_login_set "$current")
  [ "$current_set" = "$expected_set" ]
}

# unclaim_issue <repo-root> <N> [<owner/repo>]
# Removes the @me assignee AND the auto-claimed reservation label (issue #99).
# Idempotent (best-effort). The label removal is bound here for the same reason
# the add is bound to claim_issue: it tracks the assignment structurally.
unclaim_issue() {
  local repo="$1"
  local n="$2"
  local owner_repo="${3:-}"
  (
    cd "$repo"
    # shellcheck disable=SC2046
    gh issue edit "$n" $(_repo_args "$owner_repo") --remove-assignee "@me" >/dev/null 2>&1 || true
  )
  _reserve_label_remove "$repo" "$n" "$owner_repo"
}

# count_open_blockers <repo-root> <N> [<owner/repo>]
# Prints the number of OPEN issues blocking issue N and returns 0 when the
# dependency graph was read successfully. Returns non-zero (printing nothing)
# when the graph could NOT be read — the caller MUST treat that as "assume
# blocked" (fail-closed, issue #28).
#
# WHY A SECOND, AUTHORITATIVE READ (issue #28):
# The pickup search excludes blocked issues with `-is:blocked`, which reads
# GitHub's SEARCH index — eventually consistent. A lagging index once leaked 25
# blocked issues into pickup, each launched one tick apart in creation order
# (exactly the pattern an unfiltered search produces). This helper reads the
# dependency GRAPH directly (GET .../issues/{n}/dependencies/blocked_by) — the
# same graph `is:blocked` is derived from, but strongly consistent — so a blocked
# issue is caught even while the index lags. `-is:blocked` stays as the cheap
# pre-filter; this is the second line of defence, not a replacement.
#
# FAIL-CLOSED: a false positive costs one skipped tick; a false negative costs a
# whole out-of-order run. So any read error (network, auth, endpoint absent, or a
# non-numeric body) returns non-zero rather than a count — the opposite of the
# `gh api ... || echo 0` idiom, which would fail OPEN. Stays on the personal
# gh-CLI identity: this is a low-volume PER-ISSUE probe (one per candidate), not
# the per_page=100 LIST read pick_oldest_candidate moved onto the App for its
# rate limit (issue #127) — the reduction of these singleton reads is scoped out.
count_open_blockers() {
  local repo="$1"
  local n="$2"
  local owner_repo="${3:-}"
  # gh substitutes {owner}/{repo} from the cwd's remote; for a non-origin remote
  # (multi-org) we target the resolved owner/repo explicitly instead.
  local path
  if [ -n "$owner_repo" ]; then
    path="repos/$owner_repo/issues/$n/dependencies/blocked_by"
  else
    path="repos/{owner}/{repo}/issues/$n/dependencies/blocked_by"
  fi
  local out
  if ! out=$(
    cd "$repo" || exit 1
    gh api "$path" --jq '[.[] | select(.state == "open")] | length' 2>/dev/null
  ); then
    return 2
  fi
  case "$out" in
    ''|*[!0-9]*) return 2 ;;  # empty or non-numeric body → fail-closed
  esac
  printf '%s' "$out"
}

# list_blocked_by <repo-root> <N> [<owner/repo>]
# Prints one blocker per line as "<number>\t<state>" (state "open"/"closed") for
# issue N's blocked_by dependency graph, and returns 0 on a good read (including
# the empty case — an issue with no blockers prints nothing). Returns 2 (printing
# nothing) when the graph could NOT be read — the caller MUST treat that as
# "assume blocked" (fail-closed, same contract as count_open_blockers).
#
# count_open_blockers answers "how many open blockers?"; this answers "WHICH
# issues block N and in what state?", which /run-epic (issue #82) needs to build
# the child-set dependency graph (cycle check + run order) and to name the
# blocker in its report. Reading the same GET .../dependencies/blocked_by graph
# keeps the two helpers consistent. Stays on the personal gh-CLI identity — a
# low-volume per-issue read like count_open_blockers, outside issue #127's
# list-read routing.
list_blocked_by() {
  local repo="$1"
  local n="$2"
  local owner_repo="${3:-}"
  local path
  if [ -n "$owner_repo" ]; then
    path="repos/$owner_repo/issues/$n/dependencies/blocked_by"
  else
    path="repos/{owner}/{repo}/issues/$n/dependencies/blocked_by"
  fi
  local out
  if ! out=$(
    cd "$repo" || exit 1
    gh api --paginate "$path" --jq '.[] | "\(.number)\t\(.state)"' 2>/dev/null
  ); then
    return 2
  fi
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# is_epic <repo-root> <N> [<owner/repo>]
# Prints "1" when issue N carries the `epic` label, "0" when it demonstrably
# does not, and returns 0 in both cases. Returns 2 (printing nothing) when the
# label list could NOT be read — the caller MUST treat that as "assume epic"
# (fail-closed, issue #81), mirroring count_open_blockers' contract exactly.
#
# This is the authoritative backstop behind the pickup search's `-label:epic`,
# which reads GitHub's eventually-consistent SEARCH index. orchestrate.sh calls
# it AFTER the lock and BEFORE the claim: an epic that leaked into pickup during
# an index lag is caught here before it is ever assigned to us and launched
# against its aggregating body (docs/epic-orchestration.md §2.3, avoin päätös B).
# FAIL-CLOSED for the same asymmetry as S2b: refusing a leaf issue costs one
# skipped tick; running an epic burns the whole implementer timeout on a body
# that is not a task. Stays on the personal gh-CLI identity — a low-volume
# per-issue read like count_open_blockers, outside issue #127's list-read routing.
is_epic() {
  local repo="$1"
  local n="$2"
  local owner_repo="${3:-}"
  local out
  if ! out=$(
    cd "$repo" || exit 1
    # shellcheck disable=SC2046
    gh issue view "$n" $(_repo_args "$owner_repo") --json labels \
      --jq 'if ([.labels[].name] | any(. == "epic")) then "1" else "0" end' 2>/dev/null
  ); then
    return 2
  fi
  case "$out" in
    0|1) printf '%s' "$out" ;;
    *)   return 2 ;;  # unexpected body → fail-closed
  esac
}

# list_epic_children <repo-root> <N> [<owner/repo>] [OPTIONS]
# Resolves the child issues of epic N and prints one TAB-separated line per
# child on stdout:
#
#   <number>\t<state>\t<labels-csv>\t<owner/repo>\t<title>
#
# where <state> is "open"/"closed" and <owner/repo> is the child's HOME repo (the
# repo the child lives in, NOT necessarily the epic's repo — see cross-repo
# below). This is the SINGLE shared resolver every consumer uses — the running
# poller (lib/epic.sh), /run-epic (run-epic.sh, its --stop path), AND Ohjaamo's V4
# epic view (lib/status-github.sh) — so no two can disagree about which issues
# belong to an epic (AC5, docs/epic-orchestration.md §1.3; issue #91 wired the
# view onto it). Returns 0 on a successful read (including the empty case — an epic
# with no children prints nothing), 2 when the read failed (fail-closed: the
# caller must not treat "unreadable" as "done").
#
# Resolution order (docs/epic-orchestration.md §1.2): native GitHub sub-issues
# are CANONICAL. The body task-list is read ONLY as a fallback, and ONLY when
# there are zero native sub-issues — merging the two sources would produce ghost
# or duplicate children, so native wins whenever it has ANY child.
#
#   labels-csv is populated in native mode (the sub_issues API returns each
#   child's full label set for free) and EMPTY in fallback mode (the task-list
#   carries no label data). Callers that need child labels (propagation skip,
#   needs-human escalation) therefore have them without a per-child read on the
#   canonical path.
#
# FALLBACK STATE IS AUTHORITATIVE (issue #91). A task-list child's state is
# NEVER inferred from the checkbox alone — the box can lie (a `[ ]` on an issue
# that is actually closed, or a `[x]` on one still open). It is resolved against
# the set of OPEN issues in the child's HOME repo: number IN the open set =>
# "open"; NOT in the set + `[x]` => "closed" (done; absent from the open list);
# NOT in the set + `[ ]` => SKIPPED (the reference does not resolve to a real open
# issue). The epic-repo open set is INJECTED by the view (--open-map, which
# already has it, so no extra call) or, when absent, fetched once by this
# function; a cross-repo child's open set is fetched once PER repo. A failed fetch
# is fail-closed (rc 2), so a legacy epic can never announce false completion off
# an unreadable open list.
#
# CROSS-REPO CHILDREN ARE SUPPORTED (issue #92). GitHub's sub-issue relation
# permits a child in another repo; the epic layer handles it in the child's OWN
# repo (propagation, escalation, completion all target owner/repo per child — the
# repo travels in the TSV so every consumer targets the right repo). A native
# child in another repo is kept with its own owner/repo (from repository_url); a
# fallback `owner/repo#N` reference is kept with that owner/repo. What stays out of
# scope is a cross-repo WORKTREE / single PR — each child still runs in its own
# repo as its own run (docs/epic-orchestration.md Scope-out). The view resolves
# IDENTICALLY because it goes through this same function (issue #91 AC5).
#
# The function binds NO identity — the caller chooses (issue #91 edge case): the
# run side uses the plain gh-CLI (a pick-time read, like is_epic); the view passes
# `--gh-runner gha_with_token` so the App identity is honoured. NOTE (issue #92
# edge): the App token is per-org, so a cross-repo child in ANOTHER org is read
# with a token minted for the wrong org and its open-set fetch may fail — that is
# fail-closed (rc 2), never a silent wrong answer. OPTIONS (after the optional
# <owner/repo> positional):
#   --gh-runner <fn>    command prefix to invoke gh (default: none → plain `gh`)
#   --body <text>       pre-fetched epic body → skip the fallback `gh issue view`
#   --open-map <json>   {"<num>":…,…} open-issue set of the EPIC's repo for
#                       authoritative fallback state; when absent this function
#                       fetches it once itself (cross-repo children always fetched)
#   --source-file <p>   path to write the resolution source ("sub_issues" /
#                       "task_list") so a caller running via $(…) can read it back
list_epic_children() {
  local repo="$1" n="$2"
  shift 2 || true
  # <owner/repo> is optional and precedes the flags; a leading `--` means it was
  # omitted (2-arg call, origin mode).
  local owner_repo=""
  if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then
    owner_repo="$1"; shift
  fi
  local gh_runner="" inj_body="" have_body=0 inj_openmap="" have_openmap=0 source_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --gh-runner)   gh_runner="${2:-}"; shift 2 ;;
      --body)        inj_body="${2:-}"; have_body=1; shift 2 ;;
      --open-map)    inj_openmap="${2:-}"; have_openmap=1; shift 2 ;;
      --source-file) source_file="${2:-}"; shift 2 ;;
      *)             shift ;;
    esac
  done

  # gh invocation prefix: the caller's identity choice, never this function's.
  local -a ghc
  if [ -n "$gh_runner" ]; then ghc=("$gh_runner" gh); else ghc=(gh); fi

  local api_path
  if [ -n "$owner_repo" ]; then
    api_path="repos/$owner_repo/issues/$n/sub_issues"
  else
    api_path="repos/{owner}/{repo}/issues/$n/sub_issues"
  fi

  # 1. Native sub-issues (canonical). --paginate handles an epic with many
  # children; each page is a JSON array, so `jq -s 'add // []'` concatenates them.
  local native
  if ! native=$(cd "$repo" && "${ghc[@]}" api --paginate "$api_path" 2>/dev/null); then
    return 2  # unreadable native graph → fail-closed
  fi

  local native_count
  native_count=$(printf '%s' "$native" | jq -s '[.[][]?] | length' 2>/dev/null || echo 0)
  case "$native_count" in ''|*[!0-9]*) native_count=0 ;; esac

  if [ "$native_count" -gt 0 ]; then
    [ -n "$source_file" ] && printf 'sub_issues' > "$source_file" 2>/dev/null
    # Each child keeps its OWN owner/repo (from repository_url), so a cross-repo
    # child is carried through with its home repo rather than dropped (issue #92).
    printf '%s' "$native" | jq -s -r '
      ([.[][]?] | map(select(.number != null)))
      | .[]
      | [ (.number|tostring), .state, ([.labels[]?.name] | join(",")),
          (.repository_url // "" | sub(".*/repos/"; "")), (.title // "") ]
      | @tsv
    ' 2>/dev/null
    return 0
  fi

  # 2. Fallback: parse the epic body's task-list (legacy epics, pre native
  # sub-issues). Only reached when there are zero native children.
  local body
  if [ "$have_body" -eq 1 ]; then
    body="$inj_body"
  elif ! body=$(cd "$repo" && "${ghc[@]}" issue view "$n" $(_repo_args "$owner_repo") --json body --jq '.body // ""' 2>/dev/null); then
    return 2
  fi

  [ -n "$source_file" ] && printf 'task_list' > "$source_file" 2>/dev/null

  # The epic's own owner/repo. Same-repo `#N` refs are labelled with it; it is
  # resolved once here (origin mode has no explicit owner/repo).
  local expected="$owner_repo"
  if [ -z "$expected" ]; then
    expected=$(cd "$repo" && "${ghc[@]}" repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo "")
  fi

  # Per-repo open-issue set cache for authoritative fallback state. The epic
  # repo's set is injected by the view (--open-map) or fetched lazily; a cross-repo
  # child's set is fetched once per repo and cached in this dir. A failed fetch is
  # fail-closed (rc 2). The dir is cleaned on return (covers every return path).
  local mapdir=""
  mapdir=$(mktemp -d "${TMPDIR:-/tmp}/lec-maps.XXXXXX" 2>/dev/null) || mapdir=""
  # shellcheck disable=SC2064
  [ -n "$mapdir" ] && trap "rm -rf '$mapdir'" RETURN

  local openmap="$inj_openmap" openmap_ready="$have_openmap"
  local line cbox num state title seen=" " child_repo cur_map cr_key cr_file cr_raw open_raw
  while IFS= read -r line; do
    # Require a GitHub task-list checkbox: `- [ ]` / `- [x]` (also * and +).
    [[ "$line" =~ ^[[:space:]]*[-*+][[:space:]]+\[([ xX])\][[:space:]] ]] || continue
    cbox="${BASH_REMATCH[1]}"
    # Cross-repo `owner/repo#N` reference → keep it, homed in that repo (#92).
    if [[ "$line" =~ ([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)#([0-9]+) ]]; then
      child_repo="${BASH_REMATCH[1]}"
      num="${BASH_REMATCH[2]}"
    elif [[ "$line" =~ \#([0-9]+) ]]; then
      # Same-repo `#N` reference → the epic's own repo.
      child_repo="$expected"
      num="${BASH_REMATCH[1]}"
    else
      continue
    fi
    # First reference to a repo#number wins (dedup by owner/repo#N, issue #92:
    # a bare number no longer uniquely identifies a child across repos).
    case "$seen" in *" $child_repo#$num "*) continue ;; esac
    # Resolve the open set for THIS child's repo.
    if [ -n "$child_repo" ] && [ "$child_repo" != "$expected" ]; then
      # Cross-repo: fetch (and cache) this repo's open set once. The cache file is
      # only used when mapdir was created (mktemp -d succeeded); otherwise fall
      # back to fetching each time rather than writing to a bogus path.
      cr_key=$(printf '%s' "$child_repo" | tr '/' '_')
      cr_file=""
      [ -n "$mapdir" ] && cr_file="$mapdir/$cr_key"
      if [ -n "$cr_file" ] && [ -f "$cr_file" ]; then
        cur_map=$(cat "$cr_file")
      else
        if ! cr_raw=$(cd "$repo" && "${ghc[@]}" issue list --repo "$child_repo" --state open --limit 1000 --json number 2>/dev/null); then
          return 2
        fi
        cur_map=$(printf '%s' "$cr_raw" | jq -c 'if type == "array" then (reduce .[] as $i ({}; .[($i.number|tostring)] = 1)) else empty end' 2>/dev/null || printf '')
        [ -n "$cur_map" ] || return 2
        [ -n "$cr_file" ] && printf '%s' "$cur_map" > "$cr_file"
      fi
    else
      # Same-repo: the epic-repo open set (injected or lazily fetched once).
      if [ "$openmap_ready" -ne 1 ]; then
        if ! open_raw=$(cd "$repo" && "${ghc[@]}" issue list $(_repo_args "$owner_repo") --state open --limit 1000 --json number 2>/dev/null); then
          return 2
        fi
        openmap=$(printf '%s' "$open_raw" | jq -c 'if type == "array" then (reduce .[] as $i ({}; .[($i.number|tostring)] = 1)) else empty end' 2>/dev/null || printf '')
        [ -n "$openmap" ] || return 2
        openmap_ready=1
      fi
      cur_map="$openmap"
    fi
    # Authoritative state (issue #91): the open set, not the checkbox.
    #   in open set          → open
    #   not in set, [x]/[X]  → closed (done; absent from the open list)
    #   not in set, [ ]      → skip (does not resolve to a real open issue)
    if printf '%s' "$cur_map" | jq -e --arg k "$num" 'has($k)' >/dev/null 2>&1; then
      state="open"
    elif [ "$cbox" != " " ]; then
      state="closed"
    else
      continue
    fi
    seen="$seen$child_repo#$num "
    # Title: the line minus the leading checkbox and the trailing `[owner/repo]#N …`.
    title=$(printf '%s' "$line" \
      | sed -E 's/^[[:space:]]*[-*+][[:space:]]+\[[ xX]\][[:space:]]*//; s/[[:space:]]*([A-Za-z0-9._-]+\/[A-Za-z0-9._-]+)?#[0-9]+.*$//; s/[[:space:]]*$//')
    printf '%s\t%s\t\t%s\t%s\n' "$num" "$state" "$child_repo" "$title"
  done <<EOF
$body
EOF
  return 0
}

# comment_issue <repo-root> <N> <text> [<owner/repo>] [<remote>]
# Posts a comment to the issue. Text is passed via stdin to avoid
# argument-length and quoting issues on long bodies.
#
# Routed via _issue_gh so the comment is authored as <app>[bot] when App mode
# is active AND the remote is origin (per-org App scope: non-origin remotes
# bypass App mode). The clarification loop's detect_answer compares COMMENT
# TIMESTAMPS against an awaiting-answer marker, not authors, so the identity
# switch is safe — see tests/test-answer-detection.sh for the invariant.
comment_issue() {
  local repo="$1"
  local n="$2"
  local text="$3"
  local owner_repo="${4:-}"
  local remote="${5:-origin}"
  (
    cd "$repo"
    # shellcheck disable=SC2046
    printf '%s' "$text" | _issue_gh --remote "$remote" -- \
      issue comment "$n" $(_repo_args "$owner_repo") --body-file -
  )
}

# build_marker <run-id> <issue-num> <iso-ts> [<round>]
# Emits an HTML comment marker on stdout that uniquely identifies an
# awaiting-answer situation comment. Invisible in rendered GitHub markdown.
# Used by α2 (answer-and-continue) to find the run a human reply belongs to;
# in α1 it is emitted in answerable situations as a harmless forward-marker.
build_marker() {
  local run_id="$1"
  local issue_num="$2"
  local ts="$3"
  local round="${4:-0}"
  printf '<!-- run-issues:awaiting-answer run=%s issue=%s ts=%s round=%s -->' \
    "$run_id" "$issue_num" "$ts" "$round"
}

# truncate_for_github <max-bytes>
# Reads stdin, writes stdout. If the input fits within max-bytes it is passed
# through unchanged. Otherwise the TAIL is kept (the decision line lives at the
# end: CYCLE_REVIEW_DECISION: / IMPLEMENTER_RESULT:) and the head is dropped,
# with a visible truncation notice prepended. The notice is included in the
# byte budget so the result (notice + tail) stays at or under max-bytes.
truncate_for_github() {
  local max_bytes="$1"
  local input
  input=$(cat)
  local in_bytes
  in_bytes=$(printf '%s' "$input" | wc -c | tr -d ' ')

  if [ "$in_bytes" -le "$max_bytes" ]; then
    printf '%s' "$input"
    return 0
  fi

  local notice='_(Tuloste typistetty — täysi loki run-kansiossa.)_'$'\n'
  local notice_bytes
  notice_bytes=$(printf '%s' "$notice" | wc -c | tr -d ' ')
  local tail_bytes=$(( max_bytes - notice_bytes ))
  [ "$tail_bytes" -lt 0 ] && tail_bytes=0

  printf '%s' "$notice"
  printf '%s' "$input" | tail -c "$tail_bytes"
}

# fetch_issue_json <repo-root> <N> [<owner/repo>] [<remote>]
# Prints the issue body + comments as a JSON object on stdout.
# Routed via _issue_gh so reads count against the App's rate limit (15k/h) when
# active and the remote is origin. Non-origin remotes bypass App mode (per-org
# App scope-out).
#
# `state` ("OPEN"/"CLOSED") is included so the poller's scan_blocked_answered
# (issue #57) can gate on an open issue from the SAME fetch it uses for the
# marker/answer detection — no extra network round-trip. Every other caller
# reads named fields (title/body/comments/…) and ignores the extra field.
fetch_issue_json() {
  local repo="$1"
  local n="$2"
  local owner_repo="${3:-}"
  local remote="${4:-origin}"
  (
    cd "$repo"
    # shellcheck disable=SC2046
    _issue_gh --remote "$remote" -- \
      issue view "$n" $(_repo_args "$owner_repo") --json title,body,labels,author,comments,state
  )
}

# parse_marker <issue-json-file>
# Scans the issue comments for the NEWEST `run-issues:awaiting-answer` marker
# and prints "ts=<ISO> round=<n> run=<id>" on stdout, or nothing if absent.
# "Newest" is decided by the marker's own ts= field, which the orchestrator
# sets from _state_now (%FT%TZ) — so a string sort is a chronological sort
# (see tests/test-answer-detection.sh for why string comparison is valid).
# A comment may carry the marker anywhere in its body; we match the HTML
# comment with a regex and capture its ts/round/run attributes.
parse_marker() {
  local fixture="$1"
  jq -r '
    [ .comments[]?
      | .body
      | capture("<!-- run-issues:awaiting-answer run=(?<run>[^ ]+) issue=[^ ]+ ts=(?<ts>[^ ]+) round=(?<round>[^ ]+) -->"; "g")
    ]
    | sort_by(.ts)
    | last
    | if . == null then empty else "ts=\(.ts) round=\(.round) run=\(.run)" end
  ' "$fixture"
}

# detect_answer <issue-json-file> <marker-ts>
# Prints the body of the NEWEST comment created strictly after <marker-ts>
# that is NOT itself a run-issues bot comment (body does not contain the
# "run-issues:" token). Empty output means "no human reply yet".
#
# The bot and the human share the same GitHub account, so author is NOT a usable
# discriminator — the marker timestamp is the only durable boundary. The reply
# body is capped to keep the downstream cycle-review prompt bounded.
detect_answer() {
  local fixture="$1"
  local marker_ts="$2"
  local max_chars="${3:-8000}"
  jq -r --arg ts "$marker_ts" --argjson max "$max_chars" '
    [ .comments[]?
      | select(.createdAt > $ts)
      | select((.body | contains("run-issues:")) | not)
    ]
    | sort_by(.createdAt)
    | last
    | if . == null then empty else (.body[0:$max]) end
  ' "$fixture"
}
