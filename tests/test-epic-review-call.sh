#!/usr/bin/env bash
# test-epic-review-call.sh — lib/epic-review.sh's review call (issue #273):
# epic_review_run, epic_review_parse, epic_review_findings, epic_review_timeout.
#
# WHAT IS PINNED HERE:
#   (a) CRITERIA_MET => criteria_met;
#   (b) FINDINGS + lines => findings, and every finding names its criterion;
#   (c) rc 127 (CLI missing) => launch_failed;
#   (d) timeout (RUN_ISSUES_EPIC_REVIEW_TIMEOUT=1, sleeping agent) => launch_failed;
#   (e) empty output => launch_failed;
#   (f) unparseable / contradictory marker / malformed finding => launch_failed;
#   (g) the system prompt carries both principles pages (call_claude seam);
#   (h) the prompt names the three failure modes and forbids patches;
#   (i) no material => rc != 0 and no agent call;
#   (j) the timeout variable is read at call time with a numeric fallback.
#
# The agent is stubbed through RUN_ISSUES_CLAUDE_CMD — no real agent is ever
# launched (CLAUDE.md §5.5).
#
# Run: bash tests/test-epic-review-call.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
REVIEW_LIB="$ROOT/lib/epic-review.sh"
PROMPT_TPL="$ROOT/prompts/09-epic-review.md"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed — lib/epic-review.sh sources jq-using helpers"
  exit 0
fi

