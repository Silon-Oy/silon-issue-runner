#!/usr/bin/env bash
# test-status-render.sh — status-render.sh turns status.sh's --json document into
# a static, leak-safe web page. This test guards the properties that make it
# safe to serve from a read-only directory:
#
#   1. It writes both files atomically; status.json is the input verbatim.
#   2. The HTML is self-contained: inline CSS, no <script>, no fetched resource.
#   3. FIELD ALLOWLIST: forbidden fields (issue title, log content) never appear,
#      even when present in the input data.
#   4. HTML ESCAPING: a branch literally named "<script>" renders escaped.
#   5. cache age + generated_at are always shown; degraded:true shows a warning;
#      zero runs still renders a valid page.
#   6. A document with an unknown schema_version leaves the previous page intact
#      (exit 2), never overwriting a good page with a broken render.
#   7. The LaunchAgent path works: invoked with no --input it drives status.sh
#      itself and produces the two files.
#
# Run: bash tests/test-status-render.sh   (exit 0 = all pass)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RENDER="$ROOT/status-render.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed"
  exit 0
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got=[$2] expected=[$3]"; fi; }
absent(){ if grep -qF -- "$2" "$3"; then bad "$1: '$2' present in $3"; else ok "$1"; fi; }
present(){ if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1: '$2' missing from $3"; fi; }

FX="$(mktemp -d "${TMPDIR:-/tmp}/status-render-test.XXXXXX")"
trap 'rm -rf "$FX"' EXIT
LOGS="$FX/logs"

# A document that deliberately carries FORBIDDEN fields (issue title + log
# content) alongside the allowlisted ones, and a branch name that is an XSS
# payload. The renderer must show neither forbidden field and must escape the
# branch.
TITLE_LEAK="TOP-SECRET-CLIENT-ACME-CORP"
LOG_LEAK="AGENT-LOG-EXCERPT-abc123-should-not-appear"
cat > "$FX/doc.json" <<JSON
{"schema_version":1,"generated_at":"2026-08-11T20:00:00Z","host":"studio",
 "stale_after_seconds":3600,
 "enrichment":{"mode":"local","fetched_at":null,"cache_age_seconds":null},
 "totals":{"runs":1,"by_class":{"running":0,"stalled":0,"attention":1,"pr_in_flight":0,"cleanup":0},"degraded":false},
 "read_errors":[],
 "runs":[
  {"repo_slug":"acme-site","issue_number":42,
   "issue_url":"https://github.com/acme/acme-site/issues/42",
   "class":"attention","class_reason":"blocked",
   "current_state":"S6_CycleReview",
   "branch":"auto-run/<script>alert(1)</script>",
   "blocked_reason":"cycle_review_blocker",
   "age_seconds":93600,"idle_seconds":null,
   "pr_url":"https://github.com/acme/acme-site/pull/9","pr_number":9,
   "title":"$TITLE_LEAK","body":"$TITLE_LEAK in the body too",
   "log_excerpt":"$LOG_LEAK"}
 ]}
JSON

OUT="$FX/www"
RUN_ISSUES_STATUS_OUT_DIR="$OUT" RUN_ISSUES_LOG_DIR="$LOGS" \
  bash "$RENDER" --input "$FX/doc.json"; rc=$?
HTML="$OUT/index.html"
JSONOUT="$OUT/status.json"

# ---- Case 1: both files written; status.json == input ----
check "exit code clean" "$rc" "0"
if [ -f "$HTML" ]; then ok "index.html written"; else bad "index.html missing"; fi
if [ -f "$JSONOUT" ]; then ok "status.json written"; else bad "status.json missing"; fi
if [ -f "$JSONOUT" ] && diff -q <(jq -S . "$FX/doc.json") <(jq -S . "$JSONOUT") >/dev/null 2>&1; then
  ok "status.json is the input verbatim"
else
  bad "status.json differs from the input"
fi

# ---- Case 2: self-contained HTML ----
if [ -f "$HTML" ]; then
  present "inline <style> present" "<style>" "$HTML"
  absent  "no <script> tag" "<script" "$HTML"
  absent  "no external stylesheet <link>" "<link" "$HTML"
  # No embedded resource the browser would fetch (img/script/iframe src). Note
  # <a href> links are user navigation, not fetched resources, so they are fine.
  if grep -Eq '(src=|<iframe|onload=|javascript:)' "$HTML"; then
    bad "HTML pulls an external/embedded resource or inline JS"
  else
    ok "no fetched resource / inline JS handler"
  fi
fi

# ---- Case 3: field allowlist — forbidden fields never appear ----
if [ -f "$HTML" ]; then
  absent "issue title does not leak into HTML" "$TITLE_LEAK" "$HTML"
  absent "log content does not leak into HTML" "$LOG_LEAK" "$HTML"
fi

# ---- Case 4: HTML escaping of a <script> branch name ----
if [ -f "$HTML" ]; then
  absent  "raw <script>alert not present" "<script>alert" "$HTML"
  present "branch rendered HTML-escaped" "&lt;script&gt;alert(1)&lt;/script&gt;" "$HTML"
fi

# ---- Case 5: cache age + generated_at + counters ----
if [ -f "$HTML" ]; then
  present "generated_at shown" "2026-08-11T20:00:00Z" "$HTML"
  present "cache age label shown" "Cachen ikä" "$HTML"
  present "allowlisted repo_slug shown" "acme-site" "$HTML"
  present "PR link shown" "https://github.com/acme/acme-site/pull/9" "$HTML"
fi

# ---- Case 5b: degraded warning + zero runs ----
cat > "$FX/degraded.json" <<'JSON'
{"schema_version":1,"generated_at":"2026-08-11T21:00:00Z","host":"studio",
 "enrichment":{"mode":"local","cache_age_seconds":120},
 "totals":{"runs":0,"by_class":{"running":0,"stalled":0,"attention":0,"pr_in_flight":0,"cleanup":0},"degraded":true},
 "read_errors":["/x/run.json","/y/run.json"],"runs":[]}
JSON
OUT2="$FX/www2"
RUN_ISSUES_STATUS_OUT_DIR="$OUT2" RUN_ISSUES_LOG_DIR="$LOGS" \
  bash "$RENDER" --input "$FX/degraded.json"; rc2=$?
check "degraded doc renders (exit 0)" "$rc2" "0"
if [ -f "$OUT2/index.html" ]; then
  present "degraded warning shown" "Vajaa luenta" "$OUT2/index.html"
  present "zero runs renders empty page" "Ei ajoja" "$OUT2/index.html"
  present "cache age value shown" "2 min" "$OUT2/index.html"
fi

# ---- Case 6: unknown schema_version leaves the old page intact ----
OUT3="$FX/www3"
mkdir -p "$OUT3"
printf 'PREVIOUS-GOOD-PAGE' > "$OUT3/index.html"
printf '{"prev":true}'      > "$OUT3/status.json"
printf '{"schema_version":2,"runs":[]}\n' > "$FX/v2.json"
RUN_ISSUES_STATUS_OUT_DIR="$OUT3" RUN_ISSUES_LOG_DIR="$LOGS" \
  bash "$RENDER" --input "$FX/v2.json"; rc3=$?
check "unknown schema_version exits 2" "$rc3" "2"
check "old index.html untouched" "$(cat "$OUT3/index.html")" "PREVIOUS-GOOD-PAGE"
check "old status.json untouched" "$(cat "$OUT3/status.json")" '{"prev":true}'

# ---- Case 7: LaunchAgent path — no --input, drives status.sh itself ----
# Build a one-repo watchlist the way test-status-schema.sh does, so status.sh
# produces a real document that status-render then consumes.
REPO="$FX/repo"
RUNS="$REPO/.claude/run-issues/20260601-100000-issue-1"
mkdir -p "$RUNS"
HOST="$(hostname -s 2>/dev/null || echo unknown)"
cat > "$RUNS/run.json" <<JSON
{"run_id":"r1","repo":"$REPO","issue_number":1,"status":"blocked","started_at":"2026-06-01T10:00:00Z","finished_at":"2026-06-01T10:05:00Z","host":"$HOST","current_state":"S6_CycleReview","blocked_reason":"cycle_review_blocker","remote":"origin","repo_slug":"repo","base_branch":"main"}
JSON
cat > "$FX/watchlist.json" <<JSON
{"global_max_concurrent":2,"repos":[{"path":"$REPO","labels":["auto-run"],"remotes":["origin"]}]}
JSON
OUT4="$FX/www4"
HOME="$FX/home" RUN_ISSUES_WATCHLIST="$FX/watchlist.json" \
  RUN_ISSUES_STATUS_OUT_DIR="$OUT4" RUN_ISSUES_LOG_DIR="$LOGS" \
  bash "$RENDER"; rc4=$?
check "LaunchAgent path exits 0 (status.sh exit 3 degraded-ok tolerated)" "$rc4" "0"
if [ -f "$OUT4/index.html" ] && [ -f "$OUT4/status.json" ]; then
  ok "LaunchAgent path produced both files"
  present "rendered from real status.sh output" "run-issues status" "$OUT4/index.html"
else
  bad "LaunchAgent path did not produce both files"
fi

echo "----------------------------------------"
echo "status-render: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
