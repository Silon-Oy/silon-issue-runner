#!/usr/bin/env bash
# cleanup-run.sh — tear down stuck /run-issues artefacts in the target repo.
#
# Usage:
#   cleanup-run.sh --list                        # show all run-dirs and their status
#   cleanup-run.sh <run-id>                      # clean a single run
#   cleanup-run.sh --issue <N>                   # clean every run that touched issue N
#   cleanup-run.sh --all                         # clean every non-completed run
#
# Flags:
#   --repo <path>   target repo root (default: $(pwd))
#   --remote <name> when paired with --issue, only clean runs from this remote
#                   (default: all remotes match). Multi-org support (#53).
#   --dry-run       print actions, do not execute
#   --yes / -y      skip confirmation prompts
#   --force         also clean runs whose status is "completed" (those normally
#                   have an open PR — only clean after the PR is merged)
#
# What gets cleaned per run:
#   1. GitHub assignment (gh issue edit --remove-assignee @me) and the
#      needs-human label (gh issue edit --remove-label) so the issue can
#      re-enter auto-run pickup
#   2. Test-env resources (best-effort .claude/provision-test-env.sh cleanup,
#      run BEFORE the worktree removal because the hook lives in the worktree)
#   3. Worktree         (git worktree remove --force)
#   4. Local branch     (git branch -D)
#   5. DB clone         (best-effort drop via db-clone.sh cleanup; non-fatal)
#   6. Archive          (essential artefacts copied to .claude/run-issues-archive/<run-id>/)
#   7. Run-dir          (rm -rf .claude/run-issues/<run-id>)
#   8. Local lock       (rm -rf ~/Library/Application Support/run-issues/locks/<repo-slug>-issue-N.lock;
#                        the name comes from the run's own run.json identity)
#
# Local vs. remote: steps 1 (assignment + label) are REMOTE — they need `gh` and
# talk to GitHub. Steps 2–8 are LOCAL — they touch this machine only. The log
# tags every action [remote]/[local] so a partial teardown is legible at a
# glance, and the exit code reflects it (see below).
#
# Requires `gh` on PATH: the assignment is the only reservation state every
# machine sees, so a cleanup that wipes local state while leaving the issue
# assigned drops it out of auto-run pickup permanently. `gh` is checked up front
# (before the first side effect); over ssh a non-interactive shell lacks the
# Homebrew PATH — prepend it: ssh <host> 'PATH=/opt/homebrew/bin:$PATH cleanup-run.sh …'.
#
# Exit codes:
#   0  all requested runs cleaned, every operation succeeded ("Done.")
#   1  usage error / not a git repo
#   2  no run matched the selection
#   3  gh is not on PATH — refused before any side effect
#   4  partial failure — local state was torn down but one or more GitHub (or
#      local) operations failed; the summary names the counts and exit is non-zero
#      so automation and humans notice instead of trusting a bare "Done."

set -euo pipefail

# ---------- argument parsing ----------
REPO_ROOT="$(pwd)"
DRY_RUN=0
ASSUME_YES=0
FORCE=0
MODE=""
TARGET=""
# Remote filter for --issue mode (empty = match any remote). Per-run lock teardown
# and gh routing read remote from each run's run.json so this flag only narrows
# the SELECTION; the lock removal still uses the right namespace per run.
REMOTE_FILTER=""

usage() {
  sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)    REPO_ROOT="$2"; shift 2 ;;
    --remote)  REMOTE_FILTER="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -y|--yes)  ASSUME_YES=1; shift ;;
    --force)   FORCE=1; shift ;;
    --list)    MODE="list"; shift ;;
    --all)     MODE="all"; shift ;;
    --issue)   MODE="issue"; TARGET="${2:-}"; shift 2 ;;
    -h|--help) usage 0 ;;
    --*)       echo "cleanup-run: unknown flag '$1'" >&2; usage 1 ;;
    *)
      if [ -z "$MODE" ]; then
        MODE="single"
        TARGET="$1"
      else
        echo "cleanup-run: unexpected positional argument '$1'" >&2
        usage 1
      fi
      shift
      ;;
  esac
