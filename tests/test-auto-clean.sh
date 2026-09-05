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
#   C completed     — completed run, no pr_url → unresolved state → fail-closed
#                     → exit 4, auto-clean-skipped added, auto-clean NOT removed
#   D no run-dirs   — exit 5 (cross-machine), auto-clean-skipped added
#   E cleanup fail  — cleanup rc=1 → exit 6
#   G completed+MERGED — completed run whose PR is MERGED → cleaned normally:
#                     exit 0, cleanup-run --force, issue closed, auto-clean removed
#   H completed+OPEN — completed run whose PR is OPEN → exit 4, skipped added,
#                     no teardown, issue NOT closed (live PR protected)
#   I completed+CLOSED — PR CLOSED (not merged) → cleaned like MERGED (exit 0)
#   J mixed states  — one MERGED + one OPEN completed run → the OPEN one blocks:
#                     exit 4, no teardown
#   K–O --dry-run   — every terminating path (0, 4, 5, 6, 3) under --dry-run:
#                     the exit code is unchanged, nothing is written to GitHub,
#                     and the lock root is left exactly as it was found
#                     (issue #142)
#
# Every case also asserts the lock state, not just the exit code: a leaked lock
# is invisible in rc but blocks the next real teardown for RUN_ISSUES_LOCK_STALE_SECS.
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
# 'gh pr view <url> --json state --jq ...' is how auto-clean.sh resolves a
# completed run's PR merge-state (issue #116). The mock echoes a per-PR state
# read from env MOCK_PR_STATE_<num> (num = last path segment of the URL), falling
# back to MOCK_PR_STATE, then empty. Empty means "unresolved" — the fail-closed
# path — which is exactly what the pre-#116 cases (no pr_url) exercise.
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
# stub: mimic the real cleanup-run.sh closely enough for the lock assertions.
#
# Two fidelity points, both load-bearing (issue #142):
#   1. It removes the lock under the SAME name the caller acquired. The real
#      script derives it from the run's identity (repo slug + remote); a stub
#      that hard-codes the legacy issue-N.lock name would leave every
#      repo-namespaced lock standing and make the assertions below meaningless.
#      (No backticks anywhere in this heredoc: it is unquoted, so they would be
#      command substitutions evaluated while the stub is written.)
#   2. Under --dry-run it removes NOTHING. That is the real script's behaviour,
#      and it is precisely what makes auto-clean's own dry-run leak observable:
#      the success path does not unlock itself, it relies on this teardown.
repo=""; issue=""; remote="origin"; dry=0
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --repo)    repo="\$2"; shift 2 ;;
    --issue)   issue="\$2"; shift 2 ;;
    --remote)  remote="\$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    *) shift ;;
  esac
done
if [ "\$dry" = "0" ] && [ -n "\$issue" ]; then
  # Subshell: locking.sh sets -e, which must not escape into this stub.
  (
    . "$REAL_SCRIPTS/lib/locking.sh"
    unlock_issue "\$issue" "\$remote"
    slug=\$(repo_slug "\$repo" "\$remote")
    if [ -n "\$slug" ]; then unlock_issue "\$issue" "\$remote" "\$slug"; fi
  ) || true
fi
echo "cleanup-run --issue \$issue dry=\$dry" >> "$CALLS"
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

mk_run_pr() {  # <repo> <issue> <status> <pr-num> [<suffix>]
  # Like mk_run but records a pr_url whose last path segment is <pr-num>, so the
  # gh mock resolves its state from MOCK_PR_STATE_<pr-num> (issue #116).
  local repo="$1" n="$2" status="$3" prnum="$4" suffix="${5:-a}"
  local rid="20260521-00${n}${suffix}-issue-$n"
  local rd="$repo/.claude/run-issues/$rid"
  state_init "$rd" "$rid" "$repo" "$n"
  state_set "$rd" "pr_url" "https://github.com/acme/repo/pull/$prnum"
  state_finalize "$rd" "$status"
}

