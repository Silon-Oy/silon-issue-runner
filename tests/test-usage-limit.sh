#!/usr/bin/env bash
# test-usage-limit.sh — Claude usage-limit detection, finalization and resume
# (issue #294).
#
# Covers:
#   (a) detection: the CLI's limit phrasings match, ordinary errors and an
#       answer that merely TALKS about usage limits do not; a result line in the
#       output vetoes a match.
#   (b) reset parsing: epoch form, wall-clock form with a zone, fallback to
#       RUN_ISSUES_USAGE_LIMIT_BACKOFF when nothing parses; kill switch.
#   (c) machine-wide state file: later deadline wins, expiry, corrupt file,
#       status JSON.
#   (d) call_claude: a limit message returns CLAUDE_USAGE_LIMIT_RC, records the
#       reset in run.json and trips the machine gate.
#   (e) orchestrator S8: limit -> usage_limited + exit 13, no needs-human.
#   (f) output without a result line does not kill the orchestrator silently
#       (implementer and cycle review).
#   (g) --restart of a usage_limited run: resumes in the interrupted phase
#       (S6 re-runs the cycle review, S9 skips the implementer) without
#       spending the retry budget.
#   (h) poller scan_usage_limited: restart only after the reset has passed.
#
# Everything external is a PATH shim (claude, gh). No network.
#
# Run: bash tests/test-usage-limit.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
ORCH="$ROOT/orchestrate.sh"
POLLER="$ROOT/poller.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed"
  exit 0
fi

WORK=$(mktemp -d -t usage-limit.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAIL=1; }
check() { # <name> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — got '$2', want '$3'"; fi
}

# Keep every state file inside the sandbox: call_claude writes the machine-wide
# gate file under RUN_ISSUES_LOG_DIR.
export RUN_ISSUES_LOG_DIR="$WORK/logs"
mkdir -p "$RUN_ISSUES_LOG_DIR"
GATE="$RUN_ISSUES_LOG_DIR/.claude-usage-limit"

# The library under test, sourced in a subshell-free way for the unit cases.
# shellcheck source=lib/state.sh
. "$ROOT/lib/state.sh"
# shellcheck source=lib/claude-call.sh
. "$ROOT/lib/claude-call.sh"
set +e  # claude-call.sh sets -e; this harness collects failures instead

NOW=1790000000

# === (a) detection ===========================================================
for msg in \
  "Claude AI usage limit reached|1790003600" \
  "You've hit your limit · resets 3pm (Europe/Helsinki)" \
  "You've hit your session limit · resets 11:30pm" \
  "5-hour limit reached ∙ resets 2am" ; do
  claude_usage_limit_matches "$msg" && ok "matches: ${msg:0:40}" || bad "did not match: $msg"
done
for msg in \
  "Error: HTTP 500 Internal Server Error" \
  "The implementer discussed the usage limit feature at length" \
  "API rate limit exceeded" ; do
  claude_usage_limit_matches "$msg" && bad "false positive: $msg" || ok "no match: ${msg:0:40}"
done

F="$WORK/out-a"
printf 'Long answer about usage limit reached handling\nIMPLEMENTER_RESULT: SUCCESS\n' > "$F"
claude_usage_limit_check "$F" "$NOW" >/dev/null && bad "result line did not veto a match" || ok "result line vetoes a match"
claude_usage_limit_check "$WORK/missing" "$NOW" >/dev/null && bad "missing file matched" || ok "missing file does not match"
printf 'You have hit your limit\nline\nline\nline\nline\nline\n' > "$F"
claude_usage_limit_check "$F" "$NOW" >/dev/null && bad "match outside the tail counted" || ok "only the tail of the output is read"

