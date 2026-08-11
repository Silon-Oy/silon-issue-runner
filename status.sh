#!/usr/bin/env bash
# status.sh — read-only aggregate status of every watchlist repo's run-dirs.
#
# Studio runs a dozen+ watchlist repos in parallel and there is no single place
# to see the whole picture: hundreds of run-dirs across many repos, a handful
# needing a human (blocked / timed_out / awaiting_clarification / pr_conflicted)
# buried under a mountain of finished runs waiting to be cleaned up. This script
# aggregates them all into one versioned JSON document (--json) and a terse
# human summary (--human). It is PURELY READING: no network, no mutation, no new
# dependencies beyond bash 3.2 + jq. Later increments (gh enrichment, an email
# digest, a static HTML page) consume this JSON — the schema is the interface.
#
# Usage:
#   status.sh [--json|--human] [--class <a,b>] [--repo <path>]
#             [--watchlist <path>] [--stale-after <s>]
#
#   --json / --human   output format. Default: --json when stdout is not a TTY,
#                      --human when it is.
#   --class <a,b>      show only runs in these classes (comma-separated). Totals
#                      always reflect the full scan; only the runs[] list / the
#                      human display are filtered.
#   --repo <path>      restrict the scan to a single watchlist repo path.
#   --watchlist <path> override the watchlist (same semantics as the poller:
#                      an override is the ONLY candidate, a missing file errors).
#   --stale-after <s>  liveness threshold in seconds (default 3600, same var as
#                      the poller: RUN_ISSUES_STALE_AFTER).
#
# Exit codes:
#   0  read OK
#   1  usage error (unknown flag / bad value)
#   2  no watchlist, or no readable repo on disk, or jq is missing
#   3  partial read — one or more run.json files were unreadable/invalid; the
#      document is still valid and complete for the rest, degraded:true, and the
#      unreadable paths are listed in read_errors[]
#
# Environment:
#   RUN_ISSUES_WATCHLIST         watchlist override (poller semantics)
#   RUN_ISSUES_STALE_AFTER       liveness threshold (default 3600 — the SAME
#                                variable the poller uses, on purpose)
#   RUN_ISSUES_STATUS_TAIL_LINES tail lines read per state.jsonl (default 40)
#   RUN_ISSUES_HOME              install root (test injection point; defaults to
#                                this script's directory)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_ISSUES_HOME="${RUN_ISSUES_HOME:-$HERE}"

# ---- shared libraries (function-only, safe to source) ----
# poller-config.sh: poller_resolve_watchlist (identical watchlist lookup as the
#   pollers). git-remote.sh: repo_slug / resolve_remote_to_owner_repo /
#   session_suffix. locking.sh: _lock_dir (for lock_held). status-read.sh:
#   normalisation, classification, _iso_to_epoch.
# shellcheck source=lib/poller-config.sh
. "$RUN_ISSUES_HOME/lib/poller-config.sh"
# shellcheck source=lib/git-remote.sh
. "$RUN_ISSUES_HOME/lib/git-remote.sh"
# shellcheck source=lib/locking.sh
. "$RUN_ISSUES_HOME/lib/locking.sh"
# shellcheck source=lib/status-read.sh
. "$RUN_ISSUES_HOME/lib/status-read.sh"

STATUS_TAIL="${RUN_ISSUES_STATUS_TAIL_LINES:-40}"
STALE_AFTER="${RUN_ISSUES_STALE_AFTER:-3600}"
THIS_HOST="$(hostname -s 2>/dev/null || echo unknown)"

# ---- argument parsing ----
OUT_MODE=""          # "", json, human
CLASS_FILTER=""
REPO_FILTER=""
WATCHLIST_OVERRIDE="${RUN_ISSUES_WATCHLIST:-}"

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die_usage() {
  printf 'status.sh: %s\n' "$1" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json)   OUT_MODE="json" ;;
    --human)  OUT_MODE="human" ;;
    --class)  shift; [ "$#" -gt 0 ] || die_usage "--class needs a value"; CLASS_FILTER="$1" ;;
    --repo)   shift; [ "$#" -gt 0 ] || die_usage "--repo needs a value"; REPO_FILTER="$1" ;;
    --watchlist) shift; [ "$#" -gt 0 ] || die_usage "--watchlist needs a value"; WATCHLIST_OVERRIDE="$1" ;;
    --stale-after)
      shift; [ "$#" -gt 0 ] || die_usage "--stale-after needs a value"
      case "$1" in ''|*[!0-9]*) die_usage "--stale-after must be a non-negative integer" ;; esac
      STALE_AFTER="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
  shift
