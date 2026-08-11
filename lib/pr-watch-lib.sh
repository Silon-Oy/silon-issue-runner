#!/usr/bin/env bash
# lib/pr-watch-lib.sh — PR classification + merge-decision logic.
#
# Split out from pr-watch.sh so the decision rules can be unit-tested with a
# mocked `gh pr view` JSON payload, with no GitHub access and no side effects.
#
# This file is sourced; it defines functions only and does no top-level work.

# pr_decide <pr-view-json> [enable_conflict_resolution] [merge_label] [enable_ci_repair]
#
# Reads a `gh pr view --json state,mergeable,mergeStateStatus,labels,statusCheckRollup`
# payload on stdin (as the single argument) and prints exactly one decision
# token on stdout:
#
#   MERGE          — all three gates pass: merge label present AND CI green
#                    AND mergeable == "MERGEABLE" / mergeStateStatus CLEAN.
#   SKIP_NO_LABEL  — the merge label is absent (nothing to do).
#   SKIP_CLOSED    — PR is not OPEN (merged/closed).
#   WAIT_CI        — label present but checks are pending (or failing while CI
#                    repair is OFF — see FIX_CI). A no-op; retry next poll.
#   FIX_CI         — label present, CI is RED (a required/blocking check failed),
#                    and CI repair is ON. The caller runs an AI agent in the
#                    feature worktree to fix the failure, revalidates CI, and
#                    only then merges. Never returned for a merge that is already
#                    allowed (see UNSTABLE below).
#   WAIT_DIRTY     — label present, mergeStateStatus DIRTY/BEHIND, but conflict
#                    resolution is OFF (no rebase performed).
#   REBASE         — label present, mergeStateStatus BEHIND/DIRTY, and conflict
#                    resolution is ON (caller should attempt a rebase).
#   SKIP_BLOCKED   — mergeStateStatus BLOCKED with GREEN CI (e.g. a required
#                    review is missing); not actionable by the watcher.
#
# ORDERING — two deliberate points the edge cases in issue #25 pin down:
#   1. DIRTY/BEHIND is decided BEFORE the CI state. A PR that is both out of date
#      and red must be rebased FIRST (the rebase re-runs CI, so the current red
#      may be moot). This precedes FIX_CI so the rebase and CI-repair paths are
#      mutually exclusive per invocation and never nest: a PR still red after a
#      rebase is re-derived as CLEAN+red on the next poll and can then FIX_CI.
#   2. UNSTABLE never enters FIX_CI. mergeStateStatus == UNSTABLE means the
#      REQUIRED checks are green and GitHub considers the PR mergeable; a red
#      rollup entry there is a NON-required check. Repairing it would be wrong,
#      so UNSTABLE keeps its prior behaviour (falls through to the merge switch,
#      which still needs ci==GREEN to actually MERGE — a non-required red there
#      yields WAIT_CI exactly as before, never a merge on red).
#
# INVARIANT (enforced here, asserted by the unit test): the function NEVER
# returns MERGE unless label AND CI-green AND mergeable are all true together.
# The FIX_CI path does not weaken this — FIX_CI is a request to repair, not a
# merge; the merge only happens after a fresh CI-green revalidation.
#
# Arguments:
#   $1  the gh-pr-view JSON document (string)
#   $2  enable_conflict_resolution: "1" to allow REBASE, anything else = off
#   $3  merge label name (default "auto-merge")
#   $4  enable_ci_repair: "1" to allow FIX_CI on RED, anything else = off
#       (off => a red CI keeps producing WAIT_CI, bit-for-bit as before).
pr_decide() {
  local json="$1"
  local enable_res="${2:-0}"
  local merge_label="${3:-auto-merge}"
  local enable_ci_repair="${4:-0}"

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

  # Out-of-date branch: rebase FIRST (ordering point 1 above), before the CI
  # state is even consulted, so REBASE and FIX_CI never contend for the same
  # invocation.
  case "$merge_state" in
    BEHIND|DIRTY)
      if [ "$enable_res" = "1" ]; then
        echo "REBASE"
      else
        echo "WAIT_DIRTY"
      fi
      return 0
      ;;
  esac

  # CI rollup: green only if there are no FAILURE/ERROR/CANCELLED/TIMED_OUT
  # conclusions AND no still-pending checks. An empty rollup (no checks
  # configured) is treated as green — there is nothing to wait for.
  ci=$(pr_ci_state "$json")

  # RED + repair ON => FIX_CI, but only when the red check actually blocks the
  # merge. UNSTABLE is excluded (ordering point 2): its red is non-required, so
  # there is nothing to repair and it must not be blocked in FIX_CI.
  if [ "$ci" = "RED" ] && [ "$merge_state" != "UNSTABLE" ]; then
    if [ "$enable_ci_repair" = "1" ]; then
      echo "FIX_CI"
    else
      echo "WAIT_CI"
    fi
    return 0
  fi

  # PENDING (or a non-required RED under UNSTABLE) => wait; nothing to do yet.
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
    BLOCKED)
      echo "SKIP_BLOCKED"
      ;;
    *)
      # UNKNOWN or anything GitHub has not finished computing — wait.
      echo "WAIT_CI"
      ;;
  esac
}

