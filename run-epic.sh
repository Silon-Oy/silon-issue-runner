#!/usr/bin/env bash
# run-epic.sh — launch a whole epic with one command (issue #82).
#
# Usage:
#   run-epic.sh <epic-N> [--repo <path>] [--remote <name>]
#               [--labels <csv>] [--dry-run] [--start-now]
#
# An epic is a GitHub issue carrying the `epic` label that COLLECTS runnable
# sub-issues; it never runs itself (docs/epic-orchestration.md §1). The poller's
# scan_epics already propagates the run labels every tick — this command is the
# EXPLICIT launch surface it lacked: "run this epic", validated, one command,
# without waiting for the next poller tick.
#
# It is symmetric with stop-run.sh (thin operator surface, plan-then-apply) and
# reuses the SHARED epic machinery instead of copying it: list_epic_children
# resolves the child set (native sub-issues → task-list fallback), and
# propagate_run_labels performs the write through the same _epic_propagate_child
# primitive the poller uses (AC4: one propagation implementation, no second copy).
#
# Plan-then-apply (like install.sh): EVERY validation runs first and writes
# nothing; a single refusal ⇒ zero writes. Only once the epic is proven open,
# non-empty, same-repo and acyclic does it add the `epic` label (if missing,
# idempotently — this doubles as "convert an aggregating issue into an epic",
# docs §5.2 avoin päätös I) and propagate the run labels to the OPEN children.
# --dry-run prints the exact same report and writes nothing.
#
# The report answers the four questions the issue asks: what was (or would be)
# labelled, which sub-issue runs first, which are blocked and behind what, and how
# long the chain is. --start-now additionally launches the first runnable child
# via orchestrate.sh so the chain begins on a machine with no poller (docs §5.3
# avoin päätös J, recommendation (ii) behind the flag).
#
# Exit codes (own space — not the orchestrator's, not stop-run's):
#   0  validated + propagated (or --dry-run plan printed)
#   1  usage error (bad flag / missing or non-numeric epic number)
#   2  epic issue not found or not open — nothing was read past the fetch
#   3  empty epic — no sub-issues (native or task-list); nothing to propagate
#   4  cyclic dependency graph among the children — the cycle is named, no writes
#   5  read failure — the child set or a blocked_by graph was unreadable
#      (fail-closed: an unreadable graph must not be treated as runnable)
#
# Run: run-epic.sh 101 --repo /path/to/repo
#      run-epic.sh 101 --dry-run

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

# ---------- argument parsing ----------
EPIC=""
REPO_ROOT=""
REMOTE=""
LABELS_CSV=""
DRY_RUN=0
START_NOW=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)      REPO_ROOT="${2:-}"; shift 2 ;;
    --remote)    REMOTE="${2:-}"; shift 2 ;;
    --labels)    LABELS_CSV="${2:-}"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --start-now) START_NOW=1; shift ;;
    -h|--help)   usage 0 ;;
    --*)         echo "run-epic: unknown flag '$1'" >&2; usage 1 ;;
    *)
      if [ -n "$EPIC" ]; then
        echo "run-epic: unexpected argument '$1' (epic number already given as '$EPIC')" >&2
        usage 1
      fi
      EPIC="$1"; shift ;;
  esac
done

# The epic number is the one positional argument. Accept a leading '#'.
EPIC="${EPIC#\#}"
case "$EPIC" in
  ''|*[!0-9]*) echo "run-epic: epic issue number is required (e.g. run-epic.sh 101)" >&2; usage 1 ;;
esac

[ -n "$REPO_ROOT" ] || REPO_ROOT="$(pwd)"
if [ ! -d "$REPO_ROOT/.git" ]; then
  echo "run-epic: '$REPO_ROOT' is not a git repository (pass --repo <path>)" >&2
  exit 1
fi
REPO_ROOT="${REPO_ROOT%/}"

# Default the run labels to auto-run — the common single-label case. A repo that
# requires more than auto-run for pickup passes them with --labels (docs §3.3
# avoin päätös E); the command propagates exactly the set it is told to.
[ -n "$LABELS_CSV" ] || LABELS_CSV="auto-run"

# ---------- resolve owner/repo for a non-origin remote ----------
# origin mode leaves OWNER_REPO empty so the epic helpers infer the repo from the
# working copy; a non-origin remote (multi-org clone) must target its own org
# explicitly, exactly as the poller does.
OWNER_REPO=""
REMOTE_EFF="${REMOTE:-origin}"
if [ -n "$REMOTE" ] && [ "$REMOTE" != "origin" ]; then
  # shellcheck source=lib/git-remote.sh
  . "$SCRIPT_DIR/lib/git-remote.sh"
  if ! OWNER_REPO=$(resolve_remote_to_owner_repo "$REPO_ROOT" "$REMOTE" 2>/dev/null); then
    echo "run-epic: remote '$REMOTE' missing or its URL is un-parseable in $REPO_ROOT" >&2
    exit 1
  fi
