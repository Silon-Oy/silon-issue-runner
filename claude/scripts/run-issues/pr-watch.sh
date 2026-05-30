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
#                                        (never main) with mandatory CI
#                                        revalidation. A conflict-free rebase
#                                        proceeds directly; a conflicting rebase
#                                        is handed to an AI agent that resolves
#                                        the conflict IN THE WORKTREE. Either way
#                                        CI must go green again before the merge.
#                                        If the AI cannot resolve durably, or CI
#                                        stays red, the rebase aborts and a human
#                                        is asked (exit 6).
#   PR_WATCH_CONFLICT_TIMEOUT            default 1800 — wall-clock budget (s) for
#                                        the AI conflict-resolution claude call.
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
#   6  conflict needs a human (AI could not resolve / CI red — rebase aborted or
#      left for inspection, PR commented)
#   7  post-merge migration failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/locking.sh
. "$SCRIPT_DIR/lib/locking.sh"
# shellcheck source=lib/state.sh
. "$SCRIPT_DIR/lib/state.sh"
# shellcheck source=lib/pr-watch-lib.sh
. "$SCRIPT_DIR/lib/pr-watch-lib.sh"
# shellcheck source=lib/claude-call.sh
. "$SCRIPT_DIR/lib/claude-call.sh"
# shellcheck source=lib/github-app-auth.sh
# Opt-in GitHub App identity (same env vars as the orchestrator). gha_with_token
# is a pass-through when App mode is off, so wrapping every gh call here is
# regression-free for repos that don't configure the App.
#
# The watcher SHOULD use the same env file (~/.config/run-issues/env) as the
# orchestrator: it's a LaunchAgent that does not inherit the interactive shell,
# so we source the machine-local env if present — mirroring orchestrate.sh's
# source_machine_env. (We do not factor this into a shared helper yet because
# orchestrate.sh's version logs via its own `log` and we want the watcher's
# behaviour identical without coupling the two.)
RUN_ISSUES_ENV_FILE="${RUN_ISSUES_ENV_FILE:-$HOME/.config/run-issues/env}"
if [ -f "$RUN_ISSUES_ENV_FILE" ]; then
  set +eu
  # shellcheck disable=SC1090
  . "$RUN_ISSUES_ENV_FILE"
  set -eu
fi
# shellcheck source=lib/github-app-auth.sh
. "$SCRIPT_DIR/lib/github-app-auth.sh"

