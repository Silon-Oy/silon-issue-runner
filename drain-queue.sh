#!/usr/bin/env bash
# drain-queue.sh — run the pickup queue empty, then exit.
#
# This is the window model, the sibling of poller.sh. The poller ticks every
# 300 s forever, which is right for a machine that is always on. It is wrong
# for a host that bills by wall-clock and sleeps when idle (a Fly.io Sprite
# sleeps ~30 s after the last external session closes), because a 5-minute
# tick would keep it awake around the clock and bill for a machine that is
# mostly doing nothing.
#
# So: wake, take issues until there are none left, exit. See
# docs/sprite-runner.md for the host setup this was written for.
#
# One pickup search
# -----------------
# orchestrate.sh does not poll: it requires a concrete issue number, `poll` is
# a usage error, and exit code 2 ("no candidate") is decommissioned. There is
# exactly ONE pickup search in the package — pick_oldest_candidate in
# lib/issue.sh — and both the poller and this script call it. Re-implementing
# the search here would be a second query that can drift from the real one.
#
# Reservation is the `auto-claimed` label, not assignment. A failed run keeps
# the label, so the next pick skips that issue — which is what stops this loop
# from retrying the same failure forever.
#
# Usage:
#   drain-queue.sh [<repo-root> …]
#
# With no arguments, every repo in the watchlist is drained in listed order.
# Named repos need not be in the watchlist; they fall back to the built-in
# pickup label like any uncovered repo.
#
# Env:
#   RUN_ISSUES_WATCHLIST   explicit watchlist path (else the standard lookup)
#   RUN_ISSUES_LABELS_CSV  override the pickup labels for EVERY repo in this
#                          run. Normally unset: labels come per-repo from the
#                          watchlist, exactly as the poller resolves them.
#   DRAIN_BUDGET_SECONDS   wall-clock cap (default 3600). A cost brake, not a
#                          correctness requirement: an in-flight run is never
#                          interrupted, the budget only stops us starting another.
#   DRAIN_MAX_RUNS         hard cap on runs started (default 20). Backstop against
#                          a pick loop that never converges.
#   RUNNER_DIR             package root (default: ~/.claude/scripts/run-issues)
#   DRAIN_DRY_RUN=1        print what would run, start nothing.

set -uo pipefail   # NOT -e: a failing run is data, not a reason to abort the drain

RUNNER_DIR="${RUNNER_DIR:-$HOME/.claude/scripts/run-issues}"
ORCHESTRATE="$RUNNER_DIR/orchestrate.sh"
ISSUE_LIB="$RUNNER_DIR/lib/issue.sh"
CONFIG_LIB="$RUNNER_DIR/lib/poller-config.sh"
JQ_LIB="$RUNNER_DIR/lib/jq-binary.sh"
BUDGET="${DRAIN_BUDGET_SECONDS:-3600}"
MAX_RUNS="${DRAIN_MAX_RUNS:-20}"
DRY_RUN="${DRAIN_DRY_RUN:-0}"

