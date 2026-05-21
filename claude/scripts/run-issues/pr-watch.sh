#!/usr/bin/env bash
# pr-watch.sh — Phase 2 PR watcher for /run-issues.
#
# Watches PRs opened by the orchestrator and, when an auto-merge PR is green
# and mergeable, rebase-merges it, runs an optional post-merge migration, and
# tears down the run artefacts. Polling-driven and fully idempotent — there is
# no resume state; every invocation re-derives the world from `gh` + run.json.
#
# Usage:
#   pr-watch.sh <repo-root> <pr-number>   # watch one named PR
#   pr-watch.sh <repo-root> scan          # iterate completed runs on this host
#
# Env:
#   PR_WATCH_AUTO                        default 0 — reserved for future
#                                        non-interactive behaviour toggles.
#   PR_WATCH_ENABLE_CONFLICT_RESOLUTION  default 0 — OFF. When 1, a BEHIND/DIRTY
#                                        PR is rebased in its feature worktree
#                                        with mandatory CI revalidation. Any
#                                        conflict aborts and asks a human.
#   PR_WATCH_MERGE_LABEL                 default "auto-merge".
#   PR_WATCH_LABELS_CSV                  optional scan filter (unused gate today;
#                                        the merge label is the real gate).
#
# State machine (P1..P9), see docs/diagrams/pr-watch-state-machine.mmd.
#
# Exit codes:
#   0  merge + cleanup OK, or nothing to do
#   1  usage error
#   2  scan found no candidate
#   3  lock race lost (another watcher/orchestrator holds the issue)
#   4  not mergeable yet (reporting; safe to retry next poll)
#   5  merge failed
#   6  conflict needs a human (rebase aborted, PR commented)
#   7  post-merge migration failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/locking.sh
. "$SCRIPT_DIR/lib/locking.sh"
# shellcheck source=lib/state.sh
. "$SCRIPT_DIR/lib/state.sh"
# shellcheck source=lib/pr-watch-lib.sh
. "$SCRIPT_DIR/lib/pr-watch-lib.sh"

PR_WATCH_AUTO="${PR_WATCH_AUTO:-0}"
PR_WATCH_ENABLE_CONFLICT_RESOLUTION="${PR_WATCH_ENABLE_CONFLICT_RESOLUTION:-0}"
PR_WATCH_MERGE_LABEL="${PR_WATCH_MERGE_LABEL:-auto-merge}"
PR_WATCH_LABELS_CSV="${PR_WATCH_LABELS_CSV:-}"

usage() {
  echo "usage: pr-watch.sh <repo-root> <pr-number|scan>" >&2
  exit 1
}

[ "$#" -eq 2 ] || usage
REPO_ROOT="$1"
TARGET="$2"
[ -d "$REPO_ROOT/.git" ] || { echo "pr-watch: not a git repo: $REPO_ROOT" >&2; exit 1; }

RUNS_DIR="$REPO_ROOT/.claude/run-issues"
THIS_HOST="$(hostname -s)"

