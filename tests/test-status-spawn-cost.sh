#!/usr/bin/env bash
# test-status-spawn-cost.sh — status.sh's per-run cost must stay flat.
#
# WHAT THIS PROTECTS
# ------------------
# `status.sh --github` walks its runs in a bash loop. Everything that loop needs
# about a repo's OWNER — did the fetch fail, which prmap file, what fetch time —
# used to be looked up inside the loop with a grep/head/cut chain per file: eight
# processes per lap to answer a question whose answer changes only when the owner
# does. A repo's runs outnumber its owners heavily (one owner, dozens of runs),
# so the cost was O(runs x files) where the work is O(owners).
#
# That is CLAUDE.md section 5.4's cost invariant on a second axis: not "ask about
# work, not history" but "ask once per owner, not once per run". And it fails the
# same silent way — every behavioural assertion stays green while the process
# count goes back to linear, which is invisible on macOS (a spawn costs ~1 ms)
# and expensive under Git Bash (~25 ms, because MSYS emulates fork()).
#
# HOW IT MEASURES
# ---------------
# Not a threshold: an absolute spawn budget would encode this jq version, this
# platform and today's feature set, and it would have to be edited for every
# legitimate change. The invariant is a SLOPE — adding runs for an owner already
# in the document must not add owner lookups — so the test runs the same status.sh
# twice over the same fixture, once with FEW runs and once with MANY, and divides
# the difference in spawns by the difference in runs. What that per-run figure may
# contain is the loop's own honest work (its jq join), not a lookup that a memo
# should have answered.
#
# Counting is `bash -x` with a PS4 that prints nothing but the command, so the
# measurement adds no processes of its own — a PATH shim would double every spawn
# it counts and change what it measures.
#
# Run: bash tests/test-status-spawn-cost.sh   (exit 0 = pass, SKIP when jq/git absent)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
STATUS="$ROOT/status.sh"
# shellcheck source=../lib/host.sh
. "$HERE/../lib/host.sh"

command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not installed";  exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }

FX="$(mktemp -d "${TMPDIR:-/tmp}/status-spawn-test.XXXXXX")"
trap 'rm -rf "$FX"' EXIT
HOST="$(runner_host)"

REPO="$FX/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" remote add origin https://github.com/o/repo.git
RUNS="$REPO/.claude/run-issues"

# ---- runs: no PR, so every one takes the issue-only join path --------------
# One owner for all of them; that is the point of the measurement.
plant_runs() {
  rm -rf "$RUNS"; mkdir -p "$RUNS"
  local n="$1" i=1
  while [ "$i" -le "$n" ]; do
    mkdir -p "$RUNS/r$i"
    cat > "$RUNS/r$i/run.json" <<JSON
{"run_id":"r$i","repo":"$REPO","issue_number":$i,"status":"blocked","started_at":"2026-08-01T10:00:00Z","finished_at":"2026-08-01T10:05:00Z","host":"$HOST","current_state":"S6_CycleReview","blocked_reason":"cycle_review_blocker","remote":"origin","repo_slug":"repo"}
JSON
    i=$((i + 1))
  done
}

WL="$FX/watchlist.json"
cat > "$WL" <<JSON
{"global_max_concurrent":2,"repos":[{"path":"$REPO","remotes":["origin"]}]}
JSON

# ---- gh shim: enough of an answer to walk the whole enrichment path --------
BIN="$FX/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'SHIM'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then echo "[]"; exit 0; fi
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then echo "[]"; exit 0; fi
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  echo '{"state":"OPEN","stateReason":null,"title":"t","labels":[]}'; exit 0
fi
echo "[]"
SHIM
chmod +x "$BIN/gh"

# ---- one traced run -> the number of processes it started ------------------
# PS4 carries no expansions, so tracing costs nothing per line. Only commands we
# know to be external are counted; builtins in the trace are free and irrelevant.
spawns_for() {
  local n="$1"
  # Separate statements on purpose: `local a=$1 b=$a` reads b's $a as the local
  # it is in the middle of declaring, which under `set -u` is an unbound one.
  local trace="$FX/trace-$n.txt"
  local out="$FX/out-$n.json"
  plant_runs "$n"
  PS4='+ ' HOME="$FX/home" PATH="$BIN:$PATH" \
    RUN_ISSUES_WATCHLIST="$WL" RUN_ISSUES_STATUS_CACHE_FILE="$FX/cache-$n.json" \
    bash -x "$STATUS" --json --github > "$out" 2> "$trace"
  # A run that crashed would report a flattering spawn count, so the caller
  # checks the document too.
  awk '{ sub(/^\++ /, ""); print $1 }' "$trace" \
    | grep -cE '^(jq|grep|cut|head|awk|sed|sort|tail|date|git|mktemp|wc|tr|gh)$'
}

runs_in() { jq '.runs | length' "$1" 2>/dev/null || echo -1; }

FEW=3
MANY=12
S_FEW="$(spawns_for "$FEW")"
S_MANY="$(spawns_for "$MANY")"

[ "$(runs_in "$FX/out-$FEW.json")" = "$FEW" ] \
  && ok "the $FEW-run document is complete (measurement is of a working run)" \
  || bad "the $FEW-run document has $(runs_in "$FX/out-$FEW.json") runs, expected $FEW"
[ "$(runs_in "$FX/out-$MANY.json")" = "$MANY" ] \
  && ok "the $MANY-run document is complete" \
  || bad "the $MANY-run document has $(runs_in "$FX/out-$MANY.json") runs, expected $MANY"

DELTA=$((S_MANY - S_FEW))
ADDED=$((MANY - FEW))
PER_RUN=$(( (DELTA + ADDED - 1) / ADDED ))   # round up: the budget is a ceiling

# Both ends of the budget are measured against this fixture: the loop as written
# costs 5 per added run (its own jq join plus the reads every run needs), and the
# per-run owner lookup this replaced cost 14. Eight sits between them — it fails
# on the regression and leaves room for an honest addition. Move it only with a
# number, the way it was set.
BUDGET=8
printf 'processes: %s runs -> %s, %s runs -> %s (%s per added run, budget %s)\n' \
  "$FEW" "$S_FEW" "$MANY" "$S_MANY" "$PER_RUN" "$BUDGET"

if [ "$PER_RUN" -le "$BUDGET" ]; then
  ok "per-run process cost is flat ($PER_RUN <= $BUDGET)"
else
  bad "per-run process cost is $PER_RUN (> $BUDGET): something in the run loop is asking a per-OWNER question per RUN"
fi

echo "----------------------------------------"
if [ "$FAIL" -eq 0 ]; then echo "status-spawn-cost: PASS=$PASS FAIL=0"; exit 0; fi
echo "status-spawn-cost: PASS=$PASS FAIL=$FAIL"; exit 1
