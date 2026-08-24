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

# Isolate from the DEVELOPER's real poller.env: status-render.sh sources
# ${RUN_ISSUES_POLLER_ENV_FILE:-~/.config/run-issues/poller.env} (the LaunchAgent
# config channel, #78), and a machine that sets RUN_ISSUES_RENDER_GITHUB /
# RUN_ISSUES_ACTION_BASE there would override this test's per-case env (the file
# wins). Point it at a non-regular path so the sourcing guard (`[ -f … ]`) skips
# it — every case then sees ONLY the env it sets itself.
export RUN_ISSUES_POLLER_ENV_FILE=/dev/null

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

# ---- Case 4b: github enrichment (#78) — issue title + CI/verdict chips ----
# A document whose run carries a `github` sub-object with the allowlisted fields
# PLUS a bogus extra field. The page markup is data-free, so no value appears in
# it; the allowlist is enforced by the JS reading only NAMED github fields. This
# case asserts the JS references exactly those names (and not the bogus one) and
# that the Finnish CI/verdict wordings are present.
GH_TITLE="GH-ISSUE-TITLE-marker-xyz"
GH_LEAK="GHFIELD-LEAK-should-not-appear"
cat > "$FX/gh.json" <<JSON
{"schema_version":1,"generated_at":"2026-08-11T22:00:00Z","host":"studio",
 "stale_after_seconds":3600,
 "enrichment":{"mode":"github","fetched_at":"2026-08-11T22:00:00Z","cache_age_seconds":120,"repos_enriched":1,"repos_failed":[]},
 "totals":{"runs":1,"by_class":{"running":0,"stalled":0,"attention":0,"pr_in_flight":1,"cleanup":0},"degraded":false},
 "read_errors":[],
 "runs":[
  {"repo_slug":"acme-site","issue_number":42,
   "issue_url":"https://github.com/acme/acme-site/issues/42",
   "class":"pr_in_flight","class_reason":"pr_open_waiting","class_confidence":"high",
   "current_state":"S12_Finalize","branch":"auto-run/x",
   "age_seconds":9300,"idle_seconds":null,
   "pr_url":"https://github.com/acme/acme-site/pull/9","pr_number":9,
   "github":{"pr_state":"OPEN","ci":"RED","pr_decide_verdict":"WAIT_CI",
             "cache_age_seconds":120,"issue_title":"$GH_TITLE","is_draft":false,
             "secret_gh_field":"$GH_LEAK"}}
 ]}
JSON
OUTGH="$FX/wwwgh"
RUN_ISSUES_STATUS_OUT_DIR="$OUTGH" RUN_ISSUES_LOG_DIR="$LOGS" \
  bash "$RENDER" --input "$FX/gh.json"; rcgh=$?
HTMLGH="$OUTGH/index.html"
check "github doc renders (exit 0)" "$rcgh" "0"
if [ -f "$HTMLGH" ]; then
  # Data-free page: neither the title value nor the bogus field value appear.
  absent "issue title value not embedded (data fetched at runtime)" "$GH_TITLE" "$HTMLGH"
  absent "bogus github field value not embedded" "$GH_LEAK" "$HTMLGH"
  # Allowlist: the JS reads these NAMED github fields...
  present "JS reads github.issue_title" "issue_title" "$HTMLGH"
  present "JS reads github.pr_state" "pr_state" "$HTMLGH"
  present "JS reads github.pr_decide_verdict" "pr_decide_verdict" "$HTMLGH"
  present "JS reads github.cache_age_seconds" "cache_age_seconds" "$HTMLGH"
  # ...and NOT the bogus one (and never iterates the github object).
  absent "JS does not reference bogus github field" "secret_gh_field" "$HTMLGH"
  # Finnish CI + verdict wordings from the spec.
  presenti "verdict MERGE wording" "vahti mergeää seuraavalla tikillä" "$HTMLGH"
  presenti "verdict WAIT_CI wording" "odottaa CI:tä" "$HTMLGH"
  presenti "verdict SKIP_NO_LABEL wording" "ei auto-merge-labelia" "$HTMLGH"
  presenti "CI green label" "CI vihreä" "$HTMLGH"
  presenti "CI red label" "CI punainen" "$HTMLGH"
fi

