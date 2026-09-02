#!/usr/bin/env bash
# test-principles-delivery.sh — the always-on system prompt reaches every
# orchestrated claude call deterministically: the coding standard (issue #175)
# and the RUN_ISSUES_AUTO=1 operating contract (issue #176).
#
# WHAT THIS PINS. Before #175 `call_claude` passed the CLI no system prompt at
# all, and only prompts/01-cycle-review.md injected anything (the TARGET repo's
# CLAUDE.md — a different document, deliberately kept). S8, S9 and the PR
# watcher's two agents therefore inherited the coding standard only from
# whichever machine happened to have it in user-level memory. #176 moved the
# operating contract in on the same channel, out of prompts/02-implementer.md
# (where it reached one step) and out of the operator's own user-level memory
# (where it reached no machine but theirs). The delivery channel is the CLI flag,
# so the assertions here are about the ARGV the CLI actually receives — a stubbed
# RUN_ISSUES_CLAUDE_CMD records it. No real agent is ever launched (CLAUDE.md §5.5).
#
# TWO DOCUMENTS, ONE FLAG. The flag takes a single file, so call_claude
# concatenates contract + standard into <run-dir>/<step-id>.system-prompt.md.
# The asymmetry is the point and most of what is asserted below: the standard is
# overridable (RUN_ISSUES_PRINCIPLES_FILE, .claude/run-issues.json) and
# opt-out-able (empty value); the contract is NEITHER, because a target repo must
# not be able to drop the runner's own operating boundaries. Every override case
# below therefore checks that the contract is still in the delivered bytes.
#
# WHY THE UNREADABLE-PATH CASES MATTER. Measured against claude CLI 2.1.257:
# `--append-system-prompt-file /does/not/exist` aborts the process with
# "Error: Append system prompt file not found" BEFORE the agent starts. The flag
# is fail-closed, so one typo'd config key would otherwise kill every step of
# every run. (d) and (i) are that guard.
#
# Cases:
#   (a) nothing configured -> flag present, delivering contract + the packaged
#       principles/coding.md.
#   (b) RUN_ISSUES_PRINCIPLES_FILE set to another readable file -> that wins for
#       the standard half; the contract half is unchanged.
#   (c) RUN_ISSUES_PRINCIPLES_FILE set to EMPTY -> the standard is dropped, the
#       contract alone is delivered. "Unset" and "set to empty" must stay
#       distinguishable, and the opt-out must NOT reach the contract.
#   (d) RUN_ISSUES_PRINCIPLES_FILE set to a missing path -> warning + packaged
#       default; rc is the agent's own, the run does NOT die.
#   (e) .claude/run-issues.json principles_file (relative) -> resolved against
#       the repo root and delivered.
#   (f) absolute principles_file in run-issues.json -> used verbatim.
#   (g) environment beats the repo config, including the empty opt-out.
#   (h) absent file / absent key / broken JSON -> benign no-op (packaged
#       default), never an error.
#   (i) nothing configured and BOTH packaged pages missing -> no flag, no crash.
#   (j) a run-dir containing a space survives as ONE argv element (the reason the
#       flag is built as an array and not word-split like model_flag).
#   (k) structural: every orchestrated step routes through call_claude, so all
#       five call sites are covered by one seam.
#   (l) sourcing lib/claude-call.sh leaves RUN_ISSUES_PRINCIPLES_FILE UNSET.
#   (m) an `export RUN_ISSUES_PRINCIPLES_FILE=...` in the machine env file
#       reaches the CLI.
#   (n) packaged contract missing but the standard present -> the standard alone,
#       plus a warning. Degradation is per document, not all-or-nothing.
#   (o) run-dir not writable -> the CONTRACT alone (never nothing), plus a
#       warning. The non-overridable half is the one worth saving.
#   (p) structural: the contract text lives in exactly one file in the package.
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
CONTRACT="$ROOT/principles/auto-run-contract.md"

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