done

[ -n "$MODE" ] || usage 1
[ -d "$REPO_ROOT/.git" ] || { echo "cleanup-run: not a git repo: $REPO_ROOT" >&2; exit 1; }

RUNS_DIR="$REPO_ROOT/.claude/run-issues"
ARCHIVE_DIR="$REPO_ROOT/.claude/run-issues-archive"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Artefacts worth keeping after a run-dir is torn down. Logs and prompts are
# intentionally excluded — they can contain large/transient content; these
# four capture the canonical state and the agent decisions worth auditing.
ARCHIVE_FILES=(run.json state.jsonl 01-cycle-review.out 03-evolution.out)

# state_event lives in lib/state.sh; we source it so archive_run can record an
# `archived` event into state.jsonl before that file is copied to the archive.
# Sourcing is best-effort: if the lib is missing we degrade to a plain copy.
STATE_LIB="$SCRIPT_DIR/lib/state.sh"
if [ -f "$STATE_LIB" ]; then
  # shellcheck source=lib/state.sh
  . "$STATE_LIB"
fi

# locking.sh owns the lock-path convention (issue-N.lock). We source it so the
# teardown removes the SAME directory that lock_issue created — deriving the
# path here by hand was the original bug (it used issue-N without the .lock
# suffix). Sourcing also defines RUN_ISSUES_LOCK_ROOT (default under
# ~/Library/Application Support/run-issues/locks), honouring any test override.
# locking.sh pulls in git-remote.sh for remote_label, used to name multi-remote
# locks (`<remote>-issue-<N>.lock` for non-origin).
LOCKING_LIB="$SCRIPT_DIR/lib/locking.sh"
if [ -f "$LOCKING_LIB" ]; then
  # shellcheck source=lib/locking.sh
  . "$LOCKING_LIB"
fi

# labels.sh owns label writes (REST, no read:project scope needed). Sourced
# best-effort like the libs above so a missing file degrades rather than dies.
LABELS_LIB="$SCRIPT_DIR/lib/labels.sh"
if [ -f "$LABELS_LIB" ]; then
  # shellcheck source=lib/labels.sh
  . "$LABELS_LIB"
fi

# ---------- helpers ----------

# archive_run <run-id> <run-dir> — copy essential artefacts to
# .claude/run-issues-archive/<run-id>/ before the run-dir is removed. Records
# an `archived` event into state.jsonl first (so the event lands in the
# archived copy). Best-effort: missing files are skipped, failures are
# non-fatal so they never block the teardown.
archive_run() {
  local rid="$1" run_dir="$2"
  local dest="$ARCHIVE_DIR/$rid"

  if [ "$DRY_RUN" = "1" ]; then
    printf '  [dry] archive: %s -> %s\n' "${ARCHIVE_FILES[*]}" "$dest"
    return 0
  fi

  # Record the event into the live state.jsonl so the archived copy carries it.
  if [ -f "$run_dir/state.jsonl" ] && type state_event >/dev/null 2>&1; then
    state_event "$run_dir" "archived" "dest=$dest" 2>/dev/null || true
  fi

  mkdir -p "$dest" 2>/dev/null || { printf '    (archive dir create failed, skipping)\n' >&2; return 0; }
  local f copied=0
  for f in "${ARCHIVE_FILES[@]}"; do
    if [ -f "$run_dir/$f" ]; then
      cp -p "$run_dir/$f" "$dest/$f" 2>/dev/null && copied=$((copied + 1))
    fi
  done
  printf '  archive: %s file(s) -> %s\n' "$copied" "$dest"
}

run_field() {
  # run_field <run-id> <jq-path> — prints empty string if file/key missing.
  local rid="$1" path="$2"
  local rj="$RUNS_DIR/$rid/run.json"
  [ -f "$rj" ] || { printf ''; return; }
  jq -r "$path // empty" "$rj" 2>/dev/null || printf ''
}