# === (b) reset parsing =======================================================
check "epoch form" "$(claude_usage_limit_reset_epoch "Claude AI usage limit reached|$((NOW + 3600))" "$NOW")" "$((NOW + 3600))"
check "epoch in the past is discarded" "$(claude_usage_limit_reset_epoch "Claude AI usage limit reached|$((NOW - 10))" "$NOW")" ""
# 2026-09-15 12:00 UTC; 3pm UTC that day is 3 h later, 9am UTC is tomorrow.
NOON=1789473600
check "clock form with zone" "$(claude_usage_limit_reset_epoch "You've hit your limit · resets 3pm (UTC)" "$NOON")" "$((NOON + 3 * 3600))"
check "clock already passed -> tomorrow" "$(claude_usage_limit_reset_epoch "You've hit your limit · resets 9am (UTC)" "$NOON")" "$((NOON + 21 * 3600))"
check "24h clock with minutes" "$(claude_usage_limit_reset_epoch "limit reached · resets 13:30 (UTC)" "$NOON")" "$((NOON + 5400))"
check "no reset time" "$(claude_usage_limit_reset_epoch "You've hit your limit" "$NOW")" ""

printf "Claude AI usage limit reached|%s\n" "$((NOW + 600))" > "$F"
check "check: parsed reset + 60 s margin" "$(claude_usage_limit_check "$F" "$NOW")" "$((NOW + 660)) reset"
printf "You've hit your limit\n" > "$F"
check "check: fallback backoff default" "$(claude_usage_limit_check "$F" "$NOW")" "$((NOW + 3600)) backoff"
check "check: fallback backoff override" "$(RUN_ISSUES_USAGE_LIMIT_BACKOFF=120 claude_usage_limit_check "$F" "$NOW")" "$((NOW + 120)) backoff"
check "check: bad backoff override degrades to default" "$(RUN_ISSUES_USAGE_LIMIT_BACKOFF=abc claude_usage_limit_check "$F" "$NOW")" "$((NOW + 3600)) backoff"
RUN_ISSUES_USAGE_LIMIT_DETECTION=0 claude_usage_limit_check "$F" "$NOW" >/dev/null \
  && bad "kill switch did not disable detection" || ok "kill switch disables detection"

# === (c) state file ==========================================================
SF="$WORK/gate"
usage_limit_active "$SF" "$NOW" && bad "missing file gates" || ok "missing file does not gate"
echo "garbage here" > "$SF"
usage_limit_active "$SF" "$NOW" && bad "corrupt file gates" || ok "corrupt file does not gate"
rm -f "$SF"
usage_limit_trip "$SF" "$((NOW + 500))" reset
usage_limit_trip "$SF" "$((NOW + 100))" backoff
check "later deadline wins" "$(head -n1 "$SF")" "$((NOW + 500)) reset"
usage_limit_trip "$SF" "$((NOW + 900))" backoff
check "a later deadline replaces an earlier one" "$(head -n1 "$SF")" "$((NOW + 900)) backoff"
usage_limit_active "$SF" "$((NOW + 899))" && ok "future deadline gates" || bad "future deadline did not gate"
usage_limit_active "$SF" "$((NOW + 900))" && bad "expired deadline gates" || ok "expired deadline does not gate"
check "status json active" "$(usage_limit_status_json "$SF" "$((NOW + 800))")" '{"usage_limited_until":1790000900,"usage_limit_wait_seconds":100}'
check "status json expired" "$(usage_limit_status_json "$SF" "$((NOW + 901))")" '{"usage_limited_until":null,"usage_limit_wait_seconds":null}'
RUN_ISSUES_USAGE_LIMIT_DETECTION=0 usage_limit_active "$SF" "$NOW" \
  && bad "kill switch did not disable the gate" || ok "kill switch disables the gate"

