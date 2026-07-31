#!/usr/bin/env bash
# test-pr-watch-host-gate.sh — P9 cross-machine cleanup gate.
#
# A completed run whose run.json.host != this host must merge but NOT clean
# locally; pr-watch.sh must print an ssh hint instead and record
# cleanup_done with db_dropped=na.
#
# `gh` is mocked via a PATH shim so no network/GitHub is touched. The mock
# reports a green, labelled, mergeable PR and a successful merge.
#
# Run: bash tests/test-pr-watch-host-gate.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRWATCH="$HERE/../pr-watch.sh"
STATE_LIB="$HERE/../lib/state.sh"

WORK=$(mktemp -d -t prwatch-host.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
git -C "$WORK" init -q "repo"

# --- gh mock -------------------------------------------------------------
BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
# Minimal gh mock for pr-watch host-gate test.
case "$1 $2" in
  "pr view")
    cat <<'JSON'
{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN",
 "labels":[{"name":"auto-merge"}],"statusCheckRollup":[],"headRefName":"feature/x"}
JSON
    ;;
  "pr merge")
    echo "merged (mock)"
    ;;
  *)
    exit 0
    ;;
esac
SH
chmod +x "$BIN/gh"

# --- a completed run.json with a FOREIGN host ----------------------------
RID="20260521-1200-issue-77"
RD="$REPO/.claude/run-issues/$RID"
# shellcheck source=../lib/state.sh
. "$STATE_LIB"
state_init "$RD" "$RID" "$REPO" "77"
state_set "$RD" "pr_url" "https://github.com/Silon-Oy/dotfiles/pull/777"
# Force a host that is NOT this machine.
tmp=$(mktemp); jq '.host = "some-other-host"' "$RD/run.json" > "$tmp"; mv "$tmp" "$RD/run.json"
state_finalize "$RD" "completed"

# --- run pr-watch with mocked gh; lock root isolated to this test --------
export PATH="$BIN:$PATH"
export RUN_ISSUES_LOCK_ROOT="$WORK/locks"
export PR_WATCH_ENABLE_CONFLICT_RESOLUTION=0

set +e
OUT=$( "$PRWATCH" "$REPO" 777 2>&1 )
RC=$?
set -e
echo "--- pr-watch output ---"
echo "$OUT"
echo "--- (rc=$RC) ---"

FAIL=0
[ "$RC" = "0" ] || { echo "FAIL expected rc 0, got $RC"; FAIL=1; }
echo "$OUT" | grep -q "NOT cleaning locally" || { echo "FAIL missing 'NOT cleaning locally'"; FAIL=1; }
echo "$OUT" | grep -q "ssh some-other-host" || { echo "FAIL missing ssh hint"; FAIL=1; }
# run-dir must still exist (no local cleanup).
[ -d "$RD" ] || { echo "FAIL run-dir was removed despite foreign host"; FAIL=1; }
# state must show merged + cleanup_done db_dropped=na.
grep -q '"event":"pr_merged"' "$RD/state.jsonl" || { echo "FAIL no pr_merged event"; FAIL=1; }
grep -q '"db_dropped":"na"' "$RD/state.jsonl"   || { echo "FAIL no db_dropped=na"; FAIL=1; }
[ "$(jq -r '.status' "$RD/run.json")" = "merged" ] || { echo "FAIL status not merged"; FAIL=1; }

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "pr-watch-host-gate: all passed" || echo "pr-watch-host-gate: FAILURES"
[ "$FAIL" -eq 0 ]
