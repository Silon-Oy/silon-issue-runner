#!/usr/bin/env bash
# test-claude-profiles.sh — falling over between Claude subscription profiles
# on a usage limit (issue #295, lib/claude-profiles.sh + call_claude).
#
# Covers:
#   (a) no profiles: behaviour unchanged, no CLAUDE_CODE_OAUTH_TOKEN reaches
#       the CLI.
#   (b) the first profile's limit message re-runs the same step on the second
#       profile in the same call; the first is marked full, the machine gate is
#       NOT tripped, and each attempt's profile is in state.jsonl.
#   (c) the shared state: the next call skips the full profile, and the
#       preferred profile is used again once its deadline has passed.
#   (d) every profile full -> CLAUDE_USAGE_LIMIT_RC, machine gate tripped at the
#       EARLIEST profile reset; already all full at call start -> no CLI call.
#   (e) the token never leaks: not on the CLI's command line, not in the log,
#       state.jsonl, run.json or any output file, not exported to the caller.
#   (f) fail-closed: an unusable token file skips its profile, never falls back
#       to the default login; malformed entries are ignored.
#
# The claude CLI is a PATH-free mock binary. No network.
#
# Run: bash tests/test-claude-profiles.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed"
  exit 0
fi

WORK=$(mktemp -d -t claude-profiles.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAIL=1; }
check() { # <name> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — got '$2', want '$3'"; fi
}

export RUN_ISSUES_LOG_DIR="$WORK/logs"
mkdir -p "$RUN_ISSUES_LOG_DIR"
GATE="$RUN_ISSUES_LOG_DIR/.claude-usage-limit"
unset CLAUDE_CODE_OAUTH_TOKEN RUN_ISSUES_CLAUDE_PROFILES RUN_ISSUES_USAGE_LIMIT_DETECTION

# shellcheck source=lib/state.sh
. "$ROOT/lib/state.sh"
# shellcheck source=lib/claude-call.sh
. "$ROOT/lib/claude-call.sh"
set +e  # claude-call.sh sets -e; this harness collects failures instead

# Mock CLI: records which token it saw (or "none") and its argv, then answers
# from $WORK/resp-<token> — a usage-limit message when that file exists.
BIN="$WORK/bin"
mkdir -p "$BIN"
SEEN="$WORK/seen.log"
ARGV="$WORK/argv.log"
cat > "$BIN/claude" <<SH
#!/usr/bin/env bash
tok="\${CLAUDE_CODE_OAUTH_TOKEN-none}"
echo "\$tok" >> "$SEEN"
printf '%s\n' "\$*" >> "$ARGV"
if [ -f "$WORK/resp-\$tok" ]; then
  cat "$WORK/resp-\$tok"
  exit 1
fi
echo "IMPLEMENTER_RESULT: SUCCESS"
SH
chmod +x "$BIN/claude"
export RUN_ISSUES_CLAUDE_CMD="$BIN/claude"

TOK_A="sk-ant-oat01-AAAAsecretAAAA"
TOK_B="sk-ant-oat01-BBBBsecretBBBB"
printf '%s\n' "$TOK_A" > "$WORK/a.token"
printf '%s\n' "$TOK_B" > "$WORK/b.token"
chmod 600 "$WORK/a.token" "$WORK/b.token"
PROFILES="alpha=$WORK/a.token
  beta=$WORK/b.token"

limit_for() { # <token> <seconds-from-now>
  printf 'Claude AI usage limit reached|%s\n' "$(( $(date +%s) + $2 ))" > "$WORK/resp-$1"
}
reset_all() { rm -f "$WORK"/resp-* "$SEEN" "$ARGV" "$GATE" "$GATE".profile-*; }

STDERR="$WORK/stderr.log"
echo "prompt" > "$WORK/prompt"
n=0
run_call() { # <run-dir> — sets RC; appends stderr to $STDERR
  n=$((n + 1))
  RC=0
  ( call_claude "$1" "step-$n" "$WORK/prompt" ) 2>>"$STDERR" || RC=$?
}

RD="$WORK/rd"
state_init "$RD" "rid" "$WORK" "1"

# === (a) no profiles =========================================================
reset_all
run_call "$RD"
check "(a) rc 0 without profiles" "$RC" "0"
check "(a) no token in the CLI environment" "$(cat "$SEEN")" "none"
grep -q '"event":"claude_profile"' "$RD/state.jsonl" \
  && bad "(a) profile event written without profiles" || ok "(a) no profile event"

