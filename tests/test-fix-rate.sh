#!/usr/bin/env bash
# test-fix-rate.sh — the after-fix meter (issue #314): lib/fix-rate.sh's
# classification heuristic, and status-digest.sh --fix-rate end to end against a
# gh shim on PATH.
#
# The cost guard is the CALL COUNT, asserted explicitly (CLAUDE.md §5.4): three
# REST listings per repo, plus one per extra page the window reaches — and the
# same count with dozens of historical run-dirs on disk, because none is read.
# Also: no --fix-rate => zero gh calls; only `gh api` REST paths are used, never
# `gh issue list --label/--search` (§5.2); a failure or rate limit stays
# fail-soft (exit 0, marked row) and a rate limit stops the sweep.
#
# Run: bash tests/test-fix-rate.sh   (exit 0 = all pass)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DIGEST="$ROOT/status-digest.sh"

for dep in jq git; do
  if ! command -v "$dep" >/dev/null 2>&1; then echo "SKIP: $dep not installed"; exit 0; fi
done

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got=[$2] expected=[$3]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: [$3] not in output:
$2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1: [$3] unexpectedly in output" ;; *) ok "$1" ;; esac; }

FX="$(mktemp -d "${TMPDIR:-/tmp}/fix-rate-test.XXXXXX")"
trap 'rm -rf "$FX"' EXIT
export HOME="$FX/home"; mkdir -p "$HOME"
unset RUN_ISSUES_GITHUB_APP_ID RUN_ISSUES_GITHUB_APP_INSTALLATION_ID \
      RUN_ISSUES_GITHUB_APP_PRIVATE_KEY_PATH RUN_ISSUES_DIGEST_FIX_RATE \
      RUN_ISSUES_DIGEST_FIX_WINDOW_DAYS RUN_ISSUES_DIGEST_FIX_MAX_PAGES

# ---------------------------------------------------------------------------
# 1. fix_rate_classify — the heuristic, no gh at all.
# ---------------------------------------------------------------------------
# shellcheck source=lib/fix-rate.sh
. "$ROOT/lib/fix-rate.sh"
CLS="$(jq -n '{repo: "Org/my.repo", since: "2026-10-01T00:00:00Z",
 pulls: [
  {number: 10, title: "feat: a", merged_at: "2026-10-05T00:00:00Z", merge_commit_sha: "aaa111", head: {ref: "auto-run/x"}},
  {number: 11, title: "feat: b", merged_at: "2026-10-05T00:00:00Z", merge_commit_sha: "bbb222", head: {ref: "auto-run/y"}},
  {number: 12, title: "feat: c", merged_at: "2026-10-05T00:00:00Z", merge_commit_sha: "ccc333", head: {ref: "auto-run/z"}},
  {number: 13, title: "human",   merged_at: "2026-10-05T00:00:00Z", merge_commit_sha: "ddd",    head: {ref: "feature/h"}},
  {number: 14, title: "old",     merged_at: "2026-09-05T00:00:00Z", merge_commit_sha: "eee",    head: {ref: "auto-run/o"}},
  {number: 15, title: "closed",  merged_at: null,                                              head: {ref: "auto-run/c"}},
  {number: 16, title: "feat: d", merged_at: "2026-10-05T00:00:00Z", merge_commit_sha: "fff",    head: {ref: "auto-run/d"}},
  {number: 17, title: "feat: e", merged_at: "2026-10-05T00:00:00Z", merge_commit_sha: "ggg",    head: {ref: "auto-run/e"}},
  {number: 18, title: "feat: f", merged_at: "2026-10-05T00:00:00Z", merge_commit_sha: "hhh",    head: {ref: "auto-run/f"}}],
 commits: [
  {sha: "r1", commit: {message: "Revert \"feat: a\"\n\nThis reverts commit aaa111.", committer: {date: "2026-10-06T00:00:00Z"}}},
  {sha: "x9", commit: {message: "This reverts commit ggg — and #11 again", committer: {date: "2026-10-04T00:00:00Z"}}}],
 items: [
  {number: 20, title: "Bug after #11", body: null, created_at: "2026-10-07T00:00:00Z"},
  {number: 21, title: "x", body: "see https://github.com/org/my.repo/pull/12", created_at: "2026-10-07T00:00:00Z", pull_request: {}},
  {number: 22, title: "y", body: "other/repo#16 and #160 and foo#16", created_at: "2026-10-07T00:00:00Z"},
  {number: 23, title: "Revert \"feat: f\"", body: "Reverts Org/my.repo#18", created_at: "2026-10-08T00:00:00Z", pull_request: {}},
  {number: 24, title: "z", body: "follow-up to #17", created_at: "2026-10-04T00:00:00Z"}]}' | fix_rate_classify)"