fi

# epic.sh pulls in issue.sh (fetch_issue_json / list_epic_children / list_blocked_by
# / _epic_labels_have) and labels.sh (labels_add / labels_ensure), and defines the
# shared propagate_run_labels. Source AFTER arg parsing so --help never needs gh.
# shellcheck source=lib/epic.sh
. "$SCRIPT_DIR/lib/epic.sh"
# epic.sh sources with `set -euo pipefail`; restore this script's mode (keep -u
# and pipefail, drop -e) so a fail-closed helper returning non-zero — e.g. a
# failed `bl_out=$(list_blocked_by …)` — is HANDLED below instead of aborting
# the script before its exit-5 path runs.
set +e

# ======================================================================
# VALIDATION (plan phase) — reads only, writes nothing.
# ======================================================================

# --- 1. the epic issue exists and is open ---
EPIC_JSON="$(mktemp -t run-epic-json.XXXXXX)"
trap 'rm -f "$EPIC_JSON" "${CHILDREN_FILE:-}" "${CHILD_WARN_FILE:-}"' EXIT
if ! fetch_issue_json "$REPO_ROOT" "$EPIC" "$OWNER_REPO" "$REMOTE_EFF" > "$EPIC_JSON" 2>/dev/null \
   || [ ! -s "$EPIC_JSON" ]; then
  echo "run-epic: epic issue #$EPIC not found or not accessible in $REPO_ROOT" >&2
  exit 2
fi
EPIC_STATE="$(jq -r '.state // "" | ascii_upcase' "$EPIC_JSON" 2>/dev/null || echo "")"
if [ "$EPIC_STATE" != "OPEN" ]; then
  echo "run-epic: epic issue #$EPIC is not open (state=${EPIC_STATE:-unknown}) — nothing to run" >&2
  exit 2
fi
EPIC_TITLE="$(jq -r '.title // ""' "$EPIC_JSON" 2>/dev/null || echo "")"
EPIC_HAS_LABEL=0
_epic_labels_have "$EPIC_JSON" "epic" && EPIC_HAS_LABEL=1

# --- 2. resolve the child set (native canonical → task-list fallback) ---
# rc 2 from list_epic_children is fail-closed (unreadable native graph); a truly
# empty epic is rc 0 with no output. cross-repo children are dropped with a
# warning on stderr, which we capture for the report.
CHILDREN_FILE="$(mktemp -t run-epic-children.XXXXXX)"
CHILD_WARN_FILE="$(mktemp -t run-epic-warn.XXXXXX)"
if ! list_epic_children "$REPO_ROOT" "$EPIC" "$OWNER_REPO" > "$CHILDREN_FILE" 2>"$CHILD_WARN_FILE"; then
  echo "run-epic: could not read the sub-issues of epic #$EPIC (unreadable graph) — refusing (fail-closed)" >&2
  exit 5
fi
if [ ! -s "$CHILDREN_FILE" ]; then
  echo "run-epic: epic #$EPIC has no sub-issues (no native children, no task-list) — nothing to run" >&2
  echo "run-epic: add sub-issues (or a '- [ ] Title #N' task-list) before running the epic." >&2
  exit 3
fi

# Collect per-child fields into parallel indexed arrays (bash 3.2: no assoc
# arrays). Order is list order = the epic's declared child order.
NUMS=(); STATES=(); LABELS=(); TITLES=()
TOTAL=0; CLOSED=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  # _epic_parse_child_line (from epic.sh) preserves the empty labels column that
  # a plain IFS=$'\t' read would collapse.
  _epic_parse_child_line "$line"
  [ -n "$REPLY_NUM" ] || continue
  NUMS+=("$REPLY_NUM"); STATES+=("$REPLY_STATE"); LABELS+=("$REPLY_LABELS"); TITLES+=("$REPLY_TITLE")
  TOTAL=$((TOTAL + 1))
  [ "$REPLY_STATE" = "closed" ] && CLOSED=$((CLOSED + 1))
done < "$CHILDREN_FILE"
OPEN_COUNT=$((TOTAL - CLOSED))

# The set of OPEN child numbers, as a space-delimited string for membership tests.
OPEN_SET=" "
for i in $(seq 0 $((TOTAL - 1))); do
  [ "${STATES[$i]}" = "open" ] && OPEN_SET="${OPEN_SET}${NUMS[$i]} "
done

