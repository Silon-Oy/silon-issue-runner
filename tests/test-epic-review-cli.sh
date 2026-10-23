#!/usr/bin/env bash
# test-epic-review-cli.sh — epic-review.sh, the operator surface of the epic
# review (issue #274).
#
# WHAT IS PINNED HERE:
#   (a) --dry-run + findings => report printed, exit 6, ZERO GitHub writes;
#   (b) findings => exactly one epic-attention label add and one comment that
#       carries the marker and names the criteria;
#   (c) the marker already on the epic => no writes AND no agent call (exit 0);
#   (d) criteria met => one comment, no epic-attention label (exit 0);
#   (e) an epic without sub-issues => exit 3, no writes, no agent call;
#   (f) not open / no `epic` label / not found => exit 2, no writes;
#   (g) launch failure (agent rc 127) => exit 5, no writes;
#   (h) unreadable child set => exit 4, no writes;
#   (i) a failed label write => exit 7;
#   (j) no `issue close`, no merge, no write to a child in any case.
#
# gh is a PATH shim that logs every call; the agent is stubbed through
# RUN_ISSUES_CLAUDE_CMD and the machine env file is /dev/null, so no real agent
# is ever launched (CLAUDE.md §5.5).
#
# Run: bash tests/test-epic-review-cli.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
CLI="$ROOT/epic-review.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed — epic-review.sh reads issue JSON with jq"
  exit 0
fi

WORK=$(mktemp -d -t epicreviewcli.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"

FAIL=0
fail() { echo "FAIL: $*"; FAIL=1; }
pass() { echo "PASS: $*"; }

# --- fixture store ---------------------------------------------------------
# epic.json            the epic's `gh issue view --json` payload (absent = not found)
# subissues.json       sub_issues API payload for the epic
# fail/<kind>          presence => that call fails (sub_issues|labels|comment)
# gh.log               one line per gh call (all args)
STATE="$WORK/state"; mkdir -p "$STATE/fail"
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
set -u
STATE="$STATE"
printf '%s\n' "\$*" >> "\$STATE/gh.log"
expr=""; prev=""
for a in "\$@"; do case "\$prev" in --jq) expr="\$a";; esac; prev="\$a"; done
case "\$1" in
  repo) printf 'silon-oy/demo\n' ;;
  issue)
    case "\$2" in
      view) [ -f "\$STATE/epic.json" ] || { echo "not found" >&2; exit 1; }; cat "\$STATE/epic.json" ;;
      comment)
        [ -e "\$STATE/fail/comment" ] && { cat >/dev/null; echo "comment boom" >&2; exit 1; }
        cat > "\$STATE/comment-\$3.md" ;;
      *) : ;;
    esac ;;
  api)
    path=""; graphql=0
    for a in "\$@"; do
      case "\$a" in
        graphql) graphql=1 ;;
        repos/*) [ -z "\$path" ] && path="\$a" ;;
      esac
    done
    if [ "\$graphql" = 1 ]; then
      jq -n '{data:{repository:{issue:{closedByPullRequestsReferences:{nodes:[{number:11}]}}}}}' | jq -r "\${expr:-.}"
      exit 0
    fi
    case "\$path" in
      *"/sub_issues")
        [ -e "\$STATE/fail/sub_issues" ] && { echo "sub_issues boom" >&2; exit 1; }
        if [ -f "\$STATE/subissues.json" ]; then cat "\$STATE/subissues.json"; else echo '[]'; fi ;;
      *"/pulls/"*"/files")
        printf '[{"filename":"lib/a.sh"}]' | jq -r "\${expr:-.}" ;;
      *"/labels")
        [ -e "\$STATE/fail/labels" ] && { echo "labels boom (HTTP 500)" >&2; exit 1; }
        : ;;
      *) : ;;
    esac ;;
esac
exit 0
SH
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# The stub agent: prints $WORK/reply, exits with $WORK/rc; every call counted.
STUB="$WORK/claude-stub"
cat > "$STUB" <<SH
#!/usr/bin/env bash
echo call >> "$WORK/agent.log"
[ -f "$WORK/reply" ] && cat "$WORK/reply"
[ -f "$WORK/rc" ] && exit "\$(cat "$WORK/rc")"
exit 0
SH
chmod +x "$STUB"

REPO="$WORK/repo"; mkdir -p "$REPO/.git"

REPLY_FINDINGS='Gaps found.

EPIC_FINDING: criterion one | #101 ja #102 eivät yhdessä täytä tätä
EPIC_REVIEW_RESULT: FINDINGS'
REPLY_MET='All good.

EPIC_REVIEW_RESULT: CRITERIA_MET'

# seed [state] [labels-json] [comments-json] — a fresh epic #100 with two children.
seed() {
  rm -rf "$STATE"; mkdir -p "$STATE/fail"
  rm -f "$WORK/agent.log" "$WORK/reply" "$WORK/rc"
  local labels='[{"name":"epic"}]' comments='[]'
  [ -z "${2:-}" ] || labels="$2"
  [ -z "${3:-}" ] || comments="$3"
  jq -n --arg s "${1:-OPEN}" --argjson l "$labels" --argjson c "$comments" \
    '{title:"Epic title", body:"## Hyväksyntäkriteerit\n\n- [ ] criterion one\n", state:$s,
      labels:$l, comments:$c, author:{login:"tester"}}' > "$STATE/epic.json"
  printf '[%s,%s]' \
    '{"number":101,"state":"closed","title":"First","labels":[],"repository_url":"https://api.github.com/repos/silon-oy/demo"}' \
    '{"number":102,"state":"closed","title":"Second","labels":[],"repository_url":"https://api.github.com/repos/silon-oy/demo"}' \
    > "$STATE/subissues.json"
}

run_cli() { # run_cli [args...] — sets OUT, RC
  OUT=$(env RUN_ISSUES_CLAUDE_CMD="$STUB" RUN_ISSUES_CLAUDE_PROFILES= RUN_ISSUES_ENV_FILE=/dev/null \
    bash "$CLI" 100 --repo "$REPO" "$@" 2>"$WORK/stderr")
  RC=$?
}
writes()       { grep -cE '^issue comment|^api --method POST .*/labels' "$STATE/gh.log" 2>/dev/null || true; }
label_adds()   { grep -cE '^api --method POST .*/issues/100/labels .*epic-attention' "$STATE/gh.log" 2>/dev/null || true; }
comments()     { grep -cE '^issue comment 100' "$STATE/gh.log" 2>/dev/null || true; }
agent_calls()  { [ -f "$WORK/agent.log" ] && wc -l < "$WORK/agent.log" | tr -d ' ' || echo 0; }
forbidden()    { grep -cE '^issue (close|edit)|^pr merge|/issues/10[12]/labels|^issue comment 10[12]' "$STATE/gh.log" 2>/dev/null || true; }
check_forbidden() { [ "$(forbidden)" = "0" ] && pass "$1: no close/merge/child write" || fail "$1: forbidden call: $(grep -E 'close|merge|10[12]' "$STATE/gh.log")"; }

