#!/usr/bin/env bash
# test-auto-claimed-label.sh — structural guard for the auto-claimed reservation
# label (issue #99).
#
# Issue #238 later added an OPT-IN assignee allow-list to pickup; case 1 guards
# that it stayed opt-in, because an ungated assignee term would make assignment
# a reservation again.
#
# Issue #99 moved the run reservation from `no:assignee` to the automation-owned
# `auto-claimed` label. The label's lifecycle MUST be EXACTLY the assignment's
# lifecycle: added wherever the run claims, removed wherever the run un-assigns,
# and — crucially — NOT removed where the assignment is deliberately KEPT (a
# blocked/stalled run stays reserved until cleanup). If a future edit adds an
# un-assign path that forgets the label, the issue silently returns to pickup
# mid-run; if a blocked-finalisation path removes the label, a failed run is
# re-picked every tick and hits the same wall. This test pins both directions.
#
# It WRITES NOTHING and needs no $HOME. It only reads repository files.
#
# Run: bash tests/test-auto-claimed-label.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

ISSUE_LIB="$ROOT/lib/issue.sh"
CLEANUP="$ROOT/cleanup-run.sh"
RUN_TERMINATE="$ROOT/lib/run-terminate.sh"
ORCH="$ROOT/orchestrate.sh"

# func_body <file> <func-name> — prints the body of a shell function defined as
# `name() {` … up to the first line that is a bare `}` at column 0.
func_body() {
  awk -v fn="$2" '
    $0 ~ "^"fn"\\(\\) \\{" { inf=1 }
    inf { print }
    inf && /^}/ { exit }
  ' "$1"
}

# ---- Case 1: pickup reserves via the auto-claimed label, not via an assignee ----
# The reservation used to be a `-label:auto-claimed` term in the pickup SEARCH
# string. Issue #133 moved pickup to REST, so the exclusion now lives in the
# local jq filter (_pick_filter_jq) — same rule, different mechanism, and the
# invariant to guard is unchanged: auto-claimed removes an issue from pickup and
# assignee never does.
FILTER_BODY="$(func_body "$ISSUE_LIB" _pick_filter_jq)"
if [ -z "$FILTER_BODY" ]; then
  fail "could not locate the pickup exclusion filter (_pick_filter_jq) in $ISSUE_LIB"
else
  case "$FILTER_BODY" in
    *'"auto-claimed"'*) pass "pickup excludes auto-claimed" ;;
    *) fail "pickup filter no longer excludes auto-claimed" ;;
  esac
  # Issue #238 gave the filter an OPT-IN assignee term (the watchlist
  # `assignees` allow-list), so "no assignee condition at all" is no longer the
  # invariant. What #99 established still is: assignment is not a reservation,
  # so an assignee condition may never be unconditional. Every assignee term
  # therefore has to sit behind RUN_ISSUES_PICK_ASSIGNEES, which is empty in
  # every repo that did not ask for it. That the empty value filters NOTHING is
  # the behavioural half, pinned in tests/test-issue-pick.sh.
  case "$FILTER_BODY" in
    *'assignee'*)
      if printf '%s' "$FILTER_BODY" | grep -q 'RUN_ISSUES_PICK_ASSIGNEES'; then
        pass "the assignee term is gated on the opt-in allow-list"
      else
        fail "pickup filter has an UNGATED assignee condition — issue #99 removed it"
      fi
      ;;
    *) pass "pickup does not filter on assignee" ;;
  esac
fi
# And the query itself must not have drifted back onto a search-routed shape.
PICK_BODY="$(func_body "$ISSUE_LIB" pick_oldest_candidate)"
case "$PICK_BODY" in
  *'gh api'*) pass "pickup queries REST (issue #133)" ;;
  *) fail "pickup no longer uses gh api — a filtered gh issue list is search-routed" ;;
esac

# ---- Case 2: claim adds the label, unclaim removes it (bound to the functions) ----
CLAIM_BODY="$(func_body "$ISSUE_LIB" claim_issue)"
UNCLAIM_BODY="$(func_body "$ISSUE_LIB" unclaim_issue)"
if printf '%s' "$CLAIM_BODY" | grep -q '_reserve_label_add'; then
  pass "claim_issue adds the reservation label (_reserve_label_add)"
