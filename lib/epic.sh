#!/usr/bin/env bash
# lib/epic.sh — epic-level auto-run automation for /run-issues (issue #81).
#
# An epic is a GitHub issue carrying the `epic` label that COLLECTS runnable
# sub-issues; it is never itself runnable (orchestrate.sh's S2c gate and the
# pickup search's `-label:epic` keep it out of execution). This module is the
# thin layer ON TOP of the existing dependency-run (pickup, locks, S2b, PR
# watcher): it does not run children itself, it PREPARES them so the normal
# poller picks them up (docs/epic-orchestration.md §6).
#
# Three responsibilities, all idempotent because the poller repeats them every
# tick:
#
#   1. PROPAGATE the run labels (auto-run + whatever the watchlist requires) to
#      the epic's OPEN children that lack them. "auto-run on an epic" means
#      "run this epic" = "label the children and let the poller run the chain
#      under S2b's ordering" (§3). Monotonic add: a child is never de-labelled,
#      and a human opts a child out with `wip` (§3.3, avoin päätös D).
#
#   2. ESCALATE to the epic when a child stalls: a child that has earned the
#      needs-human label gets a ONE-TIME situation comment on the EPIC naming it,
#      so the epic's reader sees the chain is partly stuck without opening every
#      child (§4.2). Once-per-child via a hidden marker in the epic's comments —
#      the same suppression idiom as #65's SKIP_CLOSED (read the recorded state,
#      do not repeat).
#
#   3. ANNOUNCE completion: when every child is closed, the epic gets a summary
#      comment listing the children (and their PRs, best-effort) plus an
#      `epic-complete` label — ONCE. The runner does NOT close the epic: closing
#      is a human decision (the epic body may carry acceptance criteria a human
#      must verify), and GitHub's native auto-close wins if the repo enables it
#      (§4.1, avoin päätös F; the cycle review pinned this additive form).
#
# Only functions are defined here — no work at source time — so it is safe to
# source from the poller (which already has issue.sh / labels.sh loaded) and
# from tests in isolation. It pulls in its own deps so a lone caller needs this
# file alone.

set -euo pipefail

_EPIC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# list_epic_children / is_epic / fetch_issue_json / comment_issue live here.
# shellcheck source=issue.sh
. "$_EPIC_DIR/issue.sh"
# labels_add / labels_ensure — REST label writes (no read:project scope needed).
# shellcheck source=labels.sh
. "$_EPIC_DIR/labels.sh"

# _epic_log <message> — best-effort logger, same spirit as run-terminate.sh's
# _run_terminate_log. orchestrate.sh/poller callers with a log() function get it;
# pollers set $LOG; a bare caller (test / terminal) falls back to stderr so a
# line is never silently dropped.
_epic_log() {
  if declare -F log >/dev/null 2>&1; then
    log "epic: $*"
  elif [ -n "${LOG:-}" ]; then
    printf '%s epic: %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"
  else
    printf '%s epic: %s\n' "$(date -u +%FT%TZ)" "$*" >&2
  fi
}

# epic_list_open <repo-root> <labels-csv> [<owner/repo>]
# Prints the issue number of every OPEN epic that carries the run labels, one per
# line. The epic must carry the run labels (typically auto-run) for us to touch
# it: that is the "run this epic" propagation signal (§3.1). No `no:assignee`
# filter — an epic is never assigned by the automation, and a human assignee must
# not stop propagation. The run labels are ANDed as separate label:"x" terms,
# exactly like pick_oldest_unassigned. Reading the list is identity-neutral, so
# it stays on the gh-CLI default.
epic_list_open() {
  local repo="$1"
  local labels_csv="${2:-}"
  local owner_repo="${3:-}"
  local search="is:open label:epic sort:created-asc"
  local extra=""
  if [ -n "$labels_csv" ]; then
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
    # shellcheck disable=SC2046
    gh issue list \
      $(_repo_args "$owner_repo") \
      --search "${search}${extra}" \
      --limit 100 \
      --json number \
      --jq '.[].number' 2>/dev/null
  ) || true
}

# _epic_parse_child_line <tsv-line> — split one list_epic_children line
#   <number>\t<state>\t<labels-csv>\t<title>
# into the globals REPLY_NUM / REPLY_STATE / REPLY_LABELS / REPLY_TITLE,
# PRESERVING an empty labels column. `IFS=$'\t' read -r a b c d` cannot be used
# here: tab is an IFS-whitespace character, so a run of two tabs (the empty
# labels column of an unlabelled child) collapses to one, shifting the title into
# the labels slot and blanking the title. Splitting by hand keeps every column.
_epic_parse_child_line() {
  local line="$1" rest
  REPLY_NUM="${line%%$'\t'*}";   rest="${line#*$'\t'}"
  REPLY_STATE="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
  REPLY_LABELS="${rest%%$'\t'*}"
  REPLY_TITLE="${rest#*$'\t'}"
}

