#!/usr/bin/env bash
# lib/issue.sh — GitHub issue interactions wrapped around the `gh` CLI.
#
# All commands operate against the repo passed as first argument; we cd
# into it for the duration of each call to avoid relying on $PWD in the
# orchestrator. Output is plain JSON / number / text on stdout; errors
# escape via gh's non-zero exit.

set -euo pipefail

# pick_oldest_unassigned <repo-root> <labels-csv>
# Prints issue number on stdout, or empty string if no match.
# labels-csv may be empty; otherwise it's filtered with -label:waiting -label:blocked -label:wip.
pick_oldest_unassigned() {
  local repo="$1"
  local labels_csv="${2:-}"
  local search='is:open no:assignee -label:blocked -label:waiting -label:wip'

  local extra=""
  if [ -n "$labels_csv" ]; then
    # gh search semantics: each label is added as a separate label: term.
    local IFS=','
    for label in $labels_csv; do
      [ -n "$label" ] || continue
      extra+=" label:\"$label\""
    done
  fi

  (
    cd "$repo"
    # --sort created --order asc: oldest first.
    # --search keeps full control over filters (label/no:assignee/etc).
    gh issue list \
      --search "${search}${extra}" \
      --sort created \
      --order asc \
      --limit 1 \
      --json number \
      --jq '.[0].number // empty'
  )
}

# claim_issue <repo-root> <N>
# Assigns the issue to @me. Returns 0 on success, non-zero on failure.
claim_issue() {
  local repo="$1"
  local n="$2"
  (
    cd "$repo"
    gh issue edit "$n" --add-assignee "@me" >/dev/null
  )
}

# verify_claim <repo-root> <N>
# Returns 0 if the current user owns the assignment, 1 otherwise.
verify_claim() {
  local repo="$1"
  local n="$2"
  local me current
  me=$(gh api user --jq .login)
  current=$(
    cd "$repo"
    gh issue view "$n" --json assignees --jq '[.assignees[].login] | join(",")'
  )
  case ",$current," in
    *",$me,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# unclaim_issue <repo-root> <N>
# Removes the @me assignee. Idempotent (best-effort).
unclaim_issue() {
  local repo="$1"
  local n="$2"
  (
    cd "$repo"
    gh issue edit "$n" --remove-assignee "@me" >/dev/null 2>&1 || true
  )
}

# comment_issue <repo-root> <N> <text>
# Posts a comment to the issue. Text is passed via stdin to avoid
# argument-length and quoting issues on long bodies.
comment_issue() {
  local repo="$1"
  local n="$2"
  local text="$3"
  (
    cd "$repo"
    printf '%s' "$text" | gh issue comment "$n" --body-file -
  )
}

# fetch_issue_json <repo-root> <N>
# Prints the issue body + comments as a JSON object on stdout.
fetch_issue_json() {
  local repo="$1"
  local n="$2"
  (
    cd "$repo"
    gh issue view "$n" --json title,body,labels,author,comments
  )
}