else
  fail "claim_issue does not add the reservation label"
fi
if printf '%s' "$UNCLAIM_BODY" | grep -q '_reserve_label_remove'; then
  pass "unclaim_issue removes the reservation label (_reserve_label_remove)"
else
  fail "unclaim_issue does not remove the reservation label"
fi

# The helpers actually touch the auto-claimed label via labels.sh.
ADD_HELPER="$(func_body "$ISSUE_LIB" _reserve_label_add)"
REMOVE_HELPER="$(func_body "$ISSUE_LIB" _reserve_label_remove)"
if printf '%s' "$ADD_HELPER" | grep -q 'labels_add' \
   && printf '%s' "$ADD_HELPER" | grep -q 'AUTO_CLAIMED_LABEL'; then
  pass "_reserve_label_add writes AUTO_CLAIMED_LABEL via labels_add"
else
  fail "_reserve_label_add does not write AUTO_CLAIMED_LABEL via labels_add"
fi
if printf '%s' "$REMOVE_HELPER" | grep -q 'labels_remove' \
   && printf '%s' "$REMOVE_HELPER" | grep -q 'AUTO_CLAIMED_LABEL'; then
  pass "_reserve_label_remove deletes AUTO_CLAIMED_LABEL via labels_remove"
else
  fail "_reserve_label_remove does not delete AUTO_CLAIMED_LABEL via labels_remove"
fi

# AUTO_CLAIMED_LABEL is fixed to auto-claimed.
if grep -qE '^AUTO_CLAIMED_LABEL="auto-claimed"' "$ISSUE_LIB"; then
  pass "AUTO_CLAIMED_LABEL is fixed to auto-claimed"
else
  fail "AUTO_CLAIMED_LABEL is not defined as auto-claimed in $ISSUE_LIB"
fi

# ---- Case 3: cleanup-run.sh removes auto-claimed beside its RAW un-assign ----
# cleanup-run does a raw `gh issue edit --remove-assignee @me` (not unclaim_issue),
# so the label removal cannot ride along structurally — it must be explicit. Assert
# both the raw un-assign AND an auto-claimed removal exist in the file.
if grep -q -- '--remove-assignee' "$CLEANUP"; then
  pass "cleanup-run.sh has the raw --remove-assignee un-assign"
else
  fail "cleanup-run.sh no longer has the raw --remove-assignee — the block moved?"
fi
if grep -qE 'labels_remove[^#]*auto-claimed' "$CLEANUP"; then
  pass "cleanup-run.sh removes the auto-claimed label"
else
  fail "cleanup-run.sh does not remove the auto-claimed label beside its un-assign"
fi

# ---- Case 4: blocked/stalled finalisation does NOT remove the reservation ----
# A blocked or stalled run KEEPS its assignment (README §6.4 point 3), so it must
# keep auto-claimed too — otherwise a failed run is re-picked every tick. run-terminate
# (stop-run, stalled) is the shared finalisation path and must not touch the label.
if grep -q 'auto-claimed\|AUTO_CLAIMED_LABEL' "$RUN_TERMINATE"; then
  fail "lib/run-terminate.sh references the auto-claimed label — a blocked/stalled run must stay reserved (issue #99)"
else
  pass "lib/run-terminate.sh leaves the auto-claimed reservation in place"
fi

# ---- Case 5: auto-claimed is NOT propagated to the PR (edge case 4) ----
# The reservation is an issue-only marker; RUN_ISSUES_PR_LABELS_CSV defaults to
# auto-merge and must never carry auto-claimed onto the created PR.
PR_DEFAULT_LINE="$(grep -n 'RUN_ISSUES_PR_LABELS_CSV:-' "$ORCH" | head -1)"
if [ -z "$PR_DEFAULT_LINE" ]; then
  fail "could not locate the PR_LABELS_CSV default in $ORCH"
elif printf '%s' "$PR_DEFAULT_LINE" | grep -q 'auto-claimed'; then
  fail "auto-claimed leaks into the PR-propagation default: $PR_DEFAULT_LINE"
else
  pass "auto-claimed is not in the PR-propagation default"
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "auto-claimed-label: all passed" || echo "auto-claimed-label: FAILURES"
[ "$FAIL" -eq 0 ]
