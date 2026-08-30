#!/usr/bin/env bash
# lib/archive.sh — move terminal, aged, PR-closed run-dirs out of the hot active
# directory into the repo's archive (issue #128).
#
# Run-dirs never expired on their own: 355 accumulated on Studio, and three
# separate O(n) loads all scaled with the COUNT, not the work — scan_clean's gh
# calls, status.sh --github's detail reads, and a 345 MB state.jsonl. The
# algorithmic fixes to the first two are their own issues; none of them stops the
# SET from growing without bound. This does, by moving finished runs where the
# hot paths never look.
#
# Binding design decisions (issue #128):
#   * ARCHIVE, never delete. A whole-dir atomic `mv` into
#     <repo>/.claude/run-issues-archive/<run-id>/ — the same directory status.sh
#     already COUNTS but never scans as runs (status.sh:222), stop-run.sh refuses
#     as a target (stop-run.sh:105), and lib/gitignore.sh ignores. History stays
#     on disk; it just stops costing gh calls and reads. Deletion is a separate,
#     later decision.
#   * TERMINAL only. `initialized` is a LIVE run (S8 restart/continue revives it)
#     and is never touched. Only `completed` and `merged` are candidates;
#     `blocked` and `awaiting_clarification` still await a human answer
#     (scan_blocked_answered / scan_answered), so they are NOT terminal here.
#   * OPEN PR protects. A `completed` run with a non-null pr_url may still be in
#     flight — pr-watch flips it to `merged` when the PR closes and needs the
#     run-dir's state.jsonl until then (the pr_ci_repair_attempted cap, §8). The
#     check is LOCAL (status + pr_url), NEVER a gh call — the sweep must not add
#     the very load it removes. `merged` => PR closed => archivable.
#   * AGE, not count. RUN_ISSUES_ARCHIVE_AFTER_DAYS (default 30) gates on
#     finished_at (fallback started_at). A count cap would move the very run you
#     are looking at.
#   * IDEMPOTENT + interrupt-safe. Per-dir atomic mv on the same filesystem (the
#     archive lives inside the repo). A crash leaves an intact state; the next
#     sweep finishes the job. A name collision (same run-id already archived —
#     e.g. a partial copy from cleanup-run.sh's archive_run) is NOT overwritten,
#     it is skipped with a log line.
#
# FAIL-CLOSED: an unreadable/missing run.json is never archived. A broken state
# is to be investigated, not hidden.
#
# This file only defines functions — no side effects at source time — so it is
# safe to source from any caller. It pulls in _iso_to_epoch from status-read.sh
# (the one definition status.sh and the poller already share) if the caller has
# not sourced it already.

set -euo pipefail

# _iso_to_epoch lives in lib/status-read.sh (issue #59), shared so every caller
# turns a timestamp into epoch seconds identically. Source it only if absent.
if ! declare -F _iso_to_epoch >/dev/null 2>&1; then
  _ARCHIVE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=lib/status-read.sh
  . "$_ARCHIVE_LIB_DIR/status-read.sh"
fi

# _archive_log <message> — best-effort logger, same spirit as run-terminate.sh's
# _run_terminate_log: use a caller-defined log(), else $LOG, else stderr.
_archive_log() {
  if declare -F log >/dev/null 2>&1; then
    log "archive: $*"
  elif [ -n "${LOG:-}" ]; then
    printf '%s archive: %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"
  else
    printf '%s archive: %s\n' "$(date -u +%FT%TZ)" "$*" >&2
  fi
}

