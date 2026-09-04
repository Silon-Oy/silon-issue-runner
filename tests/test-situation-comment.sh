#!/usr/bin/env bash
# test-situation-comment.sh — _post_situation_to_issue (orchestrate.sh).
#
# orchestrate.sh runs its main `case "$MODE"` block at source time, so it cannot
# be sourced directly. We extract just the _post_situation_to_issue function via
# awk (same technique as test-poller-scan-timeout.sh) and drive it in a harness
# where comment_issue is overridden to capture the posted body to a file.
#
# Verifies: headline present; artifact decision line preserved; awaitable=1 ->
# marker present + reply instruction, awaitable=0 -> no marker; oversized
# artifact -> truncation notice + fallback path AND body < 65536 bytes;
# situation_posted event recorded in state.jsonl.
#
# Run: bash tests/test-situation-comment.sh

set -uo pipefail

# Body assertions read from a here-string, never `printf ... | grep -q`. With
# pipefail on, `grep -q` exits the moment it matches and the writer at the head
# of the pipe takes EPIPE — so a SUCCESSFUL match reports the pipeline as
# failed and the case prints its failure message. It only fires once the body is
# big enough that the write does not fit in one buffer, which is exactly case 4
# (60 KB): the suite was green for months and then failed on an unrelated
# commit. A here-string has no second process to break.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$HERE/../orchestrate.sh"
ISSUE_LIB="$HERE/../lib/issue.sh"
STATE_LIB="$HERE/../lib/state.sh"
VERSION_LIB="$HERE/../lib/version.sh"

