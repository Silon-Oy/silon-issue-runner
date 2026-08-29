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
#             [--github [--github-full]] [--no-cache] [--cache-ttl <s>]
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
#   --github           opt-in GitHub enrichment (lib/status-github.sh): fill each
#                      run's `github` sub-object from `gh pr list` (ONCE per
#                      owner/repo) via a TTL cache, AND emit the top-level epics[]
#                      list (open epic-labelled issues + sub-issues, issue #79).
#                      Without it every run's `github` is null, epics[] is empty,
#                      and behaviour is bit-for-bit as before.
#                      Enrichment never crashes output nor changes the local
#                      classification: an unreachable repo lands in
#                      enrichment.repos_failed, its runs stay github:null + low
#                      confidence, exit code unaffected.
#   --github-full      with --github: also split each NOT_OPEN PR into MERGED vs
#                      CLOSED (one `gh pr view` per closed PR). Both mean cleanup,
#                      hence the extra flag.
#   --no-cache         with --github: ignore any cached PR list, always fetch.
#   --cache-ttl <s>    with --github: cache freshness window (default 300, env
#                      RUN_ISSUES_STATUS_CACHE_TTL).
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
#   RUN_ISSUES_STATUS_CACHE_FILE --github cache path (default
#                                ${XDG_CACHE_HOME:-$HOME/Library/Caches}/run-issues/status-github.json)
#   RUN_ISSUES_STATUS_CACHE_TTL  --github cache TTL seconds (default 300)
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
# version.sh: runner version/pin state, for the top-level `runner` object (issue
# #105). Pure fail-soft functions, no network — reads git metadata only, so the
# runner object is available WITHOUT --github (the info is local, not GitHub).
# shellcheck source=lib/version.sh
. "$RUN_ISSUES_HOME/lib/version.sh"

# rate_limit_* (issue #126): the runner object reports an ACTIVE backoff, and the
# --github sweep stops early on a rejection instead of asking 18 more times.
# shellcheck source=lib/rate-limit.sh
. "$RUN_ISSUES_HOME/lib/rate-limit.sh"
# --github enrichment: pr_decide / pr_ci_state (pr-watch-lib.sh), gha_with_token
# (github-app-auth.sh), the shared epic child-set resolver (issue.sh's
# list_epic_children — issue #91: the view resolves epic children through the SAME
# function the runner does, never its own copy), and the enrichment/cache helpers
# (status-github.sh). All function-only, safe to source unconditionally; only
# exercised under --github.
# shellcheck source=lib/pr-watch-lib.sh
. "$RUN_ISSUES_HOME/lib/pr-watch-lib.sh"
# shellcheck source=lib/github-app-auth.sh
. "$RUN_ISSUES_HOME/lib/github-app-auth.sh"
# shellcheck source=lib/issue.sh
. "$RUN_ISSUES_HOME/lib/issue.sh"
# issue.sh carries `set -euo pipefail` (it doubles as a standalone lib for
# orchestrate.sh); status.sh deliberately runs WITHOUT errexit (it collects and
# classifies rather than aborting on the first non-zero read), so turn errexit
# back off after the source. -u / pipefail already match status.sh's own `set`.
set +e
# shellcheck source=lib/status-github.sh
. "$RUN_ISSUES_HOME/lib/status-github.sh"

STATUS_TAIL="${RUN_ISSUES_STATUS_TAIL_LINES:-40}"
STALE_AFTER="${RUN_ISSUES_STALE_AFTER:-3600}"
THIS_HOST="$(hostname -s 2>/dev/null || echo unknown)"

# ---- argument parsing ----
OUT_MODE=""          # "", json, human
CLASS_FILTER=""
REPO_FILTER=""
WATCHLIST_OVERRIDE="${RUN_ISSUES_WATCHLIST:-}"
GITHUB_MODE=0        # 1 when --github given
GITHUB_FULL=0        # 1 when --github-full given (implies --github)
NO_CACHE=0           # 1 when --no-cache given
CACHE_TTL="${RUN_ISSUES_STATUS_CACHE_TTL:-300}"

