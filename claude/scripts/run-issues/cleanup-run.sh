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
#   8. Local lock       (rm -rf ~/Library/Application Support/run-issues/locks/issue-N.lock)

set -euo pipefail

# ---------- argument parsing ----------
REPO_ROOT="$(pwd)"
DRY_RUN=0
ASSUME_YES=0
FORCE=0
MODE=""
TARGET=""

usage() {
  sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)    REPO_ROOT="$2"; shift 2 ;;
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
LOCKING_LIB="$SCRIPT_DIR/lib/locking.sh"
if [ -f "$LOCKING_LIB" ]; then
  # shellcheck source=lib/locking.sh
  . "$LOCKING_LIB"
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
  # do_or_dry <label> <cmd...>
  local label="$1"; shift
  if [ "$DRY_RUN" = "1" ]; then
    printf '  [dry] %s: %s\n' "$label" "$*"
  else
    printf '  %s: %s\n' "$label" "$*"
    "$@" || printf '    (non-fatal failure, continuing)\n' >&2
  fi
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
    return 1
  fi

  local status issue_num branch worktree_path db_clone provision_env
  status=$(run_field "$rid" '.status')
  issue_num=$(run_field "$rid" '.issue_number')
  branch=$(run_field "$rid" '.branch')
  worktree_path=$(run_field "$rid" '.worktree_path')
  db_clone=$(run_field "$rid" '.db_clone')
  provision_env=$(run_field "$rid" '.provision_test_env')

  if [ "$status" = "completed" ] && [ "$FORCE" != "1" ]; then
    printf 'SKIP %s — status=completed (PR likely open; pass --force to clean anyway)\n' "$rid"
    return 0
  fi

  printf '\nCleaning %s (status=%s issue=%s):\n' \
    "$rid" "${status:-unknown}" "${issue_num:-?}"

  if [ -n "$issue_num" ]; then
    (
      cd "$REPO_ROOT"
      do_or_dry "unassign" gh issue edit "$issue_num" --remove-assignee "@me"
      # Drop the needs-human label so the issue re-enters auto-run pickup once
      # unassigned. Without this the poll re-surfaces the issue as no:assignee
      # but the stale label lingers. Best-effort: do_or_dry swallows the
      # non-fatal failure when the label is absent.
      do_or_dry "unlabel" gh issue edit "$issue_num" --remove-label needs-human
    )
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
        printf '  provision-test-env: tearing down resources for %s\n' "$rid"
        if ! ( cd "$worktree_path" && "$prov_hook" cleanup "$rid" ); then
          printf '  ! provision-test-env cleanup failed for %s — tear down manually.\n' "$rid" >&2
        fi
      fi
    else
      printf '  provision-test-env: hook gone (worktree removed?) — skipping teardown for %s\n' "$rid"
    fi
  fi

  if [ -n "$worktree_path" ] && [ -d "$worktree_path" ]; then
    (
      cd "$REPO_ROOT"
      do_or_dry "worktree" git worktree remove --force "$worktree_path"
    )
  elif [ -n "$worktree_path" ]; then
    printf '  worktree: %s already gone\n' "$worktree_path"
  fi

  if [ -n "$branch" ]; then
    (
      cd "$REPO_ROOT"
      # `git branch -D` errors if the branch is missing — that's fine here.
      do_or_dry "branch" git branch -D "$branch"
    )
  fi

  # Drop the cloned DB (best-effort). db-clone.sh cleanup is opt-in and
  # idempotent; a non-zero rc must not abort the rest of the teardown, so we
  # report it and continue. We pass the run-id as the slug — the same value
  # the orchestrator used as the slug when cloning (orchestrate.sh S5).
  if [ -n "$db_clone" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      printf '  [dry] db-clone: %s cleanup %s %s\n' "$SCRIPT_DIR/db-clone/db-clone.sh" "$REPO_ROOT" "$rid"
    else
      printf '  db-clone: dropping clone %s\n' "$db_clone"
      if ! "$SCRIPT_DIR/db-clone/db-clone.sh" cleanup "$REPO_ROOT" "$rid"; then
        printf '  ! DB clone drop failed for %s — drop manually with backend tooling.\n' "$db_clone" >&2
      fi
    fi
  fi

  archive_run "$rid" "$run_dir"

  do_or_dry "run-dir" rm -rf "$run_dir"

  if [ -n "$issue_num" ]; then
    local lock_dir
    lock_dir="$(_lock_dir "$issue_num")"
    if [ -d "$lock_dir" ]; then
      do_or_dry "lock" rm -rf "$lock_dir"
    else
      printf '  lock: issue-%s not held\n' "$issue_num"
    fi
  fi
}

# ---------- selection ----------
select_runs() {
  # Emits one run-id per line on stdout. bash 3.2 compatible — no mapfile,
  # no associative arrays.
  shopt -s nullglob
  local d rid n s
  case "$MODE" in
    single)
      [ -n "$TARGET" ] && printf '%s\n' "$TARGET"
      ;;
    issue)
      [ -n "$TARGET" ] || { echo "cleanup-run: --issue requires a number" >&2; exit 1; }
      for d in "$RUNS_DIR"/*/; do
        rid=$(basename "$d")
        n=$(run_field "$rid" '.issue_number')
        [ "$n" = "$TARGET" ] && printf '%s\n' "$rid"
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

for r in "${SELECTED[@]}"; do
  cleanup_run "$r" || true
done

echo
echo "Done."
