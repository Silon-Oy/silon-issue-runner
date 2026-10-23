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
#   PR_WATCH_ENABLE_CI_REPAIR            default 0 — OFF. When 1, a green-label PR
#                                        whose CI has gone RED is handed to an AI
#                                        agent that fixes the REAL failure in the
#                                        feature worktree (never main), commits,
#                                        and the watcher revalidates CI before the
#                                        merge. The agent may NOT cheat CI green
#                                        (no deleting/skipping tests, no loosening
#                                        assertions). If it cannot fix the failure
#                                        durably, or CI stays red, the PR is handed
#                                        to a human (exit 8). Same machinery as the
#                                        conflict path (worktree agent + mandatory
#                                        CI revalidation + human handover).
#   PR_WATCH_MAX_CI_REPAIRS              default 1 — attempt cap for CI repair per
#                                        PR, derived from the run-dir event log
#                                        (pr_ci_repair_attempted) so it survives
#                                        the watcher's statelessness.
#   PR_WATCH_CI_REPAIR_TIMEOUT           default 1800 — wall-clock budget (s) for
#                                        the AI CI-repair claude call.
#   PR_WATCH_CI_LOG_MAX                  default 60000 — byte cap on the failed-CI
#                                        log excerpt fed to the agent's prompt.
#   PR_WATCH_CI_EMPTY_GRACE_SECS         default 120 — after a push, an EMPTY
#                                        statusCheckRollup on the pushed SHA is
#                                        PENDING until it has stayed empty this
#                                        long, then GREEN (checkless repo, #354).
#                                        Never GREEN when the PR had checks
#                                        before the push (the repo has CI).
#                                        Keep below (PR_WATCH_CI_MAX_POLLS - 1) ×
#                                        PR_WATCH_CI_POLL_SECS or a checkless
#                                        repo times out instead.
#   PR_WATCH_ENABLE_SECURITY_GATE        default 0 — OFF. When 1, every merge
#                                        (MERGE, and REBASE / FIX_CI once they are
#                                        green) first passes the security MERGE
#                                        GATE (issue #334): an agent reviews the
#                                        PR's FINAL diff (base...head) in a fresh
#                                        context. Findings at or above the hold
#                                        threshold are fixed by an agent in the
#                                        feature worktree, CI is revalidated and
#                                        the new head is reviewed again. If the fix
#                                        fails, the cap is spent or the review
#                                        cannot run, the PR is held for a human
#                                        (exit 10). The result is recorded per head
#                                        SHA, so a head is reviewed once.
#   PR_WATCH_MAX_SECURITY_FIXES          default 1 — fix-attempt cap per PR
#                                        (merge_gate_fix_attempted events, read
#                                        from the tail of state.jsonl).
#   PR_WATCH_SECURITY_REVIEW_TIMEOUT     default 1800 — budget (s) for the review call.
#   PR_WATCH_SECURITY_FIX_TIMEOUT        default 1800 — budget (s) for the fix call.
#   PR_WATCH_SECURITY_HOLD_MIN_SEVERITY  default high — the least severe finding
#                                        that holds the merge (critical|high|
#                                        medium|low). The target repo's
#                                        .claude/run-issues.json
#                                        `.security.hold_min_severity`, read from
#                                        the BASE branch, WINS over this value.
#   PR_WATCH_SECURITY_REVIEWER           default claude — who REVIEWS for the
#                                        security gate: claude | codex (issue
#                                        #335). Another model family sees what the
#                                        author's does not. Fixes are always made by
#                                        the claude agent. Codex selected but
#                                        missing / failing / unparseable, or an
#                                        unknown value => the review did not
#                                        happen => held; never a silent fall back
#                                        to claude, never a pass.
#   PR_WATCH_CODEX_CMD                   default "codex" — the Codex CLI invocation
#                                        (tokens; `exec …` is appended). Override =
#                                        own driver or a test stub.
#   PR_WATCH_ENABLE_SEMANTIC_CHECK       default 0 — OFF. When 1, a second merge
#                                        gate (issue #341) looks for a SEMANTIC
#                                        conflict: a sibling runner PR (auto-run/
#                                        head) merged into the base since this run
#                                        started, whose changes share a directory
#                                        with this PR's. That trigger is one REST
#                                        listing + local git and calls no agent;
#                                        no overlap => the gate passes. On overlap
#                                        an agent compares this PR with the
#                                        siblings' diffs; a duplicate is fixed IN
#                                        THIS PR (the merged code wins), CI is
#                                        revalidated, or the PR is held (exit 10).
#                                        The record is keyed by head AND base SHA.
#   PR_WATCH_MAX_SEMANTIC_FIXES          default 1 — fix-attempt cap per PR.
#   PR_WATCH_SEMANTIC_REVIEW_TIMEOUT     default 1800 — budget (s) for the review call.
#   PR_WATCH_SEMANTIC_FIX_TIMEOUT        default 1800 — budget (s) for the fix call.
#   PR_WATCH_SEMANTIC_HOLD_MIN_SEVERITY  default low — every reported conflict
#                                        is fixed or held. The base branch's
#                                        `.semantic.hold_min_severity` wins.
#   PR_WATCH_SEMANTIC_CONTEXT_MAX        default 60000 — byte cap on the sibling
#                                        diffs in the prompt (lib/semantic-gate.sh).
#   PR_WATCH_GATE_TAIL_LINES             default 1000 — state.jsonl tail window
#                                        the gate reads (lib/merge-gate.sh).
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
#      left for inspection, PR commented, needs-human label added)
#   7  post-merge migration failed
#   8  red CI needs a human (AI could not repair / CI stayed red / attempt cap
#      reached — PR commented, needs-human label added)
#   9  gh is missing or unauthenticated (checked once per run before the first PR
#      call, same lib/preflight.sh mechanism as the orchestrator's S0 gate) — a
#      durable condition, not the transient "retry next poll" of code 4
#   10 a merge gate held the PR for a human (findings at or above the hold
#      threshold the agent could not fix, fix cap spent, or the review could not
#      run — PR commented with the findings, needs-human label added)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The watcher uses the same env file (~/.config/run-issues/env) as the
# orchestrator: it's a LaunchAgent that does not inherit the interactive shell.
#
# Issue #144 factored this into lib/machine-env.sh, which the orchestrator also
# uses. The comment that used to stand here justified the duplication by the two
# copies' different logging — but the duplication is what let the precedence bug
# exist in two places at once, and _machine_env_log resolves the logging
# difference by discovering the caller's `log` (the lib/run-terminate.sh pattern).
# The rule the shared helper enforces: inside RUN_ISSUES_*/PR_WATCH_* the
# caller's already-set value WINS over the file; secrets keep file-wins.
#
# Sourced and captured FIRST (issue #200), before every other library, because
# "already set" has to mean the process environment as this script was invoked.
# Taken any later it also covered lib/claude-call.sh's own `${VAR:-default}`
# assignments, so the package's own default was restored over the env file's
# RUN_ISSUES_CLAUDE_CMD and the file could not name the CLI at all. Pure function
# definitions; source_machine_env still runs at its old place below.
# shellcheck source=lib/machine-env.sh
. "$SCRIPT_DIR/lib/machine-env.sh"
machine_env_capture
# Windows/Git Bash: give `jq` its --binary flag so its output is LF, not CRLF.
# Sourced before every library that reads jq output (lib/jq-binary.sh); only
# lib/machine-env.sh above precedes it, and it never calls jq.
# shellcheck source=lib/jq-binary.sh
. "$SCRIPT_DIR/lib/jq-binary.sh"
# shellcheck source=lib/git-remote.sh
# Multi-remote routing (issue #33): resolve_remote_to_owner_repo is the fallback
# owner/repo derivation for a non-origin run whose run.json predates the
# .owner_repo field. Pure functions; no top-level work.
. "$SCRIPT_DIR/lib/git-remote.sh"
# shellcheck source=lib/locking.sh
. "$SCRIPT_DIR/lib/locking.sh"
# shellcheck source=lib/host.sh
# runner_host (issue #213): THIS_HOST is compared against run.json.host, so
# both sides must come from the same resolver.
. "$SCRIPT_DIR/lib/host.sh"
# shellcheck source=lib/state.sh
. "$SCRIPT_DIR/lib/state.sh"
# shellcheck source=lib/pr-watch-lib.sh
. "$SCRIPT_DIR/lib/pr-watch-lib.sh"
# shellcheck source=lib/merge-gate.sh
# The merge gate's pure parts (issue #334): result parsing, the head-SHA and
# attempt bookkeeping read from state.jsonl's tail, the severity threshold.
. "$SCRIPT_DIR/lib/merge-gate.sh"
# shellcheck source=lib/semantic-gate.sh
# The semantic gate's trigger (issue #341): sibling listing filter, spans, dirs.
. "$SCRIPT_DIR/lib/semantic-gate.sh"
# shellcheck source=lib/security-scan.sh
# Optional deterministic scanners (issue #336) a gate can feed its reviewer.
. "$SCRIPT_DIR/lib/security-scan.sh"

# rate_limit_* (issue #126): the watcher spends the SAME GitHub quota as the
# pollers, so it must be able to trip the shared backoff. Functions only.
# shellcheck source=lib/rate-limit.sh
. "$SCRIPT_DIR/lib/rate-limit.sh"
# shellcheck source=lib/claude-call.sh
. "$SCRIPT_DIR/lib/claude-call.sh"
# shellcheck source=lib/preflight.sh
# Shared dependency probe. Reused for the CI-repair path's claude-CLI preflight
# (issue #45): the orchestrator's S0 gate already catches the claude CLI's
# silent 127 before a run starts, but the watcher's FIX_CI classification called
# the same CLI with no such guard, so a missing agent produced rc=127, a
# misleading "agent found no fix" comment, and a permanently blocked PR. This
# gives the watcher the identical probe. RUN_ISSUES_CLAUDE_CMD{,_DEFAULT} come
# from claude-call.sh, sourced above.
. "$SCRIPT_DIR/lib/preflight.sh"
# shellcheck source=lib/labels.sh
# Label writes go through the REST helpers (no read:project scope needed). Every
# human-handover path — CI repair AND both conflict paths — attaches the
# needs-human label through these, via the shared _pr_mark_needs_human helper.
. "$SCRIPT_DIR/lib/labels.sh"
# shellcheck source=lib/github-app-auth.sh
# Opt-in GitHub App identity (same env vars as the orchestrator). gha_with_token
# is a pass-through when App mode is off, so wrapping every gh call here is
# regression-free for repos that don't configure the App.
#
# lib/machine-env.sh is sourced and captured at the TOP of this section, before
# every other library — see the comment there. Only the injection happens here.
source_machine_env
# shellcheck source=lib/github-app-auth.sh
. "$SCRIPT_DIR/lib/github-app-auth.sh"

PR_WATCH_AUTO="${PR_WATCH_AUTO:-0}"
PR_WATCH_ENABLE_CONFLICT_RESOLUTION="${PR_WATCH_ENABLE_CONFLICT_RESOLUTION:-0}"
PR_WATCH_CONFLICT_TIMEOUT="${PR_WATCH_CONFLICT_TIMEOUT:-1800}"
PR_WATCH_ENABLE_CI_REPAIR="${PR_WATCH_ENABLE_CI_REPAIR:-0}"
PR_WATCH_MAX_CI_REPAIRS="${PR_WATCH_MAX_CI_REPAIRS:-1}"
PR_WATCH_CI_REPAIR_TIMEOUT="${PR_WATCH_CI_REPAIR_TIMEOUT:-1800}"
PR_WATCH_CI_LOG_MAX="${PR_WATCH_CI_LOG_MAX:-60000}"
PR_WATCH_ENABLE_SECURITY_GATE="${PR_WATCH_ENABLE_SECURITY_GATE:-0}"
PR_WATCH_MAX_SECURITY_FIXES="${PR_WATCH_MAX_SECURITY_FIXES:-1}"
PR_WATCH_SECURITY_REVIEW_TIMEOUT="${PR_WATCH_SECURITY_REVIEW_TIMEOUT:-1800}"
PR_WATCH_SECURITY_FIX_TIMEOUT="${PR_WATCH_SECURITY_FIX_TIMEOUT:-1800}"
PR_WATCH_SECURITY_HOLD_MIN_SEVERITY="${PR_WATCH_SECURITY_HOLD_MIN_SEVERITY:-}"
PR_WATCH_SECURITY_REVIEWER="${PR_WATCH_SECURITY_REVIEWER:-claude}"
PR_WATCH_ENABLE_SEMANTIC_CHECK="${PR_WATCH_ENABLE_SEMANTIC_CHECK:-0}"
PR_WATCH_MAX_SEMANTIC_FIXES="${PR_WATCH_MAX_SEMANTIC_FIXES:-1}"
PR_WATCH_SEMANTIC_REVIEW_TIMEOUT="${PR_WATCH_SEMANTIC_REVIEW_TIMEOUT:-1800}"
PR_WATCH_SEMANTIC_FIX_TIMEOUT="${PR_WATCH_SEMANTIC_FIX_TIMEOUT:-1800}"
PR_WATCH_SEMANTIC_HOLD_MIN_SEVERITY="${PR_WATCH_SEMANTIC_HOLD_MIN_SEVERITY:-low}"
PR_WATCH_CODEX_CMD_DEFAULT="codex"
PR_WATCH_CODEX_CMD="${PR_WATCH_CODEX_CMD:-$PR_WATCH_CODEX_CMD_DEFAULT}"
PR_WATCH_MERGE_LABEL="${PR_WATCH_MERGE_LABEL:-auto-merge}"
PR_WATCH_LABELS_CSV="${PR_WATCH_LABELS_CSV:-}"

