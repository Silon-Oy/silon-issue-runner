#!/usr/bin/env bash
# test-run-dir-archive.sh — lib/archive.sh (issue #128): the run-dir archiving
# policy that stops the run-dir set from growing without bound.
#
# The predicate and the sweep are pure/local (no gh), so they run against
# synthetic run.json fixtures with no network and no real ~/.claude. The scan
# invisibility guard is the point of decision 7: an archived run must NOT
# reappear in any scan_* or in status.sh, and that break would be silent, so it
# is asserted with a TRAP — a run placed in the archive that WOULD match a scan
# if that scan globbed the archive dir.
#
# Cases:
#   1. Predicate: initialized / blocked / awaiting_clarification / timed_out are
#      never candidates; completed+old+no-PR and merged+old are; young ones are
#      not; completed+old+open-PR is protected.
#   2. Fail-closed: an unreadable run.json is never a candidate.
#   3. Sweep moves exactly the candidates, leaves the rest in the active dir.
#   4. Zero gh calls (shim ledger): the whole sweep touches no network.
#   5. Idempotence: a second sweep is a no-op (returns 0, no error).
#   6. Collision: a same-run-id dir already in the archive is not overwritten.
#   7. mv failure (archive path unwritable) is logged, non-fatal, run-dir stays.
#   8. Scan invisibility: archived runs are gone from status.sh, scan_clean and
#      scan_stalled; a trap in the archive is caught by none of them; every
#      scan_* globs the active dir, never the archive.
#
# Run: bash tests/test-run-dir-archive.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed"
  exit 0
fi

# shellcheck source=lib/archive.sh
. "$ROOT/lib/archive.sh"
# archive.sh (and the status-read.sh it pulls in) carry `set -euo pipefail`,
# which the source turns ON for this shell. Clear -e again: a test must collect
# every failure, not abort on the first.
set +e

FAIL=0
fail() { echo "FAIL: $1"; FAIL=1; }
pass() { echo "PASS: $1"; }
check() { [ "$2" = "$3" ] && pass "$1" || fail "$1 — got '$2', want '$3'"; }

WORK=$(mktemp -d -t run-dir-archive.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || { echo "FAIL: cannot cd into WORK"; exit 1; }

THIS_HOST=$(hostname -s 2>/dev/null || echo "unknown")
NOW=$(date -u +%s)
THIRTY_D=$(( 30 * 86400 ))
OLD_TS="2020-01-01T00:00:00Z"                       # ~6y old, well past 30d
RECENT_TS=$(date -u +%FT%TZ)                        # now, well under 30d

# mk_run <dir> <status> <started> <finished> [<pr_url>] — write a run.json.
mk_run() {
  local dir="$1" status="$2" started="$3" finished="$4" pr="${5:-}"
  mkdir -p "$dir"
  local rid; rid=$(basename "$dir")
  jq -n --arg id "$rid" --arg s "$status" --arg st "$started" \
        --arg fi "$finished" --arg pr "$pr" --arg h "$THIS_HOST" \
    '{run_id:$id, status:$s, started_at:$st,
      finished_at:(if $fi=="" then null else $fi end),
      pr_url:(if $pr=="" then null else $pr end),
      host:$h, issue_number:1, remote:"origin", repo_slug:"repo-a"}' \
    > "$dir/run.json"
  : > "$dir/state.jsonl"
}

# === Case 1: predicate ========================================================
P="$WORK/pred"
mk_run "$P/init"       initialized           "$OLD_TS" ""        ; # live
mk_run "$P/blocked"    blocked               "$OLD_TS" "$OLD_TS" ; # human-answer
mk_run "$P/awaiting"   awaiting_clarification "$OLD_TS" "$OLD_TS" ; # human-answer
mk_run "$P/timedout"   timed_out             "$OLD_TS" "$OLD_TS" ; # restartable
mk_run "$P/comp_old"   completed             "$OLD_TS" "$OLD_TS" ; # terminal, no PR
mk_run "$P/comp_young" completed             "$RECENT_TS" "$RECENT_TS" ; # too young
mk_run "$P/comp_pr"    completed             "$OLD_TS" "$OLD_TS" "https://x/pull/1" ; # open PR
mk_run "$P/merged_old" merged                "$OLD_TS" "$OLD_TS" ; # terminal, PR closed
mk_run "$P/merged_young" merged              "$RECENT_TS" "$RECENT_TS" ; # too young

