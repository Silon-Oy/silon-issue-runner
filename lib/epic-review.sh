#!/usr/bin/env bash
# lib/epic-review.sh — collect an epic's review material (issue #272) and run
# the review agent over it (issue #273).
#
# Answers "what did the epic ask for, and what did its children produce
# together": the epic body's acceptance criteria, the child set (number, title,
# state), each child's PR references and the children's combined change surface
# (files changed by those PRs). The material is printed as ONE markdown block on
# stdout; a later step hands it to a review agent.
#
# FAIL-CLOSED, ALL OR NOTHING. Partial material would yield a confident review of
# missing material — the exact failure the epic review exists to catch. Every
# read happens before anything is printed; any unreadable epic, child set,
# child PR reference list or PR file list => rc 1 and EMPTY stdout.
#
# MISSING CRITERIA ARE SAID OUT LOUD. An epic body without an acceptance-criteria
# heading gets an explicit line saying so; criteria are never invented.
#
# SIZE CAP. RUN_ISSUES_EPIC_REVIEW_MAX (bytes, default 60000) bounds the block.
# The change surface is cut first (it is the tail and the least essential part);
# criteria and children are cut only if they alone exceed the cap. A cut is never
# silent: the block ends with a line naming the cut and the variable. The cap is
# resolved at CALL time, not source time (CLAUDE.md §5.5's timing trap).
#
# THE REVIEW (epic_review_run). One question: do the children's changes TOGETHER
# meet the epic's acceptance criteria (prompts/09-epic-review.md names the three
# failure modes). The call goes through call_claude, so the system prompt carries
# both principles pages. The agent runs in a scratch work dir, never a worktree:
# the review is read-only and the dir makes that structural.
#
# Result format the prompt must produce (scoped to the END of the output, the
# same narrow-matching rule lib/merge-gate.sh applies):
#
#   EPIC_FINDING: <criterion> | <description>
#   ...
#   EPIC_REVIEW_RESULT: CRITERIA_MET | FINDINGS
#
# Three outcomes, fail-closed: criteria_met | findings | launch_failed. A launch
# failure is never a verdict (CLAUDE.md §9): non-zero exit (127 CLI missing, 124
# timeout, 75 usage limit), empty output, a missing or contradictory marker or a
# malformed finding line all read as launch_failed — never criteria_met.
#
# Scope: read-only. No GitHub writes, not called from the poller.
# Shared primitives only (CLAUDE.md §7): the child set comes from
# list_epic_children, PR references from _epic_child_pr_refs.
#
# Only functions are defined here — no work at source time. It pulls in its own
# deps (via epic.sh) so a lone caller (test / terminal) needs this file alone.

set -euo pipefail

_EPIC_REVIEW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# epic.sh brings issue.sh (list_epic_children, fetch_issue_json) and owns
# _epic_parse_child_line / _epic_child_ref / _epic_child_pr_refs.
# shellcheck source=epic.sh
. "$_EPIC_REVIEW_DIR/epic.sh"
# call_claude / render_prompt (the single agent seam) and _merge_gate_result_lines
# (the shared tail reader: trailing blanks and bare fences dropped).
# shellcheck source=claude-call.sh
. "$_EPIC_REVIEW_DIR/claude-call.sh"
# shellcheck source=merge-gate.sh
. "$_EPIC_REVIEW_DIR/merge-gate.sh"

EPIC_REVIEW_STEP="09-epic-review"
EPIC_REVIEW_TIMEOUT_DEFAULT=1800