check "classify: merged = auto-run, in window, merged only" "$(jq -c '.merged_prs' <<<"$CLS")" "[10,11,12,16,17,18]"
check "classify: reverted via commit + via revert PR (reverted wins over fixed)" "$(jq -c '.reverted_prs' <<<"$CLS")" "[10,18]"
check "classify: fixed via #N + PR URL; foreign/glued refs and pre-merge items ignored" "$(jq -c '.fixed_prs' <<<"$CLS")" "[11,12]"
check "classify: counts" "$(jq -c '[.merged, .fixed, .reverted]' <<<"$CLS")" "[6,2,2]"

# ---------------------------------------------------------------------------
# 2. status-digest.sh --fix-rate against a gh shim.
# ---------------------------------------------------------------------------
BIN="$FX/bin"; mkdir -p "$BIN"
GHDATA="$FX/gh"; mkdir -p "$GHDATA"
GH_LOG="$FX/gh.log"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
# gh shim: logs argv; `gh api repos/<o>/<r>/<ep>?…page=N` answers from
# $GHDATA/<o>_<r>/<ep>.<N>.json (default []); a `fail` file fails the repo with
# its content on stderr.
printf '%s\n' "$*" >> "$GH_LOG"
[ "$1" = "api" ] || exit 64
path="$2"
rest="${path#repos/}"; owner="${rest%%/*}"; rest="${rest#*/}"; repo="${rest%%/*}"
rest="${rest#*/}"; ep="${rest%%\?*}"
page="$(printf '%s' "$path" | sed -n 's/.*[?&]page=\([0-9]*\).*/\1/p')"
d="$GHDATA/${owner}_${repo}"
if [ -f "$d/fail" ]; then cat "$d/fail" >&2; exit 1; fi
f="$d/$ep.$page.json"
if [ -f "$f" ]; then cat "$f"; else printf '[]'; fi
SH
chmod +x "$BIN/gh"

mkrepo() {  # mkrepo <dir> <owner/repo>
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" remote add origin "https://github.com/$2.git"
}
mkrepo "$FX/repo-a" "acme/alpha"
mkrepo "$FX/repo-b" "acme/beta"
WL="$FX/watchlist.json"
jq -n --arg a "$FX/repo-a" --arg b "$FX/repo-b" --arg m "$FX/missing" \
  '{repos: [{path: $a}, {path: $b, remotes: ["origin"]}, {path: $m}]}' > "$WL"

INPUT="$FX/status.json"
jq -n --arg wl "$WL" '{schema_version: 1, generated_at: "2026-10-15T00:00:00Z",
  host: "example-host", totals: {degraded: false}, runs: [], read_errors: [],
  sources: {watchlist: $wl}}' > "$INPUT"

mkdir -p "$GHDATA/acme_alpha" "$GHDATA/acme_beta"
jq -n '[{number: 5, title: "feat: x", merged_at: "2026-10-03T00:00:00Z", updated_at: "2026-10-03T00:00:00Z",
         merge_commit_sha: "m5", head: {ref: "auto-run/acme-alpha-issue-4-x"}},
        {number: 6, title: "feat: y", merged_at: "2026-10-04T00:00:00Z", updated_at: "2026-10-04T00:00:00Z",
         merge_commit_sha: "m6", head: {ref: "auto-run/acme-alpha-issue-3-y"}}]' > "$GHDATA/acme_alpha/pulls.1.json"
jq -n '[{sha: "rv", commit: {message: "Revert \"feat: y\"\n\nThis reverts commit m6.", committer: {date: "2026-10-05T00:00:00Z"}}}]' \
  > "$GHDATA/acme_alpha/commits.1.json"
jq -n '[{number: 7, title: "Regression from #5", body: "", created_at: "2026-10-06T00:00:00Z"}]' \
  > "$GHDATA/acme_alpha/issues.1.json"

