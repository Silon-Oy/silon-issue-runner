#!/usr/bin/env bash
# test-state-log-hygiene.sh — issue #65: two independent containments of
# unbounded on-disk growth.
#
#   Part A — pr_last_decision (lib/pr-watch-lib.sh) reads the last recorded
#            decision from the TAIL of state.jsonl, never the whole file.
#   Part B — pr-watch.sh suppresses the pr_watch_started / pr_classified /
#            pr_watch_skipped trio on a REPEATED SKIP_CLOSED: the first is a real
#            transition and is logged; every repeat writes nothing. A different
#            prior decision (WAIT_CI) still logs the SKIP_CLOSED. End-to-end with
#            a mocked `gh`, no network.
#   Part C — rotate_log_if_big (lib/log-rotate.sh) rotates a file past the cap to
#            .1, keeps ONE generation, disables on max=0, and no-ops on a missing
#            file.
#   Part D — both pollers wire rotation for all four log files BEFORE the exec
#            redirect that opens .stdout/.stderr (rotating an open fd's file is a
#            no-op).
#
# Plain-bash, SKIP if jq is unavailable.
#
# Run: bash tests/test-state-log-hygiene.sh   (exit 0 = all pass)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# The host name comes from the SAME primitive the code under test uses.
# `hostname -s` is not portable — Windows' hostname has no -s — and issue #213
# moved the four-step fallback into runner_host for exactly that reason. A test
# that re-derives it by hand disagrees with the code on any machine where the
# short flag fails, and then reports a host mismatch that does not exist.
# shellcheck source=../lib/host.sh
. "$HERE/../lib/host.sh"
PRWATCH="$ROOT/pr-watch.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available"
  exit 0
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got=[$2] expected=[$3]"; fi; }

WORK=$(mktemp -d -t state-log-hygiene.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ===========================================================================
# Part A — pr_last_decision unit tests
# ===========================================================================
echo "=== Part A: pr_last_decision reads the last decision from the tail ==="
# shellcheck source=../lib/pr-watch-lib.sh
. "$ROOT/lib/pr-watch-lib.sh"

A="$WORK/a"; mkdir -p "$A"

# Missing file -> empty.
check "missing file -> empty" "$(pr_last_decision "$A/nope.jsonl")" ""

# Empty file -> empty.
: > "$A/empty.jsonl"
check "empty file -> empty" "$(pr_last_decision "$A/empty.jsonl")" ""

# No pr_classified event -> empty.
printf '{"event":"pr_watch_started","ts":"t","data":{}}\n' > "$A/nodec.jsonl"
check "no pr_classified -> empty" "$(pr_last_decision "$A/nodec.jsonl")" ""

# Single pr_classified -> its decision.
printf '{"event":"pr_classified","ts":"t","data":{"decision":"WAIT_CI"}}\n' > "$A/one.jsonl"
check "single decision" "$(pr_last_decision "$A/one.jsonl")" "WAIT_CI"

# Multiple -> the LAST one, even with other events after it earlier.
{
  printf '{"event":"pr_classified","ts":"t1","data":{"decision":"WAIT_CI"}}\n'
  printf '{"event":"pr_watch_skipped","ts":"t2","data":{"reason":"WAIT_CI"}}\n'
  printf '{"event":"pr_classified","ts":"t3","data":{"decision":"SKIP_CLOSED"}}\n'
  printf '{"event":"pr_watch_skipped","ts":"t4","data":{"reason":"SKIP_CLOSED"}}\n'
} > "$A/multi.jsonl"
check "last of many" "$(pr_last_decision "$A/multi.jsonl")" "SKIP_CLOSED"

# Tail-only: a last pr_classified beyond the tail window is (correctly) not seen.
# This is the design contract — once repeats stop, the last classified stays at
# the end and always within the window; a decision buried under >window lines of
# other events is by definition stale. Prove the read is bounded, not whole-file.
{
  printf '{"event":"pr_classified","ts":"old","data":{"decision":"MERGE"}}\n'
  awk 'BEGIN{for(i=0;i<100;i++) print "{\"event\":\"pr_watch_skipped\",\"ts\":\"n\",\"data\":{}}"}'
} > "$A/deep.jsonl"
check "tail window bounded (deep decision unseen)" "$(pr_last_decision "$A/deep.jsonl")" ""

# ===========================================================================
# Part B — end-to-end SKIP_CLOSED suppression through pr-watch.sh
# ===========================================================================
echo "=== Part B: repeated SKIP_CLOSED does not grow state.jsonl ==="
STATE_LIB="$ROOT/lib/state.sh"
THIS_HOST="$(runner_host)"

# A closed (MERGED) PR classifies as SKIP_CLOSED regardless of labels/CI.
PR_VIEW_CLOSED='{"state":"MERGED","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN",
 "labels":[{"name":"auto-merge"}],
 "statusCheckRollup":[],
 "headRefName":"feature/x","baseRefName":"main"}'

