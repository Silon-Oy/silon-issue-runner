#!/usr/bin/env bash
# test-preflight-gate.sh — the S0 dependency gate in orchestrate.sh (issue #7).
#
# The invariant: a missing dependency must be reported AS a missing dependency,
# before the run has taken a lock, claimed the issue or created a run dir. Until
# the gate existed, an absent claude CLI surfaced as "the implementer got stuck"
# — a diagnosis pointing at the wrong subsystem, posted on the issue after the
# side effects had already happened.
#
# Cases:
#   B1  overridden RUN_ISSUES_CLAUDE_CMD that does not exist -> exit 8 + fix cmd
#   B2  gh present but not authenticated -> exit 8 + `gh auth login`
#   B3  default (npx) claude command whose package is absent (npx exits 127) —
#       the production failure mode that `command -v npx` cannot see
#   C   after B1-B3: no run dir, no lock, no worktree, no issue assignment
#   B4  a complete environment -> the gate is transparent: S0 passes and the run
#       proceeds into phase_a. `poll` is no longer a mode (issue #99 made a named
#       issue REQUIRED), so it is now rejected in S1 as a usage error (exit 1) —
#       but AFTER S0 has run and logged, with no lock/claim/run-dir side effects.
#       That still proves the gate did not block a healthy environment.
#   B5  RUN_ISSUES_SKIP_PREFLIGHT=1 bypasses the gate even when claude is broken
#   B6  GitHub App mode downgrades the missing personal login to a warning
#   B7  a Read-only token (permissions.push=false) is fatal at S0 (exit 8),
#       before any claim/worktree, and the message names the Write role and who
#       grants it (issue #256)
#   B8  an unreadable permissions response is fail-closed — fatal at S0, not a
#       silent pass (issue #256)
#   B9  RUN_ISSUES_SKIP_REPO_WRITE_CHECK=1 bypasses the write probe even when the
#       token lacks push
#
# B1 also pins the counterpart of the probe/have split: an overridden claude
# command must be tested for existence only, never executed. Executing it would
# make the gate fire calls the caller never asked for — the concrete regression
# that a naive `$RUN_ISSUES_CLAUDE_CMD --version` caused in the mocked runs of
# test-clarification-loop-cap.sh and test-restart-budget.sh.
#
# Offline and machine-independent: gh, npx and the claude CLI are PATH stubs,
# HOME is a throwaway dir (so the machine-local env file is never sourced) and
# the lock root is redirected into the work dir.
#
# Run: bash tests/test-preflight-gate.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$HERE/../orchestrate.sh"

WORK=$(mktemp -d -t preflight-gate.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
ok()   { echo "PASS $1"; }
bad()  { echo "FAIL $1"; FAIL=1; }

BIN="$WORK/bin"
mkdir -p "$BIN"
GH_LOG="$WORK/gh.log"
: > "$GH_LOG"

# gh stub: records argv, answers `auth token` with $GH_AUTH_RC (so a test can
# simulate a machine that never ran `gh auth login`), answers `api repos/…` with
# the repo write-access probe's `.permissions.push` value (GH_PERM: true|false,
# or "error" to fail the call — the fail-closed case) and returns an empty issue
# list otherwise, i.e. "no candidate".
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_LOG"
if [ "\${1:-}" = "auth" ] && [ "\${2:-}" = "token" ]; then
  [ "\${GH_AUTH_RC:-0}" = "0" ] && printf 'gho_stubtoken\n'
  exit "\${GH_AUTH_RC:-0}"
fi
if [ "\${1:-}" = "api" ]; then
  case "\${GH_PERM:-true}" in
    error) exit 1 ;;
    *) printf '%s\n' "\${GH_PERM:-true}" ;;
  esac
  exit 0
fi
exit 0
SH
chmod +x "$BIN/gh"

# A working claude CLI and a working npx (individual cases override npx).
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/claude"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/npx"
chmod +x "$BIN/claude" "$BIN/npx"

npx_exits() {  # npx_exits <code>
  printf '#!/usr/bin/env bash\nexit %s\n' "$1" > "$BIN/npx"
  chmod +x "$BIN/npx"
}

