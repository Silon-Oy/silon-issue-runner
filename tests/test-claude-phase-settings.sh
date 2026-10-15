#!/usr/bin/env bash
# test-claude-phase-settings.sh — per-phase model and effort (issue #306).
#
# call_claude derives the phase from the step id (_claude_step_phase) and picks
# RUN_ISSUES_CLAUDE_{MODEL,EFFORT}_<PHASE> over the general
# RUN_ISSUES_CLAUDE_{MODEL,EFFORT}, which in turn override the CLI default (no
# flag). --effort reaches the native CLI only; an unknown value is one warning
# line and no flag.
#
# Assertions are on the ARGV a stubbed RUN_ISSUES_CLAUDE_CMD records; no real
# agent is ever launched (CLAUDE.md §5.5).
#
# Cases:
#   (a) no new variables -> argv identical to the pre-#306 vector.
#   (b) every step id maps to its phase; unknown id maps to nothing.
#   (c) phase model beats general model; other phase gets the general one.
#   (d) phase effort beats general effort; general applies to other phases.
#   (e) unknown effort -> exactly one warning, no --effort, rc 0.
#   (f) overridden driver -> no --effort.
#   (g) chosen model and effort are logged.
#   (h) versioned phase model -> warning names the phase variable.
#
# Run: bash tests/test-claude-phase-settings.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/lib/claude-call.sh"