# The merge gates, in the order they run before P6 (issue #334). Each name has
# its content in _merge_gate_spec; the mechanism (pr_run_merge_gate) is shared.
MERGE_GATES="security semantic"

usage() {
  echo "usage: pr-watch.sh [--remote <name>] <repo-root> <pr-number|scan>" >&2
  exit 1
}

# Optional `--remote <name>` flag before the two positional args (issue #33).
# It is a SCAN filter + candidate-count label only: gh/git routing is derived
# per-run from run.json below, so `--remote` never overrides where a given PR is
# addressed — it just partitions which completed runs this invocation scans, so
# the poller can spawn one scan session per remote of a multi-remote clone. Empty
# (flag omitted, the legacy invocation) means "scan every remote's runs". Both
# `--remote <name>` and `--remote=<name>` shapes are accepted (mirrors
# orchestrate.sh).
REMOTE_FILTER=""
while :; do
  case "${1:-}" in
    --remote)   REMOTE_FILTER="${2:-}"; shift 2 || true ;;
    --remote=*) REMOTE_FILTER="${1#*=}"; shift ;;
    *) break ;;
  esac
done

[ "$#" -eq 2 ] || usage
REPO_ROOT="$1"
TARGET="$2"
[ -d "$REPO_ROOT/.git" ] || { echo "pr-watch: not a git repo: $REPO_ROOT" >&2; exit 1; }

RUNS_DIR="$REPO_ROOT/.claude/run-issues"
THIS_HOST="$(runner_host)"

# Per-PR routing (issues #33/#53), set at the top of watch_one from the run's OWN
# remote recorded in run.json. PR_OWNER_REPO routes gh via `--repo owner/repo` so
# a PR that lives in a non-origin org is addressed there instead of gh's cwd
# (origin) inference; PR_ROUTE_REMOTE is the git remote NAME used for
# fetch/push/rebase so the rebase + CI-repair paths target the PR's real remote.
# Both default to the legacy single-remote shape: an empty owner/repo means gh
# falls back to cwd inference, and the remote name is "origin".
PR_OWNER_REPO=""
PR_ROUTE_REMOTE="origin"