cand() { archive_is_candidate "$1/run.json" "$THIRTY_D" "$NOW"; }
cand "$P/init"        && fail "initialized is a candidate" || pass "initialized not archived"
cand "$P/blocked"     && fail "blocked is a candidate" || pass "blocked not archived"
cand "$P/awaiting"    && fail "awaiting_clarification is a candidate" || pass "awaiting_clarification not archived"
cand "$P/timedout"    && fail "timed_out is a candidate" || pass "timed_out not archived"
cand "$P/comp_old"    && pass "completed+old+no-PR archived" || fail "completed+old+no-PR NOT a candidate"
cand "$P/comp_young"  && fail "completed young is a candidate" || pass "completed young not archived"
cand "$P/comp_pr"     && fail "completed+open-PR is a candidate" || pass "completed+open-PR protected"
cand "$P/merged_old"  && pass "merged+old archived" || fail "merged+old NOT a candidate"
cand "$P/merged_young" && fail "merged young is a candidate" || pass "merged young not archived"

# === Case 2: fail-closed on unreadable run.json ===============================
mkdir -p "$P/broken"
printf '{ this is not json' > "$P/broken/run.json"
cand "$P/broken" && fail "broken run.json is a candidate (should fail-closed)" \
  || pass "unreadable run.json fail-closed (not archived)"
# Missing run.json entirely.
archive_is_candidate "$P/nope/run.json" "$THIRTY_D" "$NOW" \
  && fail "missing run.json is a candidate" || pass "missing run.json fail-closed"

# === Case 3: sweep moves exactly the candidates ===============================
R="$WORK/repo"
mkdir -p "$R/.claude/run-issues"
RD="$R/.claude/run-issues"
mk_run "$RD/comp-old-1"   completed "$OLD_TS" "$OLD_TS" ""
mk_run "$RD/merged-old-1" merged    "$OLD_TS" "$OLD_TS" ""
mk_run "$RD/comp-young-1" completed "$RECENT_TS" "$RECENT_TS" ""
mk_run "$RD/comp-pr-1"    completed "$OLD_TS" "$OLD_TS" "https://x/pull/9"
mk_run "$RD/init-1"       initialized "$OLD_TS" "" ""
mk_run "$RD/blocked-1"    blocked   "$OLD_TS" "$OLD_TS" ""

N=$(archive_sweep_repo "$R" 30)
check "sweep archived 2 runs" "$N" "2"
ARC="$R/.claude/run-issues-archive"
[ -d "$ARC/comp-old-1" ]   && pass "comp-old-1 moved to archive" || fail "comp-old-1 not archived"
[ -d "$ARC/merged-old-1" ] && pass "merged-old-1 moved to archive" || fail "merged-old-1 not archived"
[ ! -e "$RD/comp-old-1" ]   && pass "comp-old-1 gone from active" || fail "comp-old-1 still active"
[ ! -e "$RD/merged-old-1" ] && pass "merged-old-1 gone from active" || fail "merged-old-1 still active"
[ -d "$RD/comp-young-1" ] && pass "comp-young-1 kept active (too young)" || fail "comp-young-1 wrongly moved"
[ -d "$RD/comp-pr-1" ]    && pass "comp-pr-1 kept active (open PR)" || fail "comp-pr-1 wrongly moved"
[ -d "$RD/init-1" ]       && pass "init-1 kept active (live)" || fail "init-1 wrongly moved"
[ -d "$RD/blocked-1" ]    && pass "blocked-1 kept active (human-answer)" || fail "blocked-1 wrongly moved"
# The whole run-dir moves (not just 4 files): state.jsonl travels with it.
[ -f "$ARC/comp-old-1/state.jsonl" ] && pass "state.jsonl travels into the archive" \
  || fail "state.jsonl missing from the archive (history not preserved)"

# Disable via threshold 0 (kill switch): a fresh repo with an old completed run
# is left untouched.
K="$WORK/killrepo"; mkdir -p "$K/.claude/run-issues"
mk_run "$K/.claude/run-issues/comp-x" completed "$OLD_TS" "$OLD_TS" ""
NK=$(archive_sweep_repo "$K" 0)
check "threshold 0 disables archiving (count)" "$NK" "0"
[ -d "$K/.claude/run-issues/comp-x" ] && pass "threshold 0 leaves run-dir active" \
  || fail "threshold 0 archived a run (kill switch broken)"