PR_WATCH_AUTO="${PR_WATCH_AUTO:-0}"
PR_WATCH_ENABLE_CONFLICT_RESOLUTION="${PR_WATCH_ENABLE_CONFLICT_RESOLUTION:-0}"
PR_WATCH_CONFLICT_TIMEOUT="${PR_WATCH_CONFLICT_TIMEOUT:-1800}"
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
        gha_with_token gh pr view "$pr_num" \
          --json state,mergeable,mergeStateStatus,labels,statusCheckRollup,headRefName,baseRefName 2>/dev/null
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
  # Merge as the App so the "Merged by" attribution on the PR is <app>[bot].
  if ! ( cd "$REPO_ROOT" && gha_with_token gh pr merge "$pr_num" --rebase --delete-branch ); then
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
# and the PR is BEHIND/DIRTY we rebase onto the PR's base branch (origin/<baseRefName>) in its own feature
# worktree (never main):
#   - a CONFLICT-FREE rebase is published directly, then CI is revalidated;
#   - a CONFLICTING rebase is handed to an AI agent (pr_resolve_conflict_ai)
#     which resolves the conflict in the worktree and completes the rebase.
# Either path force-pushes the rebased branch and REQUIRES CI to go green again
# before the merge is allowed — CI is the safety gate that catches a wrong AI
# resolution. If the AI cannot resolve durably, or CI stays red, the rebase is
# aborted/left for inspection, the PR is commented, and a human is asked (exit 6).
#
# Returns: 0 rebased + CI green (caller proceeds to merge)
#          6 conflict unresolved / CI not green after rebase (human needed)
#          4 not actionable (no worktree, fetch failed, BLOCKED, etc.)
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

  # Rebase onto the PR's OWN base branch (e.g. a "twenty" integration branch),
  # not a hardcoded main — gh reports it as baseRefName. Fallback to main keeps
  # behaviour stable for older mocks / payloads without the field.
  local base_ref
  base_ref=$(jq -r '.baseRefName // "main"' <<<"$pr_json")

  log "rebasing PR #$pr_num branch '$branch' onto origin/$base_ref in worktree $worktree"

  # Fetch first so a network/auth failure is distinguishable from a conflict
  # (transient — retry next poll, do not claim a conflict or comment).
  # When App mode is on we pass the App token via http.extraheader so the
  # fetch credential matches the eventual push credential (otherwise a repo
  # configured to only accept the App's PAT-equivalent would refuse fetch).
  local _watch_auth_header=""
  if _h=$(gha_git_push_header 2>/dev/null); then
    _watch_auth_header="$_h"
  fi
  if [ -n "$_watch_auth_header" ]; then
    if ! ( cd "$worktree" && git -c "http.extraheader=$_watch_auth_header" fetch origin "$base_ref" --quiet ); then
      log "git fetch origin $base_ref failed for PR #$pr_num — retrying next poll"
      [ -n "$run_dir" ] && [ -d "$run_dir" ] && \
        state_event "$run_dir" "pr_watch_skipped" "pr=$pr_num" "reason=fetch_failed"
      _watch_auth_header=""
      return 4
    fi
  else
    if ! ( cd "$worktree" && git fetch origin "$base_ref" --quiet ); then
      log "git fetch origin $base_ref failed for PR #$pr_num — retrying next poll"
      [ -n "$run_dir" ] && [ -d "$run_dir" ] && \
        state_event "$run_dir" "pr_watch_skipped" "pr=$pr_num" "reason=fetch_failed"
      return 4
    fi
  fi
  _watch_auth_header=""

  # Attempt the rebase INSIDE the feature worktree, never on the base branch.
  local rebase_rc=0
  ( cd "$worktree" && git rebase "origin/$base_ref" ) || rebase_rc=$?

  if [ "$rebase_rc" -eq 0 ]; then
    # Conflict-free rebase. Publish it and revalidate CI.
    _pr_publish_and_revalidate "$pr_num" "$rid" "$run_dir" "$worktree" "$branch" "$base_ref"
    return $?
  fi

  # Conflict. Hand it to the AI agent to resolve in the worktree.
  log "rebase conflict on PR #$pr_num — attempting AI conflict resolution in $worktree"
  [ -n "$run_dir" ] && [ -d "$run_dir" ] && \
    state_event "$run_dir" "pr_conflict_resolution_started" "pr=$pr_num"

  if pr_resolve_conflict_ai "$pr_num" "$rid" "$run_dir" "$worktree" "$branch" "$base_ref"; then
    log "AI resolved conflicts for PR #$pr_num — rebase complete, publishing + revalidating CI"
    [ -n "$run_dir" ] && [ -d "$run_dir" ] && \
      state_event "$run_dir" "pr_conflict_resolved" "pr=$pr_num"
    _pr_publish_and_revalidate "$pr_num" "$rid" "$run_dir" "$worktree" "$branch" "$base_ref"
    return $?
  fi

  # AI could not produce a clean, completed rebase — abort and ask a human.
  _pr_abort_to_human "$pr_num" "$rid" "$run_dir" "$worktree" "$branch" "$base_ref"
  return 6
}