log() { printf '%s pr-watch: %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

# gh_route <gh-args…> — run gh in REPO_ROOT under the App token, appending
# `--repo <owner/repo>` when the current PR's owner/repo is known (PR_OWNER_REPO)
# so a non-origin remote reaches the right org. An empty PR_OWNER_REPO appends
# nothing, i.e. gh's legacy cwd-based inference (origin) — so single-remote repos
# and every existing gh mock behave exactly as before. The flag is appended LAST,
# a position every gh subcommand here accepts, which also keeps the tests' gh
# mocks (which switch on `$1 $2`) unaffected.
gh_route() {
  local repo_args=()
  # `gh api` carries the repository in the PATH, not in a flag, and rejects
  # --repo outright — so the routing that every other subcommand needs would
  # break the one call that addresses the repo by name.
  [ -n "$PR_OWNER_REPO" ] && [ "${1:-}" != "api" ] && repo_args=(--repo "$PR_OWNER_REPO")
  # ${repo_args[@]+"${repo_args[@]}"} expands to nothing when the array is empty
  # WITHOUT tripping `set -u` on bash 3.2 (macOS), which otherwise errors
  # "unbound variable" on a bare "${repo_args[@]}" for an empty array.
  #
  # Every gh call the watcher makes passes through here, which makes this the
  # one place a rate-limit rejection can be seen (issue #126). stderr is captured
  # rather than inherited so it can be INSPECTED, then re-emitted unchanged so
  # nothing downstream loses an error message. On a rejection we trip the backoff
  # the pollers share and set PR_RATE_LIMITED, which stops the scan loop — the
  # alternative is what the 2026-08-28 outage did: keep asking, and keep feeding
  # the limit that is refusing us.
  local err rc=0
  err=$(mktemp -t pr-watch-gh-err.XXXXXX)
  ( cd "$REPO_ROOT" && gha_with_token gh "$@" ${repo_args[@]+"${repo_args[@]}"} ) 2>"$err" || rc=$?
  if [ -s "$err" ]; then
    cat "$err" >&2
    if [ "${PR_RATE_LIMITED:-0}" -eq 0 ] && rate_limit_matches "$(cat "$err" 2>/dev/null || printf '')"; then
      PR_RATE_LIMITED=1
      local info
      info="$(rate_limit_trip "$(rate_limit_state_file)")"
      log "GitHub rate limit hit — backing off ${info##* }s and stopping this scan"
    fi
  fi
  rm -f "$err"
  return "$rc"
}

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
  local d rid status url host num rem reason
  for d in "$RUNS_DIR"/*/; do
    rid=$(basename "$d")
    status=$(run_field "$rid" '.status')
    url=$(run_field "$rid" '.pr_url')
    host=$(run_field "$rid" '.host')
    # Emit completed runs, PLUS runs a handover left for a human to un-stick:
    #   - blocked / ci_repair_failed*      (issue #45, symptom B)
    #   - pr_conflicted / ci_red_after_resolution* | rebase_conflict*
    #                                      (issue #276, symptom B)
    # Both must return to the scan so a PR whose CI has since gone green (human
    # fixed the cause in main, rebased, removed needs-human) is merged instead of
    # stranded forever. Each condition is deliberately NARROW — only the specific
    # handover reasons — so every other blocked state (stalled_in_*,
    # env_bootstrap_failed) stays out of the scan exactly as before; watch_one
    # applies the needs-human hold gate before acting on any re-emitted run.
    case "$status" in
      completed)
        # Cost gate (issue #130): a completed run whose LAST recorded PR
        # classification is SKIP_CLOSED is in a permanently final state — a
        # closed PR never reopens on its own. Emitting it would make watch_one
        # fetch the PR from GitHub only to re-derive SKIP_CLOSED, one GraphQL
        # call per tick forever (the third O(historical run-dirs) leak, after
        # #124 scan_clean and #125 status detail; #65 silenced the state.jsonl
        # WRITE but not this fetch). Read finality from LOCAL state only —
        # state.jsonl's tail via pr_last_decision, the same reader #65 built —
        # never a fresh gh call, or the fix would cost what it saves.
        #   Decision 2: only SKIP_CLOSED is final. SKIP_NO_LABEL is NOT filtered
        #     (a missing auto-merge label can appear at any time), so it is not
        #     matched here and keeps being emitted.
        #   Decision 3: this gate lives in the completed branch ONLY — the
        #     blocked/ci_repair_failed re-arm path below is untouched (#45).
        #   Decision 4: a named `pr-watch <repo> #<PR>` run bypasses
        #     scan_candidates entirely (straight to watch_one), so the paluutie
        #     for a wrongly-closed PR is structural, no code here.
        #   Decision 5 (fail-closed): a missing/unreadable state.jsonl yields an
        #     empty decision != SKIP_CLOSED, so the run is emitted exactly as
        #     before — a filter error costs a call, never a missed merge.
        if [ "$(pr_last_decision "$d/state.jsonl")" = "SKIP_CLOSED" ]; then
          continue
        fi
        ;;
      blocked)
        reason=$(run_field "$rid" '.blocked_reason')
        case "$reason" in
          # *_gate_failed*: a merge-gate hold (issue #334), re-armed like the
          # CI-repair handover once a human removes needs-human.
          ci_repair_failed*|*_gate_failed*) : ;;
          *) continue ;;
        esac
        ;;
      pr_conflicted)
        # Symptom B (issue #276): the conflict path finalizes to pr_conflicted
        # with exactly these two reasons; re-emit them so a since-mergeable PR is
        # not stranded. Any other reason (there is none today) stays out.
        reason=$(run_field "$rid" '.blocked_reason')
        case "$reason" in
          ci_red_after_resolution*|rebase_conflict*) : ;;
          *) continue ;;
        esac
        ;;
      *) continue ;;
    esac
    [ -n "$url" ] || continue
    # Empty host = pre-host-field run.json; treat as local (best effort).
    if [ -n "$host" ] && [ "$host" != "$THIS_HOST" ]; then
      continue
    fi
    # Remote filter (issue #33): when --remote was passed, only emit runs whose
    # recorded .remote matches, so the poller can drive one scan session per
    # remote of a multi-remote clone. An empty .remote is legacy = origin. No
    # filter (flag omitted) keeps the manual `pr-watch <repo> scan` behaviour of
    # scanning every remote's runs.
    if [ -n "$REMOTE_FILTER" ]; then
      rem=$(run_field "$rid" '.remote'); [ -n "$rem" ] || rem="origin"
      [ "$rem" = "$REMOTE_FILTER" ] || continue
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
  # The lock this PR's run holds is namespaced by (repo, remote, issue), so the
  # watcher MUST address it with the run's own recorded identity. Locking with a
  # bare issue number would take a DIFFERENT directory than the orchestrator's,
  # silently breaking the mutual exclusion these two rely on (issues #53, #67).
  # Both fields are absent on legacy runs, which correctly yields the legacy name.
  local run_remote="origin"
  local run_slug=""
  local run_status="" run_blocked_reason=""
  if [ -n "$rid" ]; then
    run_dir="$RUNS_DIR/$rid"
    issue_num=$(run_field "$rid" '.issue_number')
    run_remote=$(run_field "$rid" '.remote')
    [ -n "$run_remote" ] || run_remote="origin"
    run_slug=$(run_field "$rid" '.repo_slug')
    # Issue #45 (symptom B): a run left blocked by a CI-repair handover is
    # re-emitted into the scan (see scan_candidates) so it is not permanently
    # stranded. We recognise it here to apply the needs-human hold gate below.
    run_status=$(run_field "$rid" '.status')
    run_blocked_reason=$(run_field "$rid" '.blocked_reason')
  fi

  # ----- Routing (issues #33/#53): address gh + git at the PR's OWN remote -----
  # The orchestrator records the run's remote and (for non-origin remotes) its
  # owner/repo in run.json. Route every gh call via `--repo owner/repo` and every
  # git fetch/push/rebase via the remote NAME, so a PR whose issue and branch live
  # in a non-origin org is operated on THERE instead of falling through to gh's
  # cwd (origin) inference — the silent multi-remote failure of issue #33. Prefer
  # the recorded .owner_repo; resolve it from the clone as a fallback for a
  # non-origin run whose run.json predates the field. Origin stays empty on
  # purpose (legacy cwd inference). Reset per call for scan mode's PR loop.
  PR_ROUTE_REMOTE="$run_remote"
  PR_OWNER_REPO=$(run_field "$rid" '.owner_repo')
  if [ -z "$PR_OWNER_REPO" ] && [ "$run_remote" != "origin" ]; then
    PR_OWNER_REPO=$(resolve_remote_to_owner_repo "$REPO_ROOT" "$run_remote" 2>/dev/null || true)
  fi

  # ----- P2: Lock (reuse per-issue lock; PR work and orchestration share it)
  local locked=0
  if [ -n "$issue_num" ]; then
    if lock_issue "$issue_num" "$run_remote" "$run_slug"; then
      locked=1
    else
      log "lock held for issue #$issue_num — another run owns it; skipping PR #$pr_num"
      return 3
    fi
  fi
  # Always release the lock on the way out of this PR.
  _release() { [ "$locked" = "1" ] && unlock_issue "$issue_num" "$run_remote" "$run_slug" || true; }

  # ----- P3: Classify -----------------------------------------------------
  local pr_json
  # No `2>/dev/null` here: gh_route captures gh's stderr, inspects it for the
  # rate-limit signal and re-emits it unchanged "so nothing downstream loses an
  # error message" (see gh_route). Swallowing it here defeated exactly that — the
  # first call to fail was the one call whose reason went missing (issue #279).
  if ! pr_json=$(gh_route pr view "$pr_num" \
        --json state,mergeable,mergeStateStatus,labels,statusCheckRollup,headRefName,baseRefName); then
    log "gh pr view failed for PR #$pr_num"
    _release
    return 4
  fi
  # Whether this PR had CI checks before any push this invocation makes: if it
  # did, the repo has CI and an empty rollup after the push is never "checkless"
  # (pr_ci_wait_state). Read once from the snapshot already in hand.
  PR_HAD_CHECKS=0
  [ "$(jq -r '(.statusCheckRollup // []) | length' <<<"$pr_json" 2>/dev/null)" -gt 0 ] 2>/dev/null \
    && PR_HAD_CHECKS=1

  # ----- Un-stick a handover (issues #45 + #276, symptom B) --------------
  # A run this watcher previously handed to a human — via the CI-repair path
  # (_pr_ci_handover_to_human) OR the conflict path (_pr_publish_and_revalidate /
  # _pr_abort_to_human) — is re-emitted into the scan (scan_candidates above), so
  # it is no longer lost forever. The needs-human label is the hold flag for
  # BOTH: while present, the watcher stays hands-off — no re-decision, no repeated
  # comment on every poll (§5.6, §5.7). Once a human removes it (as the handover
  # comment instructs), the run is re-armed and falls through to the normal
  # decision: it merges if CI has since gone green / the branch is mergeable, or
  # is re-attempted/re-handed-over otherwise. The reason patterns uniquely
  # identify the handover states (blocked/ci_repair_failed*, pr_conflicted/
  # ci_red_after_resolution*, pr_conflicted/rebase_conflict*), so gating on the
  # reason alone is sufficient.
  case "$run_blocked_reason" in
    ci_repair_failed*|ci_red_after_resolution*|rebase_conflict*|*_gate_failed*)
      if pr_has_label "$pr_json" needs-human; then
        log "PR #$pr_num held by needs-human (automation handover) — skipping until a human removes the label"
        [ -n "$run_dir" ] && [ -d "$run_dir" ] && \
          state_event "$run_dir" "pr_watch_skipped" "pr=$pr_num" "reason=needs_human_held"
        _release
        return 4
      fi
      log "PR #$pr_num re-armed after handover (needs-human removed) — re-examining"
      ;;
  esac

  local decision
  decision=$(pr_decide "$pr_json" "$PR_WATCH_ENABLE_CONFLICT_RESOLUTION" "$PR_WATCH_MERGE_LABEL" "$PR_WATCH_ENABLE_CI_REPAIR")

  # S0-style CI-repair preflight (issue #45, symptom A): FIX_CI is only a useful
  # classification if the claude CLI can actually launch. If it cannot (the
  # claude CLI's silent 127 the orchestrator's S0 gate catches), downgrade to
  # WAIT_CI BEFORE dispatching to pr_fix_ci — so the red PR is re-examined next
  # poll instead of burning a repair attempt (and its pr_ci_repair_attempted
  # event) on an agent that never starts, and is never left permanently blocked.
  if [ "$decision" = "FIX_CI" ] && ! pr_ci_repair_preflight; then
    decision="WAIT_CI"
  fi
  log "PR #$pr_num classified: $decision"

  # state.jsonl noise gate (issue #65). A closed PR stays SKIP_CLOSED forever,
  # yet the pr_watch_started / pr_classified / pr_watch_skipped trio used to be
  # re-written on every tick — >99.7% of a 345 MB state.jsonl was exactly this.
  # Log the FIRST SKIP_CLOSED (a real transition: the PR closed) but suppress the
  # whole trio on every repeat, keyed on the last recorded decision read from the
  # tail of state.jsonl (never the whole file). Every other decision is live
  # state and is logged as before. emit_events also gates pr_watch_started below,
  # so a suppressed tick writes nothing at all.
  local emit_events=1
  if [ "$decision" = "SKIP_UNKNOWN" ]; then
    # A failed/empty fetch (issue #131). Already logged above and always logged
    # (no #65 suppression — that gates a repeated KNOWN state, not an unknown
    # one). It must NEVER be written to state.jsonl: recording it as a
    # pr_classified decision would poison the pr_last_decision tail-read, so a
    # transient rate-limit read could become the run's history — and (should #130
    # ever filter the scan on that history) permanently drop the PR. Suppress the
    # whole trio; the classify line above carries the signal.
    emit_events=0
  elif [ "$decision" = "SKIP_CLOSED" ] && [ -n "$run_dir" ] && [ -d "$run_dir" ] \
     && [ "$(pr_last_decision "$run_dir/state.jsonl")" = "SKIP_CLOSED" ]; then
    emit_events=0
  fi

  if [ "$emit_events" = 1 ] && [ -n "$run_dir" ] && [ -d "$run_dir" ]; then
    state_event "$run_dir" "pr_watch_started" "pr=$pr_num"
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
    FIX_CI)
      # ----- P5b: Repair red CI (AI agent + mandatory CI revalidation) ----
      if pr_fix_ci "$pr_num" "$rid" "$run_dir" "$pr_json"; then
        : # fixed + revalidated green; fall through to merge
      else
        local rc=$?
        _release
        return "$rc"
      fi
      ;;
    SKIP_UNKNOWN)
      # Empty/partial payload (issue #131): the FETCH failed (rate limit, network,
      # permissions), NOT "PR is closed". Fail-closed to a plain skip — never
      # merge/close/clean/label. Always logged (the classify line above fires
      # regardless of emit_events); emit_events=0 keeps it out of state.jsonl so a
      # transient failure never becomes pr_last_decision history.
      log "PR #$pr_num: could not read PR state (empty/partial payload — fetch failed?); skipping this tick, not recording"
      _release
      return 4
      ;;
    SKIP_NO_LABEL|SKIP_CLOSED|SKIP_BLOCKED)
      # Third leg of the trio: suppressed together with the two above on a
      # repeated SKIP_CLOSED (emit_events=0). All other skips are logged.
      [ "$emit_events" = 1 ] && [ -n "$run_dir" ] && [ -d "$run_dir" ] && \
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

  # ----- P5c: Merge gates (issue #334) -----------------------------------
  # Every path that reaches P6 — MERGE, and REBASE / FIX_CI once green — passes
  # here, so code the watcher's own agents changed is reviewed in its FINAL form.
  # pr_decide stays pure: whether a gate runs is read here, in the caller. A gate
  # that fixes a finding moves the head, which makes an earlier gate's review
  # stale — so with more than one gate the pass repeats until no gate moved the
  # head (bounded: every move costs a capped fix attempt).
  PR_GATE_HEAD_SHA=""
  local gate grc gates_on=0 gate_moved
  for gate in $MERGE_GATES; do
    _merge_gate_spec "$gate" && [ "$GATE_ENABLED" = "1" ] && gates_on=$((gates_on + 1))
  done
  while [ "$gates_on" -gt 0 ]; do
    gate_moved=0
    for gate in $MERGE_GATES; do
      _merge_gate_spec "$gate" || continue
      [ "$GATE_ENABLED" = "1" ] || continue
      grc=0
      pr_run_merge_gate "$gate" "$pr_num" "$rid" "$run_dir" "$pr_json" || grc=$?
      if [ "$grc" -ne 0 ]; then
        _release
        return "$grc"
      fi
      [ "$PR_GATE_START_SHA" = "$PR_GATE_HEAD_SHA" ] || gate_moved=1
    done
    [ "$gate_moved" = 1 ] && [ "$gates_on" -gt 1 ] || break
  done

  # ----- P6: Merge --------------------------------------------------------
  # Merge as the App so the "Merged by" attribution on the PR is <app>[bot].
  #
  # We prefer --rebase, but GitHub rejects a rebase-merge when the feature
  # branch contains a merge commit (issue #41) — a normal state whenever a
  # conflict was resolved by merging the base branch into the feature branch.
  # That failure is PERMANENT: the branch shape never changes on its own, so
  # retrying --rebase every tick would loop forever. Fall back to a --merge
  # commit, which GitHub accepts for such branches. gh's own error text is
  # captured and logged so a genuine failure names its cause instead of the
  # opaque "merge failed" that made every merge block look identical.
  #
  # NO --delete-branch (issue #123). gh's flag deletes the LOCAL branch as well,
  # and here the run's own worktree still holds it — the teardown that frees it
  # is P9, three phases further on. git refused, gh exited non-zero, and a merge
  # that had ALREADY succeeded was read as a failure: rc=5, needs-human, and
  # P7..P9 skipped — so the worktree that caused it was never removed and every
  # auto-merge run left another one behind. The remote branch is deleted on its
  # own in P6b; the local one dies in P9, where cleanup-run.sh removes the
  # worktree first — the order that script has documented all along.
  #
  # A merge gate reviewed one exact head; --match-head-commit makes GitHub refuse
  # the merge if the branch moved after that review (issue #334).
  local merge_out
  local -a head_args=()
  [ -n "$PR_GATE_HEAD_SHA" ] && head_args=(--match-head-commit "$PR_GATE_HEAD_SHA")
  log "merging PR #$pr_num (--rebase)"
  if ! merge_out=$(gh_route pr merge "$pr_num" --rebase ${head_args[@]+"${head_args[@]}"} 2>&1); then
    # A merge that reports failure may still have happened, and the fallback is
    # for a branch GitHub will not rebase (issue #41) — firing it at a merged PR
    # only yields "was already merged", a second wrong diagnosis on top of the
    # first. So ask what the PR actually is before retrying.
    local post_state
    post_state=$(gh_route pr view "$pr_num" --json state --jq '.state' 2>/dev/null || true)
    if [ "$post_state" = "MERGED" ]; then
      log "PR #$pr_num: gh reported an error but the PR is MERGED — continuing: ${merge_out:-<no output>}"
    else
      log "PR #$pr_num: rebase merge failed (merge commit on branch?) — retrying with --merge: ${merge_out:-<no output>}"
      if ! merge_out=$(gh_route pr merge "$pr_num" --merge ${head_args[@]+"${head_args[@]}"} 2>&1); then
        log "merge failed for PR #$pr_num: ${merge_out:-<no output>}"
        [ -n "$run_dir" ] && [ -d "$run_dir" ] && \
          state_event "$run_dir" "pr_watch_skipped" "pr=$pr_num" "reason=merge_failed"
        _release
        return 5
      fi
    fi
  fi

  # ----- P6b: delete the REMOTE head branch -------------------------------
  # The half of --delete-branch that has no local ordering problem. Best effort
  # by design and never fatal: the branch may already be gone (a repo with
  # GitHub's "automatically delete head branches" on), and a merged PR must not
  # be reported as failed over a branch that no longer matters. The repo goes in
  # the API path through the same helper the label writes use, so an empty
  # PR_OWNER_REPO keeps gh's cwd inference.
  local head_ref
  head_ref=$(jq -r '.headRefName // empty' <<<"$pr_json" 2>/dev/null || true)
  if [ -n "$head_ref" ]; then
    if gh_route api --method DELETE \
         "repos/$(_labels_repo_path "$PR_OWNER_REPO")/git/refs/heads/$head_ref" \
         >/dev/null 2>&1; then
      log "deleted remote branch $head_ref"
    else
      log "remote branch $head_ref not deleted (already gone, or deleted on merge by the repo)"
    fi
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

  # ----- P8b: Close linked issue (always, if still OPEN) ------------------
  # GitHub's native `Closes #N` keyword only fires when a PR merges into the
  # DEFAULT branch AND its body carries the keyword. An agent-authored PR (no
  # keyword) or a non-default base can drop either condition, leaving the merged
  # work open as an issue the poller could re-pick. Close it explicitly whenever
  # it is still OPEN. This is a REMOTE operation, so it runs BEFORE the P9 host
  # gate — the issue must close regardless of which machine ran the job
  # (cross-machine runs return early below). Best-effort: a failure here never
  # changes the merge outcome.
  maybe_close_linked_issue "$pr_num" "$issue_num" "$pr_json" "$run_dir"

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

# maybe_close_linked_issue <pr-number> <issue-number> <pr-json> <run-dir>
# Best-effort explicit close of the PR's linked issue after a successful merge.
# GitHub's native `Closes #N` keyword only fires when the PR merges into the
# DEFAULT branch AND the body carries the keyword; an agent-authored PR (missing
# keyword) or a non-default base can drop either condition, leaving the merged
# work open as an issue that the poller could then re-pick. So we close ALWAYS —
# but only if the issue is still OPEN, because in the common path GitHub already
# closed it natively seconds earlier and a redundant automated comment (or, worse,
# an unexpected reopen/close interaction) must be avoided. The OPEN decision is
# delegated to the pure, unit-tested should_close_linked_issue (lib/pr-watch-lib.sh).
#
# Guarantees (all fail-safe — never a wrong close, never affects the merge):
#   - empty issue_num             -> skip (nothing linked).
#   - issue state cannot be read  -> skip (fetch/auth failure — fail-safe).
#   - issue not OPEN              -> skip (GitHub already closed it natively).
#   - `gh issue close` failure    -> log only (merge outcome unaffected).
# Uses gha_with_token so the close shows the App identity when configured
# (pass-through otherwise).
maybe_close_linked_issue() {
  local pr_num="$1" issue_num="$2" pr_json="$3" run_dir="$4"

  if [ -z "$issue_num" ]; then
    log "PR #$pr_num has no linked issue number — skipping explicit close"
    return 0
  fi

  # Read the issue's current state. Fail-safe: any failure or empty result ->
  # do not close (a failed fetch must never trigger a close).
  local issue_json issue_state
  if ! issue_json=$(gh_route issue view "$issue_num" --json state 2>/dev/null); then
    log "could not read state for issue #$issue_num (gh issue view failed) — NOT closing (fail-safe)"
    return 0
  fi
  issue_state=$(jq -r '.state // empty' <<<"$issue_json")

  if ! should_close_linked_issue "$issue_state"; then
    log "issue #$issue_num is '${issue_state:-unknown}' (not OPEN) — GitHub closed it natively or state unavailable; no explicit close"
    return 0
  fi

  local base_ref
  base_ref=$(jq -r '.baseRefName // empty' <<<"$pr_json")
  log "closing issue #$issue_num explicitly after PR #$pr_num merge (base '$base_ref')"
  local body
  body="Suljettu automaattisesti PR #$pr_num mergen jälkeen, koska GitHubin closing keyword ei laukennut (joko base ei ollut default-haara tai PR-kuvauksesta puuttui sulkeva avainsana)."
  if gh_route issue close "$issue_num" --comment "$body"; then
    [ -n "$run_dir" ] && [ -d "$run_dir" ] && \
      state_event "$run_dir" "linked_issue_closed" "issue=$issue_num" "base=$base_ref"
  else
    log "gh issue close failed for issue #$issue_num (best-effort — merge unaffected)"
  fi
  return 0
}

# ----- P5: Resolve --------------------------------------------------------
# Conflict resolution is OFF by default (PR_WATCH_ENABLE_CONFLICT_RESOLUTION=0),
# in which case pr_decide never returns REBASE and this is unreachable. When ON
# and the PR is BEHIND/DIRTY we rebase onto the PR's base branch (<remote>/<baseRefName>) in its own feature
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

  # Route fetch/rebase at the PR's OWN remote (issue #33), not a hardcoded origin
  # — in a multi-remote clone the base branch lives in the PR's org, addressed by
  # PR_ROUTE_REMOTE (the run's recorded git remote name; "origin" in the common
  # single-remote case).
  log "rebasing PR #$pr_num branch '$branch' onto $PR_ROUTE_REMOTE/$base_ref in worktree $worktree"

  # Fetch first so a network/auth failure is distinguishable from a conflict
  # (transient — retry next poll, do not claim a conflict or comment).
  if ! _pr_fetch "$worktree" "$base_ref"; then
    log "git fetch $PR_ROUTE_REMOTE $base_ref failed for PR #$pr_num — retrying next poll"
    [ -n "$run_dir" ] && [ -d "$run_dir" ] && \
      state_event "$run_dir" "pr_watch_skipped" "pr=$pr_num" "reason=fetch_failed"
    return 4
  fi

  # Attempt the rebase INSIDE the feature worktree, never on the base branch.
  local rebase_rc=0
  ( cd "$worktree" && git rebase "$PR_ROUTE_REMOTE/$base_ref" ) || rebase_rc=$?

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
  base_sha=$( cd "$worktree" && git rev-parse --short "$PR_ROUTE_REMOTE/$base_ref" 2>/dev/null || echo "unknown" )
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
  _pr_call_agent "$ai_out_dir" "$worktree" "04-conflict-resolution" "$prompt_file" \
    "$PR_WATCH_CONFLICT_TIMEOUT" || crc=$?
  log "AI conflict-resolution call for PR #$pr_num returned rc=$crc"

  if _conflict_resolution_clean "$worktree" "$base_ref"; then
    return 0
  fi
  log "AI conflict resolution did not leave a clean, completed rebase for PR #$pr_num"
  return 1
}

# _conflict_resolution_clean <worktree> [base-ref] [remote] — 0 iff the worktree
# is in a clean, fully-rebased state: no rebase in progress, no unmerged paths, a
# clean working tree, and HEAD descends from <remote>/<base-ref> (the rebase
# landed). <remote> defaults to PR_ROUTE_REMOTE (issue #33) so the ancestry check
# targets the PR's own remote; "origin" in the common single-remote case.
_conflict_resolution_clean() {
  local wt="$1" base_ref="${2:-main}" remote="${3:-${PR_ROUTE_REMOTE:-origin}}"
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
    # HEAD must descend from <remote>/<base-ref>, i.e. the rebase landed on the new base.
    git merge-base --is-ancestor "$remote/$base_ref" HEAD || exit 1
    exit 0
  )
}

# _pr_mark_needs_human <pr-number> — attach the needs-human label to a PR the
# watcher is handing to a human. Ensures the label exists, then adds it; both are
# best-effort (a failed label never changes the outcome). The REST label helpers
# route to PR_OWNER_REPO when known (issue #33) and fall back to {owner}/{repo}
# cwd inference when empty, so we keep the REPO_ROOT cwd.
#
# Shared by EVERY handover path — CI repair (_pr_ci_handover_to_human) AND both
# conflict-path handovers (_pr_publish_and_revalidate, _pr_abort_to_human, issue
# #276 symptom D) — so the hold flag is written ONE way, never copied (CLAUDE.md
# §7). The label is what makes a handover FILTERABLE (CLAUDE.md §4: "pelkkä
# kommentti ei riitä: se ei ole suodatettava") and, together with the run's
# re-emission into scan_candidates, what lets watch_one's hold gate re-arm the
# run once a human removes it.
_pr_mark_needs_human() {
  local pr_num="$1"
  ( cd "$REPO_ROOT" && labels_ensure "$PR_OWNER_REPO" needs-human B60205 "Vaatii ihmisen — automaatio luovutti" ) \
    || log "could not ensure needs-human label for PR #$pr_num"
  ( cd "$REPO_ROOT" && labels_add "$PR_OWNER_REPO" "$pr_num" needs-human ) \
    || log "could not add needs-human label to PR #$pr_num"
}

# _pr_publish_and_revalidate <pr-number> <run-id> <run-dir> <worktree> <branch> [base-ref]
# Force-pushes the rebased branch and revalidates CI. Shared by the clean-rebase
# and AI-resolved paths so the CI gate is identical on both.
# Returns 0 (CI green, caller proceeds to merge) or 6 (push failed / CI red).
_pr_publish_and_revalidate() {
  local pr_num="$1" rid="$2" run_dir="$3" worktree="$4" branch="$5" base_ref="${6:-main}"

  log "rebase landed — force-pushing $branch (--force-with-lease) and revalidating CI"
  if _pr_force_push "$worktree" "$branch"; then
    :
  else
    log "force-push failed for PR #$pr_num after rebase"
    [ -n "$run_dir" ] && [ -d "$run_dir" ] && \
      state_event "$run_dir" "pr_watch_skipped" "pr=$pr_num" "reason=push_failed"
    return 6
  fi
  [ -n "$run_dir" ] && [ -d "$run_dir" ] && \
    state_event "$run_dir" "pr_rebased" "pr=$pr_num"

  local pushed_sha
  pushed_sha=$( cd "$worktree" && git rev-parse HEAD 2>/dev/null || true )
  if pr_wait_ci_green "$pr_num" "$pushed_sha"; then
    log "CI green after rebase for PR #$pr_num — proceeding to merge"
    return 0
  fi
  log "CI not green after rebase for PR #$pr_num — stopping (human needed)"
  # Filterable handover (issue #276, symptom D): the same needs-human label the
  # CI-repair path uses, so this conflict handover is not a bare comment.
  _pr_mark_needs_human "$pr_num"
  [ -n "$run_dir" ] && [ -d "$run_dir" ] && {
    state_finalize "$run_dir" "pr_conflicted" "ci_red_after_resolution_pr_$pr_num"
    state_event "$run_dir" "pr_watch_skipped" "pr=$pr_num" "reason=ci_not_green_after_rebase"
  }
  local body
  body=$(printf '%s\n\n%s\n%s\n' \
    "PR-valvoja rebasesi haaran \`$branch\` \`$PR_ROUTE_REMOTE/$base_ref\`:n päälle (konfliktit ratkaistiin AI:lla, jos niitä oli), mutta **CI ei vihreytynyt** uudelleenajossa." \
    "Haara on pushattu rebasetussa tilassa — tarkista CI-lokit ja ratkaisun oikeellisuus worktreessä \`$worktree\`." \
    "PR:ää **ei mergetty**. Korjaa ja merkkaa PR uudelleen, tai aja valvoja uudelleen.")
  printf '%s' "$body" | gh_route pr comment "$pr_num" --body-file - || \
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
  base_sha=$( cd "$worktree" && git rev-parse "$PR_ROUTE_REMOTE/$base_ref" 2>/dev/null || echo "unknown" )

  log "AI could not resolve conflict on PR #$pr_num — rebase aborted; asking for human resolution"
  # Filterable handover (issue #276, symptom D): the same needs-human label the
  # CI-repair path uses, so this conflict handover is not a bare comment.
  _pr_mark_needs_human "$pr_num"
  [ -n "$run_dir" ] && [ -d "$run_dir" ] && {
    state_finalize "$run_dir" "pr_conflicted" "rebase_conflict_pr_$pr_num"
    state_event "$run_dir" "pr_conflicted" "pr=$pr_num" "base_sha=$base_sha"
  }
  local body
  body=$(printf '%s\n\n%s\n%s\n%s\n' \
    "PR-valvoja yritti rebasea \`$PR_ROUTE_REMOTE/$base_ref\` (sha \`$base_sha\`) päälle ja ratkaista konfliktin AI-agentilla, mutta kestävää ratkaisua ei syntynyt." \
    "Rebase peruttiin (\`git rebase --abort\`), joten haara \`$branch\` on ennallaan." \
    "Ratkaise konflikti manuaalisesti worktreessä \`$worktree\`, pushaa, ja merkkaa PR uudelleen." \
    "(AI-konfliktinratkaisu on päällä \`PR_WATCH_ENABLE_CONFLICT_RESOLUTION=1\` — tämä konflikti vaati ihmisen.)")
  printf '%s' "$body" | gh_route pr comment "$pr_num" --body-file - || \
    log "failed to post conflict comment on PR #$pr_num"
}

# pr_wait_ci_green <pr-number> <expected-sha> — poll the PR's statusCheckRollup
# after a push until CI on <expected-sha> is GREEN or RED, or we time out on
# PENDING. Returns 0 only when CI is green FOR THE PUSHED SHA.
#
# The verdict comes from pr_ci_wait_state, which delegates a non-empty rollup to
# pr_ci_state — the SAME source as pr_decide's merge gate — so the two can never
# disagree on what "green" means (CLAUDE.md §7; issue #276, symptom A). On top of
# that it binds the reading to the push (issue #354): GitHub registers the new
# head's check runs seconds after the push, so a rollup that is empty or still
# carries the old headRefOid is PENDING, not GREEN. A checkless repo is still
# accepted — once its rollup has stayed empty for PR_WATCH_CI_EMPTY_GRACE_SECS —
# so #276's 10-minute spin does not return — but never when the PR had checks
# before the push (PR_HAD_CHECKS, set by watch_one): then the repo has CI, and an
# empty rollup only means GitHub is slow to register it. Elapsed time is counted in polls
# (i * interval), not wall clock, so the wait is deterministic under test.
# An empty <expected-sha> fails closed at once (rc 1): green is impossible, so
# there is nothing to wait for. Bounded so a stuck/queued pipeline doesn't hang forever.
pr_wait_ci_green() {
  local pr_num="$1" expected_sha="${2:-}"
  local max_polls="${PR_WATCH_CI_MAX_POLLS:-40}"   # 40 * 15s = 10 min
  local interval="${PR_WATCH_CI_POLL_SECS:-15}"
  local grace="${PR_WATCH_CI_EMPTY_GRACE_SECS:-120}"
  local i=0 json ci
  if [ -z "$expected_sha" ]; then
    log "pr_wait_ci_green: no expected SHA for PR #$pr_num — CI cannot be verified (fail-closed)"
    return 1
  fi
  while [ "$i" -lt "$max_polls" ]; do
    if json=$(gh_route pr view "$pr_num" --json headRefOid,statusCheckRollup 2>/dev/null); then
      ci=$(pr_ci_wait_state "$json" "$expected_sha" "$((i * interval))" "$grace" "${PR_HAD_CHECKS:-0}")
      case "$ci" in
        GREEN)
          if [ "$(jq -r '(.statusCheckRollup // []) | length' <<<"$json" 2>/dev/null)" = "0" ]; then
            log "PR #$pr_num: no CI checks on ${expected_sha:0:12} after ${grace}s grace — treating as a checkless repo"
          fi
          return 0 ;;
        RED) return 1 ;;
      esac
    fi
    # PENDING, or a failed fetch (rate limit / network) — wait and retry. A
    # failed fetch never counts as green: fail-safe, like the old rc!=0 path.
    i=$((i + 1))
    sleep "$interval"
  done
  return 1
}

# ===== Shared worktree-agent seams (conflict resolution + CI repair) =======
# Both self-repair paths (P5 conflict resolution and P5b CI repair) run an AI
# agent in the feature worktree and then force-push it. These two helpers are
# that common mechanism, extracted so neither path copies it.

# _pr_call_agent <out-dir> <worktree> <step-id> <prompt-file> <timeout-secs> [repo-principles]
# repo-principles (default 1) = 0 skips the worktree's principles_file override:
# a merge-gate reviewer must not take instructions from the PR it reviews.
# Runs the claude CLI with the worktree as CWD (the agent edits files + drives
# git there) under a dedicated wall-clock budget so a wedged call can't hang the
# watcher. Returns the agent's rc — but callers must NOT trust it: the worktree
# / CI state is always verified independently afterwards.
_pr_call_agent() {
  local out_dir="$1" worktree="$2" step_id="$3" prompt_file="$4" timeout_secs="$5"
  local repo_principles="${6:-1}"
  local crc=0
  (
    cd "$worktree" || exit 99
    # The operating contract (#176) and the coding standard (#175) reach these
    # agents through call_claude like every orchestrated step does; only the
    # standard's repo-level override needs resolving here (the contract has no
    # override), because the watcher — unlike the orchestrator — has no
    # REPO_ROOT of its own. The worktree IS a checkout of the target repo, so it
    # carries the same .claude/run-issues.json. Kept inside the subshell so the
    # variable cannot leak across PRs from different repos in one scan.
    [ "$repo_principles" = "1" ] && load_repo_principles_file "$worktree"
    RUN_ISSUES_CLAUDE_TIMEOUT="$timeout_secs" \
      call_claude "$out_dir" "$step_id" "$prompt_file"
  ) || crc=$?
  return "$crc"
}

# _pr_fetch <worktree> <ref>... — fetch refs from the PR's OWN remote
# (PR_ROUTE_REMOTE, issue #33). When App mode is on the App token goes via
# http.extraheader so the fetch credential matches the eventual push credential
# (otherwise a repo configured to only accept the App's PAT-equivalent would
# refuse the fetch); the header is captured to a local and never echoed.
# Returns 0 on success, 1 on failure.
_pr_fetch() {
  local worktree="$1"; shift
  local remote="${PR_ROUTE_REMOTE:-origin}"
  local _hdr="" _h=""
  if _h=$(gha_git_push_header 2>/dev/null); then _hdr="$_h"; fi
  _h=""
  local ok=1
  if [ -n "$_hdr" ]; then
    ( cd "$worktree" && git -c "http.extraheader=$_hdr" fetch "$remote" "$@" --quiet ) && ok=0
  else
    ( cd "$worktree" && git fetch "$remote" "$@" --quiet ) && ok=0
  fi
  _hdr=""
  return "$ok"
}

# _pr_force_push <worktree> <branch> — push the branch with --force-with-lease,
# using the App token via http.extraheader when App mode is on (same pattern as
# the orchestrator's push; the header is captured to a local and never echoed).
# --force-with-lease is safe for BOTH a rewritten (rebased) branch and a plain
# fast-forward (a new CI-fix commit): it only refuses if the remote ref moved
# unexpectedly. Pushes to the PR's OWN remote (PR_ROUTE_REMOTE, issue #33), not a
# hardcoded origin — "origin" in the common single-remote case. Returns 0 on
# success, 1 on failure.
_pr_force_push() {
  local worktree="$1" branch="$2"
  local remote="${PR_ROUTE_REMOTE:-origin}"
  local _hdr="" _h=""
  if _h=$(gha_git_push_header 2>/dev/null); then _hdr="$_h"; fi
  _h=""
  local ok=1
  if [ -n "$_hdr" ]; then
    ( cd "$worktree" && git -c "http.extraheader=$_hdr" push --force-with-lease "$remote" "$branch" ) && ok=0
  else
    ( cd "$worktree" && git push --force-with-lease "$remote" "$branch" ) && ok=0
  fi
  _hdr=""
  return "$ok"
}

# pr_ci_repair_preflight — is the claude CLI usable for a CI-repair call?
# (issue #45, symptom A). Mirrors the orchestrator's S0 gate (lib/preflight.sh):
# the DEFAULT invocation `claude` can resolve on PATH yet still exit 127 at call
# time (a machine with the npm package but no `claude` command hits exactly
# this), so `command -v` cannot see the failure — only an actual `--version`
# probe can. An overridden RUN_ISSUES_CLAUDE_CMD is the user's own driver whose
# --version we must neither guess nor fire, so we only verify its first token is
# callable (same policy as S0's `have` mode). Logs the reason once on failure.
# Returns 0 usable, 1 not.
#
# Also the merge gate's launch check (issue #334); [<what>] names the caller in
# the log line.
pr_ci_repair_preflight() {
  local what="${1:-CI-repair}" reason
  reason=$(preflight_claude_cmd_unusable) || return 0
  log "$what unavailable: $reason"
  return 1
}

# pr_codex_preflight [<what>] — is the Codex CLI usable for a merge-gate review?
# (issue #335). Same policy as pr_ci_repair_preflight: the default invocation is
# probed with `--version` (a name on PATH does not prove it starts), an override
# is the user's own driver and only its first token is checked. Called only when
# Codex is the selected reviewer. Logs the reason once on failure. Returns 0
# usable, 1 not.
pr_codex_preflight() {
  local what="${1:-merge gate}" reason=""
  if [ "$PR_WATCH_CODEX_CMD" = "$PR_WATCH_CODEX_CMD_DEFAULT" ]; then
    # shellcheck disable=SC2086
    if ! preflight_probe_codex $PR_WATCH_CODEX_CMD; then
      reason="codex CLI probe failed (\`$PR_WATCH_CODEX_CMD --version\` returned non-zero — fix: $(preflight_install_hint codex))"
    fi
  else
    local first="${PR_WATCH_CODEX_CMD%% *}"
    if ! preflight_have "$first"; then
      reason="codex driver '$first' not found on PATH (PR_WATCH_CODEX_CMD override)"
    fi
  fi
  [ -z "$reason" ] && return 0
  log "$what unavailable: $reason"
  return 1
}

# _pr_call_codex <out-dir> <worktree> <step-id> <prompt-file> <timeout-secs>
# The Codex driver for a READ-ONLY merge-gate review (issue #335). Honours the
# same file contract as call_claude, so merge_gate_parse reads both alike:
#   <step-id>.out   — Codex's final message (--output-last-message); missing or
#                     empty when Codex did not answer => launch_failed
#   <step-id>.exit  — the process's REAL exit code, written on every path,
#                     including 127 (not found) and 124 (timeout)
#   <step-id>.codex.log — the raw stdout/stderr transcript
# Flags (codex exec): `--sandbox read-only` makes the reviewer unable to write
# even if it tried (the HEAD / clean-tree check after the call stays the real
# gate), `--skip-git-repo-check` because a linked worktree is not always
# recognised as trusted, `--color never` keeps the log readable, and `-` reads
# the prompt from stdin. Returns the rc — callers must not trust it alone.
_pr_call_codex() {
  local out_dir="$1" worktree="$2" step_id="$3" prompt_file="$4" timeout_secs="$5"
  local out_file="$out_dir/$step_id.out" exit_file="$out_dir/$step_id.exit"
  local log_file="$out_dir/$step_id.codex.log"
  local tb rc=0
  tb=$(preflight_timeout_bin)
  local -a cmd
  # shellcheck disable=SC2206
  cmd=($PR_WATCH_CODEX_CMD)
  [ -n "$tb" ] && cmd=("$tb" --kill-after=60 "$timeout_secs" "${cmd[@]}")
  # rc is captured with `|| rc=$?`, never `if ! cmd; then rc=$?` — inside that
  # branch $? is the negation's status, which is always 0.
  ( cd "$worktree" || exit 99
    "${cmd[@]}" exec --sandbox read-only --skip-git-repo-check --color never \
      --output-last-message "$out_file" - < "$prompt_file"
  ) > "$log_file" 2>&1 || rc=$?
  printf '%s\n' "$rc" > "$exit_file"
  log "codex call $step_id returned rc=$rc (transcript: $log_file)"
  return "$rc"
}

# ----- P5b: Repair red CI --------------------------------------------------
# CI repair is OFF by default (PR_WATCH_ENABLE_CI_REPAIR=0), in which case
# pr_decide never returns FIX_CI and this is unreachable. When ON and a labelled
# PR's CI has gone RED (a required/blocking check failed), we hand the failure to
# an AI agent that fixes the REAL cause in the feature worktree (never main),
# commits, and the watcher force-pushes + REVALIDATES CI before allowing the
# merge — CI is the safety gate that catches a wrong or cheating "fix". The agent
# may not delete/skip tests, loosen assertions, or otherwise fake green (enforced
# by prompts/05-ci-repair.md + this mandatory revalidation). If it cannot fix the
# failure durably, makes no commit, or CI stays red, the PR is handed to a human
# (needs-human label + comment, exit 8). A durable per-PR attempt cap
# (PR_WATCH_MAX_CI_REPAIRS, counted from the run-dir event log) bounds retries so
# a stateless watcher cannot loop.
#
# Returns: 0 CI repaired + green (caller proceeds to merge)
#          8 could not repair / CI still red / attempt cap reached (human asked)
#          4 not actionable (no run-dir, no worktree, etc.)
pr_fix_ci() {
  local pr_num="$1" rid="$2" run_dir="$3" pr_json="$4"

  # Durable attempt tracking needs the run-dir event log; without it we cannot
  # bound retries across the watcher's stateless invocations, so we decline
  # rather than risk an unbounded repair loop.
  if [ -z "$run_dir" ] || [ ! -d "$run_dir" ]; then
    log "no run-dir for PR #$pr_num — cannot track CI-repair attempts durably; skipping"
    return 4
  fi

  local worktree branch
  worktree=$(run_field "$rid" '.worktree_path')
  branch=$(run_field "$rid" '.branch')
  if [ -z "$worktree" ] || [ ! -d "$worktree" ]; then
    log "no usable worktree for PR #$pr_num (worktree='$worktree') — cannot repair CI"
    state_event "$run_dir" "pr_watch_skipped" "pr=$pr_num" "reason=no_worktree"
    return 4
  fi
  if [ -z "$branch" ]; then
    log "no branch recorded for PR #$pr_num — cannot repair CI"
    return 4
  fi

  # Attempt cap from the durable event log (pr_ci_repair_attempted). grep -c
  # prints a count but exits 1 on zero matches; `|| true` keeps that from
  # tripping `set -e`, and the default handles a missing file.
  local attempts max
  max="$PR_WATCH_MAX_CI_REPAIRS"
  attempts=$(grep -c '"event":"pr_ci_repair_attempted"' "$run_dir/state.jsonl" 2>/dev/null || true)
  attempts=${attempts:-0}
  local failed_checks
  failed_checks=$(pr_failed_checks "$pr_json")
  if [ "$attempts" -ge "$max" ]; then
    log "CI-repair attempt cap reached for PR #$pr_num ($attempts/$max) — asking a human"
    _pr_ci_handover_to_human "$pr_num" "$run_dir" "$worktree" "$failed_checks" \
      "CI-korjauksen yrityskatto ($attempts/$max) täyttyi"
    return 8
  fi

  local base_ref
  base_ref=$(jq -r '.baseRefName // "main"' <<<"$pr_json")

  # Best-effort failed-CI log excerpt (bounded). The agent's most reliable source
  # is the worktree itself (it reproduces the failure locally), so an empty log
  # here is not fatal — it just means the prompt leans on the check names + local
  # reproduction.
  local ci_log
  ci_log=$(_pr_collect_ci_log "$branch")

  # Record the durable spend BEFORE running the agent (mirrors the restart
  # retry-count increment): a crash mid-repair must still count as one attempt,
  # so a no-op or wedged agent cannot loop.
  state_event "$run_dir" "pr_ci_repair_attempted" "pr=$pr_num" "attempt=$((attempts + 1))"
  state_event "$run_dir" "pr_ci_repair_started" "pr=$pr_num"

  local head_before
  head_before=$( cd "$worktree" && git rev-parse HEAD 2>/dev/null || echo "" )

  local prompt_file="$run_dir/05-ci-repair.prompt"
  render_prompt "$SCRIPT_DIR/prompts/05-ci-repair.md" "$prompt_file" \
    PR_NUMBER="$pr_num" \
    BRANCH="$branch" \
    BASE_REF="$base_ref" \
    FAILED_CHECKS="${failed_checks:-（ei listattavissa — tarkista PR:n checkit）}" \
    CI_LOG="${ci_log:-（ei saatavilla — toista virhe worktreessä ajamalla epäonnistunut check）}"

  local arc=0
  _pr_call_agent "$run_dir" "$worktree" "05-ci-repair" "$prompt_file" \
    "$PR_WATCH_CI_REPAIR_TIMEOUT" || arc=$?
  log "AI CI-repair call for PR #$pr_num returned rc=$arc"

  # Distinguish "could not launch" from "found no fix" (issue #45, symptom A).
  # rc=127 is command-not-found — the agent never ran, so reporting it as "the
  # agent produced no commit" would mislead a human into studying a CI error the
  # agent never even looked at. This is defence-in-depth: the classify-time
  # preflight (pr_ci_repair_preflight) normally downgrades FIX_CI to WAIT_CI
  # before we get here, but a transient launch failure past that check must still
  # be reported honestly as infrastructure, not an agent decision.
  if [ "$arc" -eq 127 ]; then
    log "CI-repair agent could not be launched for PR #$pr_num (rc=127) — infrastructure failure, not an agent decision"
    _pr_ci_handover_to_human "$pr_num" "$run_dir" "$worktree" "$failed_checks" \
      "CI-korjausagenttia ei voitu käynnistää (rc=127); tarkista claude-CLI:n saatavuus pr-watchin ympäristössä" \
      launch_failed
    return 8
  fi

  # Verify the agent produced a NEW commit on a CLEAN worktree. No new commit =>
  # a failed attempt (nothing to push, CI would not change) — hand to a human
  # WITHOUT a pointless push. A dirty worktree must never be published either.
  local head_after
  head_after=$( cd "$worktree" && git rev-parse HEAD 2>/dev/null || echo "" )
  if [ -z "$head_after" ] || [ "$head_after" = "$head_before" ]; then
    log "CI-repair agent produced no commit for PR #$pr_num — failed attempt"
    _pr_ci_handover_to_human "$pr_num" "$run_dir" "$worktree" "$failed_checks" \
      "AI-agentti ei tuottanut korjaavaa committia"
    return 8
  fi
  if ( cd "$worktree" && git status --porcelain 2>/dev/null | grep -q . ); then
    log "CI-repair left the worktree dirty for PR #$pr_num — not publishing"
    _pr_ci_handover_to_human "$pr_num" "$run_dir" "$worktree" "$failed_checks" \
      "AI-agentti jätti työpuun likaiseksi (committaamattomia muutoksia)"
    return 8
  fi
  state_event "$run_dir" "pr_ci_repair_committed" "pr=$pr_num" "head=$head_after"

  # Publish + mandatory CI revalidation. CI is the real gate.
  if ! _pr_force_push "$worktree" "$branch"; then
    log "force-push failed after CI-repair for PR #$pr_num"
    state_event "$run_dir" "pr_watch_skipped" "pr=$pr_num" "reason=push_failed"
    _pr_ci_handover_to_human "$pr_num" "$run_dir" "$worktree" "$failed_checks" \
      "korjauksen push epäonnistui"
    return 8
  fi
  state_event "$run_dir" "pr_ci_repair_pushed" "pr=$pr_num"

  if pr_wait_ci_green "$pr_num" "$head_after"; then
    log "CI green after repair for PR #$pr_num — proceeding to merge"
    state_event "$run_dir" "pr_ci_repaired" "pr=$pr_num"
    return 0
  fi
  log "CI still red after repair for PR #$pr_num — asking a human"
  _pr_ci_handover_to_human "$pr_num" "$run_dir" "$worktree" "$failed_checks" \
    "korjaus ei vihreyttänyt CI:tä"
  return 8
}

# _pr_collect_ci_log <branch> — best-effort, bounded excerpt of the most recent
# FAILED CI run's failed-step logs on the branch. Prints empty on any failure —
# the agent reproduces the failure in the worktree, so this is context, not a
# hard dependency. Byte-capped by PR_WATCH_CI_LOG_MAX (mirrors the orchestrator's
# RUN_ISSUES_SITUATION_ARTIFACT_MAX pattern) so a huge log never bloats the prompt.
_pr_collect_ci_log() {
  local branch="$1"
  local run_id
  run_id=$(gh_route run list --branch "$branch" --json databaseId,conclusion --limit 20 2>/dev/null \
            | jq -r 'map(select(.conclusion == "failure")) | .[0].databaseId // empty' 2>/dev/null) || run_id=""
  [ -n "$run_id" ] || { printf ''; return 0; }
  gh_route run view "$run_id" --log-failed 2>/dev/null \
    | head -c "$PR_WATCH_CI_LOG_MAX" || printf ''
}

# _pr_ci_handover_to_human <pr-number> <run-dir> <worktree> <failed-checks> <why> [<kind>]
# The CI-repair path's human handover: attach the needs-human label, comment the
# PR with what was tried and which checks stayed red, and finalize the run
# blocked. Mirrors _pr_abort_to_human but for CI repair — the branch/worktree are
# left AS-IS for inspection (no rebase to abort), the run is marked blocked, and
# it carries its own exit code (8) at the call site. All steps are best-effort:
# a failed label or comment never changes the outcome.
#   <kind> = agent_ran (default) — the agent ran but could not fix / CI stayed red
#          = launch_failed        — the agent never launched (rc=127); the comment
#            says so plainly instead of implying the agent tried (issue #45).
# The blocked_reason recorded here (ci_repair_failed_pr_<n>) is what re-emits the
# run into scan_candidates so a later CI-green PR is un-stuck (issue #45).
_pr_ci_handover_to_human() {
  local pr_num="$1" run_dir="$2" worktree="$3" failed="$4" why="$5" kind="${6:-agent_ran}"

  _pr_mark_needs_human "$pr_num"

  [ -n "$run_dir" ] && [ -d "$run_dir" ] && {
    state_finalize "$run_dir" "blocked" "ci_repair_failed_pr_$pr_num"
    state_event "$run_dir" "pr_ci_repair_handover" "pr=$pr_num" "reason=$why"
  }

  # The opening sentence is the honest signal (issue #45, symptom A): a launch
  # failure (rc=127) must NOT read as "the agent tried and found no fix", which
  # sends a human off studying a CI error the agent never looked at. Everything
  # after the opening is shared.
  local opening
  if [ "$kind" = "launch_failed" ]; then
    opening="PR-valvoja **ei voinut käynnistää** CI-korjausagenttia feature-worktreessä \`$worktree\`: $why. Agentti ei siis ehtinyt tutkia CI-virhettä lainkaan — kyseessä on infrastruktuurivika, ei agentin päätös olla korjaamatta."
  else
    opening="PR-valvoja yritti korjata punaisen CI:n AI-agentilla feature-worktreessä \`$worktree\`, mutta $why."
  fi

  local body
  body=$(printf '%s\n\n%s\n\n%s\n%s\n' \
    "$opening" \
    "Punaiseksi jääneet checkit:"$'\n'"\`\`\`"$'\n'"${failed:-（ei listattavissa — tarkista PR:n checkit）}"$'\n'"\`\`\`" \
    "PR:ää **ei mergetty**. Tarkista CI-lokit ja korjauksen oikeellisuus, tai korjaa käsin ja aja valvoja uudelleen." \
    "(AI-CI-korjaus on päällä \`PR_WATCH_ENABLE_CI_REPAIR=1\`. Poista \`needs-human\`-label kun asia on hoidettu — valvoja käsittelee PR:n uudelleen ja mergaa sen kun CI on vihreä.)")
  printf '%s' "$body" | gh_route pr comment "$pr_num" --body-file - || \
    log "failed to post ci-repair comment on PR #$pr_num"
}

# ===== P5c: Merge gates (issue #334) ======================================
# A merge gate is an agent review of the PR's FINAL head right before P6. The
# MECHANISM below is gate-agnostic: head sync, the per-SHA record, the review /
# fix / revalidate loop, the attempt cap and the hold. A gate contributes only its
# CONTENT through _merge_gate_spec — prompts, switch, cap, timeouts, threshold —
# and the result format of lib/merge-gate.sh. The reviewer (GATE_REVIEWER:
# claude | codex) only swaps the review call's driver; fixes are always claude's.
# Adding a gate = two prompts, one
# spec case, one name in MERGE_GATES.
#
# Two optional, gate-agnostic seams (issue #341):
#   GATE_TRIGGER   a function deciding, without an agent, whether there is
#                  anything to review (see pr_run_merge_gate for its contract).
#                  Empty = always review. It may write a context file that both
#                  prompts receive as {{GATE_CONTEXT}}.
#   GATE_KEY_BASE  1 = the per-head record is also keyed by the base's SHA, for a
#                  gate whose verdict depends on what the base already holds.

# _merge_gate_spec <gate> — set the gate's content into GATE_* globals; rc 1 for
# an unknown gate.
_merge_gate_spec() {
  GATE_TRIGGER=""
  GATE_KEY_BASE=0
  GATE_SCANNERS=0
  case "$1" in
    security)
      GATE_SCANNERS=1   # lib/security-scan.sh, diff mode, before the review
      GATE_TITLE="Tietoturvakatselmus"
      GATE_ENABLED="$PR_WATCH_ENABLE_SECURITY_GATE"
      GATE_SWITCH="PR_WATCH_ENABLE_SECURITY_GATE"
      GATE_REVIEW_STEP="06-security-review"
      GATE_FIX_STEP="07-security-fix"
      GATE_MAX_FIXES="$PR_WATCH_MAX_SECURITY_FIXES"
      GATE_REVIEW_TIMEOUT="$PR_WATCH_SECURITY_REVIEW_TIMEOUT"
      GATE_FIX_TIMEOUT="$PR_WATCH_SECURITY_FIX_TIMEOUT"
      GATE_HOLD_MACHINE="$PR_WATCH_SECURITY_HOLD_MIN_SEVERITY"
      GATE_REVIEWER="$PR_WATCH_SECURITY_REVIEWER"
      ;;
    semantic)
      GATE_TITLE="Semanttisen konfliktin tarkistus"
      GATE_ENABLED="$PR_WATCH_ENABLE_SEMANTIC_CHECK"
      GATE_SWITCH="PR_WATCH_ENABLE_SEMANTIC_CHECK"
      GATE_REVIEW_STEP="10-semantic-review"
      GATE_FIX_STEP="11-semantic-fix"
      GATE_MAX_FIXES="$PR_WATCH_MAX_SEMANTIC_FIXES"
      GATE_REVIEW_TIMEOUT="$PR_WATCH_SEMANTIC_REVIEW_TIMEOUT"
      GATE_FIX_TIMEOUT="$PR_WATCH_SEMANTIC_FIX_TIMEOUT"
      GATE_HOLD_MACHINE="$PR_WATCH_SEMANTIC_HOLD_MIN_SEVERITY"
      GATE_REVIEWER="claude"
      GATE_TRIGGER="_pr_semantic_trigger"
      GATE_KEY_BASE=1
      ;;
    *) return 1 ;;
  esac
}

# pr_run_merge_gate <gate> <pr-number> <run-id> <run-dir> <pr-json>
# Runs one gate against the PR's current head. Sets PR_GATE_START_SHA (the head
# it found) and PR_GATE_HEAD_SHA (the head it passed — differs after a fix).
#
# Returns: 0  the head passed (clean, or only findings below the threshold)
#          10 held for a human (needs-human + comment listing the findings)
#          4  not actionable this tick (no run-dir / worktree, fetch failed,
#             worktree not at the PR head, the trigger could not decide) —
#             fail-closed: never a merge
#
# GATE_TRIGGER contract: called as
#   <fn> <pr-number> <run-id> <run-dir> <worktree> <base-ref> <context-file>
# after the head sync, with the base fetched. rc 0 = review (it may write
# <context-file>), 1 = nothing to review (the gate passes with no agent call),
# anything else = it could not decide (rc 4: a failed lookup is never a pass). It
# may set GATE_CONTEXT_SUMMARY, one line the hold comment quotes.
pr_run_merge_gate() {
  local gate="$1" pr_num="$2" rid="$3" run_dir="$4" pr_json="$5"
  PR_GATE_START_SHA=""
  PR_GATE_HEAD_SHA=""
  GATE_BASE_SHA=""
  GATE_CONTEXT_FILE=""
  GATE_CONTEXT_SUMMARY=""
  _merge_gate_spec "$gate" || return 4

  # The per-head record lives in the run-dir: without it a head could be reviewed
  # (and fixed) on every tick, and a review we cannot record is not a pass.
  if [ -z "$run_dir" ] || [ ! -d "$run_dir" ]; then
    log "merge gate '$gate': no run-dir for PR #$pr_num — cannot record a review against a head; not merging"
    return 4
  fi
  local worktree branch base_ref
  worktree=$(run_field "$rid" '.worktree_path')
  branch=$(run_field "$rid" '.branch')
  base_ref=$(jq -r '.baseRefName // "main"' <<<"$pr_json")
  if [ -z "$worktree" ] || [ ! -d "$worktree" ] || [ -z "$branch" ]; then
    # Durable, not transient: nothing on a later tick brings the worktree back,
    # so returning 4 here would park the PR forever without telling anyone.
    log "merge gate '$gate': no usable worktree/branch for PR #$pr_num (worktree='$worktree') — not merging"
    state_event "$run_dir" "pr_watch_skipped" "pr=$pr_num" "reason=no_worktree"
    _pr_gate_hold_to_human "$gate" "$pr_num" "$run_dir" "$worktree" "" \
      "ajon worktreetä tai haaraa ei löydy tältä koneelta, joten katselmusta ei voitu ajaa" "" launch_failed
    return 10
  fi

  # Review exactly what GitHub would merge: the remote head. A worktree behind it
  # is fast-forwarded; one that diverges is not ours to reconcile. The HEAD check
  # after the merge matters: --ff-only succeeds as a no-op on a worktree AHEAD of
  # the remote, which would leave unreviewed local commits under the review.
  if ! _pr_fetch "$worktree" "$base_ref" "$branch"; then
    log "merge gate '$gate': git fetch failed for PR #$pr_num — retrying next poll"
    state_event "$run_dir" "pr_watch_skipped" "pr=$pr_num" "reason=fetch_failed"
    return 4
  fi
  local sha remote_sha
  sha=$( cd "$worktree" && git rev-parse HEAD 2>/dev/null || true )
  remote_sha=$( cd "$worktree" && git rev-parse --verify -q "$PR_ROUTE_REMOTE/$branch" 2>/dev/null || true )
  if [ -z "$sha" ] || [ "$sha" != "$remote_sha" ]; then
    if [ -n "$sha" ] && [ -n "$remote_sha" ] \
       && ! ( cd "$worktree" && git status --porcelain 2>/dev/null | grep -q . ) \
       && ( cd "$worktree" && git merge --ff-only -q "$remote_sha" >/dev/null 2>&1 ) \
       && [ "$( cd "$worktree" && git rev-parse HEAD 2>/dev/null )" = "$remote_sha" ]; then
      sha="$remote_sha"
    else
      # Durable too: a diverged or dirty worktree (a human rebase / force-push,
      # or a fix agent's leftovers) does not reconcile itself on a later tick.
      log "merge gate '$gate': worktree head '${sha:-?}' is not the PR head '${remote_sha:-?}' for PR #$pr_num — not reviewing a head GitHub would not merge"
      state_event "$run_dir" "pr_watch_skipped" "pr=$pr_num" "reason=gate_head_mismatch"
      _pr_gate_hold_to_human "$gate" "$pr_num" "$run_dir" "$worktree" "${remote_sha:-?}" \
        "worktreen head (\`${sha:-?}\`) ei ole PR:n head eikä sitä voitu siirtää siihen (haara on erkaantunut tai worktree on likainen)" "" launch_failed
      return 10
    fi
  fi
  PR_GATE_START_SHA="$sha"

  # A verdict that depends on the base is recorded against it too: a head found
  # clean against one base is not clean against a base that has gained a sibling.
  if [ "${GATE_KEY_BASE:-0}" = 1 ]; then
    GATE_BASE_SHA=$( cd "$worktree" && git rev-parse --verify -q "$PR_ROUTE_REMOTE/$base_ref" 2>/dev/null || true )
    if [ -z "$GATE_BASE_SHA" ]; then
      log "merge gate '$gate': base '$PR_ROUTE_REMOTE/$base_ref' does not resolve for PR #$pr_num — not merging"
      state_event "$run_dir" "pr_watch_skipped" "pr=$pr_num" "reason=gate_base_unresolved"
      return 4
    fi
  fi

  # The trigger runs BEFORE the record is read: it is cheap, and the base it
  # looks at may have moved since the record was written.
  if [ -n "${GATE_TRIGGER:-}" ]; then
    local ctx="$run_dir/merge-gate-$gate.context" trc=0
    rm -f "$ctx"
    "$GATE_TRIGGER" "$pr_num" "$rid" "$run_dir" "$worktree" "$base_ref" "$ctx" || trc=$?
    case "$trc" in
      0) [ -s "$ctx" ] && GATE_CONTEXT_FILE="$ctx" ;;
      1)
        log "merge gate '$gate': nothing to review for PR #$pr_num head $sha — passing without an agent"
        state_event "$run_dir" "merge_gate_not_triggered" "gate=$gate" "pr=$pr_num" "sha=$sha" "base_sha=$GATE_BASE_SHA"
        PR_GATE_HEAD_SHA="$sha"
        return 0
        ;;
      *)
        log "merge gate '$gate': trigger could not decide for PR #$pr_num (rc=$trc) — not merging, retrying next poll"
        state_event "$run_dir" "pr_watch_skipped" "pr=$pr_num" "reason=gate_trigger_failed"
        return 4
        ;;
    esac
  fi

  # The threshold comes from the BASE branch's config: the PR under review must
  # not be able to lower the gate that reviews it.
  local cfg hold_min
  cfg=$( cd "$worktree" && git show "$PR_ROUTE_REMOTE/$base_ref:.claude/run-issues.json" 2>/dev/null || true )
  hold_min=$(merge_gate_hold_min "$cfg" "$gate" "$GATE_HOLD_MACHINE")

  # The cap must hold even if the event log cannot be read: a non-numeric cap
  # reads as 0 (hold at the first holding finding), and fixes made in this
  # invocation are counted in-process as well as from the log.
  case "$GATE_MAX_FIXES" in
    ''|*[!0-9]*)
      log "merge gate '$gate': invalid fix cap '$GATE_MAX_FIXES' — using 0"
      GATE_MAX_FIXES=0
      ;;
  esac
  local jsonl="$run_dir/state.jsonl" prior result holding findings attempts fixes_here=0
  while :; do
    prior=$(merge_gate_last_result "$jsonl" "$gate" "$sha" "$GATE_BASE_SHA")
    result="${prior%% *}"
    if [ "$result" = findings ]; then
      # The recorded holding count was computed against the threshold in force at
      # review time; the decision uses the current one, re-applied to the stored
      # findings. Without them the head is reviewed again (fail-closed) rather
      # than trusting a count a lowered threshold would no longer give.
      findings=$(cat "$(_merge_gate_findings_file "$run_dir" "$gate" "$sha")" 2>/dev/null || true)
      if [ -z "$findings" ]; then
        log "merge gate '$gate': findings of already reviewed head $sha are missing — reviewing it again"
        result=""
      fi
    fi
    case "$result" in
      clean)
        log "merge gate '$gate': head $sha already reviewed clean — passing"
        PR_GATE_HEAD_SHA="$sha"
        return 0
        ;;
      findings)
        holding=$(merge_gate_holding "$hold_min" "$findings" | grep -c . || true)
        if [ "${holding:-0}" -eq 0 ]; then
          log "merge gate '$gate': head $sha already reviewed, no finding at or above '$hold_min' — passing"
          PR_GATE_HEAD_SHA="$sha"
          return 0
        fi
        log "merge gate '$gate': head $sha already reviewed with $holding finding(s) at or above '$hold_min' — not reviewing it again"
        ;;
      *)
        # No record, or a review that never happened (launch_failed): review.
        _pr_gate_review "$gate" "$pr_num" "$run_dir" "$worktree" "$branch" "$base_ref" "$sha" "$hold_min"
        case "$GATE_RESULT" in
          launch_failed)
            _pr_gate_hold_to_human "$gate" "$pr_num" "$run_dir" "$worktree" "$sha" "$GATE_WHY" "" launch_failed
            return 10
            ;;
          clean)
            PR_GATE_HEAD_SHA="$sha"
            return 0
            ;;
        esac
        findings="$GATE_FINDINGS"
        holding="$GATE_HOLDING"
        if [ "$holding" -eq 0 ]; then
          _pr_gate_report "$gate" "$pr_num" "$sha" "$hold_min" "$findings"
          PR_GATE_HEAD_SHA="$sha"
          return 0
        fi
        ;;
    esac

    # Holding findings: fix within the cap, or hold.
    attempts=$(merge_gate_attempts "$jsonl" "$gate")
    case "$attempts" in ''|*[!0-9]*) attempts=0 ;; esac
    [ "$fixes_here" -gt "$attempts" ] && attempts="$fixes_here"
    if [ "$attempts" -ge "$GATE_MAX_FIXES" ]; then
      _pr_gate_hold_to_human "$gate" "$pr_num" "$run_dir" "$worktree" "$sha" \
        "korjausyritysten katto ($attempts/$GATE_MAX_FIXES) on täynnä" "$findings"
      return 10
    fi
    if ! _pr_gate_fix "$gate" "$pr_num" "$run_dir" "$worktree" "$branch" "$base_ref" "$sha" \
           "$(merge_gate_holding "$hold_min" "$findings")" "$((attempts + 1))"; then
      _pr_gate_hold_to_human "$gate" "$pr_num" "$run_dir" "$worktree" "$sha" "$GATE_WHY" "$findings" "$GATE_KIND"
      return 10
    fi
    fixes_here=$((fixes_here + 1))
    sha="$GATE_NEW_SHA"   # the new head is reviewed on the next pass
  done
}

# _merge_gate_findings_file <run-dir> <gate> <sha> — where a head's findings are
# kept, so a later tick can list them without reviewing the head again.
_merge_gate_findings_file() {
  printf '%s/merge-gate-%s-%s.findings' "$1" "$2" "$3"
}

# _merge_gate_context — the context the gate's trigger wrote, or nothing.
_merge_gate_context() {
  [ -n "${GATE_CONTEXT_FILE:-}" ] && cat "$GATE_CONTEXT_FILE" 2>/dev/null || true
}

# _pr_gate_review <gate> <pr> <run-dir> <worktree> <branch> <base-ref> <sha> <hold-min>
# One review call in a fresh context. Sets GATE_RESULT (clean | findings |
# launch_failed), GATE_FINDINGS, GATE_HOLDING and GATE_WHY, and records the
# result against the head in state.jsonl.
_pr_gate_review() {
  local gate="$1" pr_num="$2" run_dir="$3" worktree="$4" branch="$5" base_ref="$6" sha="$7" hold_min="$8"
  GATE_RESULT="launch_failed"
  GATE_FINDINGS=""
  GATE_HOLDING=0
  GATE_WHY=""

  # Preflight BEFORE the call, so a CLI that cannot start is reported as exactly
  # that (CLAUDE.md §9) — and, unlike FIX_CI, it holds: there is no "wait" for a
  # merge that would otherwise go through unreviewed. Each reviewer is checked
  # only when selected, and an unknown one is not a review: no fall back to
  # claude, which would silently undo the user's choice.
  local reviewer="${GATE_REVIEWER:-claude}" ready=0
  case "$reviewer" in
    claude)
      if pr_ci_repair_preflight "merge gate '$gate'"; then ready=1; else
        GATE_WHY="katselmointiagenttia ei voitu käynnistää (claude-CLI ei ole käytettävissä pr-watchin ympäristössä)"
      fi
      ;;
    codex)
      if pr_codex_preflight "merge gate '$gate' (codex reviewer)"; then ready=1; else
        GATE_WHY="Codex-katselmoijaa ei voitu käynnistää (codex-CLI ei ole käytettävissä pr-watchin ympäristössä; katselmoija on valittu asetuksella PR_WATCH_SECURITY_REVIEWER=codex)"
      fi
      ;;
    *)
      log "merge gate '$gate': unknown reviewer '$reviewer' (want claude or codex) — not reviewing"
      GATE_WHY="katselmoija \`$reviewer\` on tuntematon (sallitut: \`claude\`, \`codex\`), joten katselmusta ei ajettu"
      ;;
  esac
  if [ "$ready" -eq 1 ]; then
    log "merge gate '$gate': reviewing PR #$pr_num head $sha with $reviewer (hold threshold '$hold_min')"
    # Deterministic scanners run first, by the watcher itself, and write only
    # into the run-dir: the read-only check after the review covers them too.
    local scan_dir="$run_dir/scan-$gate-$sha" scanner_results="Tälle portille ei ole deterministisiä skannereita."
    if [ "$GATE_SCANNERS" = 1 ]; then
      rm -rf "$scan_dir"
      security_scan diff "$worktree" "$scan_dir" "$PR_ROUTE_REMOTE/$base_ref" >&2 \
        || { log "merge gate '$gate': security scan did not start for PR #$pr_num — recorded as a failed scan"; rm -rf "$scan_dir"; }
      [ -f "$scan_dir/scan.summary" ] && log "merge gate '$gate': scan: $(tr '\n' ';' < "$scan_dir/scan.summary")"
      scanner_results=$(security_scan_prompt_text "$scan_dir")
    fi
    local prompt_file="$run_dir/$GATE_REVIEW_STEP.prompt"
    render_prompt "$SCRIPT_DIR/prompts/$GATE_REVIEW_STEP.md" "$prompt_file" \
      PR_NUMBER="$pr_num" BRANCH="$branch" BASE_REF="$base_ref" \
      HEAD_SHA="$sha" REMOTE="$PR_ROUTE_REMOTE" SCANNER_RESULTS="$scanner_results" \
      GATE_CONTEXT="$(_merge_gate_context)"
    # A previous review's output must never be parsed as this one's, so the
    # call starts without it; repo principles are not loaded (see _pr_call_agent).
    rm -f "$run_dir/$GATE_REVIEW_STEP.out" "$run_dir/$GATE_REVIEW_STEP.exit"
    local arc=0
    if [ "$reviewer" = codex ]; then
      _pr_call_codex "$run_dir" "$worktree" "$GATE_REVIEW_STEP" "$prompt_file" \
        "$GATE_REVIEW_TIMEOUT" || arc=$?
    else
      _pr_call_agent "$run_dir" "$worktree" "$GATE_REVIEW_STEP" "$prompt_file" \
        "$GATE_REVIEW_TIMEOUT" 0 || arc=$?
    fi
    log "merge gate '$gate': $reviewer review call for PR #$pr_num returned rc=$arc"

    local out="$run_dir/$GATE_REVIEW_STEP.out"
    local head_after
    head_after=$( cd "$worktree" && git rev-parse HEAD 2>/dev/null || true )
    if [ "$head_after" != "$sha" ] || ( cd "$worktree" && git status --porcelain 2>/dev/null | grep -q . ); then
      # A read-only review that wrote is not a review of $sha.
      GATE_WHY="katselmointiagentti muutti worktreetä, vaikka sen piti vain lukea (head \`${head_after:-?}\`), joten katselmusta ei hyväksytty"
    else
      GATE_RESULT=$(merge_gate_parse "$out" "$run_dir/$GATE_REVIEW_STEP.exit")
      # A failed call is never a verdict, whatever the files say.
      [ "$arc" -ne 0 ] && GATE_RESULT="launch_failed"
      case "$GATE_RESULT" in
        launch_failed)
          if [ "$arc" -ne 0 ]; then
            GATE_WHY="katselmointiagentti päättyi virheeseen (rc=$arc; 127 = ei käynnistynyt, 124 = aikakatkaisu)"
          else
            GATE_WHY="katselmuksen tulos oli tyhjä tai jäsentymätön (\`MERGE_GATE_RESULT\`-rivi puuttui tai oli ristiriidassa löydösten kanssa)"
          fi
          ;;
        findings)
          GATE_FINDINGS=$(merge_gate_findings "$out")
          ;;
      esac
      # Scanner rows join the verdict AFTER parsing (a CLEAN marker next to
      # finding lines would parse as launch_failed) and deterministically: a
      # secret the scanner found holds whatever the reviewer said, and a failed
      # scanner turns a clean review into a reported one, never a silent pass.
      if [ "$GATE_RESULT" != "launch_failed" ] && [ "$GATE_SCANNERS" = 1 ]; then
        local scan_rows
        scan_rows=$(security_scan_gate_findings "$scan_dir")
        if [ -n "$scan_rows" ]; then
          GATE_FINDINGS=$(printf '%s\n%s\n' "$GATE_FINDINGS" "$scan_rows" | awk 'NF && !seen[$0]++')
          GATE_RESULT="findings"
        fi
      fi
      if [ "$GATE_RESULT" = "findings" ]; then
        GATE_HOLDING=$(merge_gate_holding "$hold_min" "$GATE_FINDINGS" | grep -c . || true)
        printf '%s\n' "$GATE_FINDINGS" > "$(_merge_gate_findings_file "$run_dir" "$gate" "$sha")"
      fi
    fi
  fi
  [ "$GATE_RESULT" = "launch_failed" ] && log "merge gate '$gate': review of PR #$pr_num did not complete — $GATE_WHY"
  local -a base_kv=()
  [ -n "${GATE_BASE_SHA:-}" ] && base_kv=("base_sha=$GATE_BASE_SHA")
  state_event "$run_dir" "merge_gate_reviewed" "gate=$gate" "pr=$pr_num" "sha=$sha" \
    "result=$GATE_RESULT" "holding=${GATE_HOLDING:-0}" "hold_min=$hold_min" \
    ${base_kv[@]+"${base_kv[@]}"}
}

# _pr_gate_fix <gate> <pr> <run-dir> <worktree> <branch> <base-ref> <sha> <findings> <attempt>
# One fix attempt with the same machinery as CI repair: agent in the feature
# worktree, independent check of the result, force-push, mandatory CI
# revalidation. rc 0 sets GATE_NEW_SHA; rc 1 sets GATE_WHY and GATE_KIND.
_pr_gate_fix() {
  local gate="$1" pr_num="$2" run_dir="$3" worktree="$4" branch="$5" base_ref="$6" sha="$7" findings="$8" attempt="$9"
  GATE_NEW_SHA=""
  GATE_WHY=""
  GATE_KIND="agent_ran"

  # The spend is recorded BEFORE the call: a crash mid-fix still counts.
  state_event "$run_dir" "merge_gate_fix_attempted" "gate=$gate" "pr=$pr_num" "sha=$sha" "attempt=$attempt"
  log "merge gate '$gate': fix attempt $attempt for PR #$pr_num head $sha"

  local prompt_file="$run_dir/$GATE_FIX_STEP.prompt"
  render_prompt "$SCRIPT_DIR/prompts/$GATE_FIX_STEP.md" "$prompt_file" \
    PR_NUMBER="$pr_num" BRANCH="$branch" BASE_REF="$base_ref" \
    HEAD_SHA="$sha" REMOTE="$PR_ROUTE_REMOTE" \
    FINDINGS="$(printf '%s\n' "$findings" | sed 's/|/ | /g')" \
    GATE_CONTEXT="$(_merge_gate_context)"
  local arc=0
  _pr_call_agent "$run_dir" "$worktree" "$GATE_FIX_STEP" "$prompt_file" \
    "$GATE_FIX_TIMEOUT" || arc=$?
  log "merge gate '$gate': fix call for PR #$pr_num returned rc=$arc"
  if [ "$arc" -eq 127 ]; then
    GATE_WHY="korjausagenttia ei voitu käynnistää (rc=127)"
    GATE_KIND="launch_failed"
    return 1
  fi

  local head_after
  head_after=$( cd "$worktree" && git rev-parse HEAD 2>/dev/null || true )
  if [ -z "$head_after" ] || [ "$head_after" = "$sha" ]; then
    GATE_WHY="korjausagentti ei tuottanut korjaavaa committia"
    return 1
  fi
  if ( cd "$worktree" && git status --porcelain 2>/dev/null | grep -q . ); then
    GATE_WHY="korjausagentti jätti työpuun likaiseksi (committaamattomia muutoksia)"
    return 1
  fi
  if ! _pr_force_push "$worktree" "$branch"; then
    GATE_WHY="korjauksen push epäonnistui"
    return 1
  fi
  if ! pr_wait_ci_green "$pr_num" "$head_after"; then
    GATE_WHY="CI ei vihreytynyt korjauksen jälkeen"
    return 1
  fi
  state_event "$run_dir" "merge_gate_fix_pushed" "gate=$gate" "pr=$pr_num" "sha=$head_after"
  GATE_NEW_SHA="$head_after"
  return 0
}

# _pr_gate_report <gate> <pr> <sha> <hold-min> <findings> — comment findings
# below the threshold. They do not hold the merge; the comment is posted once per
# head, because a reviewed head is never reviewed again.
_pr_gate_report() {
  local gate="$1" pr_num="$2" sha="$3" hold_min="$4" findings="$5"
  log "merge gate '$gate': PR #$pr_num head $sha has findings below '$hold_min' only — reporting, merging"
  local body
  body=$(printf '%s\n\n%s\n\n%s\n' \
    "$GATE_TITLE (head \`$sha\`) löysi havaintoja, jotka jäävät pidätysrajan \`$hold_min\` alle. PR mergetään, mutta tarkista nämä:" \
    "$(merge_gate_format_findings "$findings")" \
    "(Merge-portti \`$gate\` on päällä \`$GATE_SWITCH=1\`. Pidätysraja: kohderepon \`.claude/run-issues.json\` \`.$gate.hold_min_severity\` tai koneen asetus.)")
  printf '%s' "$body" | gh_route pr comment "$pr_num" --body-file - || \
    log "failed to post $gate gate report on PR #$pr_num"
}

# _pr_gate_hold_to_human <gate> <pr> <run-dir> <worktree> <sha> <why> <findings> [<kind>]
# The gate's handover — same idiom as _pr_ci_handover_to_human: needs-human
# label, run finalized blocked with a reason scan_candidates re-emits
# (<gate>_gate_failed_pr_<n>), and a comment listing what is left. The branch is
# left as-is. <kind> launch_failed says plainly that no review happened.
_pr_gate_hold_to_human() {
  local gate="$1" pr_num="$2" run_dir="$3" worktree="$4" sha="$5" why="$6" findings="$7" kind="${8:-agent_ran}"

  log "merge gate '$gate': holding PR #$pr_num for a human — $why"
  _pr_mark_needs_human "$pr_num"
  state_finalize "$run_dir" "blocked" "${gate}_gate_failed_pr_$pr_num"
  state_event "$run_dir" "merge_gate_held" "gate=$gate" "pr=$pr_num" "sha=$sha" "reason=$why"

  local opening list
  if [ "$kind" = "launch_failed" ]; then
    opening="$GATE_TITLE **ei toteutunut** headille \`$sha\`: $why. Koodia ei siis katselmoitu, joten PR:ää ei mergetä ilman ihmistä."
  else
    opening="$GATE_TITLE löysi headista \`$sha\` pidätysrajan ylittäviä löydöksiä, eikä automaattinen korjaus onnistunut: $why."
  fi
  if [ -n "$findings" ]; then
    list="Jäljelle jääneet löydökset:"$'\n\n'"$(merge_gate_format_findings "$findings")"
  else
    list="Löydöslistaa ei ole: katselmus ei valmistunut, tai headin löydöstiedosto puuttuu run-diristä."
  fi
  [ -n "${GATE_CONTEXT_SUMMARY:-}" ] && list="$list"$'\n\n'"Portin konteksti: $GATE_CONTEXT_SUMMARY"

  local body
  body=$(printf '%s\n\n%s\n\n%s\n%s\n' \
    "$opening" \
    "$list" \
    "PR:ää **ei mergetty**. Haara on ennallaan worktreessä \`$worktree\`." \
    "(Merge-portti \`$gate\` on päällä \`$GATE_SWITCH=1\`. Korjaa ja pushaa, ja poista sitten \`needs-human\`-label: valvoja katselmoi uuden headin. Samaa headia ei katselmoida uudelleen, joten ilman uutta committia PR pidätetään taas. Hyväksytyt löydökset mergetään käsin.)")
  printf '%s' "$body" | gh_route pr comment "$pr_num" --body-file - || \
    log "failed to post $gate gate hold comment on PR #$pr_num"
}

# ----- The semantic gate's trigger (issue #341) ----------------------------
# GATE_TRIGGER of the `semantic` gate (contract: pr_run_merge_gate). Deterministic
# and agent-free: review only when a sibling runner PR merged into the base since
# this run started touches a directory this PR touches.
#
# The window starts at the run's start, not at the merge-base: a PR the watcher
# rebased (P5) has the base's tip as its merge-base, so `merge-base..base` would be
# empty exactly when siblings landed under it. The base's commits are dated by
# their merge (GitHub rewrites the committer on rebase and squash merges), so
# `--since=<started_at>` is that window. A run-dir without started_at falls back to
# merge-base..base.
#
# Cost (CLAUDE.md §5.2/§5.4): at most ONE gh call, a REST listing, and only when
# the base has gained commits in the window; everything else is local git.
_pr_semantic_trigger() {
  local pr_num="$1" rid="$2" run_dir="$3" worktree="$4" base_ref="$5" ctx="$6"
  local base="$PR_ROUTE_REMOTE/$base_ref"

  local mine_files mine_dirs
  mine_files=$( cd "$worktree" && git diff --name-only "$base...HEAD" 2>/dev/null ) || return 2
  mine_dirs=$(printf '%s\n' "$mine_files" | semantic_dirs_of)
  [ -n "$mine_dirs" ] || return 1

  local started range mb
  started=$(run_field "$rid" '.started_at')
  if [ -n "$started" ]; then
    range=$( cd "$worktree" && git rev-list --first-parent --reverse --since="$started" "$base" 2>/dev/null ) || return 2
  else
    mb=$( cd "$worktree" && git merge-base HEAD "$base" 2>/dev/null ) || return 2
    range=$( cd "$worktree" && git rev-list --first-parent --reverse "$mb..$base" 2>/dev/null ) || return 2
  fi
  if [ -z "$range" ]; then
    log "semantic gate: base '$base' has no commits since the run started — no sibling to compare with"
    return 1
  fi
  # The span of the oldest sibling starts at the commit before the window; a
  # window that starts at the root starts at the empty tree.
  local boundary
  boundary=$( cd "$worktree" && git rev-parse --verify -q "${range%%$'\n'*}^1" 2>/dev/null ) \
    || boundary=$( cd "$worktree" && git hash-object -t tree /dev/null )

  local owner_repo="$PR_OWNER_REPO" json siblings
  [ -n "$owner_repo" ] || owner_repo='{owner}/{repo}'
  if ! json=$(gh_route api "repos/$owner_repo/pulls?state=closed&base=$base_ref&sort=updated&direction=desc&per_page=100"); then
    log "semantic gate: listing closed PRs failed for PR #$pr_num"
    return 2
  fi
  if ! siblings=$(semantic_merged_siblings "$json" "$pr_num"); then
    log "semantic gate: closed-PR listing for PR #$pr_num is not a JSON array — not a pass"
    return 2
  fi

  local spans num ref from to dirs overlap hits="" tmp
  spans=$(semantic_sibling_spans "$boundary"$'\n'"$range" "$siblings")
  tmp=$(mktemp -t pr-watch-semantic.XXXXXX)
  while IFS=$'\t' read -r num ref from to; do
    [ -n "$to" ] || continue
    dirs=$( cd "$worktree" && git diff --name-only "$from" "$to" 2>/dev/null | semantic_dirs_of ) || { rm -f "$tmp"; return 2; }
    overlap=$(semantic_dirs_overlap "$mine_dirs" "$dirs")
    if [ -z "$overlap" ]; then
      log "semantic gate: sibling PR #$num ($ref) merged in the window but shares no directory with PR #$pr_num"
      continue
    fi
    hits="${hits:+$hits, }#$num (\`$ref\`)"
    {
      printf '### Sisar-PR #%s (`%s`)\n\n' "$num" "$ref"
      printf 'Mergetty baseen commitissa `%s`. Yhteiset hakemistot: %s. Koko diff: `git diff %s %s`.\n\n' \
        "$to" "$(printf '%s\n' "$overlap" | sed 's/.*/`&`/' | paste -sd, - | sed 's/,/, /g')" "$from" "$to"
      printf '```diff\n'
      ( cd "$worktree" && git diff "$from" "$to" 2>/dev/null )
      printf '```\n\n'
    } >> "$tmp"
  done <<<"$spans"

  if [ -z "$hits" ]; then
    rm -f "$tmp"
    return 1
  fi
  local size
  size=$(wc -c < "$tmp" | tr -d ' ')
  if [ "$size" -gt "$PR_WATCH_SEMANTIC_CONTEXT_MAX" ]; then
    { head -c "$PR_WATCH_SEMANTIC_CONTEXT_MAX" "$tmp"
      printf '\n```\n\n(Sisarten diffit on katkaistu %s tavuun %s:sta. Lue loput otsikoiden `git diff` -komennoilla.)\n' \
        "$PR_WATCH_SEMANTIC_CONTEXT_MAX" "$size"; } > "$ctx"
  else
    cp "$tmp" "$ctx"
  fi
  rm -f "$tmp"
  GATE_CONTEXT_SUMMARY="välissä mergetyt sisar-PR:t samoissa hakemistoissa: $hits"
  log "semantic gate: PR #$pr_num shares directories with $hits — reviewing"
  return 0
}

