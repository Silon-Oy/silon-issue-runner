#!/usr/bin/env bash
# test-cleanup-lock-name.sh — cleanup-run.sh removes the SAME lock dir that
# lock_issue created (issue-N.lock), not the legacy hand-built issue-N path.
#
# Regression guard for the lock-name bug: lock_issue (lib/locking.sh) creates
# `<root>/issue-<N>.lock`, but cleanup-run.sh used to remove `<root>/issue-<N>`
# (no .lock suffix), leaving the real lock behind and blocking the next run.
#
# We point RUN_ISSUES_LOCK_ROOT at a temp dir, acquire a lock with the real
# lock_issue, run cleanup-run.sh --issue N --yes with a stubbed gh, then assert
# the lock dir is gone.
#
# Run: bash tests/test-cleanup-lock-name.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP="$HERE/../cleanup-run.sh"
STATE_LIB="$HERE/../lib/state.sh"
LOCKING_LIB="$HERE/../lib/locking.sh"

WORK=$(mktemp -d -t cleanup-lock.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
mkdir -p "$REPO/.git"

export RUN_ISSUES_LOCK_ROOT="$WORK/locks"

# Acquire a real lock for issue 77 so we have something to remove.
# shellcheck source=lib/locking.sh
. "$LOCKING_LIB"
lock_issue 77 || { echo "FAIL: could not acquire test lock"; exit 1; }

LOCK_DIR="$RUN_ISSUES_LOCK_ROOT/issue-77.lock"
[ -d "$LOCK_DIR" ] || { echo "FAIL: lock dir not created at $LOCK_DIR"; exit 1; }

# Create a non-completed run for issue 77 so cleanup has a run to tear down.
# shellcheck source=lib/state.sh
. "$STATE_LIB"
RID="20260521-0077-issue-77"
RD="$REPO/.claude/run-issues/$RID"
state_init "$RD" "$RID" "$REPO" 77
state_finalize "$RD" "blocked"

# Stub gh so the issue-edit calls in cleanup_run are no-ops (no network).
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

FAIL=0
RUN_ISSUES_LOCK_ROOT="$RUN_ISSUES_LOCK_ROOT" \
  bash "$CLEANUP" --repo "$REPO" --issue 77 --yes >/dev/null 2>&1 \
  || { echo "FAIL: cleanup-run.sh exited non-zero"; FAIL=1; }

if [ -d "$LOCK_DIR" ]; then
  echo "FAIL: lock dir still present after cleanup: $LOCK_DIR"
  FAIL=1
else
  echo "PASS: lock dir issue-77.lock removed"
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "cleanup-lock-name: all passed" || echo "cleanup-lock-name: FAILURES"
[ "$FAIL" -eq 0 ]