# The target repo. orchestrate.sh requires a .git dir. A parseable github.com
# origin is added so the S0 repo write-access probe (issue #256) can resolve an
# owner/repo slug and query the stubbed `gh api repos/…`; without it the probe
# is skipped (a repo with no github remote fails later at issue fetch anyway).
REPO="$WORK/repo"
git init -q "$REPO"
git -C "$REPO" remote add origin https://github.com/example-org/app.git
# Force `main` regardless of the machine's init.defaultBranch.
git -C "$REPO" symbolic-ref HEAD refs/heads/main

export HOME="$WORK/home"
mkdir -p "$HOME"
export PATH="$BIN:$PATH"
export RUN_ISSUES_LOCK_ROOT="$WORK/locks"
export RUN_ISSUES_AUTO=1

RC=0
ERR="$WORK/err.txt"
run_orch() {  # run_orch <args...> — records rc in $RC and stderr in $ERR
  "$ORCH" "$@" >/dev/null 2>"$ERR"
  RC=$?
}

says() {  # says <needle> <tag>
  if grep -qF -- "$1" "$ERR"; then
    ok "$2"
  else
    bad "$2 — stderr was: $(tr '\n' '|' < "$ERR")"
  fi
}

rc_is() {  # rc_is <expected> <tag>
  if [ "$RC" -eq "$1" ]; then
    ok "$2"
  else
    bad "$2 — expected exit $1, got $RC"
  fi
}

rc_is_not() {  # rc_is_not <unexpected> <tag>
  if [ "$RC" -ne "$1" ]; then
    ok "$2"
  else
    bad "$2 — exit $RC was not supposed to happen"
  fi
}

# --- B1: an overridden claude command that does not exist ------------------
export RUN_ISSUES_CLAUDE_CMD="$WORK/no-such-claude"
run_orch "$REPO" 42
rc_is 8 "B1 missing claude CLI exits 8"
says 'npm i -g @anthropic-ai/claude-code' "B1 names the fix command"
says 'nothing was locked, claimed or created' "B1 states that no work started"

# --- B2: gh present but not authenticated ---------------------------------
export RUN_ISSUES_CLAUDE_CMD="$BIN/claude"
GH_AUTH_RC=1 run_orch "$REPO" 42
rc_is 8 "B2 unauthenticated gh exits 8"
says 'gh auth login' "B2 names the fix command"

# --- B3: default npx invocation, package not installed --------------------
# The package-missing case: npx itself resolves, so only running it reveals the
# failure. This is the exact chain that used to end in a wrong issue comment.
unset RUN_ISSUES_CLAUDE_CMD
npx_exits 127
run_orch "$REPO" 42
rc_is 8 "B3 default command with a missing package exits 8"
says '@anthropic-ai/claude-code' "B3 names the missing package"
npx_exits 0

# --- C: a failed gate leaves nothing behind -------------------------------
if [ -d "$REPO/.claude/run-issues" ]; then
  bad "C a failed gate created a run dir"
else
  ok "C no run dir was created"
fi
if [ -d "$RUN_ISSUES_LOCK_ROOT" ] && [ -n "$(ls -A "$RUN_ISSUES_LOCK_ROOT" 2>/dev/null)" ]; then
  bad "C a failed gate left a lock: $(ls -A "$RUN_ISSUES_LOCK_ROOT")"
else
  ok "C no lock was taken"
fi
wt_count=$(git -C "$REPO" worktree list | wc -l | tr -d ' ')
if [ "$wt_count" = "1" ]; then
  ok "C no worktree was created"
else
  bad "C worktree list has $wt_count entries"
fi
if grep -qE -- '--add-assignee|issue edit' "$GH_LOG"; then
  bad "C the issue was claimed: $(grep -E -- '--add-assignee|issue edit' "$GH_LOG")"
else
  ok "C the issue was never claimed"
fi