# ----- P0: dependency gate (issue #279) -----------------------------------
# A missing or unauthenticated gh used to look exactly like a transient PR-level
# error: the first `gh pr view` failed, watch_one logged "gh pr view failed for
# PR #N" and returned 4 ("safe to retry next poll") — but nothing had been
# checked and nothing changed on the next tick, so the run was silently stuck
# (observed 2026-09-09: gh absent from a non-interactive ssh session's PATH).
# This gate moves the observation to the one point where it is still cheap and
# honest: before the first PR call, ONCE per invocation (not once per PR, so a
# multi-repo scan cannot print the same line per candidate — §5.7).
#
# It reuses lib/preflight.sh (preflight_have + preflight_install_hint), the same
# probe the orchestrator's S0 gate uses, rather than re-deriving the check. gh
# authentication is policy, not a fact about a tool, so — exactly as in the
# orchestrator (orchestrate.sh) — the `gh auth token` check lives in this caller,
# not in the pure module. `gh auth token` (not `gh auth status`) is deliberate:
# status calls the API, which would make a network outage a new way for the
# watcher to fail to start. In App mode the runs authenticate with an
# installation token, so a missing personal login is only advisory there.
#
# Exit 9 is its own code, distinct from 4: a missing dependency is a durable
# condition, not a transient one, so it must never read as "safe to retry".
pr_watch_gh_gate() {
  if ! preflight_have gh; then
    log "gh is not available on PATH — cannot watch any PR (fix: $(preflight_install_hint gh)); exit 9"
    exit 9
  fi
  if ! gh auth token >/dev/null 2>&1; then
    if gha_enabled; then
      log "WARNING: gh has no personal auth token ($(preflight_install_hint gh-auth)) — proceeding on the GitHub App installation token"
    else
      log "gh is not authenticated — cannot watch any PR (fix: $(preflight_install_hint gh-auth)); exit 9"
      exit 9
    fi
  fi
}
pr_watch_gh_gate

# ----- main ---------------------------------------------------------------
if [ "$TARGET" = "scan" ]; then
  # Collect candidates once so we can log HOW MANY were examined for this
  # (repo, remote) before processing (issue #33). The old lone `launching` line
  # could not distinguish "no mergeable PRs here" from "looked at the wrong
  # repo" — a remote-scoped candidate count makes a mis-routed scan visible in
  # the log immediately instead of only via PRs that never merge.
  candidates=$(scan_candidates)
  candidate_count=$(printf '%s' "$candidates" | grep -c . || true)
  log "repo=$REPO_ROOT remote=${REMOTE_FILTER:-all} candidates=$candidate_count"

  found=0
  rc_final=2
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "${PR_RATE_LIMITED:-0}" -eq 1 ]; then
      log "scan: stopping early — GitHub rate limit (remaining PRs deferred to a later tick)"
      break
    fi
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
  done <<EOF
$candidates
EOF

  [ "$found" = "1" ] || { log "scan: no candidate PRs"; exit 2; }
  exit "$rc_final"
fi

# Named-PR mode.
case "$TARGET" in
  ''|*[!0-9]*) echo "pr-watch: PR target must be a number or 'scan'" >&2; exit 1 ;;
esac
watch_one "$TARGET"
exit $?