# _in_set <needle> <space-list> — 0 if the space-delimited list contains needle.
_in_set() { case "$2" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# --- already-complete short-circuit (issue #82 edge case) ---
# Every sub-issue closed ⇒ nothing to propagate and nothing to run. Report the
# completion and suggest closing (the runner never closes an epic — the body may
# carry acceptance criteria a human must verify, docs §4.1). No writes at all.
if [ "$OPEN_COUNT" -eq 0 ]; then
  echo "run-epic — epic #$EPIC: ${EPIC_TITLE:-（ei otsikkoa）}"
  echo "  repo:       $REPO_ROOT${OWNER_REPO:+ ($OWNER_REPO)}"
  echo "  sub-issues: $TOTAL total, ALL CLOSED — the epic's chain is already complete."
  echo "  nothing to label or run. Verify the epic's acceptance criteria and close it"
  echo "  yourself (the runner does not close epics; the poller has posted the summary)."
  echo
  for i in $(seq 0 $((TOTAL - 1))); do
    echo "    #${NUMS[$i]} ${TITLES[$i]} — closed"
  done
  exit 0
fi

# --- 3. read the blocked_by graph for each OPEN child (fail-closed) ---
# OPEN_BLOCKERS[i]  = csv of every OPEN blocker of child i (any repo/issue)
# INTRA_BLOCKERS[i] = csv of that child's OPEN blockers that are ALSO open
#                     children of this epic (the intra-epic dependency edges)
OPEN_BLOCKERS=(); INTRA_BLOCKERS=()
for i in $(seq 0 $((TOTAL - 1))); do
  OPEN_BLOCKERS[$i]=""; INTRA_BLOCKERS[$i]=""
  [ "${STATES[$i]}" = "open" ] || continue
  bl_out="$(list_blocked_by "$REPO_ROOT" "${NUMS[$i]}" "$OWNER_REPO")"
  if [ "$?" -ne 0 ]; then
    echo "run-epic: could not read the blocked_by graph of sub-issue #${NUMS[$i]} — refusing (fail-closed)" >&2
    exit 5
  fi
  ob=""; ib=""
  while IFS=$'\t' read -r b_num b_state; do
    [ -n "$b_num" ] || continue
    [ "$b_state" = "open" ] || continue
    ob="${ob:+$ob,}$b_num"
    if _in_set "$b_num" "$OPEN_SET"; then ib="${ib:+$ib,}$b_num"; fi
  done <<< "$bl_out"
  OPEN_BLOCKERS[$i]="$ob"
  INTRA_BLOCKERS[$i]="$ib"
done

# --- 4. cycle detection over the intra-epic edges (Kahn, no assoc arrays) ---
# Repeatedly resolve any open child whose intra-epic blockers are all resolved.
# Whatever cannot be resolved is part of (or downstream of) a cycle.
RESOLVED=" "
remaining="$OPEN_COUNT"
progress=1
while [ "$remaining" -gt 0 ] && [ "$progress" -eq 1 ]; do
  progress=0
  for i in $(seq 0 $((TOTAL - 1))); do
    [ "${STATES[$i]}" = "open" ] || continue
    _in_set "${NUMS[$i]}" "$RESOLVED" && continue
    all_in=1
    if [ -n "${INTRA_BLOCKERS[$i]}" ]; then
      IFS=','
      for dep in ${INTRA_BLOCKERS[$i]}; do
        _in_set "$dep" "$RESOLVED" || { all_in=0; break; }
      done
      unset IFS
    fi
    if [ "$all_in" -eq 1 ]; then
      RESOLVED="${RESOLVED}${NUMS[$i]} "
      remaining=$((remaining - 1))
      progress=1
    fi
  done
done
if [ "$remaining" -gt 0 ]; then
  cyc=""
  for i in $(seq 0 $((TOTAL - 1))); do
    [ "${STATES[$i]}" = "open" ] || continue
    _in_set "${NUMS[$i]}" "$RESOLVED" || cyc="${cyc:+$cyc, }#${NUMS[$i]}"
  done
  echo "run-epic: cyclic blocked_by dependency among sub-issues: $cyc — refusing to run" >&2
  echo "run-epic: break the cycle (remove a 'blocked by' edge) and try again." >&2
  exit 4
fi

# ---------- derive the report facts ----------
# First runnable = first OPEN child (list order) with zero OPEN blockers of any
# kind — that is exactly S2b's pickup condition.
FIRST_RUNNABLE=""
for i in $(seq 0 $((TOTAL - 1))); do
  [ "${STATES[$i]}" = "open" ] || continue
  if [ -z "${OPEN_BLOCKERS[$i]}" ]; then FIRST_RUNNABLE="${NUMS[$i]}"; break; fi
done

# What propagation WOULD do per open child (also drives the report).
would_label=""   # "#N,#M" list of open children missing the labels
already=""       # already fully labelled
skipped_wip=""
for i in $(seq 0 $((TOTAL - 1))); do
  [ "${STATES[$i]}" = "open" ] || continue
  if _epic_csv_has "${LABELS[$i]}" "wip"; then
    skipped_wip="${skipped_wip:+$skipped_wip, }#${NUMS[$i]}"
    continue
  fi
  if [ -n "$(_epic_missing_labels "${LABELS[$i]}" "$LABELS_CSV")" ]; then
    would_label="${would_label:+$would_label, }#${NUMS[$i]}"
  else
    already="${already:+$already, }#${NUMS[$i]}"
  fi
done

# ---------- report ----------
mode_tag="[apply]"; [ "$DRY_RUN" -eq 1 ] && mode_tag="[dry-run — no changes]"
{
  echo "run-epic $mode_tag — epic #$EPIC: ${EPIC_TITLE:-（ei otsikkoa）}"
  echo "  repo:          $REPO_ROOT${OWNER_REPO:+ ($OWNER_REPO)}"
  echo "  run labels:    $LABELS_CSV"
  if [ "$EPIC_HAS_LABEL" -eq 1 ]; then
    echo "  epic label:    present"
  elif [ "$DRY_RUN" -eq 1 ]; then
    echo "  epic label:    MISSING — would be added"
  else
    echo "  epic label:    MISSING — will be added"
  fi
  echo "  sub-issues:    $TOTAL total ($OPEN_COUNT open, $CLOSED closed)  ← chain length"
  echo "  first to run:  ${FIRST_RUNNABLE:+#}${FIRST_RUNNABLE:-none (all open children are blocked or none open)}"
  echo
  echo "  propagation:"
  echo "    label:       ${would_label:-none (all open children already carry the labels)}"
  echo "    already set:  ${already:-none}"
  [ -n "$skipped_wip" ] && echo "    skipped wip: $skipped_wip"
  echo
  echo "  run order:"
  for i in $(seq 0 $((TOTAL - 1))); do
    case "${STATES[$i]}" in
      closed) echo "    #${NUMS[$i]} ${TITLES[$i]} — closed" ;;
      open)
        if [ -z "${OPEN_BLOCKERS[$i]}" ]; then
          echo "    #${NUMS[$i]} ${TITLES[$i]} — runnable now"
        else
          echo "    #${NUMS[$i]} ${TITLES[$i]} — blocked by #$(printf '%s' "${OPEN_BLOCKERS[$i]}" | sed 's/,/, #/g')"
        fi ;;
    esac
  done
  if [ -s "$CHILD_WARN_FILE" ]; then
    echo
    echo "  warnings:"
    sed 's/^/    /' "$CHILD_WARN_FILE"
  fi
} >&1