# --- B4: a complete environment — the gate must be transparent ------------
# `poll` is now a S1 usage error (exit 1), but it only fires AFTER S0 passed, so
# the gate is still proven transparent by the 'S0_Preflight ok' log line and the
# absence of any run-dir side effect.
export RUN_ISSUES_CLAUDE_CMD="$BIN/claude"
run_orch "$REPO" poll
rc_is 1 "B4 a healthy environment passes S0 and reaches phase_a (poll rejected in S1)"
says 'S0_Preflight ok' "B4 the gate reports itself once"
if [ -d "$REPO/.claude/run-issues" ]; then
  bad "B4 poll rejection created a run dir"
else
  ok "B4 poll rejection created no run dir"
fi

# --- B5: the escape hatch -------------------------------------------------
# The gate must never be the reason a machine cannot start a run: a broken
# claude command plus RUN_ISSUES_SKIP_PREFLIGHT=1 reaches the normal flow (and
# then hits the S1 poll rejection, exit 1 — again, after the gate was skipped).
export RUN_ISSUES_CLAUDE_CMD="$WORK/no-such-claude"
RUN_ISSUES_SKIP_PREFLIGHT=1 run_orch "$REPO" poll
rc_is 1 "B5 RUN_ISSUES_SKIP_PREFLIGHT=1 bypasses the gate"
says 'S0_Preflight skipped' "B5 the bypass is logged"

# --- B6: GitHub App mode downgrades the gh-auth finding -------------------
# In App mode the runs authenticate with an installation token, so a missing
# personal login must not be fatal.
export RUN_ISSUES_CLAUDE_CMD="$BIN/claude"
PEM="$WORK/app.pem"
printf 'not-a-real-key\n' > "$PEM"
chmod 600 "$PEM"
GH_AUTH_RC=1 \
RUN_ISSUES_GITHUB_APP_ID=1 \
RUN_ISSUES_GITHUB_APP_INSTALLATION_ID=2 \
RUN_ISSUES_GITHUB_APP_PRIVATE_KEY_PATH="$PEM" \
  run_orch "$REPO" poll
rc_is_not 8 "B6 App mode does not make a missing personal login fatal"
says 'WARNING' "B6 the finding is reported as a warning"
says 'gh auth login' "B6 the warning still carries the fix command"

# --- B7: a Read-only token is fatal at S0 (issue #256) --------------------
# The token authenticates (gh auth token ok) but lacks push. Until this gate
# existed the run reached S3/S10 and failed there, after the issue was reserved
# or a worktree built. Now it must refuse at S0, before any side effect.
export RUN_ISSUES_CLAUDE_CMD="$BIN/claude"
: > "$GH_LOG"
GH_PERM=false run_orch "$REPO" 42
rc_is 8 "B7 a Read-only token exits 8"
says 'Write (push)' "B7 names the missing Write role"
says 'organization owner or a repository admin' "B7 names who grants it"
says 'nothing was locked, claimed or created' "B7 states that no work started"
if grep -qE -- '--add-assignee|issue edit|--add-label' "$GH_LOG"; then
  bad "B7 the issue was reserved/claimed: $(grep -E -- '--add-assignee|issue edit|--add-label' "$GH_LOG")"
else
  ok "B7 the issue was never reserved or claimed"
fi
if [ -d "$REPO/.claude/run-issues" ]; then
  bad "B7 a failed write probe created a run dir"
else
  ok "B7 no run dir was created"
fi

# --- B8: an unreadable permissions response is fail-closed ----------------
# A network error / SSO block / missing repo must not read as "can write".
GH_PERM=error run_orch "$REPO" 42
rc_is 8 "B8 an unreadable permissions response exits 8 (fail-closed)"
says 'refusing fail-closed' "B8 names the fail-closed refusal"

# --- B9: the write-probe escape hatch -------------------------------------
# The probe must never be the reason a working machine cannot start: a
# Read-only stub plus the skip flag reaches the normal flow (then the S1 poll
# rejection, exit 1 — after the probe was skipped).
GH_PERM=false RUN_ISSUES_SKIP_REPO_WRITE_CHECK=1 run_orch "$REPO" poll
rc_is 1 "B9 RUN_ISSUES_SKIP_REPO_WRITE_CHECK=1 bypasses the write probe"
says 'S0_Preflight ok' "B9 the gate still passes"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "preflight-gate: all passed" || echo "preflight-gate: FAILURES"
[ "$FAIL" -eq 0 ]