# _epic_csv_has <csv> <needle> — 0 if the comma-separated list contains the exact
# element, 1 otherwise. Empty csv never matches.
_epic_csv_has() {
  local csv="$1" needle="$2" item
  [ -n "$csv" ] || return 1
  local IFS=','
  for item in $csv; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

# _epic_missing_labels <have-csv> <want-csv> — prints the comma-separated subset
# of want-csv that is NOT present in have-csv. An empty have-csv (fallback child
# whose labels are unknown) yields the full want-csv.
_epic_missing_labels() {
  local have="$1" want="$2" item first=1 out=""
  local IFS=','
  for item in $want; do
    [ -n "$item" ] || continue
    if ! _epic_csv_has "$have" "$item"; then
      if [ "$first" = 1 ]; then out="$item"; first=0; else out="$out,$item"; fi
    fi
  done
  printf '%s' "$out"
}

# _epic_propagate_child <epic-N> <owner/repo> <child-N> <child-labels-csv> <run-labels-csv>
# The SINGLE run-label propagation decision for one child, shared by the poller's
# epic_process_one and run-epic.sh (#82, AC4: `grep` must not find two label-
# propagation implementations). Best-effort, always returns 0.
#
# It assumes the child is OPEN (closed children are dropped by the callers before
# they get here — closed is not "skip propagation", it is "already done" and the
# poller must still count it). It skips a `wip` child (§3.3 human opt-out) and
# adds only the run labels the child is MISSING (idempotent via _epic_missing_labels;
# labels_add is itself additive). Diagnostics go to the epic log, never stdout, so
# a poller that redirects epic_process_one's stdout to its logfile stays clean.
_epic_propagate_child() {
  local epic="$1" owner_repo="$2" num="$3" child_labels="$4" labels_csv="$5"
  if _epic_csv_has "$child_labels" "wip"; then
    _epic_log "epic #$epic: child #$num is wip — skipping propagation"
    return 0
  fi
  local missing
  missing=$(_epic_missing_labels "$child_labels" "$labels_csv")
  if [ -n "$missing" ]; then
    if labels_add "$owner_repo" "$num" "$missing" 2>&1 | while IFS= read -r _l; do _epic_log "$_l"; done; then :; fi
    _epic_log "epic #$epic: propagated [$missing] to child #$num"
  fi
  return 0
}

# propagate_run_labels <repo-root> <epic-N> <run-labels-csv> [<owner/repo>]
# Resolve the epic's children (the canonical native → task-list resolver) and
# propagate the run labels to every OPEN child through _epic_propagate_child. This
# is the shared apply path M4 (docs/epic-orchestration.md §6.2) that /run-epic
# calls at its write step: the poller's per-tick epic_process_one and the one-shot
# command therefore share ONE propagation implementation (AC4). Best-effort and
# idempotent — always returns 0; an unreadable child graph logs and does nothing
# (fail-closed: a false "propagated" would be worse than waiting a tick).
propagate_run_labels() {
  local repo="$1" epic="$2" labels_csv="${3:-}" owner_repo="${4:-}"
  local children rc=0
  children=$(list_epic_children "$repo" "$epic" "$owner_repo") || rc=$?
  if [ "$rc" -ne 0 ]; then
    _epic_log "epic #$epic: children unreadable (rc=$rc) — cannot propagate"
    return 0
  fi
  local line num state child_labels
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    _epic_parse_child_line "$line"
    num="$REPLY_NUM"; state="$REPLY_STATE"; child_labels="$REPLY_LABELS"
    [ -n "$num" ] || continue
    [ "$state" = "closed" ] && continue
    _epic_propagate_child "$epic" "$owner_repo" "$num" "$child_labels" "$labels_csv"
  done <<EOF
$children
EOF
  return 0
}

# _epic_issue_has_comment_marker <issue-json-file> <marker> — 0 if any comment
# body contains the literal marker string. Used for the per-child attention and
# the completion once-guards (the marker lives in GitHub itself, so idempotency
# survives across ticks and hosts without a local state file).
_epic_issue_has_comment_marker() {
  local file="$1" marker="$2"
  jq -e --arg m "$marker" 'any(.comments[]?; (.body // "") | contains($m))' "$file" >/dev/null 2>&1
}

# _epic_labels_have <issue-json-file> <label> — 0 if the issue carries the label.
_epic_labels_have() {
  local file="$1" label="$2"
  jq -e --arg l "$label" 'any(.labels[]?; (.name // "") == $l)' "$file" >/dev/null 2>&1
}

# _epic_child_pr_refs <repo-root> <child-N> [<owner/repo>] — best-effort: print
# the PR references (`#<n>`) that closed the child, space-separated, or nothing.
# Uses GraphQL closedByPullRequestsReferences; any failure (endpoint, auth,
# absent data) degrades silently to no PR — the summary still lists the child.
_epic_child_pr_refs() {
  local repo="$1" child="$2" owner_repo="${3:-}"
  local o r
  if [ -n "$owner_repo" ]; then
    o="${owner_repo%%/*}"; r="${owner_repo##*/}"
  else
    local nwo
    nwo=$(cd "$repo" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo "")
    [ -n "$nwo" ] || return 0
    o="${nwo%%/*}"; r="${nwo##*/}"
  fi
  local q='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){closedByPullRequestsReferences(first:5,includeClosedPrs:true){nodes{number}}}}}'
  ( cd "$repo" && gh api graphql -f query="$q" -F o="$o" -F r="$r" -F n="$child" \
      --jq '[.data.repository.issue.closedByPullRequestsReferences.nodes[]?.number | "#\(.)"] | join(" ")' 2>/dev/null ) || true
}

# epic_process_one <repo-root> <epic-N> <labels-csv> [<owner/repo>] [<remote>]
# Runs all three responsibilities for one epic. Always returns 0 — a single
# epic's GitHub hiccup must never abort the poller's tick; every write is
# best-effort and every read failure degrades to skipping just that step.
epic_process_one() {
  local repo="$1"
  local epic="$2"
  local labels_csv="${3:-}"
  local owner_repo="${4:-}"
  local remote="${5:-origin}"

  # Resolve the child set once (the canonical native → fallback resolver, shared
  # with Ohjaamo's view). rc 2 = unreadable: skip this epic this tick rather than
  # act on a half-read graph (a false "complete" would be worse than waiting).
  local children rc=0
  children=$(list_epic_children "$repo" "$epic" "$owner_repo") || rc=$?
  if [ "$rc" -ne 0 ]; then
    _epic_log "epic #$epic: children unreadable (rc=$rc) — skipping this tick"
    return 0
  fi
  if [ -z "$children" ]; then
    _epic_log "epic #$epic: no children resolved — nothing to do"
    return 0
  fi

  # Fetch the epic once for the label + comment guards and the summary title.
  local epic_json
  epic_json=$(mktemp -t epic-json.XXXXXX)
  # shellcheck disable=SC2064
  trap "rm -f '$epic_json'" RETURN
  if ! fetch_issue_json "$repo" "$epic" "$owner_repo" "$remote" > "$epic_json" 2>/dev/null; then
    _epic_log "epic #$epic: could not fetch epic issue — skipping this tick"
    return 0
  fi
  local epic_title
  epic_title=$(jq -r '.title // ""' "$epic_json" 2>/dev/null || echo "")

  local total=0 closed=0
  local num state child_labels title line
  # 1. PROPAGATION + 2. ESCALATION, per child.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    _epic_parse_child_line "$line"
    num="$REPLY_NUM"; state="$REPLY_STATE"; child_labels="$REPLY_LABELS"; title="$REPLY_TITLE"
    [ -n "$num" ] || continue
    total=$((total + 1))
    if [ "$state" = "closed" ]; then
      closed=$((closed + 1))
      continue  # closed children are already done — never labelled or escalated
    fi

    # --- opt-out: a human parks a child with `wip` (§3.3). Detectable only on
    # the native path (fallback children carry no label data); that is fine —
    # the realistic epics use native sub-issues. A wip child skips BOTH
    # propagation and escalation (it is a deliberate human hold).
    if _epic_csv_has "$child_labels" "wip"; then
      _epic_log "epic #$epic: child #$num is wip — skipping"
      continue
    fi

    # --- propagate the run labels the child is missing (idempotent). This goes
    # through the SINGLE propagation primitive shared with run-epic.sh (#82,
    # AC4: no second label-propagation implementation).
    _epic_propagate_child "$epic" "$owner_repo" "$num" "$child_labels" "$labels_csv"

    # --- escalate a stalled child to the epic, once per child.
    if _epic_csv_has "$child_labels" "needs-human"; then
      local attn_marker
      attn_marker="<!-- run-issues:epic-attention child=$num -->"
      if _epic_issue_has_comment_marker "$epic_json" "$attn_marker"; then
        : # already escalated for this child — stay silent (SKIP_CLOSED idiom)
      else
        _epic_escalate_child "$repo" "$epic" "$num" "$title" "$owner_repo" "$remote" "$attn_marker"
      fi
    fi
  done <<EOF
$children
EOF

  # 3. COMPLETION — every child closed, at least one child, announced once.
  if [ "$total" -gt 0 ] && [ "$closed" -eq "$total" ]; then
    local complete_marker="<!-- run-issues:epic-complete -->"
    if _epic_labels_have "$epic_json" "epic-complete" \
       || _epic_issue_has_comment_marker "$epic_json" "$complete_marker"; then
      : # already announced — do not repeat
    else
      _epic_announce_complete "$repo" "$epic" "$epic_title" "$children" "$owner_repo" "$remote" "$complete_marker"
    fi
  fi

  return 0
}

# _epic_escalate_child <repo> <epic> <child> <child-title> <owner/repo> <remote> <marker>
# Post a one-time attention comment on the EPIC naming the stalled child, and add
# the filterable epic-attention label. All best-effort.
_epic_escalate_child() {
  local repo="$1" epic="$2" child="$3" child_title="$4" owner_repo="$5" remote="$6" marker="$7"
  local body_file
  body_file=$(mktemp -t epic-attn.XXXXXX)
  {
    echo "$marker"
    echo "## /run-issues — Epicin alaissue vaatii ihmistä"
    echo
    echo "Alaissue #${child} (${child_title:-ei otsikkoa}) on merkitty \`needs-human\`-tilaan, joten epicin ketju on osittain pysähtynyt tästä haarasta. Muut riippumattomat alaissueet jatkavat normaalisti (S2b-portti ajaa vain ne, joiden estäjät ovat kiinni)."
    echo
    echo "Selvitä alaissueen #${child} tilanne — kun se etenee, epic jatkaa itsestään."
  } > "$body_file"
  ( cd "$repo" && labels_ensure "$owner_repo" epic-attention D4C5F9 \
      "Epicin alaissue vaatii ihmistä" ) 2>&1 \
      | while IFS= read -r _l; do _epic_log "$_l"; done || true
  ( cd "$repo" && labels_add "$owner_repo" "$epic" epic-attention ) 2>&1 \
      | while IFS= read -r _l; do _epic_log "$_l"; done || true
  comment_issue "$repo" "$epic" "$(cat "$body_file")" "$owner_repo" "$remote" >/dev/null 2>&1 || true
  rm -f "$body_file"
  _epic_log "epic #$epic: escalated stalled child #$child to epic (once)"
}

# _epic_announce_complete <repo> <epic> <epic-title> <children-tsv> <owner/repo> <remote> <marker>
# Post a one-time completion summary listing every child (and its PRs,
# best-effort) and add the epic-complete label. Does NOT close the epic.
_epic_announce_complete() {
  local repo="$1" epic="$2" epic_title="$3" children="$4" owner_repo="$5" remote="$6" marker="$7"
  local body_file
  body_file=$(mktemp -t epic-done.XXXXXX)
  {
    echo "$marker"
    echo "## /run-issues — Epicin kaikki alaissueet valmiit"
    echo
    echo "Epicin \`${epic_title:-#$epic}\` jokainen alaissue on suljettu. Runner **ei sulje epiciä** — sulkupäätös jää ihmiselle (epicin runko voi sisältää hyväksyntäkriteereitä, jotka on tarkistettava). Jos repo käyttää GitHubin natiivia auto-closea, se sulkee epicin itse."
    echo
    echo "**Alaissueet:**"
    local line num title prs
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      _epic_parse_child_line "$line"
      num="$REPLY_NUM"; title="$REPLY_TITLE"
      [ -n "$num" ] || continue
      prs=$(_epic_child_pr_refs "$repo" "$num" "$owner_repo")
      if [ -n "$prs" ]; then
        echo "- #${num} ${title} — PR: ${prs}"
      else
        echo "- #${num} ${title}"
      fi
    done <<INNER
$children
INNER
  } > "$body_file"
  ( cd "$repo" && labels_ensure "$owner_repo" epic-complete 0E8A16 \
      "Epicin kaikki alaissueet valmiit" ) 2>&1 \
      | while IFS= read -r _l; do _epic_log "$_l"; done || true
  comment_issue "$repo" "$epic" "$(cat "$body_file")" "$owner_repo" "$remote" >/dev/null 2>&1 || true
  ( cd "$repo" && labels_add "$owner_repo" "$epic" epic-complete ) 2>&1 \
      | while IFS= read -r _l; do _epic_log "$_l"; done || true
  rm -f "$body_file"
  _epic_log "epic #$epic: announced completion (once)"
}
