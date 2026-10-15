#!/usr/bin/env bash
# test-ab-arm.sh — A/B arm of a run (issue #308).
#
# lib/ab-arm.sh assigns an arm once per run into run.json (.ab_arm) when an
# experiment (RUN_ISSUES_AB_CLAUDE_{MODEL,EFFORT}[_<PHASE>]) is defined, and
# call_claude reads it back from run.json on every call: arm B takes the
# experiment's value, arm A and arm-less runs the normal settings.
#
# Assertions are on run.json and on the ARGV a stubbed RUN_ISSUES_CLAUDE_CMD
# records; no real agent is ever launched (CLAUDE.md §5.5).
#
# Cases:
#   (a) no experiment -> no ab_arm field, argv without --model/--effort.
#   (b) experiment, arm B -> ab_arm=B; B phase model + effort reach the CLI.
#   (c) arm B, phase without an experiment value -> normal settings.
#   (d) arm A -> normal settings, experiment ignored.
#   (e) an arm already in run.json is kept (restart/resume/continue re-read it).
#   (f) the arm is read at call time, in a fresh process: no re-assignment.
#   (g) unforced pick produces both arms.
#   (h) orchestrate.sh assigns on the run-creating path only.
#   (i) the chosen arm is logged.
#
# Run: bash tests/test-ab-arm.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/lib/claude-call.sh"
STATE_LIB="$ROOT/lib/state.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

