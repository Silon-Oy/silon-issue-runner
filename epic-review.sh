#!/usr/bin/env bash
# epic-review.sh — review an epic against its acceptance criteria (issue #274).
#
# Usage:
#   epic-review.sh <epic-N> [--repo <path>] [--remote <name>] [--dry-run]
#
# The operator surface of the epic review: it joins the material collection
# (epic_review_collect, issue #272) and the review agent (epic_review_run,
# issue #273) and records the verdict on the epic ONCE. `epic-complete` only
# says every child is closed; this answers whether the children's changes
# TOGETHER meet what the epic asked for.
#
# Plan-then-apply (like run-epic.sh): the epic is proven to exist, be open,
# carry the `epic` label and have sub-issues before anything else happens; the
# material is collected and the agent run before the first write. Any refusal
# or failure ⇒ zero writes.
#
# Recording uses the EXISTING vocabulary, through the same primitive as the
# poller's stalled-child escalation (_epic_post_attention in lib/epic.sh):
#   findings     → one comment (marker + findings per criterion) + epic-attention
#   criteria_met → one comment (marker + "criteria met"), NO label — a clean
#                  result is reported, not held
# Once-only is read from GitHub, not from a state file (CLAUDE.md §5.7): when the
# epic already carries the `<!-- run-issues:epic-review -->` marker in a comment,
# the agent is NOT called and nothing is written (one line, exit 0). One marker
# per epic, whatever the earlier verdict — a fresh review needs that comment
# deleted first.
#
# A launch failure is never a verdict (CLAUDE.md §9): no comment, no label, so
# the next run tries again. --dry-run runs the agent (the report needs the
# verdict) and prints the same report, but writes nothing to GitHub.
#
# Scope: never closes the epic, never touches the children, no merge, no git
# writes. Not called from the poller — a human-started opt-in surface.
#
# Exit codes (own space — not run-epic's, not the orchestrator's):
#   0  criteria met (recorded, or --dry-run), or the review is already recorded
#      on the epic (marker present — silent no-op, no agent call)
#   1  usage error (bad flag / missing or non-numeric epic number / not a git repo
#      / un-parseable --remote)
#   2  epic not found, not open, or missing the `epic` label — nothing written
#   3  epic has no sub-issues — nothing to review, nothing written
#   4  read failure — the child set or the review material was unreadable
#      (fail-closed: partial material must not be reviewed)
#   5  no verdict — the review agent failed to launch, timed out or produced no
#      parseable result. Nothing written, so the next run retries
#   6  findings — recorded (comment + epic-attention), or would be (--dry-run)
#   7  findings or criteria met, but a GitHub write failed (label and/or comment).
#      The report names which; if the comment landed, the marker silences reruns
#
# Run: epic-review.sh 101 --repo /path/to/repo
#      epic-review.sh 101 --dry-run

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Snapshot the caller's environment before any library assigns defaults
# (lib/machine-env.sh, CLAUDE.md §5.5).
# shellcheck source=lib/machine-env.sh
. "$SCRIPT_DIR/lib/machine-env.sh"
machine_env_capture
# Windows/Git Bash: LF jq output (lib/jq-binary.sh).
# shellcheck source=lib/jq-binary.sh
. "$SCRIPT_DIR/lib/jq-binary.sh"
# shellcheck source=lib/git-repo.sh
. "$SCRIPT_DIR/lib/git-repo.sh"

REVIEW_MARKER="<!-- run-issues:epic-review -->"

usage() {
  sed -n '3,5p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

# ---------- argument parsing ----------
EPIC=""
REPO_ROOT=""
REMOTE=""
DRY_RUN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)    REPO_ROOT="${2:-}"; shift 2 || usage 1 ;;
    --remote)  REMOTE="${2:-}"; shift 2 || usage 1 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    --*)       echo "epic-review: unknown flag '$1'" >&2; usage 1 ;;
    *)
      if [ -n "$EPIC" ]; then
        echo "epic-review: unexpected argument '$1' (epic number already given as '$EPIC')" >&2
        usage 1
      fi
      EPIC="$1"; shift ;;
  esac
done

EPIC="${EPIC#\#}"
case "$EPIC" in
  ''|*[!0-9]*) echo "epic-review: epic issue number is required (e.g. epic-review.sh 101)" >&2; usage 1 ;;
esac