# === (d) call_claude =========================================================
BIN="$WORK/bin"
mkdir -p "$BIN"
CALLS="$WORK/claude-calls.log"
# Step-aware claude mock: the step is recognised from the rendered prompt's
# result marker, and the response comes from $WORK/resp-<step> (default: a
# blocked implementer, so a run stops right after S8).
cat > "$BIN/claude" <<SH
#!/usr/bin/env bash
prompt="\${*: -1}"
step=other
# Most specific first: each later prompt embeds the earlier step's output.
case "\$prompt" in
  *EVOLUTION_RESULT*)      step=evolution ;;
  *IMPLEMENTER_RESULT*)    step=implementer ;;
  *CYCLE_REVIEW_DECISION*) step=cycle ;;
esac
echo "\$step" >> "$CALLS"
f="$WORK/resp-\$step"
if [ -f "\$f" ]; then
  cat "\$f"
  exit "\$(cat "\$f.rc" 2>/dev/null || echo 0)"
fi
echo "IMPLEMENTER_RESULT: BLOCKED — default mock response"
SH
chmod +x "$BIN/claude"

limit_resp() { # <step> — make <step> answer with a usage-limit message, rc 1
  printf 'Claude AI usage limit reached|%s\n' "$(( $(date +%s) + 7200 ))" > "$WORK/resp-$1"
  echo 1 > "$WORK/resp-$1.rc"
}
clear_resp() { rm -f "$WORK"/resp-*; }

RD0="$WORK/rd0"
state_init "$RD0" "rid0" "$WORK" "1"
echo "prompt" > "$WORK/prompt"
limit_resp other
rm -f "$GATE"
rc=0
( RUN_ISSUES_CLAUDE_CMD="$BIN/claude" call_claude "$RD0" "99-step" "$WORK/prompt" ) || rc=$?
check "call_claude returns CLAUDE_USAGE_LIMIT_RC" "$rc" "75"
check ".exit keeps the process rc" "$(cat "$RD0/99-step.exit")" "1"
[ -n "$(jq -r '.usage_limit_reset_at // empty' "$RD0/run.json")" ] && ok "reset recorded in run.json" || bad "no usage_limit_reset_at in run.json"
grep -q '"event":"usage_limit_hit"' "$RD0/state.jsonl" && ok "usage_limit_hit event" || bad "no usage_limit_hit event"
[ -s "$GATE" ] && ok "machine gate tripped" || bad "machine gate file not written"
clear_resp
rc=0
( RUN_ISSUES_CLAUDE_CMD="$BIN/claude" call_claude "$RD0" "98-step" "$WORK/prompt" ) || rc=$?
check "normal output keeps rc 0" "$rc" "0"

# === orchestrator harness ====================================================
REPO="$WORK/repo"
git -C "$WORK" init -q repo
GH_LOG="$WORK/gh-calls.log"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"
exit 0
SH
chmod +x "$BIN/gh"

make_worktree() {
  local wt="$1"
  git -C "$WORK" init -q "$(basename "$wt")"
  ( cd "$wt"
    git config user.email t@t; git config user.name t
    git commit -q --allow-empty -m base
    git update-ref refs/remotes/origin/main HEAD
  )
}

# mk_run <rid> <status> [<reason>] — a run dir with a usable worktree.
mk_run() {
  local rid="$1" status="$2" reason="${3:-}"
  local rd="$REPO/.claude/run-issues/$rid" wt="$WORK/wt-$rid"
  make_worktree "$wt"
  state_init "$rd" "$rid" "$REPO" "${rid##*-}"
  state_set "$rd" branch "auto-run/issue-${rid##*-}-x"
  state_set "$rd" worktree_path "$wt"
  state_set "$rd" cycle_review_decision PROCEED
  echo '{"title":"t","body":"b","comments":[]}' > "$rd/issue.json"
  echo "CYCLE_REVIEW_DECISION: PROCEED" > "$rd/01-cycle-review.out"
  [ "$status" = "initialized" ] || state_finalize "$rd" "$status" "$reason"
  printf '%s' "$rd"
}

