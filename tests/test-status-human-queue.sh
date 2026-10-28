#!/usr/bin/env bash
# test-status-human-queue.sh — status.sh --github's human_queue (issue #414).
#
# A `gh` shim on PATH answers the REST listings and counts its calls. Covers:
# a watchlist repo WITHOUT any local run is swept; only runner PRs (auto-run/
# head) carrying manual-merge or needs-human are queued, with only those two
# labels carried; the waiting time comes from the PR's labelled event, falling
# back to created_at (waiting_source "created"); oldest first; a failing repo
# lands in repos_failed while the others still report and the exit code stays
# 0; REST only (no `pr list --label` / `--search`); the call count is one
# listing per page per repo plus one events read per queued PR, a cache hit
# makes zero calls, and a cache miss carries a labelling time (zero events
# reads); a page cap marks the repo truncated; local mode emits null.
#
# Run: bash tests/test-status-human-queue.sh   (exit 0 = all pass)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
STATUS="$ROOT/status.sh"

if ! command -v jq >/dev/null 2>&1; then echo "SKIP: jq not installed"; exit 0; fi
if ! command -v git >/dev/null 2>&1; then echo "SKIP: git not installed"; exit 0; fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got=[$2] expected=[$3]"; fi; }

FX="$(mktemp -d "${TMPDIR:-/tmp}/status-hq-test.XXXXXX")"
trap 'rm -rf "$FX"' EXIT

# Three watchlist repos, none with a run-dir: the human queue must not depend
# on local runs. repo-c's listing fails.
mkrepo() {
  mkdir -p "$FX/$1"
  git -C "$FX/$1" init -q
  git -C "$FX/$1" remote add origin "https://github.com/o/$1.git"
}
mkrepo repo-a; mkrepo repo-b; mkrepo repo-c
WL="$FX/watchlist.json"
cat > "$WL" <<JSON
{"repos":[{"path":"$FX/repo-a"},{"path":"$FX/repo-b"},{"path":"$FX/repo-c"}]}
JSON

BIN="$FX/bin"; mkdir -p "$BIN"
CALLS="$FX/gh-calls.txt"; : > "$CALLS"
cat > "$BIN/gh" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS"
[ "\$1" = "api" ] || { echo "[]"; exit 0; }
case "\$2" in
  repos/o/repo-a/pulls\?state=open*)
    # 1 manual-merge (labelled), 2 needs-human (no labelled event => created),
    # 3 a human's branch, 4 a runner PR without a queue label.
    cat <<'JSON'
[
 {"number":1,"html_url":"https://github.com/o/repo-a/pull/1","title":"<img src=x onerror=alert(1)>","created_at":"2026-10-01T00:00:00Z","head":{"ref":"auto-run/a-1"},"labels":[{"name":"manual-merge"},{"name":"auto-run"}]},
 {"number":2,"html_url":"https://github.com/o/repo-a/pull/2","title":"Two","created_at":"2026-10-10T00:00:00Z","head":{"ref":"auto-run/a-2"},"labels":[{"name":"needs-human"}]},
 {"number":3,"html_url":"https://github.com/o/repo-a/pull/3","title":"Human","created_at":"2026-09-01T00:00:00Z","head":{"ref":"feature/x"},"labels":[{"name":"manual-merge"}]},
 {"number":4,"html_url":"https://github.com/o/repo-a/pull/4","title":"Plain","created_at":"2026-09-01T00:00:00Z","head":{"ref":"auto-run/a-4"},"labels":[{"name":"auto-merge"}]}
]
JSON
    ;;
  repos/o/repo-a/issues/1/events*)
    # The label was added twice; the LAST labelled event counts.
    echo '[{"event":"labeled","label":{"name":"manual-merge"},"created_at":"2026-10-02T00:00:00Z"},{"event":"unlabeled","label":{"name":"manual-merge"},"created_at":"2026-10-03T00:00:00Z"},{"event":"labeled","label":{"name":"manual-merge"},"created_at":"2026-10-05T00:00:00Z"},{"event":"labeled","label":{"name":"auto-run"},"created_at":"2026-09-01T00:00:00Z"}]' ;;
  repos/o/repo-a/issues/2/events*) echo '[]' ;;
  repos/o/repo-b/pulls\?state=open*)
    echo '[{"number":7,"html_url":"https://github.com/o/repo-b/pull/7","title":"Oldest","created_at":"2026-08-01T00:00:00Z","head":{"ref":"auto-run/b-7"},"labels":[{"name":"needs-human"},{"name":"manual-merge"}]}]' ;;
  repos/o/repo-b/issues/7/events*)
    echo '[{"event":"labeled","label":{"name":"needs-human"},"created_at":"2026-09-20T00:00:00Z"},{"event":"labeled","label":{"name":"manual-merge"},"created_at":"2026-09-15T00:00:00Z"}]' ;;
  repos/o/repo-c/pulls*) echo "gh: could not fetch (simulated failure)" >&2; exit 1 ;;
  *) echo "[]" ;;
esac
exit 0
SHIM
chmod +x "$BIN/gh"

CACHE="$FX/cache.json"
run_status() {
  HOME="$FX/home" PATH="$BIN:$PATH" RUN_ISSUES_LOG_DIR="$FX/logs" \
    RUN_ISSUES_WATCHLIST="$WL" RUN_ISSUES_STATUS_CACHE_FILE="$CACHE" \
    bash "$STATUS" "$@"
}
count() { grep -c "$1" "$CALLS" 2>/dev/null || true; }

