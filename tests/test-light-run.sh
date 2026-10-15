#!/usr/bin/env bash
# test-light-run.sh — the light-run label routes S6 through the light review
# (issue #312).
#
# Drives a full `start` run through S0..S6 with the INTERACTIVE review gate, so
# the run stops (exit 10) right after S6 with run.json and state.jsonl written:
#   - real bare origin + clone with origin/HEAD (so S4 create_worktree succeeds),
#   - gh mocked (issue lookup with a per-case label set, S2b, S2c, claim verify),
#   - claude mocked: it tells the light prompt from the full one by the decision
#     line each prompt asks for, records which one ran plus its --model, and
#     answers the light one with a per-case decision.
# No network, no real agent (CLAUDE.md §5.5).
#
# Cases:
#   (a) no label -> only the full review runs, no light_* events, run_path=default.
#   (b) light-run + LIGHT -> only the light review runs, under the LIGHT_REVIEW
#       phase model; its output becomes 01-cycle-review.out; decision PROCEED;
#       run_path=light.
#   (c) light-run + ESCALATE -> light then full review in the same run;
#       light_review_escalated reason=escalate; run_path=light_escalated.
#   (d) light-run + no decision line -> escalates (reason=no_decision).
#   (e) the light-run label is read only inside S6 — S9 evolution has no branch
#       on it, so no label can skip evolution.
#
# Run: bash tests/test-light-run.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$HERE/../orchestrate.sh"

WORK=$(mktemp -d -t light-run.XXXXXX)
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

BIN="$WORK/bin"
mkdir -p "$BIN"
LABELS_FILE="$WORK/labels.json"     # per case: the issue's label array
LIGHT_ANSWER="$WORK/light-answer"   # per case: the light review's last line
CALLS="$WORK/claude-calls.log"      # one line per agent call: <kind> model=<m>

cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"dependencies/blocked_by"*) echo "0" ;;
  *"issue view"*"--json labels"*) echo "0" ;;
  *"issue view"*"--json assignees"*) echo "testbot" ;;
  *"issue view"*) printf '{"title":"Small fix","body":"b","labels":%s,"author":{"login":"x"},"comments":[]}\n' "\$(cat "$LABELS_FILE")" ;;
  *"api user"*) echo "testbot" ;;
  *"issue comment"*"--body-file -"*) cat >/dev/null 2>&1 || true ;;
  *) : ;;
esac
exit 0
SH
chmod +x "$BIN/gh"

cat > "$BIN/claude" <<SH
#!/usr/bin/env bash
model="" prompt=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --model) model="\$2"; shift ;;
    -p) prompt="\$2"; shift ;;
  esac
  shift
done
if printf '%s' "\$prompt" | grep -q 'LIGHT_REVIEW_DECISION'; then
  echo "light model=\$model" >> "$CALLS"
  echo "light review reasoning"
  cat "$LIGHT_ANSWER"
else
  echo "full model=\$model" >> "$CALLS"
  echo "full review reasoning"
  echo "CYCLE_REVIEW_DECISION: PROCEED"
fi
SH
chmod +x "$BIN/claude"

