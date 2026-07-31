#!/usr/bin/env bash
# test-poller-stale-detection.sh — poller liveness/stale detection (issue #49).
#
# Two functions to validate:
#   scan_stalled    — selection: only initialized runs on THIS host whose
#                     last state.jsonl event ts is older than the threshold.
#                     awaiting_review and awaiting_clarification are NEVER
#                     stalled (they wait for human action by contract).
#   finalize_stalled — termination: kill tmux session, finalize blocked +
#                     stalled_in_<state>, attach needs-human, post comment.
#
# poller.sh has a Studio-only host gate that `exit 0`s at source time on any
# other machine, so we extract the function definitions and source them into
# a controlled harness (same approach as test-poller-scan-timeout.sh).
#
# Run: bash tests/test-poller-stale-detection.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLLER="$HERE/../poller.sh"
STATE_LIB="$HERE/../lib/state.sh"
GIT_REMOTE_LIB="$HERE/../lib/git-remote.sh"

WORK=$(mktemp -d -t poller-stale.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
mkdir -p "$REPO/.git"

# shellcheck source=lib/state.sh
. "$STATE_LIB"
# Multi-remote (issue #53): finalize_stalled reads remote from run.json and
# calls session_suffix + remote_label to derive tmux session names and lock
# paths. Source git-remote.sh so the helper is in scope when we eval the
# function body below.
# shellcheck source=lib/git-remote.sh
. "$GIT_REMOTE_LIB"

# finalize_stalled attaches the needs-human label through lib/labels.sh. We
# extract function bodies rather than sourcing poller.sh, so its own source
# block never runs — pull the lib in here or the label calls are undefined.
# shellcheck source=lib/labels.sh
. "$HERE/../lib/labels.sh"

# Extract function bodies from poller.sh. The awk pattern walks from each
# function header to its closing brace at column 0, mirroring the harness
# used by test-poller-scan-timeout.sh. We need scan_stalled, finalize_stalled,
# and the _iso_to_epoch helper they both rely on.
extract_fn() {
  awk -v fname="$1" '
    $0 ~ "^"fname"\\(\\) \\{" { p=1 }
    p { print }
    p && /^\}/ { exit }
  ' "$POLLER"
}

eval "$(extract_fn _iso_to_epoch)"
eval "$(extract_fn scan_stalled)"
eval "$(extract_fn finalize_stalled)"

# Pin globals the functions read. Shellcheck cannot see into the eval'd code,
# hence the disable comments.
# shellcheck disable=SC2034
THIS_HOST="test-host"
# shellcheck disable=SC2034
RUN_ISSUES_STALE_AFTER=1800   # 30 min for the test
LOG="$WORK/poller.log"        # finalize_stalled appends here
# shellcheck disable=SC2034
RUN_ISSUES_LOCK_ROOT="$WORK/locks"

# Mock tmux: track sessions and kill-calls. has-session returns 0 only for
# names previously "created" via touching a file in $WORK/tmux-sessions/.
#
# poller.sh addresses sessions with an EXACT target: `-t "=<name>"` (the leading
# `=` is tmux syntax for "the session literally named <name>", added in d137b20
# to stop `run-issues-3` from prefix-matching `run-issues-34`). The mock must
# model that syntax, so it strips a leading `=` before the filesystem lookup —
# otherwise it searches for a file named `=run-issues-100`, never matches, and
# kill-session is never issued.
mkdir -p "$WORK/tmux-sessions"
TMUX_LOG="$WORK/tmux-calls.log"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$TMUX_LOG"
case "\$1" in
  has-session)
    shift; while [ "\$1" != "-t" ] && [ \$# -gt 0 ]; do shift; done
    name="\${2#=}"   # strip tmux's exact-match '=' prefix
    [ -f "$WORK/tmux-sessions/\$name" ]
    ;;
  kill-session)
    shift; while [ "\$1" != "-t" ] && [ \$# -gt 0 ]; do shift; done
    name="\${2#=}"   # strip tmux's exact-match '=' prefix
    rm -f "$WORK/tmux-sessions/\$name"
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$WORK/bin/tmux"
PATH="$WORK/bin:$PATH"

# Mock gh: just log calls. finalize_stalled is best-effort on gh, so it must
# tolerate failures, but for test assertions we want to see what was called.
GH_LOG="$WORK/gh-calls.log"
cat > "$WORK/bin/gh" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"
# Drain piped body so the writer never gets SIGPIPE.
case "\$*" in
  *"--body-file"*) cat "\$(awk '{for(i=1;i<=NF;i++) if(\$i=="--body-file") print \$(i+1)}' <<< "\$*")" >/dev/null 2>&1 || true ;;