[ -n "$REPO_ROOT" ] || REPO_ROOT="$(pwd)"
if ! is_git_repo_root "$REPO_ROOT"; then
  echo "epic-review: '$REPO_ROOT' is not a git repository (pass --repo <path>)" >&2
  exit 1
fi
REPO_ROOT="${REPO_ROOT%/}"

# origin mode leaves OWNER_REPO empty so the helpers infer the repo from the
# working copy; a non-origin remote must target its own org explicitly.
OWNER_REPO=""
REMOTE_EFF="${REMOTE:-origin}"
if [ -n "$REMOTE" ] && [ "$REMOTE" != "origin" ]; then
  # shellcheck source=lib/git-remote.sh
  . "$SCRIPT_DIR/lib/git-remote.sh"
  if ! OWNER_REPO=$(resolve_remote_to_owner_repo "$REPO_ROOT" "$REMOTE" 2>/dev/null); then
    echo "epic-review: remote '$REMOTE' missing or its URL is un-parseable in $REPO_ROOT" >&2
    exit 1
  fi
fi

# The machine env file carries the agent CLI settings (caller wins in
# RUN_ISSUES_*). Sourced after arg parsing so --help needs nothing.
source_machine_env 2>/dev/null
# epic-review.sh brings epic.sh (fetch_issue_json, list_epic_children,
# _epic_post_attention, the marker readers), labels.sh and claude-call.sh.
# shellcheck source=lib/epic-review.sh
. "$SCRIPT_DIR/lib/epic-review.sh"
# The libraries source with `set -e`; this script handles every failure as an
# explicit exit code instead.
set +e

WORK_DIR="$(mktemp -d -t epic-review.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT
EPIC_JSON="$WORK_DIR/epic.json"

# ======================================================================
# VALIDATION (plan phase) — reads only, writes nothing.
# ======================================================================

# --- 1. the epic exists, is open and carries the `epic` label ---
if ! fetch_issue_json "$REPO_ROOT" "$EPIC" "$OWNER_REPO" "$REMOTE_EFF" > "$EPIC_JSON" 2>/dev/null \
   || [ ! -s "$EPIC_JSON" ]; then
  echo "epic-review: epic issue #$EPIC not found or not accessible in $REPO_ROOT" >&2
  exit 2
fi
EPIC_STATE="$(jq -r '.state // "" | ascii_upcase' "$EPIC_JSON" 2>/dev/null || echo "")"
if [ "$EPIC_STATE" != "OPEN" ]; then
  echo "epic-review: epic issue #$EPIC is not open (state=${EPIC_STATE:-unknown}) — nothing to review" >&2
  exit 2
fi
if ! _epic_labels_have "$EPIC_JSON" "epic"; then
  echo "epic-review: issue #$EPIC does not carry the 'epic' label — not an epic, refusing" >&2
  exit 2
fi
EPIC_TITLE="$(jq -r '.title // ""' "$EPIC_JSON" 2>/dev/null || echo "")"

# --- 2. already reviewed? (once-only, read from GitHub) ---
# Checked before the child set and the agent: a recorded review costs nothing.
if _epic_issue_has_comment_marker "$EPIC_JSON" "$REVIEW_MARKER"; then
  echo "epic-review: epic #$EPIC — review already recorded on the epic (marker present); nothing to do."
  echo "epic-review: delete that comment to review the epic again."
  exit 0
fi

# --- 3. the epic has sub-issues ---
CHILDREN_FILE="$WORK_DIR/children.tsv"
if ! list_epic_children "$REPO_ROOT" "$EPIC" "$OWNER_REPO" > "$CHILDREN_FILE" 2>/dev/null; then
  echo "epic-review: could not read the sub-issues of epic #$EPIC (unreadable graph) — refusing (fail-closed)" >&2
  exit 4
fi
if [ ! -s "$CHILDREN_FILE" ]; then
  echo "epic-review: epic #$EPIC has no sub-issues — nothing to review" >&2
  exit 3
fi
CHILD_COUNT="$(grep -c . "$CHILDREN_FILE" | tr -d ' ')"

# --- 4. the epic's owner/repo (the agent's epic reference and PR file reads) ---
EPIC_REPO="$OWNER_REPO"
if [ -z "$EPIC_REPO" ]; then
  EPIC_REPO="$(cd "$REPO_ROOT" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo "")"
fi
if [ -z "$EPIC_REPO" ]; then
  echo "epic-review: could not resolve owner/repo for $REPO_ROOT — refusing (fail-closed)" >&2
  exit 4
