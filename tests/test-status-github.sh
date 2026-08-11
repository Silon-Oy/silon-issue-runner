#!/usr/bin/env bash
# test-status-github.sh — end-to-end guard for status.sh --github (issue #60).
#
# A `gh` shim on PATH (written into a mktemp bin dir) returns stored JSON
# fixtures and counts its invocations, so the whole enrichment path runs with no
# GitHub access. Covers: the confidence bump (low -> high on a confirmed PR), the
# pr_ci_red path, the UNSTABLE edge (a non-required red does NOT become
# pr_ci_red), a cache hit (the shim's call counter proves gh is NOT called), a
# stale cache (--cache-ttl 0 refetches), a NOT_OPEN PR (=> cleanup), and one
# repo whose fetch fails (repos_failed; the OTHER repo still enriches; exit 0).
#
# Run: bash tests/test-status-github.sh   (exit 0 = all pass)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
STATUS="$ROOT/status.sh"

# Preconditions. jq is the hard dependency of status.sh; git is needed to plant
# the fake remotes that owner-resolution reads. gh itself is provided by the
# shim below — this test never touches the real gh (SKIP: gh not in PATH is thus
# handled structurally: the shim IS the PATH gh for the duration of the run).
if ! command -v jq >/dev/null 2>&1; then echo "SKIP: jq not installed"; exit 0; fi
if ! command -v git >/dev/null 2>&1; then echo "SKIP: git not installed"; exit 0; fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got=[$2] expected=[$3]"; fi; }

FX="$(mktemp -d "${TMPDIR:-/tmp}/status-github-test.XXXXXX")"
trap 'rm -rf "$FX"' EXIT
HOST="$(hostname -s 2>/dev/null || echo unknown)"

# ---- two fake repos with GitHub remotes (owner-resolution reads these) ----
REPO_A="$FX/repo-a"; mkdir -p "$REPO_A"
git -C "$REPO_A" init -q
git -C "$REPO_A" remote add origin https://github.com/o/repo-a.git
RUNS_A="$REPO_A/.claude/run-issues"; mkdir -p "$RUNS_A"

REPO_B="$FX/repo-b"; mkdir -p "$REPO_B"
git -C "$REPO_B" init -q
git -C "$REPO_B" remote add origin https://github.com/o/repo-b.git
RUNS_B="$REPO_B/.claude/run-issues"; mkdir -p "$RUNS_B"

# run_json <dir> <issue> <pr_number> — a completed run whose PR is <pr_number>.
# No pr_classified event => local verdict unknown => pr_in_flight/low locally, so
# a successful enrichment is observable as a confidence bump to high.
run_json() {
  local dir="$1" repo="$2" issue="$3" pr="$4"
  mkdir -p "$dir"
  cat > "$dir/run.json" <<JSON
{"run_id":"$(basename "$dir")","repo":"$repo","issue_number":$issue,"status":"completed","started_at":"2026-08-01T10:00:00Z","finished_at":"2026-08-01T10:05:00Z","host":"$HOST","current_state":"S12_Finalize","remote":"origin","repo_slug":"$(basename "$repo")","pr_url":"https://github.com/o/$(basename "$repo")/pull/$pr"}
JSON
}

run_json "$RUNS_A/r1" "$REPO_A" 1 1   # open, green, CLEAN  -> confidence bump
run_json "$RUNS_A/r2" "$REPO_A" 2 2   # open, RED required   -> pr_ci_red
run_json "$RUNS_A/r3" "$REPO_A" 3 3   # open, UNSTABLE red    -> NOT pr_ci_red
run_json "$RUNS_A/r5" "$REPO_A" 5 5   # PR not in open set    -> NOT_OPEN/cleanup
run_json "$RUNS_B/r9" "$REPO_B" 9 9   # repo-b fetch fails    -> repos_failed