run_orch() {
  ( cd "$REPO" && \
    PATH="$BIN:$PATH" \
    RUN_ISSUES_AUTO=1 RUN_ISSUES_REVIEW_GATE=auto \
    RUN_ISSUES_CLAUDE_CMD="$BIN/claude" \
    RUN_ISSUES_LOCK_ROOT="$WORK/locks" \
    RUN_ISSUES_LOG_DIR="$RUN_ISSUES_LOG_DIR" \
    "$@" )
}

# === (e) S8 limit -> usage_limited ===========================================
RD=$(mk_run "20261002-0001-issue-71" initialized)
clear_resp; limit_resp implementer; : > "$GH_LOG"; rm -f "$GATE"
OUT=$(run_orch "$ORCH" --resume "$RD" --decision PROCEED 2>&1); RC=$?
check "(e) exit 13" "$RC" "13"
check "(e) status usage_limited" "$(jq -r .status "$RD/run.json")" "usage_limited"
check "(e) reason usage_limit" "$(jq -r .blocked_reason "$RD/run.json")" "usage_limit"
check "(e) phase recorded" "$(jq -r .usage_limit_phase "$RD/run.json")" "S8_Implementer"
grep -q 'needs-human' "$GH_LOG" && bad "(e) needs-human label attempted" || ok "(e) no needs-human label"
grep -q 'comment' "$GH_LOG" && bad "(e) situation comment posted" || ok "(e) no situation comment"
[ -s "$GATE" ] && ok "(e) machine gate tripped" || bad "(e) machine gate not tripped"
[ "$RC" = "13" ] || echo "$OUT" | tail -8

# === (f) no result line does not kill the orchestrator =======================
RD=$(mk_run "20261002-0002-issue-72" initialized)
clear_resp; printf 'some chatter, no result line\n' > "$WORK/resp-implementer"
OUT=$(run_orch "$ORCH" --resume "$RD" --decision PROCEED 2>&1); RC=$?
check "(f) implementer without result line -> exit 5" "$RC" "5"
check "(f) implementer finalized blocked" "$(jq -r .blocked_reason "$RD/run.json")" "implementer_no_result"

# === (g) restart a usage_limited run =========================================
# S8: resumes the implementer, keeps retry_count, no budget hand-off.
RD=$(mk_run "20261002-0003-issue-73" usage_limited usage_limit)
state_set "$RD" usage_limit_phase S8_Implementer
state_set "$RD" usage_limit_reset_at "$(( $(date +%s) - 10 ))"
clear_resp; : > "$CALLS"; : > "$GH_LOG"
OUT=$(run_orch env RUN_ISSUES_MAX_RETRIES=0 "$ORCH" --restart "$RD" 2>&1); RC=$?
check "(g/S8) budget not checked: implementer ran (exit 5 from mock BLOCKED)" "$RC" "5"
check "(g/S8) retry_count unchanged" "$(jq -r .retry_count "$RD/run.json")" "0"
check "(g/S8) implementer called" "$(tr '\n' ' ' < "$CALLS")" "implementer "
grep -q '"event":"usage_limit_resume"' "$RD/state.jsonl" && ok "(g/S8) usage_limit_resume event" || bad "(g/S8) no usage_limit_resume event"

# S6: a limit in the cycle review left no decision, so the restart re-runs it.
# The re-run's output has NO decision line -> review gate blocks (exit 4), it
# does not die silently in run_cycle_review.
RD=$(mk_run "20261002-0004-issue-74" usage_limited usage_limit)
state_set "$RD" usage_limit_phase S6_CycleReview
clear_resp; : > "$CALLS"
printf 'cycle review chatter without a decision\n' > "$WORK/resp-cycle"
OUT=$(run_orch "$ORCH" --restart "$RD" 2>&1); RC=$?
check "(g/S6) cycle review re-run, missing decision -> blocked exit 4" "$RC" "4"
check "(g/S6) blocked reason" "$(jq -r .blocked_reason "$RD/run.json")" "cycle_review_empty"
check "(g/S6) only the cycle review was called" "$(tr '\n' ' ' < "$CALLS")" "cycle "
grep -q '"event":"cycle_review_done"' "$RD/state.jsonl" && ok "(g/S6) cycle_review_done recorded" || bad "(g/S6) run died before cycle_review_done"

