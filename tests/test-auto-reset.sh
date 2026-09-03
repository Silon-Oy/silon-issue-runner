#!/usr/bin/env bash
# test-auto-reset.sh — auto-reset.sh exit-code matrix, fully offline.
#
# auto-reset shares every safety gate with auto-clean (lib/teardown.sh), so this
# file does NOT re-prove the gate logic case by case — tests/test-auto-clean.sh
# owns that, and duplicating it would just make the shared layer look like two
# things. What it proves is the part that is auto-reset's OWN: the same gates
# reached through the reset verb still refuse in the same places, and the success
# path ends differently — the issue is NOT closed, and it is left in the state
# pickup wants.
#
# The mocks mirror test-auto-clean.sh:
#   gh            — every verb is a no-op that appends itself to $CALLS.
#                   'gh pr view' answers from MOCK_PR_STATE_<num>.
#   cleanup-run.sh — invoked by absolute path ($SCRIPT_DIR/cleanup-run.sh), so it
#                   cannot be PATH-stubbed. Instead auto-reset.sh runs from a temp
#                   SCRIPT_DIR that symlinks the real script + lib and provides a
#                   stub cleanup-run.sh exiting with $CLEANUP_RC.
#
# Cases:
#   A success        — non-completed run, cleanup rc=0 → exit 0, teardown ran,
#                      auto-reset removed, issue NOT closed
#   B lock held      — lock pre-acquired → exit 3, no teardown, no comment
#   C no run-dirs    — exit 5 (cross-machine), auto-reset-skipped added,
#                      auto-reset NOT removed
#   D completed+OPEN — a live PR still earns the precaution → exit 4, skipped
#                      added, no teardown (a reset would produce a SECOND PR)
#   E completed+MERGED — nothing left to orphan → torn down with --force, exit 0,
#                      issue still NOT closed
#   F cleanup fails  — cleanup rc=1 → exit 6, no label removed
#   G skipped labels are per-verb — auto-reset writes auto-reset-skipped, never
#                      auto-clean-skipped; the two loop guards must not collide
#
# Run: bash tests/test-auto-reset.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_SCRIPTS="$HERE/.."
STATE_LIB="$REAL_SCRIPTS/lib/state.sh"

WORK=$(mktemp -d -t auto-reset.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

export RUN_ISSUES_LOCK_ROOT="$WORK/locks"
CALLS="$WORK/gh-calls.log"

# shellcheck source=lib/state.sh
. "$STATE_LIB"
# shellcheck source=lib/locking.sh
. "$REAL_SCRIPTS/lib/locking.sh"

# ---- mock gh on PATH ----
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
echo "gh $*" >> "__CALLS__"
case "$1 $2" in
  "pr view")
    url="$3"; num="${url##*/}"
    var="MOCK_PR_STATE_${num}"
    printf '%s\n' "${!var:-${MOCK_PR_STATE:-}}"
    exit 0
    ;;
esac
# 'gh issue comment ... --body-file -' reads stdin; drain it so the pipe in
# comment_issue does not SIGPIPE the producer.
case "$*" in
  *"--body-file -"*) cat >/dev/null 2>&1 || true ;;
esac
exit 0
SH
sed -i.bak "s#__CALLS__#$CALLS#" "$BIN/gh" && rm -f "$BIN/gh.bak"
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# ---- a SCRIPT_DIR clone whose cleanup-run.sh is a controllable stub ----
# The stub records its FULL argv as well as the issue, so --force (which the
# merged-PR path must pass or cleanup-run.sh would skip the completed run-dir)
# is assertable rather than assumed.
ARGV="$WORK/cleanup-argv.log"

make_scriptdir() {  # <cleanup-rc> -> prints path to the fake script dir
  local rc="$1"
  local sd="$WORK/sd-$rc-$RANDOM"
  mkdir -p "$sd"
  ln -s "$REAL_SCRIPTS/auto-reset.sh" "$sd/auto-reset.sh"
  ln -s "$REAL_SCRIPTS/lib" "$sd/lib"
  cat > "$sd/cleanup-run.sh" <<SH
#!/usr/bin/env bash
# stub: record the argv, remove the lock like the real teardown does, exit $rc
printf '%s\n' "\$*" >> "$ARGV"
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
  local repo="$1" n="$2" status="$3" suffix="${4:-a}"
  local rid="20260521-00${n}${suffix}-issue-$n"
  local rd="$repo/.claude/run-issues/$rid"
  state_init "$rd" "$rid" "$repo" "$n"
  state_finalize "$rd" "$status"
}

mk_run_pr() {  # <repo> <issue> <status> <pr-num> [<suffix>]
  local repo="$1" n="$2" status="$3" prnum="$4" suffix="${5:-a}"
  local rid="20260521-00${n}${suffix}-issue-$n"
  local rd="$repo/.claude/run-issues/$rid"
  state_init "$rd" "$rid" "$repo" "$n"
  state_set "$rd" "pr_url" "https://github.com/acme/repo/pull/$prnum"
  state_finalize "$rd" "$status"
}