# ---- Case 4c: epic rollup lane (#79) --------------------------------------
# A document with an epics[] list and an epic title that is an XSS payload. The
# page markup is data-free, so no epic value appears in it; the epic lane is
# rendered client-side. This case asserts the JS references the named epic fields
# (and renders lanes) and carries the spec's Finnish wordings, and that the epic
# title value never lands in the static markup.
EPIC_TITLE_LEAK="EPIC-TITLE-<script>alert(2)</script>-SECRET"
cat > "$FX/epic.json" <<JSON
{"schema_version":1,"generated_at":"2026-08-11T22:30:00Z","host":"studio",
 "stale_after_seconds":3600,
 "enrichment":{"mode":"github","fetched_at":"2026-08-11T22:30:00Z","cache_age_seconds":60,"repos_enriched":1,"repos_failed":[]},
 "totals":{"runs":1,"by_class":{"running":1,"stalled":0,"attention":0,"pr_in_flight":0,"cleanup":0},"degraded":false},
 "read_errors":[],
 "runs":[
  {"repo_slug":"acme-site","issue_number":11,
   "issue_url":"https://github.com/acme/acme-site/issues/11",
   "class":"running","class_reason":"active_session","class_confidence":"high",
   "current_state":"S8_Implementer","branch":"auto-run/x",
   "age_seconds":300,"idle_seconds":60,"github":null}
 ],
 "epics":[
  {"repo_slug":"acme-site","epic_number":10,"epic_title":"$EPIC_TITLE_LEAK",
   "epic_url":"https://github.com/acme/acme-site/issues/10","source":"sub_issues",
   "sub_issues":[{"number":11,"state":"open","repo":"acme/acme-site","repo_slug":"acme-site"},
                 {"number":12,"state":"open","repo":"acme/acme-site","repo_slug":"acme-site"},
                 {"number":13,"state":"closed","repo":"acme/other","repo_slug":"other"}]}
 ]}
JSON
OUTEP="$FX/wwwep"
RUN_ISSUES_STATUS_OUT_DIR="$OUTEP" RUN_ISSUES_LOG_DIR="$LOGS" \
  bash "$RENDER" --input "$FX/epic.json"; rcep=$?
HTMLEP="$OUTEP/index.html"
check "epic doc renders (exit 0)" "$rcep" "0"
if [ -f "$HTMLEP" ]; then
  # Data-free page: the epic title value (incl. its XSS payload) never appears.
  absent "epic title value not embedded" "$EPIC_TITLE_LEAK" "$HTMLEP"
  absent "epic title XSS not embedded" "<script>alert(2)" "$HTMLEP"
  # Allowlist: the JS reads these NAMED epic fields and renders lanes.
  present "JS reads data.epics" "data.epics" "$HTMLEP"
  present "JS renders epic lanes" "renderEpicLane" "$HTMLEP"
  present "JS reads sub_issues" "sub_issues" "$HTMLEP"
  present "JS reads epic_title" "epic_title" "$HTMLEP"
  present "JS reads epic_number" "epic_number" "$HTMLEP"
  present "JS reads epic_url" "epic_url" "$HTMLEP"
  # Spec-mandated epic wordings.
  present "epic badge" "EPIC" "$HTMLEP"
  presenti "progress valmis wording" "valmis" "$HTMLEP"
  presenti "queue blocker wording" "jonossa · estäjä #" "$HTMLEP"
  presenti "odottaa poimintaa wording" "odottaa poimintaa" "$HTMLEP"
  # Dedup: epic-member runs are shown inside the lane, not as loose rows. Guard
  # the mechanism (epicMember set + subKey join) is present.
  present "epic dedup via epicMember" "epicMember" "$HTMLEP"
  # Cross-repo children (issue #92): the JS joins each sub by its OWN repo_slug
  # (subSlug) and tags a cross-repo sub with its repo. Guard both mechanisms — the
  # page is data-free so we assert the JS reads the fields + renders the tag.
  present "JS reads sub repo_slug via subSlug" "subSlug" "$HTMLEP"
  present "JS reads sub_issues[].repo_slug" "s.repo_slug" "$HTMLEP"
  present "JS renders cross-repo tag" "epic-sub-repo" "$HTMLEP"
  # Unreadable child-set (issue #91): the JS keeps such a lane VISIBLE and shows a
  # note instead of a progress bar (goal 3 — never silently vanish, never false
  # progress). The page is data-free, so guard the JS branch + wording.
  present "JS handles unreadable source" 'source === "unreadable"' "$HTMLEP"
  presenti "unreadable epic note wording" "lapsijoukkoa ei saatu luettua" "$HTMLEP"