# COMBINED — where call_claude writes the concatenation for the fixed run-dir /
# step-id these cases use. Asserting the exact path (not just the content) is
# what pins the file next to the step's .out/.exit, where it stays re-readable
# for debugging.
COMBINED="$RUNDIR/step.system-prompt.md"

# want_combined <principles-file> — the delivered file IS the concatenation of
# the packaged contract and <principles-file>, byte for byte. A content diff
# rather than a path comparison, because after #176 the argv path is a generated
# file: comparing paths would assert nothing about what the agent actually reads.
want_combined() {
  local got; got=$(flag_value)
  if [ "$got" != "$COMBINED" ]; then
    printf 'flag=%s (want %s)' "$got" "$COMBINED"
    return 1
  fi
  if ! diff -q <(cat "$CONTRACT"; printf '\n'; cat "$1") "$COMBINED" >/dev/null 2>&1; then
    printf 'delivered bytes are not contract + %s' "$1"
    return 1
  fi
  return 0
}

# ===========================================================================
# (a) nothing configured -> packaged standard
# ===========================================================================
RC=$(invoke)
if [ "$RC" != "0" ]; then
  bad a "call_claude returned $RC (want 0)"
elif ! has_flag; then
  bad a "no --append-system-prompt-file in argv"
elif ! why=$(want_combined "$PACKAGED"); then
  bad a "$why"
else
  ok a "default -> contract + packaged principles/coding.md, in that order"
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
if why=$(want_combined "$ALT"); then
  ok b "RUN_ISSUES_PRINCIPLES_FILE overrides the standard, contract survives"
else
  bad b "$why"
fi

# ===========================================================================
# (c) empty = opt out entirely
# ===========================================================================
RC=$(invoke "export RUN_ISSUES_PRINCIPLES_FILE=''")
if [ "$RC" != "0" ]; then
  bad c "call_claude returned $RC (want 0)"
elif [ "$(flag_value)" != "$CONTRACT" ]; then
  bad c "got '$(flag_value)' (want the contract alone, $CONTRACT) — the opt-out must reach the standard only"
elif [ -e "$COMBINED" ] && diff -q "$COMBINED" "$CONTRACT" >/dev/null 2>&1; then
  bad c "wrote a needless concatenation for a single document"
else
  ok c "empty value -> standard dropped, contract still delivered"
fi
rm -f "$COMBINED"

# ===========================================================================
# (d) unreadable override -> warn + packaged default, run survives
# ===========================================================================
RC=$(invoke "export RUN_ISSUES_PRINCIPLES_FILE='$WORK/nope.md'")
if [ "$RC" != "0" ]; then
  bad d "call_claude returned $RC — an unreadable override must not fail the run"
elif ! why=$(want_combined "$PACKAGED"); then
  bad d "$why"
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
if why=$(want_combined "$REPO/standard.md"); then
  ok e "relative principles_file resolved against the repo root, contract survives"
else
  bad e "$why"
fi

echo "{\"principles_file\":\"$ALT\"}" > "$REPO/.claude/run-issues.json"
repo_invoke >/dev/null
if why=$(want_combined "$ALT"); then
  ok f "absolute principles_file used verbatim"
else
  bad f "$why"
fi

# environment beats repo config...
echo '{"principles_file":"standard.md"}' > "$REPO/.claude/run-issues.json"
repo_invoke "export RUN_ISSUES_PRINCIPLES_FILE='$ALT'" >/dev/null
if why=$(want_combined "$ALT"); then
  ok g1 "environment beats repo config"
else
  bad g1 "$why"
fi
# ...including the empty opt-out, which the repo must not silently undo — and
# which still must not reach the contract.
repo_invoke "export RUN_ISSUES_PRINCIPLES_FILE=''" >/dev/null
if [ "$(flag_value)" = "$CONTRACT" ]; then
  ok g2 "empty environment opt-out survives a repo principles_file; contract stays"