# pr_resolve_conflict_ai <pr-number> <run-id> <run-dir> <worktree> <branch>
# Invokes the AI agent to resolve an in-progress rebase conflict in the feature
# worktree and complete the rebase. The agent runs with the worktree as CWD.
# Returns 0 only if the worktree ends in a clean, completed-rebase state
# (verified independently of the agent's self-report); non-zero otherwise.
pr_resolve_conflict_ai() {
  local pr_num="$1" rid="$2" run_dir="$3" worktree="$4" branch="$5" base_ref="${6:-main}"

  local base_sha conflict_files
  base_sha=$( cd "$worktree" && git rev-parse --short "origin/$base_ref" 2>/dev/null || echo "unknown" )
  conflict_files=$( cd "$worktree" && git diff --name-only --diff-filter=U 2>/dev/null )
  [ -n "$conflict_files" ] || conflict_files="(ei listattavissa — tarkista \`git status\`)"

  # The .out/.exit files live in the run-dir when available, else a scratch dir.
  local ai_out_dir="$run_dir"
  if [ -z "$ai_out_dir" ] || [ ! -d "$ai_out_dir" ]; then
    ai_out_dir=$(mktemp -d -t pr-watch-conflict.XXXXXX)
  fi

  local prompt_file="$ai_out_dir/04-conflict-resolution.prompt"
  render_prompt "$SCRIPT_DIR/prompts/04-conflict-resolution.md" "$prompt_file" \
    PR_NUMBER="$pr_num" \
    BRANCH="$branch" \
    BASE_REF="$base_ref" \
    BASE_SHA="$base_sha" \
    CONFLICT_FILES="$conflict_files"

  # Run the agent with the worktree as CWD (it edits files + drives git there)
  # and a dedicated wall-clock budget so a wedged resolution can't hang the
  # watcher. We do NOT trust the agent's exit code or self-report — the
  # worktree state below is the source of truth.
  local crc=0
  (
    cd "$worktree" || exit 99
    RUN_ISSUES_CLAUDE_TIMEOUT="$PR_WATCH_CONFLICT_TIMEOUT" \
      call_claude "$ai_out_dir" "04-conflict-resolution" "$prompt_file"
  ) || crc=$?
  log "AI conflict-resolution call for PR #$pr_num returned rc=$crc"

  if _conflict_resolution_clean "$worktree" "$base_ref"; then
    return 0
  fi
  log "AI conflict resolution did not leave a clean, completed rebase for PR #$pr_num"
  return 1
}

# _conflict_resolution_clean <worktree> [base-ref] — 0 iff the worktree is in a
# clean, fully-rebased state: no rebase in progress, no unmerged paths, a clean
# working tree, and HEAD descends from origin/<base-ref> (the rebase landed).
_conflict_resolution_clean() {
  local wt="$1" base_ref="${2:-main}"
  (
    cd "$wt" || exit 1
    local rebase_merge rebase_apply
    rebase_merge=$(git rev-parse --git-path rebase-merge 2>/dev/null || echo "")
    rebase_apply=$(git rev-parse --git-path rebase-apply 2>/dev/null || echo "")
    [ -n "$rebase_merge" ] && [ -d "$rebase_merge" ] && exit 1
    [ -n "$rebase_apply" ] && [ -d "$rebase_apply" ] && exit 1
    # Any unmerged path (UU/AA/DD/AU/UA/DU/UD) means conflicts remain.
    git diff --name-only --diff-filter=U 2>/dev/null | grep -q . && exit 1
    # Working tree + index must be clean (rebase committed everything).
    git status --porcelain 2>/dev/null | grep -q . && exit 1
    # HEAD must descend from origin/<base-ref>, i.e. the rebase landed on the new base.
    git merge-base --is-ancestor "origin/$base_ref" HEAD || exit 1
    exit 0
  )
}