# ---- local mode: null, so "not asked" differs from "no queue" ----
OUT="$FX/local.json"
run_status --json > "$OUT" 2>/dev/null
check "local mode: human_queue null" "$(jq -c '.human_queue' "$OUT")" "null"
check "local mode: no gh call" "$(wc -l < "$CALLS" | tr -d ' ')" "0"

# ---- first --github run ----
: > "$CALLS"
OUT="$FX/out1.json"
run_status --json --github > "$OUT" 2>/dev/null; rc=$?
check "exit 0 despite repo-c failing" "$rc" "0"
check "queue order oldest first" "$(jq -c '[.human_queue.prs[] | "\(.repo)#\(.number)"]' "$OUT")" \
  '["o/repo-b#7","o/repo-a#1","o/repo-a#2"]'
check "repos_failed == [o/repo-c]" "$(jq -c '.human_queue.repos_failed' "$OUT")" '["o/repo-c"]'
check "repos_truncated empty" "$(jq -c '.human_queue.repos_truncated' "$OUT")" '[]'
hq() { jq -c --arg r "$1" --argjson n "$2" '.human_queue.prs[] | select(.repo == $r and .number == $n)' "$OUT"; }
check "#1 last labelled event" "$(hq o/repo-a 1 | jq -r '.waiting_since')" "2026-10-05T00:00:00Z"
check "#1 source labeled" "$(hq o/repo-a 1 | jq -r '.waiting_source')" "labeled"
check "#1 only queue labels carried" "$(hq o/repo-a 1 | jq -c '.labels')" '["manual-merge"]'
check "#1 title verbatim (escaped by the renderer)" "$(hq o/repo-a 1 | jq -r '.title')" '<img src=x onerror=alert(1)>'
check "#1 url" "$(hq o/repo-a 1 | jq -r '.url')" "https://github.com/o/repo-a/pull/1"
check "#1 repo_slug from the watchlist checkout" "$(hq o/repo-a 1 | jq -r '.repo_slug')" "o-repo-a"
check "#1 waiting_seconds is a number" "$(hq o/repo-a 1 | jq -r '.waiting_seconds | type')" "number"
check "#2 falls back to created_at" "$(hq o/repo-a 2 | jq -r '.waiting_since')" "2026-10-10T00:00:00Z"
check "#2 source created" "$(hq o/repo-a 2 | jq -r '.waiting_source')" "created"
check "#7 earliest of the two labels" "$(hq o/repo-b 7 | jq -r '.waiting_since')" "2026-09-15T00:00:00Z"
check "human's branch not queued" "$(hq o/repo-a 3 | wc -l | tr -d ' ')" "0"
check "unlabelled runner PR not queued" "$(hq o/repo-a 4 | wc -l | tr -d ' ')" "0"

# Cost: one listing per repo (one page each) + one events read per queued PR.
check "one pulls listing per repo (3)" "$(count '/pulls?state=open')" "3"
check "one events read per queued PR (3)" "$(count '/events')" "3"
check "no search-routed calls" "$(count -e '--label' -e '--search' -e 'search/')" "0"

# ---- fresh cache: zero calls of the human queue ----
: > "$CALLS"
run_status --json --github > "$FX/out2.json" 2>/dev/null
check "cache hit: no pulls listing for cached repos (only failed repo-c)" "$(count '/pulls?state=open')" "1"
check "cache hit: no events reads" "$(count '/events')" "0"
check "cache hit: same queue" "$(jq -c '[.human_queue.prs[] | .number]' "$FX/out2.json")" '[7,1,2]'

# ---- cache miss: listing again, labelling time carried (only #2 re-read) ----
: > "$CALLS"
run_status --json --github --cache-ttl 0 > "$FX/out3.json" 2>/dev/null
check "cache miss: pulls listed again (3)" "$(count '/pulls?state=open')" "3"
check "cache miss: only the created-fallback PR re-read (1)" "$(count '/events')" "1"
check "cache miss: carried time kept" \
  "$(jq -r '.human_queue.prs[] | select(.number == 7) | .waiting_since' "$FX/out3.json")" "2026-09-15T00:00:00Z"

# ---- --repo restricts the sweep ----
: > "$CALLS"
run_status --json --github --no-cache --repo "$FX/repo-b" > "$FX/out4.json" 2>/dev/null
check "--repo: only that repo listed" "$(count '/pulls?state=open')" "1"
check "--repo: only its PR" "$(jq -c '[.human_queue.prs[] | .number]' "$FX/out4.json")" '[7]'

# ---- page cap: a full page at the cap marks the repo truncated ----
FULL="$FX/full.json"
jq -nc '[range(100) | {number: (100 + .), html_url: "u", title: "t", created_at: "2026-10-01T00:00:00Z", head: {ref: "auto-run/x"}, labels: [{name: "needs-human"}]}]' > "$FULL"
cat > "$BIN/gh" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS"
case "\$2" in
  repos/o/repo-a/pulls*) cat "$FULL" ;;
  *) echo "[]" ;;
esac
SHIM
chmod +x "$BIN/gh"
: > "$CALLS"
RUN_ISSUES_STATUS_HUMAN_QUEUE_PAGES=1 run_status --json --github --no-cache --repo "$FX/repo-a" > "$FX/out5.json" 2>/dev/null
check "page cap: repo truncated" "$(jq -c '.human_queue.repos_truncated' "$FX/out5.json")" '["o/repo-a"]'
check "page cap: one page read" "$(count '/pulls?state=open')" "1"
check "page cap: rows kept" "$(jq -r '.human_queue.prs | length' "$FX/out5.json")" "100"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
