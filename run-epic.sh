#!/usr/bin/env bash
# run-epic.sh — launch a whole epic with one command (issue #82).
#
# Usage:
#   run-epic.sh <epic-N> [--repo <path>] [--remote <name>]
#               [--labels <csv>] [--dry-run] [--start-now]
#   run-epic.sh <epic-N> --stop [--repo <path>] [--remote <name>]
#               [--labels <csv>] [--dry-run]
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
# --stop is the symmetric CANCEL path (issue #90): it HALTS the epic instead of
# launching it. Same plan-then-apply discipline and the SAME child set — it stops
# every live child run by DELEGATING to stop-run.sh (the teardown of #64, never
# reimplemented here), and releases the queued children from pickup by removing
# the run labels FIRST from the epic, THEN from its open children (that order
# stops the poller's scan_epics from re-propagating the labels mid-cancel). It
# does NOT --force a terminal run and does NOT touch a foreign machine's run; both
# are reported and make the overall exit non-zero (partial). --dry-run prints the
# same stop plan and writes nothing.
#
# Exit codes (own space — not the orchestrator's, not stop-run's). Codes 1/2/3/5
# are shared by both modes; 4 is launch-only, 6 is --stop-only:
#   0  launch: validated + propagated. --stop: epic fully stopped (every live
#      child run stopped, run labels removed). Or --dry-run plan printed (either mode)
#   1  usage error (bad flag / missing or non-numeric epic number /
#      --stop combined with --start-now)
#   2  epic issue not found or not open — nothing was read past the fetch
#   3  empty epic — no sub-issues (native or task-list); nothing to propagate/stop
#   4  launch: cyclic dependency graph among the children — cycle named, no writes
#   5  read failure — the child set or a blocked_by graph was unreadable
#      (fail-closed: an unreadable graph must not be treated as runnable)
#   6  --stop: partial — the epic was released but ≥1 live child run could not be
#      stopped (foreign host / terminal without --force / ambiguous / a delegated
#      stop-run.sh call failed). The rest was handled; a full stop is exit 0
#
# Run: run-epic.sh 101 --repo /path/to/repo
#      run-epic.sh 101 --dry-run
#      run-epic.sh 101 --stop

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
STOP=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)      REPO_ROOT="${2:-}"; shift 2 ;;
    --remote)    REMOTE="${2:-}"; shift 2 ;;
    --labels)    LABELS_CSV="${2:-}"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --start-now) START_NOW=1; shift ;;
    --stop)      STOP=1; shift ;;
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

# --stop and --start-now are opposite intents (cancel vs launch): refuse rather
# than guess which one the operator meant (issue #90 edge case).
if [ "$STOP" -eq 1 ] && [ "$START_NOW" -eq 1 ]; then
  echo "run-epic: --stop and --start-now are mutually exclusive" >&2
  usage 1
fi

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
# arrays). Order is list order = the epic's declared child order. REPOS carries
# each child's home owner/repo (issue #92): a cross-repo child is labelled,
# escalated and blocked-checked in its OWN repo, and the report groups by it.
NUMS=(); STATES=(); LABELS=(); TITLES=(); REPOS=()
TOTAL=0; CLOSED=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  # _epic_parse_child_line (from epic.sh) preserves the empty labels column that
  # a plain IFS=$'\t' read would collapse.
  _epic_parse_child_line "$line"
  [ -n "$REPLY_NUM" ] || continue
  # An origin-mode child may carry no repo → the epic's own owner/repo.
  _child_repo="$REPLY_REPO"; [ -n "$_child_repo" ] || _child_repo="$OWNER_REPO"
  NUMS+=("$REPLY_NUM"); STATES+=("$REPLY_STATE"); LABELS+=("$REPLY_LABELS")
  TITLES+=("$REPLY_TITLE"); REPOS+=("$_child_repo")
  TOTAL=$((TOTAL + 1))
  [ "$REPLY_STATE" = "closed" ] && CLOSED=$((CLOSED + 1))
done < "$CHILDREN_FILE"
OPEN_COUNT=$((TOTAL - CLOSED))

