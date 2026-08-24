#!/usr/bin/env bash
# lib/status-read.sh — pure read + classification helpers for status.sh.
#
# status.sh aggregates every watchlist repo's run-dirs into one versioned JSON
# document. The logic that (a) normalises a heterogeneous run.json into the
# schema-v1 shape and (b) classifies a normalised run into one of five classes
# lives here as pure functions, the same idiom as lib/pr-watch-lib.sh's
# pr_decide + tests/test-pr-watch-decision.sh. Keeping it here means the
# classifier and the two-tier read can be unit-tested by sourcing this file,
# with no watchlist, no network and no real ~/.claude on disk.
#
# Sourced by status.sh AND by poller.sh (for _iso_to_epoch, which used to live
# in the poller; moving it here keeps one definition and lets status.sh and the
# poller agree bit-for-bit on how a timestamp becomes epoch seconds). This file
# is function-only + a few jq-program string constants; no top-level work, safe
# to source repeatedly.
#
# Pure: no writes (except status_read_perfile appending to the caller-named
# error file), no network, no exits.

set -euo pipefail

# _iso_to_epoch <iso-utc-ts> — convert an ISO-8601 Zulu timestamp (the format
# lib/state.sh writes: YYYY-MM-DDTHH:MM:SSZ) to Unix epoch seconds. Empty string
# on parse failure (callers treat this as "can't compare, leave it alone").
# macOS `date -j -f` parses + emits; GNU `date -d` is the Linux fallback for CI.
#
# Moved verbatim from poller.sh (issue #59): the poller now sources this file
# and calls the same function, so the staleness clock the poller kills on and
# the idle_seconds status.sh reports are computed identically.
_iso_to_epoch() {
  local ts="$1"
  [ -n "$ts" ] || { printf ''; return 0; }
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" "+%s" 2>/dev/null \
    || date -u -d "$ts" "+%s" 2>/dev/null \
    || printf ''
}