done

# Default mode from TTY-ness of stdout.
if [ -z "$OUT_MODE" ]; then
  if [ -t 1 ]; then OUT_MODE="human"; else OUT_MODE="json"; fi
fi

# ---- hard dependency: jq ----
if ! command -v jq >/dev/null 2>&1; then
  printf 'status.sh: jq is required but not installed (brew install jq)\n' >&2
  exit 2
fi

# ---- resolve watchlist (poller semantics) ----
CONFIG_WL="$HOME/.config/run-issues/watchlist.json"
LEGACY_WL="$HOME/dotfiles/machine-studio/run-issues-watchlist.json"
if ! WATCHLIST="$(poller_resolve_watchlist "$WATCHLIST_OVERRIDE" "$CONFIG_WL" "$LEGACY_WL")"; then
  if [ -n "$WATCHLIST_OVERRIDE" ]; then
    printf 'status.sh: watchlist override not found: %s\n' "$WATCHLIST_OVERRIDE" >&2
  else
    printf 'status.sh: no watchlist found (looked at %s and %s)\n' "$CONFIG_WL" "$LEGACY_WL" >&2
  fi
  exit 2
fi

# ---- temp workspace ----
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/status.XXXXXX")"
cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT

# ---- enumerate repos + run.json paths ----
# repos_configured: every .repos[].path in the watchlist. repos_scanned: those
# that exist on disk. repos_absent: those that do not. --repo restricts the set.
REPO_PATHS_FILE="$TMPD/repo_paths.txt"
jq -r '.repos[]?.path // empty' "$WATCHLIST" > "$REPO_PATHS_FILE" 2>/dev/null || : > "$REPO_PATHS_FILE"

REPOS_CONFIGURED=0
REPOS_SCANNED=0
ABSENT_FILE="$TMPD/absent.txt"
: > "$ABSENT_FILE"
RUN_JSON_LIST="$TMPD/run_json_list.txt"
: > "$RUN_JSON_LIST"
ARCHIVED=0

while IFS= read -r rp; do
  [ -n "$rp" ] || continue
  # --repo filter: skip everything but the requested path.
  if [ -n "$REPO_FILTER" ] && [ "$rp" != "$REPO_FILTER" ]; then
    continue
  fi
  REPOS_CONFIGURED=$((REPOS_CONFIGURED + 1))
  if [ ! -d "$rp" ]; then
    printf '%s\n' "$rp" >> "$ABSENT_FILE"
    continue
  fi
  REPOS_SCANNED=$((REPOS_SCANNED + 1))
  runs_dir="$rp/.claude/run-issues"
  if [ -d "$runs_dir" ]; then
    # Live run-dirs: <runs_dir>/<run-id>/run.json.
    for rj in "$runs_dir"/*/run.json; do
      [ -e "$rj" ] || continue
      printf '%s\n' "$rj" >> "$RUN_JSON_LIST"
    done
  fi
  # Archived runs are counted, never scanned as runs (issue #59 edge case).
  archive_dir="$rp/.claude/run-issues-archive"
  if [ -d "$archive_dir" ]; then
    for ad in "$archive_dir"/*/; do
      [ -d "$ad" ] || continue
      ARCHIVED=$((ARCHIVED + 1))
    done
  fi
done < "$REPO_PATHS_FILE"

# No repo on disk at all (empty watchlist, or every path absent, or --repo
# pointed at an absent/non-listed path) — nothing to read.
if [ "$REPOS_SCANNED" -eq 0 ]; then
  printf 'status.sh: no readable repo on disk (configured=%s, watchlist=%s)\n' \
    "$REPOS_CONFIGURED" "$WATCHLIST" >&2
  exit 2
fi

# Build the paths array (bash 3.2: read the list file into a positional array).
RUN_JSON_PATHS=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  RUN_JSON_PATHS+=("$line")
done < "$RUN_JSON_LIST"

