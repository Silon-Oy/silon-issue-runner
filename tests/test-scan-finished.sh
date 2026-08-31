#!/usr/bin/env bash
# test-scan-finished.sh — poller scan_finished gates, fail-closed behaviour and
# API cost (issue #107).
#
# scan_finished emits "<issue> <run-dir>" only for runs that clear ALL of:
#   G1 not a live run (status != initialized, and status readable)
#   G2 this host
#   G3 issue CONFIRMED closed on GitHub
#   G4 the run's PR is not OPEN
#   G5 no unpushed commits on the feature branch
# Every gate is fail-closed: a gate that cannot be evaluated must SKIP the run,
# never tear it down. `git branch -D` is destructive and the issue is already
# closed, so a wrong emit is unrecoverable while a wrong skip costs one tick.
#
# Cost is asserted explicitly, not inferred. Issues #124/#125/#133 were all the
# same regression — a per-item read that stayed functionally correct while its
# call count went linear and exhausted the shared GitHub quota. The gates here
# could likewise stay green while the scan silently went back to one call per
# run-dir, so the ledger assertions are the point of this file.
#
# poller.sh exits at source time on a non-matching host, so the function is
# extracted and run against a MOCKED `gh` and a REAL local git repo (G5 needs
# genuine branch/upstream topology, which no fixture can fake honestly).
#
# Run: bash tests/test-scan-finished.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLLER="$HERE/../poller.sh"

command -v git >/dev/null 2>&1 || { echo "SKIP: git not available"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }

WORK=$(mktemp -d -t scan-finished.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=lib/state.sh
. "$HERE/../lib/state.sh"
# scan_finished builds its REST paths with _rest_issues_path / _rest_issue_path /
# _rest_pulls_path. lib/issue.sh defines functions only, so sourcing is
# side-effect-free.
# shellcheck source=lib/issue.sh
. "$HERE/../lib/issue.sh"

# Extract scan_finished + its logging helper from poller.sh and source them.
FN=$(awk '/^scan_finished\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$POLLER")
eval "$FN"
LOGFN=$(awk '/^_finished_log\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$POLLER")
eval "$LOGFN"

# shellcheck disable=SC2034
THIS_HOST="test-host"

# ---- a real git repo: bare "remote" + working clone ------------------------
REMOTE_GIT="$WORK/remote.git"
REPO="$WORK/repo"
git init -q --bare "$REMOTE_GIT"
git init -q "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name  Test
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" commit -q --allow-empty -m base
BASE_BRANCH=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)
git -C "$REPO" remote add origin "$REMOTE_GIT"
git -C "$REPO" push -q -u origin "$BASE_BRANCH"

# mk_branch_pushed_then_deleted — the normal end state after a merge: the branch
# was pushed (so it has an upstream) and the remote ref is gone.
mk_branch_pushed_then_deleted() {
  local b="$1"
  git -C "$REPO" checkout -q -b "$b"
  git -C "$REPO" commit -q --allow-empty -m "work on $b"
  git -C "$REPO" push -q -u origin "$b"
  git -C "$REPO" push -q origin --delete "$b"
  git -C "$REPO" update-ref -d "refs/remotes/origin/$b"
  git -C "$REPO" checkout -q "$BASE_BRANCH"
}
# mk_branch_unpushed — pushed once, then a commit was made locally and never
# pushed. This is the work G5 exists to protect.
mk_branch_unpushed() {
  local b="$1"
  git -C "$REPO" checkout -q -b "$b"
  git -C "$REPO" commit -q --allow-empty -m "pushed work on $b"
  git -C "$REPO" push -q -u origin "$b"
  git -C "$REPO" commit -q --allow-empty -m "LOCAL ONLY work on $b"
  git -C "$REPO" checkout -q "$BASE_BRANCH"
}
# mk_branch_never_pushed — no upstream at all.
mk_branch_never_pushed() {
  local b="$1"
  git -C "$REPO" checkout -q -b "$b"
  git -C "$REPO" commit -q --allow-empty -m "never pushed $b"
  git -C "$REPO" checkout -q "$BASE_BRANCH"
}

# ---- GitHub fixtures + call ledgers ---------------------------------------
# OPEN_ISSUES / OPEN_PRS are the authoritative fixture: the list mock and the
# per-issue mock both read them, so they can never disagree about one issue.
OPEN_ISSUES="$WORK/open-issues"; : > "$OPEN_ISSUES"
OPEN_PRS="$WORK/open-prs";       : > "$OPEN_PRS"
# Issue numbers the LIST mock omits, simulating rows lost past the page limit.
HIDDEN="$WORK/hidden";           : > "$HIDDEN"
# When non-empty, the issues list call fails (network / rate limit).
FAIL_ISSUE_LIST="$WORK/fail-issue-list"; : > "$FAIL_ISSUE_LIST"

ILIST_CALLS="$WORK/c-ilist"; PLIST_CALLS="$WORK/c-plist"; VIEW_CALLS="$WORK/c-view"
ARGS="$WORK/args"
reset_ledgers() { : > "$ILIST_CALLS"; : > "$PLIST_CALLS"; : > "$VIEW_CALLS"; : > "$ARGS"; }
reset_ledgers
n_ilist() { wc -l < "$ILIST_CALLS" | tr -d ' '; }
n_plist() { wc -l < "$PLIST_CALLS" | tr -d ' '; }
n_view()  { wc -l < "$VIEW_CALLS"  | tr -d ' '; }

gh() {
  [ "${1:-}" = "api" ] || return 0
  local path="$2"
  printf '%s\n' "$path" >> "$ARGS"
  case "$path" in
    */issues/[0-9]*)
      echo call >> "$VIEW_CALLS"
      local num="${path##*/}"
      if grep -qx "$num" "$OPEN_ISSUES"; then printf 'open'; else printf 'closed'; fi
      ;;
    */issues\?*)
      echo call >> "$ILIST_CALLS"
      [ -s "$FAIL_ISSUE_LIST" ] && return 1
      local page="${path##*page=}"; page="${page%%&*}"
      case "$page" in ''|*[!0-9]*) page=1 ;; esac
      [ "$page" = "1" ] || return 0     # fixtures never fill a page
      local n
      while IFS= read -r n; do
        [ -n "$n" ] || continue
        grep -qx "$n" "$HIDDEN" 2>/dev/null && continue
        printf '%s\n' "$n"
      done < "$OPEN_ISSUES"
      ;;
    */pulls/[0-9]*)
      echo call >> "$VIEW_CALLS"
      local num="${path##*/}"
      if grep -qx "$num" "$OPEN_PRS"; then printf 'open'; else printf 'closed'; fi
      ;;
    */pulls\?*)
      echo call >> "$PLIST_CALLS"
      local page="${path##*page=}"; page="${page%%&*}"
      case "$page" in ''|*[!0-9]*) page=1 ;; esac
      [ "$page" = "1" ] || return 0
      cat "$OPEN_PRS"
      ;;
  esac
}

# mk_run <issue> <status> <host> <pr-number|-> <branch|-> [<suffix>] [<repo>]
mk_run() {
  local n="$1" status="$2" host="$3" pr="$4" br="$5" suffix="${6:-a}" root="${7:-$REPO}"
  local rid="20260521-00${n}${suffix}-issue-$n"
  local rd="$root/.claude/run-issues/$rid"
  state_init "$rd" "$rid" "$root" "$n"
  local tmp; tmp=$(mktemp)
  local pr_url=""
  [ "$pr" != "-" ] && pr_url="https://github.com/acme/widget/pull/$pr"
  local branch=""
  [ "$br" != "-" ] && branch="$br"
  jq --arg h "$host" --arg u "$pr_url" --arg b "$branch" \
     '.host=$h | .pr_url=(if $u=="" then null else $u end) | .branch=(if $b=="" then null else $b end)' \
     "$rd/run.json" > "$tmp"; mv "$tmp" "$rd/run.json"
  # state_finalize refuses nothing; "initialized" is written directly because a
  # live run is exactly the run that was never finalized.
  if [ "$status" != "initialized" ]; then
    state_finalize "$rd" "$status"
  fi
  printf '%s' "$rd"
}

