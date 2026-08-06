#!/usr/bin/env bash
# labels.sh — label management for issues and PRs via the REST API.
#
# Why not `gh issue edit --add-label` / `gh pr edit --add-label`?
# ---------------------------------------------------------------
# Those subcommands go through gh's GraphQL *edit* mutation, whose selection
# set also covers the item's ProjectV2 fields. gh therefore refuses to run
# them unless the token carries the `read:project` OAuth scope:
#
#   error: your authentication token is missing required scopes [read:project]
#
# Attaching a label needs no project data. The plain REST label endpoints are
# satisfied by the `repo` scope alone, so calling them directly removes the
# scope dependency instead of relying on every machine's gh token happening to
# have been minted with an extra scope it does not otherwise need.
#
# This is not hypothetical: between 2026-06-12 and 2026-07-20 every
# propagate_pr_labels call on this fleet failed for exactly this reason. The
# failures were invisible because label management is best-effort and the
# callers discarded stderr — so `auto-merge` silently never reached any PR and
# the issue → PR → auto-merge chain stalled on its last step (customer-c-erp#40).
# Hence the second rule here: these helpers never swallow the diagnostic. They
# stay non-fatal, but they say why on stderr so the caller can log it.
#
# REST treats a PR as an issue for labelling purposes, so `repos/{O}/{R}/issues/
# {N}/labels` serves both and the issue/PR split in the callers disappears.
#
# Labels are passed as repeated `-f 'labels[]=<name>'` arguments rather than a
# JSON body on stdin. Both work; argv keeps the label name visible to `ps`, to
# `set -x` traces and to the gh mocks in tests/, which assert on the recorded
# argument line.

# labels_gh <args…> — indirection point for the GitHub App identity. orchestrate.sh
# sets LABELS_GH_FN=_gh_for_labels so label writes are attributed to <app>[bot]
# on origin remotes; callers with no App wiring (poller, auto-clean, cleanup-run)
# get plain gh.
labels_gh() {
  "${LABELS_GH_FN:-gh}" "$@"
}

# _labels_repo_path <owner/repo> — the {owner}/{repo} segment of an API path.
# An empty owner/repo is not an error: orchestrate.sh deliberately leaves
# OWNER_REPO empty on origin remotes so gh infers the repo from the working
# directory. gh api honours the literal {owner}/{repo} placeholders and fills
# them from the cwd's git remote, so the same cwd-inference survives the move
# from `gh issue edit` to `gh api`. Callers must run in the repo in that case,
# exactly as they already did.
_labels_repo_path() {
  local owner_repo="${1:-}"
  if [ -n "$owner_repo" ]; then
    printf '%s' "$owner_repo"
  else
    printf '{owner}/{repo}'
  fi
}

# _labels_trim <string> — strip leading/trailing whitespace.
_labels_trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# _labels_diag <prefix> <stderr-text> — emit a single-line diagnostic. Long gh
# errors are flattened and clipped so a caller's log stays one line per event.
_labels_diag() {
  local prefix="$1" err="$2"
  [ -n "$err" ] || err="(no output)"
  printf '%s: %s\n' "$prefix" "$(printf '%s' "$err" | tr '\n' ' ' | cut -c1-300)" >&2
}

# labels_owner_repo_from_url <url> — pure. "https://github.com/o/r/pull/42" -> "o/r".
# Accepts both /pull/ and /issues/ URLs; prints nothing on no match.
labels_owner_repo_from_url() {
  printf '%s' "${1:-}" | sed -nE 's#^https?://[^/]+/([^/]+)/([^/]+)/(pull|issues)/[0-9]+.*$#\1/\2#p'
}

# labels_number_from_url <url> — pure. "https://github.com/o/r/pull/42" -> "42".
labels_number_from_url() {
  printf '%s' "${1:-}" | sed -nE 's#^https?://[^/]+/[^/]+/[^/]+/(pull|issues)/([0-9]+).*$#\2#p'
}