log() { printf '%s pr-watch: %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

# run_field <run-id> <jq-path> — empty string if file/key missing.
run_field() {
  local rid="$1" path="$2"
  local rj="$RUNS_DIR/$rid/run.json"
  [ -f "$rj" ] || { printf ''; return; }
  jq -r "$path // empty" "$rj" 2>/dev/null || printf ''
}

# ----- P1: Discover -------------------------------------------------------
# For a named PR we resolve its run-dir by matching pr_url's PR number; if no
# run-dir matches we still proceed (merge works without run state, cleanup is
# then a no-op). For scan we emit run-ids for completed PRs on this host.

# pr_number_from_url <url> — trailing path segment of a GitHub PR URL.
pr_number_from_url() {
  printf '%s' "$1" | sed -E 's#.*/pull/([0-9]+).*#\1#'
}

# discover_runid_for_pr <pr-number> — prints the matching run-id, or empty.
discover_runid_for_pr() {
  local want="$1" d rid url
  shopt -s nullglob
  for d in "$RUNS_DIR"/*/; do
    rid=$(basename "$d")
    url=$(run_field "$rid" '.pr_url')
    [ -n "$url" ] || continue
    if [ "$(pr_number_from_url "$url")" = "$want" ]; then
      printf '%s' "$rid"
      return 0
    fi
  done
  printf ''
}

# scan_candidates — prints "<pr-number> <run-id>" lines for completed runs on
# this host with a non-null pr_url. The host gate is a safety rail (decision 4):
# a watcher only acts on PRs whose run originated on the same machine, so it
# never tries to remove a worktree that lives on another host.
scan_candidates() {
  shopt -s nullglob
  local d rid status url host num
  for d in "$RUNS_DIR"/*/; do
    rid=$(basename "$d")
    status=$(run_field "$rid" '.status')
    url=$(run_field "$rid" '.pr_url')
    host=$(run_field "$rid" '.host')
    [ "$status" = "completed" ] || continue
    [ -n "$url" ] || continue
    # Empty host = pre-host-field run.json; treat as local (best effort).
    if [ -n "$host" ] && [ "$host" != "$THIS_HOST" ]; then
      continue
    fi
    num=$(pr_number_from_url "$url")
    [ -n "$num" ] && printf '%s %s\n' "$num" "$rid"
  done
}

# ----- watch_one: P2..P9 for a single PR ----------------------------------
# Args: <pr-number> [<run-id>]
watch_one() {
  local pr_num="$1"
  local rid="${2:-}"

  [ -n "$rid" ] || rid=$(discover_runid_for_pr "$pr_num")
  local run_dir=""
  local issue_num=""
  if [ -n "$rid" ]; then
    run_dir="$RUNS_DIR/$rid"
    issue_num=$(run_field "$rid" '.issue_number')
  fi

  # ----- P2: Lock (reuse per-issue lock; PR work and orchestration share it)
  local locked=0
  if [ -n "$issue_num" ]; then
    if lock_issue "$issue_num"; then
      locked=1
    else
      log "lock held for issue #$issue_num — another run owns it; skipping PR #$pr_num"
      return 3
    fi
  fi
  # Always release the lock on the way out of this PR.
  _release() { [ "$locked" = "1" ] && unlock_issue "$issue_num" || true; }

  if [ -n "$run_dir" ] && [ -d "$run_dir" ]; then
    state_event "$run_dir" "pr_watch_started" "pr=$pr_num"
  fi

  # ----- P3: Classify -----------------------------------------------------
  local pr_json
  if ! pr_json=$(
        cd "$REPO_ROOT"
        gh pr view "$pr_num" \
          --json state,mergeable,mergeStateStatus,labels,statusCheckRollup,headRefName 2>/dev/null
      ); then
    log "gh pr view failed for PR #$pr_num"
    _release
    return 4
  fi

  local decision
  decision=$(pr_decide "$pr_json" "$PR_WATCH_ENABLE_CONFLICT_RESOLUTION" "$PR_WATCH_MERGE_LABEL")
  log "PR #$pr_num classified: $decision"
  if [ -n "$run_dir" ] && [ -d "$run_dir" ]; then
    state_event "$run_dir" "pr_classified" "pr=$pr_num" "decision=$decision"
  fi

  # ----- P4: Decide -------------------------------------------------------
  case "$decision" in
    MERGE)
      : # fall through to P6
      ;;
    REBASE)
      # ----- P5: Resolve (conflict-free rebase + CI revalidation) ---------
      if pr_resolve "$pr_num" "$rid" "$run_dir" "$pr_json"; then
        : # rebased + revalidated green; fall through to merge
      else
        local rc=$?
        _release
        return "$rc"
      fi
      ;;
    SKIP_NO_LABEL|SKIP_CLOSED|SKIP_BLOCKED)
      [ -n "$run_dir" ] && [ -d "$run_dir" ] && \
        state_event "$run_dir" "pr_watch_skipped" "pr=$pr_num" "reason=$decision"
      _release
      return 4
      ;;
    WAIT_CI|WAIT_DIRTY)
      [ -n "$run_dir" ] && [ -d "$run_dir" ] && \
        state_event "$run_dir" "pr_watch_skipped" "pr=$pr_num" "reason=$decision"
      _release
      return 4
      ;;
    *)
      log "unexpected decision '$decision' for PR #$pr_num"
      _release
      return 4
      ;;
  esac

  # ----- P6: Merge --------------------------------------------------------
  log "merging PR #$pr_num (--rebase --delete-branch)"
  if ! ( cd "$REPO_ROOT" && gh pr merge "$pr_num" --rebase --delete-branch ); then
    log "merge failed for PR #$pr_num"
    [ -n "$run_dir" ] && [ -d "$run_dir" ] && \
      state_event "$run_dir" "pr_watch_skipped" "pr=$pr_num" "reason=merge_failed"
    _release
    return 5
  fi

  # ----- P7: PostMerge ----------------------------------------------------
  # The watcher deliberately does NOT set POST_COMMIT_SYNC=1: post-merge work
  # happens on main and must not pull doc/security fix commits into the merged
  # PR after the fact.
  if [ ! -L "$HOME/.git-hooks" ]; then
    log "WARNING: ~/.git-hooks is not a symlink — git-template hooks may be stale (I6 health note)"
  fi
  local migrate="$REPO_ROOT/.claude/post-merge-migrate.sh"
  if [ -x "$migrate" ]; then
    log "running post-merge migration: $migrate"
    if ! ( cd "$REPO_ROOT" && "$migrate" "$REPO_ROOT" "$pr_num" ); then
      log "post-merge migration FAILED for PR #$pr_num"
      [ -n "$run_dir" ] && [ -d "$run_dir" ] && \
        state_event "$run_dir" "post_merge_migrate" "pr=$pr_num" "result=failed"
      _release
      return 7
    fi
    [ -n "$run_dir" ] && [ -d "$run_dir" ] && \
      state_event "$run_dir" "post_merge_migrate" "pr=$pr_num" "result=ok"
  elif [ -e "$migrate" ]; then
    log "post-merge migration present but not executable — skipping: $migrate"
  fi

  # ----- P8: Finalize (BEFORE cleanup; I4 — never lose the merged record) -
  if [ -n "$run_dir" ] && [ -d "$run_dir" ]; then
    state_finalize "$run_dir" "merged"
    state_event "$run_dir" "pr_merged" "pr=$pr_num"
  fi

  # ----- P9: Cleanup (host gate; decision 4) ------------------------------
  local run_host=""
  [ -n "$rid" ] && run_host=$(run_field "$rid" '.host')
  if [ -n "$run_host" ] && [ "$run_host" != "$THIS_HOST" ]; then
    log "run originated on '$run_host' (this host '$THIS_HOST') — NOT cleaning locally"
    log "to clean: ssh $run_host '~/.claude/scripts/run-issues/cleanup-run.sh --issue $issue_num --force --yes'"
    [ -d "$run_dir" ] && state_event "$run_dir" "cleanup_done" "pr=$pr_num" "db_dropped=na"
    _release
    return 0
  fi

  if [ -n "$issue_num" ]; then
    log "cleaning local run artefacts for issue #$issue_num"
    # The lock is released first: cleanup-run.sh removes the run-dir and the
    # lock dir itself, so holding it here would race with its own teardown.
    _release
    locked=0
    ( cd "$REPO_ROOT" && "$SCRIPT_DIR/cleanup-run.sh" --repo "$REPO_ROOT" --issue "$issue_num" --force --yes ) || \
      log "cleanup-run.sh reported a non-fatal failure for issue #$issue_num"
  fi

  _release
  return 0
}