STATE="$FX/last-digest.sha"
digest() {
  OUT="$(PATH="$BIN:$PATH" GH_LOG="$GH_LOG" GHDATA="$GHDATA" \
         RUN_ISSUES_DIGEST_GWS=/nonexistent/gws \
         RUN_ISSUES_DIGEST_STATE_FILE="$STATE" \
         RUN_ISSUES_DIGEST_ENV_FILE=/nonexistent/digest.env \
         bash "$DIGEST" --from-file "$INPUT" --dry-run "$@" 2>"$FX/stderr")"
  RC=$?
}
n_gh() { if [ -f "$GH_LOG" ]; then wc -l < "$GH_LOG" | tr -d ' '; else echo 0; fi; }

# Off by default: zero gh calls, no section.
: > "$GH_LOG"
digest --force
check "off: exit 0" "$RC" "0"
check "off: zero gh calls" "$(n_gh)" "0"
hasnt "off: no section" "$OUT" "Jälkikorjaukset"

# On: per-repo rows, 3 listings per repo.
: > "$GH_LOG"
digest --force --fix-rate
check "on: exit 0" "$RC" "0"
has "on: section header with default window" "$OUT" "Jälkikorjaukset (yhdistetyt auto-run-PR:t, viimeiset 14 vrk):"
has "on: alpha row" "$OUT" "acme/alpha  yhdistetty 2  jälkikorjattu 1 (#5)  peruutettu 1 (#6)"
has "on: beta row (no merges)" "$OUT" "acme/beta  yhdistetty 0  jälkikorjattu 0  peruutettu 0"
check "on: 3 REST listings per repo x 2 repos" "$(n_gh)" "6"
if grep -qv '^api repos/' "$GH_LOG"; then bad "only gh api REST paths used"; else ok "only gh api REST paths used"; fi
if grep -q -- '--search\|--label\|issue list' "$GH_LOG"; then bad "search connection used"; else ok "no search connection"; fi
has "on: window start from generated_at - 14 d" "$(cat "$GH_LOG")" "since=2026-10-01T00:00:00Z"

# Env opt-in + window override.
: > "$GH_LOG"
OUT="$(PATH="$BIN:$PATH" GH_LOG="$GH_LOG" GHDATA="$GHDATA" RUN_ISSUES_DIGEST_FIX_RATE=1 \
       RUN_ISSUES_DIGEST_FIX_WINDOW_DAYS=3 RUN_ISSUES_DIGEST_GWS=/nonexistent/gws \
       RUN_ISSUES_DIGEST_STATE_FILE="$STATE" RUN_ISSUES_DIGEST_ENV_FILE=/nonexistent/digest.env \
       bash "$DIGEST" --from-file "$INPUT" --dry-run --force 2>/dev/null)"
has "env: window override in header" "$OUT" "viimeiset 3 vrk"
has "env: PRs merged before the window drop out" "$OUT" "acme/alpha  yhdistetty 0"
check "env: still 6 calls" "$(n_gh)" "6"

# §5.4: historical run-dirs do not change the call count.
for i in $(seq 1 40); do
  mkdir -p "$FX/repo-a/.claude/run-issues-archive/old-$i" "$FX/repo-a/.claude/run-issues/live-$i"
  printf '{"run_id":"old-%s"}\n' "$i" > "$FX/repo-a/.claude/run-issues-archive/old-$i/run.json"
done
: > "$GH_LOG"
digest --force --fix-rate
check "cost: 40 historical run-dirs, still 6 calls" "$(n_gh)" "6"

# Paging: a full page inside the window asks for exactly one more page.
jq -n '[range(0; 100) | {number: (1000 + .), title: "closed", merged_at: null,
        updated_at: "2026-10-10T00:00:00Z", head: {ref: "auto-run/z"}}]' > "$GHDATA/acme_beta/pulls.1.json"
jq -n '[{number: 900, title: "feat: z", merged_at: "2026-10-02T00:00:00Z", updated_at: "2026-10-02T00:00:00Z",
         merge_commit_sha: "m900", head: {ref: "auto-run/acme-beta-issue-1-z"}}]' > "$GHDATA/acme_beta/pulls.2.json"
: > "$GH_LOG"
digest --force --fix-rate
check "paging: one extra page => 7 calls" "$(n_gh)" "7"
has "paging: PR on page 2 counted" "$OUT" "acme/beta  yhdistetty 1"

