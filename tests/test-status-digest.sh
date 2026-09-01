#!/usr/bin/env bash
# test-status-digest.sh — behavioural tests for status-digest.sh against fixture
# status.sh --json documents (via --from-file), so no scan / network / gws is
# needed. gws is neutralised by pointing RUN_ISSUES_DIGEST_GWS at a non-existent
# command AND setting no recipient, so every "send" degrades to the stdout
# channel (spec point 5): a printed body == "would have sent", empty stdout ==
# "did not send". The fingerprint state file is redirected into the temp dir so
# the real ~/.local/state is never touched.
#
# Covers acceptance criterion 8: a #92-style run + its age in days in the body;
# an empty attention set does not send; same fingerprint does not send while
# --force does; a different fingerprint sends; --max-silence overrun sends;
# unknown schema_version -> exit 2; without gws -> stdout + exit 0. Plus
# --dry-run writes no state, github:null is handled, and read_errors adds a
# warning line.
#
# Run: bash tests/test-status-digest.sh   (exit 0 = all pass)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DIGEST="$ROOT/status-digest.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed"
  exit 0
fi

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got=[$2] expected=[$3]"; fi; }

FX="$(mktemp -d "${TMPDIR:-/tmp}/status-digest-test.XXXXXX")"
trap 'rm -rf "$FX"' EXIT

STATE="$FX/last-digest.sha"

# run <fixture> <extra-args...> : run the digest with gws disabled, no recipient
# (=> stdout channel), the redirected state file, and a fixed max-silence unless
# overridden. Sets global OUT (stdout) and RC (exit code).
run() {
  local fx="$1"; shift
  OUT="$(RUN_ISSUES_DIGEST_GWS="/nonexistent/gws" \
         RUN_ISSUES_DIGEST_STATE_FILE="$STATE" \
         RUN_ISSUES_DIGEST_ENV_FILE="/nonexistent/digest.env" \
         bash "$DIGEST" --from-file "$fx" "$@" 2>/dev/null)"
  RC=$?
}

# ---- fixture A: the #92-style awaiting_clarification + blocked + stalled ----
FXA="$FX/a.json"
cat > "$FXA" <<'JSON'
{
  "schema_version": 1,
  "generated_at": "2026-08-11T20:49:34Z",
  "host": "host-a",
  "totals": { "degraded": false },
  "runs": [
    {"run_id":"r92","repo_slug":"bar","issue_number":92,"issue_url":"https://github.com/Silon-Oy/bar/issues/92","pr_url":null,"pr_number":null,"age_seconds":6134400,"class":"attention","class_reason":"awaiting_clarification","current_state":"S6_CycleReview"},
    {"run_id":"rb1","repo_slug":"foo","issue_number":10,"issue_url":"https://github.com/Silon-Oy/foo/issues/10","pr_url":null,"pr_number":null,"age_seconds":1036800,"class":"attention","class_reason":"blocked","current_state":"S5_DBClone"},
    {"run_id":"rs1","repo_slug":"baz","issue_number":20,"issue_url":"https://github.com/Silon-Oy/baz/issues/20","pr_url":null,"pr_number":null,"age_seconds":200000,"class":"stalled","class_reason":"orphaned","current_state":"S8_Implementer"},
    {"run_id":"rc1","repo_slug":"baz","issue_number":21,"issue_url":null,"pr_url":null,"pr_number":null,"age_seconds":50,"class":"cleanup","class_reason":"pr_not_open","current_state":null}
  ],
  "read_errors": []
}
JSON

# 6134400 s = 71 days exactly.
run "$FXA" --dry-run
check "A: dry-run exit 0" "$RC" "0"
if printf '%s' "$OUT" | grep -q "#92"; then ok "A: #92 issue in body"; else bad "A: #92 missing"; fi
if printf '%s' "$OUT" | grep -q "71 vrk"; then ok "A: age 71 vrk in body"; else bad "A: 71 vrk missing"; fi
if printf '%s' "$OUT" | grep -q "odottaa vastaustasi"; then ok "A: awaiting label"; else bad "A: awaiting label missing"; fi
if printf '%s' "$OUT" | grep -q "orpo ajo"; then ok "A: stalled group present (min-class stalled default)"; else bad "A: stalled group missing"; fi
if printf '%s' "$OUT" | grep -q "issues/92"; then ok "A: issue link present"; else bad "A: issue link missing"; fi
# cleanup runs must never appear.
if printf '%s' "$OUT" | grep -q "#21"; then bad "A: cleanup run leaked into digest"; else ok "A: cleanup excluded"; fi