# _epic_review_criteria <body> — print the acceptance-criteria section of an
# issue body: the lines under the first markdown heading naming
# "Hyväksyntäkriteerit" or "Acceptance criteria" (case-insensitive), up to the
# next heading of the same or a higher level. Headings inside code fences do
# not end the section. Leading/trailing blank lines are trimmed. Empty output =
# no criteria.
_epic_review_criteria() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    function hlevel(s,   n) { n = match(s, /^#+[ \t]/); return n ? RLENGTH - 1 : 0 }
    /^[ \t]*(```|~~~)/ { fence = !fence }
    {
      lvl = fence ? 0 : hlevel($0)
      if (!found) {
        if (lvl > 0) {
          l = tolower($0)
          if (index(l, "hyväksyntäkriteerit") || index(l, "acceptance criteria")) {
            found = 1; want = lvl
          }
        }
        next
      }
      if (lvl > 0 && lvl <= want) exit
      buf[++n] = $0
    }
    END {
      first = 1; last = n
      while (first <= last && buf[first] ~ /^[ \t]*$/) first++
      while (last >= first && buf[last] ~ /^[ \t]*$/) last--
      for (i = first; i <= last; i++) print buf[i]
    }'
}

# _epic_review_pr_files <owner/repo> <pr-N> — print the files changed by a PR,
# one per line. rc 1 on any read failure (fail-closed). REST, not search
# (CLAUDE.md §5.2).
_epic_review_pr_files() {
  local owner_repo="$1" pr="$2"
  gh api --paginate "repos/$owner_repo/pulls/$pr/files" --jq '.[].filename' 2>/dev/null || return 1
}

# _epic_review_bytes <text> — byte length of the text.
_epic_review_bytes() {
  printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' '
}

# epic_review_collect <repo-root> <epic-N> [<owner/repo>]
# Print the epic's review material as one markdown block. rc 0 on success,
# rc 1 (and nothing on stdout) when any read failed.
epic_review_collect() {
  local repo="$1" epic="$2" owner_repo="${3:-}"
  local max="${RUN_ISSUES_EPIC_REVIEW_MAX:-60000}"
  case "$max" in ''|*[!0-9]*) max=60000 ;; esac

  # Resolve the epic's owner/repo once: the PR file reads need it explicitly.
  if [ -z "$owner_repo" ]; then
    owner_repo=$(cd "$repo" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || return 1
    [ -n "$owner_repo" ] || return 1
  fi

  # 1. The epic itself.
  local epic_json title body
  epic_json=$(fetch_issue_json "$repo" "$epic" "$owner_repo" 2>/dev/null) || return 1
  title=$(printf '%s' "$epic_json" | jq -r '.title // ""' 2>/dev/null) || return 1
  body=$(printf '%s' "$epic_json" | jq -r '.body // ""' 2>/dev/null) || return 1

  # 2. The child set (shared resolver; rc 2 = unreadable graph).
  local children
  children=$(list_epic_children "$repo" "$epic" "$owner_repo" --body "$body") || return 1

  # 3. Per child: PR references, then each PR's files. Nothing is printed yet.
  local child_lines="" surface="" line num state ctitle child_repo child_ref prs pr files f
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    _epic_parse_child_line "$line"
    num="$REPLY_NUM"; state="$REPLY_STATE"; ctitle="$REPLY_TITLE"; child_repo="$REPLY_REPO"
    [ -n "$num" ] || continue
    [ -n "$child_repo" ] || child_repo="$owner_repo"
    child_ref="$(_epic_child_ref "$child_repo" "$owner_repo" "$num")"
    prs=$(_epic_child_pr_refs "$repo" "$num" "$child_repo") || return 1
    child_lines+="- ${child_ref} (${state:-?}) — ${ctitle} — PR: ${prs:-ei PR-viitteitä}"$'\n'
    for pr in $prs; do
      pr="${pr#\#}"
      files=$(_epic_review_pr_files "$child_repo" "$pr") || return 1
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        surface+="${f}"$'\t'"${child_ref}"$'\n'
      done <<FILES
$files
FILES
    done
  done <<CHILDREN
$children
CHILDREN

  # 4. Combine the surface: one line per file, naming every child that touched it.
  local file_lines=""
  if [ -n "$surface" ]; then
    file_lines=$(printf '%s' "$surface" | LC_ALL=C sort -u | awk -F'\t' '
      $1 != prev { if (NR > 1) print out ")"; out = "- `" $1 "` (" $2; prev = $1; next }
      { out = out ", " $2 }
      END { if (NR > 0) print out ")" }')
  fi

  # 5. Assemble.
  local criteria head
  criteria=$(_epic_review_criteria "$body")
  head="## Epic #${epic}: ${title}"$'\n\n'"### Hyväksyntäkriteerit"$'\n\n'
  if [ -n "$criteria" ]; then
    head+="${criteria}"$'\n\n'
  else
    head+="_Epicin rungossa ei ole hyväksyntäkriteerejä — niitä ei ole keksitty._"$'\n\n'
  fi
  head+="### Alaissueet"$'\n\n'
  if [ -n "$child_lines" ]; then
    head+="$child_lines"$'\n'
  else
    head+="_Epicillä ei ole alaissueita._"$'\n\n'
  fi
  head+="### Muutospinta"$'\n\n'

  local total_files=0
  [ -z "$file_lines" ] || total_files=$(printf '%s\n' "$file_lines" | wc -l | tr -d ' ')
  local tail
  if [ "$total_files" -gt 0 ]; then tail="$file_lines"; else tail="_Ei muuttuneita tiedostoja._"; fi

  local block="${head}${tail}"
  if [ "$(_epic_review_bytes "$block")" -le "$max" ]; then
    printf '%s\n' "$block"
    return 0
  fi

  # 6. Over the cap: drop file lines from the end. The notice is sized with the
  # original count in both slots (kept <= total, so the real notice is no longer).
  local notice_fmt='_Aineisto katkaistu kokokattoon (RUN_ISSUES_EPIC_REVIEW_MAX=%s tavua): muutospinnasta näytetään %s/%s tiedostoa._'
  local notice reserve head_bytes budget kept
  # shellcheck disable=SC2059
  notice=$(printf "$notice_fmt" "$max" "$total_files" "$total_files")
  reserve=$(( $(_epic_review_bytes "$notice") + 2 ))
  head_bytes=$(_epic_review_bytes "$head")
  budget=$(( max - head_bytes - reserve ))
  if [ "$budget" -ge 0 ] && [ "$total_files" -gt 0 ]; then
    kept=$(printf '%s\n' "$file_lines" | LC_ALL=C awk -v b="$budget" '
      { used += length($0) + 1; if (used > b) exit; print }')
    local kept_n=0
    [ -z "$kept" ] || kept_n=$(printf '%s\n' "$kept" | wc -l | tr -d ' ')
    # shellcheck disable=SC2059
    notice=$(printf "$notice_fmt" "$max" "$kept_n" "$total_files")
    if [ -n "$kept" ]; then
      printf '%s%s\n\n%s\n' "$head" "$kept" "$notice"
    else
      printf '%s%s\n' "$head" "$notice"
    fi
    return 0
  fi

  # Criteria + children alone exceed the cap: cut them at a byte boundary too
  # (whole lines only, so a multibyte character is never split). A cap smaller
  # than the notice itself still prints the notice: a silent cut is worse than
  # an oversized block.
  notice="_Aineisto katkaistu kokokattoon (RUN_ISSUES_EPIC_REVIEW_MAX=${max} tavua): kriteerit ja alaissueet eivät mahdu kokonaan, muutospinta (${total_files} tiedostoa) puuttuu kokonaan._"
  budget=$(( max - $(_epic_review_bytes "$notice") - 2 ))
  [ "$budget" -ge 0 ] || budget=0
  kept=$(printf '%s' "$head" | LC_ALL=C awk -v b="$budget" '
    { used += length($0) + 1; if (used > b) exit; print }')
  if [ -n "$kept" ]; then
    printf '%s\n\n%s\n' "$kept" "$notice"
  else
    printf '%s\n' "$notice"
  fi
}

# epic_review_timeout — the review call's budget in seconds. Read at CALL time
# (CLAUDE.md §5.5's timing trap); a non-numeric or zero value => the default.
epic_review_timeout() {
  local t="${RUN_ISSUES_EPIC_REVIEW_TIMEOUT:-$EPIC_REVIEW_TIMEOUT_DEFAULT}"
  case "$t" in ''|*[!0-9]*|0) t="$EPIC_REVIEW_TIMEOUT_DEFAULT" ;; esac
  printf '%s\n' "$t"
}

# epic_review_findings <out-file> — prints every EPIC_FINDING line normalised to
# "criterion|description" (trimmed fields; a "|" inside the description is
# kept). rc 1 if any line lacks a criterion or a description: a finding that
# names no criterion is not one we may report or ignore.
epic_review_findings() {
  local f="$1"
  [ -s "$f" ] || return 0
  { grep -E '^[[:space:]]*EPIC_FINDING:' "$f" 2>/dev/null || true; } | awk '
    function trim(s) { gsub(/^[ \t`*]+|[ \t`*]+$/, "", s); return s }
    BEGIN { bad = 0 }
    {
      line = $0
      sub(/^[ \t]*EPIC_FINDING:[ \t]*/, "", line)
      i = index(line, "|")
      if (!i) { bad = 1; next }
      crit = trim(substr(line, 1, i - 1)); desc = trim(substr(line, i + 1))
      if (crit == "" || desc == "") { bad = 1; next }
      print crit "|" desc
    }
    END { exit bad }'
}

# epic_review_parse <out-file> [<exit-file>] — prints exactly one of
# criteria_met | findings | launch_failed (see the header for the rules).
epic_review_parse() {
  local out="$1" exit_file="${2:-}"
  if [ -n "$exit_file" ]; then
    local rc
    rc=$(tr -dc '0-9' < "$exit_file" 2>/dev/null || true)
    if [ "${rc:-1}" != "0" ]; then printf 'launch_failed'; return 0; fi
  fi
  [ -s "$out" ] || { printf 'launch_failed'; return 0; }

  local last marker
  last=$(_merge_gate_result_lines "$out" | tail -n 1)
  marker=$(printf '%s' "$last" | sed -nE 's/^[[:space:]`*]*EPIC_REVIEW_RESULT:[[:space:]]*([A-Za-z_]+)[[:space:]`*]*$/\1/p')

  local findings count frc=0
  findings=$(epic_review_findings "$out") || frc=$?
  [ "$frc" -eq 0 ] || { printf 'launch_failed'; return 0; }
  count=$(printf '%s' "$findings" | grep -c . || true)

  case "$marker" in
    CRITERIA_MET) [ "${count:-0}" -eq 0 ] && printf 'criteria_met' || printf 'launch_failed' ;;
    FINDINGS)     [ "${count:-0}" -gt 0 ] && printf 'findings' || printf 'launch_failed' ;;
    *)            printf 'launch_failed' ;;
  esac
}

# epic_review_run <work-dir> <epic-ref> <material>
# Render prompts/09-epic-review.md with the material (epic_review_collect's
# block), call the agent in <work-dir> and print the parsed outcome. The agent's
# output stays in <work-dir>/09-epic-review.out for epic_review_findings.
# rc 0 with an outcome on stdout; rc 1 and nothing on stdout when there is no
# material or the prompt could not be rendered (no agent was called).
epic_review_run() {
  local work_dir="$1" epic_ref="$2" material="$3"
  [ -n "$material" ] || return 1
  [ -d "$work_dir" ] || return 1

  local prompt="$work_dir/$EPIC_REVIEW_STEP.prompt"
  render_prompt "$_EPIC_REVIEW_DIR/../prompts/$EPIC_REVIEW_STEP.md" "$prompt" \
    EPIC_REF="$epic_ref" MATERIAL="$material" || return 1
  [ -s "$prompt" ] || return 1

  local arc=0 timeout
  timeout=$(epic_review_timeout)
  ( cd "$work_dir" && RUN_ISSUES_CLAUDE_TIMEOUT="$timeout" call_claude "$work_dir" "$EPIC_REVIEW_STEP" "$prompt" ) >&2 || arc=$?

  if [ "$arc" -ne 0 ]; then
    printf 'launch_failed\n'
    return 0
  fi
  printf '%s\n' "$(epic_review_parse "$work_dir/$EPIC_REVIEW_STEP.out" "$work_dir/$EPIC_REVIEW_STEP.exit")"
}
