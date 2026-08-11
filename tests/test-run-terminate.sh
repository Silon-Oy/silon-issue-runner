#!/usr/bin/env bash
# test-run-terminate.sh — lib/run-terminate.sh:run_terminate (issue #63).
#
# run_terminate is the safe live-run teardown extracted from
# poller.sh:finalize_stalled. Unlike the stale-detection test (which extracts
# the poller's thin wrapper), this exercises the lib directly. It covers the
# five responsibilities that were each paid for by a production incident:
#
#   - foreign-host gate: no tmux kill, no state_finalize, refused return
#   - exact tmux match: run-issues-3 must NOT kill run-issues-34
#   - state_finalize writes the given reason + a <context>_finalized event
#   - lock teardown from the run's OWN repo_slug+remote identity (#67 regression)
#   - pre-#67 run (no repo_slug) releases the legacy-named lock
#
# Fixtures live under a mktemp HOME + RUN_ISSUES_LOCK_ROOT so the real lock root
# (which the poller uses on this same machine) is never touched.
#
# Run: bash tests/test-run-terminate.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK=$(mktemp -d -t run-terminate.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Sandbox: redirect HOME and the lock root so nothing outside $WORK is touched.
export HOME="$WORK/home"
mkdir -p "$HOME"
export RUN_ISSUES_LOCK_ROOT="$WORK/locks"
mkdir -p "$RUN_ISSUES_LOCK_ROOT"

# run-terminate.sh sources its own deps (git-remote/state/labels/issue), so the
# lib is all we need to pull in.
# shellcheck source=lib/run-terminate.sh
. "$HERE/../lib/run-terminate.sh"

# Globals run_terminate reads.
# shellcheck disable=SC2034
THIS_HOST="test-host"
# shellcheck disable=SC2034
RUN_ISSUES_STALE_AFTER=1800
LOG="$WORK/run.log"          # run_terminate logs here when $LOG is set
: > "$LOG"

REPO="$WORK/repo"
mkdir -p "$REPO/.git"

# --- Mock tmux (same model as test-poller-stale-detection.sh) ----------------
# Sessions "exist" as files in $WORK/tmux-sessions/. run_terminate addresses
# them with an EXACT target `-t "=<name>"`; the mock strips the leading `=`
# before the filesystem lookup, so it faithfully models exact-match semantics.
mkdir -p "$WORK/tmux-sessions"
TMUX_LOG="$WORK/tmux-calls.log"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$TMUX_LOG"
case "\$1" in
  has-session)
    shift; while [ "\$1" != "-t" ] && [ \$# -gt 0 ]; do shift; done
    name="\${2#=}"
    [ -f "$WORK/tmux-sessions/\$name" ]
    ;;
  kill-session)
    shift; while [ "\$1" != "-t" ] && [ \$# -gt 0 ]; do shift; done
    name="\${2#=}"
    rm -f "$WORK/tmux-sessions/\$name"
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$WORK/bin/tmux"
PATH="$WORK/bin:$PATH"

# --- Mock gh: log calls, drain piped bodies -----------------------------------
GH_LOG="$WORK/gh-calls.log"
cat > "$WORK/bin/gh" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"
case "\$*" in
  *"--body-file"*) cat "\$(awk '{for(i=1;i<=NF;i++) if(\$i=="--body-file") print \$(i+1)}' <<< "\$*")" >/dev/null 2>&1 || true ;;
esac
exit 0
SH
chmod +x "$WORK/bin/gh"

# mk_run <rid> <issue> <host> <remote> <repo-slug> [current_state]
# Writes a run.json (and empty state.jsonl) with full control over every field
# run_terminate reads. An empty <remote> means the field is written as "origin";
# an empty <repo-slug> means the field is absent (pre-#67 run).
mk_run() {
  local rid="$1" issue="$2" host="$3" remote="$4" slug="$5" cstate="${6:-S7b_EnvBootstrap}"
  local rd="$REPO/.claude/run-issues/$rid"
  mkdir -p "$rd"
  : > "$rd/state.jsonl"
  local rem="${remote:-origin}"
  jq -n \
    --arg run_id "$rid" \
    --arg repo "$REPO" \
    --argjson issue "$issue" \
    --arg host "$host" \
    --arg remote "$rem" \
    --arg slug "$slug" \
    --arg cs "$cstate" \
    '{
      run_id: $run_id,
      repo: $repo,
      issue_number: $issue,
      status: "initialized",
      host: $host,
      current_state: $cs,
      remote: $remote,
      finished_at: null,
      blocked_reason: null
    }
    | (if $slug == "" then . else . + {repo_slug: $slug} end)' \
    > "$rd/run.json"
  echo "$rd"
}

