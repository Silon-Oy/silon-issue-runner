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
# Case Z is the one that matters: it drives the real orchestrate.sh with a
# hostile env file and proves the stub, not the file's command, was executed.
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

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "machine-env: all passed" || echo "machine-env: FAILURES"
[ "$FAIL" -eq 0 ]
