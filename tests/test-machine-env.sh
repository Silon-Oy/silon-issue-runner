#!/usr/bin/env bash
# test-machine-env.sh — machine-local env file sourcing with CALLER PRECEDENCE
# (issue #144).
#
# The bug: the env file is hand-written shell full of `export FOO=bar`, and
# `export` beats a command-prefix assignment. Sourcing it therefore overwrote
# whatever the caller had deliberately set. The test suite stubs the agent with
# `RUN_ISSUES_CLAUDE_CMD="$BIN/claude"`, so on a machine whose env file exports
# the real CLI, orchestrate.sh silently ran the REAL claude with a 3600 s
# timeout — measured 2026-08-31, tests/run-all.sh launched live, billed agent
# runs and nothing in the output said so. The same test did two different things
# on two machines.
#
# The rule under test is a NAMESPACE rule, not an exception list: inside
# RUN_ISSUES_* / PR_WATCH_* the caller wins; everything else (secrets, which
# nobody hand-sets) keeps the file-wins delivery semantics the channel exists
# for. An exception list would silently fail to cover the next variable added —
# which is precisely how this survived.
#
# WHEN the snapshot is taken decides what the rule means (issue #200). Cases
# 1-7 source lib/machine-env.sh alone, which is NOT the order the entry points
# use: they load lib/claude-call.sh first, and it assigns
# RUN_ISSUES_CLAUDE_CMD/_MODEL at source time. A snapshot taken inside
# source_machine_env therefore counted the package's own npx default as a caller
# choice and restored it over the env file — measured on two machines as an S0
# failure ("MISSING (required): @anthropic-ai/claude-code") while the env file
# named an installed driver. Cases 8-10 pin the real order and the
# machine_env_capture entry point that fixes it.
#
# Cases Y and Z are the ones that matter: both drive the real orchestrate.sh, Y
# proving the env file's command runs when nobody overrode it, Z proving the
# caller's stub wins when someone did. Neither direction is safe alone — Y alone
# would pass again if #144 were reverted, Z alone passed throughout #200.
#
# Run: bash tests/test-machine-env.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
LIB="$ROOT/lib/machine-env.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }

