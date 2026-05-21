#!/usr/bin/env bash
# test-auto-clean.sh — auto-clean.sh exit-code matrix, fully offline.
#
# Mocks (via a PATH-front bin dir):
#   gh            — close/edit/comment/label are no-ops that append the verb +
#                   args to $CALLS so we can assert which gh calls were made.
#   cleanup-run.sh — NOT a PATH binary; auto-clean.sh invokes it by absolute
#                   path ($SCRIPT_DIR/cleanup-run.sh). We cannot PATH-stub it,
#                   so instead we point auto-clean.sh at a temp SCRIPT_DIR copy
#                   whose cleanup-run.sh is a stub that exits with $CLEANUP_RC
#                   and removes the lock (mimicking the real teardown).
#
# Cases:
#   A success      — non-completed run, cleanup rc=0 → exit 0, gh close + remove-label
#   B lock held    — lock pre-acquired → exit 3, no cleanup, no close
#   C completed     — only completed runs → exit 4, auto-clean-skipped added,
#                     auto-clean NOT removed
#   D no run-dirs   — exit 5 (cross-machine), auto-clean-skipped added
#   E cleanup fail  — cleanup rc=1 → exit 6
#
# Run: bash tests/test-auto-clean.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_SCRIPTS="$HERE/.."
STATE_LIB="$REAL_SCRIPTS/lib/state.sh"

WORK=$(mktemp -d -t auto-clean.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

export RUN_ISSUES_LOCK_ROOT="$WORK/locks"
CALLS="$WORK/gh-calls.log"

# shellcheck source=lib/state.sh
. "$STATE_LIB"
# shellcheck source=lib/locking.sh
. "$REAL_SCRIPTS/lib/locking.sh"

# ---- mock gh on PATH ----
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
echo "gh \$*" >> "$CALLS"
# 'gh issue comment ... --body-file -' reads stdin; drain it so the pipe in
# comment_issue does not SIGPIPE the producer.
case "\$*" in
  *"--body-file -"*) cat >/dev/null 2>&1 || true ;;
esac
exit 0
SH
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# ---- a SCRIPT_DIR clone whose cleanup-run.sh is a controllable stub ----
# auto-clean.sh resolves cleanup-run.sh as "$SCRIPT_DIR/cleanup-run.sh" and the
# libs as "$SCRIPT_DIR/lib/*". We build a fake script dir that symlinks the real
# auto-clean.sh + lib, but provides a stub cleanup-run.sh.
make_scriptdir() {  # <cleanup-rc> -> prints path to the fake script dir
  local rc="$1"
  local sd="$WORK/sd-$rc-$RANDOM"
  mkdir -p "$sd"
  ln -s "$REAL_SCRIPTS/auto-clean.sh" "$sd/auto-clean.sh"
  ln -s "$REAL_SCRIPTS/lib" "$sd/lib"
  cat > "$sd/cleanup-run.sh" <<SH
#!/usr/bin/env bash
# stub: parse --issue, remove the lock like the real teardown does, exit $rc
issue=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --issue) issue="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "\$issue" ] && [ -n "\${RUN_ISSUES_LOCK_ROOT:-}" ]; then
  rm -rf "\$RUN_ISSUES_LOCK_ROOT/issue-\$issue.lock"
fi
echo "cleanup-run --issue \$issue" >> "$CALLS"
exit $rc
SH
  chmod +x "$sd/cleanup-run.sh"
  printf '%s' "$sd"
}

mk_repo() {  # fresh repo dir
  local r="$WORK/repo-$RANDOM"
  mkdir -p "$r/.git"
  printf '%s' "$r"
}

mk_run() {  # <repo> <issue> <status> [<suffix>]
  # suffix lets a single issue have multiple distinct run-dirs (mixed case).
  local repo="$1" n="$2" status="$3" suffix="${4:-a}"
  local rid="20260521-00${n}${suffix}-issue-$n"
  local rd="$repo/.claude/run-issues/$rid"
  state_init "$rd" "$rid" "$repo" "$n"
  state_finalize "$rd" "$status"
}

