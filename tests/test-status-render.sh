#!/usr/bin/env bash
# test-status-render.sh — status-render.sh turns status.sh's --json document into
# a self-contained web app: a static, data-free HTML page with inline CSS + inline
# JS that fetches status.json in the browser and renders a grouped, filterable,
# Finnish-explained view (#76). This test guards the properties that keep it safe
# to serve from a read-only directory AND the new client-side structure:
#
#   1. It writes both files atomically; status.json is the input verbatim.
#   2. Self-contained: inline <style> + inline <script>, NO external resource
#      (no <link>, no src=, no http URL in src/href except github.com links the
#      JS builds at runtime). The page fetches status.json (same directory).
#   3. FIELD ALLOWLIST: forbidden fields (issue title, log content) never appear
#      in the page markup — the JS reads only named fields, never the raw object.
#   4. SAFE INSERTION: data is inserted with textContent, never innerHTML, so a
#      branch literally named "<script>" can never execute.
#   5. Every class_reason documented in lib/status-read.sh has a Finnish entry in
#      the JS REASONS map; grouping/filter structure (data-class/data-repo,
#      cleanup summary, chips, auto-refresh) is present.
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
presenti(){ if grep -qiF -- "$2" "$3"; then ok "$1"; else bad "$1: '$2' missing from $3"; fi; }

FX="$(mktemp -d "${TMPDIR:-/tmp}/status-render-test.XXXXXX")"
trap 'rm -rf "$FX"' EXIT
LOGS="$FX/logs"

# A document that deliberately carries FORBIDDEN fields (issue title + log
# content) alongside the allowlisted ones, and a branch name that is an XSS
# payload. The page markup must show neither forbidden field; the JS must insert
# the branch with textContent (verified structurally — no browser here).
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

# ---- Case 1: both files written; status.json == input verbatim ----
check "exit code clean" "$rc" "0"
if [ -f "$HTML" ]; then ok "index.html written"; else bad "index.html missing"; fi
if [ -f "$JSONOUT" ]; then ok "status.json written"; else bad "status.json missing"; fi
if [ -f "$JSONOUT" ] && diff -q <(jq -S . "$FX/doc.json") <(jq -S . "$JSONOUT") >/dev/null 2>&1; then
  ok "status.json is the input verbatim"
else
  bad "status.json differs from the input"
fi

# ---- Case 2: self-contained page, no external resource ----
if [ -f "$HTML" ]; then
  present "inline <style> present" "<style>" "$HTML"
  present "inline <script> present" "<script>" "$HTML"
  present "fetches status.json" 'fetch("status.json"' "$HTML"
  absent  "no external stylesheet <link>" "<link" "$HTML"
  # No embedded/fetched resource or inline event handler. <a href> links are
  # user navigation, not fetched resources, so they are fine.
  if grep -Eq '(src=|<iframe|onload=|javascript:)' "$HTML"; then
    bad "HTML pulls an external/embedded resource or inline JS handler"
  else
    ok "no fetched resource / inline JS handler"
  fi
  # Criterion 5: no http(s) URL in a src/href attribute (github.com excepted —
  # the JS builds those links at runtime, they are not in the static markup).
  EXT="$(grep -oE '(src|href)="[^"]*"' "$HTML" | grep -oE 'https?://[^"]*' | grep -v 'github.com' || true)"
  if [ -z "$EXT" ]; then ok "no external resource URL in static markup"; else bad "external URL in markup: $EXT"; fi
fi

# ---- Case 3: field allowlist — forbidden fields never in the page markup ----
if [ -f "$HTML" ]; then
  absent "issue title does not leak into HTML" "$TITLE_LEAK" "$HTML"
  absent "log content does not leak into HTML" "$LOG_LEAK" "$HTML"
  # The JS must not reference the forbidden log field name at all.
  absent "JS does not read log_excerpt" "log_excerpt" "$HTML"
fi

# ---- Case 4: safe insertion via textContent, never innerHTML ----
if [ -f "$HTML" ]; then
  absent  "raw <script>alert not present (data is fetched, not embedded)" "<script>alert" "$HTML"
  present "data inserted via textContent" "textContent" "$HTML"
  absent  "no .innerHTML property use" ".innerHTML" "$HTML"
fi

# ---- Case 5: reason coverage + client-side structure ----
if [ -f "$HTML" ]; then
  # Every documented class_reason (lib/status-read.sh) has a Finnish entry.
  MISSING=""
  while read -r reason; do
    [ -n "$reason" ] || continue
    grep -qF "$reason" "$HTML" || MISSING="$MISSING $reason"
  done < <(grep -oE 'class_reason:"[a-z_]+"' "$ROOT/lib/status-read.sh" \
             | sed 's/class_reason:"//; s/"//' | sort -u)
  if [ -z "$MISSING" ]; then ok "every class_reason has a Finnish explanation"
  else bad "class_reason(s) without explanation:$MISSING"; fi

  # Spec-mandated exact wordings.
  presenti "awaiting_clarification wording" "botin kysymys odottaa vastaustasi issuessa" "$HTML"
  presenti "pr_unlabelled wording" "PR ilman auto-merge-labelia — vahti ei koske siihen" "$HTML"

  # Grouping / filter / sort structure.
  present "row carries data-class" 'data-class' "$HTML"
  present "row carries data-repo" 'data-repo' "$HTML"
  present "filter chips present" "Huomiota" "$HTML"
  present "PR matkalla chip present" "PR matkalla" "$HTML"
  present "Siivousjono chip present" "Siivousjono" "$HTML"
  present "cleanup summary row" "valmista ajoa" "$HTML"
  present "empty view text" "Ei ajoja" "$HTML"
  present "degraded warning text" "Vajaa luenta" "$HTML"
  present "connection-lost text" "Yhteys katkennut" "$HTML"
  present "first-load recovery hint" "status.sh --human" "$HTML"

  # Auto-refresh every 60 s.
  present "auto-refresh interval" "setInterval" "$HTML"
  present "60 second cadence" "60000" "$HTML"

  # Light default theme + dark via media query.
  present "light default background" "#ffffff" "$HTML"
  present "dark theme media query" "prefers-color-scheme: dark" "$HTML"

  # noscript fallback.
  present "noscript fallback" "<noscript>" "$HTML"
fi

# ---- Case 5b: degraded + zero-runs document still renders (exit 0, verbatim) ----
# The page markup is data-free, so it is identical regardless of input; this case
# exercises the schema gate + verbatim status.json on a different document.
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
if [ -f "$OUT2/status.json" ] && diff -q <(jq -S . "$FX/degraded.json") <(jq -S . "$OUT2/status.json") >/dev/null 2>&1; then
  ok "degraded status.json is the input verbatim"
else
  bad "degraded status.json differs from the input"
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
  present "rendered the status page" "run-issues status" "$OUT4/index.html"
else
  bad "LaunchAgent path did not produce both files"
fi

echo "----------------------------------------"
echo "status-render: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