# S6 again, now the re-run hits the limit itself -> usage_limited, phase S6.
RD=$(mk_run "20261002-0005-issue-75" usage_limited usage_limit)
state_set "$RD" usage_limit_phase S6_CycleReview
clear_resp; limit_resp cycle
OUT=$(run_orch "$ORCH" --restart "$RD" 2>&1); RC=$?
check "(g/S6 limit) exit 13" "$RC" "13"
check "(g/S6 limit) phase S6" "$(jq -r .usage_limit_phase "$RD/run.json")" "S6_CycleReview"

# S9: the implementer finished; the restart must NOT re-run it.
RD=$(mk_run "20261002-0006-issue-76" usage_limited usage_limit)
state_set "$RD" usage_limit_phase S9_Evolution
echo "IMPLEMENTER_RESULT: SUCCESS" > "$RD/02-implementer.out"
clear_resp; : > "$CALLS"
echo "EVOLUTION_RESULT: NO_CHANGES" > "$WORK/resp-evolution"
OUT=$(run_orch "$ORCH" --restart "$RD" 2>&1); RC=$?
check "(g/S9) only evolution was called" "$(tr '\n' ' ' < "$CALLS")" "evolution "
check "(g/S9) implementer output untouched" "$(cat "$RD/02-implementer.out")" "IMPLEMENTER_RESULT: SUCCESS"
# No remote to push to -> S10 fails with exit 6; reaching it is the point.
check "(g/S9) reached S10 push" "$RC" "6"

# A timed_out restart still spends its budget (regression guard).
RD=$(mk_run "20261002-0007-issue-77" timed_out implementer_timeout)
clear_resp
OUT=$(run_orch env RUN_ISSUES_MAX_RETRIES=1 "$ORCH" --restart "$RD" 2>&1); RC=$?
check "timed_out restart increments retry_count" "$(jq -r .retry_count "$RD/run.json")" "1"

# === (h) poller scan_usage_limited ===========================================
FN=$(awk '/^scan_usage_limited\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$POLLER")
[ -n "$FN" ] || bad "scan_usage_limited not found in poller.sh"
eval "$FN"
# shellcheck disable=SC2034  # read by the eval'd function
THIS_HOST="test-host"
PREPO="$WORK/prepo"
mkdir -p "$PREPO/.git"
mk_limited() { # <rid> <host> <reset>
  local rd="$PREPO/.claude/run-issues/$1"
  state_init "$rd" "$1" "$PREPO" "${1##*-}"
  local tmp; tmp=$(mktemp)
  jq --arg h "$2" '.host = $h' "$rd/run.json" > "$tmp"; mv "$tmp" "$rd/run.json"
  [ -n "$3" ] && state_set "$rd" usage_limit_reset_at "$3"
  state_finalize "$rd" usage_limited usage_limit
}
mk_limited "r-issue-81" test-host "$((NOW - 1))"    # reset passed
mk_limited "r-issue-82" test-host "$((NOW + 600))"  # still limited
mk_limited "r-issue-83" other-host "$((NOW - 1))"   # foreign host
mk_limited "r-issue-84" test-host ""                # no reset recorded
GOT=$(scan_usage_limited "$PREPO" "" "$NOW" | awk '{print $1}' | sort | tr '\n' ' ')
check "(h) only past-reset local runs are restarted" "$GOT" "81 84 "
GOT=$(scan_usage_limited "$PREPO" "" "$((NOW + 601))" | awk '{print $1}' | sort | tr '\n' ' ')
check "(h) the limited run becomes eligible after its reset" "$GOT" "81 82 84 "

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "usage-limit: all passed" || echo "usage-limit: FAILURES"
exit "$FAIL"