# ---- two-tier read: bulk first, per-file fallback on any parse error ----
ERRORS_FILE="$TMPD/read_errors.jsonl"
: > "$ERRORS_FILE"
NORMALIZED="[]"
if [ "${#RUN_JSON_PATHS[@]}" -gt 0 ]; then
  if BULK_OUT="$(status_read_bulk "${RUN_JSON_PATHS[@]}" 2>/dev/null)"; then
    NORMALIZED="$BULK_OUT"
  else
    # A malformed run.json killed the bulk read; isolate it per-file.
    export STATUS_READ_ERRORS_FILE="$ERRORS_FILE"
    NORMALIZED="$(status_read_perfile "${RUN_JSON_PATHS[@]}" | jq -s -c '.')"
    unset STATUS_READ_ERRORS_FILE
  fi
fi
printf '%s' "$NORMALIZED" > "$TMPD/normalized.json"

# read_errors[] as a JSON array (empty when the bulk path succeeded).
if [ -s "$ERRORS_FILE" ]; then
  READ_ERRORS="$(jq -s -c '.' "$ERRORS_FILE")"
else
  READ_ERRORS="[]"
fi

# ---- owner/slug resolution: once per (repo, remote) ----
# owner_repo + issue_url + the effective repo_slug fallback derive from the git
# remote, which is a side effect (git remote get-url) — so resolve each distinct
# (repo, remote) pair exactly once, not per run.
PAIRS_FILE="$TMPD/pairs.tsv"
jq -r '.[] | [.repo_path, .remote] | @tsv' "$TMPD/normalized.json" 2>/dev/null \
  | sort -u > "$PAIRS_FILE" || : > "$PAIRS_FILE"
OWNERS_TSV="$TMPD/owners.tsv"
: > "$OWNERS_TSV"
while IFS=$'\t' read -r rp rem; do
  [ -n "$rp" ] || continue
  [ -n "$rem" ] || rem="origin"
  owner="$(resolve_remote_to_owner_repo "$rp" "$rem" 2>/dev/null || true)"
  slug="$(repo_slug "$rp" "$rem" 2>/dev/null || true)"
  printf '%s\t%s\t%s\t%s\n' "$rp" "$rem" "$owner" "$slug" >> "$OWNERS_TSV"
done < "$PAIRS_FILE"
OWNERS_JSON="$(jq -R -s '
  split("\n") | map(select(length > 0) | split("\t"))
  | map({ (.[0] + "\t" + .[1]): {owner: .[2], slug: .[3]} }) | add // {}
' "$OWNERS_TSV")"
printf '%s' "$OWNERS_JSON" > "$TMPD/owners.json"

# ---- per-run side-effect probes: worktree_exists, lock_held, session_alive ----
# Keyed by the run's array index so the join with the JSON stays path-safe and
# needs no bash 4 associative arrays. session_alive is only probed for
# initialized runs (terminal runs have no session); tmux missing => false.
ENUM_FILE="$TMPD/enum.tsv"
jq -r 'to_entries[] | [.key, .value.run_dir, (.value.worktree_path // ""),
        (.value.issue_number // ""), .value.remote, .value.repo_slug_raw,
        .value.status, .value.repo_path] | @tsv' \
  "$TMPD/normalized.json" 2>/dev/null > "$ENUM_FILE" || : > "$ENUM_FILE"

PROBE_TSV="$TMPD/probe.tsv"
: > "$PROBE_TSV"
mkdir -p "$TMPD/tails"
while IFS=$'\t' read -r idx run_dir wt issue remote slug_raw status repo_path; do
  [ -n "$idx" ] || continue

  we=false
  if [ -n "$wt" ] && [ "$wt" != "null" ] && [ -d "$wt" ]; then we=true; fi

  sa=false
  if [ "$status" = "initialized" ] && [ -n "$issue" ] && [ "$issue" != "null" ]; then
    slug_eff="$slug_raw"
    [ -n "$slug_eff" ] || slug_eff="$(repo_slug "$repo_path" "$remote" 2>/dev/null || true)"
    suf="$(session_suffix "$remote" "$issue" "$slug_eff")"
    for pre in run-issues- run-issues-restart- run-issues-continue-; do
      if tmux has-session -t "=${pre}${suf}" 2>/dev/null; then sa=true; break; fi
    done
  fi

  lh=false
  if [ -n "$issue" ] && [ "$issue" != "null" ]; then
    ld="$(_lock_dir "$issue" "$remote" "$slug_raw" 2>/dev/null || true)"
    if [ -n "$ld" ] && [ -d "$ld" ]; then lh=true; fi
  fi

  printf '%s\t%s\t%s\t%s\n' "$idx" "$we" "$lh" "$sa" >> "$PROBE_TSV"

  # Tail the event log for idle_seconds + the last pr verdict. NEVER read the
  # whole file (issue #59 constraint 2: state.jsonl is 99.7% PR-watch noise and
  # up to 6.7 MB); tail seeks from the end, so this is fast even on huge files.
  jsonl="$run_dir/state.jsonl"
  if [ -s "$jsonl" ]; then
    tail -n "$STATUS_TAIL" "$jsonl" > "$TMPD/tails/$idx.jsonl" 2>/dev/null || true
  fi