# run_case <name> <labels-json> <light-answer> — fresh clone, one start run.
# Sets RC and RD (the run dir).
run_case() {
  local name="$1"
  printf '%s' "$2" > "$LABELS_FILE"
  printf '%s\n' "$3" > "$LIGHT_ANSWER"
  : > "$CALLS"
  local repo="$WORK/repo-$name"
  git clone -q "$ORIGIN" "$repo"
  git -C "$repo" remote set-head origin main
  RC=0
  ( cd "$repo" && \
    PATH="$BIN:$PATH" \
    RUN_ISSUES_AUTO=1 RUN_ISSUES_REVIEW_GATE=interactive \
    RUN_ISSUES_CLAUDE_CMD="$BIN/claude" \
    RUN_ISSUES_CLAUDE_MODEL=opus RUN_ISSUES_CLAUDE_MODEL_LIGHT_REVIEW=haiku \
    RUN_ISSUES_LOCK_ROOT="$WORK/locks-$name" \
    RUN_ISSUES_ENV_FILE="$WORK/no-such-env" \
    "$ORCH" "$repo" 312 ) >"$WORK/out-$name.txt" 2>&1 || RC=$?
  RD=$(ls -d "$repo"/.claude/run-issues/*-issue-312 2>/dev/null | tail -1)
}

events() { jq -r '.event' "$RD/state.jsonl" 2>/dev/null; }
rj()     { jq -r "$1" "$RD/run.json" 2>/dev/null; }

# (a)
run_case a '[]' 'LIGHT_REVIEW_DECISION: LIGHT'
if [ "$RC" = 10 ] && [ "$(cat "$CALLS")" = "full model=opus" ] \
   && ! events | grep -q '^light_review' \
   && [ "$(rj .run_path)" = default ] && [ "$(rj .cycle_review_decision)" = PROCEED ] \
   && [ ! -e "$RD/01-cycle-review-light.out" ]; then
  ok a "no label -> full review only, run_path=default"
else
  bad a "rc=$RC calls='$(tr '\n' ' ' < "$CALLS")' run_path='$(rj .run_path)' events='$(events | tr '\n' ' ')'"
fi

# (b)
run_case b '[{"name":"light-run"}]' 'LIGHT_REVIEW_DECISION: LIGHT'
if [ "$RC" = 10 ] && [ "$(cat "$CALLS")" = "light model=haiku" ] \
   && [ "$(rj .run_path)" = light ] && [ "$(rj .cycle_review_decision)" = PROCEED ] \
   && [ "$(rj .light_review_decision)" = LIGHT ] \
   && cmp -s "$RD/01-cycle-review-light.out" "$RD/01-cycle-review.out" \
   && ! events | grep -q '^light_review_escalated'; then
  ok b "light-run + LIGHT -> light review only, LIGHT_REVIEW model, run_path=light"
else
  bad b "rc=$RC calls='$(tr '\n' ' ' < "$CALLS")' run_path='$(rj .run_path)' decision='$(rj .cycle_review_decision)'"
fi

# (c)
run_case c '[{"name":"light-run"}]' 'LIGHT_REVIEW_DECISION: ESCALATE'
CALLS_C=$(tr '\n' ' ' < "$CALLS")
ESC=$(jq -r 'select(.event == "light_review_escalated") | .data.reason' "$RD/state.jsonl" 2>/dev/null)
if [ "$RC" = 10 ] && [ "$CALLS_C" = "light model=haiku full model=opus " ] \
   && [ "$ESC" = escalate ] && [ "$(rj .run_path)" = light_escalated ] \
   && [ "$(rj .cycle_review_decision)" = PROCEED ] \
   && grep -q 'full review reasoning' "$RD/01-cycle-review.out"; then
  ok c "ESCALATE -> full review in the same run, event + run_path=light_escalated"
else
  bad c "rc=$RC calls='$CALLS_C' reason='$ESC' run_path='$(rj .run_path)'"
fi

# (d)
run_case d '[{"name":"light-run"}]' ''
ESC=$(jq -r 'select(.event == "light_review_escalated") | .data.reason' "$RD/state.jsonl" 2>/dev/null)
if [ "$RC" = 10 ] && [ "$(tr '\n' ' ' < "$CALLS")" = "light model=haiku full model=opus " ] \
   && [ "$ESC" = no_decision ] && [ "$(rj .run_path)" = light_escalated ]; then
  ok d "no decision line -> escalates (fail toward the full review)"
else
  bad d "rc=$RC calls='$(tr '\n' ' ' < "$CALLS")' reason='$ESC'"
fi

# (e) Every use of the label constant sits inside S6's own functions.
OUTSIDE=$(awk '
  /^[a-z_]+\(\) *\{/ { fn = $1 }
  /LIGHT_RUN_LABEL/ && !/^LIGHT_RUN_LABEL=/ && fn != "run_cycle_review()" { print NR": "$0 }
' "$ORCH")
if [ -z "$OUTSIDE" ] && grep -q 'LIGHT_RUN_LABEL' "$ORCH"; then
  ok e "light-run label is read only in run_cycle_review (no evolution bypass)"
else
  bad e "label read outside S6: $OUTSIDE"
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "light-run: all passed" || echo "light-run: FAILURES"
[ "$FAIL" -eq 0 ]
