#!/usr/bin/env bash
# lib/pr-watch-lib.sh — PR classification + merge-decision logic.
#
# Split out from pr-watch.sh so the decision rules can be unit-tested with a
# mocked `gh pr view` JSON payload, with no GitHub access and no side effects.
#
# This file is sourced; it defines functions only and does no top-level work.

# pr_decide <pr-view-json> [enable_conflict_resolution] [merge_label]
#
# Reads a `gh pr view --json state,mergeable,mergeStateStatus,labels,statusCheckRollup`
# payload on stdin (as the single argument) and prints exactly one decision
# token on stdout:
#
#   MERGE          — all three gates pass: merge label present AND CI green
#                    AND mergeable == "MERGEABLE" / mergeStateStatus CLEAN.
#   SKIP_NO_LABEL  — the merge label is absent (nothing to do).
#   SKIP_CLOSED    — PR is not OPEN (merged/closed).
#   WAIT_CI        — label present but checks are pending/failing.
#   WAIT_DIRTY     — label present, mergeStateStatus DIRTY/BEHIND, but conflict
#                    resolution is OFF (no rebase performed).
#   REBASE         — label present, mergeStateStatus BEHIND/DIRTY, and conflict
#                    resolution is ON (caller should attempt a rebase).
#   SKIP_BLOCKED   — mergeStateStatus BLOCKED (e.g. required review missing);
#                    not actionable by the watcher.
#
# INVARIANT (enforced here, asserted by the unit test): the function NEVER
# returns MERGE unless label AND CI-green AND mergeable are all true together.
#
# Arguments:
#   $1  the gh-pr-view JSON document (string)
#   $2  enable_conflict_resolution: "1" to allow REBASE, anything else = off
#   $3  merge label name (default "auto-merge")
pr_decide() {
  local json="$1"
  local enable_res="${2:-0}"
  local merge_label="${3:-auto-merge}"

  local state mergeable merge_state has_label ci
  state=$(jq -r '.state // empty' <<<"$json")
  mergeable=$(jq -r '.mergeable // empty' <<<"$json")
  merge_state=$(jq -r '.mergeStateStatus // empty' <<<"$json")

  # PR must be open to be actionable.
  if [ "$state" != "OPEN" ]; then
    echo "SKIP_CLOSED"
    return 0
  fi

  has_label=$(jq -r --arg L "$merge_label" \
    '[.labels[]?.name] | index($L) | if . == null then "0" else "1" end' <<<"$json")
  if [ "$has_label" != "1" ]; then
    echo "SKIP_NO_LABEL"
    return 0
  fi

  # CI rollup: green only if there are no FAILURE/ERROR/CANCELLED/TIMED_OUT
  # conclusions AND no still-pending checks. An empty rollup (no checks
  # configured) is treated as green — there is nothing to wait for.
  ci=$(pr_ci_state "$json")
  if [ "$ci" != "GREEN" ]; then
    echo "WAIT_CI"
    return 0
  fi

  case "$merge_state" in
    CLEAN|HAS_HOOKS|UNSTABLE)
      # UNSTABLE = mergeable but some non-required check failed; CI gate above
      # already validated required checks, so this is still mergeable.
      if [ "$mergeable" = "MERGEABLE" ]; then
        echo "MERGE"
      else
        echo "WAIT_CI"
      fi
      ;;
    BEHIND|DIRTY)
      if [ "$enable_res" = "1" ]; then
        echo "REBASE"
      else
        echo "WAIT_DIRTY"
      fi
      ;;
    BLOCKED)
      echo "SKIP_BLOCKED"
      ;;
    *)
      # UNKNOWN or anything GitHub has not finished computing — wait.
      echo "WAIT_CI"
      ;;
  esac
}

# pr_ci_state <pr-view-json> — prints GREEN / RED / PENDING.
#
# statusCheckRollup entries come in two shapes:
#   CheckRun:    {status, conclusion}             (GitHub Actions / checks API)
#   StatusContext: {state}                        (legacy commit statuses)
# We normalise both. An empty rollup => GREEN (nothing to gate on).
pr_ci_state() {
  local json="$1"
  jq -r '
    (.statusCheckRollup // []) as $r
    | if ($r | length) == 0 then "GREEN"
      else
        ([ $r[]
            | if has("conclusion") then
                # CheckRun: pending while status != COMPLETED.
                if (.status // "") != "COMPLETED" then "PENDING"
                elif (.conclusion // "") as $c
                     | ($c == "SUCCESS" or $c == "NEUTRAL" or $c == "SKIPPED")
                then "OK" else "BAD" end
              else
                # StatusContext: state in SUCCESS/PENDING/FAILURE/ERROR.
                (.state // "") as $s
                | if $s == "SUCCESS" then "OK"
                  elif $s == "PENDING" then "PENDING"
                  else "BAD" end
              end
         ]) as $states
        | if ($states | index("BAD")) != null then "RED"
          elif ($states | index("PENDING")) != null then "PENDING"
          else "GREEN" end
      end
  ' <<<"$json"
}
