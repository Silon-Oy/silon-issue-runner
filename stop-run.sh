#!/usr/bin/env bash
# stop-run.sh — stop a single live /run-issues run on request (issue #64).
#
# Usage:
#   stop-run.sh --run-dir <path>                        # address one run directly
#   stop-run.sh --repo <path> --issue <N> [--remote <name>]  # address by issue
#
# Flags:
#   --force     also stop a run whose status is terminal (e.g. completed, whose
#               open PR context would otherwise be torn loose)
#   --yes / -y  skip the confirmation prompt
#   --dry-run   print the plan, write nothing
#
# This is a thin operator surface over lib/run-terminate.sh:run_terminate — the
# safe teardown extracted in #63 (exact tmux kill, host gate, state_finalize,
# needs-human label, situation comment, lock release from the run's OWN recorded
# identity). NONE of that logic is reimplemented here; stop-run only RESOLVES the
# target run and enforces the operator-facing gates before delegating.
#
# Five safety constraints (issue #64):
#   1. No --all, no default target. A stop is always an explicit single run;
#      stopping everything is stopping the orchestrator (launchctl), not this.
#   2. Per-run host gate: run.json.host != `runner_host` -> exit 4, no side
#      effects. A foreign machine's live tmux session is never touched. (This is
#      stop-run's OWN check — run_terminate returns 0 silently on a foreign host,
#      so the exit-4 refusal must happen here, before delegation.)
#   3. A terminal-status run is refused without --force (exit 5): "stopping" a
#      completed run would tear loose its live PR context. Same gate posture as
#      cleanup-run.sh's --force.
#   4. Confirmation prompt without --yes; --dry-run writes nothing.
#   5. A stop is NOT a cleanup. Worktree, branch and run-dir are left intact —
#      teardown stays with cleanup-run.sh / the auto-clean label.
#
# Exit codes:
#   0  stopped (or --dry-run plan printed)
#   1  usage error (bad flag / missing or conflicting target)
#   2  no run found for the given target (includes an archived --run-dir)
#   3  --issue matched more than one run — narrow with --run-dir
#   4  foreign host — the run belongs to another machine; nothing was touched
#   5  terminal-status run — pass --force to stop it anyway; nothing was touched
#
# Run: stop-run.sh --repo <path> --issue <N> --yes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# runner_host (issue #213): the per-run host gate below compares against
# run.json.host, which lib/state.sh writes with this same resolver.
# shellcheck source=lib/host.sh
. "$SCRIPT_DIR/lib/host.sh"

usage() {
  sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

# ---------- argument parsing ----------
RUN_DIR=""
REPO_ROOT=""
ISSUE=""
REMOTE=""
FORCE=0
ASSUME_YES=0
DRY_RUN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-dir) RUN_DIR="${2:-}"; shift 2 ;;
    --repo)    REPO_ROOT="${2:-}"; shift 2 ;;
    --issue)   ISSUE="${2:-}"; shift 2 ;;
    --remote)  REMOTE="${2:-}"; shift 2 ;;
    --force)   FORCE=1; shift ;;
    -y|--yes)  ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    --*)       echo "stop-run: unknown flag '$1'" >&2; usage 1 ;;
    *)         echo "stop-run: unexpected argument '$1'" >&2; usage 1 ;;
  esac
done

# ---------- target validation (constraint 1: always explicit, no default) ------
if [ -n "$RUN_DIR" ]; then
  # --run-dir is a complete address on its own; combining it with the by-issue
  # selectors is ambiguous, so reject rather than silently pick one.
  if [ -n "$REPO_ROOT" ] || [ -n "$ISSUE" ] || [ -n "$REMOTE" ]; then
    echo "stop-run: --run-dir cannot be combined with --repo/--issue/--remote" >&2
    usage 1
  fi
elif [ -n "$REPO_ROOT" ] || [ -n "$ISSUE" ] || [ -n "$REMOTE" ]; then
  # By-issue address: --repo and --issue are both required; --remote is optional.
  if [ -z "$REPO_ROOT" ] || [ -z "$ISSUE" ]; then
    echo "stop-run: --repo and --issue are both required (or use --run-dir)" >&2
    usage 1
  fi
  case "$ISSUE" in
    ''|*[!0-9]*) echo "stop-run: --issue must be a positive integer" >&2; usage 1 ;;
  esac
else
  echo "stop-run: no target — specify --run-dir <path> or --repo <path> --issue <N>" >&2
  usage 1
fi

# ---------- resolve the target run-dir ----------
RESOLVED=""
if [ -n "$RUN_DIR" ]; then
  # An archived run-dir is not a live run — its teardown already happened. Treat
  # it as "not found" (exit 2) so we never resurrect a state_finalize on it.
  case "$RUN_DIR" in
    */run-issues-archive/*|*/run-issues-archive)
      echo "stop-run: run-dir is archived, nothing to stop: $RUN_DIR" >&2
      exit 2 ;;
  esac
  if [ ! -f "$RUN_DIR/run.json" ]; then
    echo "stop-run: no run.json under run-dir: $RUN_DIR" >&2
    exit 2
  fi
  RESOLVED="${RUN_DIR%/}"