# ----- P5: Resolve --------------------------------------------------------
# Conflict resolution is OFF by default (PR_WATCH_ENABLE_CONFLICT_RESOLUTION=0),
# in which case pr_decide never returns REBASE and this is unreachable. When ON
# and the PR is BEHIND/DIRTY we attempt a CONFLICT-FREE rebase onto origin/main
# in the PR's own feature worktree (never main), then force-push and require CI
# to go green again before allowing the merge. There is NO AI conflict
# resolution: any rebase conflict aborts, comments, and asks a human (exit 6).
#
# Returns: 0 rebased + CI green (caller proceeds to merge)
#          6 conflict / CI not green after rebase (human needed)
#          4 not actionable (no worktree, BLOCKED, etc.)
pr_resolve() {
  local pr_num="$1" rid="$2" run_dir="$3" pr_json="$4"

  local worktree branch
  worktree=$(run_field "$rid" '.worktree_path')
  branch=$(run_field "$rid" '.branch')
  if [ -z "$worktree" ] || [ ! -d "$worktree" ]; then
    log "no usable worktree for PR #$pr_num (worktree='$worktree') — cannot rebase"
    [ -n "$run_dir" ] && [ -d "$run_dir" ] && \
      state_event "$run_dir" "pr_watch_skipped" "pr=$pr_num" "reason=no_worktree"
    return 4
  fi
  if [ -z "$branch" ]; then
    log "no branch recorded for PR #$pr_num — cannot rebase"
    return 4
  fi

  log "rebasing PR #$pr_num branch '$branch' onto origin/main in worktree $worktree"

  # All git operations run INSIDE the feature worktree, never on main.
  local main_sha
  if ! (
        cd "$worktree" || exit 99
        git fetch origin main --quiet || exit 98
        git rebase origin/main
      ); then
    # Rebase failed — abort to leave the worktree clean, then ask a human.
    ( cd "$worktree" && git rebase --abort 2>/dev/null || true )
    main_sha=$( cd "$worktree" && git rev-parse origin/main 2>/dev/null || echo "unknown" )

    log "rebase conflict on PR #$pr_num — aborted; asking for human resolution"
    [ -n "$run_dir" ] && [ -d "$run_dir" ] && {
      state_finalize "$run_dir" "pr_conflicted" "rebase_conflict_pr_$pr_num"
      state_event "$run_dir" "pr_conflicted" "pr=$pr_num" "main_sha=$main_sha"
    }
    local body
    body=$(printf '%s\n\n%s\n%s\n%s\n' \
      "PR-valvoja yritti rebasea \`origin/main\` (sha \`$main_sha\`) päälle, mutta kohtasi konfliktin." \
      "Rebase peruttiin (\`git rebase --abort\`), joten haara \`$branch\` on ennallaan." \
      "Ratkaise konflikti manuaalisesti worktreessä \`$worktree\`, pushaa, ja merkkaa PR uudelleen." \
      "PR-valvoja EI ratkaise konflikteja automaattisesti (lukittu päätös 2).")
    ( cd "$REPO_ROOT" && printf '%s' "$body" | gh pr comment "$pr_num" --body-file - ) || \
      log "failed to post conflict comment on PR #$pr_num"
    return 6
  fi

  # Conflict-free rebase succeeded. Publish it and revalidate CI.
  log "rebase clean — force-pushing $branch (--force-with-lease) and revalidating CI"
  if ! ( cd "$worktree" && git push --force-with-lease origin "$branch" ); then
    log "force-push failed for PR #$pr_num after rebase"
    [ -n "$run_dir" ] && [ -d "$run_dir" ] && \
      state_event "$run_dir" "pr_watch_skipped" "pr=$pr_num" "reason=push_failed"
    return 6
  fi
  [ -n "$run_dir" ] && [ -d "$run_dir" ] && \
    state_event "$run_dir" "pr_rebased" "pr=$pr_num"

  if pr_wait_ci_green "$pr_num"; then
    log "CI green after rebase for PR #$pr_num — proceeding to merge"
    return 0
  fi
  log "CI not green after rebase for PR #$pr_num — stopping (human needed)"
  [ -n "$run_dir" ] && [ -d "$run_dir" ] && \
    state_event "$run_dir" "pr_watch_skipped" "pr=$pr_num" "reason=ci_not_green_after_rebase"
  return 6
}

