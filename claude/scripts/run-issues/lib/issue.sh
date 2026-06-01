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
# labels-csv may be empty; otherwise it's filtered with -label:waiting -label:blocked -label:wip.
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
  local search="is:open no:assignee -label:blocked -label:waiting -label:wip -label:${clean_label} sort:created-asc"

  local extra=""
  if [ -n "$labels_csv" ]; then
    # Each label becomes a separate `label:"x"` term; gh ANDs them (see above).
    local IFS=','
    for label in $labels_csv; do
      [ -n "$label" ] || continue
      extra+=" label:\"$label\""
    done
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
fetch_issue_json() {
  local repo="$1"
  local n="$2"
  local owner_repo="${3:-}"
  local remote="${4:-origin}"
  (
    cd "$repo"
    # shellcheck disable=SC2046
    _issue_gh --remote "$remote" -- \
      issue view "$n" $(_repo_args "$owner_repo") --json title,body,labels,author,comments
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
