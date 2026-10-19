#!/usr/bin/env bash
# lib/teardown.sh — the shared mechanism behind every label-driven teardown of a
# run's LOCAL artefacts (issue #202).
#
# WHY THIS LAYER EXISTS. There are two teardown VERBS and they differ in exactly
# five values; everything else — the lock, the run-dir inventory, the completed-run
# PR gate, the cleanup-run.sh delegation, the loop-guard label — is identical:
#
#   verb         trigger label             skipped label        closes issue?  deletes remote branch?
#   auto-clean   RUN_ISSUES_CLEAN_LABEL    auto-clean-skipped   yes            no
#   auto-reset   RUN_ISSUES_RESET_LABEL    auto-reset-skipped   no             yes
#
# (the fifth value is the comment wording). auto-reset deletes the remote branch
# because a reset run gets the SAME branch name (orchestrate.sh derives it from
# the issue): a leftover branch of a closed PR would reject its S10 push as
# non-fast-forward, and no number of resets would help (issue #329).
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
#   3b. (TEARDOWN_DELETE_REMOTE_BRANCH=1 only) every run's branch's PRs, read
#      with `gh pr list --head`. An OPEN PR on the branch — or an unreadable
#      answer — refuses like gate 3: deleting an open PR's head closes the PR,
#      and NOT deleting it would replay the same push rejection on the next run.
#   4. teardown delegated to cleanup-run.sh, which owns the HOW (worktree,
#      branch, run-dir, DB clone, assignment, labels, lock, archive)
#   4b. (TEARDOWN_DELETE_REMOTE_BRANCH=1 only) the remote branch is deleted when
#      every PR on it is MERGED/CLOSED, or it has no PR and is runner-owned
#      (`auto-run/` prefix). Best effort: a failed delete is logged, not fatal.
#
# CONFIGURATION — the caller sets these before calling teardown_run:
#   TEARDOWN_VERB            log prefix and skipped-label description ("auto-clean")
#   TEARDOWN_TRIGGER_LABEL   removed from the issue on the success path
#   TEARDOWN_SKIPPED_LABEL   loop guard added on the non-cleanable terminal cases
#   TEARDOWN_CLOSE_ISSUE     1 => `gh issue close` on success, 0 => leave it open
#   TEARDOWN_CLEANUP         absolute path to cleanup-run.sh
#   TEARDOWN_DELETE_REMOTE_BRANCH  1 => gates 3b/4b on, 0 (default) => off
#
# COMMENTS — the caller defines three functions, each printing a Finnish body.
# They are what makes an outcome layer thin rather than empty: the gates are
# shared, the words a human reads are not. Context is in the TD_* variables set
# before the call (TD_ISSUE, TD_REMOTE, TD_HOST, TD_TOTAL, TD_COMPLETED,
# TD_BLOCKING, and with gates 3b/4b TD_BRANCH_BLOCKING — the refusing branches,
# space-separated — and TD_REMOTE_BRANCHES — one "<branch>|<outcome>|<reason>"
# line per existing remote branch handled at 4b; outcome is deleted, failed or
# unreadable, reason "all PRs closed/merged" or "no PR, runner-owned"):
#   teardown_comment_no_rundirs   gate 2 refused
#   teardown_comment_open_pr      gate 3 or 3b refused
#   teardown_comment_success      teardown done
#
# RETURN CODES (the callers map them onto their own exit-code spaces — the spaces
# are deliberately NOT unified, see CLAUDE.md §6):
#   0  torn down; trigger label removed
#   3  per-issue lock held by another run — safe to retry on a later tick
#   4  a completed run has an OPEN (or unresolvable) PR, or (gate 3b) a run's
#      branch has an OPEN PR or its PRs could not be read — skipped label added
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

# teardown_branch_prs <repo> <owner/repo> <branch> — prints the states of every
# PR whose head is <branch> (any state), upper-cased and comma-joined; empty when
# the branch has no PR. Returns 1 on ANY failure (gh missing, network/API error,
# a non-array answer) so the caller can tell "no PRs" from "could not tell" —
# gate 3b treats the latter as fail-closed. Read-only.
teardown_branch_prs() {
  local repo="$1" owner_repo="$2" branch="$3" json
  local route=()
  [ -n "$owner_repo" ] && route=(--repo "$owner_repo")
  json=$(cd "$repo" && gh pr list --head "$branch" --state all --limit 100 \
           --json state ${route[@]+"${route[@]}"} 2>/dev/null) || return 1
  jq -er 'if type == "array" then [.[].state | ascii_upcase] | join(",") else error end' \
    <<<"$json" 2>/dev/null || return 1
}

# _teardown_git_remote <repo> <remote> <git-args…> — run a git command that talks
# to <remote>, authenticated as the GitHub App when the caller has loaded
# lib/github-app-auth.sh and the remote is origin — the same rule as
# orchestrate.sh's S10 push, so a branch pushed as the App is deleted as the App.
# The header lives in a local and goes only into `git -c`, never into a log or
# .git/config.
_teardown_git_remote() {
  local repo="$1" remote="$2"; shift 2
  local hdr=""
  if [ "$remote" = "origin" ] && declare -F gha_git_push_header >/dev/null 2>&1; then
    hdr=$(gha_git_push_header 2>/dev/null) || hdr=""
  fi
  if [ -n "$hdr" ]; then
    git -C "$repo" -c "http.extraheader=$hdr" "$@"
  else
    git -C "$repo" "$@"
  fi
}

# teardown_remote_branch_exists <repo> <remote> <branch> — rc 0 exists, 2 absent,
# anything else: the remote could not be read.
teardown_remote_branch_exists() {
  local repo="$1" remote="$2" branch="$3"
  _teardown_git_remote "$repo" "$remote" ls-remote --exit-code --heads "$remote" "refs/heads/$branch" \
    >/dev/null 2>&1
}

