#!/usr/bin/env bash
# test-pr-watch-close-issue.sh — explicit linked-issue close on non-default base.
#
# Two layers, both network-free and deterministic:
#
#  1. Pure unit: lib/pr-watch-lib.sh:should_close_linked_issue selection matrix
#     (base==default -> no close; base!=default -> close; empty args -> fail-safe
#     no close).
#
#  2. Integration: pr-watch.sh with a mocked `gh` (PATH shim). Asserts that the
#     watcher, AFTER a successful merge and BEFORE the P9 host gate, closes the
#     linked issue via `gh issue close` iff the merged PR's base is NOT the repo
#     default branch. Covers: non-default base -> close; default base -> no
#     close; empty issue_number -> no close; cross-machine run (foreign host)
#     -> close still happens (remote op precedes the host gate).
#
# Run: bash tests/test-pr-watch-close-issue.sh   (exit 0 = all pass)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pr-watch-lib.sh
. "$HERE/../lib/pr-watch-lib.sh"
PRWATCH="$HERE/../pr-watch.sh"
STATE_LIB="$HERE/../lib/state.sh"

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Layer 1: pure decision function
# ---------------------------------------------------------------------------
echo "--- should_close_linked_issue: pure selection matrix ---"

# assert_rc <name> <expected-rc> <base> <default>
assert_rc() {
  local name="$1" want="$2" base="$3" def="$4" got
  if should_close_linked_issue "$base" "$def"; then got=0; else got=1; fi
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1)); printf 'PASS  %-42s -> rc=%s\n' "$name" "$got"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL  %-42s -> rc=%s expected=%s\n' "$name" "$got" "$want"
  fi
}

assert_rc "base!=default -> close"        0 "twenty" "main"
assert_rc "base==default -> no close"     1 "main"   "main"
assert_rc "empty base -> fail-safe skip"  1 ""       "main"
assert_rc "empty default -> fail-safe"    1 "twenty" ""
assert_rc "both empty -> fail-safe skip"  1 ""       ""

# ---------------------------------------------------------------------------
# Layer 2: integration through pr-watch.sh with a mocked gh
# ---------------------------------------------------------------------------
echo "--- pr-watch.sh integration: explicit close placement ---"

# run_case <name> <base-ref> <default-branch> <issue-num|-> <host> <expect-close>
# <issue-num> "-" means: run.json has a null issue_number (no linked issue).
# <host> "self" means this host; anything else forces a foreign host.
run_case() {
  local name="$1" base="$2" def="$3" issue="$4" host="$5" expect_close="$6"

  local WORK; WORK=$(mktemp -d -t prwatch-close.XXXXXX)
  local REPO="$WORK/repo"
  git -C "$WORK" init -q "repo"

  local BIN="$WORK/bin"; mkdir -p "$BIN"
  local CALL_LOG="$WORK/gh-calls.log"; : > "$CALL_LOG"

  # gh mock: records every invocation; serves a green/labelled/mergeable PR
  # with the requested baseRefName, the requested default branch, and a
  # successful merge. `issue close` is recorded so we can assert on it.
  cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
echo "gh \$*" >> "$CALL_LOG"
case "\$1 \$2" in
  "pr view")
    cat <<'JSON'
{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN",
 "labels":[{"name":"auto-merge"}],"statusCheckRollup":[],
 "headRefName":"feature/x","baseRefName":"$base"}
JSON
    ;;
  "repo view")
    echo '{"defaultBranchRef":{"name":"$def"}}'
    ;;
  "pr merge")   echo "merged (mock)" ;;
  "issue close") echo "closed (mock)" ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$BIN/gh"

  local RID="20260722-1200-issue-${issue/-/0}"
  local RD="$REPO/.claude/run-issues/$RID"
  # shellcheck source=../lib/state.sh
  . "$STATE_LIB"
  state_init "$RD" "$RID" "$REPO" "${issue/-/0}"
  state_set "$RD" "pr_url" "https://github.com/Silon-Oy/dotfiles/pull/900"
  if [ "$issue" = "-" ]; then
    tmp=$(mktemp); jq '.issue_number = null' "$RD/run.json" > "$tmp"; mv "$tmp" "$RD/run.json"
  fi
  if [ "$host" != "self" ]; then
    tmp=$(mktemp); jq '.host = "some-other-host"' "$RD/run.json" > "$tmp"; mv "$tmp" "$RD/run.json"
  fi
  state_finalize "$RD" "completed"

  (
    export PATH="$BIN:$PATH"
    export RUN_ISSUES_LOCK_ROOT="$WORK/locks"
    export PR_WATCH_ENABLE_CONFLICT_RESOLUTION=0
    set +e
    "$PRWATCH" "$REPO" 900 >/dev/null 2>&1
    set -e
  )

  local closed=0
  grep -q '^gh issue close' "$CALL_LOG" && closed=1

  if [ "$closed" = "$expect_close" ]; then
    PASS=$((PASS + 1)); printf 'PASS  %-42s -> closed=%s\n' "$name" "$closed"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL  %-42s -> closed=%s expected=%s\n' "$name" "$closed" "$expect_close"
    echo "    gh calls:"; sed 's/^/      /' "$CALL_LOG"
  fi
  rm -rf "$WORK"
}

run_case "non-default base -> close"     "twenty" "main" "77" self  1
run_case "default base -> no close"      "main"   "main" "77" self  0
run_case "empty issue_number -> no close" "twenty" "main" "-"  self  0
run_case "foreign host, non-default -> close" "twenty" "main" "77" foreign 1

echo "----------------------------------------"
printf 'pr-watch-close-issue: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
