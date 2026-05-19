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
#   1. GitHub assignment (gh issue edit --remove-assignee @me)
#   2. Worktree         (git worktree remove --force)
#   3. Local branch     (git branch -D)
#   4. Run-dir          (rm -rf .claude/run-issues/<run-id>)
#   5. Local lock       (rm -rf ~/Library/Application Support/run-issues/locks/issue-N)
#   6. DB clone         (only warned about — drop manually with backend-specific tooling)

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
LOCK_ROOT="${HOME}/Library/Application Support/run-issues/locks"

# ---------- helpers ----------
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

  local status issue_num branch worktree_path db_clone
  status=$(run_field "$rid" '.status')
  issue_num=$(run_field "$rid" '.issue_number')
  branch=$(run_field "$rid" '.branch')
  worktree_path=$(run_field "$rid" '.worktree_path')
  db_clone=$(run_field "$rid" '.db_clone')

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
    )
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

  do_or_dry "run-dir" rm -rf "$run_dir"

  if [ -n "$issue_num" ]; then
    local lock_dir="$LOCK_ROOT/issue-$issue_num"
    if [ -d "$lock_dir" ]; then
      do_or_dry "lock" rm -rf "$lock_dir"
    else
      printf '  lock: issue-%s not held\n' "$issue_num"
    fi
  fi

  if [ -n "$db_clone" ]; then
    printf '  ! DB clone present (%s) — NOT cleaned automatically. Drop manually.\n' "$db_clone"
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