# seed_run <repo> <rid> <issue> <pr> — minimal run.json + empty state.jsonl.
seed_run() {
  local repo="$1" rid="$2" issue="$3" pr="$4"
  local rd="$repo/.claude/run-issues/$rid"
  # shellcheck source=../lib/state.sh
  . "$STATE_LIB"
  state_init "$rd" "$rid" "$repo" "$issue"
  state_set "$rd" "pr_url" "https://github.com/o/r/pull/$pr"
  local tmp; tmp=$(mktemp); jq --arg h "$THIS_HOST" '.host = $h' "$rd/run.json" > "$tmp"; mv "$tmp" "$rd/run.json"
  state_finalize "$rd" "completed"
  printf '%s' "$rd"
}

# run_watch <repo> <pr> — drive pr-watch.sh in named-PR mode against the mock gh.
run_watch() {
  local repo="$1" pr="$2"
  PATH="$BIN:$PATH" \
    RUN_ISSUES_LOCK_ROOT="$WORK/locks" \
    RUN_ISSUES_ENV_FILE="$WORK/no-such-env" \
    PR_WATCH_ENABLE_CI_REPAIR=0 \
    PR_WATCH_ENABLE_CONFLICT_RESOLUTION=0 \
    "$PRWATCH" "$repo" "$pr" >/dev/null 2>&1 || true
}

REPO="$WORK/repo"
git init -q "$REPO"
# Force `main` regardless of the machine's init.defaultBranch.
git -C "$REPO" symbolic-ref HEAD refs/heads/main
( cd "$REPO" && git config user.email t@t.t && git config user.name t \
    && echo x > f && git add f && git commit -qm init )

BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
case "\$1 \$2" in
  "pr view") cat <<'JSON'
$PR_VIEW_CLOSED
JSON
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN/gh"

lines() { wc -l < "$1" | tr -d ' '; }

# B1 — first SKIP_CLOSED on a fresh (empty) state.jsonl: the trio is written.
RD1=$(seed_run "$REPO" "20260101-0000-issue-1" 1 101)
check "B1 fresh state.jsonl empty" "$(lines "$RD1/state.jsonl")" "0"
run_watch "$REPO" 101
L1=$(lines "$RD1/state.jsonl")
check "B1 first SKIP_CLOSED writes trio (3 lines)" "$L1" "3"
grep -q '"event":"pr_watch_started"' "$RD1/state.jsonl" && ok "B1 has pr_watch_started" || bad "B1 missing pr_watch_started"
check "B1 last decision recorded" "$(pr_last_decision "$RD1/state.jsonl")" "SKIP_CLOSED"
grep -q '"event":"pr_watch_skipped".*SKIP_CLOSED' "$RD1/state.jsonl" && ok "B1 has skip event" || bad "B1 missing skip event"

# B2 — repeat on the SAME run: previous recorded decision is SKIP_CLOSED, so the
# trio is suppressed. Line count unchanged across as many ticks as we run.
run_watch "$REPO" 101
check "B2 second SKIP_CLOSED writes nothing" "$(lines "$RD1/state.jsonl")" "3"
run_watch "$REPO" 101
run_watch "$REPO" 101
check "B2 further repeats still write nothing" "$(lines "$RD1/state.jsonl")" "3"

# B3 — transition: the previous recorded decision was WAIT_CI (live state), so
# the SKIP_CLOSED IS logged (the PR just closed — a meaningful transition).
RD3=$(seed_run "$REPO" "20260101-0001-issue-2" 2 102)
printf '{"event":"pr_watch_started","ts":"t0","data":{"pr":"102"}}\n' >> "$RD3/state.jsonl"
printf '{"event":"pr_classified","ts":"t1","data":{"pr":"102","decision":"WAIT_CI"}}\n' >> "$RD3/state.jsonl"
printf '{"event":"pr_watch_skipped","ts":"t2","data":{"pr":"102","reason":"WAIT_CI"}}\n' >> "$RD3/state.jsonl"
BEFORE=$(lines "$RD3/state.jsonl")
run_watch "$REPO" 102
AFTER=$(lines "$RD3/state.jsonl")
check "B3 WAIT_CI -> SKIP_CLOSED logs the transition (+3)" "$AFTER" "$((BEFORE + 3))"
check "B3 last decision is now SKIP_CLOSED" "$(pr_last_decision "$RD3/state.jsonl")" "SKIP_CLOSED"
# And the NEXT tick after the logged transition is suppressed again.
run_watch "$REPO" 102
check "B3 repeat after transition suppressed" "$(lines "$RD3/state.jsonl")" "$AFTER"