WORK=$(mktemp -d -t claude-phase.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
ok()  { echo "PASS ($1) $2"; }
bad() { echo "FAIL ($1) $2"; FAIL=1; }

ARGV="$WORK/argv.txt"
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/claude-stub" <<SH
#!/usr/bin/env bash
: > "$ARGV"
for a in "\$@"; do printf '%s\n' "\$a" >> "$ARGV"; done
exit 0
SH
chmod +x "$BIN/claude-stub"
NATIVE_DIR="$WORK/native"; mkdir -p "$NATIVE_DIR"
ln -sf "$BIN/claude-stub" "$NATIVE_DIR/claude"
NATIVE="$NATIVE_DIR/claude"
OVERRIDE="$BIN/claude-stub"

RUNDIR="$WORK/run"; mkdir -p "$RUNDIR"
PROMPT="$WORK/prompt.txt"; printf 'do the thing\n' > "$PROMPT"
STDERR="$WORK/stderr.txt"

# invoke <cmd> <step-id> [VAR=value ...] — call_claude in a fresh subshell with
# every model/effort variable cleared first, then the given ones exported.
invoke() {
  local cmd="$1" step="$2" rc=0; shift 2
  (
    set -euo pipefail
    for v in $(compgen -v RUN_ISSUES_CLAUDE_MODEL) $(compgen -v RUN_ISSUES_CLAUDE_EFFORT) RUN_ISSUES_CLAUDE_FALLBACK_MODEL; do unset "$v"; done
    unset RUN_ISSUES_CLAUDE_PROFILES
    export RUN_ISSUES_CLAUDE_CMD="$cmd"
    for kv in "$@"; do export "${kv?}"; done
    # shellcheck disable=SC1090
    . "$LIB"
    call_claude "$RUNDIR" "$step" "$PROMPT"
  ) 2> "$STDERR" || rc=$?
  printf '%s' "$rc"
}

flag_value() { awk -v f="$1" '$0 == f { getline; print; exit }' "$ARGV"; }
has_flag()   { grep -qxF -- "$1" "$ARGV"; }

# (a) The pre-#306 vector for the native CLI, nothing set: the command, the
# system prompt, the plugin context, then the fixed tail.
RC=$(invoke "$NATIVE" "02-implementer")
EXPECTED="$WORK/expected.txt"
{
  printf '%s\n' --append-system-prompt-file "$RUNDIR/02-implementer.system-prompt.md"
  printf '%s\n' --strict-mcp-config --setting-sources project,local
  printf '%s\n' --session-id '<uuid>'
  printf '%s\n' --dangerously-skip-permissions -p 'do the thing'
} > "$EXPECTED"
# The system-prompt path depends on which principles files exist and the session
# id (#307) is fresh per call; compare the flag set structurally instead.
sed -i.bak '2s/.*/<sp>/' "$EXPECTED"; sed -e '2s/.*/<sp>/' -e '7s/.*/<uuid>/' "$ARGV" > "$WORK/argv.norm"
if [ "$RC" = 0 ] && diff -q "$EXPECTED" "$WORK/argv.norm" >/dev/null; then
  ok a "no new variables -> argv unchanged (plus #307 --session-id)"
else
  bad a "rc=$RC; diff: $(diff "$EXPECTED" "$WORK/argv.norm" | tr '\n' ' ')"
fi

# (b)
PHASES=$(
  # shellcheck disable=SC1090
  . "$LIB"
  for s in 01-cycle-review 02-implementer 03-evolution 04-conflict-resolution 05-ci-repair 99-other; do
    printf '%s=%s ' "$s" "$(_claude_step_phase "$s")"
  done
)
WANT="01-cycle-review=CYCLE_REVIEW 02-implementer=IMPLEMENTER 03-evolution=EVOLUTION 04-conflict-resolution=CONFLICT 05-ci-repair=CI_REPAIR 99-other= "
if [ "$PHASES" = "$WANT" ]; then
  ok b "step id -> phase mapping"
else
  bad b "got '$PHASES'"
fi

# (c)
RC=$(invoke "$NATIVE" "02-implementer" RUN_ISSUES_CLAUDE_MODEL=sonnet RUN_ISSUES_CLAUDE_MODEL_IMPLEMENTER=opus)
M1=$(flag_value --model)
RC2=$(invoke "$NATIVE" "03-evolution" RUN_ISSUES_CLAUDE_MODEL=sonnet RUN_ISSUES_CLAUDE_MODEL_IMPLEMENTER=opus)
M2=$(flag_value --model)
if [ "$RC$RC2" = 00 ] && [ "$M1" = opus ] && [ "$M2" = sonnet ]; then
  ok c "phase model beats general; other phase gets general"
else
  bad c "rc=$RC/$RC2 implementer='$M1' evolution='$M2'"
fi

# (d)
RC=$(invoke "$NATIVE" "05-ci-repair" RUN_ISSUES_CLAUDE_EFFORT=low RUN_ISSUES_CLAUDE_EFFORT_CI_REPAIR=xhigh)
E1=$(flag_value --effort)
RC2=$(invoke "$NATIVE" "01-cycle-review" RUN_ISSUES_CLAUDE_EFFORT=low RUN_ISSUES_CLAUDE_EFFORT_CI_REPAIR=xhigh)
E2=$(flag_value --effort)
if [ "$RC$RC2" = 00 ] && [ "$E1" = xhigh ] && [ "$E2" = low ]; then
  ok d "phase effort beats general; other phase gets general"
else
  bad d "rc=$RC/$RC2 ci-repair='$E1' cycle-review='$E2'"
fi

# (e)
RC=$(invoke "$NATIVE" "04-conflict-resolution" RUN_ISSUES_CLAUDE_EFFORT_CONFLICT=extreme)
W=$(grep -c 'not a known effort' "$STDERR")
if [ "$RC" = 0 ] && ! has_flag --effort && [ "$W" = 1 ]; then
  ok e "unknown effort -> one warning, no --effort"
else
  bad e "rc=$RC warnings=$W effort='$(flag_value --effort)'"
fi

# (f)
RC=$(invoke "$OVERRIDE" "02-implementer" RUN_ISSUES_CLAUDE_EFFORT=high)
if [ "$RC" = 0 ] && ! has_flag --effort; then
  ok f "overridden driver -> no --effort"
else
  bad f "rc=$RC effort='$(flag_value --effort)'"
fi

# (g)
RC=$(invoke "$NATIVE" "03-evolution" RUN_ISSUES_CLAUDE_MODEL_EVOLUTION=haiku RUN_ISSUES_CLAUDE_EFFORT=medium)
if [ "$RC" = 0 ] && grep -q 'step 03-evolution (phase EVOLUTION): model=haiku from RUN_ISSUES_CLAUDE_MODEL_EVOLUTION effort=medium from RUN_ISSUES_CLAUDE_EFFORT' "$STDERR"; then
  ok g "chosen model and effort logged"
else
  bad g "rc=$RC log: $(grep 'step 03-evolution' "$STDERR")"
fi

# (h)
RC=$(invoke "$NATIVE" "01-cycle-review" RUN_ISSUES_CLAUDE_MODEL_CYCLE_REVIEW=claude-opus-4-8)
if [ "$RC" = 0 ] && grep -q 'WARNING: RUN_ISSUES_CLAUDE_MODEL_CYCLE_REVIEW=claude-opus-4-8 is a versioned' "$STDERR"; then
  ok h "versioned phase model -> warning names the phase variable"
else
  bad h "rc=$RC log: $(grep -i warning "$STDERR")"
fi

[ "$FAIL" -eq 0 ] && echo "claude-phase-settings: all passed" || echo "claude-phase-settings: FAILURES"
exit "$FAIL"
