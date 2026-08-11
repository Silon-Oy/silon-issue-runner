#!/usr/bin/env bash
# test-stop-run.sh — stop-run.sh, the operator surface for stopping one live run
# (issue #64). stop-run is a thin front-end over lib/run-terminate.sh (tested
# separately in test-run-terminate.sh); this test exercises the surface's own
# job: RESOLVING the target run and enforcing the five safety gates before it
# ever delegates.
#
# Cases (mirroring the issue's acceptance criteria):
#   1. --dry-run writes nothing (status, lock, tmux, comment all untouched)
#   2. terminal-status run without --force -> exit 5, run untouched
#   3. --issue matching two runs -> exit 3, nothing done
#   4. foreign host -> exit 4, no side effects
#   5. successful stop -> blocked/stopped_by_operator, worktree+run-dir intact,
#      situation comment carries NO awaiting-answer marker (scope-out: no auto
#      restart), needs-human label + comment attempted, own lock released
#   6. by-issue addressing resolves a single run
#   7. archived --run-dir -> exit 2
#   8. no match -> exit 2
#   9. usage errors -> exit 1 (no target; --run-dir combined with --issue)
#  10. confirmation prompt: a "no" answer aborts without side effects
#
# Fixtures live under a mktemp HOME + RUN_ISSUES_LOCK_ROOT, and `hostname` is
# mocked to a fixed value, so the real lock root and machine identity (which the
# poller uses on this same machine) are never touched.
#
# Run: bash tests/test-stop-run.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
STOP="$ROOT/stop-run.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

WORK=$(mktemp -d -t stop-run.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"
mkdir -p "$HOME"
export RUN_ISSUES_LOCK_ROOT="$WORK/locks"
mkdir -p "$RUN_ISSUES_LOCK_ROOT"

REPO="$WORK/repo"
mkdir -p "$REPO/.git"

# --- Mocks (hostname / tmux / gh) --------------------------------------------
mkdir -p "$WORK/bin"

# hostname: deterministic sandbox identity so the host gate is testable without
# depending on the real machine name.
cat > "$WORK/bin/hostname" <<'SH'
#!/usr/bin/env bash
echo "test-host"
SH
chmod +x "$WORK/bin/hostname"

# tmux: sessions "exist" as files in $WORK/tmux-sessions/. run_terminate targets
# them with `-t "=<name>"`; the mock strips the leading `=`.
mkdir -p "$WORK/tmux-sessions"
TMUX_LOG="$WORK/tmux-calls.log"
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

# gh: log calls; capture any --body-file so the test can inspect the comment.
GH_LOG="$WORK/gh-calls.log"
LAST_BODY="$WORK/last-comment-body.txt"
cat > "$WORK/bin/gh" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"
case "\$*" in
  *"--body-file"*)
    bf=\$(awk '{for(i=1;i<=NF;i++) if(\$i=="--body-file") print \$(i+1)}' <<< "\$*")
    [ -n "\$bf" ] && cp "\$bf" "$LAST_BODY" 2>/dev/null || true
    ;;
esac
exit 0
SH
chmod +x "$WORK/bin/gh"

export PATH="$WORK/bin:$PATH"

FAIL=0

# mk_run <rid> <issue> <host> <status> [<remote>] [<slug>] — writes a run.json
# (and empty state.jsonl) under $REPO/.claude/run-issues/<rid>. Also creates a
# worktree dir + branch marker so "left intact" is checkable. Prints the run-dir.
mk_run() {
  local rid="$1" issue="$2" host="$3" status="$4" remote="${5:-origin}" slug="${6:-repo-a}"
  local rd="$REPO/.claude/run-issues/$rid"
  local wt="$WORK/worktrees/$rid"
  mkdir -p "$rd" "$wt"
  : > "$rd/state.jsonl"
  jq -n \
    --arg run_id "$rid" \
    --arg repo "$REPO" \
    --argjson issue "$issue" \
    --arg host "$host" \
    --arg status "$status" \
    --arg remote "$remote" \
    --arg slug "$slug" \
    --arg wt "$wt" \
    '{
      run_id: $run_id,
      repo: $repo,
      issue_number: $issue,
      status: $status,
      host: $host,
      current_state: "S8_Implementer",
      remote: $remote,
      repo_slug: $slug,
      worktree_path: $wt,
      branch: ("auto-run/issue-" + ($issue|tostring)),
      finished_at: null,
      blocked_reason: null
    }' > "$rd/run.json"
  echo "$rd"
}