fi

# --- 5. the material (all or nothing) ---
if ! MATERIAL="$(epic_review_collect "$REPO_ROOT" "$EPIC" "$EPIC_REPO" 2>/dev/null)" \
   || [ -z "$MATERIAL" ]; then
  echo "epic-review: could not collect the review material for epic #$EPIC (a GitHub read failed) — refusing (fail-closed)" >&2
  exit 4
fi

# --- 6. the review ---
AGENT_DIR="$WORK_DIR/agent"; mkdir -p "$AGENT_DIR"
RESULT="$(epic_review_run "$AGENT_DIR" "$EPIC_REPO#$EPIC" "$MATERIAL")" || RESULT=""
FINDINGS=""
if [ "$RESULT" = "findings" ]; then
  FINDINGS="$(epic_review_findings "$AGENT_DIR/$EPIC_REVIEW_STEP.out" 2>/dev/null)"
fi

# ---------- report (identical for --dry-run and a real run) ----------
echo "epic-review — epic #$EPIC: ${EPIC_TITLE:-(ei otsikkoa)}"
echo "  repo:          $REPO_ROOT ($EPIC_REPO)"
echo "  sub-issues:    $CHILD_COUNT"
case "$RESULT" in
  criteria_met) echo "  result:        criteria met" ;;
  findings)
    echo "  result:        findings ($(printf '%s\n' "$FINDINGS" | grep -c .))"
    echo
    echo "  findings:"
    while IFS='|' read -r crit desc; do
      [ -n "$crit" ] || continue
      echo "    - $crit — $desc"
    done <<EOF
$FINDINGS
EOF
    ;;
  *) echo "  result:        no verdict (the review agent failed to launch, timed out or gave no parseable result)" ;;
esac

case "$RESULT" in
  criteria_met|findings) : ;;
  *)
    echo
    echo "epic-review: no verdict — nothing was written; run again to retry."
    exit 5 ;;
esac

if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "epic-review: dry-run complete — nothing was written."
  [ "$RESULT" = "findings" ] && exit 6
  exit 0
fi

# ======================================================================
# APPLY — one comment (+ epic-attention for findings).
# ======================================================================
BODY_FILE="$WORK_DIR/comment.md"
{
  echo "$REVIEW_MARKER"
  if [ "$RESULT" = "findings" ]; then
    echo "## /run-issues — Epicin katselmus: löydöksiä"
    echo
    echo "Katselmus vertasi alaissueiden yhteisiä muutoksia epicin hyväksyntäkriteereihin ja löysi kohtia, jotka eivät täyty. Runner **ei sulje epiciä** eikä korjaa löydöksiä — päätös jää ihmiselle."
    echo
    echo "**Löydökset kriteereittäin:**"
    echo
    while IFS='|' read -r crit desc; do
      [ -n "$crit" ] || continue
      echo "- **${crit}** — ${desc}"
    done <<EOF
$FINDINGS
EOF
    echo
    echo "Kun löydökset on käsitelty, poista \`epic-attention\`-label."
  else
    echo "## /run-issues — Epicin katselmus: kriteerit täyttyvät"
    echo
    echo "Katselmus ei löytänyt hyväksyntäkriteeriä, jota alaissueiden muutokset eivät yhdessä täyttäisi. Runner **ei sulje epiciä** — sulkupäätös jää ihmiselle."
  fi
  echo
  echo "_Katselmus kirjataan epicille kerran. Uusi katselmus vaatii tämän kommentin poistamisen._"
} > "$BODY_FILE"

WITH_LABEL=0; [ "$RESULT" = "findings" ] && WITH_LABEL=1
echo
if _epic_post_attention "$REPO_ROOT" "$EPIC" "$OWNER_REPO" "$REMOTE_EFF" "$BODY_FILE" "$WITH_LABEL"; then
  if [ "$RESULT" = "findings" ]; then
    echo "epic-review: recorded on epic #$EPIC — comment + epic-attention."
    exit 6
  fi
  echo "epic-review: recorded on epic #$EPIC — comment (no label: criteria met)."
  exit 0
fi
echo "epic-review: a GitHub write failed on epic #$EPIC — check the epic: the comment and/or the epic-attention label may be missing." >&2
echo "epic-review: if the comment is missing, run again; if only the label is missing, add epic-attention by hand." >&2
exit 7
