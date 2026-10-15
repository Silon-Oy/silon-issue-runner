#!/usr/bin/env bash
# test-claude-usage.sh — per-call model and token bookkeeping (issue #307).
#
# A native call_claude passes --session-id, reads that session's transcript
# afterwards and merges the actual model and the summed tokens into run.json's
# .usage[<step-id>] (state_usage_add).
#
# Cases:
#   (a) native call: actual model from the transcript (not the setting), tokens
#       summed over DEDUPLICATED turns (one line per content block), synthetic
#       and unparseable lines skipped, effort and duration recorded, calls=1.
#   (b) the same step again (a restart) sums; a second model is a union.
#   (c) .out keeps the CLI's stdout byte for byte.
#   (d) no transcript -> "unknown" values, rc 0; unknown absorbs a later sum,
#       duration keeps summing.
#   (e) overridden driver -> no --session-id, no usage, exactly one log line.
#   (f) no run.json (a PR-watch scratch dir) -> nothing written, rc 0.
#
# The CLI is a mock; HOME and CLAUDE_CONFIG_DIR are temporary (CLAUDE.md §8).
#
# Run: bash tests/test-claude-usage.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed"
  exit 0
fi

WORK=$(mktemp -d -t claude-usage.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
ok()  { echo "PASS ($1) $2"; }
bad() { echo "FAIL ($1) $2"; FAIL=1; }
check() { # <case> <name> <got> <want>
  if [ "$3" = "$4" ]; then ok "$1" "$2"; else bad "$1" "$2 — got '$3', want '$4'"; fi
}

export HOME="$WORK/home"
export CLAUDE_CONFIG_DIR="$WORK/claude-config"
mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR/projects/-some-worktree"
unset RUN_ISSUES_CLAUDE_PROFILES RUN_ISSUES_CLAUDE_MODEL RUN_ISSUES_CLAUDE_EFFORT RUN_ISSUES_CLAUDE_FALLBACK_MODEL
export RUN_ISSUES_LOG_DIR="$WORK/logs"
mkdir -p "$RUN_ISSUES_LOG_DIR"

# Mock CLI: writes a transcript for its --session-id unless $WORK/no-transcript
# exists. The model name comes from $WORK/model so a test can change it.
BIN="$WORK/bin"; mkdir -p "$BIN"
ARGV="$WORK/argv.txt"
cat > "$BIN/claude" <<SH
#!/usr/bin/env bash
: > "$ARGV"
sid=""
while [ "\$#" -gt 0 ]; do
  printf '%s\n' "\$1" >> "$ARGV"
  [ "\$1" = "--session-id" ] && sid="\$2"
  shift
done
if [ -n "\$sid" ] && [ ! -e "$WORK/no-transcript" ]; then
  m=\$(cat "$WORK/model")
  t="$CLAUDE_CONFIG_DIR/projects/-some-worktree/\$sid.jsonl"
  {
    printf '{"type":"user","message":{"role":"user"}}\n'
    # Turn 1: two content blocks -> two lines repeating the same id and usage.
    for _ in 1 2; do
      printf '{"type":"assistant","message":{"id":"m1","model":"%s","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":1000,"cache_creation_input_tokens":5}}}\n' "\$m"
    done
    printf '{"type":"assistant","message":{"id":"m2","model":"%s","usage":{"input_tokens":1,"output_tokens":20,"cache_read_input_tokens":2000,"cache_creation_input_tokens":0}}}\n' "\$m"
    printf '{"type":"assistant","message":{"id":"s1","model":"<synthetic>","usage":{"input_tokens":999,"output_tokens":999}}}\n'
    printf '{"type":"assistant","message":{"id":"m3", "trunc'
  } > "\$t"
fi
printf 'agent says hi\nRESULT: SUCCESS\n'
exit 0
SH
chmod +x "$BIN/claude"
printf 'claude-test-model' > "$WORK/model"

PROMPT="$WORK/prompt.txt"; printf 'do it\n' > "$PROMPT"
RUNDIR="$WORK/run"
LOGF="$WORK/stderr.txt"

# shellcheck source=lib/state.sh
. "$ROOT/lib/state.sh"
state_init "$RUNDIR" "run-1" "$WORK/repo" 7

# invoke <cmd> <step> [VAR=value ...] — call_claude in a subshell.
invoke() {
  local cmd="$1" step="$2" rc=0; shift 2
  (
    export RUN_ISSUES_CLAUDE_CMD="$cmd"
    for kv in "$@"; do export "${kv?}"; done
    # shellcheck source=lib/state.sh
    . "$ROOT/lib/state.sh"
    # shellcheck source=lib/claude-call.sh
    . "$ROOT/lib/claude-call.sh"
    call_claude "$RUNDIR" "$step" "$PROMPT"
  ) 2> "$LOGF" || rc=$?
  printf '%s' "$rc"
}
u() { jq -r ".usage[\"$1\"].$2" "$RUNDIR/run.json"; }

# (a)
RC=$(invoke "$BIN/claude" 02-implementer RUN_ISSUES_CLAUDE_MODEL=opus RUN_ISSUES_CLAUDE_EFFORT=high)
check a "rc" "$RC" "0"
check a "--session-id passed" "$(grep -cxF -- --session-id "$ARGV")" "1"
check a "model from the transcript, not the setting" "$(u 02-implementer model)" "claude-test-model"
check a "input_tokens deduplicated" "$(u 02-implementer input_tokens)" "11"
check a "output_tokens" "$(u 02-implementer output_tokens)" "120"
check a "cache_read_input_tokens" "$(u 02-implementer cache_read_input_tokens)" "3000"
check a "cache_creation_input_tokens" "$(u 02-implementer cache_creation_input_tokens)" "5"
check a "assistant_turns" "$(u 02-implementer assistant_turns)" "2"
check a "effort" "$(u 02-implementer effort)" "high"
check a "duration is a number" "$(jq -r '.usage["02-implementer"].duration_seconds | type' "$RUNDIR/run.json")" "number"
check a "calls" "$(u 02-implementer calls)" "1"

# (b)
printf 'claude-other-model' > "$WORK/model"
RC=$(invoke "$BIN/claude" 02-implementer)
check b "rc" "$RC" "0"
check b "tokens summed" "$(u 02-implementer output_tokens)" "240"
check b "turns summed" "$(u 02-implementer assistant_turns)" "4"
check b "models united" "$(u 02-implementer model)" "claude-other-model,claude-test-model"
check b "efforts united" "$(u 02-implementer effort)" "default,high"
check b "calls" "$(u 02-implementer calls)" "2"

# (c)
check c ".out unchanged" "$(cat "$RUNDIR/02-implementer.out")" "$(printf 'agent says hi\nRESULT: SUCCESS')"

# (d)
touch "$WORK/no-transcript"
RC=$(invoke "$BIN/claude" 03-evolution)
check d "rc" "$RC" "0"
check d "model unknown" "$(u 03-evolution model)" "unknown"
check d "tokens unknown" "$(u 03-evolution input_tokens)" "unknown"
check d "turns unknown" "$(u 03-evolution assistant_turns)" "unknown"
rm -f "$WORK/no-transcript"
RC=$(invoke "$BIN/claude" 03-evolution)
check d "unknown absorbs a later sum" "$(u 03-evolution output_tokens)" "unknown"
check d "duration keeps summing" "$(jq -r '.usage["03-evolution"].duration_seconds | type' "$RUNDIR/run.json")" "number"
check d "calls" "$(u 03-evolution calls)" "2"

# (e)
cp "$BIN/claude" "$BIN/my-driver"
RC=$(invoke "$BIN/my-driver" 01-cycle-review)
check e "rc" "$RC" "0"
check e "no --session-id" "$(grep -cxF -- --session-id "$ARGV")" "0"
check e "no usage record" "$(jq -r '.usage | has("01-cycle-review")' "$RUNDIR/run.json")" "false"
check e "one log line" "$(grep -c 'usage not recorded' "$LOGF")" "1"

# (f)
SCRATCH="$WORK/scratch"; mkdir -p "$SCRATCH"
RC=$(
  RUNDIR="$SCRATCH"
  invoke "$BIN/claude" 05-ci-repair
)
check f "rc" "$RC" "0"
check f "no run.json created" "$([ -e "$SCRATCH/run.json" ] && echo yes || echo no)" "no"

if [ "$FAIL" -eq 0 ]; then
  echo "claude-usage: all passed"
  exit 0
fi
echo "claude-usage: FAILURES"
exit 1