WORK=$(mktemp -d -t epicreviewcall.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"

FAIL=0
fail() { echo "FAIL: $*"; FAIL=1; }
pass() { echo "PASS: $*"; }

# The stub agent: prints $WORK/reply, sleeps $WORK/sleep seconds, exits with
# $WORK/rc. Every call is counted.
STUB="$WORK/claude-stub"
cat > "$STUB" <<SH
#!/usr/bin/env bash
echo call >> "$WORK/calls.log"
prev=""
for a in "\$@"; do
  [ "\$prev" = "--append-system-prompt-file" ] && cp "\$a" "$WORK/system-prompt-seen"
  prev="\$a"
done
[ -f "$WORK/sleep" ] && sleep "\$(cat "$WORK/sleep")"
[ -f "$WORK/reply" ] && cat "$WORK/reply"
[ -f "$WORK/rc" ] && exit "\$(cat "$WORK/rc")"
exit 0
SH
chmod +x "$STUB"

MATERIAL='## Epic #100: Epic title

### Hyväksyntäkriteerit

- [ ] criterion one
- [ ] criterion two'

# review [env...] — run epic_review_run in a fresh shell (set -e must not leak);
# sets RES, RC and leaves the agent output under $RD.
review() {
  rm -rf "$WORK/rd" "$WORK/calls.log" "$WORK/system-prompt-seen"
  RD="$WORK/rd"; mkdir -p "$RD"
  RES=$(env RUN_ISSUES_CLAUDE_CMD="$STUB" RUN_ISSUES_CLAUDE_PROFILES= "$@" bash -c \
    '. "$1" && epic_review_run "$2" "silon-oy/demo#100" "$3"' _ "$REVIEW_LIB" "$RD" "$MATERIAL" 2>/dev/null)
  RC=$?
}
calls() { [ -f "$WORK/calls.log" ] && wc -l < "$WORK/calls.log" | tr -d ' ' || echo 0; }
reset_stub() { rm -f "$WORK/reply" "$WORK/rc" "$WORK/sleep"; }
reply() { printf '%s\n' "$1" > "$WORK/reply"; }

parse() { # parse <out-text> [<exit-code>]
  printf '%s' "$1" > "$WORK/p.out"
  if [ -n "${2:-}" ]; then printf '%s\n' "$2" > "$WORK/p.exit"; else rm -f "$WORK/p.exit"; fi
  bash -c '. "$1" && epic_review_parse "$2" ${3:+"$3"}' _ "$REVIEW_LIB" "$WORK/p.out" \
    "$([ -n "${2:-}" ] && echo "$WORK/p.exit")" 2>/dev/null
}

# --- (a) CRITERIA_MET ---------------------------------------------------------
reset_stub; reply 'All criteria hold.

EPIC_REVIEW_RESULT: CRITERIA_MET'
review
[ "$RC" -eq 0 ] && pass "a: rc 0" || fail "a: rc=$RC"
[ "$RES" = "criteria_met" ] && pass "a: criteria_met" || fail "a: got '$RES'"
[ "$(calls)" = "1" ] && pass "a: exactly one agent call" || fail "a: calls=$(calls)"
[ -f "$RD/09-epic-review.out" ] && [ -f "$RD/09-epic-review.exit" ] \
  && pass "a: .out/.exit written in the work dir" || fail "a: call_claude artefacts missing"

# --- (b) FINDINGS -------------------------------------------------------------
reset_stub; reply 'Two gaps.

EPIC_FINDING: criterion one | yhdessä täyttämättä: #101 ja #102 olettavat toisensa
EPIC_FINDING: `criterion two` | ristiriita: #101 | #102 eri muoto
EPIC_REVIEW_RESULT: FINDINGS'
review
[ "$RES" = "findings" ] && pass "b: findings" || fail "b: got '$RES'"
f=$(bash -c '. "$1" && epic_review_findings "$2"' _ "$REVIEW_LIB" "$RD/09-epic-review.out" 2>/dev/null)
[ "$(printf '%s\n' "$f" | grep -c .)" -eq 2 ] && pass "b: two normalised findings" || fail "b: findings: $f"
printf '%s\n' "$f" | grep -qx 'criterion one|yhdessä täyttämättä: #101 ja #102 olettavat toisensa' \
  && pass "b: finding names criterion one" || fail "b: criterion one missing: $f"
printf '%s\n' "$f" | grep -qx 'criterion two|ristiriita: #101 | #102 eri muoto' \
  && pass "b: criterion trimmed, '|' kept in description" || fail "b: criterion two wrong: $f"

# Fenced result block still parses.
[ "$(parse $'x\n```\nEPIC_FINDING: c | d\nEPIC_REVIEW_RESULT: FINDINGS\n```\n\n' 0)" = "findings" ] \
  && pass "b: fenced result parses" || fail "b: fenced result not parsed"

# --- (c) rc 127: CLI missing --------------------------------------------------
reset_stub
review RUN_ISSUES_CLAUDE_CMD="$WORK/no-such-claude"
[ "$RES" = "launch_failed" ] && pass "c: missing CLI => launch_failed" || fail "c: got '$RES'"
[ "$(tr -dc '0-9' < "$RD/09-epic-review.exit" 2>/dev/null)" = "127" ] \
  && pass "c: exit file records 127" || fail "c: exit file: $(cat "$RD/09-epic-review.exit" 2>/dev/null)"
# Even a "CRITERIA_MET" output with rc 127 is no verdict.
reset_stub; reply 'EPIC_REVIEW_RESULT: CRITERIA_MET'; echo 127 > "$WORK/rc"
review
[ "$RES" = "launch_failed" ] && pass "c: rc 127 beats a CRITERIA_MET marker" || fail "c: got '$RES'"
[ "$(parse 'EPIC_REVIEW_RESULT: CRITERIA_MET' 75)" = "launch_failed" ] \
  && pass "c: usage-limit rc 75 => launch_failed" || fail "c: rc 75 accepted"

# --- (d) timeout --------------------------------------------------------------
# In a subshell: preflight.sh turns on set -e, which must not reach this file.
if [ -n "$(bash -c '. "$1" && preflight_timeout_bin' _ "$ROOT/lib/preflight.sh" 2>/dev/null || true)" ]; then
  reset_stub; reply 'EPIC_REVIEW_RESULT: CRITERIA_MET'; echo 5 > "$WORK/sleep"
  start=$(date +%s)
  review RUN_ISSUES_EPIC_REVIEW_TIMEOUT=1
  took=$(( $(date +%s) - start ))
  [ "$RES" = "launch_failed" ] && pass "d: timeout => launch_failed" || fail "d: got '$RES'"
  [ "$took" -lt 5 ] && pass "d: call cut at the budget (${took}s)" || fail "d: took ${took}s — timeout not applied"
else
  echo "SKIP: d — no timeout/gtimeout binary"
fi

# --- (e) empty output ---------------------------------------------------------
reset_stub; : > "$WORK/reply"
review
[ "$RES" = "launch_failed" ] && pass "e: empty output => launch_failed" || fail "e: got '$RES'"
[ "$(parse '' 0)" = "launch_failed" ] && pass "e: empty file => launch_failed" || fail "e: empty file accepted"
rm -f "$WORK/none.out"
[ "$(bash -c '. "$1" && epic_review_parse "$2"' _ "$REVIEW_LIB" "$WORK/none.out" 2>/dev/null)" = "launch_failed" ] \
  && pass "e: missing file => launch_failed" || fail "e: missing file accepted"

# --- (f) unparseable / contradictory -----------------------------------------
check_f() { # check_f <label> <text>
  local r; r=$(parse "$2" 0)
  [ "$r" = "launch_failed" ] && pass "f: $1 => launch_failed" || fail "f: $1 => '$r'"
}
check_f "no marker"                  'Looks fine to me.'
check_f "unknown marker value"       'EPIC_REVIEW_RESULT: OK'
check_f "marker not last"            $'EPIC_REVIEW_RESULT: CRITERIA_MET\nmore prose after'
check_f "CRITERIA_MET with finding"  $'EPIC_FINDING: c | d\nEPIC_REVIEW_RESULT: CRITERIA_MET'
check_f "FINDINGS without finding"   'EPIC_REVIEW_RESULT: FINDINGS'
check_f "finding without criterion"  $'EPIC_FINDING:  | d\nEPIC_REVIEW_RESULT: FINDINGS'
check_f "finding without separator"  $'EPIC_FINDING: just text\nEPIC_REVIEW_RESULT: FINDINGS'
check_f "finding without desc"       $'EPIC_FINDING: c |  \nEPIC_REVIEW_RESULT: FINDINGS'
check_f "other gate's marker"        'MERGE_GATE_RESULT: CLEAN'
reset_stub; reply 'no verdict here'
review
[ "$RES" = "launch_failed" ] && pass "f: run with unparseable reply => launch_failed" || fail "f: got '$RES'"

# --- (g) system prompt carries both principles pages -------------------------
reset_stub; reply 'EPIC_REVIEW_RESULT: CRITERIA_MET'
review
sp="$WORK/system-prompt-seen"
if [ -f "$sp" ]; then
  grep -qF "$(head -n 1 "$ROOT/principles/coding.md")" "$sp" \
    && pass "g: coding.md delivered" || fail "g: coding.md missing from system prompt"
  grep -qF "$(head -n 1 "$ROOT/principles/auto-run-contract.md")" "$sp" \
    && pass "g: auto-run-contract.md delivered" || fail "g: contract missing from system prompt"
else
  fail "g: no --append-system-prompt-file reached the CLI"
fi
grep -q 'call_claude' "$REVIEW_LIB" && pass "g: routed through call_claude" || fail "g: no call_claude in lib"
grep -q -- '--dangerously-skip-permissions\|RUN_ISSUES_CLAUDE_CMD' "$REVIEW_LIB" \
  && fail "g: lib invokes the CLI directly" || pass "g: no direct CLI invocation"

# --- (h) the prompt -----------------------------------------------------------
for want in 'Yhdessä täyttämättä jäävä kriteeri' 'Lasten keskinäinen ristiriita' \
            'Kriteerien väliin jäävä aukko' 'Et ehdota patchia' 'Et muokkaa yhtään tiedostoa' \
            '(ei kriteereitä)' 'EPIC_REVIEW_RESULT: CRITERIA_MET' 'EPIC_REVIEW_RESULT: FINDINGS' \
            'EPIC_FINDING: <kriteeri> | <kuvaus>' '{{EPIC_REF}}' '{{MATERIAL}}'; do
  grep -qF -- "$want" "$PROMPT_TPL" && pass "h: prompt has '$want'" || fail "h: prompt lacks '$want'"
done
rendered="$RD/09-epic-review.prompt"
grep -qF -- '- [ ] criterion two' "$rendered" && grep -qF 'silon-oy/demo#100' "$rendered" \
  && ! grep -qF '{{MATERIAL}}' "$rendered" \
  && pass "h: prompt rendered with material and ref" || fail "h: rendering incomplete"

# --- (i) no material => no agent call -----------------------------------------
reset_stub; reply 'EPIC_REVIEW_RESULT: CRITERIA_MET'
rm -f "$WORK/calls.log"; mkdir -p "$WORK/rd-empty"
out=$(env RUN_ISSUES_CLAUDE_CMD="$STUB" bash -c '. "$1" && epic_review_run "$2" ref ""' _ "$REVIEW_LIB" "$WORK/rd-empty" 2>/dev/null); rc=$?
[ "$rc" -ne 0 ] && pass "i: rc != 0 on empty material" || fail "i: rc 0"
[ -z "$out" ] && pass "i: nothing on stdout" || fail "i: printed '$out'"
[ "$(calls)" = "0" ] && pass "i: no agent call" || fail "i: agent called"

# --- (j) timeout resolution ---------------------------------------------------
tmo() { env "$@" bash -c '. "$1" && epic_review_timeout' _ "$REVIEW_LIB" 2>/dev/null; }
[ "$(tmo)" = "1800" ] && pass "j: default 1800" || fail "j: default $(tmo)"
[ "$(tmo RUN_ISSUES_EPIC_REVIEW_TIMEOUT=42)" = "42" ] && pass "j: override" || fail "j: override ignored"
[ "$(tmo RUN_ISSUES_EPIC_REVIEW_TIMEOUT=abc)" = "1800" ] && pass "j: non-numeric => default" || fail "j: non-numeric kept"
# Set AFTER sourcing: read at call time, not source time.
[ "$(bash -c '. "$1"; RUN_ISSUES_EPIC_REVIEW_TIMEOUT=7 epic_review_timeout' _ "$REVIEW_LIB" 2>/dev/null)" = "7" ] \
  && pass "j: read at call time" || fail "j: frozen at source time"

if [ "$FAIL" -eq 0 ]; then echo "ALL PASS"; else exit 1; fi
