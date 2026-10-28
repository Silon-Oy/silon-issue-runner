#!/usr/bin/env bash
# lib/epic-write.sh — write epics, their child issues, the sub-issue links and
# the blocked_by dependencies to GitHub in /issue-runner:new-epic's order
# (issue #396).
#
# The order is the command's (commands/issue-runner/new-epic.md §3): the epic
# first so the children can be linked to it, then the children, then the
# sub-issue links, then the dependencies. Dependencies are written after EVERY
# epic of the plan has been created, so a child may wait for a child of another
# epic. Both link endpoints take an issue's `id`, not its number, so issues are
# created with `gh api` whose answer carries both.
#
# This writer never adds a pickup label or an assignee: it writes the labels the
# plan names and nothing else. Starting a run is a separate, human decision
# (/issue-runner:run-epic). That is also why the labels may go in with the
# create call instead of last: what new-epic must keep for last is the pickup
# label, and there is none here.
#
# Failures (new-epic §3.1): an epic that cannot be created skips its children
# and every dependency touching them; a child that cannot be created, or a link
# or dependency that fails, does not stop the rest. Every SUCCESSFUL write is
# recorded in the ledger as it happens — a half-written plan nobody is told
# about is the worst outcome — and rc 1 says at least one write failed.
#
# Plan JSON (the input contract):
#   { "epics": [ { "key", "title", "body", "labels": [..],
#                  "children": [ { "key", "title", "body", "labels": [..],
#                                  "blocked_by": [<child key>, ..] } ] } ] }
# Keys are unique across the whole plan. A blocked_by key that names no
# written child is reported as a failed dependency.
#
# Sourced; defines functions only. Needs lib/labels.sh (labels_gh,
# labels_ensure), sourced here if not yet loaded.

if ! declare -F labels_ensure >/dev/null 2>&1; then
  # shellcheck source=labels.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/labels.sh"
fi

# epic_write_create_issue <owner/repo> <title> <body-file> <labels-csv> — create
# one issue; prints "<number>\t<id>". The body comes from a file so markdown,
# newlines and backticks arrive untouched; the labels go in the same call.
# rc 1 with the reason on stderr.
epic_write_create_issue() {
  local owner_repo="$1" title="$2" body_file="$3" labels="$4" resp line
  if ! resp=$(jq -n --arg t "$title" --rawfile b "$body_file" --arg l "$labels" \
                '{title: $t, body: $b}
                 + ([$l | split(",")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0)]
                    | if length > 0 then {labels: .} else {} end)' \
              | labels_gh api --method POST "repos/$owner_repo/issues" --input - 2>&1); then
    _labels_diag "epic_write_create_issue($owner_repo: $title)" "$resp"
    return 1
  fi
  line=$(printf '%s' "$resp" | jq -r 'select(.number and .id) | [.number, .id] | @tsv' 2>/dev/null)
  if [ -z "$line" ]; then
    _labels_diag "epic_write_create_issue($owner_repo: $title)" "no issue number or id in the response"
    return 1
  fi
  printf '%s' "$line"
}

# epic_write_link_sub_issue <owner/repo> <epic-number> <child-id> — rc 1 on failure.
epic_write_link_sub_issue() {
  local resp
  if ! resp=$(labels_gh api --method POST "repos/$1/issues/$2/sub_issues" -F "sub_issue_id=$3" 2>&1 >/dev/null); then
    _labels_diag "epic_write_link_sub_issue($1#$2 <- id $3)" "$resp"
    return 1
  fi
}

# epic_write_block <owner/repo> <blocked-number> <blocker-id> — mark the issue
# blocked by the blocker. rc 1 on failure.
epic_write_block() {
  local resp
  if ! resp=$(labels_gh api --method POST "repos/$1/issues/$2/dependencies/blocked_by" -F "issue_id=$3" 2>&1 >/dev/null); then
    _labels_diag "epic_write_block($1#$2 blocked by id $3)" "$resp"
    return 1
  fi
}

