#!/usr/bin/env bash
# test-pr-watch-close-issue.sh — explicit linked-issue close after merge.
#
# The watcher closes the PR's linked issue ALWAYS (best-effort), regardless of
# base branch: GitHub's native `Closes #N` keyword only fires when a PR merges
# into the DEFAULT branch AND the body carries the keyword, and an agent-authored
# PR (or a non-default base) can drop either condition — leaving merged work open
# as an issue. The sole gate is the issue's state: close only when still OPEN, so
# an issue GitHub already closed natively does not get a redundant comment.
#
# Two layers, both network-free and deterministic:
#
#  1. Pure unit: lib/pr-watch-lib.sh:should_close_linked_issue selection matrix
#     (OPEN -> close; CLOSED / anything else / empty -> no close, fail-safe).
#
#  2. Integration: pr-watch.sh with a mocked `gh` (PATH shim). Asserts that the
#     watcher, AFTER a successful merge and BEFORE the P9 host gate, closes the
#     linked issue via `gh issue close` iff the issue is still OPEN. Covers:
#     default base + OPEN -> close (the #239 regression); default base + already
#     CLOSED -> no close; issue-state fetch failure -> no close, no crash;
#     non-default base -> close (unchanged); cross-machine run (foreign host) ->
#     close still happens (remote op precedes the host gate); no linked issue ->
#     no close.
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

# assert_rc <name> <expected-rc> <issue-state>
assert_rc() {
  local name="$1" want="$2" state="$3" got
  if should_close_linked_issue "$state"; then got=0; else got=1; fi
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1)); printf 'PASS  %-42s -> rc=%s\n' "$name" "$got"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL  %-42s -> rc=%s expected=%s\n' "$name" "$got" "$want"
  fi
}

assert_rc "OPEN -> close"                 0 "OPEN"
assert_rc "CLOSED -> no close"            1 "CLOSED"
assert_rc "empty state -> fail-safe skip" 1 ""
assert_rc "unknown state -> no close"     1 "SOMETHING_ELSE"

# ---------------------------------------------------------------------------
# Layer 2: integration through pr-watch.sh with a mocked gh
# ---------------------------------------------------------------------------
echo "--- pr-watch.sh integration: explicit close placement ---"

# run_case <name> <base-ref> <issue-num|-> <issue-state|FAIL> <host> <expect-close>
# <issue-num> "-" means: run.json has a null issue_number (no linked issue).
# <issue-state> is what the mocked `gh issue view` serves; "FAIL" makes that
#   call exit non-zero (simulating a fetch/auth failure).
# <host> "self" means this host; anything else forces a foreign host.
run_case() {
  local name="$1" base="$2" issue="$3" state="$4" host="$5" expect_close="$6"

  local WORK; WORK=$(mktemp -d -t prwatch-close.XXXXXX)
  local REPO="$WORK/repo"
  git -C "$WORK" init -q "repo"

  local BIN="$WORK/bin"; mkdir -p "$BIN"
  local CALL_LOG="$WORK/gh-calls.log"; : > "$CALL_LOG"

  # gh mock: records every invocation; serves a green/labelled/mergeable PR
  # with the requested baseRefName and a successful merge. `issue view` serves
  # the requested state (or exits 1 when state == FAIL); `issue close` is
  # recorded so we can assert on it.
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
  "pr merge")   echo "merged (mock)" ;;
  "issue view")
    if [ "$state" = "FAIL" ]; then exit 1; fi
    echo '{"state":"$state"}'
    ;;
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

  local rc=0
  (
    export PATH="$BIN:$PATH"
    export RUN_ISSUES_LOCK_ROOT="$WORK/locks"
    export PR_WATCH_ENABLE_CONFLICT_RESOLUTION=0
    set +e
    "$PRWATCH" "$REPO" 900 >/dev/null 2>&1
    set -e
  ) || rc=$?

  local closed=0
  grep -q '^gh issue close' "$CALL_LOG" && closed=1

  local ok=1
  [ "$closed" = "$expect_close" ] || ok=0
  # A best-effort close path must never crash the watcher.
  [ "$rc" = "0" ] || ok=0

  if [ "$ok" = "1" ]; then
    PASS=$((PASS + 1)); printf 'PASS  %-44s -> closed=%s rc=%s\n' "$name" "$closed" "$rc"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL  %-44s -> closed=%s (want %s) rc=%s\n' "$name" "$closed" "$expect_close" "$rc"
    echo "    gh calls:"; sed 's/^/      /' "$CALL_LOG"
  fi
  rm -rf "$WORK"
}

run_case "default base + OPEN -> close"          "main"   "77" "OPEN"   self    1
run_case "default base + CLOSED -> no close"     "main"   "77" "CLOSED" self    0
run_case "issue-state fetch fails -> no close"   "main"   "77" "FAIL"   self    0
run_case "non-default base + OPEN -> close"      "twenty" "77" "OPEN"   self    1
run_case "foreign host + OPEN -> close"          "main"   "77" "OPEN"   foreign 1
run_case "no linked issue -> no close"           "main"   "-"  "OPEN"   self    0

echo "----------------------------------------"
printf 'pr-watch-close-issue: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