# The epic's effective owner/repo for cross-repo comparison + reporting. In origin
# mode OWNER_REPO is empty, so resolve it once from the working copy (the same way
# list_epic_children does) — otherwise every child would look "cross-repo".
EPIC_REPO="$OWNER_REPO"
if [ -z "$EPIC_REPO" ]; then
  EPIC_REPO="$(cd "$REPO_ROOT" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo "")"
fi

# _child_ref <i> — human-facing reference for child i: owner/repo#N when it lives
# in a different repo than the epic, plain #N otherwise (matches lib/epic.sh).
_child_ref() {
  local i="$1"
  if [ -n "${REPOS[$i]}" ] && [ -n "$EPIC_REPO" ] && [ "${REPOS[$i]}" != "$EPIC_REPO" ]; then
    printf '%s#%s' "${REPOS[$i]}" "${NUMS[$i]}"
  else
    printf '#%s' "${NUMS[$i]}"
  fi
}

# The set of OPEN child numbers, as a space-delimited string for membership tests.
OPEN_SET=" "
for i in $(seq 0 $((TOTAL - 1))); do
  [ "${STATES[$i]}" = "open" ] && OPEN_SET="${OPEN_SET}${NUMS[$i]} "
done

# _in_set <needle> <space-list> — 0 if the space-delimited list contains needle.
_in_set() { case "$2" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ======================================================================
# STOP mode (issue #90) — cancel the epic. Branches out of the launch path
# BEFORE the blocked_by graph + cycle detection (which stopping does not
# need): it reuses only the child set built above (list_epic_children, the
# SHARED resolver — AC2) and the label primitive family of propagation
# (labels_remove is labels_add's sister in lib/labels.sh — AC2, no second
# implementation). Live-run teardown is DELEGATED to stop-run.sh, never
# reimplemented here (AC3). Plan-then-apply like launch: classify every
# child first, write nothing until the plan is whole; --dry-run writes
# nothing at all.
# ======================================================================

# _stop_is_live_status <status> — mirrors stop-run.sh's is_stoppable_status: a
# live run carries status "initialized" throughout its life (S8 restart/continue
# reset it back), and state_finalize is the only writer of a terminal status. An
# empty/malformed field is treated as live (stop-run's own gate is the authority
# at apply time; this is only the plan-phase preview).
_stop_is_live_status() {
  case "${1:-}" in
    initialized|"") return 0 ;;
    *) return 1 ;;
  esac
}