# pr_has_label <pr-view-json> <label> — rc 0 if the label is present on the PR,
# 1 otherwise. Pure + side-effect-free; reads the same `labels[].name` shape
# pr_decide gates the merge label on. Used by the watcher to treat `needs-human`
# as the CI-repair hold flag (issue #45): while it is present the watcher stays
# hands-off; removing it re-arms the run.
pr_has_label() {
  local json="$1" label="$2"
  local present
  present=$(jq -r --arg L "$label" \
    '[.labels[]?.name] | index($L) | if . == null then "0" else "1" end' <<<"$json")
  [ "$present" = "1" ]
}

# pr_failed_checks <pr-view-json> — prints one "name: conclusion" line per
# failed check in the statusCheckRollup, newline-separated (empty if none).
# Pure + side-effect-free (mirrors pr_ci_state); used to name the red checks in
# the CI-repair prompt and human-handover comment. Both rollup shapes are
# handled: CheckRun (conclusion) and legacy StatusContext (state).
pr_failed_checks() {
  local json="$1"
  jq -r '
    (.statusCheckRollup // [])
    | map(
        if has("conclusion") then
          select((.status // "") == "COMPLETED"
                 and ((.conclusion // "") as $c
                      | ($c != "SUCCESS" and $c != "NEUTRAL" and $c != "SKIPPED")))
          | "\(.name // .context // "check"): \(.conclusion)"
        else
          select((.state // "") as $s | ($s != "SUCCESS" and $s != "PENDING"))
          | "\(.context // .name // "status"): \(.state)"
        end
      )
    | .[]
  ' <<<"$json" 2>/dev/null || printf ''
}

# should_close_linked_issue <issue_state>
#
# Decides whether the PR-watcher must EXPLICITLY close the PR's linked issue
# after a successful merge. The watcher closes ALWAYS, best-effort, regardless
# of base branch: GitHub's native `Closes #N` closing keyword only fires when a
# PR merges into the DEFAULT branch AND the body carries the keyword — and an
# agent-authored PR (or a non-default base) can drop either condition, leaving
# the merged work open as an issue. The one thing to avoid is closing an issue
# that is already closed (GitHub usually closes it natively seconds earlier),
# which would post a redundant comment. So the sole gate is the issue's state.
#
# Pure + side-effect-free (mirrors pr_decide / detect_answer / parse_marker);
# the caller fetches the state (a network op) and passes it in:
#   rc 0  — close explicitly: issue is OPEN.
#   rc 1  — do NOT close: issue is not OPEN (already CLOSED — GitHub handled it),
#           or the state is empty (FAIL-SAFE — a failed/unknown state fetch must
#           never trigger a close).
should_close_linked_issue() {
  local issue_state="${1:-}"
  [ "$issue_state" = "OPEN" ]
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

# PR_LAST_DECISION_TAIL — how many lines of state.jsonl's TAIL pr_last_decision
# reads. state.jsonl grows without bound and is dominated by PR-watch noise (up
# to multiple MB, issue #59), so the whole file must never be read; the last
# pr_classified sits at most a handful of events from the end in normal
# operation, so a small tail window always contains it. Matches status.sh's own
# tail-window convention.
PR_LAST_DECISION_TAIL="${PR_LAST_DECISION_TAIL:-40}"

# pr_last_decision <state-jsonl-path> — prints the `decision` of the most recent
# pr_classified event in the given state.jsonl, or nothing when the file is
# missing/empty or holds no such event.
#
# Reads only the tail of the file (never the whole thing — see above). Used by
# the watcher to suppress the pr_watch_started / pr_classified / pr_watch_skipped
# trio when a PR stays closed: the first SKIP_CLOSED is a meaningful transition
# and is logged, but every repeat after it would otherwise re-write the trio on
# every tick forever (the root cause of the 345 MB state.jsonl measured in #65).
# Pure read, no writes; testable by pointing at a temp file.
pr_last_decision() {
  local jsonl="$1"
  [ -f "$jsonl" ] || return 0
  tail -n "$PR_LAST_DECISION_TAIL" "$jsonl" 2>/dev/null \
    | jq -rn '[inputs | select(.event == "pr_classified") | .data.decision] | last // empty' \
        2>/dev/null || true
}