reset_logs() { : > "$TMUX_LOG"; : > "$GH_LOG"; rm -f "$LAST_BODY"; }

# ===========================================================================
# 1. --dry-run writes nothing.
# ===========================================================================
RD1=$(mk_run "20260601-1000-issue-100" 100 "test-host" "initialized")
touch "$WORK/tmux-sessions/run-issues-100"
mkdir -p "$RUN_ISSUES_LOCK_ROOT/repo-a-issue-100.lock"
reset_logs
"$STOP" --run-dir "$RD1" --dry-run >/dev/null 2>&1
RC=$?
[ "$RC" = "0" ] || { echo "FAIL dry-run: exit $RC (want 0)"; FAIL=1; }
[ "$(jq -r '.status' "$RD1/run.json")" = "initialized" ] \
  || { echo "FAIL dry-run: status mutated"; FAIL=1; }
[ -f "$WORK/tmux-sessions/run-issues-100" ] \
  || { echo "FAIL dry-run: tmux session killed"; FAIL=1; }
[ -d "$RUN_ISSUES_LOCK_ROOT/repo-a-issue-100.lock" ] \
  || { echo "FAIL dry-run: lock released"; FAIL=1; }
[ ! -f "$LAST_BODY" ] || { echo "FAIL dry-run: a comment was posted"; FAIL=1; }
[ -s "$GH_LOG" ] && { echo "FAIL dry-run: gh was called"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS dry-run: no side effects, exit 0"

# ===========================================================================
# 2. Terminal-status run without --force -> exit 5, untouched.
# ===========================================================================
RD2=$(mk_run "20260601-1001-issue-101" 101 "test-host" "completed")
touch "$WORK/tmux-sessions/run-issues-101"
mkdir -p "$RUN_ISSUES_LOCK_ROOT/repo-a-issue-101.lock"
reset_logs
"$STOP" --run-dir "$RD2" --yes >/dev/null 2>&1
RC=$?
[ "$RC" = "5" ] || { echo "FAIL terminal: exit $RC (want 5)"; FAIL=1; }
[ "$(jq -r '.status' "$RD2/run.json")" = "completed" ] \
  || { echo "FAIL terminal: status mutated"; FAIL=1; }
[ -f "$WORK/tmux-sessions/run-issues-101" ] \
  || { echo "FAIL terminal: tmux session killed"; FAIL=1; }
[ -d "$RUN_ISSUES_LOCK_ROOT/repo-a-issue-101.lock" ] \
  || { echo "FAIL terminal: lock released"; FAIL=1; }
[ ! -s "$GH_LOG" ] || { echo "FAIL terminal: gh was called"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS terminal status: exit 5, run untouched (no --force)"

# ...but --force lets a terminal run through (delegates + finalizes).
reset_logs
"$STOP" --run-dir "$RD2" --force --yes >/dev/null 2>&1
RC=$?
[ "$RC" = "0" ] || { echo "FAIL terminal-force: exit $RC (want 0)"; FAIL=1; }
[ "$(jq -r '.blocked_reason' "$RD2/run.json")" = "stopped_by_operator" ] \
  || { echo "FAIL terminal-force: not stopped"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS terminal status: --force stops it anyway"

# ===========================================================================
# 3. --issue matching two runs -> exit 3, nothing done.
# ===========================================================================
RDA=$(mk_run "20260601-1002a-issue-102" 102 "test-host" "initialized" "origin" "repo-a")
RDB=$(mk_run "20260601-1002b-issue-102" 102 "test-host" "initialized" "upstream" "repo-a")
reset_logs
"$STOP" --repo "$REPO" --issue 102 --yes >/dev/null 2>&1
RC=$?
[ "$RC" = "3" ] || { echo "FAIL multi: exit $RC (want 3)"; FAIL=1; }
[ "$(jq -r '.status' "$RDA/run.json")" = "initialized" ] \
  && [ "$(jq -r '.status' "$RDB/run.json")" = "initialized" ] \
  || { echo "FAIL multi: a run was mutated"; FAIL=1; }
[ ! -s "$GH_LOG" ] || { echo "FAIL multi: gh was called"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS multi-match: exit 3, nothing done"

# ...and --remote disambiguates the very same pair down to one run.
reset_logs
"$STOP" --repo "$REPO" --issue 102 --remote upstream --yes >/dev/null 2>&1
RC=$?
[ "$RC" = "0" ] || { echo "FAIL multi-remote: exit $RC (want 0)"; FAIL=1; }
[ "$(jq -r '.status' "$RDB/run.json")" = "blocked" ] \
  || { echo "FAIL multi-remote: upstream run not stopped"; FAIL=1; }
[ "$(jq -r '.status' "$RDA/run.json")" = "initialized" ] \
  || { echo "FAIL multi-remote: origin run wrongly stopped"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS multi-match: --remote narrows to a single run"

# ===========================================================================
# 4. Foreign host -> exit 4, no side effects.
# ===========================================================================
RD4=$(mk_run "20260601-1003-issue-103" 103 "other-host" "initialized")
touch "$WORK/tmux-sessions/run-issues-103"
mkdir -p "$RUN_ISSUES_LOCK_ROOT/repo-a-issue-103.lock"
reset_logs
"$STOP" --run-dir "$RD4" --yes >/dev/null 2>&1
RC=$?
[ "$RC" = "4" ] || { echo "FAIL foreign: exit $RC (want 4)"; FAIL=1; }
[ "$(jq -r '.status' "$RD4/run.json")" = "initialized" ] \
  || { echo "FAIL foreign: status mutated"; FAIL=1; }
[ -f "$WORK/tmux-sessions/run-issues-103" ] \
  || { echo "FAIL foreign: tmux session killed"; FAIL=1; }
[ -d "$RUN_ISSUES_LOCK_ROOT/repo-a-issue-103.lock" ] \
  || { echo "FAIL foreign: lock released"; FAIL=1; }
[ ! -s "$GH_LOG" ] || { echo "FAIL foreign: gh was called"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS foreign host: exit 4, no side effects"

# ===========================================================================
# 5. Successful stop: blocked/stopped_by_operator; worktree+run-dir intact;
#    comment carries NO awaiting-answer marker; label + comment attempted.
# ===========================================================================
RD5=$(mk_run "20260601-1004-issue-104" 104 "test-host" "initialized")
WT5="$WORK/worktrees/20260601-1004-issue-104"
# The live session name is repo-namespaced (session_suffix: slug-<n> on origin).
SESS5="run-issues-repo-a-104"
touch "$WORK/tmux-sessions/$SESS5"
mkdir -p "$RUN_ISSUES_LOCK_ROOT/repo-a-issue-104.lock"
reset_logs
"$STOP" --run-dir "$RD5" --yes >/dev/null 2>&1
RC=$?
[ "$RC" = "0" ] || { echo "FAIL stop: exit $RC (want 0)"; FAIL=1; }
[ "$(jq -r '.status' "$RD5/run.json")" = "blocked" ] \
  || { echo "FAIL stop: status not blocked"; FAIL=1; }
[ "$(jq -r '.blocked_reason' "$RD5/run.json")" = "stopped_by_operator" ] \
  || { echo "FAIL stop: blocked_reason wrong"; FAIL=1; }
grep -q '"event":"stopped_finalized"' "$RD5/state.jsonl" \
  || { echo "FAIL stop: no stopped_finalized event"; FAIL=1; }
[ ! -f "$WORK/tmux-sessions/$SESS5" ] \
  || { echo "FAIL stop: tmux session not killed"; FAIL=1; }
[ ! -d "$RUN_ISSUES_LOCK_ROOT/repo-a-issue-104.lock" ] \
  || { echo "FAIL stop: own lock not released"; FAIL=1; }
# Constraint 5: worktree + run-dir survive (stop is NOT cleanup).
[ -d "$WT5" ] || { echo "FAIL stop: worktree removed (must stay intact)"; FAIL=1; }
[ -d "$RD5" ] || { echo "FAIL stop: run-dir removed (must stay intact)"; FAIL=1; }
# Label + comment attempted.
grep -qF "labels[]=needs-human" "$GH_LOG" \
  || { echo "FAIL stop: needs-human label not attempted"; FAIL=1; }
grep -q "issue comment" "$GH_LOG" \
  || { echo "FAIL stop: situation comment not posted"; FAIL=1; }
# Scope-out: the stopped comment must NOT carry an awaiting-answer marker,
# else a human reply would auto-retry via scan_blocked_answered.
[ -f "$LAST_BODY" ] || { echo "FAIL stop: no comment body captured"; FAIL=1; }
if [ -f "$LAST_BODY" ]; then
  grep -q "awaiting-answer" "$LAST_BODY" \
    && { echo "FAIL stop: comment carries an awaiting-answer marker (no auto-retry allowed)"; FAIL=1; }
  grep -q "pysäytetty" "$LAST_BODY" \
    || { echo "FAIL stop: comment lacks the stopped wording"; FAIL=1; }
fi
[ "$FAIL" = "0" ] && echo "PASS successful stop: blocked/stopped_by_operator, intact, no marker"

# ===========================================================================
# 6. By-issue addressing resolves a single run.
# ===========================================================================
RD6=$(mk_run "20260601-1005-issue-105" 105 "test-host" "initialized")
reset_logs
"$STOP" --repo "$REPO" --issue 105 --yes >/dev/null 2>&1
RC=$?
[ "$RC" = "0" ] || { echo "FAIL by-issue: exit $RC (want 0)"; FAIL=1; }
[ "$(jq -r '.blocked_reason' "$RD6/run.json")" = "stopped_by_operator" ] \
  || { echo "FAIL by-issue: not stopped"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS by-issue addressing: single run resolved and stopped"

# ===========================================================================
# 7. Archived --run-dir -> exit 2.
# ===========================================================================
ARCH="$REPO/.claude/run-issues-archive/20260601-0900-issue-106"
mkdir -p "$ARCH"
echo '{"issue_number":106,"host":"test-host","status":"completed"}' > "$ARCH/run.json"
reset_logs
"$STOP" --run-dir "$ARCH" --yes >/dev/null 2>&1
RC=$?
[ "$RC" = "2" ] || { echo "FAIL archive: exit $RC (want 2)"; FAIL=1; }
[ ! -s "$GH_LOG" ] || { echo "FAIL archive: gh was called"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS archived run-dir: exit 2"

# ===========================================================================
# 8. No match -> exit 2.
# ===========================================================================
reset_logs
"$STOP" --repo "$REPO" --issue 999999 --yes >/dev/null 2>&1
RC=$?
[ "$RC" = "2" ] || { echo "FAIL nomatch: exit $RC (want 2)"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS no match: exit 2"

# ===========================================================================
# 9. Usage errors -> exit 1.
# ===========================================================================
"$STOP" --yes >/dev/null 2>&1
[ "$?" = "1" ] || { echo "FAIL usage: no target did not exit 1"; FAIL=1; }
"$STOP" --run-dir "$RD6" --issue 105 >/dev/null 2>&1
[ "$?" = "1" ] || { echo "FAIL usage: --run-dir + --issue did not exit 1"; FAIL=1; }
"$STOP" --repo "$REPO" >/dev/null 2>&1
[ "$?" = "1" ] || { echo "FAIL usage: --repo without --issue did not exit 1"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS usage errors: exit 1"

# ===========================================================================
# 10. Confirmation prompt: a "no" answer aborts without side effects.
# ===========================================================================
RD10=$(mk_run "20260601-1006-issue-107" 107 "test-host" "initialized")
touch "$WORK/tmux-sessions/run-issues-107"
reset_logs
printf 'n\n' | "$STOP" --run-dir "$RD10" >/dev/null 2>&1
RC=$?
[ "$RC" = "0" ] || { echo "FAIL confirm: exit $RC (want 0 on abort)"; FAIL=1; }
[ "$(jq -r '.status' "$RD10/run.json")" = "initialized" ] \
  || { echo "FAIL confirm: run mutated despite 'no'"; FAIL=1; }
[ -f "$WORK/tmux-sessions/run-issues-107" ] \
  || { echo "FAIL confirm: tmux killed despite 'no'"; FAIL=1; }
[ ! -s "$GH_LOG" ] || { echo "FAIL confirm: gh called despite 'no'"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS confirmation: 'no' aborts, no side effects"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "stop-run: all passed" || echo "stop-run: FAILURES"
[ "$FAIL" -eq 0 ]