FAIL=0

# ===========================================================================
# 1. Foreign-host gate: no side effects at all.
# ===========================================================================
RD_FOREIGN=$(mk_run "20260601-1000-issue-200" 200 "other-host" "origin" "repo-a")
touch "$WORK/tmux-sessions/run-issues-200"
mkdir -p "$RUN_ISSUES_LOCK_ROOT/repo-a-issue-200.lock"

: > "$TMUX_LOG"; : > "$GH_LOG"
run_terminate "$RD_FOREIGN" "stalled_in_S7b_EnvBootstrap" "stalled"
RC=$?

[ "$RC" = "0" ] || { echo "FAIL foreign: return code $RC (want 0)"; FAIL=1; }
[ "$(jq -r '.status' "$RD_FOREIGN/run.json")" = "initialized" ] \
  || { echo "FAIL foreign: run.json status mutated"; FAIL=1; }
[ -f "$WORK/tmux-sessions/run-issues-200" ] \
  || { echo "FAIL foreign: tmux session was killed"; FAIL=1; }
[ -d "$RUN_ISSUES_LOCK_ROOT/repo-a-issue-200.lock" ] \
  || { echo "FAIL foreign: lock was released"; FAIL=1; }
grep -q "kill-session" "$TMUX_LOG" \
  && { echo "FAIL foreign: kill-session issued"; FAIL=1; }