# _STATUS_NORMALIZE_JQ — jq filter applied to ONE raw run.json object (with
# `input_filename` in scope) to produce the normalised, defaulted record every
# later stage consumes. The on-disk schema is heterogeneous (issue #59: remote
# missing from 34 run.jsons, repo_slug from 167, base_branch from 9), so every
# read carries a default AND records the gap in schema_gaps. repo_path is
# derived structurally from the run.json path, so a run-dir physically located
# under repo X is attributed to repo X regardless of a stale .repo field.
#
# INV-STATUS (issue #59): the record carries blocked_reason as history only.
# The classifier reads .status, never .blocked_reason — state_finalize writes
# blocked_reason on a non-empty reason and never clears it, so a completed run
# that recovered from a timeout still has blocked_reason set on disk.
#
# Single-quoted: contains literal jq $-variables and must not be expanded by
# the shell that sources this file.
# jq $-variables are meant to stay literal (SC2016); consumed elsewhere (SC2034).
# shellcheck disable=SC2016,SC2034
_STATUS_NORMALIZE_JQ='
  (input_filename | rtrimstr("/run.json")) as $run_dir
  | ($run_dir | sub("/\\.claude/run-issues/.*$"; "")) as $repo_path
  | {
      run_id: (.run_id // ($run_dir | sub(".*/"; ""))),
      run_dir: $run_dir,
      repo_path: $repo_path,
      issue_number: (.issue_number // null),
      remote: (.remote // "origin"),
      repo_slug_raw: (.repo_slug // ""),
      host: (.host // ""),
      status: (.status // "initialized"),
      blocked_reason: (.blocked_reason // null),
      current_state: (.current_state // null),
      cycle_review_decision: (.cycle_review_decision // null),
      started_at: (.started_at // null),
      finished_at: (.finished_at // null),
      awaiting_answer_since: (.awaiting_answer_since // null),
      retry_count: (.retry_count // 0),
      clarification_round: (.clarification_round // 0),
      branch: (.branch // null),
      worktree_path: (.worktree_path // null),
      pr_url: (.pr_url // null),
      schema_gaps: ([
        (if (.remote // null) == null then "remote" else empty end),
        (if (.repo_slug // null) == null then "repo_slug" else empty end),
        (if (.base_branch // null) == null then "base_branch" else empty end)
      ])
    }
'

# _STATUS_CLASSIFY_JQ — jq program text that DEFINES `_classify($stale)`. Applied
# to a fully-enriched run object (session_alive, idle_seconds, pr_local_verdict
# already set), it returns the same object plus {class, class_reason,
# class_confidence}. Five classes, first match wins; the initialized branch is
# spelled out so every documented class_reason is reachable and the view agrees
# with the poller's scan_stalled on what "stalled" means (an initialized run
# whose last event is older than stale IS stalled, even with a live tmux session
# — the poller kills exactly those).
#
# INV-UNKNOWN (fail-closed, issue #59): an unknown PR verdict leans to the live
# side (pr_in_flight + low confidence), never cleanup — the wrong direction
# would suggest tearing down a live PR's worktree.
#
# Single-quoted for the same reason as the normalize program.
# jq $-variables are meant to stay literal (SC2016); consumed elsewhere (SC2034).
# shellcheck disable=SC2016,SC2034
_STATUS_CLASSIFY_JQ='
  def _classify($stale):
    . as $r
    | ($r.status) as $st
    | ($r.session_alive == true) as $alive
    | ($r.idle_seconds) as $idle
    | (
        if $st == "initialized" then
          if ($r.current_state == "S7_ReviewGate" and ($alive | not)) then
            {class:"attention", class_reason:"awaiting_review", class_confidence:"high"}
          elif ($idle != null and $idle > $stale) then
            {class:"stalled",
             class_reason:(if $alive then "wedged_session" else "orphaned" end),
             class_confidence:"high"}
          elif $alive then
            {class:"running", class_reason:"active_session", class_confidence:"high"}
          elif ($idle != null) then
            {class:"running", class_reason:"recent_progress", class_confidence:"high"}
          else
            {class:"stalled", class_reason:"orphaned", class_confidence:"high"}
          end
        elif $st == "blocked" then
          {class:"attention", class_reason:"blocked", class_confidence:"high"}
        elif $st == "timed_out" then
          {class:"attention", class_reason:"timed_out", class_confidence:"high"}
        elif $st == "pr_conflicted" then
          {class:"attention", class_reason:"pr_conflicted", class_confidence:"high"}
        elif $st == "awaiting_clarification" then
          {class:"attention", class_reason:"awaiting_clarification", class_confidence:"high"}
        elif $st == "completed" then
          ($r.pr_local_verdict) as $v
          | if $v == "SKIP_CLOSED" then
              {class:"cleanup", class_reason:"pr_not_open", class_confidence:"high"}
            elif $v == "SKIP_NO_LABEL" then
              {class:"attention", class_reason:"pr_unlabelled", class_confidence:"high"}
            elif ($v == "WAIT_CI" or $v == "WAIT_DIRTY" or $v == "REBASE"
                  or $v == "MERGE" or $v == "FIX_CI" or $v == "SKIP_BLOCKED") then
              {class:"pr_in_flight", class_reason:"pr_open_waiting", class_confidence:"high"}
            else
              {class:"pr_in_flight", class_reason:"pr_state_unknown", class_confidence:"low"}
            end
        elif $st == "lost_race" then
          {class:"cleanup", class_reason:"lost_race", class_confidence:"high"}
        elif $st == "cancelled" then
          {class:"cleanup", class_reason:"cancelled", class_confidence:"high"}
        elif $st == "merged" then
          {class:"cleanup", class_reason:"pr_not_open", class_confidence:"high"}
        else
          {class:"attention", class_reason:"blocked", class_confidence:"low"}
        end
      ) as $c
    | $r + $c
  ;
'

# _STATUS_GITHUB_RECLASSIFY_JQ — jq program text that DEFINES `_github_reclassify`.
# Applied AFTER _classify, to a run object that already carries a `github`
# sub-object (issue #60). A no-op when `.github == null`, so in local mode
# (no --github) the output is bit-for-bit what #59 produced. When github is
# present it refines the local verdict with the live PR state:
#
#   - pr_state NOT_OPEN  => cleanup/pr_not_open/high. The PR is gone (merged or
#       closed); the run's worktree should be torn down. This is the core of the
#       ~30% the local view cannot see: run.json still says `completed` with a
#       stale `pr_open_waiting` verdict, but the PR has since left GitHub.
#   - pr_state OPEN      => confidence -> high (the PR state is now CONFIRMED,
#       not inferred from state.jsonl), then three attention refinements, first
#       match wins:
#       * ci RED (and NOT merge_state UNSTABLE — same edge as pr_decide ordering
#         point 2: an UNSTABLE red is a non-required check, not a blocker)
#         => attention/pr_ci_red
#       * review_decision CHANGES_REQUESTED => attention/pr_changes_requested
#       * is_draft AND run age > 7d (604800s) => attention/pr_draft_stale
#       otherwise the local class stands, only its confidence rises.
#   - pr_state null/absent (a run with NO PR — issue-only object, issue #78) AND
#       issue_state CONFIRMED "CLOSED" => cleanup/issue_closed/high (issue #96).
#       A run that ended before a PR (blocked/timed_out/…) whose issue was later
#       closed by hand would otherwise sit in attention forever. issue_state is
#       only set when an explicit `gh issue view` confirmed the closure (see
#       lib/status-github.sh:status_github_issue_state) — absence from the open
#       map alone is a hint, never proof, so an unread/failed state stays null and
#       the local class stands (fail-soft). The PR branches above own the
#       closed-PR case, so this only fires when there is no PR at all.
#
# Single-quoted for the same reason as the classify program.
# jq $-variables are meant to stay literal (SC2016); consumed elsewhere (SC2034).
# shellcheck disable=SC2016,SC2034
_STATUS_GITHUB_RECLASSIFY_JQ='
  def _github_reclassify:
    . as $r
    | if ($r.github == null) then $r
      else
        ($r.github) as $g
        | if ($g.pr_state // "") == "NOT_OPEN" then
            $r + {class:"cleanup", class_reason:"pr_not_open", class_confidence:"high"}
          elif ($g.pr_state // "") == "OPEN" then
            ($r + {class_confidence:"high"}) as $base
            | if ($g.ci == "RED" and ($g.merge_state_status // "") != "UNSTABLE") then
                $base + {class:"attention", class_reason:"pr_ci_red"}
              elif ($g.review_decision == "CHANGES_REQUESTED") then
                $base + {class:"attention", class_reason:"pr_changes_requested"}
              elif ($g.is_draft == true and ($r.age_seconds != null and $r.age_seconds > 604800)) then
                $base + {class:"attention", class_reason:"pr_draft_stale"}
              else $base
              end
          elif (($g.issue_state // "") == "CLOSED") then
            $r + {class:"cleanup", class_reason:"issue_closed", class_confidence:"high"}
          else $r
          end
      end
  ;
'

# status_classify <run-json-object> [<stale-after-seconds>]
# Pure classifier over ONE fully-enriched run object. Prints
# "<class> <class_reason> <class_confidence>" on stdout. Used by
# tests/test-status-classify.sh; status.sh applies the same _classify def in
# bulk inside its assembly jq, so there is one source of truth.
status_classify() {
  local obj="$1" stale="${2:-3600}"
  printf '%s' "$obj" | jq -r --argjson stale "$stale" \
    "${_STATUS_CLASSIFY_JQ} _classify(\$stale) | \"\(.class) \(.class_reason) \(.class_confidence)\""
}

# status_read_bulk <run.json-path>... — the fast path: one jq joule-read over
# every run.json at once (issue #59 measured this 100x faster than per-file jq).
# Prints a JSON array of normalised records on stdout. Returns jq's exit code:
# a SINGLE malformed run.json makes jq exit non-zero and the array is not
# emitted, so the caller MUST discard stdout on a non-zero return and fall back
# to status_read_perfile. With no paths it prints [] and returns 0.
status_read_bulk() {
  [ "$#" -gt 0 ] || { printf '[]'; return 0; }
  jq -n -c "[ inputs | ${_STATUS_NORMALIZE_JQ} ]" "$@"
}

# _status_read_error <path> <error> — append one read-error record (issue #59
# shape: {path, error}) to the file named by STATUS_READ_ERRORS_FILE, if set.
_status_read_error() {
  [ -n "${STATUS_READ_ERRORS_FILE:-}" ] || return 0
  jq -nc --arg p "$1" --arg e "$2" '{path:$p, error:$e}' >> "$STATUS_READ_ERRORS_FILE"
}

# status_read_perfile <run.json-path>... — the fallback path: read each file
# on its own so one broken run.json isolates to a read-error instead of losing
# the whole scan. Prints readable records as JSONL (one object per line) on
# stdout; appends {path, error:"invalid_json"|"unreadable"} records to
# STATUS_READ_ERRORS_FILE. Always returns 0 — a broken file is data, not a
# crash. Both read functions are named (not inlined) so the fallback is
# testable with a fixture that plants a truncated run.json.
status_read_perfile() {
  local p obj
  for p in "$@"; do
    if [ ! -r "$p" ]; then
      _status_read_error "$p" "unreadable"
      continue
    fi
    if obj=$(jq -c "${_STATUS_NORMALIZE_JQ}" "$p" 2>/dev/null); then
      printf '%s\n' "$obj"
    else
      _status_read_error "$p" "invalid_json"
    fi
  done
  return 0
}
