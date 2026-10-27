#!/usr/bin/env bash
# lib/finding-issues.sh — audit findings to GitHub issues, deduplicated by a
# fingerprint (issue #339).
#
# An audit (security-audit.sh; the coherence audit of #342 next) produces
# findings. Each finding becomes ONE issue carrying a hidden marker with the
# finding's fingerprint, so the next audit recognises it:
#
#   <!-- run-issues:finding kind=<kind> fp=<fingerprint> -->
#
# The mechanism is audit-agnostic. An audit contributes only its kind (which is
# also the label the issues carry), its fingerprint key and its issue text; the
# fingerprint, the marker, the index, the dedup decision and the GitHub writes
# live here once, so two audits cannot drift into two notions of "the same
# finding".
#
# What happens to a finding (finding_issue_plan):
#
#   no issue with the fingerprint    create  — a new issue
#   an open issue                    exists  — nothing (also: the same finding
#                                              twice in one audit)
#   closed as completed              reopen  — the finding recurred after a fix
#   closed as not planned            dismissed — a human decided it is not a
#                                              finding; an audit does not
#                                              overrule that, ever
#
# The index is a REST label listing (state=all), never a search: the search
# connection can be blocked on its own (CLAUDE.md §5.2). Its cost is
# O(issues carrying the label), paid once per audit, not per finding (§5.4).
#
# Fingerprint: sha256 over "<source>|<location without line>|<key>", first 16
# hex. The line number is dropped because code moves; the key is a stable class
# (a scanner's rule or advisory id, the agent's category slug). An unstable
# fingerprint costs a duplicate issue, never a lost finding.
#
# Sourced; defines functions only and does no top-level work. Needs
# lib/labels.sh and lib/merge-gate.sh (sourced here if not yet loaded).

if ! declare -F _labels_repo_path >/dev/null 2>&1; then
  # shellcheck source=labels.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/labels.sh"
fi
if ! declare -F merge_gate_severity_rank >/dev/null 2>&1; then
  # shellcheck source=merge-gate.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/merge-gate.sh"
fi

# _finding_sha256 — sha256 hex of stdin (shasum on macOS, sha256sum elsewhere).
_finding_sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  else sha256sum | awk '{print $1}'; fi
}

# finding_location_file <location> — the location without a trailing line or
# line range (`a/b.php:12`, `a/b.php:12-14`, `a/b.php:L12`) and without `./`.
finding_location_file() {
  printf '%s' "$1" | sed -E -e 's/^[[:space:]]+|[[:space:]]+$//g' -e 's#^\./##' \
    -e 's/:L?[0-9]+(-L?[0-9]+)?$//'
}

# finding_fingerprint <source> <location> <key> — 16 hex characters.
finding_fingerprint() {
  local src key loc
  src=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  loc=$(finding_location_file "$2")
  key=$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
  printf '%s|%s|%s' "$src" "$loc" "$key" | _finding_sha256 | cut -c1-16
}

# finding_marker <kind> <fingerprint> — the hidden marker an issue body carries.
finding_marker() {
  printf '<!-- run-issues:finding kind=%s fp=%s -->' "$1" "$2"
}