grep -q "refusing foreign host" "$LOG" \
  || { echo "FAIL foreign: no refusal log line"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS foreign-host gate: no tmux kill, no finalize, refused"

# ===========================================================================
# 2. Lock teardown uses the run's OWN repo_slug+remote (issue #67 regression).
#    A different repo's same-numbered lock must survive.
# ===========================================================================
RD_OWN=$(mk_run "20260601-1001-issue-42" 42 "test-host" "origin" "repo-a")
# The run's own lock, plus a decoy from a DIFFERENT repo with the same issue #,
# plus the legacy repo-agnostic lock — only the run's own must be removed.
mkdir -p "$RUN_ISSUES_LOCK_ROOT/repo-a-issue-42.lock"    # this run's own
mkdir -p "$RUN_ISSUES_LOCK_ROOT/repo-b-issue-42.lock"    # another repo, same #
mkdir -p "$RUN_ISSUES_LOCK_ROOT/issue-42.lock"           # legacy repo-agnostic

: > "$TMUX_LOG"; : > "$GH_LOG"
run_terminate "$RD_OWN" "stalled_in_S7b_EnvBootstrap" "stalled"

[ ! -d "$RUN_ISSUES_LOCK_ROOT/repo-a-issue-42.lock" ] \
  || { echo "FAIL lock: run's own lock not released"; FAIL=1; }
[ -d "$RUN_ISSUES_LOCK_ROOT/repo-b-issue-42.lock" ] \
  || { echo "FAIL lock: OTHER repo's same-numbered lock was stolen (#67)"; FAIL=1; }
[ -d "$RUN_ISSUES_LOCK_ROOT/issue-42.lock" ] \
  || { echo "FAIL lock: legacy lock removed though run carries a repo_slug"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS lock teardown: run's own identity only; cross-repo lock safe (#67)"

# ===========================================================================
# 3. Pre-#67 run (no repo_slug) releases the legacy-named lock.
# ===========================================================================
RD_LEGACY=$(mk_run "20260601-1002-issue-43" 43 "test-host" "origin" "")
mkdir -p "$RUN_ISSUES_LOCK_ROOT/issue-43.lock"           # legacy shape
mkdir -p "$RUN_ISSUES_LOCK_ROOT/repo-a-issue-43.lock"    # decoy, must survive

: > "$TMUX_LOG"; : > "$GH_LOG"
run_terminate "$RD_LEGACY" "stalled_in_S7b_EnvBootstrap" "stalled"

[ ! -d "$RUN_ISSUES_LOCK_ROOT/issue-43.lock" ] \
  || { echo "FAIL legacy: legacy-named lock not released"; FAIL=1; }
[ -d "$RUN_ISSUES_LOCK_ROOT/repo-a-issue-43.lock" ] \
  || { echo "FAIL legacy: unrelated repo-slug lock removed"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS pre-#67 run: legacy-named lock released"

# ===========================================================================
# 4. Exact tmux match: run-issues-3 must not kill run-issues-34.
# ===========================================================================
RD_EXACT=$(mk_run "20260601-1003-issue-3" 3 "test-host" "origin" "")
touch "$WORK/tmux-sessions/run-issues-3"
touch "$WORK/tmux-sessions/run-issues-34"

: > "$TMUX_LOG"; : > "$GH_LOG"
run_terminate "$RD_EXACT" "stalled_in_S8_Implementer" "stalled"

[ ! -f "$WORK/tmux-sessions/run-issues-3" ] \
  || { echo "FAIL exact: run-issues-3 not killed"; FAIL=1; }
[ -f "$WORK/tmux-sessions/run-issues-34" ] \
  || { echo "FAIL exact: run-issues-34 killed by prefix match"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS exact tmux match: run-issues-3 killed, run-issues-34 spared"

# ===========================================================================
# 5. state_finalize writes the given reason + a <context>_finalized event.
# ===========================================================================
RD_STATE=$(mk_run "20260601-1004-issue-50" 50 "test-host" "origin" "repo-a" "S9_Evolution")

: > "$TMUX_LOG"; : > "$GH_LOG"
run_terminate "$RD_STATE" "stalled_in_S9_Evolution" "stalled"

[ "$(jq -r '.status' "$RD_STATE/run.json")" = "blocked" ] \
  || { echo "FAIL state: status not blocked"; FAIL=1; }
[ "$(jq -r '.blocked_reason' "$RD_STATE/run.json")" = "stalled_in_S9_Evolution" ] \
  || { echo "FAIL state: blocked_reason wrong"; FAIL=1; }
grep -q '"event":"stalled_finalized"' "$RD_STATE/state.jsonl" \
  || { echo "FAIL state: no stalled_finalized event"; FAIL=1; }
# needs-human label + situation comment attempted.
grep -qF "labels[]=needs-human" "$GH_LOG" \
  || { echo "FAIL state: needs-human label not attempted"; FAIL=1; }
grep -q "issue comment" "$GH_LOG" \
  || { echo "FAIL state: situation comment not posted"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS state finalize: blocked/reason + event + label + comment"

# ===========================================================================
# 6. Context drives the event name: a different context -> <context>_finalized.
# ===========================================================================
RD_CTX=$(mk_run "20260601-1005-issue-51" 51 "test-host" "origin" "repo-a" "S8_Implementer")

: > "$TMUX_LOG"; : > "$GH_LOG"
run_terminate "$RD_CTX" "stopped_by_request" "stopped"

grep -q '"event":"stopped_finalized"' "$RD_CTX/state.jsonl" \
  || { echo "FAIL context: event name not derived from context"; FAIL=1; }
[ "$(jq -r '.blocked_reason' "$RD_CTX/run.json")" = "stopped_by_request" ] \
  || { echo "FAIL context: reason not written verbatim"; FAIL=1; }
grep -q "STOPPED issue=#51" "$LOG" \
  || { echo "FAIL context: log headline verb not uppercased context"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS context flavouring: event name + log verb follow the context arg"

# ===========================================================================
# 7. Missing run.json -> no-op, return 0.
# ===========================================================================
run_terminate "$WORK/does-not-exist" "stalled_in_x" "stalled"
[ "$?" = "0" ] || { echo "FAIL missing: non-zero return for missing run.json"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS missing run.json: no-op, return 0"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "run-terminate: all passed" || echo "run-terminate: FAILURES"
[ "$FAIL" -eq 0 ]
