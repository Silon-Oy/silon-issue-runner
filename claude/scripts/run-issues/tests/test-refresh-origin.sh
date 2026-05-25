#!/usr/bin/env bash
# test-refresh-origin.sh — refresh_origin (lib/worktree.sh) fetches origin and
# reports the outcome via its return code so the orchestrator can decide policy
# (fail-fast on a new run, soft on restart/continue). Networkless, deterministic.
#
# Cases:
#   1. No origin remote        -> return 2 (benign no-op, e.g. local-only repo)
#   2. Valid bare origin       -> return 0, and origin/<default> sees the new tip
#   3. Origin -> nonexistent   -> return 1 (fetch ran but failed)
#   4. Side-effect free        -> worktree clean + HEAD unchanged across the call
#
# Run: bash tests/test-refresh-origin.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_LIB="$HERE/../lib/worktree.sh"

# worktree.sh has `set -euo pipefail`; sourcing inherits it. We deliberately
# call refresh_origin with `set +e` below so its return 1/2 do not kill the test.
# shellcheck source=lib/worktree.sh
. "$WORKTREE_LIB"
set +e

WORK=$(mktemp -d -t refresh-origin.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0

git_q() { git -c init.defaultBranch=main -c user.email=t@t -c user.name=t "$@"; }

# ---- Case 1: no origin remote -> return 2 ----
R1="$WORK/case1"
git_q init -q "$R1"
refresh_origin "$R1"
rc=$?
if [ "$rc" -eq 2 ]; then
  echo "PASS: case1 returns 2 (no origin remote)"
else
  echo "FAIL: case1 expected 2, got $rc"; FAIL=1
fi

# ---- Case 2: valid bare origin, fetch succeeds & sees the new tip ----
BARE="$WORK/origin.git"
git_q init -q --bare "$BARE"

# A second clone pushes a commit into the bare repo. After refresh_origin runs
# in our work repo, origin/<default> must see that pushed tip.
PUSHER="$WORK/pusher"
git_q clone -q "$BARE" "$PUSHER"
echo "hello" > "$PUSHER/file.txt"
git_q -C "$PUSHER" add file.txt
git_q -C "$PUSHER" commit -q -m "initial"
DEFBRANCH=$(git_q -C "$PUSHER" symbolic-ref --short HEAD)
git_q -C "$PUSHER" push -q origin "$DEFBRANCH"

R2="$WORK/case2"
git_q clone -q "$BARE" "$R2"   # clones the now-populated bare repo

# Add a SECOND commit to the bare via the pusher, so refresh_origin must fetch
# something new for the assertion to be meaningful.
echo "world" >> "$PUSHER/file.txt"
git_q -C "$PUSHER" commit -aq -m "second"
git_q -C "$PUSHER" push -q origin "$DEFBRANCH"
EXPECTED_TIP=$(git_q -C "$PUSHER" rev-parse HEAD)

refresh_origin "$R2"
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "PASS: case2 returns 0 (fetch ok)"
else
  echo "FAIL: case2 expected 0, got $rc"; FAIL=1
fi
GOT_TIP=$(git_q -C "$R2" rev-parse "origin/$DEFBRANCH" 2>/dev/null)
if [ "$GOT_TIP" = "$EXPECTED_TIP" ]; then
  echo "PASS: case2 origin/$DEFBRANCH advanced to the pushed tip"
else
  echo "FAIL: case2 origin/$DEFBRANCH=$GOT_TIP expected $EXPECTED_TIP"; FAIL=1
fi

# ---- Case 4 (uses case2 repo): side-effect free ----
STATUS_BEFORE=$(git_q -C "$R2" status --porcelain)
HEAD_BEFORE=$(git_q -C "$R2" rev-parse HEAD)
refresh_origin "$R2" >/dev/null 2>&1
STATUS_AFTER=$(git_q -C "$R2" status --porcelain)
HEAD_AFTER=$(git_q -C "$R2" rev-parse HEAD)
if [ -z "$STATUS_AFTER" ] && [ "$STATUS_BEFORE" = "$STATUS_AFTER" ]; then
  echo "PASS: case4 working tree clean & unchanged"
else
  echo "FAIL: case4 working tree dirty/changed (before='$STATUS_BEFORE' after='$STATUS_AFTER')"; FAIL=1
fi
if [ "$HEAD_BEFORE" = "$HEAD_AFTER" ]; then
  echo "PASS: case4 HEAD unchanged"
else
  echo "FAIL: case4 HEAD moved ($HEAD_BEFORE -> $HEAD_AFTER)"; FAIL=1
fi

# ---- Case 3: origin points at a nonexistent path -> return 1 ----
R3="$WORK/case3"
git_q init -q "$R3"
git_q -C "$R3" remote add origin "/tmp/nonexistent-refresh-origin-$$/x.git"
refresh_origin "$R3" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 1 ]; then
  echo "PASS: case3 returns 1 (fetch failed, nonexistent origin)"
else
  echo "FAIL: case3 expected 1, got $rc"; FAIL=1
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "refresh-origin: all passed" || echo "refresh-origin: FAILURES"
[ "$FAIL" -eq 0 ]