fi

# ---- Case 4d: runner version state banner (#105) --------------------------
# A document whose top-level `runner` object is pin_pending, with a version sha
# that is an XSS payload. The page markup is data-free, so the sha value never
# lands in it; the banner is rendered client-side. This case asserts the JS reads
# the named runner fields, has the up_to_date guard (=> nothing shown when healthy),
# carries distinct pin_pending / behind_upstream wordings, and that pin_pending's
# wording reads as self-correcting (never a warning). The XSS sha must not appear.
RUNNER_SHA_LEAK="RUNNERSHA-<script>alert(3)</script>-SECRET"
cat > "$FX/runner.json" <<JSON
{"schema_version":1,"generated_at":"2026-08-11T23:30:00Z","host":"studio",
 "stale_after_seconds":3600,
 "runner":{"version":"$RUNNER_SHA_LEAK","behind_origin":14,"pinned_version":"deadbee",
           "update_state":"pin_pending","pin_age_seconds":12600},
 "enrichment":{"mode":"local","fetched_at":null,"cache_age_seconds":null},
 "totals":{"runs":0,"by_class":{"running":0,"stalled":0,"attention":0,"pr_in_flight":0,"cleanup":0},"degraded":false},
 "read_errors":[],"runs":[],"epics":[]}
JSON
OUTRN="$FX/wwwrn"
RUN_ISSUES_STATUS_OUT_DIR="$OUTRN" RUN_ISSUES_LOG_DIR="$LOGS" \
  bash "$RENDER" --input "$FX/runner.json"; rcrn=$?
HTMLRN="$OUTRN/index.html"
check "runner doc renders (exit 0)" "$rcrn" "0"
if [ -f "$HTMLRN" ]; then
  # Data-free page: the version sha value (incl. its XSS payload) never appears.
  absent "runner sha value not embedded" "$RUNNER_SHA_LEAK" "$HTMLRN"
  absent "runner sha XSS not embedded" "<script>alert(3)" "$HTMLRN"
  # Allowlist: the JS reads the named runner fields and renders the banner.
  present "JS reads data.runner" "data.runner" "$HTMLRN"
  present "JS renders runner banner" "renderRunner" "$HTMLRN"
  present "JS reads runner.update_state" "update_state" "$HTMLRN"
  present "JS reads runner.pinned_version" "pinned_version" "$HTMLRN"
  present "JS reads runner.behind_origin" "behind_origin" "$HTMLRN"
  present "JS reads runner.pin_age_seconds" "pin_age_seconds" "$HTMLRN"
  # up_to_date guard: a healthy runner shows no element (spec AC #4).
  present "up_to_date guard present" 'update_state === "up_to_date"' "$HTMLRN"
  # Distinct wordings for pin_pending vs behind_upstream, each with a next step.
  presenti "pin_pending label" "Pinni odottaa lykättynä" "$HTMLRN"
  presenti "pin_pending self-correcting wording" "korjaantuu itsestään" "$HTMLRN"
  presenti "behind_upstream label" "Jäljessä yläjuoksusta" "$HTMLRN"
  presenti "behind_upstream next step" "Odota pinnin nostoa" "$HTMLRN"
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

# ---- Case 8: RUN_ISSUES_RENDER_GITHUB toggle drives status.sh --github (#78) ----
# A fake status.sh records its args and emits a valid schema-v1 document, so we
# can assert the toggle passes (or omits) --github WITHOUT any gh/network access.
FAKEHOME="$FX/fakehome"
mkdir -p "$FAKEHOME"
ARGSFILE="$FX/statusargs.txt"
cat > "$FAKEHOME/status.sh" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ARGSFILE"
cat <<'JSON'
{"schema_version":1,"generated_at":"2026-08-11T23:00:00Z","host":"studio",
 "totals":{"runs":0,"by_class":{"running":0,"stalled":0,"attention":0,"pr_in_flight":0,"cleanup":0},"degraded":false},
 "read_errors":[],"runs":[]}