# === Case 4: zero gh calls ====================================================
# A gh shim on PATH records every call. The sweep — predicate + move — must touch
# no network, exactly the "check is local, never a gh call" of decision 4.
SHIM="$WORK/shim"; mkdir -p "$SHIM"
GH_CALLS="$WORK/gh-calls"; : > "$GH_CALLS"
cat > "$SHIM/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_CALLS"
exit 0
SH
chmod +x "$SHIM/gh"
G="$WORK/ghrepo"; mkdir -p "$G/.claude/run-issues"
mk_run "$G/.claude/run-issues/comp-old" completed "$OLD_TS" "$OLD_TS" ""
mk_run "$G/.claude/run-issues/comp-pr"  completed "$OLD_TS" "$OLD_TS" "https://x/pull/3"
PATH="$SHIM:$PATH" archive_sweep_repo "$G" 30 >/dev/null
check "zero gh calls during sweep" "$(grep -c . "$GH_CALLS")" "0"

# === Case 5: idempotence ======================================================
N2=$(archive_sweep_repo "$R" 30)
check "second sweep is a no-op (0 archived)" "$N2" "0"
[ -d "$ARC/comp-old-1" ] && pass "archive intact after second sweep" || fail "archive changed on re-sweep"
[ -d "$RD/comp-young-1" ] && pass "young run still active after re-sweep" || fail "re-sweep disturbed active dir"

# === Case 6: collision — same run-id already archived =========================
C="$WORK/collrepo"; mkdir -p "$C/.claude/run-issues" "$C/.claude/run-issues-archive"
mk_run "$C/.claude/run-issues/dup-1" completed "$OLD_TS" "$OLD_TS" ""
# A pre-existing (partial) archive copy of the same run-id, with a sentinel file.
mkdir -p "$C/.claude/run-issues-archive/dup-1"
printf 'sentinel\n' > "$C/.claude/run-issues-archive/dup-1/marker"
NC=$(archive_sweep_repo "$C" 30)
check "collision not counted as archived" "$NC" "0"
[ -d "$C/.claude/run-issues/dup-1" ] && pass "collision leaves the active run-dir in place" \
  || fail "collision consumed the active run-dir"
[ -f "$C/.claude/run-issues-archive/dup-1/marker" ] && pass "collision did not overwrite the archived copy" \
  || fail "collision overwrote the archived copy"

# === Case 7: mv failure is non-fatal ==========================================
# Make the archive path unwritable: plant a FILE where the archive DIR must be,
# so mkdir -p fails and the mv never runs. The sweep must not crash; the run-dir
# stays for a later retry.
F="$WORK/failrepo"; mkdir -p "$F/.claude/run-issues"
mk_run "$F/.claude/run-issues/comp-f" completed "$OLD_TS" "$OLD_TS" ""
printf 'block\n' > "$F/.claude/run-issues-archive"   # a FILE, not a dir
NF=$(archive_sweep_repo "$F" 30); rcF=$?
check "mv failure: sweep exits 0" "$rcF" "0"
check "mv failure: nothing counted archived" "$NF" "0"
[ -d "$F/.claude/run-issues/comp-f" ] && pass "mv failure leaves the run-dir for retry" \
  || fail "mv failure lost the run-dir"

