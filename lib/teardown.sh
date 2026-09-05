#!/usr/bin/env bash
# lib/teardown.sh — the shared mechanism behind every label-driven teardown of a
# run's LOCAL artefacts (issue #202).
#
# WHY THIS LAYER EXISTS. There are two teardown VERBS and they differ in exactly
# four values; everything else — the lock, the run-dir inventory, the completed-run
# PR gate, the cleanup-run.sh delegation, the loop-guard label — is identical:
#
#   verb         trigger label             skipped label        closes issue?
#   auto-clean   RUN_ISSUES_CLEAN_LABEL    auto-clean-skipped   yes  (a finishing verb)
#   auto-reset   RUN_ISSUES_RESET_LABEL    auto-reset-skipped   no   (a re-run verb)
#
# Copying the gates per verb would put the safety-critical part of the system in
# two places, where the second copy drifts silently: a gate that is merely absent
# looks exactly like a gate that passed. So the gates live here once and each verb
# is a thin outcome layer on top.
#
# THE GATES, in order. Each one is fail-closed on unreadable information:
#   1. per-issue lock BEFORE any teardown — a live run owns its own artefacts
#   2. run-dir inventory for (issue, remote); zero local run-dirs is a
#      cross-machine situation, not a cleanable one
#   3. every `completed` run's PR state, read from run.json .pr_url. OPEN — or
#      unresolvable — protects the run. An unnecessary skip is recoverable; a
#      torn-down open PR is not.
#   4. teardown delegated to cleanup-run.sh, which owns the HOW (worktree,
#      branch, run-dir, DB clone, assignment, labels, lock, archive)
#
# CONFIGURATION — the caller sets these before calling teardown_run:
#   TEARDOWN_VERB            log prefix and skipped-label description ("auto-clean")
#   TEARDOWN_TRIGGER_LABEL   removed from the issue on the success path
#   TEARDOWN_SKIPPED_LABEL   loop guard added on the non-cleanable terminal cases
#   TEARDOWN_CLOSE_ISSUE     1 => `gh issue close` on success, 0 => leave it open
#   TEARDOWN_CLEANUP         absolute path to cleanup-run.sh
#
# COMMENTS — the caller defines three functions, each printing a Finnish body.
# They are what makes an outcome layer thin rather than empty: the gates are
# shared, the words a human reads are not. Context is in the TD_* variables set
# before the call (TD_ISSUE, TD_REMOTE, TD_HOST, TD_TOTAL, TD_COMPLETED,
# TD_BLOCKING):
#   teardown_comment_no_rundirs   gate 2 refused
#   teardown_comment_open_pr      gate 3 refused
#   teardown_comment_success      teardown done
#
# RETURN CODES (the callers map them onto their own exit-code spaces — the spaces
# are deliberately NOT unified, see CLAUDE.md §6):
#   0  torn down; trigger label removed
#   3  per-issue lock held by another run — safe to retry on a later tick
#   4  a completed run has an OPEN (or unresolvable) PR — skipped label added
#   5  no local run-dirs for this issue (cross-machine) — skipped label added
#   6  cleanup-run.sh teardown failed
#
# Requires: lib/locking.sh, lib/issue.sh (comment_issue), lib/labels.sh.

# runner_host lives in lib/host.sh — TD_HOST is compared against run.json.host
# by the callers' comment functions, so it has to come from the same resolver
# that wrote the field. Path relative to this file; function-only, so
# re-sourcing is harmless.
_TEARDOWN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=host.sh
. "$_TEARDOWN_LIB_DIR/host.sh"

# teardown_log <message…> — one stderr line, prefixed with the verb so the two
# verbs' lines never read as each other's in a shared tick log.
teardown_log() {
  printf '%s %s: %s\n' "$(date -u +%FT%TZ)" "${TEARDOWN_VERB:-teardown}" "$*" >&2
}

# teardown_pr_state <pr-url> — prints the PR's GitHub state (OPEN/MERGED/CLOSED),
# upper-cased, or empty on any failure (no URL, gh missing, network/API error).
# The URL carries its own owner/repo, so gh needs no --repo routing. Read-only —
# it never mutates. The completed-run gate treats an empty result as fail-closed.
teardown_pr_state() {
  local url="$1"
  [ -n "$url" ] || { printf ''; return 0; }
  gh pr view "$url" --json state --jq '(.state // "") | ascii_upcase' 2>/dev/null || printf ''
}

# _teardown_add_skipped_label <repo> <issue> <owner/repo> <dry-run>
# Best-effort: ensure the label exists, then add it. Any failure is non-fatal
# (logged only) — the loop guard is a courtesy to the scanner, not a gate.
_teardown_add_skipped_label() {
  local repo="$1" issue="$2" owner_repo="$3" dry="$4"
  if [ "$dry" = "1" ]; then
    teardown_log "[dry] add label $TEARDOWN_SKIPPED_LABEL to #$issue"
    return 0
  fi
  (
    cd "$repo" || exit 0
    labels_ensure "$owner_repo" "$TEARDOWN_SKIPPED_LABEL" "ededed" \
      "$TEARDOWN_VERB skipped this issue; needs human attention" || true
    labels_add "$owner_repo" "$issue" "$TEARDOWN_SKIPPED_LABEL" || true
  ) 2>&1 | while IFS= read -r l; do teardown_log "$l"; done || true
  return 0
}