# ---- fixture RL: an ACTIVE GitHub backoff (issue #126) ---------------------
# A rate-limited factory produces no NEW attention runs, so without an explicit
# signal it reads exactly like a quiet, healthy one. Three things must carry it:
# the subject line, the body, and the fingerprint — the last so entering or
# leaving the backoff sends a mail instead of waiting days for the heartbeat.
FXRL="$FX/rl.json"
jq '.runner = {version:"abc1234",behind_origin:0,pinned_version:null,
               update_state:"up_to_date",pin_age_seconds:null,
               rate_limited_until:1900000000,rate_limit_backoff_seconds:1200}' \
   "$FXA" > "$FXRL"
run "$FXRL" --dry-run --force
check "RL: dry-run exit 0" "$RC" "0"
if printf '%s' "$OUT" | grep -q "GitHubin kutsuraja"; then ok "RL: backoff named in body"; else bad "RL: backoff missing from body"; fi
if printf '%s' "$OUT" | grep -q "Aihe:.*kutsuraja"; then ok "RL: backoff owns the subject line"; else bad "RL: subject does not mention the backoff"; fi
if printf '%s' "$OUT" | grep -q "Aihe:.*kaikki kunnossa"; then bad "RL: subject still claims all is well"; else ok "RL: subject does not claim all is well"; fi
if printf '%s' "$OUT" | grep -q "20 min"; then ok "RL: remaining backoff shown in minutes"; else bad "RL: remaining backoff not shown"; fi

# The fingerprint must differ from the same document WITHOUT the backoff,
# otherwise the state change is silently swallowed as "no change".
: > "$STATE"
run "$FXA" --dry-run --force >/dev/null 2>&1
run "$FXA"            # writes the healthy fingerprint to $STATE
run "$FXRL"           # same runs, backoff added
if [ "$RC" = "0" ] && printf '%s' "$OUT" | grep -q "kutsuraja"; then
  ok "RL: entering the backoff changes the fingerprint (sends despite identical runs)"
else
  bad "RL: backoff did not change the fingerprint (rc=$RC)"
fi
rm -f "$STATE"
# dry-run must not create the state file.
if [ -f "$STATE" ]; then bad "A: dry-run wrote state file"; else ok "A: dry-run wrote no state"; fi

# ---- min-class attention excludes the stalled group ----
run "$FXA" --dry-run --min-class attention
if printf '%s' "$OUT" | grep -q "orpo ajo"; then bad "min-class attention leaked stalled"; else ok "min-class attention excludes stalled"; fi

# ---- first real run: sends (stdout channel), writes state ----
rm -f "$STATE"
run "$FXA"
check "A: first run exit 0" "$RC" "0"
if [ -n "$OUT" ]; then ok "A: first run emitted body (would send)"; else bad "A: first run sent nothing"; fi
if [ -f "$STATE" ]; then ok "A: first run wrote state"; else bad "A: first run wrote no state"; fi

# ---- second run, same fingerprint: no send ----
run "$FXA"
check "A: unchanged exit 0" "$RC" "0"
if [ -z "$OUT" ]; then ok "A: unchanged -> no send (empty stdout)"; else bad "A: unchanged still sent"; fi

# ---- --force sends despite unchanged fingerprint ----
run "$FXA" --force
if [ -n "$OUT" ]; then ok "A: --force sends unchanged"; else bad "A: --force did not send"; fi

# ---- different fingerprint sends (fixture B differs by one run) ----
FXB="$FX/b.json"
cat > "$FXB" <<'JSON'
{
  "schema_version": 1,
  "generated_at": "2026-08-11T21:00:00Z",
  "host": "host-a",
  "totals": { "degraded": false },
  "runs": [
    {"run_id":"r92","repo_slug":"bar","issue_number":92,"issue_url":"https://github.com/Silon-Oy/bar/issues/92","pr_url":null,"pr_number":null,"age_seconds":6220800,"class":"attention","class_reason":"awaiting_clarification","current_state":"S6_CycleReview"},
    {"run_id":"rb1","repo_slug":"foo","issue_number":10,"issue_url":"https://github.com/Silon-Oy/foo/issues/10","pr_url":null,"pr_number":null,"age_seconds":1123200,"class":"attention","class_reason":"blocked","current_state":"S5_DBClone"},
    {"run_id":"rb2","repo_slug":"foo","issue_number":11,"issue_url":"https://github.com/Silon-Oy/foo/issues/11","pr_url":null,"pr_number":null,"age_seconds":900000,"class":"attention","class_reason":"blocked","current_state":"S4_Worktree"},
    {"run_id":"rs1","repo_slug":"baz","issue_number":20,"issue_url":"https://github.com/Silon-Oy/baz/issues/20","pr_url":null,"pr_number":null,"age_seconds":260000,"class":"stalled","class_reason":"orphaned","current_state":"S8_Implementer"}
  ],
  "read_errors": []
}
JSON
# Re-establish A's fingerprint first (force writes state for A).
run "$FXA" --force
run "$FXB"
if [ -n "$OUT" ]; then ok "B: different fingerprint sends"; else bad "B: change not sent"; fi
# then B unchanged -> no send
run "$FXB"
if [ -z "$OUT" ]; then ok "B: unchanged after change -> no send"; else bad "B: unchanged still sent"; fi