# archive_is_candidate <run.json> <threshold-secs> <now-epoch> — return 0 iff the
# run is terminal (completed|merged), NOT a completed run with an open PR, and
# older than the threshold. Fail-closed: a missing/unreadable run.json, an
# unparseable status, or a missing timestamp all return 1 (never archive).
#
# Reads ONLY local state (run.json) — no gh call — so the sweep never adds the
# load it exists to remove.
archive_is_candidate() {
  local rj="$1" threshold="$2" now="$3"
  [ -f "$rj" ] || return 1

  # One jq read: status, pr_url, finished_at, started_at, one per line. A
  # read/parse failure (broken JSON) fails the jq call => fail-closed. Fields are
  # read line-by-line (NOT split on IFS) because pr_url is often empty and a
  # whitespace IFS would collapse the blank field and shift the rest.
  local out
  out=$(jq -r '.status // "", .pr_url // "", .finished_at // "", .started_at // ""' "$rj" 2>/dev/null) || return 1
  [ -n "$out" ] || return 1

  local status pr_url finished started
  {
    IFS= read -r status
    IFS= read -r pr_url
    IFS= read -r finished
    IFS= read -r started
  } <<EOF
$out
EOF

  # Terminal-only gate. Everything else — initialized (live), blocked and
  # awaiting_clarification (human-answer paths), timed_out (restartable) — is
  # left alone.
  case "$status" in
    completed|merged) ;;
    *) return 1 ;;
  esac

  # Open-PR guard (decision 4): a completed run whose PR has not yet closed still
  # carries a non-null pr_url — pr-watch flips it to `merged` on close. `merged`
  # means the PR is closed, so only a `completed` run with a pr_url is protected.
  if [ "$status" = "completed" ] && [ -n "$pr_url" ]; then
    return 1
  fi

  # Age gate: prefer finished_at (set by state_finalize), fall back to
  # started_at. No comparable timestamp => fail-closed.
  local ref="$finished"
  [ -n "$ref" ] || ref="$started"
  [ -n "$ref" ] || return 1
  local epoch
  epoch=$(_iso_to_epoch "$ref")
  [ -n "$epoch" ] || return 1
  [ $(( now - epoch )) -gt "$threshold" ] || return 1
  return 0
}

# archive_run_dir <run-dir> <archive-dir> — atomically move one run-dir into the
# archive. Echoes exactly one status token: `archived`, `collision` (dest already
# exists — not overwritten) or `failed` (mkdir/mv error, e.g. disk full). Never
# aborts the caller; a `failed` run is retried on the next sweep.
archive_run_dir() {
  local run_dir="$1" archive_dir="$2"
  local dest
  dest="$archive_dir/$(basename "$run_dir")"

  # A same-run-id dir already in the archive (a partial copy from cleanup-run.sh)
  # is never overwritten. mv into an existing dir would nest it — skip instead.
  if [ -e "$dest" ]; then
    printf 'collision\n'
    return 0
  fi
  mkdir -p "$archive_dir" 2>/dev/null || { printf 'failed\n'; return 0; }
  if mv "$run_dir" "$dest" 2>/dev/null; then
    printf 'archived\n'
  else
    printf 'failed\n'
  fi
}

# archive_sweep_repo <repo-path> <threshold-days> — move every archivable run-dir
# in the repo's ACTIVE run-issues directory into its archive. Returns the number
# of newly-archived runs on stdout (0 if none). No jq or a threshold <= 0 => no-op.
# The active directory is globbed; the archive is a DIFFERENT directory, so a run
# archived here is invisible to the next glob and to every scan_* / status.sh.
archive_sweep_repo() {
  local repo_path="$1" threshold_days="$2"
  local runs_dir="$repo_path/.claude/run-issues"
  local archive_dir="$repo_path/.claude/run-issues-archive"

  [ -d "$runs_dir" ] || { printf '0\n'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf '0\n'; return 0; }
  # A threshold of 0 (or below) DISABLES archiving — a kill switch, not "archive
  # everything immediately". Same hazard-avoidance posture as the other guards.
  [ "$threshold_days" -gt 0 ] 2>/dev/null || { printf '0\n'; return 0; }

  local now threshold_secs
  now=$(date -u +%s)
  threshold_secs=$(( threshold_days * 86400 ))

  local rj run_dir rid result archived=0
  shopt -s nullglob
  for rj in "$runs_dir"/*/run.json; do
    # A human may have deleted the run-dir between glob and read — skip silently.
    [ -e "$rj" ] || continue
    if archive_is_candidate "$rj" "$threshold_secs" "$now"; then
      run_dir=$(dirname "$rj")
      rid=$(basename "$run_dir")
      result=$(archive_run_dir "$run_dir" "$archive_dir")
      case "$result" in
        archived)  archived=$(( archived + 1 )); _archive_log "$rid -> archived ($repo_path)" ;;
        collision) _archive_log "$rid -> already in archive, skipping ($repo_path)" ;;
        failed)    _archive_log "$rid -> mv failed, will retry next sweep ($repo_path)" ;;
      esac
    fi
  done
  printf '%s\n' "$archived"
  return 0
}