# --- (a) --dry-run + findings -------------------------------------------------
seed; printf '%s\n' "$REPLY_FINDINGS" > "$WORK/reply"
run_cli --dry-run
[ "$RC" -eq 6 ] && pass "a: exit 6 (findings)" || fail "a: rc=$RC ($(cat "$WORK/stderr"))"
[ "$(writes)" = "0" ] && pass "a: dry-run wrote nothing" || fail "a: writes=$(writes)"
printf '%s\n' "$OUT" | grep -qF 'criterion one — #101 ja #102' && pass "a: report lists the finding" || fail "a: report: $OUT"
printf '%s\n' "$OUT" | grep -qF 'dry-run complete' && pass "a: dry-run said so" || fail "a: no dry-run line"
[ "$(agent_calls)" = "1" ] && pass "a: agent ran once" || fail "a: agent calls=$(agent_calls)"
check_forbidden a

# --- (b) findings => label + comment, once ----------------------------------
seed; printf '%s\n' "$REPLY_FINDINGS" > "$WORK/reply"
run_cli
[ "$RC" -eq 6 ] && pass "b: exit 6" || fail "b: rc=$RC ($(cat "$WORK/stderr"))"
[ "$(label_adds)" = "1" ] && pass "b: epic-attention added once" || fail "b: label adds=$(label_adds)"
[ "$(comments)" = "1" ] && pass "b: one comment" || fail "b: comments=$(comments)"
c="$STATE/comment-100.md"
[ "$(head -n 1 "$c" 2>/dev/null)" = "<!-- run-issues:epic-review -->" ] && pass "b: marker on the first line" || fail "b: marker missing"
grep -qF -- '- **criterion one** — #101 ja #102' "$c" 2>/dev/null && pass "b: comment names the criterion" || fail "b: comment body: $(cat "$c" 2>/dev/null)"
grep -n 'epic-attention' "$STATE/gh.log" | grep -n 'POST' | head -1 | grep -q . \
  && [ "$(grep -nE '/labels|issue comment' "$STATE/gh.log" | tail -1 | grep -c 'issue comment')" = "1" ] \
  && pass "b: label written before the comment" || fail "b: write order wrong"
check_forbidden b

# --- (c) toisto vaikenee: marker present => no agent, no writes ---------------
seed OPEN '[{"name":"epic"},{"name":"epic-attention"}]' \
  '[{"body":"<!-- run-issues:epic-review -->\n## old review","author":{"login":"bot"}}]'