run_ar() {  # <cleanup-rc> <repo> <issue> -> sets RC, resets the ledgers
  local rc="$1" repo="$2" issue="$3"
  : > "$CALLS"; : > "$ARGV"
  local sd; sd=$(make_scriptdir "$rc")
  set +e
  RUN_ISSUES_LOCK_ROOT="$RUN_ISSUES_LOCK_ROOT" \
    bash "$sd/auto-reset.sh" --repo "$repo" --issue "$issue" >/dev/null 2>&1
  RC=$?
  set -e
}

FAIL=0
expect_rc() {  # <want> <label>
  if [ "$RC" = "$1" ]; then echo "PASS: $2 (rc=$RC)"; else echo "FAIL: $2 — want rc=$1 got $RC"; FAIL=1; fi
}
calls_have()    { grep -qF -- "$1" "$CALLS"; }
expect_call()   { if calls_have "$1"; then echo "PASS: $2"; else echo "FAIL: $2 — '$1' not in calls"; FAIL=1; fi; }
expect_nocall() { if calls_have "$1"; then echo "FAIL: $2 — '$1' WAS called"; FAIL=1; else echo "PASS: $2"; fi; }

echo "=== Case A: success — torn down, issue left OPEN ==="
R=$(mk_repo); mk_run "$R" 11 "blocked"
run_ar 0 "$R" 11
expect_rc 0 "A success exit 0"
expect_call "cleanup-run --issue 11" "A runs teardown"
expect_call "labels/auto-reset" "A removes the auto-reset label last"
# THE case this whole verb exists for: no close. cleanup-run.sh has already
# dropped the assignment and the auto-claimed / needs-human labels, so an open,
# unlabelled issue is exactly what pickup takes next tick.
expect_nocall "issue close 11" "A does NOT close the issue"
expect_nocall "issue reopen" "A does not reopen anything either"
expect_nocall "labels[]=auto-reset-skipped" "A does NOT add the skipped label"

echo "=== Case B: lock held by a live run ==="
R=$(mk_repo); mk_run "$R" 12 "blocked"
lock_issue 12   # pre-acquire so auto-reset cannot get it
run_ar 0 "$R" 12
expect_rc 3 "B lock-held exit 3"
expect_nocall "cleanup-run --issue 12" "B does not run teardown"
expect_nocall "labels" "B writes no label at all"
unlock_issue 12

echo "=== Case C: no local run-dirs (cross-machine) ==="
R=$(mk_repo)   # no runs at all
run_ar 0 "$R" 13
expect_rc 5 "C no-rundirs exit 5"
expect_call "labels[]=auto-reset-skipped" "C adds auto-reset-skipped"
expect_nocall "labels/auto-reset" "C does NOT remove auto-reset"
expect_nocall "issue close 13" "C does not close the issue"

echo "=== Case D: completed run with an OPEN PR ==="
# Fail-closed: resetting would release the issue back into pickup and produce a
# SECOND PR on top of the live one.
R=$(mk_repo); mk_run_pr "$R" 14 "completed" 301
MOCK_PR_STATE_301=OPEN run_ar 0 "$R" 14
expect_rc 4 "D open-PR exit 4"
expect_call "labels[]=auto-reset-skipped" "D adds auto-reset-skipped"
expect_nocall "cleanup-run --issue 14" "D does NOT run teardown"
expect_nocall "labels/auto-reset" "D does NOT remove auto-reset"

echo "=== Case D2: completed run with NO pr_url (unresolvable) ==="
# The same fail-closed branch, reached the other way: an unresolvable state must
# never be mistaken for 'merged'.
R=$(mk_repo); mk_run "$R" 15 "completed"
run_ar 0 "$R" 15
expect_rc 4 "D2 unresolved-PR exit 4"
expect_nocall "cleanup-run --issue 15" "D2 does NOT run teardown"

echo "=== Case E: completed run whose PR is MERGED ==="
R=$(mk_repo); mk_run_pr "$R" 16 "completed" 302
MOCK_PR_STATE_302=MERGED run_ar 0 "$R" 16
expect_rc 0 "E merged-PR exit 0"
expect_call "cleanup-run --issue 16" "E runs teardown"
if grep -qF -- "--force" "$ARGV"; then
  echo "PASS: E passes --force so the completed run-dir is included"
else echo "FAIL: E did not pass --force — cleanup-run.sh would skip the completed run"; FAIL=1; fi
expect_nocall "issue close 16" "E still does NOT close the issue"

echo "=== Case F: cleanup-run.sh fails ==="
R=$(mk_repo); mk_run "$R" 17 "blocked"
run_ar 1 "$R" 17
expect_rc 6 "F cleanup-fail exit 6"
expect_nocall "labels/auto-reset" "F does NOT remove auto-reset (stays in the scan)"
expect_nocall "issue close 17" "F does not close the issue"

echo "=== Case G: the loop guards are per-verb ==="
# auto-reset must never write auto-clean's guard, or a failed reset would
# suppress a later clean (and vice versa). Re-uses case C's terminal branch.
R=$(mk_repo)
run_ar 0 "$R" 18
expect_call "labels[]=auto-reset-skipped" "G writes its own skipped label"
expect_nocall "auto-clean-skipped" "G never writes auto-clean's skipped label"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "auto-reset: all passed" || echo "auto-reset: FAILURES"
[ "$FAIL" -eq 0 ]