else
  bad g2 "got '$(flag_value)' (want $CONTRACT)"
fi
rm -f "$COMBINED"

# absent key / broken JSON / absent file -> benign no-op (CLAUDE.md §9: missing
# configuration is a default, never an error)
H_OK=1
echo '{"claude_timeout_seconds":2700}' > "$REPO/.claude/run-issues.json"
repo_invoke >/dev/null
why=$(want_combined "$PACKAGED") || { bad h1 "absent key: $why"; H_OK=0; }
echo '{not json' > "$REPO/.claude/run-issues.json"
RC=$(repo_invoke)
[ "$RC" = "0" ] || { bad h2 "broken JSON returned $RC"; H_OK=0; }
why=$(want_combined "$PACKAGED") || { bad h2 "broken JSON: $why"; H_OK=0; }
rm -f "$REPO/.claude/run-issues.json"
repo_invoke >/dev/null
why=$(want_combined "$PACKAGED") || { bad h3 "absent config: $why"; H_OK=0; }
[ "$H_OK" = "1" ] && ok h "absent key / broken JSON / absent config -> packaged default, no error"

# ===========================================================================
# (i) BOTH packaged pages missing -> drop the flag rather than feed the CLI a
#     path it is documented to reject
# ===========================================================================
# A real broken installation — the module in a package root that has no
# principles/ — rather than poking the internal default variables. The paths are
# derived from BASH_SOURCE, so copying the lib is enough to reproduce it.
BROKEN_ROOT="$WORK/broken-pkg"
BROKEN="$BROKEN_ROOT/lib"; mkdir -p "$BROKEN"
cp "$LIB" "$ROOT/lib/preflight.sh" "$BROKEN/"

broken_invoke() {  # runs the copied module, whose package root is $BROKEN_ROOT
  local rc=0
  (
    set -euo pipefail
    export RUN_ISSUES_CLAUDE_CMD="$BIN/claude-stub"
    # shellcheck disable=SC1090
    . "$BROKEN/claude-call.sh"
    call_claude "$RUNDIR" "step" "$PROMPT"
  ) 2> "$WORK/stderr.txt" || rc=$?
  printf '%s' "$rc"
}

RC=$(broken_invoke)
if [ "$RC" != "0" ]; then
  bad i "call_claude returned $RC — missing packaged pages must not fail the run"
elif has_flag; then
  bad i "passed a non-existent path to the CLI (which aborts on it)"
elif ! grep -q 'packaged coding standard missing' "$WORK/stderr.txt"; then
  bad i "dropped the standard silently"
elif ! grep -q 'packaged operating contract missing' "$WORK/stderr.txt"; then
  bad i "dropped the contract silently"
else
  ok i "both packaged pages missing -> no flag + two warnings, run survives"
fi

# ===========================================================================
# (n) contract missing, standard present -> the standard alone
# ===========================================================================
# Degradation is PER DOCUMENT. An all-or-nothing fallback would mean one absent
# file silently costs the agent the other one too.
mkdir -p "$BROKEN_ROOT/principles"
cp "$PACKAGED" "$BROKEN_ROOT/principles/coding.md"
RC=$(broken_invoke)
if [ "$RC" != "0" ]; then
  bad n "call_claude returned $RC"
elif [ "$(flag_value)" != "$BROKEN_ROOT/principles/coding.md" ]; then
  bad n "got '$(flag_value)' (want the standard alone)"
elif ! grep -q 'packaged operating contract missing' "$WORK/stderr.txt"; then
  bad n "dropped the contract silently"
else
  ok n "contract missing -> standard alone + warning, not nothing"
fi

