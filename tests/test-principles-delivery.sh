#!/usr/bin/env bash
# test-principles-delivery.sh — the always-on coding standard reaches every
# orchestrated claude call deterministically (issue #175).
#
# WHAT THIS PINS. Before #175 `call_claude` passed the CLI no system prompt at
# all, and only prompts/01-cycle-review.md injected anything (the TARGET repo's
# CLAUDE.md — a different document, deliberately kept). S8, S9 and the PR
# watcher's two agents therefore inherited the coding standard only from
# whichever machine happened to have it in user-level memory. The delivery
# channel is now the CLI flag, so the assertions here are about the ARGV the
# CLI actually receives — a stubbed RUN_ISSUES_CLAUDE_CMD records it. No real
# agent is ever launched (CLAUDE.md §5.5).
#
# WHY THE UNREADABLE-PATH CASES MATTER. Measured against claude CLI 2.1.257:
# `--append-system-prompt-file /does/not/exist` aborts the process with
# "Error: Append system prompt file not found" BEFORE the agent starts. The flag
# is fail-closed, so one typo'd config key would otherwise kill every step of
# every run. (d) and (i) are that guard.
#
# Cases:
#   (a) nothing configured -> flag present, pointing at the packaged
#       principles/coding.md.
#   (b) RUN_ISSUES_PRINCIPLES_FILE set to another readable file -> that wins.
#   (c) RUN_ISSUES_PRINCIPLES_FILE set to EMPTY -> no flag at all (opt-out).
#       "Unset" and "set to empty" must stay distinguishable.
#   (d) RUN_ISSUES_PRINCIPLES_FILE set to a missing path -> warning + packaged
#       default; rc is the agent's own, the run does NOT die.
#   (e) .claude/run-issues.json principles_file (relative) -> resolved against
#       the repo root and delivered.
#   (f) absolute principles_file in run-issues.json -> used verbatim.
#   (g) environment beats the repo config, including the empty opt-out.
#   (h) absent file / absent key / broken JSON -> benign no-op (packaged
#       default), never an error.
#   (i) nothing configured and the packaged standard missing -> no flag, no
#       crash.
#   (j) a path containing a space survives as ONE argv element (the reason the
#       flag is built as an array and not word-split like model_flag).
#   (k) structural: every orchestrated step routes through call_claude, so all
#       five call sites are covered by one seam.
#   (l) sourcing lib/claude-call.sh leaves RUN_ISSUES_PRINCIPLES_FILE UNSET.
#   (m) an `export RUN_ISSUES_PRINCIPLES_FILE=...` in the machine env file
#       reaches the CLI.
#
# (l) AND (m) ARE ONE INVARIANT, and it is the subtlest thing here. The obvious
# `RUN_ISSUES_PRINCIPLES_FILE="${RUN_ISSUES_PRINCIPLES_FILE:-$DEFAULT}"` line at
# the top of the module would break BOTH: `:-` erases the unset/empty
# distinction (c), and — measured on this package — lib/machine-env.sh snapshots
# every ALREADY-SET RUN_ISSUES_* name and restores it over the env file, so a
# default materialised at source time (claude-call.sh is sourced long before
# source_machine_env runs) permanently locks the env file out. Resolution is
# therefore lazy, inside call_claude. (m) is the end-to-end proof.
#
# Run: bash tests/test-principles-delivery.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/lib/claude-call.sh"
PACKAGED="$ROOT/principles/coding.md"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not on PATH (required by load_repo_principles_file)"
  exit 0
fi