# ======================================================================
# APPLY — only past this point does anything get written.
# ======================================================================
if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "run-epic: dry-run complete — nothing was written."
  exit 0
fi

echo
echo "run-epic: applying…"

# 1. Ensure the `epic` label on the epic (idempotent; docs §5.2 avoin päätös I).
if [ "$EPIC_HAS_LABEL" -ne 1 ]; then
  ( cd "$REPO_ROOT" && labels_ensure "$OWNER_REPO" epic B60205 "Kokoava epic-issue" ) 2>&1 \
    | sed 's/^/  /' || true
  ( cd "$REPO_ROOT" && labels_add "$OWNER_REPO" "$EPIC" epic ) 2>&1 | sed 's/^/  /' || true
  echo "  added 'epic' label to #$EPIC"
fi

# 2. Propagate the run labels to the open children — the SHARED apply path (AC4).
propagate_run_labels "$REPO_ROOT" "$EPIC" "$LABELS_CSV" "$OWNER_REPO"
echo "  propagated run labels to open children (see report above)"

# 3. --start-now: launch the first runnable child immediately (docs §5.3).
if [ "$START_NOW" -eq 1 ]; then
  if [ -z "$FIRST_RUNNABLE" ]; then
    echo "  --start-now: no runnable child right now — the poller will pick the chain up."
  else
    ORCH="${RUN_EPIC_ORCHESTRATE:-$SCRIPT_DIR/orchestrate.sh}"
    echo "  --start-now: launching orchestrate.sh for sub-issue #$FIRST_RUNNABLE"
    if [ -n "$REMOTE" ] && [ "$REMOTE" != "origin" ]; then
      RUN_ISSUES_AUTO=1 RUN_ISSUES_REVIEW_GATE=auto "$ORCH" "$REPO_ROOT" "$FIRST_RUNNABLE" --remote "$REMOTE" || true
    else
      RUN_ISSUES_AUTO=1 RUN_ISSUES_REVIEW_GATE=auto "$ORCH" "$REPO_ROOT" "$FIRST_RUNNABLE" || true
    fi
  fi
fi

echo
echo "run-epic: done — epic #$EPIC labelled; the poller runs the chain under S2b ordering."
[ "$START_NOW" -eq 1 ] || echo "run-epic: pass --start-now to launch #${FIRST_RUNNABLE:-<child>} now instead of waiting for a tick."
exit 0
