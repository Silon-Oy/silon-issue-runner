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
#   8  red CI needs a human (AI could not repair / CI stayed red / attempt cap
#      reached — PR commented, needs-human label added)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-remote.sh
# Multi-remote routing (issue #33): resolve_remote_to_owner_repo is the fallback
# owner/repo derivation for a non-origin run whose run.json predates the
# .owner_repo field. Pure functions; no top-level work.
. "$SCRIPT_DIR/lib/git-remote.sh"
# shellcheck source=lib/locking.sh
. "$SCRIPT_DIR/lib/locking.sh"
# shellcheck source=lib/state.sh
. "$SCRIPT_DIR/lib/state.sh"
# shellcheck source=lib/pr-watch-lib.sh
. "$SCRIPT_DIR/lib/pr-watch-lib.sh"

# rate_limit_* (issue #126): the watcher spends the SAME GitHub quota as the
# pollers, so it must be able to trip the shared backoff. Functions only.
# shellcheck source=lib/rate-limit.sh
. "$SCRIPT_DIR/lib/rate-limit.sh"
# shellcheck source=lib/claude-call.sh
. "$SCRIPT_DIR/lib/claude-call.sh"
# shellcheck source=lib/preflight.sh
# Shared dependency probe. Reused for the CI-repair path's claude-CLI preflight
# (issue #45): the orchestrator's S0 gate already catches the npx --no-install
# 127 trap before a run starts, but the watcher's FIX_CI classification called
# the same CLI with no such guard, so a missing agent produced rc=127, a
# misleading "agent found no fix" comment, and a permanently blocked PR. This
# gives the watcher the identical probe. RUN_ISSUES_CLAUDE_CMD{,_DEFAULT} come
# from claude-call.sh, sourced above.
. "$SCRIPT_DIR/lib/preflight.sh"
# shellcheck source=lib/labels.sh
# Label writes go through the REST helpers (no read:project scope needed). The
# CI-repair human-handover attaches the needs-human label through these.
. "$SCRIPT_DIR/lib/labels.sh"
# shellcheck source=lib/github-app-auth.sh
# Opt-in GitHub App identity (same env vars as the orchestrator). gha_with_token
# is a pass-through when App mode is off, so wrapping every gh call here is
# regression-free for repos that don't configure the App.
#
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
# shellcheck source=lib/machine-env.sh
. "$SCRIPT_DIR/lib/machine-env.sh"
RUN_ISSUES_ENV_FILE="${RUN_ISSUES_ENV_FILE:-$HOME/.config/run-issues/env}"
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
PR_WATCH_MERGE_LABEL="${PR_WATCH_MERGE_LABEL:-auto-merge}"
PR_WATCH_LABELS_CSV="${PR_WATCH_LABELS_CSV:-}"

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
THIS_HOST="$(hostname -s)"

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
  [ -n "$PR_OWNER_REPO" ] && repo_args=(--repo "$PR_OWNER_REPO")
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
    # Emit completed runs, PLUS runs left blocked by a CI-repair handover (issue
    # #45, symptom B): those must return to the scan so a PR whose CI has since
    # gone green (human fixed the cause in main, rebased, removed needs-human) is
    # merged instead of stranded forever. The condition is deliberately NARROW —
    # only the ci_repair_failed* blocked_reason — so every other blocked state
    # (stalled_in_*, env_bootstrap_failed, pr_conflicted) stays out of the scan
    # exactly as before; watch_one applies the needs-human hold gate before acting.
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
          ci_repair_failed*) : ;;
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
  if ! pr_json=$(gh_route pr view "$pr_num" \
        --json state,mergeable,mergeStateStatus,labels,statusCheckRollup,headRefName,baseRefName 2>/dev/null); then
    log "gh pr view failed for PR #$pr_num"
    _release
    return 4
  fi

  # ----- Issue #45 (symptom B): un-stick a CI-repair handover ------------
  # A run this watcher previously blocked via _pr_ci_handover_to_human is
  # re-emitted into the scan (scan_candidates below), so it is no longer lost
  # forever. The needs-human label is the hold flag: while present, the watcher
  # stays hands-off — no re-decision, no repeated comment on every poll. Once a
  # human removes it (as the handover comment instructs), the run is re-armed and
  # falls through to the normal decision: it merges if CI has since gone green, or
  # is re-attempted/re-handed-over if still red. This delivers what the comment
  # promises ("remove needs-human when handled").
  case "$run_blocked_reason" in
    ci_repair_failed*)
      if [ "$run_status" = "blocked" ] && pr_has_label "$pr_json" needs-human; then
        log "PR #$pr_num held by needs-human (CI-repair handover) — skipping until a human removes the label"
        [ -n "$run_dir" ] && [ -d "$run_dir" ] && \
          state_event "$run_dir" "pr_watch_skipped" "pr=$pr_num" "reason=needs_human_held"
        _release
        return 4
      fi
      [ "$run_status" = "blocked" ] && \
        log "PR #$pr_num re-armed after CI-repair handover (needs-human removed) — re-examining"
      ;;
  esac

  local decision
  decision=$(pr_decide "$pr_json" "$PR_WATCH_ENABLE_CONFLICT_RESOLUTION" "$PR_WATCH_MERGE_LABEL" "$PR_WATCH_ENABLE_CI_REPAIR")

  # S0-style CI-repair preflight (issue #45, symptom A): FIX_CI is only a useful
  # classification if the claude CLI can actually launch. If it cannot (the
  # npx --no-install 127 trap the orchestrator's S0 gate catches), downgrade to
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
  local merge_out
  log "merging PR #$pr_num (--rebase --delete-branch)"
  if ! merge_out=$(gh_route pr merge "$pr_num" --rebase --delete-branch 2>&1); then
    log "PR #$pr_num: rebase merge failed (merge commit on branch?) — retrying with --merge: ${merge_out:-<no output>}"
    if ! merge_out=$(gh_route pr merge "$pr_num" --merge --delete-branch 2>&1); then
      log "merge failed for PR #$pr_num: ${merge_out:-<no output>}"
      [ -n "$run_dir" ] && [ -d "$run_dir" ] && \
        state_event "$run_dir" "pr_watch_skipped" "pr=$pr_num" "reason=merge_failed"
      _release
      return 5
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
  # When App mode is on we pass the App token via http.extraheader so the
  # fetch credential matches the eventual push credential (otherwise a repo
  # configured to only accept the App's PAT-equivalent would refuse fetch).
  local _watch_auth_header=""
  local _h=""
  if _h=$(gha_git_push_header 2>/dev/null); then
    _watch_auth_header="$_h"
  fi
  _h=""
  if [ -n "$_watch_auth_header" ]; then
    if ! ( cd "$worktree" && git -c "http.extraheader=$_watch_auth_header" fetch "$PR_ROUTE_REMOTE" "$base_ref" --quiet ); then
      log "git fetch $PR_ROUTE_REMOTE $base_ref failed for PR #$pr_num — retrying next poll"
      [ -n "$run_dir" ] && [ -d "$run_dir" ] && \
        state_event "$run_dir" "pr_watch_skipped" "pr=$pr_num" "reason=fetch_failed"
      _watch_auth_header=""
      return 4
    fi
  else
    if ! ( cd "$worktree" && git fetch "$PR_ROUTE_REMOTE" "$base_ref" --quiet ); then
      log "git fetch $PR_ROUTE_REMOTE $base_ref failed for PR #$pr_num — retrying next poll"
      [ -n "$run_dir" ] && [ -d "$run_dir" ] && \
        state_event "$run_dir" "pr_watch_skipped" "pr=$pr_num" "reason=fetch_failed"
      return 4
    fi
  fi
  _watch_auth_header=""

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
    out=$(gh_route pr checks "$pr_num" 2>/dev/null)
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