esac
exit 0
SH
chmod +x "$WORK/bin/gh"

# Helper: create a run-dir with a given status, host, and a last-event ts at
# `now - age_seconds`. The state.jsonl gets a single fake event with the
# back-dated ts so the staleness check sees it. issue-number is parsed from rid.
mk_run() {  # <rid> <status> <host> <age-seconds> [current_state]
  local rid="$1" status="$2" host="$3" age="$4" cstate="${5:-S7b_EnvBootstrap}"
  local rd="$REPO/.claude/run-issues/$rid"
  local inum="${rid##*-}"
  state_init "$rd" "$rid" "$REPO" "$inum"
  # Patch host + current_state.
  local tmp; tmp=$(mktemp)
  jq --arg h "$host" --arg cs "$cstate" \
    '.host = $h | .current_state = $cs' \
    "$rd/run.json" > "$tmp"; mv "$tmp" "$rd/run.json"
  state_finalize "$rd" "$status"   # writes status + finished_at; clears nothing
  # Back-date the state.jsonl with a synthetic event at the target age.
  local backdated
  backdated=$(date -u -j -f "%s" "$(( $(date -u +%s) - age ))" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -d "@$(( $(date -u +%s) - age ))" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
  printf '{"event":"fake","ts":"%s","data":{}}\n' "$backdated" > "$rd/state.jsonl"
  echo "$rd"
}

FAIL=0

# ===========================================================================
# scan_stalled: selection matrix
# ===========================================================================
#
# Eligible (initialized + this host + state.jsonl older than threshold):
RD_STALE=$(mk_run "20260528-1000-issue-100" "initialized" "test-host" 7200 "S7b_EnvBootstrap")
# Not eligible: recent (within budget).
mk_run "20260528-1001-issue-101" "initialized" "test-host" 60 "S8_Implementer" >/dev/null
# Not eligible: foreign host.
mk_run "20260528-1002-issue-102" "initialized" "other-host" 7200 "S7b_EnvBootstrap" >/dev/null
# Not eligible: terminal status (already finalized).
mk_run "20260528-1003-issue-103" "completed" "test-host" 7200 "S12_Finalize" >/dev/null
mk_run "20260528-1004-issue-104" "blocked" "test-host" 7200 "S7b_EnvBootstrap" >/dev/null
# Not eligible: awaiting human action (documented contract, not stalled).
mk_run "20260528-1005-issue-105" "awaiting_review" "test-host" 7200 "S7_ReviewGate" >/dev/null
mk_run "20260528-1006-issue-106" "awaiting_clarification" "test-host" 7200 "S_AwaitingClarification" >/dev/null
# Eligible: empty host treated as local (back-compat with pre-host-field runs).
RD_EMPTY=$(mk_run "20260528-1007-issue-107" "initialized" "" 7200 "S6_CycleReview")

OUT=$(scan_stalled "$REPO" | sort)
echo "--- scan_stalled output ---"; echo "$OUT"

echo "$OUT" | grep -q "^100 " \
  || { echo "FAIL: issue 100 (stale + local + initialized) not selected"; FAIL=1; }
echo "$OUT" | grep -q "^107 " \
  || { echo "FAIL: issue 107 (empty host treated as local) not selected"; FAIL=1; }
echo "$OUT" | grep -q "^101 " \
  && { echo "FAIL: issue 101 (recent) WAS selected"; FAIL=1; }
echo "$OUT" | grep -q "^102 " \
  && { echo "FAIL: issue 102 (foreign host) WAS selected"; FAIL=1; }
echo "$OUT" | grep -q "^103 " \
  && { echo "FAIL: issue 103 (completed) WAS selected"; FAIL=1; }
echo "$OUT" | grep -q "^104 " \
  && { echo "FAIL: issue 104 (blocked) WAS selected"; FAIL=1; }
echo "$OUT" | grep -q "^105 " \
  && { echo "FAIL: issue 105 (awaiting_review) WAS selected — must NOT be killed under human"; FAIL=1; }
echo "$OUT" | grep -q "^106 " \
  && { echo "FAIL: issue 106 (awaiting_clarification) WAS selected — must NOT be killed under human"; FAIL=1; }
COUNT=$(printf '%s\n' "$OUT" | grep -c '^[0-9]')
[ "$COUNT" = "2" ] \
  || { echo "FAIL: expected exactly 2 stalled candidates, got $COUNT"; FAIL=1; }

[ "$FAIL" = "0" ] && echo "PASS scan_stalled selection: stale + initialized + local only; awaiting_* protected"

# ===========================================================================
# finalize_stalled: kill tmux + finalize blocked + label + comment
# ===========================================================================
#
# Pretend the stalled run has a live tmux session.
touch "$WORK/tmux-sessions/run-issues-100"
# And a stale advisory lock that the dead orchestrator should have released.
mkdir -p "$RUN_ISSUES_LOCK_ROOT/issue-100.lock"
echo "12345" > "$RUN_ISSUES_LOCK_ROOT/issue-100.lock/pid"

: > "$GH_LOG"
: > "$TMUX_LOG"
finalize_stalled 100 "$RD_STALE"

# 1. tmux session killed.
grep -q "kill-session.*run-issues-100" "$TMUX_LOG" \
  || { echo "FAIL finalize: tmux kill-session for run-issues-100 not called"; FAIL=1; }
[ ! -f "$WORK/tmux-sessions/run-issues-100" ] \
  || { echo "FAIL finalize: tmux session still 'alive' after kill"; FAIL=1; }

# 2. run.json finalized.
ST=$(jq -r '.status' "$RD_STALE/run.json")
RE=$(jq -r '.blocked_reason' "$RD_STALE/run.json")
[ "$ST" = "blocked" ] || { echo "FAIL finalize: status='$ST' (want blocked)"; FAIL=1; }
[ "$RE" = "stalled_in_S7b_EnvBootstrap" ] \
  || { echo "FAIL finalize: blocked_reason='$RE' (want stalled_in_S7b_EnvBootstrap)"; FAIL=1; }

# 3. state.jsonl event recorded.
grep -q '"event":"stalled_finalized"' "$RD_STALE/state.jsonl" \
  || { echo "FAIL finalize: no stalled_finalized event"; FAIL=1; }

# 4. needs-human label added; comment posted.
grep -qF "labels[]=needs-human" "$GH_LOG" \
  || { echo "FAIL finalize: needs-human label not attempted"; FAIL=1; }
grep -q "issue comment" "$GH_LOG" \
  || { echo "FAIL finalize: situation comment not posted"; FAIL=1; }

# 5. Advisory lock released.
[ ! -d "$RUN_ISSUES_LOCK_ROOT/issue-100.lock" ] \
  || { echo "FAIL finalize: advisory lock not released"; FAIL=1; }

# 6. Poller log line written.
grep -q "STALLED issue=#100" "$LOG" \
  || { echo "FAIL finalize: no poller log line for STALLED issue=#100"; FAIL=1; }

[ "$FAIL" = "0" ] && echo "PASS finalize_stalled: kill + blocked/stalled_in_* + label + comment + lock release"

# ===========================================================================
# finalize_stalled: host-mismatch defense in depth
# ===========================================================================
#
# Directly call finalize_stalled on a foreign-host run-dir. scan_stalled
# already filters this out, but finalize_stalled has its own gate as defense
# in depth. The expected outcome: no state mutation, no tmux kill, log line.
RD_FOREIGN=$(mk_run "20260528-1010-issue-110" "initialized" "other-host" 7200 "S7b_EnvBootstrap")
touch "$WORK/tmux-sessions/run-issues-110"   # pretend it has a session

: > "$TMUX_LOG"
finalize_stalled 110 "$RD_FOREIGN"
ST_F=$(jq -r '.status' "$RD_FOREIGN/run.json")
[ "$ST_F" = "initialized" ] \
  || { echo "FAIL host-gate: foreign run status mutated to '$ST_F' (expected initialized)"; FAIL=1; }
[ -f "$WORK/tmux-sessions/run-issues-110" ] \
  || { echo "FAIL host-gate: foreign tmux session was killed"; FAIL=1; }
grep -q "refusing foreign host" "$LOG" \
  || { echo "FAIL host-gate: no refusal log line"; FAIL=1; }

[ "$FAIL" = "0" ] && echo "PASS finalize_stalled host-gate: foreign run untouched"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "poller-stale-detection: all passed" || echo "poller-stale-detection: FAILURES"
[ "$FAIL" -eq 0 ]