JSON
FAKE
chmod +x "$FAKEHOME/status.sh"

# Toggle ON: status.sh invoked with --github.
: > "$ARGSFILE"
OUT5="$FX/www5"
RUN_ISSUES_HOME="$FAKEHOME" RUN_ISSUES_RENDER_GITHUB=1 \
  RUN_ISSUES_STATUS_OUT_DIR="$OUT5" RUN_ISSUES_LOG_DIR="$LOGS" \
  bash "$RENDER"; rc5=$?
check "RENDER_GITHUB=1 renders (exit 0)" "$rc5" "0"
present "RENDER_GITHUB=1 passes --github to status.sh" "--github" "$ARGSFILE"

# Toggle OFF: plain local read, no --github anywhere.
: > "$ARGSFILE"
OUT6="$FX/www6"
RUN_ISSUES_HOME="$FAKEHOME" RUN_ISSUES_RENDER_GITHUB=0 \
  RUN_ISSUES_STATUS_OUT_DIR="$OUT6" RUN_ISSUES_LOG_DIR="$LOGS" \
  bash "$RENDER"; rc6=$?
check "RENDER_GITHUB=0 renders (exit 0)" "$rc6" "0"
absent "RENDER_GITHUB=0 does NOT pass --github" "--github" "$ARGSFILE"

# ---- Case 9: action channel (#77) — opt-in buttons + token confinement ----
# With RUN_ISSUES_ACTION_BASE set, the page embeds the base URL and the shared
# token as <meta> tags and renders the four buttons. The token must reach ONLY
# index.html, never status.json. Without the base, neither appears (V1 surface).
ACT_TOKFILE="$FX/act-token"
OUT7="$FX/www7"
RUN_ISSUES_ACTION_BASE="http://studio:8081" RUN_ISSUES_ACTION_TOKEN_FILE="$ACT_TOKFILE" \
  RUN_ISSUES_STATUS_OUT_DIR="$OUT7" RUN_ISSUES_LOG_DIR="$LOGS" \
  bash "$RENDER" --input "$FX/doc.json"; rc7=$?
check "action-base doc renders (exit 0)" "$rc7" "0"
HTML7="$OUT7/index.html"
if [ -f "$HTML7" ]; then
  present "action base meta filled" 'run-issues-action-base" content="http://studio:8081"' "$HTML7"
  present "action buttons rendered (Pysäytä)" "Pysäytä" "$HTML7"
  present "action buttons rendered (Salli auto-merge)" "Salli auto-merge" "$HTML7"
  present "JS posts to the action endpoint" '"/action"' "$HTML7"
  present "JS sends the CSRF header" "X-Run-Issues-Action" "$HTML7"
  present "JS probes /healthz for service liveness" "/healthz" "$HTML7"
  # Turvamalli 6 / edge case: buttons disable with a message when the service is
  # down. The page still renders (read surface); the JS carries the disabled path.
  present "service-down disables buttons with a message" "Toimintopalvelu ei tavoitettavissa" "$HTML7"
  present "confirmation names the consequences (worktree/haara/run-dir)" "run-dir" "$HTML7"
  if [ -s "$ACT_TOKFILE" ]; then
    ok "token file created (0600 in production)"
    TOKVAL="$(head -n1 "$ACT_TOKFILE")"
    present "token embedded in index.html" "$TOKVAL" "$HTML7"
    absent  "token NEVER in status.json" "$TOKVAL" "$OUT7/status.json"
  else
    bad "token file not created"
  fi
fi

# Without the base: no buttons, no token embedded (pure V1 read surface).
OUT8="$FX/www8"
RUN_ISSUES_STATUS_OUT_DIR="$OUT8" RUN_ISSUES_LOG_DIR="$LOGS" \
  bash "$RENDER" --input "$FX/doc.json" >/dev/null 2>&1
HTML8="$OUT8/index.html"
if [ -f "$HTML8" ]; then
  present "action-base meta empty without config" 'run-issues-action-base" content=""' "$HTML8"
  present "action-token meta empty without config" 'run-issues-action-token" content=""' "$HTML8"
fi

echo "----------------------------------------"
echo "status-render: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