done < "$ENUM_FILE"

PROBE_JSON="$(jq -R -s '
  split("\n") | map(select(length > 0) | split("\t"))
  | map({ (.[0]): {worktree_exists: (.[1] == "true"),
                   lock_held:       (.[2] == "true"),
                   session_alive:   (.[3] == "true")} }) | add // {}
' "$PROBE_TSV")"
printf '%s' "$PROBE_JSON" > "$TMPD/probe.json"

# ---- state map: last event ts (idle) + last pr_classified decision (verdict) ----
# One jq pass over the tail snippets. fromjson? drops a truncated final line (a
# process killed mid-write) instead of losing the whole map to a lexer error.
STATE_JSON="{}"
if ls "$TMPD"/tails/*.jsonl >/dev/null 2>&1; then
  STATE_JSON="$(jq -nRc '
    reduce inputs as $line ({};
      ($line | fromjson? // null) as $e
      | if $e == null then .
        else
          (input_filename | gsub(".*/"; "") | gsub("\\.jsonl$"; "")) as $idx
          | .[$idx] = ((.[$idx] // {}) + {last_ts: $e.ts})
          | if ($e.event == "pr_classified")
            then .[$idx] = (.[$idx] + {decision: ($e.data.decision // null), pr_ts: $e.ts})
            else . end
        end)
  ' "$TMPD"/tails/*.jsonl 2>/dev/null || echo '{}')"
fi
printf '%s' "$STATE_JSON" > "$TMPD/state.json"

# ---- repos_absent as a JSON array ----
if [ -s "$ABSENT_FILE" ]; then
  REPOS_ABSENT="$(jq -R -s 'split("\n") | map(select(length > 0))' "$ABSENT_FILE")"
else
  REPOS_ABSENT="[]"
fi

# ---- assemble the document ----
NOW_EPOCH="$(date -u +%s)"
GENERATED_AT="$(date -u +%FT%TZ)"

ASSEMBLE_JQ="
def _epoch: (try fromdateiso8601 catch null);
${_STATUS_CLASSIFY_JQ}
(\$runs[0]) as \$raw
| (\$owners[0]) as \$ownermap
| (\$probe[0]) as \$probemap
| (\$state[0]) as \$statemap
| [ \$raw | to_entries[]
    | (.key | tostring) as \$is | .value as \$r
    | (\$probemap[\$is] // {}) as \$p
    | (\$statemap[\$is] // {}) as \$s
    | (\$ownermap[\$r.repo_path + \"\t\" + \$r.remote] // {}) as \$o
    | (\$o.owner // \"\") as \$owner
    | (if (\$r.repo_slug_raw // \"\") != \"\" then \$r.repo_slug_raw else (\$o.slug // \"\") end) as \$slug_eff
    | (if \$r.finished_at != null then \$r.finished_at elif \$r.started_at != null then \$r.started_at else null end) as \$age_ref
    | (if \$age_ref != null then ((\$age_ref | _epoch) as \$e | if \$e == null then null else (\$now - \$e) end) else null end) as \$age
    | (\$s.last_ts // \$r.started_at) as \$idle_ref
    | (if \$r.status == \"initialized\" and \$idle_ref != null then ((\$idle_ref | _epoch) as \$e | if \$e == null then null else (\$now - \$e) end) else null end) as \$idle
    | (if (\$r.pr_url // \"\") == \"\" then null else ((\$r.pr_url | capture(\"/(?<n>[0-9]+)/?\$\") | .n | tonumber)? // null) end) as \$prnum
    | (if \$owner == \"\" or \$r.issue_number == null then null else \"https://github.com/\(\$owner)/issues/\(\$r.issue_number)\" end) as \$iurl
    | ((\$r.host // \"\") == \"\" or (\$r.host == \$this_host)) as \$islocal
    | {
        run_id: \$r.run_id,
        run_dir: \$r.run_dir,
        repo_path: \$r.repo_path,
        repo_slug: \$slug_eff,
        owner_repo: (if \$owner == \"\" then null else \$owner end),
        remote: \$r.remote,
        issue_number: \$r.issue_number,
        issue_url: \$iurl,
        host: (if (\$r.host // \"\") == \"\" then null else \$r.host end),
        is_local: \$islocal,
        status: \$r.status,
        blocked_reason: \$r.blocked_reason,
        current_state: \$r.current_state,
        cycle_review_decision: \$r.cycle_review_decision,
        started_at: \$r.started_at,
        finished_at: \$r.finished_at,
        awaiting_answer_since: \$r.awaiting_answer_since,
        age_seconds: \$age,
        idle_seconds: \$idle,
        retry_count: \$r.retry_count,
        clarification_round: \$r.clarification_round,
        branch: \$r.branch,
        worktree_path: \$r.worktree_path,
        worktree_exists: (\$p.worktree_exists // false),
        pr_url: \$r.pr_url,
        pr_number: \$prnum,
        pr_local_verdict: (\$s.decision // null),
        pr_local_verdict_at: (\$s.pr_ts // null),
        session_alive: (\$p.session_alive // false),
        lock_held: (\$p.lock_held // false),
        schema_gaps: \$r.schema_gaps,
        github: null
      }
    | _classify(\$stale)
  ] as \$runs_final
| {
    schema_version: 1,
    generated_at: \$generated_at,
    host: \$this_host,
    stale_after_seconds: \$stale,
    enrichment: { mode: \"local\", fetched_at: null, cache_age_seconds: null,
                  repos_enriched: 0, repos_failed: [] },
    sources: { watchlist: \$watchlist, repos_configured: \$repos_configured,
               repos_scanned: \$repos_scanned, repos_absent: \$repos_absent },
    totals: {
      runs: (\$runs_final | length),
      by_class: {
        running:      ([\$runs_final[] | select(.class == \"running\")]      | length),
        stalled:      ([\$runs_final[] | select(.class == \"stalled\")]      | length),
        attention:    ([\$runs_final[] | select(.class == \"attention\")]    | length),
        pr_in_flight: ([\$runs_final[] | select(.class == \"pr_in_flight\")] | length),
        cleanup:      ([\$runs_final[] | select(.class == \"cleanup\")]      | length)
      },
      by_class_reason: (\$runs_final | group_by(.class_reason)
                        | map({key: .[0].class_reason, value: length}) | from_entries),
      by_repo: (\$runs_final | group_by(.repo_path) | map({
          repo_path: .[0].repo_path,
          repo_slug: .[0].repo_slug,
          attention: ([.[] | select(.class == \"attention\")] | length),
          cleanup:   ([.[] | select(.class == \"cleanup\")]   | length),
          runs: length
        })),
      attention_oldest_age_seconds:
        ([\$runs_final[] | select(.class == \"attention\") | .age_seconds | select(. != null)]
         | if length == 0 then null else max end),
      archived_runs: \$archived,
      degraded: (\$read_errors | length > 0)
    },
    runs: \$runs_final,
    read_errors: \$read_errors
  }
"

DOC="$(jq -n \
  --slurpfile runs "$TMPD/normalized.json" \
  --slurpfile owners "$TMPD/owners.json" \
  --slurpfile probe "$TMPD/probe.json" \
  --slurpfile state "$TMPD/state.json" \
  --argjson now "$NOW_EPOCH" \
  --argjson stale "$STALE_AFTER" \
  --argjson repos_configured "$REPOS_CONFIGURED" \
  --argjson repos_scanned "$REPOS_SCANNED" \
  --argjson repos_absent "$REPOS_ABSENT" \
  --argjson archived "$ARCHIVED" \
  --argjson read_errors "$READ_ERRORS" \
  --arg this_host "$THIS_HOST" \
  --arg generated_at "$GENERATED_AT" \
  --arg watchlist "$WATCHLIST" \
  "$ASSEMBLE_JQ")"

# --class post-filter: totals stay full, only the displayed runs[] is narrowed.
if [ -n "$CLASS_FILTER" ]; then
  DOC="$(printf '%s' "$DOC" | jq --arg cf "$CLASS_FILTER" \
    '($cf | split(",") | map(select(length > 0))) as $cs
     | .runs |= map(select(.class as $c | $cs | index($c)))')"
fi

# ---- output ----
if [ "$OUT_MODE" = "json" ]; then
  printf '%s\n' "$DOC"
else
  # -------- human summary --------
  # ANSI colour only on a TTY.
  if [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
    C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_DIM=$'\033[2m'
  else
    C_RESET=""; C_BOLD=""; C_RED=""; C_YEL=""; C_GRN=""; C_DIM=""
  fi

  degraded="$(printf '%s' "$DOC" | jq -r '.totals.degraded')"
  n_err="$(printf '%s' "$DOC" | jq -r '.read_errors | length')"

  printf '%srun-issues status%s — %s — %s — paikallinen data\n' \
    "$C_BOLD" "$C_RESET" "$THIS_HOST" "$GENERATED_AT"
  if [ "$degraded" = "true" ]; then
    printf '  %s⚠ vajaa luenta: %s lukuvirhettä%s\n' "$C_RED" "$n_err" "$C_RESET"
  fi
  printf '\n'

  # Attention list: age desc. Cap at 10 unless --class was given (then show all).
  ATT_CAP=10
  [ -n "$CLASS_FILTER" ] && ATT_CAP=100000
  n_att="$(printf '%s' "$DOC" | jq -r '[.runs[] | select(.class=="attention")] | length')"
  printf '%sHUOMIOTA VAATIVAT (%s)%s\n' "$C_BOLD" "$n_att" "$C_RESET"
  if [ "$n_att" -eq 0 ]; then
    printf '  %s(ei mitään)%s\n' "$C_DIM" "$C_RESET"
  else
    printf '%s' "$DOC" | jq -r --argjson cap "$ATT_CAP" '
      [.runs[] | select(.class=="attention")] | sort_by(.age_seconds // 0) | reverse
      | .[:$cap][]
      | "  \(.repo_slug // "?")  #\(.issue_number // "?")  \(.class_reason)  \(((.age_seconds // 0)/86400)|floor)d  \(.current_state // "-")"'
    if [ "$n_att" -gt "$ATT_CAP" ]; then
      printf '  %s… (%s lisää, --class attention näyttää kaikki)%s\n' \
        "$C_DIM" "$((n_att - ATT_CAP))" "$C_RESET"
    fi
  fi
  printf '\n'

  # One-line counters.
  read -r n_run n_stall n_pr <<<"$(printf '%s' "$DOC" | jq -r \
    '"\(.totals.by_class.running) \(.totals.by_class.stalled) \(.totals.by_class.pr_in_flight)"')"
  printf '%sKÄYNNISSÄ%s %s · %sJUMISSA%s %s · %sPR MATKALLA%s %s\n\n' \
    "$C_GRN" "$C_RESET" "$n_run" "$C_YEL" "$C_RESET" "$n_stall" "$C_GRN" "$C_RESET" "$n_pr"

  # Cleanup queue collapsed to a per-repo counter.
  n_clean="$(printf '%s' "$DOC" | jq -r '.totals.by_class.cleanup')"
  printf '%sSIIVOUSJONO (%s)%s\n' "$C_BOLD" "$n_clean" "$C_RESET"
  if [ "$n_clean" -eq 0 ]; then
    printf '  %s(tyhjä)%s\n' "$C_DIM" "$C_RESET"
  else
    printf '%s' "$DOC" | jq -r '
      .totals.by_repo[] | select(.cleanup > 0)
      | "  \(.repo_slug // "?"): \(.cleanup)"'
    printf '  %svihje: lisää auto-clean-label issueen, tai aja cleanup-run.sh --repo <path> --issue <N>%s\n' \
      "$C_DIM" "$C_RESET"
  fi
fi

# ---- exit code ----
if [ "$READ_ERRORS" != "[]" ]; then
  exit 3
fi
exit 0
