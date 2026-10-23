#!/usr/bin/env bash
# test-serialize.sh — the S7 serialize gate (issue #338).
#
# A cycle review that returns `CYCLE_REVIEW_DECISION: SERIALIZE #N` for an
# older sibling run turns the overlap into a dependency: the runner adds the
# blocked_by edge "this issue is blocked by #N", comments, releases the claim,
# tears the local artefacts down and exits 14 — with NO needs-human label, since
# S2b resumes the issue by itself once #N closes. Anything else is read as
# PROCEED and logged.
#
# Drives full `start` runs through S0..S7 against a real bare origin + clone,
# with gh mocked (every call logged) and claude mocked: the first call is the
# cycle review, any later call (the implementer) returns BLOCKED so a run that
# passed the gate stops right after it. The sibling is an open runner PR for
# issue #12 whose created_at is set per case.
#
# Cases:
#   (a) older sibling → exit 14, edge POSTed with the blocker's id, comment,
#       claim released, no needs-human, worktree + branch gone, no implementer.
#   (b) younger sibling → no POST, serialize_rejected reason=not_older, PROCEED.
#   (c) the edge write fails → serialize_edge_failed, no comment, no unclaim,
#       PROCEED.
#   (d) unparseable SERIALIZE lines → reason=unparseable, PROCEED.
#   (e) a number that is not a listed sibling → reason=not_a_sibling.
#   (f) the sibling list could not be read → reason=siblings_unknown.
#   (g) the reservation label survives the unclaim → exit 15 as
#       serialize_unclaim_failed, needs-human, artefacts kept.
#
# Run: bash tests/test-serialize.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$HERE/../orchestrate.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

WORK=$(mktemp -d -t serialize.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
ok()  { echo "PASS ($1) $2"; }
bad() { echo "FAIL ($1) $2"; FAIL=1; }

ORIGIN="$WORK/origin.git"
SRC="$WORK/src"
git init -q --bare "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q "$SRC"
git -C "$SRC" symbolic-ref HEAD refs/heads/main
(
  cd "$SRC"
  git config user.email t@t.t; git config user.name t
  git remote add origin "$ORIGIN"
  echo "v0" > f.txt; git add f.txt; git commit -qm init
  git push -q origin main
)
REPO="$WORK/repo"
git clone -q "$ORIGIN" "$REPO"
git -C "$REPO" remote set-head origin main

BIN="$WORK/bin"
mkdir -p "$BIN"
# orchestrate.sh waits 5 s at S3 for the claim to settle on GitHub; against the
# gh shim there is nothing to settle, and ten runs would spend most of this
# file's wall time asleep.
GH_LOG="$WORK/gh-calls.log"
# Per-case knobs read by the gh mock.
SIB_TIME="$WORK/sib-time"       # the sibling PR's created_at
POST_MODE="$WORK/post-mode"     # ok | fail
LIST_MODE="$WORK/list-mode"     # ok | fail (the open-PR listing)
LABEL_MODE="$WORK/label-mode"   # clear | stuck (labels read after unclaim)
EDGE="$WORK/edge"               # exists once a POST succeeded

cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"
case "\$*" in
  *"pulls?state=open"*)
    [ "\$(cat "$LIST_MODE")" = ok ] || exit 1
    jq -n -c --arg t "\$(cat "$SIB_TIME")" '[{number: 112, title: "Sibling", created_at: \$t,
      body: "Closes #12", head: {ref: "auto-run/issue-12-sibling"}, base: {ref: "main"}}]' ;;
  *"-X DELETE"*"issues/43/dependencies/blocked_by/"*)
    echo "\$*" >> "$WORK/deletes.log"; rm -f "$EDGE"; exit 0 ;;
  *"-X POST"*"issues/43/dependencies/blocked_by"*)
    [ "\$(cat "$POST_MODE")" = ok ] || exit 1
    touch "$EDGE"; echo '{}' ;;
  *"--paginate"*"issues/43/dependencies/blocked_by"*)
    [ "\$(cat "$WORK/verify-mode" 2>/dev/null)" = fail ] && exit 1
    [ -f "$EDGE" ] && printf '12\topen\n'; exit 0 ;;
  *"--paginate"*"dependencies/blocked_by"*) exit 0 ;;          # sibling's own blockers: none
  *"dependencies/blocked_by"*) echo "0" ;;                       # S2b: no blockers
  *"/issues/12 --jq"*".id"*)                                      # blocker id + state
    printf '987654 %s\n' "\$(cat "$WORK/target-state" 2>/dev/null || echo open)" ;;
  *"/issues/43 --jq .labels"*)
    [ "\$(cat "$LABEL_MODE")" = stuck ] && echo "auto-claimed"; exit 0 ;;
  *"issue view"*"--json labels"*) echo "0" ;;                    # S2c: not an epic
  *"issue view"*"--json assignees"*) echo "testbot" ;;           # verify_claim
  *"issue view"*) echo '{"title":"Same thing twice","body":"b","labels":[],"author":{"login":"x"},"comments":[]}' ;;
  *"api user"*) echo "testbot" ;;
  *"issue comment"*"--body-file -"*) cat >/dev/null 2>&1 || true ;;
  *) : ;;