# ===========================================================================
# (j) a path with a space stays ONE argv element
# ===========================================================================
# Both halves are exercised: the run-dir (which the generated file inherits, and
# which an operator may well keep under a spaced directory) and the override.
SPACED_RUN="$WORK/with space/run"; mkdir -p "$SPACED_RUN"
SPACED="$WORK/with space/std.md"; printf 'spaced\n' > "$SPACED"
(
  set -euo pipefail
  export RUN_ISSUES_CLAUDE_CMD="$BIN/claude-stub"
  export RUN_ISSUES_PRINCIPLES_FILE="$SPACED"
  # shellcheck disable=SC1090
  . "$LIB"
  call_claude "$SPACED_RUN" "step" "$PROMPT"
) >/dev/null 2>&1
if [ "$(flag_value)" = "$SPACED_RUN/step.system-prompt.md" ]; then
  ok j "spaced run-dir and spaced override survive as one argument"
else
  bad j "got '$(flag_value)' (want $SPACED_RUN/step.system-prompt.md) — the flag is being word-split"
fi

# ===========================================================================
# (o) run-dir not writable -> the CONTRACT alone, never nothing
# ===========================================================================
# The contract is the half that cannot be recovered from anywhere else: a target
# repo can ship a standard, nothing ships the runner's own boundaries.
# The run-dir itself must stay writable — call_claude also writes .out and .exit
# there, so a wholly read-only run-dir would be a different (and unrecoverable)
# failure. Blocking exactly the concatenation target isolates this branch.
RO="$WORK/blocked-run"; mkdir -p "$RO/step.system-prompt.md"
RC=$(
  rc=0
  (
    set -euo pipefail
    export RUN_ISSUES_CLAUDE_CMD="$BIN/claude-stub"
    # shellcheck disable=SC1090
    . "$LIB"
    call_claude "$RO" "step" "$PROMPT"
  ) 2> "$WORK/stderr.txt" || rc=$?
  printf '%s' "$rc"
)
if [ "$RC" != "0" ]; then
  bad o "call_claude returned $RC — an unwritable system-prompt path must not fail the run"
elif [ "$(flag_value)" != "$CONTRACT" ]; then
  bad o "got '$(flag_value)' (want $CONTRACT)"
elif ! grep -q 'could not write' "$WORK/stderr.txt"; then
  bad o "degraded silently"
else
  ok o "unwritable run-dir -> contract alone + warning"
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
if why=$(want_combined "$ALT"); then
  ok m "machine env file delivers RUN_ISSUES_PRINCIPLES_FILE through to the CLI"
else
  bad m "$why — the env file lost to a source-time default"
fi

# ===========================================================================
# (p) the contract text exists in exactly ONE file in the package
# ===========================================================================
# The whole point of #176 was collapsing three parallel wordings (the implementer
# prompt, README §7.3's copy-me block and the operator's own user-level memory)
# into one. A second copy would not fail anything else in this suite, and would
# drift the moment either side is edited. Anchors are distinctive full sentences
# from the contract rather than single words, so an ordinary paraphrase
# elsewhere in the docs does not trip this.
CONTRACT_ANCHORS=(
  'Saat siis tehdä muutoksia ilman erillistä lupakyselyä.'
  'voittaa jokaisen ohjeen, joka vaatii kysymään luvan ennen muutosta'
)
dupes=""
for anchor in "${CONTRACT_ANCHORS[@]}"; do
  while IFS= read -r f; do
    case "$f" in
      "$CONTRACT"|"$HERE"/*) continue ;;   # the source, and this guard itself
    esac
    dupes="$dupes $f"
  done < <(grep -rlF -- "$anchor" "$ROOT" --exclude-dir=.git 2>/dev/null || true)
done
if [ -n "$dupes" ]; then
  bad p "the contract wording is duplicated outside principles/auto-run-contract.md:$dupes"
else
  ok p "the contract wording lives in exactly one file"
fi

[ "$FAIL" -eq 0 ] && echo "principles-delivery: all passed" || echo "principles-delivery: FAILURES"
exit "$FAIL"