confirm() {
  [ "$ASSUME_YES" = "1" ] && return 0
  printf '%s [y/N]: ' "$1"
  local ans=""
  read -r ans || true
  [[ "$ans" =~ ^[Yy]$ ]]
}

do_or_dry() {
  # do_or_dry <scope> <label> <cmd...>
  #   scope = local | remote   (tags the log line so a partial teardown reads at
  #                             a glance: local artefacts gone but GitHub state
  #                             untouched, or the reverse)
  # Runs <cmd...> unless --dry-run and RETURNS the command's exit status (0 in
  # dry-run) so the CALLER can tally failures. A non-zero status prints the
  # non-fatal notice but never aborts — the rest of the teardown keeps running.
  local scope="$1" label="$2"; shift 2
  if [ "$DRY_RUN" = "1" ]; then
    printf '  [dry] [%s] %s: %s\n' "$scope" "$label" "$*"
    return 0
  fi
  printf '  [%s] %s: %s\n' "$scope" "$label" "$*"
  local rc=0
  "$@" || rc=$?
  [ "$rc" -eq 0 ] || printf '    (non-fatal failure, continuing)\n' >&2
  return "$rc"
}

# require_gh — fail before the FIRST side effect if the GitHub CLI is missing.
# The remote steps (unassign, remove needs-human) are the whole point of a
# cleanup: the assignment is the only reservation state every machine sees, so a
# run that wipes the worktree/branch/lock while leaving the issue assigned drops
# it out of auto-run pickup permanently — 25 issues were stranded exactly this
# way (issue #31). A partial teardown is worse than none, because it destroys the
# local state a retry would need. Same posture as the orchestrator's S0 gate.
# --dry-run performs no side effects, so it never requires gh.
require_gh() {
  [ "$DRY_RUN" = "1" ] && return 0
  command -v gh >/dev/null 2>&1 && return 0
  {
    echo "cleanup-run: gh is not on PATH — GitHub operations (unassign, unlabel) cannot run."
    echo "  Refusing before any teardown: local state a retry would need must not be destroyed"
    echo "  while the issue stays assigned and out of auto-run pickup."
    echo "  Over ssh a non-interactive shell lacks the Homebrew PATH — prepend it:"
    echo "    ssh <host> 'PATH=/opt/homebrew/bin:\$PATH cleanup-run.sh …'"
  } >&2
  exit 3
}