# ===== Shared worktree-agent seams (conflict resolution + CI repair) =======
# Both self-repair paths (P5 conflict resolution and P5b CI repair) run an AI
# agent in the feature worktree and then force-push it. These two helpers are
# that common mechanism, extracted so neither path copies it.

# _pr_call_agent <out-dir> <worktree> <step-id> <prompt-file> <timeout-secs>
# Runs the claude CLI with the worktree as CWD (the agent edits files + drives
# git there) under a dedicated wall-clock budget so a wedged call can't hang the
# watcher. Returns the agent's rc — but callers must NOT trust it: the worktree
# / CI state is always verified independently afterwards.
_pr_call_agent() {
  local out_dir="$1" worktree="$2" step_id="$3" prompt_file="$4" timeout_secs="$5"
  local crc=0
  (
    cd "$worktree" || exit 99
    RUN_ISSUES_CLAUDE_TIMEOUT="$timeout_secs" \
      call_claude "$out_dir" "$step_id" "$prompt_file"
  ) || crc=$?
  return "$crc"
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
# the DEFAULT invocation `npx --no-install @anthropic-ai/claude-code` exits 127
# when the package is absent even though npx itself is on PATH, so `command -v`
# cannot see the failure — only an actual `--version` probe can. An overridden
# RUN_ISSUES_CLAUDE_CMD is the user's own driver whose --version we must neither
# guess nor fire, so we only verify its first token is callable (same policy as
# S0's `have` mode). Logs the reason once on failure. Returns 0 usable, 1 not.
pr_ci_repair_preflight() {
  local reason=""
  if [ "$RUN_ISSUES_CLAUDE_CMD" = "$RUN_ISSUES_CLAUDE_CMD_DEFAULT" ]; then
    # shellcheck disable=SC2086
    if ! preflight_probe_claude $RUN_ISSUES_CLAUDE_CMD; then
      reason="claude CLI probe failed (\`$RUN_ISSUES_CLAUDE_CMD --version\` returned non-zero — likely the npx --no-install 127 trap; fix: $(preflight_install_hint claude))"
    fi
  else
    local first="${RUN_ISSUES_CLAUDE_CMD%% *}"
    if ! preflight_have "$first"; then
      reason="claude driver '$first' not found on PATH (RUN_ISSUES_CLAUDE_CMD override)"
    fi
  fi
  [ -z "$reason" ] && return 0
  log "CI-repair unavailable: $reason"
  return 1
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

  if pr_wait_ci_green "$pr_num"; then
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

  # needs-human label — ensure it exists, then attach. Both are best-effort. The
  # REST label helpers route to PR_OWNER_REPO when known (issue #33) and fall back
  # to {owner}/{repo} cwd inference when empty, so we keep the REPO_ROOT cwd.
  ( cd "$REPO_ROOT" && labels_ensure "$PR_OWNER_REPO" needs-human B60205 "Vaatii ihmisen — automaatio luovutti" ) \
    || log "could not ensure needs-human label for PR #$pr_num"
  ( cd "$REPO_ROOT" && labels_add "$PR_OWNER_REPO" "$pr_num" needs-human ) \
    || log "could not add needs-human label to PR #$pr_num"

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
