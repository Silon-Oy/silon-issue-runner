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
# GitHub App identity: when the orchestrator has loaded lib/github-app-auth.sh
# and gha_enabled is true, the helpers below route comment / view / label
# operations through gha_with_token so they post as <app>[bot] instead of the
# personal gh-CLI identity. claim_issue / verify_claim / unclaim_issue
# DELIBERATELY stay on the personal identity: GitHub Apps cannot be issue
# assignees, so the race-arbitration logic ("am I the sole assignee?") must
# continue to use a real user account.
#
# Per-org App scope: the App identity is per-org (token is minted for one
# installation). When the active remote is NOT origin, the App-mode wrapper
# would route the call with a token minted for the WRONG org. Per-org App
# support is explicitly scope-out for issue #53, so we fall back to the
# personal gh-CLI identity for non-origin remotes. _issue_gh accepts an
# optional <remote> hint for this purpose.

set -euo pipefail

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

# pick_oldest_unassigned <repo-root> <labels-csv> [<owner/repo>]
# Prints issue number on stdout, or empty string if no match.
# labels-csv may be empty; otherwise it's filtered with -label:waiting -is:blocked -label:wip.
#
# Blocked issues are excluded with GitHub's native `-is:blocked` qualifier,
# which reads the `blocked_by` dependency graph directly — no `blocked` label
# and no synchronising script. A single open blocker is enough to hold an issue
# back, and closing the last blocker clears it within seconds, without any sync.
# NOTE: an unknown negative qualifier does NOT error on GitHub — it silently
# matches everything (measured: `-is:totallynotreal` returned all open issues),
# so a typo here would leak blocked issues into pickup. tests/test-issue-pick.sh
# pins the exact `-is:blocked` string for this reason.
#
# gh search label semantics (probed empirically against a live repo with
# gh 2.88.0, issue #12 — see tests/test-issue-pick.sh):
#   - Multiple `label:"x" label:"y"` terms are ANDed: only issues carrying
#     BOTH labels match. (label:"auto-run" label:"enhancement" → only the
#     issue with both; an issue with auto-run alone does NOT match.)
#   - Negative `-label:"x"` excludes and composes with positive label: terms
#     (label:"auto-run" -label:"enhancement" → auto-run issues lacking
#     enhancement).
#   - Zero matches → gh exits 0 with empty/[] output, so `// empty` yields an
#     empty string and the caller sees a clean "no candidate" signal.
# This AND behaviour is exactly what the orchestrator wants (require every
# configured label), so separate label:"…" terms are the correct encoding.
pick_oldest_unassigned() {
  local repo="$1"
  local labels_csv="${2:-}"
  local owner_repo="${3:-}"
  # auto-clean issues are a teardown signal handled by the poller's scan_clean,
  # never a development candidate — exclude them from new-issue pickup so a
  # labelled issue is not picked up as work.
  local clean_label="${RUN_ISSUES_CLEAN_LABEL:-auto-clean}"
  # Sort is encoded inside --search (sort:created-asc) because gh 2.83+
  # no longer accepts standalone --sort/--order flags on `issue list`.
  #
  # `-label:epic` excludes epic issues from pickup (issue #81). An epic COLLECTS
  # runnable sub-issues; it is never itself runnable (its "implementation" is its
  # children's). Without this an epic carrying auto-run matches the pickup filter
  # exactly like a leaf issue and would be launched against its aggregating body
  # (docs/epic-orchestration.md §2). Like -is:blocked this reads GitHub's
  # eventually-consistent SEARCH index, so orchestrate.sh re-checks authoritatively
  # (is_epic) after the lock — the same second-line-of-defence pattern as S2b.
  local search="is:open no:assignee -is:blocked -label:waiting -label:wip -label:epic -label:${clean_label} sort:created-asc"

  local extra=""
  if [ -n "$labels_csv" ]; then
    # Each label becomes a separate `label:"x"` term; gh ANDs them (see above).
    # The IFS=',' split is confined to this command substitution so it does NOT
    # leak into the subshell below — otherwise `$(_repo_args "$owner_repo")`
    # would word-split on comma instead of space, passing "--repo owner/repo"
    # as a single unknown flag and silently breaking pickup for any non-empty
    # owner/repo. (See the matching fix in poller.sh's inline pickup.)
    extra=$(
      IFS=','
      for label in $labels_csv; do
        [ -n "$label" ] || continue
        printf ' label:"%s"' "$label"
      done
    )
  fi

  (
    cd "$repo"
    # Reading the issue list is unaffected by identity (no privacy boundary
    # crossed) and used during pick — keep this on the gh-CLI default to avoid
    # spending an App API call on every pick attempt.
    # shellcheck disable=SC2046  # intentional word-splitting on _repo_args
    gh issue list \
      $(_repo_args "$owner_repo") \
      --search "${search}${extra}" \
      --limit 1 \
      --json number \
      --jq '.[0].number // empty'
  )
}