WORK=$(mktemp -d -t machine-env.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — got '$2', want '$3'"; fi; }

# Every case below states its own inputs, and the "unset variable" cases only
# mean something in an environment that really has them unset. orchestrate.sh
# exports these into the agents it launches, so a run of this suite from inside
# an orchestrated step inherits them and turns cases 3, 8 and 10 red for a reason
# that has nothing to do with the code under test.
unset RUN_ISSUES_CLAUDE_CMD RUN_ISSUES_CLAUDE_MODEL RUN_ISSUES_CLAUDE_TIMEOUT RUN_ISSUES_ENV_FILE

# ---------------------------------------------------------------------------
# Unit cases: source the lib in a subshell per case so leaked globals cannot
# make a later case pass for the wrong reason.
# ---------------------------------------------------------------------------
ENVF="$WORK/env"
cat > "$ENVF" <<'ENVEOF'
export RUN_ISSUES_CLAUDE_CMD=/real/claude
export RUN_ISSUES_CLAUDE_MODEL=real-model
export RUN_ISSUES_ONLY_IN_FILE=from-file
export PR_WATCH_MERGE_LABEL=from-file
export GITHUB_TOKEN=secret-from-file
ENVEOF
chmod 600 "$ENVF"

run_case() {  # <var-to-print> — runs source_machine_env with the current env
  ( . "$LIB" >/dev/null 2>&1; source_machine_env >/dev/null 2>&1; printf '%s' "${!1-<unset>}" )
}

echo "=== Case 1: caller's RUN_ISSUES_* value wins over the file ==="
OUT=$(RUN_ISSUES_ENV_FILE="$ENVF" RUN_ISSUES_CLAUDE_CMD=/stub/claude run_case RUN_ISSUES_CLAUDE_CMD)
check "caller RUN_ISSUES_CLAUDE_CMD survives" "$OUT" "/stub/claude"
OUT=$(RUN_ISSUES_ENV_FILE="$ENVF" RUN_ISSUES_CLAUDE_MODEL=stub-model run_case RUN_ISSUES_CLAUDE_MODEL)
check "caller RUN_ISSUES_CLAUDE_MODEL survives" "$OUT" "stub-model"

echo "=== Case 2: PR_WATCH_* namespace obeys the same rule ==="
OUT=$(RUN_ISSUES_ENV_FILE="$ENVF" PR_WATCH_MERGE_LABEL=from-caller run_case PR_WATCH_MERGE_LABEL)
check "caller PR_WATCH_MERGE_LABEL survives" "$OUT" "from-caller"

echo "=== Case 3: UNSET variable still receives the file's value ==="
# This is the channel's actual purpose. Breaking it would trade one silent
# failure for another: LaunchAgent runs would lose their config.
OUT=$(RUN_ISSUES_ENV_FILE="$ENVF" run_case RUN_ISSUES_CLAUDE_CMD)
check "unset RUN_ISSUES_CLAUDE_CMD takes the file's value" "$OUT" "/real/claude"
OUT=$(RUN_ISSUES_ENV_FILE="$ENVF" run_case RUN_ISSUES_ONLY_IN_FILE)
check "file-only variable is delivered" "$OUT" "from-file"

echo "=== Case 4: outside the namespaces the FILE still wins (secrets) ==="
# Nobody hand-sets GITHUB_TOKEN before invoking the orchestrator, and the file
# exists to deliver exactly this. Extending caller-precedence here would change
# secret delivery, which #144 explicitly scopes out.
OUT=$(RUN_ISSUES_ENV_FILE="$ENVF" GITHUB_TOKEN=from-caller run_case GITHUB_TOKEN)
check "GITHUB_TOKEN keeps file-wins semantics" "$OUT" "secret-from-file"

echo "=== Case 5: set-but-EMPTY counts as SET ==="
OUT=$(RUN_ISSUES_ENV_FILE="$ENVF" RUN_ISSUES_CLAUDE_MODEL="" run_case RUN_ISSUES_CLAUDE_MODEL)
check "empty caller value is not overwritten" "$OUT" ""

echo "=== Case 6: values with spaces and quotes survive the round-trip ==="
# The snapshot goes through eval, so quoting has to hold or a caller value like
# `npx --no-install @anthropic-ai/claude-code` would be silently mangled.
TRICKY='npx --no-install "@scope/pkg" $notavar'
OUT=$(RUN_ISSUES_ENV_FILE="$ENVF" RUN_ISSUES_CLAUDE_CMD="$TRICKY" run_case RUN_ISSUES_CLAUDE_CMD)
check "spaces/quotes/dollars preserved" "$OUT" "$TRICKY"

echo "=== Case 7: absent file is a benign no-op ==="
OUT=$(RUN_ISSUES_ENV_FILE="$WORK/does-not-exist" RUN_ISSUES_CLAUDE_CMD=/stub/claude run_case RUN_ISSUES_CLAUDE_CMD)
check "absent file leaves the caller's value alone" "$OUT" "/stub/claude"
( . "$LIB" >/dev/null 2>&1; RUN_ISSUES_ENV_FILE="$WORK/does-not-exist" source_machine_env >/dev/null 2>&1 )
check "absent file exits 0" "$?" "0"

# ---------------------------------------------------------------------------
# Cases 8-10: the ENTRY POINTS' source order (issue #200).
# ---------------------------------------------------------------------------
CALL_LIB="$ROOT/lib/claude-call.sh"
ENVF2="$WORK/env2"
cat > "$ENVF2" <<'ENVEOF'
export RUN_ISSUES_CLAUDE_CMD=/from/file
export RUN_ISSUES_CLAUDE_MODEL=model-from-file
export RUN_ISSUES_CLAUDE_TIMEOUT=1234
ENVEOF
chmod 600 "$ENVF2"

# The order orchestrate.sh and pr-watch.sh use: capture, THEN load the libraries
# that materialise their own defaults, THEN inject the file.
run_real_order() {  # <var-to-print>
  (
    . "$LIB" >/dev/null 2>&1
    machine_env_capture
    . "$CALL_LIB" >/dev/null 2>&1
    source_machine_env >/dev/null 2>&1
    printf '%s' "${!1-<unset>}"
  )
}

echo "=== Case 8: with capture, the file wins over a library's source-time default ==="
# The regression at unit level. Without machine_env_capture every one of these
# returns claude-call.sh's own default instead of the file's value.
OUT=$(RUN_ISSUES_ENV_FILE="$ENVF2" run_real_order RUN_ISSUES_CLAUDE_CMD)
check "RUN_ISSUES_CLAUDE_CMD comes from the file, not the npx default" "$OUT" "/from/file"
OUT=$(RUN_ISSUES_ENV_FILE="$ENVF2" run_real_order RUN_ISSUES_CLAUDE_MODEL)
check "RUN_ISSUES_CLAUDE_MODEL comes from the file, not the empty default" "$OUT" "model-from-file"
OUT=$(RUN_ISSUES_ENV_FILE="$ENVF2" run_real_order RUN_ISSUES_CLAUDE_TIMEOUT)
check "RUN_ISSUES_CLAUDE_TIMEOUT comes from the file" "$OUT" "1234"

echo "=== Case 9: capture does not weaken caller precedence (#144 must hold) ==="
OUT=$(RUN_ISSUES_ENV_FILE="$ENVF2" RUN_ISSUES_CLAUDE_CMD=/stub/claude run_real_order RUN_ISSUES_CLAUDE_CMD)
check "a real caller value still beats the file in the real order" "$OUT" "/stub/claude"
OUT=$(RUN_ISSUES_ENV_FILE="$ENVF2" RUN_ISSUES_CLAUDE_MODEL="" run_real_order RUN_ISSUES_CLAUDE_MODEL)
check "set-but-empty still counts as SET in the real order" "$OUT" ""

echo "=== Case 10: machine_env_capture is idempotent — the FIRST capture stands ==="
# A second call must not widen the snapshot: whatever the process assigned to
# itself between the two calls is precisely what must not count as the caller's.
OUT=$(
  RUN_ISSUES_ENV_FILE="$ENVF2" bash -c '
    . "$1" >/dev/null 2>&1
    machine_env_capture
    RUN_ISSUES_CLAUDE_CMD=/materialised/by/a/library
    machine_env_capture
    source_machine_env >/dev/null 2>&1
    printf "%s" "$RUN_ISSUES_CLAUDE_CMD"
  ' _ "$LIB"
)
check "second capture does not adopt an in-between assignment" "$OUT" "/from/file"

echo "=== Case 11: without capture, source_machine_env still works (fail-soft) ==="
# source_machine_env is public. A caller that never captures must keep the old
# behaviour rather than losing the precedence rule altogether.
OUT=$(RUN_ISSUES_ENV_FILE="$ENVF2" RUN_ISSUES_CLAUDE_CMD=/stub/claude run_case RUN_ISSUES_CLAUDE_CMD)
check "no capture: caller value still wins" "$OUT" "/stub/claude"
OUT=$(RUN_ISSUES_ENV_FILE="$ENVF2" run_case RUN_ISSUES_CLAUDE_CMD)
check "no capture: unset still receives the file's value" "$OUT" "/from/file"

# ---------------------------------------------------------------------------
echo "=== Case Z: orchestrate.sh runs the CALLER's claude, not the file's ==="
# The regression itself, end to end. A hostile env file exports a command that
# would touch $REAL_MARKER; the caller stubs a command that touches $STUB_MARKER.
# Only the stub may run.
ORCH="$ROOT/orchestrate.sh"
STATE_LIB="$ROOT/lib/state.sh"
# shellcheck source=lib/state.sh
. "$STATE_LIB"
# lib/state.sh declares `set -euo pipefail`, and sourcing it turns -e ON in this
# shell. The suite convention is the opposite (§10: no -e, so a test collects
# every failure instead of dying at the first). Restore it — otherwise the
# orchestrate run below, whose exit 5 is the EXPECTED blocked outcome, would
# abort the test before it can assert anything.
set +e

REPO="$WORK/repo"
git -C "$WORK" init -q repo
( cd "$REPO" && git config user.email t@t && git config user.name t \
  && git symbolic-ref HEAD refs/heads/main \
  && git commit -q --allow-empty -m base \
  && git update-ref refs/remotes/origin/main HEAD )

WT="$WORK/wt"
git -C "$WORK" init -q wt
( cd "$WT" && git config user.email t@t && git config user.name t \
  && git symbolic-ref HEAD refs/heads/main \
  && git commit -q --allow-empty -m base \
  && git update-ref refs/remotes/origin/main HEAD \
  && git commit -q --allow-empty -m "feat: partial work" )

BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$BIN/gh"

STUB_MARKER="$WORK/stub-ran"
REAL_MARKER="$WORK/real-ran"
cat > "$BIN/claude-stub" <<SH
#!/usr/bin/env bash
touch "$STUB_MARKER"
echo "IMPLEMENTER_RESULT: BLOCKED — stub"
exit 0
SH
cat > "$BIN/claude-from-file" <<SH
#!/usr/bin/env bash
touch "$REAL_MARKER"
echo "IMPLEMENTER_RESULT: BLOCKED — file"
exit 0
SH
chmod +x "$BIN/claude-stub" "$BIN/claude-from-file"

HOSTILE="$WORK/hostile-env"
cat > "$HOSTILE" <<SH
export RUN_ISSUES_CLAUDE_CMD=$BIN/claude-from-file
SH
chmod 600 "$HOSTILE"

RID="20260101-0000-issue-7"
RD="$REPO/.claude/run-issues/$RID"
state_init "$RD" "$RID" "$REPO" 7
TMP=$(mktemp)
jq --arg wt "$WT" '.status="timed_out" | .worktree_path=$wt | .branch="main" | .retry_count=0 | .current_state="S8_Implementer"' \
  "$RD/run.json" > "$TMP" && mv "$TMP" "$RD/run.json"

( cd "$REPO" && \
  PATH="$BIN:$PATH" \
  RUN_ISSUES_AUTO=1 \
  RUN_ISSUES_ENV_FILE="$HOSTILE" \
  RUN_ISSUES_CLAUDE_CMD="$BIN/claude-stub" \
  RUN_ISSUES_LOCK_ROOT="$WORK/locks" \
  RUN_ISSUES_SKIP_PREFLIGHT=1 \
  bash "$ORCH" --restart "$RD" ) >/dev/null 2>&1

if [ -e "$REAL_MARKER" ]; then
  fail "Z orchestrate ran the ENV FILE's command — the stub was overridden (the #144 regression)"
else
  pass "Z orchestrate did not run the env file's command"
fi
if [ -e "$STUB_MARKER" ]; then
  pass "Z orchestrate ran the caller's stub"
else
  fail "Z orchestrate ran neither command — the case proves nothing; fix the fixture"
fi

# ---------------------------------------------------------------------------
echo "=== Case Y: orchestrate.sh runs the ENV FILE's claude when nobody overrode it ==="
# The #200 regression, end to end, and the exact scenario measured on two
# machines: ~/.config/run-issues/env names the CLI, the caller names nothing, and
# the run must use the file's driver. Before the fix lib/claude-call.sh's npx
# default was already in the snapshot by the time source_machine_env ran, so the
# file's value was restored away and S0 reported the package missing.
#
# Same fixture as Z with the one variable that matters removed, on its own
# worktree and issue number so Z's finalisation cannot bleed in.
WT_Y="$WORK/wt-y"
git -C "$WORK" init -q wt-y
( cd "$WT_Y" && git config user.email t@t && git config user.name t \
  && git symbolic-ref HEAD refs/heads/main \
  && git commit -q --allow-empty -m base \
  && git update-ref refs/remotes/origin/main HEAD \
  && git commit -q --allow-empty -m "feat: partial work" )

Y_MARKER="$WORK/y-file-ran"
cat > "$BIN/claude-y-from-file" <<SH
#!/usr/bin/env bash
touch "$Y_MARKER"
echo "IMPLEMENTER_RESULT: BLOCKED — file"
exit 0
SH
chmod +x "$BIN/claude-y-from-file"

ENVF_Y="$WORK/env-y"
cat > "$ENVF_Y" <<SH
export RUN_ISSUES_CLAUDE_CMD=$BIN/claude-y-from-file
SH
chmod 600 "$ENVF_Y"

RID_Y="20260101-0000-issue-8"
RD_Y="$REPO/.claude/run-issues/$RID_Y"
state_init "$RD_Y" "$RID_Y" "$REPO" 8
TMP=$(mktemp)
jq --arg wt "$WT_Y" '.status="timed_out" | .worktree_path=$wt | .branch="main" | .retry_count=0 | .current_state="S8_Implementer"' \
  "$RD_Y/run.json" > "$TMP" && mv "$TMP" "$RD_Y/run.json"

# No RUN_ISSUES_CLAUDE_CMD in the invocation — that is the whole point. The
# preflight gate is skipped for the same reason as in Z: this case is about
# which command the implementer launches, not about probing it.
( cd "$REPO" && \
  PATH="$BIN:$PATH" \
  RUN_ISSUES_AUTO=1 \
  RUN_ISSUES_ENV_FILE="$ENVF_Y" \
  RUN_ISSUES_LOCK_ROOT="$WORK/locks" \
  RUN_ISSUES_SKIP_PREFLIGHT=1 \
  bash "$ORCH" --restart "$RD_Y" ) >/dev/null 2>&1

if [ -e "$Y_MARKER" ]; then
  pass "Y orchestrate ran the env file's command"
else
  fail "Y orchestrate did NOT run the env file's command — the machine env file cannot set RUN_ISSUES_CLAUDE_CMD (the #200 regression)"
fi

# ---------------------------------------------------------------------------
echo "=== Case X: every source_machine_env caller captures BEFORE its first other library ==="
# Case Y covers orchestrate.sh behaviourally; pr-watch.sh has no equally cheap
# end-to-end fixture, and the property is positional anyway. Reordering two
# source lines is a one-character-looking edit that reintroduces the whole bug
# silently, so read the order off disk.
#
# Fail-closed in both directions: an entry point that stops sourcing libraries
# through "$SCRIPT_DIR/lib/..." fails here rather than passing on zero matches.
#
# The entry-point set is DERIVED FROM DISK, the way tests/test-jq-binary.sh
# derives its own (CLAUDE.md section 5.8): whoever calls source_machine_env owns
# this property, and a hand-written list would leave the next such caller
# silently uncovered — which is the shape of the bug this case exists for.
ENTRIES=()
while IFS= read -r f; do
  ENTRIES+=("$f")
done < <(cd "$ROOT" && grep -lE '^[^#]*(^|[^[:alnum:]_])source_machine_env([^[:alnum:]_]|$)' \
         ./*.sh 2>/dev/null | sed 's|^\./||' | sort)

# Plausibility floor: the orchestrator and the watcher have both sourced the
# machine env file since #144. A collapse below that means the derivation broke,
# and an empty set must not pass silently.
if [ "${#ENTRIES[@]}" -ge 2 ]; then
  pass "X derived ${#ENTRIES[@]} source_machine_env callers from disk (${ENTRIES[*]})"
else
  fail "X entry-point derivation collapsed to ${#ENTRIES[@]} — the pattern is broken, not the package"
fi

for entry in ${ENTRIES[@]+"${ENTRIES[@]}"}; do
  f="$ROOT/$entry"
  if [ ! -f "$f" ]; then fail "X $entry not found"; continue; fi
  # Only the top-level library-loading section counts: orchestrate.sh's
  # --version branch sources lib/version.sh and exits long before it, so it can
  # never observe an env file. That branch is indented inside an `if`, hence the
  # unindented SCRIPT_DIR assignment as the region marker.
  region=$(grep -nE '^SCRIPT_DIR=' "$f" | tail -1 | cut -d: -f1)
  if [ -z "$region" ]; then
    fail "X $entry has no top-level SCRIPT_DIR assignment — the check cannot locate the library section"
    continue
  fi
  # Line numbers of every `. "$SCRIPT_DIR/lib/x.sh"` / `source "..."`, in order.
  libs=$(grep -nE '^[[:space:]]*(\.|source)[[:space:]]+"\$SCRIPT_DIR/lib/' "$f" \
         | cut -d: -f1 | awk -v r="$region" '$1 > r')
  cap=$(grep -nE '^[[:space:]]*machine_env_capture[[:space:]]*$' "$f" \
        | cut -d: -f1 | awk -v r="$region" '$1 > r' | head -1)
  first=$(printf '%s\n' "$libs" | sed -n 1p)
  second=$(printf '%s\n' "$libs" | sed -n 2p)
  if [ -z "$first" ] || [ -z "$second" ]; then
    fail "X $entry: found fewer than two \$SCRIPT_DIR/lib sources — the check cannot conclude anything; fix the pattern"
    continue
  fi
  if [ -z "$cap" ]; then
    fail "X $entry never calls machine_env_capture — the caller snapshot degrades to whatever the libraries have already assigned themselves"
    continue
  fi
  first_lib=$(sed -n "${first}p" "$f")
  case "$first_lib" in
    *"lib/machine-env.sh"*) : ;;
    *) fail "X $entry loads another library before lib/machine-env.sh (line $first: $first_lib)"; continue ;;
  esac
  if [ "$cap" -lt "$second" ]; then
    pass "X $entry captures at line $cap, before its next library at line $second"
  else
    fail "X $entry calls machine_env_capture at line $cap, AFTER a library load at line $second — that library's \${VAR:-default} is now inside the snapshot"
  fi
done

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "machine-env: all passed" || echo "machine-env: FAILURES"
[ "$FAIL" -eq 0 ]