WL="$FX/watchlist.json"
cat > "$WL" <<JSON
{"global_max_concurrent":2,"repos":[{"path":"$REPO_A","remotes":["origin"]},{"path":"$REPO_B","remotes":["origin"]}]}
JSON

# ---- gh shim: returns fixtures for repo-a, FAILS for repo-b, counts calls ----
BIN="$FX/bin"; mkdir -p "$BIN"
CALLS="$FX/gh-calls.txt"; : > "$CALLS"
cat > "$BIN/gh" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS"
repo=""; prev=""
for a in "\$@"; do [ "\$prev" = "--repo" ] && repo="\$a"; prev="\$a"; done
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then
  case "\$repo" in
    o/repo-a)
      cat <<'JSON'
[
 {"number":1,"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","labels":[{"name":"auto-merge"}],"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","name":"ci"}],"reviewDecision":"","headRefName":"h1","baseRefName":"main"},
 {"number":2,"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","labels":[{"name":"auto-merge"}],"statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE","name":"ci"}],"reviewDecision":"","headRefName":"h2","baseRefName":"main"},
 {"number":3,"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"UNSTABLE","labels":[{"name":"auto-merge"}],"statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE","name":"non-required-lint"}],"reviewDecision":"","headRefName":"h3","baseRefName":"main"}
]
JSON
      exit 0
      ;;
    o/repo-b)
      # Simulate a network / rate-limit failure for this repo only.
      echo "gh: could not fetch (simulated failure)" >&2
      exit 1
      ;;
    *) echo "[]"; exit 0 ;;
  esac
fi
exit 0
SHIM
chmod +x "$BIN/gh"