WORK=$(mktemp -d -t principles-delivery.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
ok()   { echo "PASS ($1) $2"; }
bad()  { echo "FAIL ($1) $2"; FAIL=1; }

# The stubbed CLI: record argv, one element per line, then behave like a
# successful agent. This is the only thing `call_claude` executes.
BIN="$WORK/bin"; mkdir -p "$BIN"
ARGV="$WORK/argv.txt"
cat > "$BIN/claude-stub" <<SH
#!/usr/bin/env bash
: > "$ARGV"
for a in "\$@"; do printf '%s\n' "\$a" >> "$ARGV"; done
exit 0
SH
chmod +x "$BIN/claude-stub"

RUNDIR="$WORK/run"; mkdir -p "$RUNDIR"
PROMPT="$WORK/prompt.txt"; printf 'do the thing\n' > "$PROMPT"

# invoke [<shell prelude>] — run call_claude in a FRESH subshell so each case
# starts from a clean, unset RUN_ISSUES_PRINCIPLES_FILE. Prints the agent's rc;
# argv lands in $ARGV and any warnings in $WORK/stderr.txt.
#
# The prelude runs BEFORE the module is sourced, because that is the only
# faithful order: in production the environment (and the machine env file)
# already exists when orchestrate.sh sources lib/claude-call.sh. Evaluating it
# afterwards would let a source-time default masquerade as correct.
invoke() {
  local rc=0
  (
    set -euo pipefail
    export RUN_ISSUES_CLAUDE_CMD="$BIN/claude-stub"
    # shellcheck disable=SC2294  # the prelude IS shell source text, by design
    [ "$#" -gt 0 ] && eval "$*"
    # shellcheck disable=SC1090
    . "$LIB"
    call_claude "$RUNDIR" "step" "$PROMPT"
  ) 2> "$WORK/stderr.txt" || rc=$?
  printf '%s' "$rc"
}

# flag_value — the argument that follows --append-system-prompt-file in the
# recorded argv, or the empty string when the flag is absent.
flag_value() {
  awk '$0 == "--append-system-prompt-file" { getline; print; exit }' "$ARGV"
}
has_flag() { grep -qxF -- '--append-system-prompt-file' "$ARGV"; }

# ===========================================================================
# (a) nothing configured -> packaged standard
# ===========================================================================
RC=$(invoke)
if [ "$RC" != "0" ]; then
  bad a "call_claude returned $RC (want 0)"
elif ! has_flag; then
  bad a "no --append-system-prompt-file in argv"
elif [ "$(flag_value)" != "$PACKAGED" ]; then
  bad a "got '$(flag_value)' (want $PACKAGED)"
else
  ok a "default -> packaged principles/coding.md"
fi

# The flag must not have displaced the invocation's existing shape.
if grep -qxF -- '--dangerously-skip-permissions' "$ARGV" && grep -qxF -- '-p' "$ARGV"; then
  ok a2 "--dangerously-skip-permissions and -p still present"
else
  bad a2 "the flag disturbed the existing invocation shape"
fi

# ===========================================================================
# (b) explicit env override
# ===========================================================================
ALT="$WORK/alt-standard.md"; printf 'alt rules\n' > "$ALT"
RC=$(invoke "export RUN_ISSUES_PRINCIPLES_FILE='$ALT'")
if [ "$(flag_value)" = "$ALT" ]; then
  ok b "RUN_ISSUES_PRINCIPLES_FILE overrides the packaged default"
else
  bad b "got '$(flag_value)' (want $ALT)"
fi

# ===========================================================================
# (c) empty = opt out entirely
# ===========================================================================
RC=$(invoke "export RUN_ISSUES_PRINCIPLES_FILE=''")
if [ "$RC" != "0" ]; then
  bad c "call_claude returned $RC (want 0)"
elif has_flag; then
  bad c "flag still present after an explicit empty opt-out"
else
  ok c "empty value -> no system prompt flag at all"
fi

# ===========================================================================
# (d) unreadable override -> warn + packaged default, run survives
# ===========================================================================
RC=$(invoke "export RUN_ISSUES_PRINCIPLES_FILE='$WORK/nope.md'")
if [ "$RC" != "0" ]; then
  bad d "call_claude returned $RC — an unreadable override must not fail the run"
elif [ "$(flag_value)" != "$PACKAGED" ]; then
  bad d "got '$(flag_value)' (want fallback to $PACKAGED)"
elif ! grep -q 'not readable' "$WORK/stderr.txt"; then
  bad d "fell back silently — the operator gets no signal"
else
  ok d "missing override -> log line + packaged default, rc unchanged"
fi

# ===========================================================================
# (e)(f)(g)(h) repo config: .claude/run-issues.json
# ===========================================================================
REPO="$WORK/repo"; mkdir -p "$REPO/.claude"
printf 'repo rules\n' > "$REPO/standard.md"

repo_invoke() {  # [<shell prelude>] — same pre-source ordering as invoke
  local rc=0
  (
    set -euo pipefail
    export RUN_ISSUES_CLAUDE_CMD="$BIN/claude-stub"
    # shellcheck disable=SC2294  # the prelude IS shell source text, by design
    [ "$#" -gt 0 ] && eval "$*"
    # shellcheck disable=SC1090
    . "$LIB"
    load_repo_principles_file "$REPO"
    call_claude "$RUNDIR" "step" "$PROMPT"
  ) 2> "$WORK/stderr.txt" || rc=$?
  printf '%s' "$rc"
}

echo '{"principles_file":"standard.md"}' > "$REPO/.claude/run-issues.json"
repo_invoke >/dev/null
if [ "$(flag_value)" = "$REPO/standard.md" ]; then
  ok e "relative principles_file resolved against the repo root"
else
  bad e "got '$(flag_value)' (want $REPO/standard.md)"
fi

echo "{\"principles_file\":\"$ALT\"}" > "$REPO/.claude/run-issues.json"
repo_invoke >/dev/null
if [ "$(flag_value)" = "$ALT" ]; then
  ok f "absolute principles_file used verbatim"
else
  bad f "got '$(flag_value)' (want $ALT)"
fi

# environment beats repo config...
echo '{"principles_file":"standard.md"}' > "$REPO/.claude/run-issues.json"
repo_invoke "export RUN_ISSUES_PRINCIPLES_FILE='$ALT'" >/dev/null
if [ "$(flag_value)" = "$ALT" ]; then
  ok g1 "environment beats repo config"
else
  bad g1 "got '$(flag_value)' (want $ALT)"
fi
# ...including the empty opt-out, which the repo must not silently undo.
repo_invoke "export RUN_ISSUES_PRINCIPLES_FILE=''" >/dev/null
if has_flag; then
  bad g2 "repo config overrode a deliberate empty opt-out"
else
  ok g2 "empty environment opt-out survives a repo principles_file"
fi

# absent key / broken JSON / absent file -> benign no-op (CLAUDE.md §9: missing
# configuration is a default, never an error)
H_OK=1
echo '{"claude_timeout_seconds":2700}' > "$REPO/.claude/run-issues.json"
repo_invoke >/dev/null
[ "$(flag_value)" = "$PACKAGED" ] || { bad h1 "absent key: got '$(flag_value)'"; H_OK=0; }
echo '{not json' > "$REPO/.claude/run-issues.json"
RC=$(repo_invoke)
[ "$RC" = "0" ] || { bad h2 "broken JSON returned $RC"; H_OK=0; }
[ "$(flag_value)" = "$PACKAGED" ] || { bad h2 "broken JSON: got '$(flag_value)'"; H_OK=0; }
rm -f "$REPO/.claude/run-issues.json"
repo_invoke >/dev/null
[ "$(flag_value)" = "$PACKAGED" ] || { bad h3 "absent config: got '$(flag_value)'"; H_OK=0; }
[ "$H_OK" = "1" ] && ok h "absent key / broken JSON / absent config -> packaged default, no error"

# ===========================================================================
# (i) packaged standard itself missing -> drop the flag rather than feed the
#     CLI a path it is documented to reject
# ===========================================================================
# A real broken installation — the module in a package root that has no
# principles/ — rather than poking the internal default variable. The path is
# derived from BASH_SOURCE, so copying the lib is enough to reproduce it.
BROKEN="$WORK/broken-pkg/lib"; mkdir -p "$BROKEN"
cp "$LIB" "$ROOT/lib/preflight.sh" "$BROKEN/"
RC=$(
  rc=0
  (
    set -euo pipefail
    export RUN_ISSUES_CLAUDE_CMD="$BIN/claude-stub"
    # shellcheck disable=SC1090
    . "$BROKEN/claude-call.sh"
    call_claude "$RUNDIR" "step" "$PROMPT"
  ) 2> "$WORK/stderr.txt" || rc=$?
  printf '%s' "$rc"
)
if [ "$RC" != "0" ]; then
  bad i "call_claude returned $RC — a missing packaged standard must not fail the run"
elif has_flag; then
  bad i "passed a non-existent path to the CLI (which aborts on it)"
elif ! grep -q 'packaged coding standard missing' "$WORK/stderr.txt"; then
  bad i "dropped the standard silently"
else
  ok i "packaged standard missing -> no flag + warning, run survives"
fi

# ===========================================================================
# (j) a path with a space stays ONE argv element
# ===========================================================================
SPACED="$WORK/with space/std.md"
mkdir -p "$WORK/with space"; printf 'spaced\n' > "$SPACED"
invoke "export RUN_ISSUES_PRINCIPLES_FILE='$SPACED'" >/dev/null
if [ "$(flag_value)" = "$SPACED" ]; then
  ok j "path containing a space survives as one argument"
else
  bad j "got '$(flag_value)' (want $SPACED) — the flag is being word-split"
fi

# ===========================================================================
# (k) structural: all orchestrated steps go through the single seam
# ===========================================================================
missing=""
for step in 01-cycle-review 02-implementer 03-evolution; do
  grep -q "call_claude \"\$RUN_DIR\" \"$step\"" "$ROOT/orchestrate.sh" || missing="$missing $step"
done
grep -q 'call_claude "$out_dir" "$step_id" "$prompt_file"' "$ROOT/pr-watch.sh" \
  || missing="$missing pr-watch/_pr_call_agent"
# Nothing may invoke the CLI around call_claude's back. The marker is
# --dangerously-skip-permissions: any code path that actually runs an
# orchestrated step needs it, so a second occurrence anywhere in the package's
# shell would be a second invocation site — one the standard would not reach.
strays=$(grep -rln -- '--dangerously-skip-permissions' "$ROOT" 2>/dev/null \
  | grep -E '\.(sh|py)$' \
  | grep -v '/tests/' \
  | grep -v '/lib/claude-call\.sh$' || true)
if [ -n "$missing" ]; then
  bad k "step(s) not routed through call_claude:$missing"
elif [ -n "$strays" ]; then
  bad k "the CLI is invoked outside lib/claude-call.sh (bypasses the standard):
$strays"
else
  ok k "S6 / S8 / S9 / both PR-watch agents all route through call_claude"
fi

# ===========================================================================
# (l) the module must not materialise the variable at source time
# ===========================================================================
STATE=$(
  env -u RUN_ISSUES_PRINCIPLES_FILE bash -c '
    . "$1" >/dev/null 2>&1
    printf "%s" "${RUN_ISSUES_PRINCIPLES_FILE+SET}"
  ' _ "$LIB"
)
if [ -n "$STATE" ]; then
  bad l "sourcing claude-call.sh SET RUN_ISSUES_PRINCIPLES_FILE — this locks the machine env file out (see the header) and erases the unset/empty distinction"
else
  ok l "sourcing the module leaves RUN_ISSUES_PRINCIPLES_FILE unset"
fi

# ===========================================================================
# (m) end to end: the machine env file can still deliver the override
# ===========================================================================
ENVF="$WORK/machine-env"
printf 'export RUN_ISSUES_PRINCIPLES_FILE=%s
' "$ALT" > "$ENVF"
chmod 600 "$ENVF"
(
  set -euo pipefail
  export RUN_ISSUES_CLAUDE_CMD="$BIN/claude-stub"
  export RUN_ISSUES_ENV_FILE="$ENVF"
  # shellcheck disable=SC1090
  . "$ROOT/lib/machine-env.sh"
  # shellcheck disable=SC1090
  . "$LIB"
  source_machine_env
  call_claude "$RUNDIR" "step" "$PROMPT"
) >/dev/null 2>&1
if [ "$(flag_value)" = "$ALT" ]; then
  ok m "machine env file delivers RUN_ISSUES_PRINCIPLES_FILE through to the CLI"
else
  bad m "got '$(flag_value)' (want $ALT) — the env file lost to a source-time default"
fi

[ "$FAIL" -eq 0 ] && echo "principles-delivery: all passed" || echo "principles-delivery: FAILURES"
exit "$FAIL"