run_ac() {  # <cleanup-rc> <repo> <issue> [extra auto-clean args…] -> sets RC, resets CALLS
  local rc="$1" repo="$2" issue="$3"; shift 3
  : > "$CALLS"
  local sd; sd=$(make_scriptdir "$rc")
  set +e
  RUN_ISSUES_LOCK_ROOT="$RUN_ISSUES_LOCK_ROOT" \
    bash "$sd/auto-clean.sh" --repo "$repo" --issue "$issue" "$@" >/dev/null 2>&1
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

# ---- lock-state assertions (issue #142) ----
# Every terminating path of auto-clean must leave the lock root exactly as it
# found it: the run's own lock released, a foreign lock untouched. The leak this
# guards against was invisible from the exit code — rc=0 while the lock stayed,
# so the very teardown the preview was rehearsing then refused with rc=3.
list_locks() {  # one lock dir name per line; empty when the root is clean
  local d
  shopt -s nullglob
  for d in "$RUN_ISSUES_LOCK_ROOT"/*.lock; do basename "$d"; done
  shopt -u nullglob
}
expect_no_locks() {  # <label>
  local got; got=$(list_locks)
  if [ -z "$got" ]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 — lock(s) left behind: $(echo "$got" | tr '\n' ' ')"; FAIL=1
  fi
}
expect_only_lock() {  # <lock-dir-name> <label>
  local got; got=$(list_locks)
  if [ "$got" = "$1" ]; then
    echo "PASS: $2"
  else
    echo "FAIL: $2 — want only '$1', got: $(echo "$got" | tr '\n' ' ')"; FAIL=1
  fi
}

echo "=== Case A: success ==="
R=$(mk_repo); mk_run "$R" 11 "blocked"
run_ac 0 "$R" 11
expect_rc 0 "A success exit 0"
expect_call "issue close 11" "A closes issue"
expect_call "labels/auto-clean" "A removes auto-clean label"
expect_no_locks "A releases the lock"

echo "=== Case B: lock held ==="
R=$(mk_repo); mk_run "$R" 12 "blocked"
lock_issue 12   # pre-acquire so auto-clean cannot get it
run_ac 0 "$R" 12
expect_rc 3 "B lock-held exit 3"
expect_nocall "cleanup-run --issue 12" "B does not run cleanup"
expect_nocall "issue close 12" "B does not close issue"
expect_only_lock "issue-12.lock" "B leaves the foreign lock untouched"
unlock_issue 12

echo "=== Case C: all completed ==="
R=$(mk_repo); mk_run "$R" 13 "completed"
run_ac 0 "$R" 13
expect_rc 4 "C all-completed exit 4"
expect_call "labels[]=auto-clean-skipped" "C adds auto-clean-skipped"
expect_nocall "labels/auto-clean" "C does NOT remove auto-clean"
expect_nocall "issue close 13" "C does not close issue"
expect_no_locks "C releases the lock"

echo "=== Case F: mixed (1 completed + 1 non-completed) ==="
# A completed run coexisting with a non-completed one must still refuse — here
# the completed run has no pr_url, so its PR state is unresolved → fail-closed.
R=$(mk_repo)
mk_run "$R" 16 "completed" "a"
mk_run "$R" 16 "blocked"   "b"
run_ac 0 "$R" 16
expect_rc 4 "F mixed exit 4 (completed w/o pr_url → fail-closed)"
expect_call "labels[]=auto-clean-skipped" "F adds auto-clean-skipped"
expect_nocall "labels/auto-clean" "F does NOT remove auto-clean"
expect_nocall "cleanup-run --issue 16" "F does NOT run teardown"
expect_nocall "issue close 16" "F does not close issue"
expect_no_locks "F releases the lock"

echo "=== Case G: completed + MERGED PR (issue #116) ==="
# A completed run whose PR is already merged must be cleaned normally, not
# refused — the bug this change fixes.
R=$(mk_repo); mk_run_pr "$R" 17 "completed" 201
MOCK_PR_STATE_201=MERGED run_ac 0 "$R" 17
expect_rc 0 "G merged-PR exit 0"
expect_call "cleanup-run --issue 17" "G runs teardown"
expect_call "issue close 17" "G closes issue"
expect_call "labels/auto-clean" "G removes auto-clean label"
expect_nocall "labels[]=auto-clean-skipped" "G does NOT add skipped label"
expect_no_locks "G releases the lock"

echo "=== Case H: completed + OPEN PR ==="
# A genuinely open PR still earns the precaution.
R=$(mk_repo); mk_run_pr "$R" 18 "completed" 202
MOCK_PR_STATE_202=OPEN run_ac 0 "$R" 18
expect_rc 4 "H open-PR exit 4"
expect_call "labels[]=auto-clean-skipped" "H adds auto-clean-skipped"
expect_nocall "cleanup-run --issue 18" "H does NOT run teardown"
expect_nocall "issue close 18" "H does not close issue"
expect_nocall "labels/auto-clean" "H does NOT remove auto-clean"
expect_no_locks "H releases the lock"

echo "=== Case I: completed + CLOSED (unmerged) PR ==="
# A closed-but-not-merged PR is also non-open → nothing to orphan → clean.
R=$(mk_repo); mk_run_pr "$R" 19 "completed" 203
MOCK_PR_STATE_203=CLOSED run_ac 0 "$R" 19
expect_rc 0 "I closed-PR exit 0"
expect_call "cleanup-run --issue 19" "I runs teardown"
expect_call "issue close 19" "I closes issue"
expect_no_locks "I releases the lock"

echo "=== Case J: mixed PR states (one MERGED + one OPEN) ==="
# The single open PR must block the whole issue even though a sibling merged.
R=$(mk_repo)
mk_run_pr "$R" 20 "completed" 204 "a"
mk_run_pr "$R" 20 "completed" 205 "b"
MOCK_PR_STATE_204=MERGED MOCK_PR_STATE_205=OPEN run_ac 0 "$R" 20
expect_rc 4 "J mixed-states exit 4 (open blocks)"
expect_call "labels[]=auto-clean-skipped" "J adds auto-clean-skipped"
expect_nocall "cleanup-run --issue 20" "J does NOT run teardown"
expect_no_locks "J releases the lock"

echo "=== Case D: no run-dirs (cross-machine) ==="
R=$(mk_repo)   # no runs at all
run_ac 0 "$R" 14
expect_rc 5 "D no-rundirs exit 5"
expect_call "labels[]=auto-clean-skipped" "D adds auto-clean-skipped"
expect_nocall "issue close 14" "D does not close issue"
expect_no_locks "D releases the lock"

echo "=== Case E: cleanup fails ==="
R=$(mk_repo); mk_run "$R" 15 "blocked"
run_ac 1 "$R" 15
expect_rc 6 "E cleanup-fail exit 6"
expect_nocall "issue close 15" "E does not close issue"
expect_no_locks "E releases the lock"

echo "=== Case K: --dry-run success path leaves no lock (issue #142) ==="
# The success path deliberately does not unlock itself: in a real run
# cleanup-run.sh has already removed the lock. Under --dry-run cleanup-run.sh
# removes nothing, so the preview has to release its own lock — otherwise it
# leaves the state change it exists to avoid, and the real teardown it was
# previewing refuses with rc=3 until the lock goes stale.
R=$(mk_repo); mk_run "$R" 21 "blocked"
run_ac 0 "$R" 21 --dry-run
expect_rc 0 "K dry-run success exit 0"
expect_call "cleanup-run --issue 21 dry=1" "K passes --dry-run through to cleanup-run"
expect_nocall "issue close 21" "K does not close issue"
expect_nocall "labels/auto-clean" "K does not remove the auto-clean label"
expect_no_locks "K releases the lock"

echo "=== Case L: --dry-run open/unresolved PR refusal leaves no lock ==="
R=$(mk_repo); mk_run_pr "$R" 22 "completed" 206
MOCK_PR_STATE_206=OPEN run_ac 0 "$R" 22 --dry-run
expect_rc 4 "L dry-run open-PR exit 4"
expect_nocall "cleanup-run --issue 22" "L does NOT run teardown"
expect_nocall "labels[]=auto-clean-skipped" "L does not add the skipped label"
expect_no_locks "L releases the lock"

echo "=== Case M: --dry-run no-run-dirs refusal leaves no lock ==="
R=$(mk_repo)   # no runs at all
run_ac 0 "$R" 23 --dry-run
expect_rc 5 "M dry-run no-rundirs exit 5"
expect_nocall "labels[]=auto-clean-skipped" "M does not add the skipped label"
expect_no_locks "M releases the lock"

echo "=== Case N: --dry-run teardown failure leaves no lock ==="
R=$(mk_repo); mk_run "$R" 24 "blocked"
run_ac 1 "$R" 24 --dry-run
expect_rc 6 "N dry-run cleanup-fail exit 6"
expect_no_locks "N releases the lock"

echo "=== Case O: --dry-run does not touch a foreign lock ==="
# A preview must never release a lock it did not take: the run holding it is
# alive, and stealing it would be a far worse state change than leaking one.
R=$(mk_repo); mk_run "$R" 25 "blocked"
lock_issue 25
run_ac 0 "$R" 25 --dry-run
expect_rc 3 "O dry-run lock-held exit 3"
expect_nocall "cleanup-run --issue 25" "O does not run cleanup"
expect_only_lock "issue-25.lock" "O leaves the foreign lock untouched"
unlock_issue 25

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "auto-clean: all passed" || echo "auto-clean: FAILURES"
[ "$FAIL" -eq 0 ]