CACHE="$FX/cache.json"
run_status() {
  HOME="$FX/home" PATH="$BIN:$PATH" \
    RUN_ISSUES_WATCHLIST="$WL" RUN_ISSUES_STATUS_CACHE_FILE="$CACHE" \
    bash "$STATUS" "$@"
}
# grep -c prints "0" even on no match (then exits 1); swallow that exit so the
# count is a single clean integer.
pr_list_calls() { grep -c 'pr list' "$CALLS" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# 1) First --github run: fetches, enriches repo-a, fails repo-b.
# ---------------------------------------------------------------------------
: > "$CALLS"
OUT="$FX/out1.json"
run_status --json --github > "$OUT" 2>"$FX/err1.txt"; rc=$?
check "exit 0 on first --github run" "$rc" "0"
jq -e . "$OUT" >/dev/null 2>&1 && ok "output is valid JSON" || bad "output not valid JSON"

check "enrichment.mode github" "$(jq -r '.enrichment.mode' "$OUT")" "github"
check "repos_enriched == 1" "$(jq -r '.enrichment.repos_enriched' "$OUT")" "1"
check "repos_failed == [o/repo-b]" "$(jq -c '.enrichment.repos_failed' "$OUT")" '["o/repo-b"]'
check "enrichment.fetched_at is set" "$(jq -r '.enrichment.fetched_at != null' "$OUT")" "true"
check "enrichment.cache_age_seconds is a number" "$(jq -r '.enrichment.cache_age_seconds | type' "$OUT")" "number"

# gh pr list called ONCE per owner/repo (repo-a + repo-b = 2), not per run.
check "gh pr list called once per owner/repo (2)" "$(pr_list_calls)" "2"

# by-issue lookups.
gi() { jq -c --argjson n "$1" '.runs[] | select(.issue_number==$n)' "$OUT"; }

# #1 confirmed OPEN => confidence bumped low->high; class stays pr_in_flight.
check "#1 github.pr_state OPEN"      "$(gi 1 | jq -r '.github.pr_state')" "OPEN"
check "#1 confidence bumped to high" "$(gi 1 | jq -r '.class_confidence')" "high"
check "#1 class pr_in_flight"        "$(gi 1 | jq -r '.class')" "pr_in_flight"
check "#1 github.ci GREEN"           "$(gi 1 | jq -r '.github.ci')" "GREEN"
check "#1 verdict from pr_decide"    "$(gi 1 | jq -r '.github.pr_decide_verdict')" "MERGE"

# #2 required check red => attention/pr_ci_red.
check "#2 class attention"        "$(gi 2 | jq -r '.class')" "attention"
check "#2 reason pr_ci_red"       "$(gi 2 | jq -r '.class_reason')" "pr_ci_red"
check "#2 github.ci RED"          "$(gi 2 | jq -r '.github.ci')" "RED"

# #3 UNSTABLE + non-required red => ci RED but NOT pr_ci_red (same edge as pr_decide).
check "#3 github.ci RED"                 "$(gi 3 | jq -r '.github.ci')" "RED"
check "#3 merge_state UNSTABLE"          "$(gi 3 | jq -r '.github.merge_state_status')" "UNSTABLE"
check "#3 reason is NOT pr_ci_red"       "$(gi 3 | jq -r '.class_reason != "pr_ci_red"')" "true"
check "#3 confidence high (confirmed)"   "$(gi 3 | jq -r '.class_confidence')" "high"

# #5 not in the open set => NOT_OPEN => cleanup/pr_not_open.
check "#5 github.pr_state NOT_OPEN" "$(gi 5 | jq -r '.github.pr_state')" "NOT_OPEN"
check "#5 class cleanup"            "$(gi 5 | jq -r '.class')" "cleanup"
check "#5 reason pr_not_open"       "$(gi 5 | jq -r '.class_reason')" "pr_not_open"

# #9 repo-b failed => github null + low confidence (local classification untouched).
check "#9 github null (repo failed)" "$(gi 9 | jq -r '.github')" "null"
check "#9 confidence low"            "$(gi 9 | jq -r '.class_confidence')" "low"

# ---------------------------------------------------------------------------
# 2) Cache hit: rerun within TTL => the shim is NOT called for repo-a.
#    (repo-b failed and was not cached, so it is retried — 1 call, not 2.)
# ---------------------------------------------------------------------------
: > "$CALLS"
run_status --json --github > "$FX/out2.json" 2>/dev/null
check "cache hit: repo-a NOT refetched (repo-b retried => 1 call)" "$(pr_list_calls)" "1"
check "cache hit: #1 still enriched from cache" \
  "$(jq -r '.runs[] | select(.issue_number==1) | .github.pr_state' "$FX/out2.json")" "OPEN"
check "cache hit: cache_age_seconds >= 0" \
  "$(jq -r '.enrichment.cache_age_seconds >= 0' "$FX/out2.json")" "true"

# ---------------------------------------------------------------------------
# 3) Stale cache: --cache-ttl 0 forces a refetch of repo-a too.
# ---------------------------------------------------------------------------
: > "$CALLS"
run_status --json --github --cache-ttl 0 > /dev/null 2>&1
check "stale cache (--cache-ttl 0) refetches both repos (2)" "$(pr_list_calls)" "2"

# ---------------------------------------------------------------------------
# 4) --no-cache also refetches.
# ---------------------------------------------------------------------------
: > "$CALLS"
run_status --json --github --no-cache > /dev/null 2>&1
check "--no-cache refetches (2)" "$(pr_list_calls)" "2"

# ---------------------------------------------------------------------------
# 5) Without --github: behaviour is unchanged — github null, gh never called.
# ---------------------------------------------------------------------------
: > "$CALLS"
run_status --json > "$FX/out_local.json" 2>/dev/null
check "local mode: gh never called" "$(pr_list_calls)" "0"
check "local mode: enrichment.mode local" "$(jq -r '.enrichment.mode' "$FX/out_local.json")" "local"
check "local mode: every github null" \
  "$(jq '[.runs[] | select(.github != null)] | length' "$FX/out_local.json")" "0"

echo "----------------------------------------"
echo "status-github: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