# finding_issues_index <owner/repo> <label> <index-file> — write every issue
# carrying <label> that has a finding marker, one TSV row per marker:
#   fingerprint  kind  number  state  title
# state is open | closed | dismissed (closed as not planned). PRs are dropped
# (REST /issues returns them too). rc 1 if the listing failed: the caller must
# then write NOTHING — an empty index would turn every known finding into a
# duplicate.
finding_issues_index() {
  local owner_repo="$1" label="$2" index="$3" raw enc
  enc=$(jq -rn --arg s "$label" '$s|@uri' 2>/dev/null) || enc="$label"
  if ! raw=$(labels_gh api --paginate "repos/$owner_repo/issues?labels=$enc&state=all&per_page=100" 2>/dev/null); then
    return 1
  fi
  printf '%s' "$raw" | jq -r '
      .[]? | select(.pull_request | not)
      | . as $i
      | ($i.body // "") | [scan("<!-- run-issues:finding kind=([a-z0-9-]+) fp=([0-9a-f]+) -->")][]
      | [.[1], .[0], ($i.number | tostring),
         (if $i.state == "open" then "open"
          elif ($i.state_reason // "") == "not_planned" then "dismissed"
          else "closed" end),
         ($i.title // "" | gsub("[\t\r\n]"; " "))]
      | @tsv' > "$index" 2>/dev/null || return 1
}

# finding_issue_plan <index-file> <kind> <fingerprint> — prints one of
# "create", "exists <N>", "reopen <N>", "dismissed <N>". An open issue wins over
# a closed one with the same fingerprint (a human may have opened a fresh copy).
finding_issue_plan() {
  local index="$1" kind="$2" fp="$3" rows n
  rows=$(awk -F'\t' -v fp="$fp" -v k="$kind" '$1 == fp && $2 == k' "$index" 2>/dev/null)
  if [ -z "$rows" ]; then printf 'create'; return 0; fi
  n=$(printf '%s\n' "$rows" | awk -F'\t' '$4 == "open" { print $3; exit }')
  if [ -n "$n" ]; then printf 'exists %s' "$n"; return 0; fi
  n=$(printf '%s\n' "$rows" | awk -F'\t' '$4 == "dismissed" { print $3; exit }')
  if [ -n "$n" ]; then printf 'dismissed %s' "$n"; return 0; fi
  n=$(printf '%s\n' "$rows" | awk -F'\t' 'NR == 1 { print $3 }')
  printf 'reopen %s' "$n"
}

# finding_issue_note <index-file> <kind> <fingerprint> <number> <title> — record
# that the finding now has an OPEN issue, so a second occurrence in the same
# audit plans "exists" instead of a second create or reopen.
finding_issue_note() {
  printf '%s\t%s\t%s\topen\t%s\n' "$3" "$2" "$4" "$(printf '%s' "$5" | tr '\t\r\n' '   ')" >> "$1"
}

# finding_issue_apply <owner/repo> <index-file> <kind> <fingerprint> <title>
#                     <body> <labels-csv> <reopen-comment> [<assignee>]
# Carries out finding_issue_plan. <labels-csv> is every label the issue should
# carry (the kind's label first, then e.g. pickup labels); each is ensured in the
# repo before use. A reopened issue gets <reopen-comment> and the labels.
#
# <assignee> (optional, issue #374) routes the issue to a login — the caller
# resolves it with pick_assignee_route so the issue matches this machine's
# pickup in a repo with an `assignees` list. A created issue gets it in the SAME
# POST, so there is never a labelled-but-unrouted issue (the #239 rule). A
# reopened issue gets it only when it has no assignee: an existing assignment
# is a human's routing and stays. GitHub silently drops an assignee without
# repo access; that, like a failed assignee write on reopen, is a warning on
# stderr and not rc 1 — the issue exists either way.
# The body must already contain finding_marker. Prints "<action> #<N>" (create
# prints "created #N"); rc 1 on a failed GitHub write, with the reason on stderr.
finding_issue_apply() {
  local owner_repo="$1" index="$2" kind="$3" fp="$4" title="$5" body="$6" labels="$7" comment="$8"
  local assignee="${9:-}"
  local plan action n lbl resp
  plan=$(finding_issue_plan "$index" "$kind" "$fp")
  action="${plan%% *}"
  n="${plan#* }"
  case "$action" in
    exists|dismissed)
      printf '%s #%s' "$action" "$n"
      return 0
      ;;
  esac

  local -a label_args=()
  while IFS= read -r lbl; do
    lbl=$(_labels_trim "$lbl")
    [ -n "$lbl" ] || continue
    labels_ensure "$owner_repo" "$lbl" || return 1
    label_args+=(-f "labels[]=$lbl")
  done <<EOF
$(printf '%s' "$labels" | tr ',' '\n')
EOF

  local -a assignee_args=()
  [ -n "$assignee" ] && assignee_args=(-f "assignees[]=$assignee")

  if [ "$action" = "create" ]; then
    if ! resp=$(labels_gh api --method POST "repos/$owner_repo/issues" \
                  -f "title=$title" -f "body=$body" ${label_args[@]+"${label_args[@]}"} \
                  ${assignee_args[@]+"${assignee_args[@]}"} 2>&1); then
      _labels_diag "finding_issue_apply($owner_repo: create $fp)" "$resp"
      return 1
    fi
    n=$(printf '%s' "$resp" | jq -r '.number // empty' 2>/dev/null)
    if [ -z "$n" ]; then
      _labels_diag "finding_issue_apply($owner_repo: create $fp)" "no issue number in the response"
      return 1
    fi
    if [ -n "$assignee" ] \
       && ! printf '%s' "$resp" | jq -e --arg a "$assignee" 'any(.assignees[]?; .login == $a)' >/dev/null 2>&1; then
      _labels_diag "finding_issue_apply($owner_repo#$n: assign $assignee)" \
        "GitHub did not keep the assignee (no repo access?) — the issue is not routed"
    fi
    finding_issue_note "$index" "$kind" "$fp" "$n" "$title"
    printf 'created #%s' "$n"
    return 0
  fi

  # reopen
  if ! resp=$(labels_gh api --method PATCH "repos/$owner_repo/issues/$n" -f state=open 2>&1); then
    _labels_diag "finding_issue_apply($owner_repo#$n: reopen)" "$resp"
    return 1
  fi
  local assigned
  assigned=$(printf '%s' "$resp" | jq -r '(.assignees // []) | length' 2>/dev/null)
  if [ -n "$assignee" ] && [ "$assigned" = 0 ]; then
    local aresp
    if ! aresp=$(labels_gh api --method POST "repos/$owner_repo/issues/$n/assignees" \
                   -f "assignees[]=$assignee" 2>&1 >/dev/null); then
      _labels_diag "finding_issue_apply($owner_repo#$n: assign $assignee)" "$aresp"
    fi
  fi
  finding_issue_note "$index" "$kind" "$fp" "$n" "$title"
  if ! resp=$(labels_gh api --method POST "repos/$owner_repo/issues/$n/comments" -f "body=$comment" 2>&1 >/dev/null); then
    _labels_diag "finding_issue_apply($owner_repo#$n: comment)" "$resp"
    return 1
  fi
  if [ -n "$labels" ]; then
    labels_add "$owner_repo" "$n" "$labels" || return 1
  fi
  printf 'reopened #%s' "$n"
}

# finding_issues_auto_run_min <repo-config-json> <section> <machine-value> — the
# mildest severity whose issue gets the pickup labels, or `none`. The REPO's
# `.<section>.audit_auto_run_min_severity` wins over the machine value, which
# wins over the default `high` — the same order as merge_gate_hold_min, for the
# same reason: how much an audit may start on its own is a property of the
# application, not of the machine that happens to run the audit.
#
# Fails the OTHER way from the merge gate, on purpose: an unparseable config or
# an unknown value resolves to `none` (issues are still created, nothing runs on
# its own). The gate's safe side is "hold more"; an audit's safe side is "start
# fewer unattended code changes".
finding_issues_auto_run_min() {
  local cfg="$1" section="$2" machine="$3" repo_val=""
  if [ -n "$cfg" ]; then
    if ! repo_val=$(jq -r --arg s "$section" '.[$s].audit_auto_run_min_severity // empty' <<<"$cfg" 2>/dev/null); then
      echo "finding-issues: .claude/run-issues.json on the default branch is not valid JSON — no $section finding gets pickup labels" >&2
      printf 'none'
      return 0
    fi
  fi
  local val="${repo_val:-${machine:-high}}"
  val=$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')
  if [ "$val" = none ] || merge_gate_severity_rank "$val" >/dev/null; then
    printf '%s' "$val"
  else
    echo "finding-issues: unknown $section audit_auto_run_min_severity '$val' (want none or one of: $MERGE_GATE_SEVERITIES) — no finding gets pickup labels" >&2
    printf 'none'
  fi
}

# finding_issues_auto_runs <min> <severity> — rc 0 when a finding of <severity>
# reaches <min> (finding_issues_auto_run_min). `none` and unknown severities
# never do.
finding_issues_auto_runs() {
  local min="$1" sev="$2" mr sr
  [ "$min" = none ] && return 1
  mr=$(merge_gate_severity_rank "$min") || return 1
  sr=$(merge_gate_severity_rank "$sev") || return 1
  [ "$sr" -ge "$mr" ]
}