FAIL=0
fail()  { echo "FAIL: $1"; FAIL=1; }
pass()  { echo "PASS: $1"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — got '$2', want '$3'"; fi; }
selected()     { printf '%s\n' "$1" | grep -q "^$2 "; }
expect_sel()   { if selected "$1" "$2"; then pass "$3"; else fail "$3 — not selected"; fi; }
expect_nosel() { if selected "$1" "$2"; then fail "$3 — WAS selected"; else pass "$3"; fi; }

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
mk_branch_pushed_then_deleted "auto-run/issue-10" >/dev/null
mk_branch_pushed_then_deleted "auto-run/issue-14" >/dev/null
mk_branch_unpushed            "auto-run/issue-15" >/dev/null
mk_branch_never_pushed        "auto-run/issue-16" >/dev/null

# 10 — closed issue, finalized run, merged PR, branch pushed+deleted → SELECT
mk_run 10 completed  test-host  110 "auto-run/issue-10" >/dev/null
# 11 — G1: live run (status initialized) → SKIP
mk_run 11 initialized test-host 111 -                   >/dev/null
# 12 — G2: foreign host → SKIP
mk_run 12 completed  other-host 112 -                   >/dev/null
# 13 — G3: issue still OPEN → SKIP
mk_run 13 completed  test-host  113 -                   >/dev/null
# 14 — G4: PR still OPEN → SKIP (issue closed by hand before the merge)
mk_run 14 completed  test-host  114 "auto-run/issue-14" >/dev/null
# 15 — G5: unpushed commits on the branch → SKIP
mk_run 15 completed  test-host  115 "auto-run/issue-15" >/dev/null
# 16 — G5: branch never pushed (no upstream) → SKIP
mk_run 16 completed  test-host  116 "auto-run/issue-16" >/dev/null
# 17 — closed issue, blocked run, NO PR at all → SELECT. This is the run the PR
# watcher can never see (scan_candidates requires a pr_url) and the measured
# case in #107 (customer-a-report#287).
mk_run 17 blocked    test-host  -   -                   >/dev/null

printf '13\n' > "$OPEN_ISSUES"     # only issue 13 is still open
printf '114\n' > "$OPEN_PRS"       # only PR 114 is still open

# ---------------------------------------------------------------------------
echo "=== Case 1: gates + API cost (untruncated lists) ==="
reset_ledgers
OUT=$(scan_finished "$REPO" 2>/dev/null | sort)
echo "--- scan_finished output ---"; echo "$OUT"

expect_sel   "$OUT" 10 "10 closed issue + merged PR + pushed branch"
expect_nosel "$OUT" 11 "11 G1 live run"
expect_nosel "$OUT" 12 "12 G2 foreign host"
expect_nosel "$OUT" 13 "13 G3 issue open"
expect_nosel "$OUT" 14 "14 G4 PR open"
expect_nosel "$OUT" 15 "15 G5 unpushed commits"
expect_nosel "$OUT" 16 "16 G5 branch never pushed"
expect_sel   "$OUT" 17 "17 closed issue, PR-less run (the watcher's blind spot)"

COUNT=$(printf '%s\n' "$OUT" | grep -c '^[0-9]')
check "selected count" "$COUNT" "2"

# THE regression guard: 7 local candidates, ONE issues list + ONE pulls list and
# ZERO per-issue reads. A return to per-run reads would keep every gate green.
check "issues list calls" "$(n_ilist)" "1"
check "pulls list calls"  "$(n_plist)" "1"
check "per-issue reads"   "$(n_view)"  "0"
grep -q -- "state=open" "$ARGS" || fail "REST calls do not filter state=open"
grep -q -- "issues?"    "$ARGS" || fail "not using the REST issues endpoint"
grep -q -- "pulls?"     "$ARGS" || fail "not using the REST pulls endpoint"

# ---------------------------------------------------------------------------
echo "=== Case 2: no local candidates => no network at all ==="
# Before #107 such a repo made zero calls from this pass; the new pass must not
# ADD one to repos with nothing to do.
FOREIGN="$WORK/foreign"; mkdir -p "$FOREIGN/.git"
mk_run 70 completed other-host - - a "$FOREIGN" >/dev/null
reset_ledgers
OUT2=$(scan_finished "$FOREIGN" 2>/dev/null)
check "foreign-only: no output"    "$OUT2"       ""
check "foreign-only: issues calls" "$(n_ilist)"  "0"
check "foreign-only: pulls calls"  "$(n_plist)"  "0"

# ---------------------------------------------------------------------------
echo "=== Case 3: no candidate carries a PR => the pulls list is not fetched ==="
NOPR="$WORK/nopr"; mkdir -p "$NOPR/.git"
mk_run 80 blocked test-host - - a "$NOPR" >/dev/null
reset_ledgers
OUT3=$(scan_finished "$NOPR" 2>/dev/null)
expect_sel "$OUT3" 80 "80 PR-less closed-issue run selected"
check "no-PR: issues calls" "$(n_ilist)" "1"
check "no-PR: pulls calls"  "$(n_plist)" "0"

# ---------------------------------------------------------------------------
echo "=== Case 4: truncated open-issue list falls back to per-issue reads ==="
# limit=1 makes rows >= limit, so absence from the list stops being proof and
# every uncovered candidate must be confirmed individually. Selection must be
# IDENTICAL to case 1 — a truncated list may cost more calls, never fewer runs.
reset_ledgers
OUT4=$(RUN_ISSUES_FINISHED_SCAN_LIMIT=1 scan_finished "$REPO" 2>/dev/null | sort)
expect_sel   "$OUT4" 10 "truncated: 10 still selected via per-issue fallback"
expect_sel   "$OUT4" 17 "truncated: 17 still selected"
expect_nosel "$OUT4" 13 "truncated: 13 (open) still skipped"
expect_nosel "$OUT4" 14 "truncated: 14 (open PR) still skipped"
COUNT4=$(printf '%s\n' "$OUT4" | grep -c '^[0-9]')
check "truncated: selected count unchanged" "$COUNT4" "2"
V4=$(n_view); [ "$V4" -gt 0 ] && pass "truncated: targeted fallback ran ($V4 reads)" \
  || fail "truncated: fallback did not run"

# ---------------------------------------------------------------------------
echo "=== Case 5: issue list unreadable => fail-closed, nothing selected ==="
# A rate-limit episode must never read as "every issue is closed". This is the
# exact failure shape #131 found in pr_decide: an empty payload that looks
# identical to a real answer.
echo fail > "$FAIL_ISSUE_LIST"
reset_ledgers
OUT5=$(scan_finished "$REPO" 2>/dev/null)
check "unreadable list: no output" "$OUT5" ""
check "unreadable list: no pulls call" "$(n_plist)" "0"
: > "$FAIL_ISSUE_LIST"

# ---------------------------------------------------------------------------
echo "=== Case 6: every skip is logged with its reason ==="
# AC7 of #107: a gate must be checkable from the log. "Nothing was reconciled"
# and "the gate blocked it" are indistinguishable without this.
ERR="$WORK/err"
scan_finished "$REPO" >/dev/null 2>"$ERR"
for pat in live_run issue_open pr_open unpushed_commits branch_never_pushed; do
  grep -q "reason=$pat" "$ERR" || fail "log does not name reason=$pat"
done
grep -q "reconcile .*issue=10" "$ERR" || fail "log does not name the reconciled run"
[ "$FAIL" -eq 0 ] && pass "every gate decision appears in the log"

# ---------------------------------------------------------------------------
echo "=== Case 7: scan_finished never closes an issue or writes a label ======"
# Structural, not behavioural: the function must not reach for any mutating gh
# verb. #107 decision 5 — it reacts to a close, so causing one would make the
# signal self-fulfilling.
BODY=$(awk '/^scan_finished\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$POLLER")
for verb in "issue close" "issue edit" "issue comment" "labels_add" "labels_remove"; do
  case "$BODY" in
    *"$verb"*) fail "scan_finished contains a mutating call: $verb" ;;
    *) pass "scan_finished does not call: $verb" ;;
  esac
done

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "scan-finished: all passed" || echo "scan-finished: FAILURES"
[ "$FAIL" -eq 0 ]