# pr_wait_ci_green <pr-number> — poll `gh pr checks` until all checks pass,
# any fails, or we time out. Returns 0 only when all checks pass.
# Bounded so a stuck/queued pipeline doesn't hang the watcher forever.
pr_wait_ci_green() {
  local pr_num="$1"
  local max_polls="${PR_WATCH_CI_MAX_POLLS:-40}"   # 40 * 15s = 10 min
  local interval="${PR_WATCH_CI_POLL_SECS:-15}"
  local i=0 out rc
  while [ "$i" -lt "$max_polls" ]; do
    set +e
    out=$( cd "$REPO_ROOT" && gh pr checks "$pr_num" 2>/dev/null )
    rc=$?
    set -e
    # gh pr checks: rc 0 = all passed, 8 = some pending, non-zero/other = failure.
    if [ "$rc" = "0" ]; then
      return 0
    fi
    if printf '%s' "$out" | grep -qiE '\bfail|\berror'; then
      return 1
    fi
    i=$((i + 1))
    sleep "$interval"
  done
  return 1
}

# ----- main ---------------------------------------------------------------
if [ "$TARGET" = "scan" ]; then
  found=0
  rc_final=2
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    found=1
    pr_num="${line%% *}"
    rid="${line#* }"
    log "scan: processing PR #$pr_num (run $rid)"
    set +e
    watch_one "$pr_num" "$rid"
    rc=$?
    set -e
    # In scan mode we keep going across PRs; the most "successful" rc wins
    # (0 if any merged/cleaned, otherwise the last informative code).
    if [ "$rc" = "0" ]; then
      rc_final=0
    elif [ "$rc_final" != "0" ]; then
      rc_final="$rc"
    fi
  done < <(scan_candidates)

  [ "$found" = "1" ] || { log "scan: no candidate PRs"; exit 2; }
  exit "$rc_final"
fi

# Named-PR mode.
case "$TARGET" in
  ''|*[!0-9]*) echo "pr-watch: PR target must be a number or 'scan'" >&2; exit 1 ;;
esac
watch_one "$TARGET"
exit $?