# Paging stops at the window edge even when the page is full.
jq -n '[range(0; 100) | {number: (1000 + .), title: "closed", merged_at: null,
        updated_at: "2026-09-20T00:00:00Z", head: {ref: "auto-run/z"}}]' > "$GHDATA/acme_beta/pulls.1.json"
: > "$GH_LOG"
digest --force --fix-rate
check "paging: full page ending before the window => no extra page" "$(n_gh)" "6"

# Page cap: a cut list is marked, never read as a clean zero.
jq -n '[range(0; 100) | {number: (1000 + .), title: "closed", merged_at: null,
        updated_at: "2026-10-10T00:00:00Z", head: {ref: "auto-run/z"}}]' > "$GHDATA/acme_beta/pulls.1.json"
: > "$GH_LOG"
OUT="$(PATH="$BIN:$PATH" GH_LOG="$GH_LOG" GHDATA="$GHDATA" RUN_ISSUES_DIGEST_FIX_MAX_PAGES=1 \
       RUN_ISSUES_DIGEST_GWS=/nonexistent/gws RUN_ISSUES_DIGEST_STATE_FILE="$STATE" \
       RUN_ISSUES_DIGEST_ENV_FILE=/nonexistent/digest.env \
       bash "$DIGEST" --from-file "$INPUT" --dry-run --force --fix-rate 2>/dev/null)"
has "cap: truncated row is marked" "$OUT" "acme/beta  yhdistetty 0  jälkikorjattu 0  peruutettu 0  ⚠ lista katkesi"
check "cap: no call past the cap" "$(n_gh)" "6"
rm -f "$GHDATA/acme_beta/pulls.1.json" "$GHDATA/acme_beta/pulls.2.json"

# Failure is fail-soft and per repo.
printf 'HTTP 502: Bad Gateway\n' > "$GHDATA/acme_alpha/fail"
: > "$GH_LOG"
digest --force --fix-rate
check "fail: exit 0" "$RC" "0"
has "fail: alpha marked" "$OUT" "acme/alpha  ei tietoa: haku epäonnistui"
has "fail: beta still reported" "$OUT" "acme/beta  yhdistetty 0"
has "fail: rest of the body intact" "$OUT" "Kaikki kunnossa"

# Rate limit: marked, and the sweep stops (beta is not asked).
printf 'gh: API rate limit exceeded for user\n' > "$GHDATA/acme_alpha/fail"
: > "$GH_LOG"
digest --force --fix-rate
check "rate limit: exit 0" "$RC" "0"
has "rate limit: alpha marked" "$OUT" "acme/alpha  ei tietoa: GitHubin kutsuraja"
has "rate limit: beta marked without a call" "$OUT" "acme/beta  ei tietoa: GitHubin kutsuraja"
check "rate limit: one call, then stop" "$(n_gh)" "1"
rm -f "$GHDATA/acme_alpha/fail"

# No watchlist in the input: section skipped, exit 0.
jq 'del(.sources)' "$INPUT" > "$FX/nowl.json"
: > "$GH_LOG"
OUT="$(PATH="$BIN:$PATH" GH_LOG="$GH_LOG" GHDATA="$GHDATA" RUN_ISSUES_DIGEST_GWS=/nonexistent/gws \
       RUN_ISSUES_DIGEST_STATE_FILE="$STATE" RUN_ISSUES_DIGEST_ENV_FILE=/nonexistent/digest.env \
       bash "$DIGEST" --from-file "$FX/nowl.json" --dry-run --force --fix-rate 2>/dev/null)"; RC=$?
check "no watchlist: exit 0" "$RC" "0"
hasnt "no watchlist: no section" "$OUT" "Jälkikorjaukset"
check "no watchlist: zero calls" "$(n_gh)" "0"

# Bad window value is a usage error.
RUN_ISSUES_DIGEST_FIX_WINDOW_DAYS=abc RUN_ISSUES_DIGEST_ENV_FILE=/nonexistent/digest.env \
  bash "$DIGEST" --from-file "$INPUT" --dry-run >/dev/null 2>&1; rc=$?
check "bad FIX_WINDOW_DAYS -> exit 1" "$rc" "1"

echo "----------------------------------------"
echo "fix-rate: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