# _teardown_delete_remote_branches <repo> <remote> <dry-run> <branch:reason>…
# Gate 4b. Best effort per branch; every outcome is one log line naming the branch
# and the reason, and (unless the branch was already absent) one
# TD_REMOTE_BRANCHES line for the caller's comment.
_teardown_delete_remote_branches() {
  local repo="$1" remote="$2" dry="$3"; shift 3
  local entry b why rc
  TD_REMOTE_BRANCHES=""
  for entry in "$@"; do
    b="${entry%%|*}"; why="${entry#*|}"
    if [ "$dry" = "1" ]; then
      teardown_log "[dry] would delete remote branch $b on $remote if present (reason: $why)"
      continue
    fi
    if teardown_remote_branch_exists "$repo" "$remote" "$b"; then rc=0; else rc=$?; fi
    if [ "$rc" -eq 2 ]; then
      teardown_log "remote branch $b not on $remote — nothing to delete"
      continue
    fi
    if [ "$rc" -ne 0 ]; then
      teardown_log "WARN: could not read $remote for branch $b (rc=$rc) — remote branch left as is"
      TD_REMOTE_BRANCHES="${TD_REMOTE_BRANCHES}${b}|unreadable|${why}"$'\n'
      continue
    fi
    if _teardown_git_remote "$repo" "$remote" push "$remote" --delete "$b" >/dev/null 2>&1; then
      teardown_log "deleted remote branch $b on $remote (reason: $why)"
      TD_REMOTE_BRANCHES="${TD_REMOTE_BRANCHES}${b}|deleted|${why}"$'\n'
    else
      teardown_log "WARN: failed to delete remote branch $b on $remote (reason: $why) — the next run's push may be rejected"
      TD_REMOTE_BRANCHES="${TD_REMOTE_BRANCHES}${b}|failed|${why}"$'\n'
    fi
  done
  return 0
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
  local total=0 completed=0 rj n r s x
  local completed_prs=() branches=() b seen
  TEARDOWN_FORCE=0
  shopt -s nullglob
  for rj in "$runs_dir"/*/run.json; do
    n=$(jq -r '.issue_number // empty' "$rj" 2>/dev/null || echo "")
    [ "$n" = "$issue" ] || continue
    r=$(jq -r '.remote // "origin"' "$rj" 2>/dev/null || echo "origin")
    [ "$r" = "$remote" ] || continue
    total=$((total + 1))
    # The run's branch, for gates 3b/4b. Empty (legacy run.json) is skipped;
    # duplicates (several runs of one issue share a name) are kept once.
    b=$(jq -r '.branch // ""' "$rj" 2>/dev/null || echo "")
    if [ -n "$b" ]; then
      seen=0
      for x in ${branches[@]+"${branches[@]}"}; do [ "$x" = "$b" ] && seen=1; done
      [ "$seen" = "1" ] || branches+=("$b")
    fi
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
    TD_BRANCH_BLOCKING=""; TD_REMOTE_BRANCHES=""
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

  # ---------- 3b. branch PR gate (opt-in) ----------
  # Decide BEFORE any teardown what happens to each run's remote branch. Checking
  # only after cleanup-run.sh would be too late: the issue would already be back
  # in pickup, and its next run would hit the same push rejection on an open PR's
  # branch. Entries are "<branch>|<reason>" for gate 4b.
  local delete_branches=() prs
  if [ "${TEARDOWN_DELETE_REMOTE_BRANCH:-0}" = "1" ]; then
    local branch_blocking=""
    for b in ${branches[@]+"${branches[@]}"}; do
      if ! prs=$(teardown_branch_prs "$repo" "$owner_repo" "$b"); then
        branch_blocking="$branch_blocking $b"
        teardown_log "issue #$issue: PRs of branch $b could not be read — fail-closed, protecting"
        continue
      fi
      case ",$prs," in
        *,OPEN,*)
          branch_blocking="$branch_blocking $b"
          teardown_log "issue #$issue: branch $b has an OPEN PR — protecting it"
          ;;
        ,,)
          case "$b" in
            auto-run/*) delete_branches+=("$b|no PR, runner-owned") ;;
            *) teardown_log "issue #$issue: branch $b has no PR and is not runner-owned — remote branch left alone" ;;
          esac
          ;;
        *) delete_branches+=("$b|all PRs closed/merged") ;;
      esac
    done

    if [ -n "$branch_blocking" ]; then
      # shellcheck disable=SC2034
      TD_BRANCH_BLOCKING="${branch_blocking# }"
      teardown_log "issue #$issue: branch(es) with an open/unknown PR: $TD_BRANCH_BLOCKING — skipping"
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

  # ---------- 4b. remote branch deletion (opt-in) ----------
  # After the local teardown (cleanup-run.sh has deleted the local branch, so
  # nothing here still checks it out) and before the comment that reports it.
  if [ "${#delete_branches[@]}" -gt 0 ]; then
    _teardown_delete_remote_branches "$repo" "$remote" "$dry" "${delete_branches[@]}"
  fi

  # ---------- 5. success: close (or not), comment, remove the trigger label ----
  # The lock was already removed by cleanup-run.sh's teardown — see the IMPORTANT
  # note above. We do NOT call unlock_issue here.
  if [ "$dry" = "1" ]; then
    # The exception noted at gate 1: cleanup-run.sh released nothing under
    # --dry-run, so this branch releases the lock we took there. A preview that
    # leaves a lock behind blocks the very teardown it was rehearsing (rc 3)
    # until the lock goes stale.
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