else
  RUNS_DIR="$REPO_ROOT/.claude/run-issues"
  MATCHES=()
  if [ -d "$RUNS_DIR" ]; then
    shopt -s nullglob
    for d in "$RUNS_DIR"/*/; do
      d="${d%/}"
      [ -f "$d/run.json" ] || continue
      n=$(jq -r '.issue_number // empty' "$d/run.json" 2>/dev/null || echo "")
      [ "$n" = "$ISSUE" ] || continue
      if [ -n "$REMOTE" ]; then
        r=$(jq -r '.remote // "origin"' "$d/run.json" 2>/dev/null || echo "origin")
        [ "$r" = "$REMOTE" ] || continue
      fi
      MATCHES+=("$d")
    done
  fi
  case "${#MATCHES[@]}" in
    0)
      echo "stop-run: no run found for issue #$ISSUE${REMOTE:+ on remote '$REMOTE'} under $RUNS_DIR" >&2
      exit 2 ;;
    1)
      RESOLVED="${MATCHES[0]}" ;;
    *)
      # Constraint / exit 3: more than one run touched this issue (e.g. two
      # remotes, or a restart left an old run-dir). Refuse and let the operator
      # disambiguate with --run-dir — never guess which live run to kill.
      {
        echo "stop-run: issue #$ISSUE matches ${#MATCHES[@]} runs — narrow with --run-dir:"
        for d in "${MATCHES[@]}"; do echo "  $d"; done
      } >&2
      exit 3 ;;
  esac
fi

# ---------- read the fields the gates need ----------
RJ="$RESOLVED/run.json"
THIS_HOST="$(runner_host)"
RUN_HOST=$(jq -r '.host // empty' "$RJ" 2>/dev/null || echo "")
RUN_STATUS=$(jq -r '.status // empty' "$RJ" 2>/dev/null || echo "")
RUN_ISSUE=$(jq -r '.issue_number // empty' "$RJ" 2>/dev/null || echo "")
RUN_STATE=$(jq -r '.current_state // "unknown"' "$RJ" 2>/dev/null || echo "unknown")

# is_stoppable_status <status> — a live run carries status "initialized"
# throughout its lifetime (S8 restart/continue reset it back to "initialized");
# state_finalize is the ONLY writer of a terminal status. So anything other than
# initialized (or an empty/malformed field, treated as live) is a finalized run
# whose terminal record we must not overwrite without --force.
is_stoppable_status() {
  case "${1:-}" in
    initialized|"") return 0 ;;
    *) return 1 ;;
  esac
}

# ---------- gate 1: host (constraint 2) — exit 4, no side effects ----------
# Checked BEFORE the terminal-status gate: a foreign run is the more fundamental
# refusal (we must not reason about, let alone touch, another machine's run).
if [ -n "$RUN_HOST" ] && [ "$RUN_HOST" != "$THIS_HOST" ]; then
  echo "stop-run: run belongs to host '$RUN_HOST', not '$THIS_HOST' — refusing (run it there)." >&2
  exit 4
fi

# ---------- gate 2: terminal status (constraint 3) — exit 5, no side effects ---
if ! is_stoppable_status "$RUN_STATUS" && [ "$FORCE" != "1" ]; then
  echo "stop-run: run status is '$RUN_STATUS' (terminal) — pass --force to stop it anyway." >&2
  exit 5
fi

# ---------- plan / confirm / delegate ----------
print_plan() {
  cat <<EOF
Stop plan for issue #${RUN_ISSUE:-?} (state=$RUN_STATE, status=${RUN_STATUS:-unknown}):
  run-dir: $RESOLVED
  host:    $THIS_HOST
  action:  kill the tmux session, finalize blocked/stopped_by_operator,
           add the needs-human label, post a situation comment, release the lock.
  intact:  worktree, branch and run-dir are LEFT IN PLACE — use cleanup-run.sh
           (or the auto-clean label) to tear them down.
EOF
}

# --dry-run (constraint 4): print the plan, write nothing. The gates above have
# already run, so a foreign/terminal run never reaches here even in dry-run.
if [ "$DRY_RUN" = "1" ]; then
  echo "[dry-run] no changes will be made."
  print_plan
  exit 0
fi

# Confirmation prompt without --yes (constraint 4).
if [ "$ASSUME_YES" != "1" ]; then
  print_plan
  printf 'Stop this run? [y/N]: '
  ans=""
  read -r ans || true
  case "$ans" in
    [Yy]|[Yy][Ee][Ss]) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

# Delegate the actual teardown to the extracted helper (constraint 5 falls out
# for free: run_terminate never touches worktree/branch/run-dir). run_terminate
# reads every field it needs from run.json, so we pass only the run-dir, the
# reason slug and the "stopped" context that selects the operator comment body.
# shellcheck source=lib/run-terminate.sh
. "$SCRIPT_DIR/lib/run-terminate.sh"
run_terminate "$RESOLVED" "stopped_by_operator" "stopped"

echo "Stopped run for issue #${RUN_ISSUE:-?} (blocked/stopped_by_operator)."
echo "Worktree, branch and run-dir left intact — clean up with:"
echo "  $SCRIPT_DIR/cleanup-run.sh --issue ${RUN_ISSUE:-<N>} --force --yes"
exit 0