# _stop_scan_child_run <child-N> — read-only scan of the repo's run directories
# for a run of this child. Sets _SCAN_COUNT (0/1/N), and for a single match
# _SCAN_DIR / _SCAN_HOST / _SCAN_STATUS. Mirrors stop-run.sh's own resolution
# (issue_number [+ remote] match) so the plan and the delegate agree on the run;
# it reads named fields only — NO tmux kill, lock release or state_finalize lives
# here (AC3).
_stop_scan_child_run() {
  local child="$1"
  _SCAN_DIR=""; _SCAN_HOST=""; _SCAN_STATUS=""; _SCAN_COUNT=0
  local runs="$REPO_ROOT/.claude/run-issues"
  [ -d "$runs" ] || return 0
  local d n r
  shopt -s nullglob
  for d in "$runs"/*/; do
    d="${d%/}"
    [ -f "$d/run.json" ] || continue
    n=$(jq -r '.issue_number // empty' "$d/run.json" 2>/dev/null || echo "")
    [ "$n" = "$child" ] || continue
    if [ -n "$REMOTE" ]; then
      r=$(jq -r '.remote // "origin"' "$d/run.json" 2>/dev/null || echo "origin")
      [ "$r" = "$REMOTE" ] || continue
    fi
    _SCAN_COUNT=$((_SCAN_COUNT + 1))
    _SCAN_DIR="$d"
    _SCAN_HOST=$(jq -r '.host // empty' "$d/run.json" 2>/dev/null || echo "")
    _SCAN_STATUS=$(jq -r '.status // empty' "$d/run.json" 2>/dev/null || echo "")
  done
  shopt -u nullglob
}

if [ "$STOP" -eq 1 ]; then
  THIS_HOST="$(hostname -s 2>/dev/null || echo unknown)"
  STOP_RUN="${RUN_EPIC_STOP_RUN:-$SCRIPT_DIR/stop-run.sh}"
  # The epic's own label set — its run labels are what we remove FIRST.
  EPIC_LABELS_CSV="$(jq -r '[.labels[]?.name] | join(",")' "$EPIC_JSON" 2>/dev/null || echo "")"

  # Does the epic carry any of the run labels? (drives the report + apply.)
  epic_has_any=0
  for _lbl in $(printf '%s' "$LABELS_CSV" | tr ',' ' '); do
    [ -n "$_lbl" ] || continue
    if _epic_csv_has "$EPIC_LABELS_CSV" "$_lbl"; then epic_has_any=1; break; fi
  done

  # Classify each child into parallel arrays (bash 3.2, no assoc arrays). CLASS:
  #   closed | wip | stoppable | foreign | terminal | ambiguous | norun
  CLASS=(); RUN_HOST_I=(); RUN_STATUS_I=(); HAS_LABEL_I=()
  for i in $(seq 0 $((TOTAL - 1))); do
    CLASS[$i]=""; RUN_HOST_I[$i]=""; RUN_STATUS_I[$i]=""; HAS_LABEL_I[$i]=0
    # does the child carry any run label we would remove?
    for _lbl in $(printf '%s' "$LABELS_CSV" | tr ',' ' '); do
      [ -n "$_lbl" ] || continue
      if _epic_csv_has "${LABELS[$i]}" "$_lbl"; then HAS_LABEL_I[$i]=1; break; fi
    done
    if [ "${STATES[$i]}" = "closed" ]; then CLASS[$i]="closed"; continue; fi
    if _epic_csv_has "${LABELS[$i]}" "wip"; then CLASS[$i]="wip"; continue; fi
    _stop_scan_child_run "${NUMS[$i]}"
    if [ "$_SCAN_COUNT" -eq 0 ]; then
      CLASS[$i]="norun"
    elif [ "$_SCAN_COUNT" -gt 1 ]; then
      CLASS[$i]="ambiguous"
    else
      RUN_HOST_I[$i]="$_SCAN_HOST"; RUN_STATUS_I[$i]="$_SCAN_STATUS"
      if [ -n "$_SCAN_HOST" ] && [ "$_SCAN_HOST" != "$THIS_HOST" ]; then
        CLASS[$i]="foreign"
      elif _stop_is_live_status "$_SCAN_STATUS"; then
        CLASS[$i]="stoppable"
      else
        CLASS[$i]="terminal"
      fi
    fi
  done

  # ---------- report ----------
  stop_tag="[stop]"; [ "$DRY_RUN" -eq 1 ] && stop_tag="[stop — dry-run, no changes]"
  {
    echo "run-epic $stop_tag — epic #$EPIC: ${EPIC_TITLE:-（ei otsikkoa）}"
    echo "  repo:          $REPO_ROOT${OWNER_REPO:+ ($OWNER_REPO)}"
    echo "  run labels:    $LABELS_CSV"
    if [ "$epic_has_any" -eq 1 ]; then
      if [ "$DRY_RUN" -eq 1 ]; then
        echo "  epic labels:   present — would be removed (first, before children)"
      else
        echo "  epic labels:   present — will be removed (first, before children)"
      fi
    else
      echo "  epic labels:   none of the run labels present on the epic"
    fi
    echo "  sub-issues:    $TOTAL total ($OPEN_COUNT open, $CLOSED closed)"
    echo
    echo "  actions per sub-issue:"
    for i in $(seq 0 $((TOTAL - 1))); do
      sfx=""; [ "${HAS_LABEL_I[$i]}" -eq 1 ] && sfx=" · release from pickup"
      ref="$(_child_ref "$i")"
      case "${CLASS[$i]}" in
        closed)    echo "    ${ref} ${TITLES[$i]} — closed, skipped" ;;
        wip)       echo "    ${ref} ${TITLES[$i]} — wip (human opt-out), left untouched" ;;
        stoppable) echo "    ${ref} ${TITLES[$i]} — live run on '$THIS_HOST' → stop$sfx" ;;
        foreign)   echo "    ${ref} ${TITLES[$i]} — run on '${RUN_HOST_I[$i]}' NOT stopped (foreign host)$sfx" ;;
        terminal)  echo "    ${ref} ${TITLES[$i]} — run status '${RUN_STATUS_I[$i]}' (terminal) NOT stopped (stop does not --force)$sfx" ;;
        ambiguous) echo "    ${ref} ${TITLES[$i]} — multiple runs match; narrow with stop-run --run-dir$sfx" ;;
        norun)     [ -n "$sfx" ] && echo "    ${ref} ${TITLES[$i]} — no live run$sfx" \
                                 || echo "    ${ref} ${TITLES[$i]} — no live run, nothing to do" ;;
      esac
    done
    if [ -s "$CHILD_WARN_FILE" ]; then
      echo
      echo "  warnings:"
      sed 's/^/    /' "$CHILD_WARN_FILE"
    fi
  } >&1

  # --dry-run: write nothing (AC4).
  if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "run-epic: dry-run complete — nothing was written."
    exit 0
  fi

  # ---------- apply ----------
  echo
  echo "run-epic: stopping…"
  PARTIAL=0

  # 1. Remove the run labels from the EPIC FIRST (AC1 ordering: epic before any
  #    child, so a poller tick cannot re-propagate the labels mid-cancel).
  for _lbl in $(printf '%s' "$LABELS_CSV" | tr ',' ' '); do
    [ -n "$_lbl" ] || continue
    if _epic_csv_has "$EPIC_LABELS_CSV" "$_lbl"; then
      ( cd "$REPO_ROOT" && labels_remove "$OWNER_REPO" "$EPIC" "$_lbl" ) 2>&1 | sed 's/^/  /'
      [ "${PIPESTATUS[0]}" -eq 0 ] || PARTIAL=1
    fi
  done
  [ "$epic_has_any" -eq 1 ] && echo "  removed run labels from epic #$EPIC"

  # 2. Per OPEN, non-wip child: stop a live run (DELEGATE to stop-run.sh, AC3),
  #    then remove the run labels the child carries. Closed/wip children skipped.
  for i in $(seq 0 $((TOTAL - 1))); do
    case "${CLASS[$i]}" in closed|wip) continue ;; esac
    num="${NUMS[$i]}"
    case "${CLASS[$i]}" in
      stoppable)
        if [ -n "$REMOTE" ] && [ "$REMOTE" != "origin" ]; then
          "$STOP_RUN" --repo "$REPO_ROOT" --issue "$num" --remote "$REMOTE" --yes 2>&1 | sed 's/^/  /'
        else
          "$STOP_RUN" --repo "$REPO_ROOT" --issue "$num" --yes 2>&1 | sed 's/^/  /'
        fi
        rc=${PIPESTATUS[0]}
        if [ "$rc" -eq 0 ]; then
          echo "  #$num: run stopped (delegated to stop-run.sh)"
        else
          PARTIAL=1
          echo "  #$num: stop-run.sh exited $rc — run NOT stopped"
        fi ;;
      foreign|terminal|ambiguous)
        # A live/terminal/ambiguous run we deliberately did not stop (foreign
        # host, terminal without --force, or ambiguous). Reported above; the
        # release still happens below, but the overall stop is partial.
        PARTIAL=1 ;;
    esac
    # release the child from pickup: remove the run labels it actually carries,
    # IN ITS OWN repo (issue #92 — a cross-repo child's labels live in its home
    # repo, not the epic's).
    for _lbl in $(printf '%s' "$LABELS_CSV" | tr ',' ' '); do
      [ -n "$_lbl" ] || continue
      if _epic_csv_has "${LABELS[$i]}" "$_lbl"; then
        ( cd "$REPO_ROOT" && labels_remove "${REPOS[$i]}" "$num" "$_lbl" ) 2>&1 | sed 's/^/  /'
        [ "${PIPESTATUS[0]}" -eq 0 ] || PARTIAL=1
      fi
    done
  done

  echo
  if [ "$PARTIAL" -eq 1 ]; then
    echo "run-epic: stop INCOMPLETE — the epic was released but ≥1 live child run"
    echo "was left running or un-handled (see the report above). Exit 6."
    exit 6
  fi
  echo "run-epic: stop complete — epic #$EPIC released from pickup and every live"
  echo "child run stopped. Worktrees/branches/run-dirs are left intact (cleanup-run.sh"
  echo "or the auto-clean label tears them down)."
  exit 0
fi

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
  # Read the child's blocked_by graph in ITS OWN repo (issue #92): a cross-repo
  # child does not exist in the epic's repo, so reading it there would 404 and
  # fail-close the whole epic.
  bl_out="$(list_blocked_by "$REPO_ROOT" "${NUMS[$i]}" "${REPOS[$i]}")"
  if [ "$?" -ne 0 ]; then
    echo "run-epic: could not read the blocked_by graph of sub-issue $(_child_ref "$i") — refusing (fail-closed)" >&2
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
# Distinct child repos in first-seen order — the report groups by repo (AC "raportoi
# lapset repoittain"). A single-repo epic yields one group (unchanged shape).
REPO_ORDER=""
IS_CROSS_REPO=0
for i in $(seq 0 $((TOTAL - 1))); do
  case $'\n'"$REPO_ORDER" in *$'\n'"${REPOS[$i]}"$'\n'*) : ;; *) REPO_ORDER="${REPO_ORDER}${REPOS[$i]}"$'\n' ;; esac
  [ -n "${REPOS[$i]}" ] && [ -n "$EPIC_REPO" ] && [ "${REPOS[$i]}" != "$EPIC_REPO" ] && IS_CROSS_REPO=1
done

# ---------- watchlist coverage (issue #92) ----------
# A cross-repo child gets its run labels, but only a machine whose poller watches
# that repo will actually RUN it — the most common silent failure of a cross-repo
# epic. Resolve the set of owner/repos this machine's watchlist covers so the
# report can NAME the children no local poller will run (AC2). Best-effort: an
# unreadable watchlist skips the check rather than warning falsely. Only done for a
# cross-repo epic — a single-repo epic runs where the operator already is, so the
# coverage note would be pure noise.
WATCHLIST_REPOS=""       # newline-delimited set of covered owner/repo
WATCHLIST_READABLE=0
if [ "$IS_CROSS_REPO" -eq 1 ]; then
  # shellcheck source=lib/poller-config.sh
  . "$SCRIPT_DIR/lib/poller-config.sh" 2>/dev/null || true
  # git-remote.sh may already be sourced (non-origin remote); sourcing is idempotent.
  # shellcheck source=lib/git-remote.sh
  . "$SCRIPT_DIR/lib/git-remote.sh" 2>/dev/null || true
  if declare -F poller_resolve_watchlist >/dev/null 2>&1; then
    _wl_path="$(poller_resolve_watchlist "${RUN_ISSUES_WATCHLIST:-}" \
      "${HOME}/.config/run-issues/watchlist.json" \
      "${HOME}/dotfiles/machine-studio/run-issues-watchlist.json" 2>/dev/null || true)"
    if [ -n "$_wl_path" ] && jq -e . "$_wl_path" >/dev/null 2>&1; then
      WATCHLIST_READABLE=1
      while IFS=$'\t' read -r _wpath _wremote; do
        [ -n "$_wpath" ] || continue
        _wor="$(resolve_remote_to_owner_repo "$_wpath" "${_wremote:-origin}" 2>/dev/null || true)"
        [ -n "$_wor" ] && WATCHLIST_REPOS="${WATCHLIST_REPOS}${_wor}"$'\n'
      done < <(jq -r '.repos[]? | .path as $p | ((.remotes // ["origin"])[]) | [$p, .] | @tsv' "$_wl_path" 2>/dev/null)
    fi
  fi
fi
# _repo_watched <owner/repo> — 0 if the repo is in this machine's watchlist set.
_repo_watched() {
  [ -n "$1" ] || return 1
  case $'\n'"$WATCHLIST_REPOS" in *$'\n'"$1"$'\n'*) return 0 ;; *) return 1 ;; esac
}

# Children whose repo no local poller watches (AC2). Only meaningful for a
# cross-repo epic with a readable watchlist; else no false warning.
UNWATCHED_REFS=""
if [ "$IS_CROSS_REPO" -eq 1 ] && [ "$WATCHLIST_READABLE" -eq 1 ]; then
  for i in $(seq 0 $((TOTAL - 1))); do
    [ "${STATES[$i]}" = "open" ] || continue
    _repo_watched "${REPOS[$i]}" || UNWATCHED_REFS="${UNWATCHED_REFS:+$UNWATCHED_REFS, }$(_child_ref "$i")"
  done
fi

# First runnable = first OPEN child (list order) with zero OPEN blockers of any
# kind — that is exactly S2b's pickup condition.
FIRST_RUNNABLE=""
FIRST_RUNNABLE_I=""
for i in $(seq 0 $((TOTAL - 1))); do
  [ "${STATES[$i]}" = "open" ] || continue
  if [ -z "${OPEN_BLOCKERS[$i]}" ]; then FIRST_RUNNABLE="${NUMS[$i]}"; FIRST_RUNNABLE_I="$i"; break; fi
done

# What propagation WOULD do per open child (also drives the report). Refs are
# repo-qualified for a cross-repo child (issue #92).
would_label=""   # list of open children missing the labels
already=""       # already fully labelled
skipped_wip=""
for i in $(seq 0 $((TOTAL - 1))); do
  [ "${STATES[$i]}" = "open" ] || continue
  if _epic_csv_has "${LABELS[$i]}" "wip"; then
    skipped_wip="${skipped_wip:+$skipped_wip, }$(_child_ref "$i")"
    continue
  fi
  if [ -n "$(_epic_missing_labels "${LABELS[$i]}" "$LABELS_CSV")" ]; then
    would_label="${would_label:+$would_label, }$(_child_ref "$i")"
  else
    already="${already:+$already, }$(_child_ref "$i")"
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
  if [ -n "$FIRST_RUNNABLE_I" ]; then
    echo "  first to run:  $(_child_ref "$FIRST_RUNNABLE_I")"
  else
    echo "  first to run:  none (all open children are blocked or none open)"
  fi
  echo
  echo "  propagation:"
  echo "    label:       ${would_label:-none (all open children already carry the labels)}"
  echo "    already set:  ${already:-none}"
  [ -n "$skipped_wip" ] && echo "    skipped wip: $skipped_wip"
  echo
  # Run order, grouped by repo (issue #92: a cross-repo epic lists its children
  # under each repo). A single-repo epic prints one group.
  echo "  run order (by repo):"
  while IFS= read -r _grepo; do
    [ -n "$_grepo" ] || continue
    echo "    $_grepo:"
    for i in $(seq 0 $((TOTAL - 1))); do
      [ "${REPOS[$i]}" = "$_grepo" ] || continue
      case "${STATES[$i]}" in
        closed) echo "      #${NUMS[$i]} ${TITLES[$i]} — closed" ;;
        open)
          if [ -z "${OPEN_BLOCKERS[$i]}" ]; then
            echo "      #${NUMS[$i]} ${TITLES[$i]} — runnable now"
          else
            echo "      #${NUMS[$i]} ${TITLES[$i]} — blocked by #$(printf '%s' "${OPEN_BLOCKERS[$i]}" | sed 's/,/, #/g')"
          fi ;;
      esac
    done
  done <<EOF
$REPO_ORDER
EOF
  # Watchlist coverage warning (AC2, cross-repo only): children whose repo no
  # local poller runs. A single-repo epic runs where the operator already is, so
  # the coverage note is skipped there.
  if [ -n "$UNWATCHED_REFS" ]; then
    echo
    echo "  warnings:"
    echo "    NOT RUN HERE — no poller on this machine watches the repo of: $UNWATCHED_REFS"
    echo "    (they will be labelled, but a machine whose watchlist covers that repo must run them.)"
  elif [ "$IS_CROSS_REPO" -eq 1 ] && [ "$WATCHLIST_READABLE" -ne 1 ]; then
    echo
    echo "  warnings:"
    echo "    watchlist not readable — cannot verify which of these cross-repo children this machine runs."
  fi
  if [ -s "$CHILD_WARN_FILE" ]; then
    echo
    echo "  resolver warnings:"
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