# teardown_run <repo-root> <issue> <remote> <owner/repo> <repo-slug> <dry-run>
teardown_run() {
  local repo="$1" issue="$2" remote="$3" owner_repo="$4" repo_slug="$5" dry="$6"
  local runs_dir="$repo/.claude/run-issues"

  # ---------- 1. lock ----------
  # Acquire the per-issue lock BEFORE any teardown. The lock is namespaced by
  # repo AND remote so two orgs' #5 and another repo's #5 hold distinct locks
  # and never block each other.
  if ! lock_issue "$issue" "$remote" "$repo_slug"; then
    teardown_log "lock held for issue #$issue (remote=$remote) — a run is in progress; will retry later"
    return 3
  fi

  # IMPORTANT: cleanup-run.sh removes the per-issue lock as part of its teardown
  # (it sources lib/locking.sh and rm -rf's the lock dir). So once we hand off to
  # it on the success path, the lock is already gone and we must not treat a
  # later unlock as meaningful. unlock_issue is idempotent, but we simply never
  # call it on the success path; every early return below releases it explicitly.
  #
  # ONE EXCEPTION, and it is the whole of issue #142: under --dry-run that
  # hand-off tears nothing down — cleanup-run.sh only prints its plan. The
  # premise of the paragraph above ("the lock is already gone") is therefore
  # false in a preview, so the dry-run success branch releases the lock itself.
  # The exception lives in the dry-run branch and NOT in the real path, because
  # the real path's ownership rule is correct as written and a second unlock
  # there would only make it read as though it were not.

  # ---------- 2. run-dir inventory ----------
  # Count run-dirs whose run.json .issue_number matches AND whose .remote matches
  # (legacy run.json without .remote is treated as "origin" so the default remote
  # picks them up). bash 3.2 compatible — plain counters.
  local total=0 completed=0 rj n r s
  local completed_prs=()
  TEARDOWN_FORCE=0
  shopt -s nullglob
  for rj in "$runs_dir"/*/run.json; do
    n=$(jq -r '.issue_number // empty' "$rj" 2>/dev/null || echo "")
    [ "$n" = "$issue" ] || continue
    r=$(jq -r '.remote // "origin"' "$rj" 2>/dev/null || echo "origin")
    [ "$r" = "$remote" ] || continue
    total=$((total + 1))
    s=$(jq -r '.status // ""' "$rj" 2>/dev/null || echo "")
    if [ "$s" = "completed" ]; then
      completed=$((completed + 1))
      # Record the run's PR URL (empty if legacy/unset) so the completed-run gate
      # below can resolve each PR's merge state. orchestrate.sh S12 writes pr_url.
      completed_prs+=("$(jq -r '.pr_url // ""' "$rj" 2>/dev/null || echo "")")
    fi
  done

  # Context for the caller's comment functions. Assigned here and read only
  # there, which is what shellcheck cannot see across the indirection.
  # shellcheck disable=SC2034
  {
    TD_ISSUE="$issue"; TD_REMOTE="$remote"
    TD_HOST="$(runner_host)"
    TD_TOTAL="$total"; TD_COMPLETED="$completed"; TD_BLOCKING=0
  }

  if [ "$total" -eq 0 ]; then
    # Cross-machine fallback: this issue has no run-dirs on this host. The
    # resources (if any) live on another machine. Post a hint and mark the issue
    # skipped so we stop re-emitting it.
    teardown_log "no local run-dirs for issue #$issue (remote=$remote, cross-machine?)"
    if [ "$dry" = "1" ]; then
      teardown_log "[dry] would post cross-machine cleanup hint + label $TEARDOWN_SKIPPED_LABEL"
    else
      comment_issue "$repo" "$issue" "$(teardown_comment_no_rundirs)" "$owner_repo" "$remote" \
        || teardown_log "comment post failed (non-fatal)"
    fi
    _teardown_add_skipped_label "$repo" "$issue" "$owner_repo" "$dry"
    unlock_issue "$issue" "$remote" "$repo_slug"
    return 5
  fi

  # ---------- 3. completed-run PR gate ----------
  if [ "$completed" -gt 0 ]; then
    # A completed run normally has an OPEN PR, and tearing down the run-dir could
    # orphan it. But once that PR is MERGED (or CLOSED) there is nothing left to
    # orphan. So resolve each completed run's PR state from its recorded pr_url
    # and refuse ONLY if some PR is still OPEN, or its state cannot be determined.
    # The latter is FAIL-CLOSED on purpose: an unresolvable state (missing pr_url
    # on a legacy run, a network/gh error) must never be mistaken for "merged".
    local blocking=0 pr st
    for pr in "${completed_prs[@]}"; do
      st=$(teardown_pr_state "$pr")
      case "$st" in
        MERGED|CLOSED) : ;;  # not open — safe to tear down
        OPEN)
          blocking=$((blocking + 1))
          teardown_log "issue #$issue: a completed run's PR is OPEN ($pr) — protecting it"
          ;;
        *)
          blocking=$((blocking + 1))
          teardown_log "issue #$issue: completed-run PR state unresolved (${pr:-no pr_url}) — fail-closed, protecting"
          ;;
      esac
    done

    if [ "$blocking" -gt 0 ]; then
      # shellcheck disable=SC2034
      TD_BLOCKING="$blocking"
      teardown_log "$blocking of $completed completed run-dir(s) for issue #$issue have an open/unknown PR — skipping"
      if [ "$dry" = "1" ]; then
        teardown_log "[dry] would post open-PR notice + label $TEARDOWN_SKIPPED_LABEL"
      else
        comment_issue "$repo" "$issue" "$(teardown_comment_open_pr)" "$owner_repo" "$remote" \
          || teardown_log "comment post failed (non-fatal)"
      fi
      _teardown_add_skipped_label "$repo" "$issue" "$owner_repo" "$dry"
      unlock_issue "$issue" "$remote" "$repo_slug"
      return 4
    fi

    # Every completed run's PR is MERGED/CLOSED — nothing to orphan. Fall through
    # to teardown, forcing cleanup-run.sh to include the completed run-dirs (it
    # skips completed runs without --force).
    teardown_log "$completed completed run-dir(s) for issue #$issue all have a merged/closed PR — cleaning"
    TEARDOWN_FORCE=1
  fi

  # ---------- 4. teardown ----------
  teardown_log "tearing down issue #$issue remote=$remote ($total run-dir(s), force=$TEARDOWN_FORCE)"
  local cleanup_args=(--repo "$repo" --issue "$issue" --remote "$remote" --yes)
  [ "$TEARDOWN_FORCE" = "1" ] && cleanup_args+=(--force)
  [ "$dry" = "1" ] && cleanup_args+=(--dry-run)

  local cleanup_rc
  if bash "$TEARDOWN_CLEANUP" "${cleanup_args[@]}"; then
    cleanup_rc=0
  else
    cleanup_rc=$?
  fi

  if [ "$cleanup_rc" -ne 0 ]; then
    teardown_log "cleanup-run.sh failed (rc=$cleanup_rc) for issue #$issue"
    # cleanup-run.sh may or may not have removed the lock depending on where it
    # failed; unlock_issue is idempotent so this is safe either way.
    unlock_issue "$issue" "$remote" "$repo_slug"
    return 6
  fi

  # ---------- 5. success: close (or not), comment, remove the trigger label ----
  # The lock was already removed by cleanup-run.sh's teardown — see the IMPORTANT
  # note above. We do NOT call unlock_issue here.
  if [ "$dry" = "1" ]; then
    # Release the lock we took at gate 1: cleanup-run.sh did not, and a preview
    # must not leave state behind. Leaking it here was the worst kind of state
    # change — the next REAL teardown of this issue refused with rc 3, and since
    # the lock has no live owner it would not expire until
    # RUN_ISSUES_LOCK_STALE_SECS (24 h by default). Measured: 129 previewed
    # issues left 129 locks, and the cleanup they were previewing refused on all
    # 129. unlock_issue is idempotent, so this is safe regardless.
    unlock_issue "$issue" "$remote" "$repo_slug"
    if [ "${TEARDOWN_CLOSE_ISSUE:-0}" = "1" ]; then
      teardown_log "[dry] would close issue #$issue, post summary, remove label $TEARDOWN_TRIGGER_LABEL"
    else
      teardown_log "[dry] would leave issue #$issue open, post summary, remove label $TEARDOWN_TRIGGER_LABEL"
    fi
    return 0
  fi

  if [ "${TEARDOWN_CLOSE_ISSUE:-0}" = "1" ]; then
    local repo_args=""
    [ -n "$owner_repo" ] && repo_args="--repo $owner_repo"
    # shellcheck disable=SC2086
    (
      cd "$repo" || exit 0
      gh issue close "$issue" $repo_args >/dev/null 2>&1 || true
    )
  fi

  comment_issue "$repo" "$issue" "$(teardown_comment_success)" "$owner_repo" "$remote" \
    || teardown_log "summary comment post failed (non-fatal)"

  # Remove the trigger label LAST, so a failure anywhere above leaves the issue
  # in the scanner's sight instead of silently dropping it.
  (
    cd "$repo" || exit 0
    labels_remove "$owner_repo" "$issue" "$TEARDOWN_TRIGGER_LABEL" || true
  ) 2>&1 | while IFS= read -r l; do teardown_log "$l"; done || true

  return 0
}