# epic_write_plan <owner/repo> <plan-file> <ledger> — write the plan (contract
# above). Prints one line per write, FAIL lines included; appends each
# successful write to <ledger> as TSV:
#   epic <key> <number> <id> | child <key> <number> <id>
#   sub_issue <child-number> <epic-number> | blocked_by <blocked-number> <blocker-number>
# rc 1 when any write failed (or the plan is unreadable), 0 otherwise.
epic_write_plan() {
  local owner_repo="$1" plan="$2" ledger="$3"
  local failed=0 ne nc e c key title labels line num id epic_num tmp ensured=" " lbl
  local -a created_keys=() created_nums=() created_ids=()

  ne=$(jq -r '.epics | length' "$plan" 2>/dev/null) || ne=""
  case "$ne" in ''|*[!0-9]*) _labels_diag "epic_write_plan" "unreadable plan $plan"; return 1 ;; esac
  tmp=$(mktemp "${TMPDIR:-/tmp}/epic-write.XXXXXX") || return 1

  # Every label the plan names, ensured once before the first create.
  while IFS= read -r lbl; do
    [ -n "$lbl" ] || continue
    if [[ "$ensured" != *" $lbl "* ]]; then
      labels_ensure "$owner_repo" "$lbl" || failed=1
      ensured="$ensured$lbl "
    fi
  done < <(jq -r '[.epics[] | .labels[]?, (.children[]? | .labels[]?)] | unique | .[]' "$plan" 2>/dev/null)

  e=0
  while [ "$e" -lt "$ne" ]; do
    title=$(jq -r --argjson e "$e" '.epics[$e].title' "$plan")
    labels=$(jq -r --argjson e "$e" '(.epics[$e].labels // []) | join(",")' "$plan")
    jq -j --argjson e "$e" '.epics[$e].body' "$plan" > "$tmp"
    if ! line=$(epic_write_create_issue "$owner_repo" "$title" "$tmp" "$labels"); then
      failed=1
      printf 'FAIL epic: %s — its children were not written\n' "$title"
      e=$((e + 1)); continue
    fi
    IFS=$'\t' read -r epic_num id <<<"$line"
    printf 'epic\t%s\t%s\t%s\n' "$(jq -r --argjson e "$e" '.epics[$e].key' "$plan")" "$epic_num" "$id" >> "$ledger"
    printf 'created epic #%s: %s\n' "$epic_num" "$title"

    nc=$(jq -r --argjson e "$e" '(.epics[$e].children // []) | length' "$plan")
    local -a child_nums=() child_ids=()
    c=0
    while [ "$c" -lt "$nc" ]; do
      key=$(jq -r --argjson e "$e" --argjson c "$c" '.epics[$e].children[$c].key' "$plan")
      title=$(jq -r --argjson e "$e" --argjson c "$c" '.epics[$e].children[$c].title' "$plan")
      labels=$(jq -r --argjson e "$e" --argjson c "$c" '(.epics[$e].children[$c].labels // []) | join(",")' "$plan")
      jq -j --argjson e "$e" --argjson c "$c" '.epics[$e].children[$c].body' "$plan" > "$tmp"
      if line=$(epic_write_create_issue "$owner_repo" "$title" "$tmp" "$labels"); then
        IFS=$'\t' read -r num id <<<"$line"
        created_keys+=("$key"); created_nums+=("$num"); created_ids+=("$id")
        child_nums+=("$num"); child_ids+=("$id")
        printf 'child\t%s\t%s\t%s\n' "$key" "$num" "$id" >> "$ledger"
        printf 'created #%s: %s\n' "$num" "$title"
      else
        failed=1
        printf 'FAIL child: %s\n' "$title"
      fi
      c=$((c + 1))
    done

    c=0
    while [ "$c" -lt "${#child_nums[@]}" ]; do
      if epic_write_link_sub_issue "$owner_repo" "$epic_num" "${child_ids[$c]}"; then
        printf 'sub_issue\t%s\t%s\n' "${child_nums[$c]}" "$epic_num" >> "$ledger"
        printf 'sub-issue: #%s -> epic #%s\n' "${child_nums[$c]}" "$epic_num"
      else
        failed=1
        printf 'FAIL sub-issue: #%s -> epic #%s\n' "${child_nums[$c]}" "$epic_num"
      fi
      c=$((c + 1))
    done
    unset child_nums child_ids
    e=$((e + 1))
  done
  rm -f "$tmp"

  # Dependencies last, over the whole plan. A child or blocker that was not
  # written cannot be linked: reported, never guessed.
  local blocked blocker bi ki k
  while IFS=$'\t' read -r blocked blocker; do
    [ -n "$blocked" ] || continue
    bi=""; ki=""
    k=0
    while [ "$k" -lt "${#created_keys[@]}" ]; do
      [ "${created_keys[$k]}" = "$blocked" ] && bi="$k"
      [ "${created_keys[$k]}" = "$blocker" ] && ki="$k"
      k=$((k + 1))
    done
    if [ -z "$bi" ] || [ -z "$ki" ]; then
      failed=1
      printf 'FAIL blocked_by: %s waits for %s — one of them was not written\n' "$blocked" "$blocker"
      continue
    fi
    if epic_write_block "$owner_repo" "${created_nums[$bi]}" "${created_ids[$ki]}"; then
      printf 'blocked_by\t%s\t%s\n' "${created_nums[$bi]}" "${created_nums[$ki]}" >> "$ledger"
      printf 'blocked_by: #%s waits for #%s\n' "${created_nums[$bi]}" "${created_nums[$ki]}"
    else
      failed=1
      printf 'FAIL blocked_by: #%s waits for #%s\n' "${created_nums[$bi]}" "${created_nums[$ki]}"
    fi
  done < <(jq -r '.epics[].children[]? | .key as $k | (.blocked_by // [])[] | [$k, .] | @tsv' "$plan" 2>/dev/null)

  return "$failed"
}