printf '%s\n' "$REPLY_FINDINGS" > "$WORK/reply"
run_cli
[ "$RC" -eq 0 ] && pass "c: exit 0 (already recorded)" || fail "c: rc=$RC"
[ "$(writes)" = "0" ] && pass "c: no writes" || fail "c: writes=$(writes)"
[ "$(agent_calls)" = "0" ] && pass "c: agent not called" || fail "c: agent calls=$(agent_calls)"
printf '%s\n' "$OUT" | grep -qF 'already recorded' && pass "c: one line says so" || fail "c: out: $OUT"

# --- (d) criteria met => comment, no label ----------------------------------
seed; printf '%s\n' "$REPLY_MET" > "$WORK/reply"
run_cli
[ "$RC" -eq 0 ] && pass "d: exit 0" || fail "d: rc=$RC ($(cat "$WORK/stderr"))"
[ "$(comments)" = "1" ] && pass "d: one comment" || fail "d: comments=$(comments)"
[ "$(label_adds)" = "0" ] && pass "d: no epic-attention" || fail "d: label adds=$(label_adds)"
grep -qF 'kriteerit täyttyvät' "$STATE/comment-100.md" 2>/dev/null && pass "d: comment reports criteria met" || fail "d: body"
check_forbidden d

# --- (e) no sub-issues => exit 3 ----------------------------------------------
seed; echo '[]' > "$STATE/subissues.json"; printf '%s\n' "$REPLY_MET" > "$WORK/reply"
run_cli
[ "$RC" -eq 3 ] && pass "e: exit 3" || fail "e: rc=$RC"
[ "$(writes)" = "0" ] && [ "$(agent_calls)" = "0" ] && pass "e: no writes, no agent" || fail "e: writes=$(writes) agent=$(agent_calls)"

# --- (f) not open / no epic label / not found => exit 2 ----------------------
seed CLOSED; run_cli
[ "$RC" -eq 2 ] && [ "$(writes)" = "0" ] && pass "f: closed epic => exit 2, no writes" || fail "f: closed rc=$RC"
seed OPEN '[{"name":"auto-run"}]'; run_cli
[ "$RC" -eq 2 ] && [ "$(writes)" = "0" ] && pass "f: no epic label => exit 2, no writes" || fail "f: label rc=$RC"
seed; rm -f "$STATE/epic.json"; run_cli
[ "$RC" -eq 2 ] && pass "f: not found => exit 2" || fail "f: not found rc=$RC"

# --- (g) launch failure => exit 5, no writes ---------------------------------
seed; printf '%s\n' "$REPLY_MET" > "$WORK/reply"; echo 127 > "$WORK/rc"
run_cli
[ "$RC" -eq 5 ] && pass "g: exit 5" || fail "g: rc=$RC"
[ "$(writes)" = "0" ] && pass "g: launch failure wrote nothing" || fail "g: writes=$(writes)"
seed; printf 'no marker at all\n' > "$WORK/reply"; run_cli --dry-run
[ "$RC" -eq 5 ] && pass "g: unparseable output => exit 5" || fail "g: unparseable rc=$RC"

# --- (h) unreadable child set => exit 4 ---------------------------------------
seed; : > "$STATE/fail/sub_issues"; run_cli
[ "$RC" -eq 4 ] && [ "$(writes)" = "0" ] && [ "$(agent_calls)" = "0" ] \
  && pass "h: unreadable graph => exit 4, no writes, no agent" || fail "h: rc=$RC writes=$(writes)"

# --- (i) a failed label write => exit 7 ---------------------------------------
seed; printf '%s\n' "$REPLY_FINDINGS" > "$WORK/reply"; : > "$STATE/fail/labels"
run_cli
[ "$RC" -eq 7 ] && pass "i: failed write => exit 7" || fail "i: rc=$RC"

# --- usage ----------------------------------------------------------------------
bash "$CLI" >/dev/null 2>&1; [ "$?" -eq 1 ] && pass "usage: no epic => exit 1" || fail "usage: no epic"
bash "$CLI" 100 --bogus >/dev/null 2>&1; [ "$?" -eq 1 ] && pass "usage: unknown flag => exit 1" || fail "usage: flag"

# --- (j) source-level: no close / merge / git writes ---------------------------
if grep -nE 'issue close|pr merge|git (push|commit)' "$CLI" | grep -v '^[0-9]*:#' | grep -q .; then
  fail "j: epic-review.sh contains a close/merge/git write"
else
  pass "j: no close/merge/git write in epic-review.sh"
fi

echo "----------------------------------------"
if [ "$FAIL" -eq 0 ]; then echo "epic-review-cli: all passed"; else echo "epic-review-cli: FAILURES"; fi
exit "$FAIL"