WORK=$(mktemp -d -t situation-comment.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
mkdir -p "$REPO"

# Real lib functions used by the helper (build_marker, truncate_for_github,
# state_event), then override comment_issue to capture the body.
# shellcheck source=lib/issue.sh
. "$ISSUE_LIB"
# shellcheck source=lib/state.sh
. "$STATE_LIB"
# runner_version_summary is called by _post_situation_to_issue for the
# Runner-version meta line (issue #32).
# shellcheck source=lib/version.sh
. "$VERSION_LIB"

CAPTURE="$WORK/last-comment.txt"
comment_issue() {  # <repo> <N> <text> [<owner/repo>] [<remote>] — capture body only
  printf '%s' "$3" > "$CAPTURE"
}

# Extract _post_situation_to_issue and the artifact-max default from orchestrate.sh.
FN=$(awk '/^_post_situation_to_issue\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$ORCH")
eval "$FN"
# shellcheck disable=SC2034
RUN_ISSUES_SITUATION_ARTIFACT_MAX=60000

# Run state globals the helper reads.
RUN_ID="20260521-1500-issue-99"
RUN_DIR="$REPO/.claude/run-issues/$RUN_ID"
REPO_ROOT="$REPO"
# _post_situation_to_issue reads SCRIPT_DIR (the package root) for the
# Runner-version meta line; point it at this checkout so runner_version_summary
# resolves a real sha instead of "?".
SCRIPT_DIR="$HERE/.."
ISSUE_NUM="99"
BRANCH="auto-run/issue-99-x"
# Multi-remote (issue #53): _post_situation_to_issue passes these to
# comment_issue. The defaults exercise the legacy origin path (empty
# OWNER_REPO -> gh's cwd resolution).
OWNER_REPO=""
REMOTE_NAME="origin"
state_init "$RUN_DIR" "$RUN_ID" "$REPO" "99"

FAIL=0

# === case 1: non-awaitable blocker with artifact ==========================
ART="$WORK/cr.out"
{
  echo "some cycle review reasoning"
  echo "CYCLE_REVIEW_DECISION: BLOCKER"
} > "$ART"

# cycle-review artifacts use prose mode: Markdown wraps on GitHub instead of a
# horizontally-scrolling code fence.
_post_situation_to_issue "cycle_review_blocker" "Cycle review esti ajon. Korjaa este." "$ART" 0 prose
BODY=$(cat "$CAPTURE")
echo "--- case 1 body (first 6 lines) ---"; printf '%s\n' "$BODY" | head -6

grep -q 'Cycle review esti ajon' <<< "$BODY" || { echo "FAIL c1: headline missing"; FAIL=1; }
grep -q 'CYCLE_REVIEW_DECISION: BLOCKER' <<< "$BODY" || { echo "FAIL c1: artifact decision line missing"; FAIL=1; }
grep -q '<details open>' <<< "$BODY" || { echo "FAIL c1: prose artifact not in <details>"; FAIL=1; }
grep -q '<summary>cr.out</summary>' <<< "$BODY" || { echo "FAIL c1: prose <summary> missing"; FAIL=1; }
grep -q '```' <<< "$BODY" && { echo "FAIL c1: prose artifact wrapped in code fence"; FAIL=1; }
grep -q 'run-issues:awaiting-answer' <<< "$BODY" && { echo "FAIL c1: marker present in non-awaitable"; FAIL=1; }
grep -q 'Vastaa tähän issueen' <<< "$BODY" && { echo "FAIL c1: reply prompt present in non-awaitable"; FAIL=1; }
grep -q 'Status/syy: `cycle_review_blocker`' <<< "$BODY" || { echo "FAIL c1: kind meta line missing"; FAIL=1; }
grep -q 'Runner-version: `' <<< "$BODY" || { echo "FAIL c1: Runner-version meta line missing"; FAIL=1; }
grep -q '"event":"situation_posted"' "$RUN_DIR/state.jsonl" || { echo "FAIL c1: no situation_posted event"; FAIL=1; }
grep -q '"awaitable":"0"' "$RUN_DIR/state.jsonl" || { echo "FAIL c1: event awaitable!=0"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS case 1: blocker prose (<details>, no fence), no marker, event"

# === case 2: awaitable clarification (marker + reply prompt) ==============
: > "$RUN_DIR/state.jsonl"
_post_situation_to_issue "cycle_review_clarification" "Tarvitsen tarkennusta." "$ART" 1 prose
BODY=$(cat "$CAPTURE")
echo "--- case 2 body (first 4 lines) ---"; printf '%s\n' "$BODY" | head -4

head -1 <<< "$BODY" | grep -q 'run-issues:awaiting-answer' || { echo "FAIL c2: marker not on first line"; FAIL=1; }
grep -q "run=$RUN_ID" <<< "$BODY" || { echo "FAIL c2: marker run field wrong"; FAIL=1; }
grep -q 'Vastaa tähän issueen' <<< "$BODY" || { echo "FAIL c2: reply prompt missing"; FAIL=1; }
grep -q 'Tarvitsen tarkennusta' <<< "$BODY" || { echo "FAIL c2: headline missing"; FAIL=1; }
grep -q '<details open>' <<< "$BODY" || { echo "FAIL c2: prose artifact not in <details>"; FAIL=1; }
grep -q '"awaitable":"1"' "$RUN_DIR/state.jsonl" || { echo "FAIL c2: event awaitable!=1"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS case 2: clarification, marker first + reply prompt + prose"

# === case 3: no artifact ==================================================
: > "$RUN_DIR/state.jsonl"
_post_situation_to_issue "pr_create_failed" "PR-luonti epäonnistui." "" 0
BODY=$(cat "$CAPTURE")
grep -q 'PR-luonti epäonnistui' <<< "$BODY" || { echo "FAIL c3: headline missing"; FAIL=1; }
grep -q '```' <<< "$BODY" && { echo "FAIL c3: code fence present with no artifact"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS case 3: no artifact -> no code fence"

# === case 4: oversized artifact -> truncation notice + fallback + < 64KiB =
BIG="$WORK/big.out"
head -c 80000 /dev/zero | tr '\0' 'x' > "$BIG"
printf '\nIMPLEMENTER_RESULT: BLOCKED\n' >> "$BIG"
_post_situation_to_issue "implementer_blocked" "Implementer jumissa." "$BIG" 0
BODY=$(cat "$CAPTURE")
BODY_BYTES=$(printf '%s' "$BODY" | wc -c | tr -d ' ')
echo "--- case 4 body bytes: $BODY_BYTES ---"

[ "$BODY_BYTES" -lt 65536 ] || { echo "FAIL c4: body $BODY_BYTES >= 65536"; FAIL=1; }
grep -q 'typistetty' <<< "$BODY" || { echo "FAIL c4: truncation notice missing"; FAIL=1; }
grep -q 'IMPLEMENTER_RESULT: BLOCKED' <<< "$BODY" || { echo "FAIL c4: decision line (tail) dropped"; FAIL=1; }
grep -q 'Täysi loki Studiolla' <<< "$BODY" || { echo "FAIL c4: fallback path missing"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS case 4: oversized -> notice + fallback, body under cap"

# === case 5b: awaitable "blocked" (marker + blocked-flavoured reply) ========
# Issue #57: a terminal blocked comment must carry a marker (so a reply re-picks)
# but a DIFFERENT reply instruction than clarification — no --continue, a whole
# new run. Verifies the marker is present, the blocked prompt text is used, and
# the clarification prompt text is NOT.
: > "$RUN_DIR/state.jsonl"
_post_situation_to_issue "implementer_blocked" "Implementer jumissa." "" blocked
BODY=$(cat "$CAPTURE")
echo "--- case 5b body (first 3 lines) ---"; printf '%s\n' "$BODY" | head -3
head -1 <<< "$BODY" | grep -q 'run-issues:awaiting-answer' || { echo "FAIL c5b: marker not on first line"; FAIL=1; }
grep -q 'este on poistettu' <<< "$BODY" || { echo "FAIL c5b: blocked reply prompt missing"; FAIL=1; }
grep -q 'yritetään uudelleen' <<< "$BODY" || { echo "FAIL c5b: blocked retry wording missing"; FAIL=1; }
grep -q 'Studio jatkaa automaattisesti' <<< "$BODY" && { echo "FAIL c5b: clarification prompt leaked into blocked"; FAIL=1; }
grep -q '"awaitable":"blocked"' "$RUN_DIR/state.jsonl" || { echo "FAIL c5b: event awaitable!=blocked"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS case 5b: blocked flavour, marker + distinct reply prompt"

# === case 5: log mode keeps the code fence (monospace logs) ================
: > "$RUN_DIR/state.jsonl"
LOG="$WORK/db.log"
{ echo "mysqldump: column-aligned   output"; echo "ERROR 1045 (28000): Access denied"; } > "$LOG"
_post_situation_to_issue "db_clone_failed" "DB-klooni epäonnistui." "$LOG" 0 log
BODY=$(cat "$CAPTURE")
grep -q 'DB-klooni epäonnistui' <<< "$BODY" || { echo "FAIL c5: headline missing"; FAIL=1; }
grep -q '```' <<< "$BODY" || { echo "FAIL c5: log artifact not in code fence"; FAIL=1; }
grep -q '<details open>' <<< "$BODY" && { echo "FAIL c5: log mode used <details>"; FAIL=1; }
grep -q 'Access denied' <<< "$BODY" || { echo "FAIL c5: log content missing"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS case 5: log mode -> code fence preserved"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "situation-comment: all passed" || echo "situation-comment: FAILURES"
[ "$FAIL" -eq 0 ]