usage() {
  sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
    --github)       GITHUB_MODE=1 ;;
    --github-full)  GITHUB_MODE=1; GITHUB_FULL=1 ;;
    --no-cache)     NO_CACHE=1 ;;
    --cache-ttl)
      shift; [ "$#" -gt 0 ] || die_usage "--cache-ttl needs a value"
      case "$1" in ''|*[!0-9]*) die_usage "--cache-ttl must be a non-negative integer" ;; esac
      CACHE_TTL="$1" ;;
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

# ---- clock (shared by enrichment cache-age and the assembled document) ----
NOW_EPOCH="$(date -u +%s)"
GENERATED_AT="$(date -u +%FT%TZ)"

# ---- runner version state (issue #105) --------------------------------------
# The top-level `runner` object distinguishes "pin waiting, self-corrects" from
# "genuinely behind upstream" — two states that produced the SAME poller log line
# and one wrong "5 days behind" diagnosis (#32). Read from the package's own git
# metadata (RUN_ISSUES_HOME); NO new network call — behind_origin is only as fresh
# as the last runner_fetch_throttled, exactly like the poller. Fail-soft: outside
# a git repo every field degrades (version "?", update_state "unknown"), never an
# empty document or a non-zero exit. Available WITHOUT --github (info is local).
RUNNER_VERSION="$(runner_version "$RUN_ISSUES_HOME")"
RUNNER_BEHIND="$(runner_behind_origin "$RUN_ISSUES_HOME")"
RUNNER_PINNED="$(runner_pinned_version "$RUN_ISSUES_HOME")"
RUNNER_STATE="$(runner_update_state "$RUN_ISSUES_HOME")"
RUNNER_PIN_EPOCH="$(runner_pin_commit_epoch "$RUN_ISSUES_HOME")"
# Only an ACTIVE deadline is reported: a stale state file left over from a past
# outage must not make a healthy runner look throttled.
RUNNER_RATE_LIMIT="$(rate_limit_status_json "$(rate_limit_state_file)" "$NOW_EPOCH")"
RUNNER_JSON="$(jq -nc \
  --arg version "$RUNNER_VERSION" \
  --arg behind "$RUNNER_BEHIND" \
  --arg pinned "$RUNNER_PINNED" \
  --arg state "$RUNNER_STATE" \
  --arg pinepoch "$RUNNER_PIN_EPOCH" \
  --argjson rl "$RUNNER_RATE_LIMIT" \
  --argjson now "$NOW_EPOCH" '
  {
    version: $version,
    behind_origin: (if $behind == "" or $behind == "?" then null else ($behind | tonumber? // null) end),
    pinned_version: (if $pinned == "" then null else $pinned end),
    update_state: $state,
    pin_age_seconds: (if $pinepoch == "" then null
                      else (($now - ($pinepoch | tonumber)) as $a | if $a < 0 then 0 else $a end) end)
  } + $rl' 2>/dev/null || printf '{"version":"?","behind_origin":null,"pinned_version":null,"update_state":"unknown","pin_age_seconds":null,"rate_limited_until":null,"rate_limit_backoff_seconds":null}')"

# ---- optional GitHub enrichment (--github) ----------------------------------
# Fill each run's `github` sub-object from `gh pr list` ONCE per owner/repo,
# behind a TTL cache. Fail-soft throughout: an unreachable repo lands in
# repos_failed, its runs keep github:null + low confidence, exit code unchanged.
# GHMAP_JSON is a { "<run-index>": <ghmap-entry> } map the assembly jq joins in.
# A ghmap entry is one of: {failed:true} (repo enrichment failed, force low
# confidence) or {github:<obj>} (an OPEN or NOT_OPEN sub-object).
GHMAP_JSON="{}"
EPICS_JSON="[]"          # top-level epics[] (issue #79); [] in local mode
ENRICH_MODE="local"
ENRICH_FETCHED_AT="null"
ENRICH_CACHE_AGE="null"
ENRICH_REPOS_ENRICHED=0
ENRICH_REPOS_FAILED="[]"
if [ "$GITHUB_MODE" -eq 1 ]; then
  ENRICH_MODE="github"
  [ "$GITHUB_FULL" -eq 1 ] && ENRICH_MODE="github-full"

  # pr_decide toggles: match the pollers that actually tend these repos (both ON)
  # so pr_decide_verdict is "what the watcher would decide right now". Overridable
  # via the same env vars pr-watch reads.
  GH_RES="${PR_WATCH_ENABLE_CONFLICT_RESOLUTION:-1}"
  GH_REPAIR="${PR_WATCH_ENABLE_CI_REPAIR:-1}"
  GH_LABEL="${PR_WATCH_MERGE_LABEL:-auto-merge}"

  # Github enum: run-index <tab> issue_number <tab> pr_number <tab> owner/repo,
  # for every run that has an issue_number and a resolved owner (issue #78:
  # broadened from PR-only, so issue titles reach attention/running rows, not just
  # PR rows). pr_number is "-" (a sentinel, not empty) when the run has no PR yet:
  # `IFS=$'\t' read` collapses a genuinely empty field because tab is whitespace,
  # which would shift the owner into the wrong variable. Edge cases: no
  # issue_number => no query; unresolvable remote => no enrichment for that run.
  GH_ENUM="$TMPD/gh_enum.tsv"
  jq -r --slurpfile owners "$TMPD/owners.json" '
    ($owners[0]) as $om
    | to_entries[]
    | .key as $idx | .value as $r
    | ($om[$r.repo_path + "\t" + $r.remote].owner // "") as $owner
    | (if (($r.pr_url // "") | length) == 0 then ""
       else ((($r.pr_url | capture("/(?<n>[0-9]+)/?$") | .n)?) // "") end) as $pn
    | select($r.issue_number != null and $owner != "")
    | [$idx, ($r.issue_number | tostring),
       (if $pn == "" then "-" else $pn end), $owner] | @tsv
  ' "$TMPD/normalized.json" > "$GH_ENUM" 2>/dev/null || : > "$GH_ENUM"

  # Distinct owner/repos to query (one gh pr list + one gh issue list each).
  GH_OWNERS="$TMPD/gh_owners.txt"
  cut -f4 "$GH_ENUM" 2>/dev/null | sort -u | sed '/^$/d' > "$GH_OWNERS" || : > "$GH_OWNERS"

  # owner -> repo_slug (issue #79): epics are keyed by owner on the GitHub side
  # but the page groups by repo_slug (a LOCAL watchlist concept), so each epic
  # object needs its repo_slug injected — and it MUST match the EFFECTIVE slug the
  # runs carry (repo_slug_raw from run.json, else the computed slug), or the epic
  # lane would not join to its repo group. So derive the map from the runs' own
  # effective slug, keyed by owner; the first run per owner wins (a duplicate
  # owner from two local clones is a scope-out cross-repo case).
  OWNER_SLUG_JSON="$(jq -c --slurpfile owners "$TMPD/owners.json" '
    ($owners[0]) as $om
    | [ .[]
        | ($om[.repo_path + "\t" + .remote] // {}) as $o
        | ($o.owner // "") as $owner
        | select($owner != "")
        | {owner: $owner,
           slug: (if (.repo_slug_raw // "") != "" then .repo_slug_raw else ($o.slug // "") end)} ]
    | reduce .[] as $e ({}; if has($e.owner) then . else . + {($e.owner): $e.slug} end)
  ' "$TMPD/normalized.json" 2>/dev/null || echo '{}')"
  EPICS_FILE="$TMPD/epics.jsonl"; : > "$EPICS_FILE"

  CACHE_FILE="$(status_github_cache_file)"
  CACHE_IN="$(status_github_load_cache "$CACHE_FILE")"
  CACHE_OUT="$CACHE_IN"
  mkdir -p "$TMPD/gh"
  FAILED_FILE="$TMPD/gh_failed.txt"; : > "$FAILED_FILE"
  # Captured gh stderr for the enrichment sweep (issue #126). Inspected only to
  # tell a rate-limit rejection apart from an ordinary per-repo failure.
  GH_ENRICH_ERR="$TMPD/gh_enrich_err.txt"; : > "$GH_ENRICH_ERR"
  ENRICH_RATE_LIMITED=0
  OWNER_META="$TMPD/gh_owner_meta.tsv"; : > "$OWNER_META"  # owner \t status \t age
  gh_i=0
  MIN_FETCHED_EPOCH=""
  MIN_FETCHED_AT=""
  MAX_AGE=""

  while IFS= read -r owner; do
    [ -n "$owner" ] || continue
    prs=""
    issues=""
    epics=""
    issue_details=""
    fetched_at=""
    fetched_epoch=""
    used_cache=0

    # Cache hit? Entry present, fresh, and caching not disabled. One entry per
    # owner holds BOTH the PR list and the issue-title list (issue #78), fetched
    # together under one TTL, so a cache hit serves both with no gh call.
    if [ "$NO_CACHE" -ne 1 ]; then
      cached="$(printf '%s' "$CACHE_IN" | jq -c --arg k "$owner" '.[$k] // empty' 2>/dev/null || true)"
      if [ -n "$cached" ]; then
        c_epoch="$(printf '%s' "$cached" | jq -r '.fetched_epoch // empty' 2>/dev/null || true)"
        # A fresh entry that PRE-DATES issue_details (issue #103's key) must be
        # treated as STALE, not empty: the #96 bug was a fresh legacy entry lacking
        # the new key served as {} on the cache-hit path, silently skipping the
        # per-issue reads. Requiring the key present forces a one-time refetch after
        # deploy, then cache hits work; a fresh entry legitimately WITHOUT any
        # closed issue still carries the key as {} (always written below).
        if [ -n "$c_epoch" ] \
           && printf '%s' "$cached" | jq -e 'has("issue_details")' >/dev/null 2>&1; then
          age=$((NOW_EPOCH - c_epoch))
          if [ "$age" -ge 0 ] && [ "$age" -le "$CACHE_TTL" ]; then
            prs="$(printf '%s' "$cached" | jq -c '.prs // []' 2>/dev/null || echo '[]')"
            issues="$(printf '%s' "$cached" | jq -c '.issues // []' 2>/dev/null || echo '[]')"
            # Epics are cached fully RESOLVED (sub_issues already fetched), so a
            # cache hit serves them with no gh/api call (issue #79). Legacy cache
            # entries without .epics degrade to [].
            epics="$(printf '%s' "$cached" | jq -c '.epics // []' 2>/dev/null || echo '[]')"
            # Per-issue detail reads (state + stateReason + title) for issues absent
            # from the open list are cached in the same owner entry (issue #96 read
            # #103): a cache hit serves them with no gh call, so the read runs at
            # most once per issue per TTL window.
            issue_details="$(printf '%s' "$cached" | jq -c '.issue_details // {}' 2>/dev/null || echo '{}')"
            fetched_at="$(printf '%s' "$cached" | jq -r '.fetched_at // empty' 2>/dev/null || true)"
            fetched_epoch="$c_epoch"
            used_cache=1
          fi
        fi
      fi
    fi

    # Cache miss / stale / disabled => fetch once. The PR fetch is the PRIMARY
    # enrichment and owns repos_failed; the issue-title fetch is best-effort on
    # top (a failure only drops titles for this repo, never marks it failed).
    if [ "$used_cache" -ne 1 ]; then
      if prs="$(status_github_fetch_open_prs "$owner" 2>>"$GH_ENRICH_ERR")" && [ -n "$prs" ] \
         && printf '%s' "$prs" | jq -e 'type == "array"' >/dev/null 2>&1; then
        fetched_at="$GENERATED_AT"
        fetched_epoch="$NOW_EPOCH"
        # Best-effort issue titles: empty array on any failure (=> no titles).
        if ! issues="$(status_github_fetch_open_issues "$owner")" \
           || [ -z "$issues" ] \
           || ! printf '%s' "$issues" | jq -e 'type == "array"' >/dev/null 2>&1; then
          issues="[]"
        fi
        # Best-effort epics (issue #79): fetch the open epic-labelled issues and
        # resolve each one's sub-issues (native API, task-list fallback). The
        # open-issue TITLE map doubles as the authoritative open/closed source for
        # the task-list fallback. A failure => no epics for this repo, never a
        # repos_failed mark (the PR fetch owns that).
        epics_raw="$(status_github_fetch_epics "$owner")"
        if [ -z "$epics_raw" ] || ! printf '%s' "$epics_raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
          epics_raw="[]"
        fi
        openmap="$(status_github_build_issue_map "$issues")"
        epics="$(status_github_build_epics "$owner" "$epics_raw" "$openmap")"
        [ -n "$epics" ] || epics="[]"
        # Resolve issue detail (state + stateReason + title) for every issue a run
        # references that is ABSENT from the open-issue map (issue #96 read #103,
        # broadened from no-PR runs to ALL runs so PR rows also carry issue_state).
        # Absence is a hint, not proof (the open fetch is best-effort), so confirm
        # each with one explicit `gh issue view` — the SAME call yields the closed
        # issue's title, which --state open cannot. The result is cached in this
        # owner's entry, so the read runs at most once per issue per TTL window
        # (criterion 6/AC5) and is deduped across runs => bounded by the number of
        # DISTINCT closed issues, never linear in runs. An open issue is skipped
        # (the map already proves it open + carries its title); a read that fails is
        # not recorded (=> null => local class stands, fail-soft).
        issue_details="{}"
        while IFS=$'\t' read -r _ e_issue e_pn e_owner; do
          [ "$e_owner" = "$owner" ] || continue
          [ -n "$e_issue" ] || continue
          # Already resolved (a duplicate issue across two runs)? Skip the 2nd read.
          if printf '%s' "$issue_details" | jq -e --arg k "$e_issue" 'has($k)' >/dev/null 2>&1; then
            continue
          fi
          # In the open map => definitely open, no read needed.
          if printf '%s' "$openmap" | jq -e --arg k "$e_issue" 'has($k)' >/dev/null 2>&1; then
            continue
          fi
          det="$(status_github_issue_detail "$owner" "$e_issue")"
          [ -n "$det" ] || continue
          issue_details="$(printf '%s' "$issue_details" | jq -c --arg k "$e_issue" --argjson v "$det" '.[$k]=$v' 2>/dev/null || printf '%s' "$issue_details")"
        done < "$GH_ENUM"
        # Refresh this owner's cache entry (PRs + issue titles + epics + details).
        CACHE_OUT="$(printf '%s' "$CACHE_OUT" | jq -c \
          --arg k "$owner" --argjson prs "$prs" --argjson issues "$issues" \
          --argjson epics "$epics" --argjson idet "$issue_details" \
          --arg fa "$fetched_at" --argjson fe "$fetched_epoch" \
          '.[$k] = {fetched_at:$fa, fetched_epoch:$fe, prs:$prs, issues:$issues, epics:$epics, issue_details:$idet}' 2>/dev/null || printf '%s' "$CACHE_OUT")"
      else
        # Network failure / rate limit / bad payload => this repo failed.
        printf '%s\n' "$owner" >> "$FAILED_FILE"
        # A rate-limit rejection is not this repo's problem, it is the account's
        # (issue #126): the remaining owners would fail identically, and each
        # rejection feeds the limit that produced it. Stop the sweep. Enrichment
        # stays fail-soft — the document is still emitted and the un-attempted
        # repos simply keep their local classification (github: null), exactly as
        # if they had been unreachable. status.sh does NOT trip the shared backoff:
        # it is a read-only view, and a page refresh must not be able to throttle
        # the pollers.
        if rate_limit_file_matches "$GH_ENRICH_ERR"; then
          ENRICH_RATE_LIMITED=1
          break
        fi
        continue
      fi
    fi
    [ -n "$issues" ] || issues="[]"
    [ -n "$epics" ] || epics="[]"
    [ -n "$issue_details" ] || issue_details="{}"

    # Emit this owner's epics to the top-level epics[] accumulator, injecting the
    # repo_slug the page groups by (issue #79). One JSONL line per epic. Each
    # sub-issue ALSO gets a repo_slug (issue #92): its home owner/repo mapped to
    # the local slug via OWNER_SLUG_JSON (a cross-repo child in a locally-run repo
    # joins to its own run and group), falling back to the epic's slug when the
    # child is same-repo and to the repo basename when the child repo has no local
    # run. repo_slug is a LOCAL concept, so it is injected here at emit — never in
    # the cached GitHub payload.
    slug_for_epic="$(printf '%s' "$OWNER_SLUG_JSON" | jq -r --arg o "$owner" '.[$o] // ""' 2>/dev/null || true)"
    printf '%s' "$epics" | jq -c --arg slug "$slug_for_epic" --argjson om "$OWNER_SLUG_JSON" '
      if type == "array" then .[] else empty end
      | .sub_issues = ((.sub_issues // []) | map(
          . + {repo_slug: (
            (.repo // "") as $r
            | if $r == "" then $slug
              elif ($om[$r] // "") != "" then $om[$r]
              else ($r | sub(".*/"; ""))
              end)}))
      | {repo_slug: $slug} + .' \
      >> "$EPICS_FILE" 2>/dev/null || true

    age=$((NOW_EPOCH - fetched_epoch))
    [ "$age" -ge 0 ] || age=0
    # Track the STALEST data so the top-level cache_age_seconds never looks fresher
    # than the oldest repo (issue #60: old data must not look fresh).
    if [ -z "$MAX_AGE" ] || [ "$age" -gt "$MAX_AGE" ]; then MAX_AGE="$age"; fi
    if [ -z "$MIN_FETCHED_EPOCH" ] || [ "$fetched_epoch" -lt "$MIN_FETCHED_EPOCH" ]; then
      MIN_FETCHED_EPOCH="$fetched_epoch"
      MIN_FETCHED_AT="$fetched_at"
    fi

    # Build the number->github map for this owner (ci + verdict per open PR) and
    # the issue_number->meta map (issue #78 title + issue #96/#103 state/reason).
    prmap="$(status_github_build_pr_map "$prs" "$fetched_at" "$age" "$GH_LABEL" "$GH_RES" "$GH_REPAIR")"
    printf '%s' "$prmap" > "$TMPD/gh/$gh_i.prmap.json"
    # One per-owner issue-meta map: { "<n>": {state, state_reason, title, labels} },
    # keyed by issue number, merging the OPEN list (state OPEN, reason null, title +
    # whitelisted labels from the open list) with the per-issue detail reads for
    # ABSENT issues (state CLOSED/OPEN, reason, title, labels). status.sh joins this
    # against each run's issue_number at assembly so EVERY github object (open PR,
    # NOT_OPEN, issue-only) carries issue_title + issue_state + issue_state_reason +
    # issue_labels uniformly (issue #103 AC1/AC2, issue #106). The label map is
    # rebuilt from the cached `issues` array (which now carries labels), so a cache
    # hit serves labels with no gh call; the detail reads already carry labels.
    openmap="$(status_github_build_issue_map "$issues")"
    openlabels="$(status_github_build_issue_labels_map "$issues")"
    issuemeta="$(jq -nc --argjson om "$openmap" --argjson lm "$openlabels" --argjson det "$issue_details" '
      (($om | to_entries
        | map({key: .key, value: {state: "OPEN", state_reason: null, title: .value,
                                  labels: ($lm[.key] // [])}}))
       | from_entries) + $det')"
    [ -n "$issuemeta" ] || issuemeta="{}"
    printf '%s' "$issuemeta" > "$TMPD/gh/$gh_i.issuemeta.json"
    printf '%s\t%s\t%s\n' "$owner" "$gh_i" "$age" >> "$OWNER_META"
    printf '%s\t%s\n' "$owner" "$fetched_at" >> "$TMPD/gh_owner_fetched.tsv"
    ENRICH_REPOS_ENRICHED=$((ENRICH_REPOS_ENRICHED + 1))
    gh_i=$((gh_i + 1))
  done < "$GH_OWNERS"

  # Persist the refreshed cache (best-effort, atomic).
  status_github_write_cache "$CACHE_FILE" "$CACHE_OUT"

  # repos_failed as a JSON array.
  if [ -s "$FAILED_FILE" ]; then
    ENRICH_REPOS_FAILED="$(jq -R -s 'split("\n") | map(select(length > 0))' "$FAILED_FILE")"
  fi

  # Map each enumerated run to its ghmap entry.
  # owner -> prmap/issuemeta index + age lookup (built above). Every run carries a
  # github object: an OPEN-PR object, a NOT_OPEN object, or (no PR yet) an
  # issue-only object — and each gets issue_title + issue_state + issue_state_reason
  # joined in from the per-owner issue-meta map by issue_number (issue #78/#96/#103).
  GHMAP_FILE="$TMPD/ghmap.jsonl"; : > "$GHMAP_FILE"
  while IFS=$'\t' read -r idx issue pn owner; do
    [ -n "$idx" ] || continue
    [ "$pn" = "-" ] && pn=""   # sentinel back to empty (no PR)
    # Failed repo?
    if grep -Fxq "$owner" "$FAILED_FILE" 2>/dev/null; then
      jq -nc --arg i "$idx" '{($i): {failed:true}}' >> "$GHMAP_FILE"
      continue
    fi
    # Look up this owner's prmap/issuemeta index + age.
    meta="$(grep -F "$owner"$'\t' "$OWNER_META" 2>/dev/null | head -n1 || true)"
    [ -n "$meta" ] || continue
    pmi="$(printf '%s' "$meta" | cut -f2)"
    page="$(printf '%s' "$meta" | cut -f3)"
    fetched_at="$(grep -F "$owner"$'\t' "$TMPD/gh_owner_fetched.tsv" 2>/dev/null | head -n1 | cut -f2 || true)"
    obj=""
    if [ -n "$pn" ]; then
      obj="$(jq -c --arg k "$pn" '.[$k] // empty' "$TMPD/gh/$pmi.prmap.json" 2>/dev/null || true)"
    fi
    if [ -n "$obj" ]; then
      # Open PR.
      base="$obj"
    elif [ -n "$pn" ]; then
      # Has a PR URL but it is not in the open set => NOT_OPEN. Optionally
      # resolve MERGED/CLOSED.
      closed_as=""
      if [ "$GITHUB_FULL" -eq 1 ]; then
        closed_as="$(status_github_closed_state "$owner" "$pn")"
      fi
      base="$(status_github_not_open_object "$fetched_at" "$page" "$closed_as")"
    else
      # No PR yet => an issue-only object (title, no PR fields / chips).
      base="$(status_github_issue_only_object "$fetched_at" "$page")"
    fi
    # Join the issue meta in by issue_number: title + state + state_reason + labels
    # (issue #78/#96/#103/#106). An absent issue (unread / read-failed / no meta) =>
    # title/state/reason null and labels [], so the row keeps its V1 shape and the
    # local class stands (fail-soft). The OPEN-PR branch above still wins
    # classification (the reclassifier's OPEN branch returns before the issue_state
    # elif), so setting issue_state/issue_labels on a PR object is view-only — it
    # never reclassifies (scope-out: classification is #96).
    jq -nc --arg i "$idx" --argjson o "$base" \
      --slurpfile mm "$TMPD/gh/$pmi.issuemeta.json" --arg k "$issue" \
      '($mm[0][$k] // {}) as $m
       | {($i): {github: ($o + {
            issue_title: ($m.title // null),
            issue_state: ($m.state // null),
            issue_state_reason: ($m.state_reason // null),
            issue_labels: ($m.labels // [])
          })}}' >> "$GHMAP_FILE"
  done < "$GH_ENUM"

  if [ -s "$GHMAP_FILE" ]; then
    GHMAP_JSON="$(jq -s -c 'add // {}' "$GHMAP_FILE")"
  fi

  # Assemble the top-level epics[] from the per-owner accumulator (issue #79).
  if [ -s "$EPICS_FILE" ]; then
    EPICS_JSON="$(jq -s -c '.' "$EPICS_FILE" 2>/dev/null || echo '[]')"
  fi

  # Top-level enrichment provenance: stalest age wins.
  if [ -n "$MAX_AGE" ]; then ENRICH_CACHE_AGE="$MAX_AGE"; fi
  if [ -n "$MIN_FETCHED_AT" ]; then
    ENRICH_FETCHED_AT="$(jq -nc --arg v "$MIN_FETCHED_AT" '$v')"
  fi
fi
printf '%s' "$GHMAP_JSON" > "$TMPD/ghmap.json"

ASSEMBLE_JQ="
def _epoch: (try fromdateiso8601 catch null);
${_STATUS_CLASSIFY_JQ}
${_STATUS_GITHUB_RECLASSIFY_JQ}
(\$runs[0]) as \$raw
| (\$owners[0]) as \$ownermap
| (\$probe[0]) as \$probemap
| (\$state[0]) as \$statemap
| (\$ghmap[0]) as \$ghmap
| [ \$raw | to_entries[]
    | (.key | tostring) as \$is | .value as \$r
    | (\$probemap[\$is] // {}) as \$p
    | (\$statemap[\$is] // {}) as \$s
    | (\$ghmap[\$is] // null) as \$gh
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
        github: (if \$gh == null then null
                 elif (\$gh.failed == true) then null
                 else \$gh.github end)
      }
    | _classify(\$stale)
    | (if (\$gh != null and \$gh.failed == true) then . + {class_confidence: \"low\"} else . end)
    | _github_reclassify
  ] as \$runs_final
| {
    schema_version: 1,
    generated_at: \$generated_at,
    host: \$this_host,
    stale_after_seconds: \$stale,
    runner: \$runner,
    enrichment: { mode: \$enrich_mode, fetched_at: \$enrich_fetched_at,
                  cache_age_seconds: \$enrich_cache_age,
                  repos_enriched: \$enrich_repos_enriched,
                  repos_failed: \$enrich_repos_failed },
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
    epics: \$epics,
    read_errors: \$read_errors
  }
"

DOC="$(jq -n \
  --slurpfile runs "$TMPD/normalized.json" \
  --slurpfile owners "$TMPD/owners.json" \
  --slurpfile probe "$TMPD/probe.json" \
  --slurpfile state "$TMPD/state.json" \
  --slurpfile ghmap "$TMPD/ghmap.json" \
  --argjson epics "$EPICS_JSON" \
  --argjson runner "$RUNNER_JSON" \
  --argjson now "$NOW_EPOCH" \
  --argjson stale "$STALE_AFTER" \
  --argjson repos_configured "$REPOS_CONFIGURED" \
  --argjson repos_scanned "$REPOS_SCANNED" \
  --argjson repos_absent "$REPOS_ABSENT" \
  --argjson archived "$ARCHIVED" \
  --argjson read_errors "$READ_ERRORS" \
  --arg enrich_mode "$ENRICH_MODE" \
  --argjson enrich_fetched_at "$ENRICH_FETCHED_AT" \
  --argjson enrich_cache_age "$ENRICH_CACHE_AGE" \
  --argjson enrich_repos_enriched "$ENRICH_REPOS_ENRICHED" \
  --argjson enrich_repos_failed "$ENRICH_REPOS_FAILED" \
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

  if [ "$GITHUB_MODE" -eq 1 ]; then
    gh_age="$(printf '%s' "$DOC" | jq -r '.enrichment.cache_age_seconds // "?"')"
    gh_failed="$(printf '%s' "$DOC" | jq -r '.enrichment.repos_failed | length')"
    printf '%srun-issues status%s — %s — %s — GitHub-rikastus (cache %ss vanha' \
      "$C_BOLD" "$C_RESET" "$THIS_HOST" "$GENERATED_AT" "$gh_age"
    if [ "$gh_failed" != "0" ]; then
      printf ', %s%s repoa epäonnistui%s' "$C_RED" "$gh_failed" "$C_RESET"
    fi
    printf ')\n'
  else
    printf '%srun-issues status%s — %s — %s — paikallinen data\n' \
      "$C_BOLD" "$C_RESET" "$THIS_HOST" "$GENERATED_AT"
  fi
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
