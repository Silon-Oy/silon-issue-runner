#!/usr/bin/env bash
# test-continue-flow.sh — --continue state loading + clarification re-review.
#
# Covers:
#   (a) status gate: --continue only applies to awaiting_clarification runs;
#       any other status is a usage error (exit 1) and does NOT mutate state.
#   (b) round increment before claude: continue_load_state bumps
#       clarification_round under the lock BEFORE re-running cycle-review, and
#       a PROCEED re-review removes the waiting label and proceeds to phase_b.
#   (c) no reply (race): a marker with no human reply after it re-parks the run
#       as awaiting_clarification and exits 0 without incrementing the round.
#   (d) worktree validation: a missing worktree -> blocked + needs-human + exit 0.
#
# gh + claude + git mocked via PATH shims. No network, no real worktree builds.
#
# Run: bash tests/test-continue-flow.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$HERE/../orchestrate.sh"
STATE_LIB="$HERE/../lib/state.sh"
ISSUE_LIB="$HERE/../lib/issue.sh"

WORK=$(mktemp -d -t continue-flow.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
git -C "$WORK" init -q "repo"

BIN="$WORK/bin"
mkdir -p "$BIN"

# gh mock: `issue view` returns a fixture issue JSON (so fetch_issue_json /
# parse_marker / detect_answer work offline); everything else is recorded.
GH_LOG="$WORK/gh-calls.log"
ISSUE_FIXTURE="$WORK/issue-fixture.json"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"
case "\$1" in
  issue)
    case "\$2" in
      view) cat "$ISSUE_FIXTURE" ;;
      *) : ;;
    esac
    ;;
  *) : ;;
esac
exit 0
SH
chmod +x "$BIN/gh"

# shellcheck source=lib/state.sh
. "$STATE_LIB"
# shellcheck source=lib/issue.sh
. "$ISSUE_LIB"

MARKER_TS="2026-05-21T10:00:00Z"

# write_fixture <reply-or-empty> — build the issue JSON the gh mock returns.
# When reply is empty, only the bot marker comment is present (no answer).
write_fixture() {
  local reply="$1" rid="$2"
  local marker
  marker=$(build_marker "$rid" 7 "$MARKER_TS" 1)
  if [ -n "$reply" ]; then
    jq -n --arg marker "$marker" --arg reply "$reply" '{
      title: "t", body: "b",
      comments: [
        { author:{login:"maintainer"}, createdAt:"2026-05-21T10:00:00Z", body:($marker+"\n## tarkennus") },
        { author:{login:"maintainer"}, createdAt:"2026-05-21T10:05:00Z", body:$reply }
      ]
    }' > "$ISSUE_FIXTURE"
  else
    jq -n --arg marker "$marker" '{
      title:"t", body:"b",
      comments:[ { author:{login:"maintainer"}, createdAt:"2026-05-21T10:00:00Z", body:($marker+"\n## tarkennus") } ]
    }' > "$ISSUE_FIXTURE"
  fi
}

# make_worktree — minimal usable worktree (git status must succeed).
make_worktree() {
  local wt="$1"
  git -C "$WORK" init -q "$(basename "$wt")"
  ( cd "$wt"; git config user.email t@t; git config user.name t
    git commit -q --allow-empty -m base )
}

run_orch() {
  ( cd "$REPO" && PATH="$BIN:$PATH" RUN_ISSUES_AUTO=1 \
    RUN_ISSUES_REVIEW_GATE=auto \
    RUN_ISSUES_CLAUDE_CMD="$BIN/claude" \
    RUN_ISSUES_LOCK_ROOT="$WORK/locks" "$@" )
}

# seed_run <rid> <wt> <status> <round> — an awaiting_clarification run by default.
seed_run() {
  local rid="$1" wt="$2" status="$3" round="$4"
  local rd="$REPO/.claude/run-issues/$rid"
  state_init "$rd" "$rid" "$REPO" "7"
  state_set "$rd" "branch" "auto-run/issue-7-x"
  state_set "$rd" "worktree_path" "$wt"
  local tmp; tmp=$(mktemp)
  jq --argjson r "$round" '.clarification_round = $r' "$rd/run.json" > "$tmp"; mv "$tmp" "$rd/run.json"
  echo '{"title":"t","body":"b","comments":[]}' > "$rd/issue.json"
  echo "ok" > "$rd/01-cycle-review.out"
  state_finalize "$rd" "$status"
  echo "$rd"
}

FAIL=0