esac
exit 0
SH
chmod +x "$BIN/gh"

DECISION="$WORK/decision"
CALLS="$WORK/claude-calls"
cat > "$BIN/claude" <<SH
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
n=\$(( \$(cat "$CALLS" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "$CALLS"
if [ "\$n" = 1 ]; then
  echo "cycle review reasoning"
  echo "CYCLE_REVIEW_DECISION: \$(cat "$DECISION")"
else
  echo "IMPLEMENTER_RESULT: BLOCKED — test stops after the gate"
fi
SH
chmod +x "$BIN/claude"

# reset — a clean slate between cases: no run-dirs, worktrees, branches, locks.
reset() {
  local wt
  for wt in "$REPO"/.claude/worktrees/*; do
    [ -d "$wt" ] && git -C "$REPO" worktree remove --force "$wt" >/dev/null 2>&1
  done
  git -C "$REPO" worktree prune
  git -C "$REPO" for-each-ref --format='%(refname:short)' 'refs/heads/auto-run/*' \
    | while read -r b; do git -C "$REPO" branch -D "$b" >/dev/null 2>&1; done
  rm -rf "$REPO/.claude/run-issues" "$REPO/.claude/run-issues-archive" "$WORK/locks" "$EDGE" "$CALLS" \
    "$WORK/target-state" "$WORK/verify-mode" "$WORK/deletes.log"
  : > "$GH_LOG"
}

# run_case <decision> <sib-time> [post-mode] [list-mode] [label-mode]
# Sets RC, OUT and RD (the run-dir, or its archive after a teardown).
run_case() {
  reset
  printf '%s' "$1" > "$DECISION"
  printf '%s' "$2" > "$SIB_TIME"
  printf '%s' "${3:-ok}" > "$POST_MODE"
  printf '%s' "${4:-ok}" > "$LIST_MODE"
  printf '%s' "${5:-clear}" > "$LABEL_MODE"
  OUT=$( cd "$REPO" && \
    PATH="$BIN:$PATH" \
    RUN_ISSUES_AUTO=1 RUN_ISSUES_REVIEW_GATE=auto \
    RUN_ISSUES_CLAUDE_CMD="$BIN/claude" \
    RUN_ISSUES_LOCK_ROOT="$WORK/locks" \
    RUN_ISSUES_ENV_FILE="$WORK/no-such-env" \
    "$ORCH" "$REPO" 43 2>&1 )
  RC=$?
  RD=$(ls -d "$REPO"/.claude/run-issues/*-issue-43 "$REPO"/.claude/run-issues-archive/*-issue-43 2>/dev/null | tail -1)
}

OLD="2020-01-01T00:00:00Z"
NEW="2099-01-01T00:00:00Z"

has_event() { grep -q "\"event\":\"$1\"" "$RD/state.jsonl" 2>/dev/null; }
has_field() { grep "\"event\":\"$1\"" "$RD/state.jsonl" 2>/dev/null | grep -q "\"$2\":\"$3\""; }

# (a)
run_case "SERIALIZE #12" "$OLD"
if [ "$RC" = 14 ] && [ -n "$RD" ] \
   && [ "$(jq -r '.status + "/" + .blocked_reason' "$RD/run.json")" = "blocked/serialized_behind_sibling" ] \
   && [ "$(jq -r '.serialized_behind' "$RD/run.json")" = 12 ] \
   && grep -q -- '-X POST .*issues/43/dependencies/blocked_by -F issue_id=987654' "$GH_LOG" \
   && grep -q 'issue comment' "$GH_LOG" \
   && has_field situation_posted kind serialized \
   && grep -q -- '--remove-assignee' "$GH_LOG" \
   && grep -qF 'labels/auto-claimed' "$GH_LOG" \
   && ! grep -qF 'labels[]=needs-human' "$GH_LOG" \
   && [ "$(cat "$CALLS")" = 1 ] \
   && [ -z "$(git -C "$REPO" for-each-ref 'refs/heads/auto-run/*')" ] \
   && [ ! -d "$REPO/.claude/run-issues/$(basename "$RD")" ]; then
  ok a "older sibling: edge + comment + unclaim, no needs-human, torn down, exit 14"
else
  bad a "rc=$RC rd=$RD calls=$(cat "$CALLS" 2>/dev/null) out=$(echo "$OUT" | tail -5) gh=$(cat "$GH_LOG")"
fi

# (b)
run_case "SERIALIZE #12" "$NEW"
if [ "$RC" != 14 ] && has_field serialize_rejected reason not_older \
   && has_event review_gate_auto_proceed \
   && ! grep -q -- '-X POST' "$GH_LOG" \
   && [ "$(jq -r '.cycle_review_decision' "$RD/run.json")" = PROCEED ]; then
  ok b "younger sibling: rejected as not_older, no edge, run proceeds"
else
  bad b "rc=$RC out=$(echo "$OUT" | tail -5)"
fi

# (c)
run_case "SERIALIZE #12" "$OLD" fail
if [ "$RC" != 14 ] && has_event serialize_edge_failed \
   && has_event review_gate_auto_proceed \
   && grep -q -- '-X POST' "$GH_LOG" \
   && ! has_field situation_posted kind serialized \
   && ! has_event serialized \
   && ! grep -q -- '--remove-assignee' "$GH_LOG"; then
  ok c "edge write fails: serialize_edge_failed, no comment, no unclaim, run proceeds"
else
  bad c "rc=$RC out=$(echo "$OUT" | tail -5)"
fi

# (d)
d_ok=1
for line in "SERIALIZE" "SERIALIZE 12" "SERIALIZE #abc" "SERIALIZE #12 and more"; do
  run_case "$line" "$OLD"
  if ! { [ "$RC" != 14 ] && has_field serialize_rejected reason unparseable \
         && has_event review_gate_auto_proceed && ! grep -q -- '-X POST' "$GH_LOG"; }; then
    d_ok=0; bad d "'$line': rc=$RC"
  fi
done
[ "$d_ok" = 1 ] && ok d "unparseable SERIALIZE lines are read as PROCEED (reason=unparseable)"

# (e)
run_case "SERIALIZE #77" "$OLD"
if [ "$RC" != 14 ] && has_field serialize_rejected reason not_a_sibling \
   && ! grep -q -- '-X POST' "$GH_LOG"; then
  ok e "a number outside the sibling list is rejected (not_a_sibling)"
else
  bad e "rc=$RC"
fi

# (f)
run_case "SERIALIZE #12" "$OLD" ok fail
if [ "$RC" != 14 ] && has_field serialize_rejected reason siblings_unknown \
   && ! grep -q -- '-X POST' "$GH_LOG"; then
  ok f "an unreadable sibling list rejects the serialization (siblings_unknown)"
else
  bad f "rc=$RC"
fi

# (g)
run_case "SERIALIZE #12" "$OLD" ok ok stuck
if [ "$RC" = 15 ] \
   && [ "$(jq -r '.blocked_reason' "$RD/run.json")" = serialize_unclaim_failed ] \
   && grep -qF 'labels[]=needs-human' "$GH_LOG" \
   && [ -d "$REPO/.claude/run-issues/$(basename "$RD")" ]; then
  ok g "reservation label survives: needs-human, artefacts kept, exit 15"
else
  bad g "rc=$RC rd=$RD out=$(echo "$OUT" | tail -5)"
fi

# (i) A closed target is no wait: S2b would pick the issue straight back up and
# the same sibling row would serialize it again on every tick.
reset; echo closed > "$WORK/target-state"
printf '%s' "SERIALIZE #12" > "$DECISION"; printf '%s' "$OLD" > "$SIB_TIME"
printf ok > "$POST_MODE"; printf ok > "$LIST_MODE"; printf clear > "$LABEL_MODE"
OUT=$( cd "$REPO" && PATH="$BIN:$PATH" RUN_ISSUES_AUTO=1 RUN_ISSUES_REVIEW_GATE=auto \
  RUN_ISSUES_CLAUDE_CMD="$BIN/claude" RUN_ISSUES_LOCK_ROOT="$WORK/locks" \
  RUN_ISSUES_ENV_FILE="$WORK/no-such-env" "$ORCH" "$REPO" 43 2>&1 ); RC=$?
RD=$(ls -d "$REPO"/.claude/run-issues/*-issue-43 "$REPO"/.claude/run-issues-archive/*-issue-43 2>/dev/null | tail -1)
if [ "$RC" != 14 ] && has_field serialize_rejected reason target_closed \
   && ! grep -q -- '-X POST' "$GH_LOG" \
   && [ "$(jq -r '.cycle_review_decision' "$RD/run.json")" = PROCEED ]; then
  ok i "closed target: rejected as target_closed, no edge, run proceeds"
else
  bad i "rc=$RC out=$(echo "$OUT" | tail -5)"
fi

# (j) The POST lands but the verifying re-read fails: the run carries on as
# PROCEED, so the edge it cannot vouch for is taken back.
reset; echo fail > "$WORK/verify-mode"
printf '%s' "SERIALIZE #12" > "$DECISION"; printf '%s' "$OLD" > "$SIB_TIME"
printf ok > "$POST_MODE"; printf ok > "$LIST_MODE"; printf clear > "$LABEL_MODE"
OUT=$( cd "$REPO" && PATH="$BIN:$PATH" RUN_ISSUES_AUTO=1 RUN_ISSUES_REVIEW_GATE=auto \
  RUN_ISSUES_CLAUDE_CMD="$BIN/claude" RUN_ISSUES_LOCK_ROOT="$WORK/locks" \
  RUN_ISSUES_ENV_FILE="$WORK/no-such-env" "$ORCH" "$REPO" 43 2>&1 ); RC=$?
RD=$(ls -d "$REPO"/.claude/run-issues/*-issue-43 "$REPO"/.claude/run-issues-archive/*-issue-43 2>/dev/null | tail -1)
if [ "$RC" != 14 ] && has_event serialize_edge_failed \
   && grep -q -- '-X DELETE .*issues/43/dependencies/blocked_by/987654' "$GH_LOG" \
   && [ ! -f "$EDGE" ] \
   && ! grep -q -- '--remove-assignee' "$GH_LOG"; then
  ok j "unverified edge taken back, run proceeds"
else
  bad j "rc=$RC edge=$([ -f "$EDGE" ] && echo left) out=$(echo "$OUT" | tail -5)"
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "serialize: all passed" || echo "serialize: FAILURES"
exit "$FAIL"