# _pr_publish_and_revalidate <pr-number> <run-id> <run-dir> <worktree> <branch> [base-ref]
# Force-pushes the rebased branch and revalidates CI. Shared by the clean-rebase
# and AI-resolved paths so the CI gate is identical on both.
# Returns 0 (CI green, caller proceeds to merge) or 6 (push failed / CI red).
_pr_publish_and_revalidate() {
  local pr_num="$1" rid="$2" run_dir="$3" worktree="$4" branch="$5" base_ref="${6:-main}"

  log "rebase landed — force-pushing $branch (--force-with-lease) and revalidating CI"
  # Same token-via-extraheader pattern as the orchestrator's push. The header
  # is captured to a local and never echoed; --force-with-lease still consults
  # the local ref the worktree fetched, so there is no extra leak surface.
  local _pub_auth_header=""
  if _h2=$(gha_git_push_header 2>/dev/null); then
    _pub_auth_header="$_h2"
  fi
  local push_ok=0
  if [ -n "$_pub_auth_header" ]; then
    if ( cd "$worktree" && git -c "http.extraheader=$_pub_auth_header" push --force-with-lease origin "$branch" ); then
      push_ok=1
    fi
  else
    if ( cd "$worktree" && git push --force-with-lease origin "$branch" ); then
      push_ok=1
    fi
  fi
  _pub_auth_header=""
  if [ "$push_ok" = "0" ]; then
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
  [ -n "$run_dir" ] && [ -d "$run_dir" ] && {
    state_finalize "$run_dir" "pr_conflicted" "ci_red_after_resolution_pr_$pr_num"
    state_event "$run_dir" "pr_watch_skipped" "pr=$pr_num" "reason=ci_not_green_after_rebase"
  }
  local body
  body=$(printf '%s\n\n%s\n%s\n' \
    "PR-valvoja rebasesi haaran \`$branch\` \`origin/$base_ref\`:n päälle (konfliktit ratkaistiin AI:lla, jos niitä oli), mutta **CI ei vihreytynyt** uudelleenajossa." \
    "Haara on pushattu rebasetussa tilassa — tarkista CI-lokit ja ratkaisun oikeellisuus worktreessä \`$worktree\`." \
    "PR:ää **ei mergetty**. Korjaa ja merkkaa PR uudelleen, tai aja valvoja uudelleen.")
  ( cd "$REPO_ROOT" && printf '%s' "$body" | gha_with_token gh pr comment "$pr_num" --body-file - ) || \
    log "failed to post ci-red comment on PR #$pr_num"
  return 6
}

# _pr_abort_to_human <pr-number> <run-id> <run-dir> <worktree> <branch> [base-ref]
# Aborts any in-progress rebase to leave the branch unchanged, records the
# conflicted state, and comments the PR asking for human resolution. Used when
# the AI agent could not produce a clean, completed rebase.
_pr_abort_to_human() {
  local pr_num="$1" rid="$2" run_dir="$3" worktree="$4" branch="$5" base_ref="${6:-main}"

  ( cd "$worktree" && git rebase --abort 2>/dev/null || true )
  local base_sha
  base_sha=$( cd "$worktree" && git rev-parse "origin/$base_ref" 2>/dev/null || echo "unknown" )

  log "AI could not resolve conflict on PR #$pr_num — rebase aborted; asking for human resolution"
  [ -n "$run_dir" ] && [ -d "$run_dir" ] && {
    state_finalize "$run_dir" "pr_conflicted" "rebase_conflict_pr_$pr_num"
    state_event "$run_dir" "pr_conflicted" "pr=$pr_num" "base_sha=$base_sha"
  }
  local body
  body=$(printf '%s\n\n%s\n%s\n%s\n' \
    "PR-valvoja yritti rebasea \`origin/$base_ref\` (sha \`$base_sha\`) päälle ja ratkaista konfliktin AI-agentilla, mutta kestävää ratkaisua ei syntynyt." \
    "Rebase peruttiin (\`git rebase --abort\`), joten haara \`$branch\` on ennallaan." \
    "Ratkaise konflikti manuaalisesti worktreessä \`$worktree\`, pushaa, ja merkkaa PR uudelleen." \
    "(AI-konfliktinratkaisu on päällä \`PR_WATCH_ENABLE_CONFLICT_RESOLUTION=1\` — tämä konflikti vaati ihmisen.)")
  ( cd "$REPO_ROOT" && printf '%s' "$body" | gha_with_token gh pr comment "$pr_num" --body-file - ) || \
    log "failed to post conflict comment on PR #$pr_num"
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
    out=$( cd "$REPO_ROOT" && gha_with_token gh pr checks "$pr_num" 2>/dev/null )
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