WORK=$(mktemp -d -t ab-arm.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
ok()  { echo "PASS ($1) $2"; }
bad() { echo "FAIL ($1) $2"; FAIL=1; }

ARGV="$WORK/argv.txt"
NATIVE_DIR="$WORK/native"; mkdir -p "$NATIVE_DIR"
cat > "$NATIVE_DIR/claude" <<SH
#!/usr/bin/env bash
: > "$ARGV"
for a in "\$@"; do printf '%s\n' "\$a" >> "$ARGV"; done
exit 0
SH
chmod +x "$NATIVE_DIR/claude"
NATIVE="$NATIVE_DIR/claude"

PROMPT="$WORK/prompt.txt"; printf 'do the thing\n' > "$PROMPT"
STDERR="$WORK/stderr.txt"

# fresh_run <name> — a run dir with a pre-#308 run.json (state_init).
fresh_run() {
  local d="$WORK/$1"
  # shellcheck disable=SC1090
  ( . "$STATE_LIB"; state_init "$d" "$1" "$WORK/repo" 1 ) >/dev/null
  printf '%s' "$d"
}

# clean_env — clear every model/effort/experiment variable, export the given ones.
clean_env() {
  for v in $(compgen -v RUN_ISSUES_CLAUDE_MODEL) $(compgen -v RUN_ISSUES_CLAUDE_EFFORT) \
           $(compgen -v RUN_ISSUES_AB_) RUN_ISSUES_CLAUDE_FALLBACK_MODEL RUN_ISSUES_CLAUDE_PROFILES; do
    unset "$v"
  done
  for kv in "$@"; do export "${kv?}"; done
}

# assign <run-dir> [VAR=value ...] — ab_arm_assign in a fresh process.
assign() {
  local d="$1"; shift
  # shellcheck disable=SC1090
  ( clean_env "$@"; . "$STATE_LIB"; . "$ROOT/lib/ab-arm.sh"; ab_arm_assign "$d" )
}

# invoke <run-dir> <step-id> [VAR=value ...] — call_claude in a fresh process.
invoke() {
  local d="$1" step="$2" rc=0; shift 2
  (
    set -euo pipefail
    clean_env RUN_ISSUES_CLAUDE_CMD="$NATIVE" "$@"
    # shellcheck disable=SC1090
    . "$STATE_LIB"
    # shellcheck disable=SC1090
    . "$LIB"
    call_claude "$d" "$step" "$PROMPT"
  ) 2> "$STDERR" || rc=$?
  printf '%s' "$rc"
}

flag_value() { awk -v f="$1" '$0 == f { getline; print; exit }' "$ARGV"; }
has_flag()   { grep -qxF -- "$1" "$ARGV"; }
arm_field()  { jq -r 'if has("ab_arm") then .ab_arm else "<absent>" end' "$1/run.json"; }

EXP=(RUN_ISSUES_AB_CLAUDE_MODEL_IMPLEMENTER=sonnet RUN_ISSUES_AB_CLAUDE_EFFORT_IMPLEMENTER=medium
     RUN_ISSUES_CLAUDE_MODEL=opus RUN_ISSUES_CLAUDE_EFFORT=high)

# (a)
R=$(fresh_run a)
BEFORE=$(cat "$R/run.json")
A_OUT=$(assign "$R")
RC=$(invoke "$R" 02-implementer)
if [ -z "$A_OUT" ] && [ "$(arm_field "$R")" = "<absent>" ] && [ "$RC" = 0 ] \
   && ! has_flag --model && ! has_flag --effort \
   && [ "$(jq -S 'del(.usage)' <<<"$BEFORE")" = "$(jq -S 'del(.usage)' "$R/run.json")" ]; then
  ok a "no experiment -> no ab_arm field, no new flags"
else
  bad a "assign='$A_OUT' field=$(arm_field "$R") rc=$RC argv=$(tr '\n' ' ' < "$ARGV")"
fi
# Empty experiment variables are "not set", like every other setting.
R=$(fresh_run a2)
A_OUT=$(assign "$R" RUN_ISSUES_AB_CLAUDE_MODEL_IMPLEMENTER=)
if [ -z "$A_OUT" ] && [ "$(arm_field "$R")" = "<absent>" ]; then
  ok a "empty experiment variable -> no experiment"
else
  bad a "empty variable assigned '$A_OUT'"
fi

# (b)
R=$(fresh_run b)
A_OUT=$(assign "$R" RUN_ISSUES_AB_ARM=B "${EXP[@]}")
RC=$(invoke "$R" 02-implementer "${EXP[@]}")
if [ "$A_OUT" = B ] && [ "$(arm_field "$R")" = B ] && [ "$RC" = 0 ] \
   && [ "$(flag_value --model)" = sonnet ] && [ "$(flag_value --effort)" = medium ]; then
  ok b "arm B -> experiment model and effort"
else
  bad b "assign='$A_OUT' field=$(arm_field "$R") model=$(flag_value --model) effort=$(flag_value --effort)"
fi

# (c)
RC=$(invoke "$R" 03-evolution "${EXP[@]}")
if [ "$RC" = 0 ] && [ "$(flag_value --model)" = opus ] && [ "$(flag_value --effort)" = high ]; then
  ok c "arm B, phase outside the experiment -> normal settings"
else
  bad c "model=$(flag_value --model) effort=$(flag_value --effort)"
fi

# (d)
R=$(fresh_run d)
A_OUT=$(assign "$R" RUN_ISSUES_AB_ARM=A "${EXP[@]}")
RC=$(invoke "$R" 02-implementer "${EXP[@]}")
if [ "$A_OUT" = A ] && [ "$(arm_field "$R")" = A ] \
   && [ "$(flag_value --model)" = opus ] && [ "$(flag_value --effort)" = high ]; then
  ok d "arm A -> normal settings"
else
  bad d "assign='$A_OUT' model=$(flag_value --model) effort=$(flag_value --effort)"
fi

# (e)
A_OUT=$(assign "$R" RUN_ISSUES_AB_ARM=B "${EXP[@]}")
if [ "$A_OUT" = A ] && [ "$(arm_field "$R")" = A ]; then
  ok e "recorded arm is kept on a second assignment"
else
  bad e "second assign='$A_OUT' field=$(arm_field "$R")"
fi

# (f) A run recorded as B keeps B even when the calling process forces A and
# the run.json is the only carrier of the arm.
R=$(fresh_run f)
assign "$R" RUN_ISSUES_AB_ARM=B "${EXP[@]}" >/dev/null
RC=$(invoke "$R" 02-implementer RUN_ISSUES_AB_ARM=A "${EXP[@]}")
if [ "$(flag_value --model)" = sonnet ] && [ "$(arm_field "$R")" = B ]; then
  ok f "call reads the arm from run.json, never re-assigns"
else
  bad f "model=$(flag_value --model) field=$(arm_field "$R")"
fi

# (g)
SEEN=""
for i in $(seq 1 40); do
  R=$(fresh_run "g$i")
  SEEN="$SEEN$(assign "$R" RUN_ISSUES_AB_CLAUDE_EFFORT=low)"
done
case "$SEEN" in
  *A*B*|*B*A*) ok g "unforced pick produces both arms" ;;
  *) bad g "40 picks gave only '$SEEN'" ;;
esac

# (h) The restart / resume / continue paths are separate entries into
# orchestrate.sh; assignment must live only in phase_a, the run-creating path.
CALLS=$(grep -c 'ab_arm_assign "' "$ROOT/orchestrate.sh")
IN_PHASE_A=$(awk '/^phase_a\(\) \{/{f=1} f && /ab_arm_assign "/{n++} f && /^}/{f=0} END{print n+0}' "$ROOT/orchestrate.sh")
if [ "$CALLS" = 1 ] && [ "$IN_PHASE_A" = 1 ]; then
  ok h "orchestrate.sh assigns the arm only in phase_a"
else
  bad h "ab_arm_assign occurrences=$CALLS in_phase_a=$IN_PHASE_A"
fi

# (i)
R=$(fresh_run i)
assign "$R" RUN_ISSUES_AB_ARM=B "${EXP[@]}" >/dev/null
invoke "$R" 02-implementer "${EXP[@]}" >/dev/null
if grep -q 'ab_arm=B: model=sonnet from RUN_ISSUES_AB_CLAUDE_MODEL_IMPLEMENTER' "$STDERR"; then
  ok i "arm and the experiment variable are logged"
else
  bad i "log: $(cat "$STDERR")"
fi

[ "$FAIL" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$FAIL"