# ---------- listing ----------
list_runs() {
  shopt -s nullglob
  local any=0
  local d
  printf 'Runs under %s:\n' "$RUNS_DIR"
  for d in "$RUNS_DIR"/*/; do
    any=1
    local rid status issue branch
    rid=$(basename "$d")
    status=$(run_field "$rid" '.status')
    issue=$(run_field "$rid" '.issue_number')
    branch=$(run_field "$rid" '.branch')
    printf '  %-40s  issue=%-6s  status=%-18s  branch=%s\n' \
      "$rid" "${issue:-?}" "${status:-unknown}" "${branch:-?}"
  done
  [ "$any" = "0" ] && printf '  (none)\n'
}

# ---------- per-run cleanup ----------
cleanup_run() {
  local rid="$1"
  local run_dir="$RUNS_DIR/$rid"

  if [ ! -d "$run_dir" ]; then
    echo "cleanup-run: run-dir not found: $run_dir" >&2
    LOCAL_FAIL_COUNT=$((LOCAL_FAIL_COUNT + 1))
    return 1
  fi

  # Snapshot the fleet-wide failure tallies so we can tell, at the end of THIS
  # run's teardown, whether it completed with zero failed operations (→ RUNS_OK).
  local pre_gh_fail="$GH_FAIL_COUNT" pre_local_fail="$LOCAL_FAIL_COUNT"

  local status issue_num branch worktree_path db_clone provision_env remote owner_repo run_slug
  status=$(run_field "$rid" '.status')
  issue_num=$(run_field "$rid" '.issue_number')
  branch=$(run_field "$rid" '.branch')
  worktree_path=$(run_field "$rid" '.worktree_path')
  db_clone=$(run_field "$rid" '.db_clone')
  provision_env=$(run_field "$rid" '.provision_test_env')
  # Multi-remote: empty -> "origin" (legacy run.json predating the field).
  remote=$(run_field "$rid" '.remote')
  [ -n "$remote" ] || remote="origin"
  owner_repo=$(run_field "$rid" '.owner_repo')
  # Repo namespacing (issue #67): the slug this run recorded. Empty = a run
  # created before #67, whose lock carries the legacy repo-agnostic name.
  run_slug=$(run_field "$rid" '.repo_slug')

  if [ "$status" = "completed" ] && [ "$FORCE" != "1" ]; then
    printf 'SKIP %s — status=completed (PR likely open; pass --force to clean anyway)\n' "$rid"
    RUNS_SKIPPED=$((RUNS_SKIPPED + 1))
    return 0
  fi

  printf '\nCleaning %s (status=%s issue=%s remote=%s):\n' \
    "$rid" "${status:-unknown}" "${issue_num:-?}" "$remote"

  # Route gh calls to the right org for non-origin runs.
  local repo_args=""
  [ -n "$owner_repo" ] && repo_args="--repo $owner_repo"

  if [ -n "$issue_num" ]; then
    # The remote ops run in a subshell because `gh` (and labels_remove's
    # {owner}/{repo} placeholder) infer the repo from the cwd on origin runs.
    # A subshell cannot mutate the parent's GH_FAIL_COUNT, so it tallies its own
    # failures and hands the count back as its exit status; the parent folds it
    # in. `|| rf=$?` captures that status without tripping `set -e`.
    local rf=0
    # shellcheck disable=SC2086
    (
      cd "$REPO_ROOT"
      f=0
      do_or_dry remote "unassign" gh issue edit "$issue_num" $repo_args --remove-assignee "@me" || f=$((f + 1))
      # Drop the needs-human label so the issue re-enters auto-run pickup once
      # unassigned. Without this the poll re-surfaces the issue as no:assignee
      # but the stale label lingers. labels_remove treats an absent label (404)
      # as success, so this only counts as a failure on a REAL error — a 403
      # (missing read:project scope, the silent breakage that stalled the
      # pipeline for weeks elsewhere) or a 127 (gh not on PATH).
      do_or_dry remote "unlabel" labels_remove "$owner_repo" "$issue_num" needs-human || f=$((f + 1))
      exit "$f"
    ) || rf=$?
    GH_FAIL_COUNT=$((GH_FAIL_COUNT + rf))
  fi

  # Tear down per-run provisioned test-env resources (best-effort, idempotent).
  # The hook lives INSIDE the worktree, so this MUST run before the worktree is
  # removed below — unlike db-clone.sh, which lives in the orchestrator's script
  # dir and survives worktree removal. Gated on the run.json provision_test_env
  # field (set by orchestrate.sh S7c on a successful provision). The run-id is
  # the teardown handle; the hook reconstructs the resource name from it
  # (DROP ... IF EXISTS), so a non-zero rc is non-fatal — we report and continue.
  if [ -n "$provision_env" ]; then
    local prov_hook="$worktree_path/.claude/provision-test-env.sh"
    if [ -n "$worktree_path" ] && [ -x "$prov_hook" ]; then
      if [ "$DRY_RUN" = "1" ]; then
        printf '  [dry] provision-test-env: %s cleanup %s\n' "$prov_hook" "$rid"
      else
        printf '  [local] provision-test-env: tearing down resources for %s\n' "$rid"
        if ! ( cd "$worktree_path" && "$prov_hook" cleanup "$rid" ); then
          printf '  ! provision-test-env cleanup failed for %s — tear down manually.\n' "$rid" >&2
          LOCAL_FAIL_COUNT=$((LOCAL_FAIL_COUNT + 1))
        fi
      fi
    else
      printf '  [local] provision-test-env: hook gone (worktree removed?) — skipping teardown for %s\n' "$rid"
    fi
  fi

  # Local git ops run via `git -C "$REPO_ROOT"` rather than a `( cd … )` subshell
  # so their failure count reaches the parent's LOCAL_FAIL_COUNT — a subshell
  # cannot mutate it.
  if [ -n "$worktree_path" ] && [ -d "$worktree_path" ]; then
    do_or_dry local "worktree" git -C "$REPO_ROOT" worktree remove --force "$worktree_path" \
      || LOCAL_FAIL_COUNT=$((LOCAL_FAIL_COUNT + 1))
  elif [ -n "$worktree_path" ]; then
    printf '  [local] worktree: %s already gone\n' "$worktree_path"
  fi

  if [ -n "$branch" ]; then
    # `git branch -D` errors if the branch is missing. That is the expected
    # idempotent case, not a failure — check existence first so a re-run (or a
    # run whose branch was already deleted) does not inflate the failure count.
    if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
      do_or_dry local "branch" git -C "$REPO_ROOT" branch -D "$branch" \
        || LOCAL_FAIL_COUNT=$((LOCAL_FAIL_COUNT + 1))
    else
      printf '  [local] branch: %s already gone\n' "$branch"
    fi
  fi

  # Drop the cloned DB (best-effort). db-clone.sh cleanup is opt-in and
  # idempotent; a non-zero rc must not abort the rest of the teardown, so we
  # report it and continue. We pass the run-id as the slug — the same value
  # the orchestrator used as the slug when cloning (orchestrate.sh S5).
  if [ -n "$db_clone" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      printf '  [dry] db-clone: %s cleanup %s %s\n' "$SCRIPT_DIR/db-clone/db-clone.sh" "$REPO_ROOT" "$rid"
    else
      printf '  [local] db-clone: dropping clone %s\n' "$db_clone"
      if ! "$SCRIPT_DIR/db-clone/db-clone.sh" cleanup "$REPO_ROOT" "$rid"; then
        printf '  ! DB clone drop failed for %s — drop manually with backend tooling.\n' "$db_clone" >&2
        LOCAL_FAIL_COUNT=$((LOCAL_FAIL_COUNT + 1))
      fi
    fi
  fi

  archive_run "$rid" "$run_dir"

  do_or_dry local "run-dir" rm -rf "$run_dir" || LOCAL_FAIL_COUNT=$((LOCAL_FAIL_COUNT + 1))

  if [ -n "$issue_num" ]; then
    # Remove the lock this run actually holds — derived from its OWN recorded
    # identity (repo slug + remote), never rebuilt from the issue number alone.
    local lock_dirs=()
    lock_dirs+=("$(_lock_dir "$issue_num" "$remote" "$run_slug")")

    # A pre-#67 run records no slug, so the line above targets its legacy
    # repo-agnostic lock. But a NEW-code caller that handed this teardown to us
    # (auto-clean.sh takes the per-issue lock before delegating) holds the
    # repo-namespaced name, which would then leak. Add it: removing a
    # repo-namespaced lock is safe by construction — it can only belong to this
    # repo, so there is no cross-repo theft in either direction.
    if [ -z "$run_slug" ]; then
      local derived_slug
      derived_slug=$(repo_slug "$REPO_ROOT" "$remote")
      [ -n "$derived_slug" ] && lock_dirs+=("$(_lock_dir "$issue_num" "$remote" "$derived_slug")")
    fi

    local lock_dir
    for lock_dir in "${lock_dirs[@]}"; do
      if [ -d "$lock_dir" ]; then
        do_or_dry local "lock" rm -rf "$lock_dir" || LOCAL_FAIL_COUNT=$((LOCAL_FAIL_COUNT + 1))
      else
        printf '  [local] lock: %s not held\n' "$(basename "$lock_dir" .lock)"
      fi
    done
  fi

  # This run's teardown is fully clean iff it added no failures to either tally.
  if [ "$GH_FAIL_COUNT" -eq "$pre_gh_fail" ] && [ "$LOCAL_FAIL_COUNT" -eq "$pre_local_fail" ]; then
    RUNS_OK=$((RUNS_OK + 1))
  fi
}

# ---------- selection ----------
select_runs() {
  # Emits one run-id per line on stdout. bash 3.2 compatible — no mapfile,
  # no associative arrays.
  shopt -s nullglob
  local d rid n s r
  case "$MODE" in
    single)
      [ -n "$TARGET" ] && printf '%s\n' "$TARGET"
      ;;
    issue)
      [ -n "$TARGET" ] || { echo "cleanup-run: --issue requires a number" >&2; exit 1; }
      for d in "$RUNS_DIR"/*/; do
        rid=$(basename "$d")
        n=$(run_field "$rid" '.issue_number')
        [ "$n" = "$TARGET" ] || continue
        if [ -n "$REMOTE_FILTER" ]; then
          r=$(run_field "$rid" '.remote')
          [ -n "$r" ] || r="origin"
          [ "$r" = "$REMOTE_FILTER" ] || continue
        fi
        printf '%s\n' "$rid"
      done
      ;;
    all)
      for d in "$RUNS_DIR"/*/; do
        rid=$(basename "$d")
        s=$(run_field "$rid" '.status')
        if [ "$s" != "completed" ] || [ "$FORCE" = "1" ]; then
          printf '%s\n' "$rid"
        fi
      done
      ;;
  esac
}

# ---------- main ----------
if [ "$MODE" = "list" ]; then
  list_runs
  exit 0
fi

# Fail before selection (read-only) and before any teardown: every non-list mode
# performs GitHub side effects and must not start a partial cleanup without gh.
require_gh

SELECTED=()
while IFS= read -r line; do
  [ -n "$line" ] && SELECTED+=("$line")
done < <(select_runs)

if [ "${#SELECTED[@]}" -eq 0 ]; then
  case "$MODE" in
    single) echo "cleanup-run: no run matches '$TARGET'" >&2 ;;
    issue)  echo "cleanup-run: no runs found for issue #$TARGET" >&2 ;;
    all)    echo "cleanup-run: no non-completed runs to clean" >&2 ;;
  esac
  exit 2
fi

echo "Selected runs:"
for r in "${SELECTED[@]}"; do
  s=$(run_field "$r" '.status')
  i=$(run_field "$r" '.issue_number')
  printf '  %s  (issue=%s status=%s)\n' "$r" "${i:-?}" "${s:-unknown}"
done

if ! confirm "Proceed with cleanup?"; then
  echo "Aborted."
  exit 0
fi

# Fleet-wide tallies. cleanup_run runs in THIS shell (not a subshell), so these
# globals accumulate across every selected run. Separating remote (GitHub) from
# local failures is the crux of issue #31: a run that wipes local state while a
# GitHub op fails must not report a bare "Done.".
GH_FAIL_COUNT=0
LOCAL_FAIL_COUNT=0
RUNS_OK=0
RUNS_SKIPPED=0
RUNS_TOTAL=${#SELECTED[@]}

for r in "${SELECTED[@]}"; do
  cleanup_run "$r" || true
done

echo
if [ "$GH_FAIL_COUNT" -eq 0 ] && [ "$LOCAL_FAIL_COUNT" -eq 0 ]; then
  echo "Done."
  exit 0
fi

# Partial failure: local state was (at least partly) torn down but some
# operation failed. Report the split and exit non-zero so automation and humans
# notice instead of trusting a bare "Done." — the bug this whole change fixes.
attempted=$((RUNS_TOTAL - RUNS_SKIPPED))
{
  printf 'Done with failures: %d/%d run(s) fully cleaned, %d GitHub op(s) failed, %d local op(s) failed.\n' \
    "$RUNS_OK" "$attempted" "$GH_FAIL_COUNT" "$LOCAL_FAIL_COUNT"
  [ "$RUNS_SKIPPED" -gt 0 ] && printf '  (%d completed run(s) skipped; pass --force to include them.)\n' "$RUNS_SKIPPED"
  if [ "$GH_FAIL_COUNT" -gt 0 ]; then
    printf '  Some issues may remain assigned and out of auto-run pickup — inspect the [remote] lines above.\n'
  fi
} >&2
exit 4
