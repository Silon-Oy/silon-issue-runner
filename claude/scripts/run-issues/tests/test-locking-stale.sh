#!/usr/bin/env bash
# test-locking-stale.sh — lock_issue staleness branch (issue #66):
# portable mtime read + conservative fallback.
#
# Two guarantees:
#   1. When the lock dir mtime is readable and genuinely older than
#      RUN_ISSUES_LOCK_STALE_SECS, the stale lock is stolen (re-acquired).
#   2. When `stat` fails for ANY reason, lock_issue does NOT steal the lock —
#      it returns 1 (someone else holds it) and leaves the lock dir intact.
#      A `stat` stub on PATH forces the failure.
#
# Both cases run in subshells because locking.sh enables `set -euo pipefail`.
#
# Run: bash tests/test-locking-stale.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCKING_LIB="$HERE/../lib/locking.sh"

FAIL=0

# ---- Case 1: readable, genuinely-old mtime → steal allowed ----
WORK1=$(mktemp -d -t locking-stale.XXXXXX)
(
  export RUN_ISSUES_LOCK_ROOT="$WORK1/locks"
  export RUN_ISSUES_LOCK_STALE_SECS=1
  # shellcheck source=../lib/locking.sh
  . "$LOCKING_LIB"
  lock_issue 88 || { echo "FAIL(1): initial acquire failed"; exit 1; }
  dir="$RUN_ISSUES_LOCK_ROOT/issue-88.lock"
  # Age the lock far into the past so its mtime is older than STALE_SECS.
  touch -t 202001010000 "$dir"
  # A second run finds the existing (now genuinely stale) lock and steals it.
  if lock_issue 88; then
    echo "PASS(1): genuinely-old lock stolen"
  else
    echo "FAIL(1): old lock not stolen"; exit 1
  fi
) || FAIL=1
rm -rf "$WORK1"

# ---- Case 2: stat fails → conservative, no steal ----
WORK2=$(mktemp -d -t locking-stale.XXXXXX)
(
  export RUN_ISSUES_LOCK_ROOT="$WORK2/locks"
  export RUN_ISSUES_LOCK_STALE_SECS=1
  # Stub `stat` on PATH so the mtime read always fails, regardless of platform.
  BIN="$WORK2/bin"; mkdir -p "$BIN"
  cat > "$BIN/stat" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$BIN/stat"
  export PATH="$BIN:$PATH"
  # shellcheck source=../lib/locking.sh
  . "$LOCKING_LIB"
  lock_issue 99 || { echo "FAIL(2): initial acquire failed"; exit 1; }
  dir="$RUN_ISSUES_LOCK_ROOT/issue-99.lock"
  # Age it too: it WOULD be stolen as stale if stat worked — proving the
  # conservative fallback (not the age check) is what protects the lock.
  touch -t 202001010000 "$dir"
  if lock_issue 99; then
    echo "FAIL(2): stole lock despite stat failure"; exit 1
  else
    echo "PASS(2): stat failure → lock preserved"
  fi
  [ -d "$dir" ] || { echo "FAIL(2): lock dir vanished after failed steal"; exit 1; }
) || FAIL=1
rm -rf "$WORK2"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "locking-stale: all passed" || echo "locking-stale: FAILURES"
[ "$FAIL" -eq 0 ]