# ---- --max-silence overrun: unchanged fingerprint but stale send epoch -> send ----
# The state file's line 1 is the fingerprint; rewrite line 2 (send epoch) far
# into the past so the default 7-day silence is exceeded.
FP_LINE="$(sed -n '1p' "$STATE")"
printf '%s\n%s\n' "$FP_LINE" "1000000000" > "$STATE"   # epoch 2001 -> very stale
run "$FXB"
if [ -n "$OUT" ]; then ok "max-silence overrun sends unchanged"; else bad "max-silence overrun did not send"; fi
# and with max-silence disabled (0) the same stale-but-unchanged run stays quiet
printf '%s\n%s\n' "$FP_LINE" "1000000000" > "$STATE"
run "$FXB" --max-silence 0
if [ -z "$OUT" ]; then ok "max-silence 0 disables heartbeat"; else bad "max-silence 0 still sent"; fi

# ---- empty attention set: no send, no all-clear on first run ----
FXE="$FX/empty.json"
cat > "$FXE" <<'JSON'
{
  "schema_version": 1,
  "generated_at": "2026-08-11T21:10:00Z",
  "host": "host-a",
  "totals": { "degraded": false },
  "runs": [
    {"run_id":"rc1","repo_slug":"baz","issue_number":21,"issue_url":null,"pr_url":null,"pr_number":null,"age_seconds":50,"class":"cleanup","class_reason":"pr_not_open","current_state":null},
    {"run_id":"rn1","repo_slug":"baz","issue_number":22,"issue_url":null,"pr_url":null,"pr_number":null,"age_seconds":30,"class":"running","class_reason":"active_session","current_state":"S8_Implementer"}
  ],
  "read_errors": []
}
JSON
rm -f "$STATE"
run "$FXE"
check "empty: first run exit 0" "$RC" "0"
if [ -z "$OUT" ]; then ok "empty: no send on first run"; else bad "empty: sent an all-clear on first run"; fi
if [ -f "$STATE" ]; then ok "empty: baseline state written"; else bad "empty: no baseline state"; fi
# empty + max-silence overrun -> all-clear heartbeat
FP_LINE="$(sed -n '1p' "$STATE")"
printf '%s\n%s\n' "$FP_LINE" "1000000000" > "$STATE"
run "$FXE"
if printf '%s' "$OUT" | grep -q "Kaikki kunnossa"; then ok "empty: max-silence -> all-clear message"; else bad "empty: no all-clear on overrun"; fi

# ---- unknown schema_version -> exit 2, no send ----
FXV="$FX/badversion.json"
cat > "$FXV" <<'JSON'
{ "schema_version": 999, "generated_at": "x", "host": "h", "runs": [], "read_errors": [] }
JSON
run "$FXV"
check "schema_version 999 -> exit 2" "$RC" "2"
if [ -z "$OUT" ]; then ok "bad schema: nothing on stdout"; else bad "bad schema: emitted body"; fi

# ---- github:null / degraded=true with read_errors -> warning line ----
FXD="$FX/degraded.json"
cat > "$FXD" <<'JSON'
{
  "schema_version": 1,
  "generated_at": "2026-08-11T21:20:00Z",
  "host": "host-a",
  "totals": { "degraded": true },
  "runs": [
    {"run_id":"rg1","repo_slug":"foo","issue_number":30,"issue_url":"https://github.com/Silon-Oy/foo/issues/30","pr_url":null,"pr_number":null,"age_seconds":100000,"class":"attention","class_reason":"blocked","current_state":"S5_DBClone","github":null}
  ],
  "read_errors": [ {"path":"/x/run.json","error":"invalid_json"} ]
}
JSON
rm -f "$STATE"
run "$FXD" --dry-run
check "degraded: exit 0" "$RC" "0"
if printf '%s' "$OUT" | grep -q "Vajaa luenta"; then ok "degraded: warning line present"; else bad "degraded: warning line missing"; fi
if printf '%s' "$OUT" | grep -q "#30"; then ok "degraded: github:null run still reported"; else bad "degraded: run missing"; fi