run_ac() {  # <cleanup-rc> <repo> <issue> -> sets RC, resets CALLS
  local rc="$1" repo="$2" issue="$3"
  : > "$CALLS"
  local sd; sd=$(make_scriptdir "$rc")
  set +e
  RUN_ISSUES_LOCK_ROOT="$RUN_ISSUES_LOCK_ROOT" \
    bash "$sd/auto-clean.sh" --repo "$repo" --issue "$issue" >/dev/null 2>&1
  RC=$?
  set -e
}

FAIL=0
expect_rc() {  # <want> <label>
  if [ "$RC" = "$1" ]; then echo "PASS: $2 (rc=$RC)"; else echo "FAIL: $2 — want rc=$1 got $RC"; FAIL=1; fi
}
calls_have()    { grep -q -- "$1" "$CALLS"; }
expect_call()   { if calls_have "$1"; then echo "PASS: $2"; else echo "FAIL: $2 — '$1' not in calls"; FAIL=1; fi; }
expect_nocall() { if calls_have "$1"; then echo "FAIL: $2 — '$1' WAS called"; FAIL=1; else echo "PASS: $2"; fi; }

echo "=== Case A: success ==="
R=$(mk_repo); mk_run "$R" 11 "blocked"
run_ac 0 "$R" 11
expect_rc 0 "A success exit 0"
expect_call "issue close 11" "A closes issue"
expect_call "remove-label auto-clean" "A removes auto-clean label"

echo "=== Case B: lock held ==="
R=$(mk_repo); mk_run "$R" 12 "blocked"
lock_issue 12   # pre-acquire so auto-clean cannot get it
run_ac 0 "$R" 12
expect_rc 3 "B lock-held exit 3"
expect_nocall "cleanup-run --issue 12" "B does not run cleanup"
expect_nocall "issue close 12" "B does not close issue"
unlock_issue 12

echo "=== Case C: all completed ==="
R=$(mk_repo); mk_run "$R" 13 "completed"
run_ac 0 "$R" 13
expect_rc 4 "C all-completed exit 4"
expect_call "add-label auto-clean-skipped" "C adds auto-clean-skipped"
expect_nocall "remove-label auto-clean " "C does NOT remove auto-clean"
expect_nocall "issue close 13" "C does not close issue"

echo "=== Case F: mixed (1 completed + 1 non-completed) ==="
# completed > 0 must short-circuit to exit 4 even though a non-completed run
# also exists — the completed run likely has an open PR we must not orphan.
R=$(mk_repo)
mk_run "$R" 16 "completed" "a"
mk_run "$R" 16 "blocked"   "b"
run_ac 0 "$R" 16
expect_rc 4 "F mixed exit 4 (completed>0 short-circuits)"
expect_call "add-label auto-clean-skipped" "F adds auto-clean-skipped"
expect_nocall "remove-label auto-clean " "F does NOT remove auto-clean"
expect_nocall "cleanup-run --issue 16" "F does NOT run teardown"
expect_nocall "issue close 16" "F does not close issue"

echo "=== Case D: no run-dirs (cross-machine) ==="
R=$(mk_repo)   # no runs at all
run_ac 0 "$R" 14
expect_rc 5 "D no-rundirs exit 5"
expect_call "add-label auto-clean-skipped" "D adds auto-clean-skipped"
expect_nocall "issue close 14" "D does not close issue"

echo "=== Case E: cleanup fails ==="
R=$(mk_repo); mk_run "$R" 15 "blocked"
run_ac 1 "$R" 15
expect_rc 6 "E cleanup-fail exit 6"
expect_nocall "issue close 15" "E does not close issue"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "auto-clean: all passed" || echo "auto-clean: FAILURES"
[ "$FAIL" -eq 0 ]