# === (b) failover in the same call ===========================================
export RUN_ISSUES_CLAUDE_PROFILES="$PROFILES"
reset_all
limit_for "$TOK_A" 7200
run_call "$RD"
check "(b) rc 0 after failover" "$RC" "0"
check "(b) the step ran on alpha, then beta" "$(tr '\n' ' ' < "$SEEN")" "$TOK_A $TOK_B "
check "(b) .out is the final attempt" "$(cat "$RD/step-$n.out")" "IMPLEMENTER_RESULT: SUCCESS"
[ -s "$RD/step-$n.out.limited-alpha" ] && ok "(b) limited attempt kept" || bad "(b) no .out.limited-alpha"
usage_limit_active "$GATE.profile-alpha" && ok "(b) alpha marked full" || bad "(b) alpha not marked full"
usage_limit_active "$GATE.profile-beta" && bad "(b) beta marked full" || ok "(b) beta free"
[ -e "$GATE" ] && bad "(b) machine gate tripped with a free profile" || ok "(b) machine gate untouched"
check "(b) profile per attempt in state.jsonl" \
  "$(jq -r --arg s "step-$n" 'select(.event=="claude_profile" and .data.step==$s) | .data.profile' "$RD/state.jsonl" | tr '\n' ' ')" \
  "alpha beta "
grep -q '"event":"claude_profile_limited"' "$RD/state.jsonl" && ok "(b) limited event" || bad "(b) no claude_profile_limited event"
grep -q "runs on Claude profile 'beta'" "$STDERR" && ok "(b) profile in log" || bad "(b) profile name not logged"

# === (c) shared state, preferred profile returns =============================
rm -f "$SEEN"
run_call "$RD"
check "(c) next call skips the full profile" "$(tr '\n' ' ' < "$SEEN")" "$TOK_B "
# alpha's window has passed (and its limit with it).
printf '%s reset\n' "$(( $(date +%s) - 10 ))" > "$GATE.profile-alpha"
rm -f "$WORK/resp-$TOK_A" "$SEEN"
run_call "$RD"
check "(c) preferred profile used again after its reset" "$(tr '\n' ' ' < "$SEEN")" "$TOK_A "

# === (d) every profile full ==================================================
reset_all
limit_for "$TOK_A" 7200
limit_for "$TOK_B" 3600
EARLY=$(( $(date +%s) + 3600 + 60 ))
run_call "$RD"
check "(d) rc is CLAUDE_USAGE_LIMIT_RC" "$RC" "$CLAUDE_USAGE_LIMIT_RC"
check "(d) both profiles tried" "$(tr '\n' ' ' < "$SEEN")" "$TOK_A $TOK_B "
GOT=$(deadline_file_read "$GATE"); GOT="${GOT%% *}"
[ "$GOT" -ge $((EARLY - 5)) ] && [ "$GOT" -le $((EARLY + 5)) ] \
  && ok "(d) machine gate at the earliest reset" || bad "(d) machine gate $GOT, want ~$EARLY"
check "(d) run.json reset = earliest" "$(jq -r '.usage_limit_reset_at' "$RD/run.json")" "$GOT"
rm -f "$SEEN"
run_call "$RD"
check "(d) all full at call start: rc" "$RC" "$CLAUDE_USAGE_LIMIT_RC"
[ -e "$SEEN" ] && bad "(d) CLI called with every profile full" || ok "(d) no CLI call when all full"
check "(d) .exit written" "$(cat "$RD/step-$n.exit")" "$CLAUDE_USAGE_LIMIT_RC"

# === (e) the token never leaks ===============================================
for t in "$TOK_A" "$TOK_B"; do
  grep -qF "$t" "$ARGV" 2>/dev/null && bad "(e) token on the CLI command line" || ok "(e) token not in argv"
  grep -qF "$t" "$STDERR" && bad "(e) token in the log" || ok "(e) token not in the log"
  grep -rqF "$t" "$RD" && bad "(e) token in the run dir" || ok "(e) token not in the run dir"
  grep -rqF "$t" "$RUN_ISSUES_LOG_DIR" && bad "(e) token in a state file" || ok "(e) token not in state files"
done
check "(e) token not exported to the caller" "${CLAUDE_CODE_OAUTH_TOKEN-unset}" "unset"

# === (f) fail-closed on broken profiles ======================================
reset_all
export RUN_ISSUES_CLAUDE_PROFILES="ghost=$WORK/missing.token bogus beta=$WORK/b.token"
run_call "$RD"
check "(f) missing token file skipped, next profile used" "$(tr '\n' ' ' < "$SEEN")" "$TOK_B "
grep -q "profile 'ghost' not found" "$STDERR" && ok "(f) missing token file logged" || bad "(f) missing token file not logged"
grep -q "malformed RUN_ISSUES_CLAUDE_PROFILES entry" "$STDERR" && ok "(f) malformed entry logged" || bad "(f) malformed entry not logged"
reset_all
export RUN_ISSUES_CLAUDE_PROFILES="ghost=$WORK/missing.token"
run_call "$RD"
check "(f) no usable profile: rc 1" "$RC" "1"
[ -e "$SEEN" ] && bad "(f) fell back to the default login" || ok "(f) no CLI call without a usable profile"
[ -e "$GATE" ] && bad "(f) config error tripped the usage gate" || ok "(f) config error is not a usage limit"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "claude-profiles: all passed" || echo "claude-profiles: FAILURES"
exit "$FAIL"