# === (a) status gate: a completed run cannot be continued ==================
RID_A="20260521-1700-issue-7"
WT_A="$WORK/wt-a"; make_worktree "$WT_A"
RD_A=$(seed_run "$RID_A" "$WT_A" "completed" 0)
write_fixture "vastaus" "$RID_A"
set +e
OUT_A=$(run_orch env RUN_ISSUES_MAX_CLARIFICATIONS=3 "$ORCH" --continue "$RD_A" 2>&1)
RC_A=$?
set -e
echo "--- (a) status gate (rc=$RC_A) ---"; echo "$OUT_A" | tail -3
[ "$RC_A" = "1" ] || { echo "FAIL (a): expected exit 1 for non-awaiting status, got $RC_A"; FAIL=1; }
[ "$(jq -r '.status' "$RD_A/run.json")" = "completed" ] || { echo "FAIL (a): status mutated"; FAIL=1; }
[ "$(jq -r '.clarification_round' "$RD_A/run.json")" = "0" ] || { echo "FAIL (a): round mutated on rejected continue"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (a) non-awaiting status rejected, state untouched"

# === (b) round++ before claude; PROCEED removes waiting + proceeds =========
# claude mock emits PROCEED so the gate proceeds (phase_b then fails at push
# with the mocked gh — irrelevant; we assert round was bumped + waiting removed).
cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
echo "CYCLE_REVIEW_DECISION: PROCEED"
SH
chmod +x "$BIN/claude"

RID_B="20260521-1701-issue-7"
WT_B="$WORK/wt-b"; make_worktree "$WT_B"
RD_B=$(seed_run "$RID_B" "$WT_B" "awaiting_clarification" 1)
write_fixture "Käytä Postgresia." "$RID_B"
: > "$GH_LOG"
set +e
OUT_B=$(run_orch env RUN_ISSUES_MAX_CLARIFICATIONS=3 "$ORCH" --continue "$RD_B" 2>&1)
RC_B=$?
set -e
echo "--- (b) round++ + PROCEED (rc=$RC_B) ---"; echo "$OUT_B" | tail -4
[ "$(jq -r '.clarification_round' "$RD_B/run.json")" = "2" ] || { echo "FAIL (b): round not incremented to 2 (got $(jq -r '.clarification_round' "$RD_B/run.json"))"; FAIL=1; }
grep -q '"event":"continue_attempt"' "$RD_B/state.jsonl" || { echo "FAIL (b): no continue_attempt event"; FAIL=1; }
grep -qF 'labels/waiting' "$GH_LOG" || { echo "FAIL (b): waiting label not removed on PROCEED"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (b) round incremented before claude, PROCEED removed waiting"

# === (c) no reply (race) -> re-park, no increment, exit 0 ==================
RID_C="20260521-1702-issue-7"
WT_C="$WORK/wt-c"; make_worktree "$WT_C"
RD_C=$(seed_run "$RID_C" "$WT_C" "awaiting_clarification" 1)
write_fixture "" "$RID_C"   # only the bot marker, no human reply
set +e
OUT_C=$(run_orch env RUN_ISSUES_MAX_CLARIFICATIONS=3 "$ORCH" --continue "$RD_C" 2>&1)
RC_C=$?
set -e
echo "--- (c) no reply race (rc=$RC_C) ---"; echo "$OUT_C" | tail -3
[ "$RC_C" = "0" ] || { echo "FAIL (c): expected exit 0 on no-reply, got $RC_C"; FAIL=1; }
[ "$(jq -r '.status' "$RD_C/run.json")" = "awaiting_clarification" ] || { echo "FAIL (c): not re-parked"; FAIL=1; }
[ "$(jq -r '.clarification_round' "$RD_C/run.json")" = "1" ] || { echo "FAIL (c): round changed despite no reply"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (c) no reply -> re-parked awaiting_clarification, no increment, exit 0"

# === (d) corrupt worktree -> blocked + needs-human + exit 0 ================
RID_D="20260521-1703-issue-7"
RD_D=$(seed_run "$RID_D" "$WORK/does-not-exist" "awaiting_clarification" 0)
write_fixture "vastaus" "$RID_D"
: > "$GH_LOG"
set +e
OUT_D=$(run_orch env RUN_ISSUES_MAX_CLARIFICATIONS=3 "$ORCH" --continue "$RD_D" 2>&1)
RC_D=$?
set -e
echo "--- (d) corrupt worktree (rc=$RC_D) ---"; echo "$OUT_D" | tail -3
[ "$RC_D" = "0" ] || { echo "FAIL (d): expected exit 0, got $RC_D"; FAIL=1; }
[ "$(jq -r '.status' "$RD_D/run.json")" = "blocked" ] || { echo "FAIL (d): status not blocked"; FAIL=1; }
[ "$(jq -r '.blocked_reason' "$RD_D/run.json")" = "continue_worktree_corrupt" ] || { echo "FAIL (d): wrong reason"; FAIL=1; }
grep -qF 'labels[]=needs-human' "$GH_LOG" || { echo "FAIL (d): needs-human not attempted"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (d) corrupt worktree -> blocked + needs-human + exit 0"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "continue-flow: all passed" || echo "continue-flow: FAILURES"
[ "$FAIL" -eq 0 ]