# labels_add <owner/repo> <number> <labels-csv>
# Adds every label in the CSV in one call. Additive: existing labels on the
# item are kept (this is POST, not PUT). Returns gh's exit code; on failure a
# one-line diagnostic goes to stderr.
labels_add() {
  local owner_repo="$1" number="$2" csv="$3"
  if [ -z "$number" ] || [ -z "$csv" ]; then
    _labels_diag "labels_add" "missing argument (number='$number' labels='$csv')"
    return 2
  fi

  local -a args=(api --method POST "repos/$(_labels_repo_path "$owner_repo")/issues/$number/labels")
  local lbl found=0
  while IFS= read -r lbl; do
    lbl="$(_labels_trim "$lbl")"
    [ -n "$lbl" ] || continue
    args+=(-f "labels[]=$lbl")
    found=1
  done <<EOF
$(printf '%s' "$csv" | tr ',' '\n')
EOF
  if [ "$found" -eq 0 ]; then
    _labels_diag "labels_add" "no non-empty label names in '$csv'"
    return 2
  fi

  local err rc
  err=$(labels_gh "${args[@]}" 2>&1 >/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || _labels_diag "labels_add($owner_repo#$number: $csv)" "$err"
  return "$rc"
}

# labels_remove <owner/repo> <number> <label>
# Removing a label that is not attached returns 404 from the API. That IS the
# desired end state (the label is not on the item), so — exactly like
# labels_ensure treats a 422 "already_exists" as success — a 404 is reported as
# rc=0 and stays silent. This distinction matters to callers that count failures
# (cleanup-run.sh): a routine cleanup of an issue that never carried the label
# must not read as a failed GitHub operation, while a real 403 (missing scope)
# or a 127 (gh not on PATH) still returns non-zero and gets counted.
labels_remove() {
  local owner_repo="$1" number="$2" label="$3"
  if [ -z "$number" ] || [ -z "$label" ]; then
    _labels_diag "labels_remove" "missing argument (number='$number' label='$label')"
    return 2
  fi

  # Label names may contain spaces and other path-unsafe characters.
  local encoded
  encoded=$(jq -rn --arg s "$label" '$s|@uri' 2>/dev/null) || encoded="$label"

  local err rc
  err=$(labels_gh api --method DELETE "repos/$(_labels_repo_path "$owner_repo")/issues/$number/labels/$encoded" 2>&1 >/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    # A 404 means the label is already absent — success for our intent.
    if printf '%s' "$err" | grep -qiE 'HTTP 404|404:|not found|does not exist'; then
      return 0
    fi
    _labels_diag "labels_remove($owner_repo#$number: $label)" "$err"
  fi
  return "$rc"
}

# labels_ensure <owner/repo> <label> [<color>] [<description>]
# Creates the label in the repo if it does not exist yet. An existing label
# makes the API return 422, which is success for our intent — so that case is
# reported as rc=0 and stays silent.
labels_ensure() {
  local owner_repo="$1" label="$2" color="${3:-}" desc="${4:-}"
  if [ -z "$label" ]; then
    _labels_diag "labels_ensure" "missing argument (label='$label')"
    return 2
  fi

  local -a args=(api --method POST "repos/$(_labels_repo_path "$owner_repo")/labels" -f "name=$label")
  [ -n "$color" ] && args+=(-f "color=$color")
  [ -n "$desc" ] && args+=(-f "description=$desc")

  local err rc
  err=$(labels_gh "${args[@]}" 2>&1 >/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    # "already_exists" is the documented 422 validation code for a duplicate
    # label name — the desired end state, not an error.
    if printf '%s' "$err" | grep -qi 'already_exists\|already exists'; then
      return 0
    fi
    _labels_diag "labels_ensure($owner_repo: $label)" "$err"
  fi
  return "$rc"
}