# ---- long list: > MAX_ROWS in one class_reason group -> cap + "…ja M muuta" ----
FXL="$FX/long.json"
jq -n '{schema_version:1, generated_at:"2026-08-11T22:00:00Z", host:"host-a",
  totals:{degraded:false},
  runs: [range(0;12) | {run_id:"L\(.)", repo_slug:"foo", issue_number:(100+.),
    issue_url:"https://github.com/Silon-Oy/foo/issues/\(100+.)", pr_url:null, pr_number:null,
    age_seconds:(1000000 - .*1000), class:"attention", class_reason:"blocked",
    current_state:"S5_DBClone"}],
  read_errors: [] }' > "$FXL"
run "$FXL" --dry-run
if printf '%s' "$OUT" | grep -q "…ja 2 muuta"; then ok "long list: truncation marker present"; else bad "long list: no '…ja M muuta'"; fi
check "long list: capped at 10 rows" "$(printf '%s' "$OUT" | grep -c '    foo  #')" "10"

# ---- without gws (already the mode) but WITH a recipient -> stdout + exit 0 ----
rm -f "$STATE"
OUT="$(RUN_ISSUES_DIGEST_GWS="/nonexistent/gws" RUN_ISSUES_DIGEST_STATE_FILE="$STATE" \
       RUN_ISSUES_DIGEST_ENV_FILE="/nonexistent/digest.env" \
       bash "$DIGEST" --from-file "$FXA" --to "maintainer@example.com" 2>/dev/null)"; RC=$?
check "no-gws + recipient -> exit 0" "$RC" "0"
if [ -n "$OUT" ]; then ok "no-gws + recipient -> body on stdout"; else bad "no-gws + recipient -> no body"; fi

# ---- stdin input path ----
rm -f "$STATE"
OUT="$(RUN_ISSUES_DIGEST_GWS="/nonexistent/gws" RUN_ISSUES_DIGEST_STATE_FILE="$STATE" \
       RUN_ISSUES_DIGEST_ENV_FILE="/nonexistent/digest.env" \
       bash "$DIGEST" --dry-run < "$FXA" 2>/dev/null)"; RC=$?
check "stdin input -> exit 0" "$RC" "0"
if printf '%s' "$OUT" | grep -q "#92"; then ok "stdin: body built from stdin"; else bad "stdin: body missing"; fi

# ---- large real-world input must complete (regression: bash 3.2 pattern
# substitution on the whole input is effectively quadratic — a ~400 KB
# pretty-printed document spun forever in ${INPUT// /}) ----
if command -v timeout >/dev/null 2>&1; then
  FXBIG="$FX/big.json"
  jq -n '{schema_version: 1, generated_at: "2026-08-11T20:49:34Z", host: "host-a",
          totals: {degraded: false},
          runs: [range(400) | {run_id: "run-\(.)", repo_slug: "some-repo",
                 issue_number: ., issue_url: "https://example.invalid/\(.)",
                 status: "completed", class: "cleanup", class_reason: "pr_not_open",
                 age_seconds: 1000, branch: "auto-run/issue-\(.)-padding-padding-padding",
                 current_state: "S12_Finalize", blocked_reason: null, github: null}],
          read_errors: []}' > "$FXBIG"
  SIZE="$(wc -c < "$FXBIG" | tr -d ' ')"
  rm -f "$STATE"
  RUN_ISSUES_DIGEST_GWS="/nonexistent/gws" RUN_ISSUES_DIGEST_STATE_FILE="$STATE" \
    RUN_ISSUES_DIGEST_ENV_FILE="/nonexistent/digest.env" \
    timeout 15 bash "$DIGEST" --dry-run --from-file "$FXBIG" >/dev/null 2>&1; rc=$?
  check "large input (${SIZE} bytes) completes within 15s" "$rc" "0"
else
  echo "SKIP: timeout not installed (large-input regression)"
fi

# ---- usage errors -> exit 1 ----
RUN_ISSUES_DIGEST_ENV_FILE="/nonexistent/digest.env" bash "$DIGEST" --min-class bogus < "$FXA" >/dev/null 2>&1; rc=$?
check "bad --min-class -> exit 1" "$rc" "1"
RUN_ISSUES_DIGEST_ENV_FILE="/nonexistent/digest.env" bash "$DIGEST" --unknown-flag < "$FXA" >/dev/null 2>&1; rc=$?
check "unknown flag -> exit 1" "$rc" "1"
printf 'not json at all' | RUN_ISSUES_DIGEST_ENV_FILE="/nonexistent/digest.env" bash "$DIGEST" >/dev/null 2>&1; rc=$?
check "invalid JSON input -> exit 1" "$rc" "1"

echo "----------------------------------------"
echo "status-digest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