# ===========================================================================
# Part C — rotate_log_if_big unit tests
# ===========================================================================
echo "=== Part C: rotate_log_if_big ==="
# shellcheck source=../lib/log-rotate.sh
. "$ROOT/lib/log-rotate.sh"

C="$WORK/c"; mkdir -p "$C"
MAX=10

# Over the cap -> rotated to .1; original moved away, .1 holds the content.
printf '0123456789ABCDEF' > "$C/big.log"   # 16 bytes > 10
rotate_log_if_big "$C/big.log" "$MAX"
[ ! -f "$C/big.log" ] && ok "C over-cap: original moved away" || bad "C over-cap: original still present"
[ -f "$C/big.log.1" ] && ok "C over-cap: .1 generation created" || bad "C over-cap: no .1"
check "C over-cap: .1 holds the content" "$(cat "$C/big.log.1" 2>/dev/null)" "0123456789ABCDEF"

# Under the cap -> untouched, no .1.
printf 'small' > "$C/tiny.log"             # 5 bytes < 10
rotate_log_if_big "$C/tiny.log" "$MAX"
[ -f "$C/tiny.log" ] && [ ! -f "$C/tiny.log.1" ] && ok "C under-cap: untouched" || bad "C under-cap: rotated unexpectedly"

# One generation: a new over-cap file overwrites the previous .1.
printf 'OLDGEN' > "$C/gen.log.1"
printf 'NEWCONTENT-OVER-CAP' > "$C/gen.log"  # 19 bytes > 10
rotate_log_if_big "$C/gen.log" "$MAX"
check "C one generation: .1 overwritten with newest" "$(cat "$C/gen.log.1")" "NEWCONTENT-OVER-CAP"

# max=0 disables rotation even for a huge file.
printf '0123456789ABCDEF' > "$C/off.log"
rotate_log_if_big "$C/off.log" 0
[ -f "$C/off.log" ] && [ ! -f "$C/off.log.1" ] && ok "C max=0 disables rotation" || bad "C max=0 rotated"

# Missing file -> no-op, no error, no .1 created.
rotate_log_if_big "$C/ghost.log" "$MAX" && RC=0 || RC=$?
[ "$RC" = "0" ] && [ ! -f "$C/ghost.log.1" ] && ok "C missing file: silent no-op" || bad "C missing file: not a clean no-op (rc=$RC)"

# ===========================================================================
# Part D — both pollers wire rotation for all four logs before the exec redirect
# ===========================================================================
echo "=== Part D: pollers rotate all four logs before exec ==="
# Each poller makes exactly FOUR rotate_log_if_big calls (one per log file),
# every one BEFORE the exec redirect that opens .stdout/.stderr.
count_calls() {
  # count only actual call sites (line starts with optional space then the fn)
  grep -cE '^[[:space:]]*rotate_log_if_big ' "$ROOT/$1"
}
assert_before_exec() {
  local f="$ROOT/$1"
  local last_rot exec_ln
  last_rot=$(grep -nE '^[[:space:]]*rotate_log_if_big ' "$f" | tail -n1 | cut -d: -f1)
  exec_ln=$(grep -nE '^[[:space:]]*exec >>' "$f" | head -n1 | cut -d: -f1)
  if [ -n "$last_rot" ] && [ -n "$exec_ln" ] && [ "$last_rot" -lt "$exec_ln" ]; then
    ok "D $1 rotates before exec ($last_rot < $exec_ln)"
  else
    bad "D $1 rotation not before exec (rot=$last_rot exec=$exec_ln)"
  fi
}

for P in poller.sh pr-watch-poller.sh; do
  grep -q 'lib/log-rotate.sh' "$ROOT/$P" && ok "D $P sources log-rotate" || bad "D $P does not source log-rotate"
  grep -q 'RUN_ISSUES_LOG_MAX_BYTES:-10485760' "$ROOT/$P" && ok "D $P has 10 MB default" || bad "D $P missing default cap"
  check "D $P has four rotate calls" "$(count_calls "$P")" "4"
  assert_before_exec "$P"
done

echo
echo "state-log-hygiene: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