# === Case 8: scan invisibility ================================================
# 8a. status.sh: the archived runs are absent from runs[] but counted in
# totals.archived_runs; no read_errors, not degraded.
WL="$WORK/watchlist.json"
cat > "$WL" <<JSON
{"global_max_concurrent":2,"default_labels":["auto-run"],"repos":[{"path":"$R","labels":["auto-run"],"remotes":["origin"]}]}
JSON
SOUT="$WORK/status.json"
HOME="$WORK/fakehome" RUN_ISSUES_WATCHLIST="$WL" bash "$ROOT/status.sh" --json > "$SOUT" 2>/dev/null
src=$?
check "status.sh exit clean" "$src" "0"
if jq -e . "$SOUT" >/dev/null 2>&1; then
  ARCHIVED_IN_RUNS=$(jq -r '[.runs[].run_id | select(. == "comp-old-1" or . == "merged-old-1")] | length' "$SOUT")
  check "archived runs absent from status runs[]" "$ARCHIVED_IN_RUNS" "0"
  check "archived runs counted in totals.archived_runs" "$(jq -r '.totals.archived_runs' "$SOUT")" "2"
  check "status not degraded by archive" "$(jq -r '.totals.degraded' "$SOUT")" "false"
  check "status read_errors empty" "$(jq -r '.read_errors | length' "$SOUT")" "0"
  # The still-active runs ARE present.
  check "active young run present in status" \
    "$(jq -r '[.runs[].run_id | select(. == "comp-young-1")] | length' "$SOUT")" "1"
else
  fail "status.sh did not emit valid JSON"
fi

# 8b. TRAP: place, in the ARCHIVE dir, runs that WOULD be caught by a scan if the
# scan globbed the archive. Extract the scans and prove they emit nothing for the
# trap — they glob run-issues/*, not run-issues-archive/*.
TR="$WORK/traprepo"; mkdir -p "$TR/.claude/run-issues" "$TR/.claude/run-issues-archive"
# scan_stalled trap: an initialized, old-event run on THIS host would be killed.
mk_run "$TR/.claude/run-issues-archive/stale-trap" initialized "$OLD_TS" "" ""
printf '{"event":"claude_started","ts":"%s","data":{}}\n' "$OLD_TS" \
  > "$TR/.claude/run-issues-archive/stale-trap/state.jsonl"
# scan_clean trap: a completed run on THIS host, issue carries auto-clean.
mk_run "$TR/.claude/run-issues-archive/clean-trap" completed "$OLD_TS" "$OLD_TS" ""

# Extract + run scan_stalled (pure: _iso_to_epoch already sourced via archive.sh).
FN_STALLED=$(awk '/^scan_stalled\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$ROOT/poller.sh")
eval "$FN_STALLED"
RUN_ISSUES_STALE_AFTER=3600
OUT_STALLED=$(scan_stalled "$TR")
check "scan_stalled ignores the archive dir" "$OUT_STALLED" ""

# Extract + run scan_clean with a gh mock that would return the auto-clean label.
# lib/issue.sh supplies _rest_issues_path / _rest_issue_path.
# shellcheck source=lib/issue.sh
. "$ROOT/lib/issue.sh"
set +e   # issue.sh re-enables -e; a test must keep collecting failures
FN_CLEAN=$(awk '/^scan_clean\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$ROOT/poller.sh")
eval "$FN_CLEAN"
RUN_ISSUES_CLEAN_LABEL="auto-clean"
gh() {  # would report every issue as auto-clean — but there is no ACTIVE run-dir
  [ "${1:-}" = "api" ] || return 0
  case "$2" in
    */issues\?*) printf '1\tauto-clean\n' ;;
    */issues/[0-9]*) printf 'auto-clean' ;;
  esac
}
OUT_CLEAN=$(scan_clean "$TR")
unset -f gh
check "scan_clean ignores the archive dir" "$OUT_CLEAN" ""

# 8c. Structural guard: every scan_* (and the poller's other run.json loops)
# derive their runs_dir from .claude/run-issues, NEVER .claude/run-issues-archive.
# This covers scan_answered / scan_blocked_answered / scan_timed_out uniformly,
# which are gh-heavy to run in isolation but share this one glob root.
BAD_ROOT=$(grep -nE 'run-issues-archive/\*|run-issues-archive"?/[^"]*run\.json' "$ROOT/poller.sh" | grep -v '^\s*#')
check "no scan globs the archive dir" "$BAD_ROOT" ""
SCAN_ROOTS=$(grep -cE 'local runs_dir="\$repo_path/\.claude/run-issues"' "$ROOT/poller.sh")
[ "$SCAN_ROOTS" -ge 5 ] && pass "all scan_* use the active run-issues glob root ($SCAN_ROOTS found)" \
  || fail "expected >=5 scan_* using the active glob root, found $SCAN_ROOTS"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "run-dir-archive: all passed" || echo "run-dir-archive: FAILURES"
[ "$FAIL" -eq 0 ]