log() { printf '[drain %s] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
die() { printf 'drain: %s\n' "$*" >&2; exit 1; }

[ -x "$ORCHESTRATE" ] || die "orchestrate.sh not executable at $ORCHESTRATE"
[ -r "$ISSUE_LIB" ]   || die "lib/issue.sh not readable at $ISSUE_LIB"
[ -r "$CONFIG_LIB" ]  || die "lib/poller-config.sh not readable at $CONFIG_LIB"
[ -r "$JQ_LIB" ]      || die "lib/jq-binary.sh not readable at $JQ_LIB"

# Sourced before the others: they all read jq output, and on Windows jq emits
# CRLF unless it is invoked through this shim.
# shellcheck source=lib/jq-binary.sh
source "$JQ_LIB" || die "could not source $JQ_LIB"
# shellcheck source=lib/issue.sh
source "$ISSUE_LIB" || die "could not source $ISSUE_LIB"
# shellcheck source=lib/poller-config.sh
source "$CONFIG_LIB" || die "could not source $CONFIG_LIB"
# Both libs set `-euo pipefail` for their production callers, which silently
# overrides the `set -uo pipefail` above. Restore it: under `-e` the first run
# that exits non-zero aborts the whole drain before `rc=$?` is even read, and a
# repo missing from the watchlist (poller_watchlist_pick_labels returns 1) kills
# the window with no message at all. A failing run is data here, not a reason to
# stop taking issues.
set +e

command -v pick_oldest_candidate >/dev/null 2>&1 \
  || die "pick_oldest_candidate not found after sourcing $ISSUE_LIB — package layout changed?"
command -v poller_watchlist_pick_labels >/dev/null 2>&1 \
  || die "poller_watchlist_pick_labels not found after sourcing $CONFIG_LIB — package layout changed?"
command -v poller_watchlist_pick_assignees >/dev/null 2>&1 \
  || die "poller_watchlist_pick_assignees not found after sourcing $CONFIG_LIB — package layout changed?"

WATCHLIST=$(poller_resolve_watchlist \
  "${RUN_ISSUES_WATCHLIST:-}" \
  "$HOME/.config/run-issues/watchlist.json" \
  "$HOME/dotfiles/machine-studio/run-issues-watchlist.json") || WATCHLIST=""

# Repos: the arguments, or every watchlist entry when there are none. Draining
# the watchlist is the common case — a wake-up window wants "whatever this host
# is responsible for", and repeating that list in the caller is one more place
# for it to drift.
declare -a REPOS=()
if [ $# -ge 1 ]; then
  REPOS=("$@")
elif [ -n "$WATCHLIST" ] && command -v jq >/dev/null 2>&1; then
  while IFS= read -r p; do [ -n "$p" ] && REPOS+=("$p"); done \
    < <(jq -r '.repos[]?.path // empty' "$WATCHLIST")
fi
[ ${#REPOS[@]} -ge 1 ] || die "no repos: pass one or more repo roots, or list them in the watchlist"

# The orchestrator's own auto-mode flags. Without these it stops at the review
# gate (exit 10) and waits for a human who, by definition, is not here.
export RUN_ISSUES_AUTO=1
export RUN_ISSUES_REVIEW_GATE=auto

started=0
declare -a summary=()

for repo in "${REPOS[@]}"; do
  [ -d "$repo" ] || { log "skip: not a directory: $repo"; continue; }

  # Labels come from the watchlist through the SAME function the poller uses,
  # so the two models cannot disagree about what this host picks up. The env
  # override is for one-off runs, not the normal path.
  if [ -n "${RUN_ISSUES_LABELS_CSV:-}" ]; then
    LABELS="$RUN_ISSUES_LABELS_CSV"
  else
    LABELS=$(poller_watchlist_pick_labels "$WATCHLIST" "$repo")
  fi

  # Defensive, and not a formality. pick_oldest_candidate takes the label CSV
  # as an argument and, when it is empty, adds NO label terms — i.e. no filter
  # at all, not "no matches". A drain with an empty filter takes the oldest
  # open issue in the repo whether or not anyone marked it for automation;
  # observed in practice picking up a three-week-old chore. poller_pick_labels
  # always returns at least the built-in default, so an empty value here means
  # something is broken rather than unconfigured.
  [ -n "$LABELS" ] || die "resolved an empty pickup label set for $repo — refusing to run"

  # The optional per-repo assignee allow-list, through the SAME resolver the
  # poller uses. Empty is the normal case and means no assignee filtering —
  # unlike the label set above, an empty value here needs no defence, because
  # it widens rather than narrows.
  ASSIGNEES=$(poller_watchlist_pick_assignees "$WATCHLIST" "$repo")

  log "draining $repo (labels: $LABELS${ASSIGNEES:+, assignees: $ASSIGNEES})"

  # Exit 9 (blocked by an open dependency) is the one code that can repeat
  # forever: it refuses BEFORE the claim, so the issue never gets the
  # auto-claimed label and the next pick can hand us the same one. Every other
  # failure leaves the reservation in place, which pickup then skips.
  consecutive_blocked=0

  while :; do
    if [ "$SECONDS" -ge "$BUDGET" ]; then
      log "budget ${BUDGET}s reached — not starting another run"
      break
    fi
    if [ "$started" -ge "$MAX_RUNS" ]; then
      log "run cap $MAX_RUNS reached — stopping"
      break
    fi

    # The single pickup search, shared with the poller. Empty = queue empty:
    # this replaces the decommissioned exit code 2.
    issue=$(pick_oldest_candidate "$repo" "$LABELS" "" "" "$ASSIGNEES" || true)
    if [ -z "$issue" ]; then
      log "queue empty"
      break
    fi

    if [ "$DRY_RUN" = 1 ]; then
      log "DRY RUN: would exec $ORCHESTRATE $repo $issue"
      break
    fi

    started=$((started + 1))
    log "run #$started: issue #$issue ($repo)"
    "$ORCHESTRATE" "$repo" "$issue"
    rc=$?

    case "$rc" in
      0)
        log "run #$started: issue #$issue — PR opened"
        summary+=("$repo #$issue: ok")
        consecutive_blocked=0
        ;;
      3)
        # Another machine won the claim. It holds the reservation now, so the
        # next pick skips the issue; keep going.
        log "run #$started: issue #$issue — claim race lost, continuing"
        consecutive_blocked=0
        ;;
      9)
        consecutive_blocked=$((consecutive_blocked + 1))
        log "run #$started: issue #$issue blocked by dependency (#$consecutive_blocked in a row)"
        if [ "$consecutive_blocked" -ge 3 ]; then
          log "three blocked picks in a row — search index is probably lagging, stopping this repo"
          break
        fi
        ;;
      1|8)
        # Usage error or a missing dependency. Retrying cannot fix either, and
        # exit 8 means the preflight gate refused before touching anything.
        log "run #$started: fatal (rc=$rc) — stopping this repo"
        summary+=("$repo #$issue: FATAL rc=$rc")
        break
        ;;
      *)
        # 4,5,6,7,… — this issue failed but keeps its reservation, so the next
        # pick moves on. Worth continuing; worth reporting.
        log "run #$started: issue #$issue failed (rc=$rc) — continuing"
        summary+=("$repo #$issue: rc=$rc")
        consecutive_blocked=0
        ;;
    esac
  done
done

log "done — $started run(s) started in ${SECONDS}s"
for line in "${summary[@]:-}"; do [ -n "$line" ] && log "  $line"; done

# Exit 0 whenever the drain itself completed. Individual run failures are
# reported above and on the issues themselves (needs-human, situation comments);
# collapsing them into our exit code would make a wake-up look broken when it
# actually did its job.
exit 0
