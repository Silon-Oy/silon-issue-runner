#!/usr/bin/env bash
# test-claude-model.sh — how call_claude turns RUN_ISSUES_CLAUDE_MODEL and
# RUN_ISSUES_CLAUDE_FALLBACK_MODEL into CLI flags (issue #305).
#
# The model is chosen as a FAMILY alias (opus, sonnet, haiku, optionally with a
# context-window suffix like opus[1m]) so a new version is picked up without a
# configuration change. A versioned id still works — it is the emergency brake —
# but call_claude logs one warning line saying it pins the version. Availability
# is handled by --fallback-model, which is native CLI vocabulary and therefore
# never reaches an operator's own driver.
#
# Assertions are on the ARGV a stubbed RUN_ISSUES_CLAUDE_CMD records; no real
# agent is ever launched (CLAUDE.md §5.5).
#
# Cases:
#   (a) family alias -> --model <alias>, no warning.
#   (b) context-window alias opus[1m] -> passed verbatim as ONE argv element,
#       even when a file the bracket expression would glob-match exists in cwd.
#   (c) versioned id -> passed through, exactly one warning line.
#   (d) empty model -> no --model flag at all.
#   (e) fallback set, native CLI -> --fallback-model <value>.
#   (f) fallback set, overridden driver -> no --fallback-model.
#   (g) fallback empty, native CLI -> no --fallback-model.
#
# Run: bash tests/test-claude-model.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/lib/claude-call.sh"

WORK=$(mktemp -d -t claude-model.XXXXXX)
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
# The native CLI by absolute path: claude_cmd_is_native keys on the basename.
NATIVE_DIR="$WORK/native"; mkdir -p "$NATIVE_DIR"
ln -sf "$BIN/claude-stub" "$NATIVE_DIR/claude"
NATIVE="$NATIVE_DIR/claude"
OVERRIDE="$BIN/claude-stub"

RUNDIR="$WORK/run"; mkdir -p "$RUNDIR"
PROMPT="$WORK/prompt.txt"; printf 'do the thing\n' > "$PROMPT"
# cwd for every call: holds a file `opus1`, which an unquoted opus[1m] would
# glob-expand to.
CWD="$WORK/cwd"; mkdir -p "$CWD"; : > "$CWD/opus1"

# invoke <cmd> <model> <fallback> — call_claude in a fresh subshell. Prints rc;
# argv lands in $ARGV, log lines in $WORK/stderr.txt.
invoke() {
  local rc=0
  (
    set -euo pipefail
    cd "$CWD"
    export RUN_ISSUES_CLAUDE_CMD="$1"
    export RUN_ISSUES_CLAUDE_MODEL="$2"
    export RUN_ISSUES_CLAUDE_FALLBACK_MODEL="$3"
    unset RUN_ISSUES_CLAUDE_PROFILES
    # shellcheck disable=SC1090
    . "$LIB"
    call_claude "$RUNDIR" "step" "$PROMPT"
  ) 2> "$WORK/stderr.txt" || rc=$?
  printf '%s' "$rc"
}

flag_value() { awk -v f="$1" '$0 == f { getline; print; exit }' "$ARGV"; }
has_flag()   { grep -qxF -- "$1" "$ARGV"; }
warnings()   { grep -c 'versioned model id' "$WORK/stderr.txt"; }

# (a)
RC=$(invoke "$NATIVE" sonnet "")
if [ "$RC" = 0 ] && [ "$(flag_value --model)" = "sonnet" ] && [ "$(warnings)" = 0 ]; then
  ok a "family alias -> --model sonnet, no warning"
else
  bad a "rc=$RC model='$(flag_value --model)' warnings=$(warnings)"
fi

# (b)
RC=$(invoke "$NATIVE" 'opus[1m]' "")
if [ "$RC" = 0 ] && [ "$(flag_value --model)" = "opus[1m]" ] && [ "$(warnings)" = 0 ]; then
  ok b "context-window alias opus[1m] -> passed verbatim, not glob-expanded"
else
  bad b "rc=$RC model='$(flag_value --model)' warnings=$(warnings)"
fi

# (c)
RC=$(invoke "$NATIVE" claude-opus-4-8 "")
if [ "$RC" = 0 ] && [ "$(flag_value --model)" = "claude-opus-4-8" ] && [ "$(warnings)" = 1 ]; then
  ok c "versioned id -> passed through with one warning line"
else
  bad c "rc=$RC model='$(flag_value --model)' warnings=$(warnings)"
fi

# (d)
RC=$(invoke "$NATIVE" "" "")
if [ "$RC" = 0 ] && ! has_flag --model; then
  ok d "empty model -> no --model flag"
else
  bad d "rc=$RC, --model present: $(flag_value --model)"
fi

# (e)
RC=$(invoke "$NATIVE" opus sonnet)
if [ "$RC" = 0 ] && [ "$(flag_value --fallback-model)" = "sonnet" ]; then
  ok e "fallback on the native CLI -> --fallback-model sonnet"
else
  bad e "rc=$RC fallback='$(flag_value --fallback-model)'"
fi

# (f)
RC=$(invoke "$OVERRIDE" opus sonnet)
if [ "$RC" = 0 ] && ! has_flag --fallback-model && [ "$(flag_value --model)" = "opus" ]; then
  ok f "overridden driver -> no --fallback-model (model still passed)"
else
  bad f "rc=$RC fallback present=$(has_flag --fallback-model && echo yes || echo no) model='$(flag_value --model)'"
fi

# (g)
RC=$(invoke "$NATIVE" opus "")
if [ "$RC" = 0 ] && ! has_flag --fallback-model; then
  ok g "empty fallback -> no --fallback-model"
else
  bad g "rc=$RC fallback='$(flag_value --fallback-model)'"
fi

[ "$FAIL" -eq 0 ] && echo "claude-model: all passed" || echo "claude-model: FAILURES"
exit "$FAIL"