# claim_issue <repo-root> <N> [<owner/repo>]
# Assigns the issue to @me. Returns 0 on success, non-zero on failure.
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
  )
}

# verify_claim <repo-root> <N> [<owner/repo>]
# Returns 0 only if the current user is the SOLE assignee. A multi-assignee
# state means a racing runner has also claimed the issue — caller must lose
# the race and unclaim. GitHub permits concurrent --add-assignee calls, so
# verifying singleton membership is the only durable arbiter.
#
# Stays on the personal identity for the same reason as claim_issue: the
# arbiter is "is @me alone assigned", and @me only resolves to a user account.
verify_claim() {
  local repo="$1"
  local n="$2"
  local owner_repo="${3:-}"
  local me current
  me=$(gh api user --jq .login)
  current=$(
    cd "$repo"
    # shellcheck disable=SC2046
    gh issue view "$n" $(_repo_args "$owner_repo") --json assignees --jq '[.assignees[].login] | join(",")'
  )
  [ "$current" = "$me" ]
}

# unclaim_issue <repo-root> <N> [<owner/repo>]
# Removes the @me assignee. Idempotent (best-effort).
unclaim_issue() {
  local repo="$1"
  local n="$2"
  local owner_repo="${3:-}"
  (
    cd "$repo"
    # shellcheck disable=SC2046
    gh issue edit "$n" $(_repo_args "$owner_repo") --remove-assignee "@me" >/dev/null 2>&1 || true
  )
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
# gh-CLI identity: this is a pick-time read with no privacy boundary, like
# pick_oldest_unassigned.
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
# read with no privacy boundary, like count_open_blockers.
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
# that is not a task. Stays on the personal gh-CLI identity — a pick-time read
# with no privacy boundary, like pick_oldest_unassigned / count_open_blockers.
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

# list_epic_children <repo-root> <N> [<owner/repo>]
# Resolves the child issues of epic N and prints one TAB-separated line per
# child on stdout:
#
#   <number>\t<state>\t<labels-csv>\t<title>
#
# where <state> is "open"/"closed". This is the SINGLE shared resolver both the
# running poller (issue #81) and Ohjaamo's V4 epic view consume, so the two can
# never disagree about which issues belong to an epic (AC5,
# docs/epic-orchestration.md §1.3). Returns 0 on a successful read (including
# the empty case — an epic with no children prints nothing), 2 when the native
# read failed (fail-closed: the caller must not treat "unreadable" as "done").
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
# Cross-repo children are out of scope (Rajaukset): a native child in another
# repo is filtered out (and would otherwise be mislabelled in the epic's OWN
# repo, since propagation writes with the epic's owner/repo), and a fallback
# `owner/repo#N` reference is skipped. Both cases emit a one-line warning on
# stderr so the exclusion is visible, never silent.
list_epic_children() {
  local repo="$1"
  local n="$2"
  local owner_repo="${3:-}"

  # Expected owner/repo for the cross-repo filter. In multi-remote mode it is
  # passed explicitly; in origin mode it is empty, so resolve it once from the
  # working copy (cheap, cached for the call) — otherwise a native cross-repo
  # child could be labelled against the epic's repo by number.
  local expected="$owner_repo"
  if [ -z "$expected" ]; then
    expected=$(cd "$repo" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo "")
  fi

  local api_path
  if [ -n "$owner_repo" ]; then
    api_path="repos/$owner_repo/issues/$n/sub_issues"
  else
    api_path="repos/{owner}/{repo}/issues/$n/sub_issues"
  fi

  # 1. Native sub-issues (canonical). --paginate handles an epic with many
  # children; each page is a JSON array, so `jq -s 'add // []'` concatenates them.
  local native
  if ! native=$(cd "$repo" && gh api --paginate "$api_path" 2>/dev/null); then
    return 2  # unreadable native graph → fail-closed
  fi

  local native_count
  native_count=$(printf '%s' "$native" | jq -s '[.[][]?] | length' 2>/dev/null || echo 0)
  case "$native_count" in ''|*[!0-9]*) native_count=0 ;; esac

  if [ "$native_count" -gt 0 ]; then
    # Warn about (and drop) any native child that lives in another repo.
    local skipped
    skipped=$(printf '%s' "$native" | jq -s -r --arg exp "$expected" '
      ([.[][]?] | map(select(.number != null)))
      | map(select(($exp != "") and ((.repository_url // "" | sub(".*/repos/"; "")) != $exp)))
      | .[] | "\(.repository_url // "" | sub(".*/repos/"; ""))#\(.number)"
    ' 2>/dev/null || true)
    if [ -n "$skipped" ]; then
      local ref
      while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        printf 'list_epic_children: epic #%s: cross-repo child %s skipped (scope-out)\n' "$n" "$ref" >&2
      done <<EOF
$skipped
EOF
    fi
    printf '%s' "$native" | jq -s -r --arg exp "$expected" '
      ([.[][]?] | map(select(.number != null)))
      | map(select($exp == "" or ((.repository_url // "" | sub(".*/repos/"; "")) == $exp)))
      | .[]
      | [ (.number|tostring), .state, ([.labels[]?.name] | join(",")), (.title // "") ]
      | @tsv
    ' 2>/dev/null
    return 0
  fi

  # 2. Fallback: parse the epic body's task-list (legacy epics, pre native
  # sub-issues). Only reached when there are zero native children.
  local body
  if ! body=$(cd "$repo" && gh issue view "$n" $(_repo_args "$owner_repo") --json body --jq '.body // ""' 2>/dev/null); then
    return 2
  fi
  local line cbox num state title
  while IFS= read -r line; do
    # Require a GitHub task-list checkbox: `- [ ]` / `- [x]` (also * and +).
    [[ "$line" =~ ^[[:space:]]*[-*+][[:space:]]+\[([ xX])\][[:space:]] ]] || continue
    cbox="${BASH_REMATCH[1]}"
    # Cross-repo `owner/repo#N` reference → skip with a warning (scope-out).
    if [[ "$line" =~ ([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)#([0-9]+) ]]; then
      printf 'list_epic_children: epic #%s: cross-repo child %s#%s skipped (scope-out)\n' \
        "$n" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" >&2
      continue
    fi
    # Same-repo `#N` reference.
    [[ "$line" =~ \#([0-9]+) ]] || continue
    num="${BASH_REMATCH[1]}"
    # Checkbox state is the fallback's only truth about the child (§1.2 rule 3):
    # [x]/[X] = done (closed, not run), [ ] = open.
    if [ "$cbox" = " " ]; then state="open"; else state="closed"; fi
    # Title: the line minus the leading checkbox and the trailing `#N …`.
    title=$(printf '%s' "$line" \
      | sed -E 's/^[[:space:]]*[-*+][[:space:]]+\[[ xX]\][[:space:]]*//; s/[[:space:]]*#[0-9]+.*$//; s/[[:space:]]*$//')
    printf '%s\t%s\t\t%s\n' "$num" "$state" "$title"
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
# The bot and maintainer share the same GitHub account, so author is NOT a usable
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
