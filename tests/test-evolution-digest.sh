#!/usr/bin/env bash
# test-evolution-digest.sh — behavioural tests for evolution-digest.sh (issue
# #315) and its shared parser lib/evolution-findings.sh, against fixture run-dirs
# in a temp watchlist. No network, no gh; the --claude path runs a stub agent
# through RUN_ISSUES_CLAUDE_CMD, and HOME is a temp dir so neither the real
# watchlist nor the machine env file is read.
#
# Cases:
#   1. parser: FIXED / NEEDS_FOLLOWUP / Δψ extraction, CLEAN yields only Δψ
#   2. live + archived runs in the window are read; a run outside it is not
#   3. a key shared by two runs in two repos → implementer-prompt target
#   4. one repo, FIXED → CLAUDE.md target; one repo, only follow-ups → new issue
#   5. a single-run key is not a recurring topic
#   6. state.jsonl is never opened (a FIFO would hang any reader)
#   7. --json shape; --claude with a stub agent; --claude failure → exit 3
#   8. read-only: the fixture tree is byte-identical afterwards
#   9. usage errors → exit 1; no watchlist → exit 2
#
# Run: bash tests/test-evolution-digest.sh   (exit 0 = all pass)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DIGEST="$ROOT/evolution-digest.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed"
  exit 0
fi

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got=[$2] expected=[$3]"; fi; }
has()  { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1: missing [$3]"; fi; }
lacks(){ if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1: unexpected [$3]"; else ok "$1"; fi; }

FX="$(mktemp -d "${TMPDIR:-/tmp}/evolution-digest-test.XXXXXX")"
trap 'rm -rf "$FX"' EXIT
export HOME="$FX/home"
mkdir -p "$HOME"

# ---- 1. parser ----
# shellcheck source=../lib/evolution-findings.sh
. "$ROOT/lib/evolution-findings.sh"
P="$FX/p.out"
printf '%s\n' "noise" "EVOLUTION_DELTA_PSI: lock leaks in \`lib/locking.sh\`" \
  "EVOLUTION_RESULT: FIXED — added missing test" > "$P"
check "parser: result payload" "$(evolution_result_payload "$P")" "FIXED — added missing test"
check "parser: findings" "$(evolution_findings "$P" | tr '\t' '|' | tr '\n' ';')" \
  "FIXED|added missing test;DELTA_PSI|lock leaks in \`lib/locking.sh\`;"
printf '%s\n' "EVOLUTION_RESULT: NEEDS_FOLLOWUP -- goal not met" > "$P"
check "parser: -- separator" "$(evolution_findings "$P" | tr '\t' '|')" "NEEDS_FOLLOWUP|goal not met"
printf '%s\n' "EVOLUTION_DELTA_PSI: x" "EVOLUTION_RESULT: CLEAN" > "$P"
check "parser: CLEAN keeps only Δψ" "$(evolution_findings "$P" | tr '\t' '|')" "DELTA_PSI|x"
check "parser: missing file is empty, rc 0" "$(evolution_findings "$FX/nope"; echo "rc=$?")" "rc=0"

# ---- fixtures ----
iso_ago() {  # <days> -> ISO timestamp that many days ago
  local e=$(( $(date -u +%s) - $1 * 86400 ))
  date -u -r "$e" +%FT%TZ 2>/dev/null || date -u -d "@$e" +%FT%TZ
}
# mkrun <repo> <live|archive> <run-id> <issue> <days-ago> <evolution lines...>
mkrun() {
  local repo="$1" where="$2" rid="$3" issue="$4" ago="$5"; shift 5
  local base="$repo/.claude/run-issues"
  [ "$where" = archive ] && base="$repo/.claude/run-issues-archive"
  local rd="$base/$rid"
  mkdir -p "$rd"
  jq -n --arg r "$rid" --argjson i "$issue" --arg f "$(iso_ago "$ago")" \
    '{run_id: $r, issue_number: $i, status: "completed", started_at: $f, finished_at: $f}' > "$rd/run.json"
  printf '%s\n' "$@" > "$rd/03-evolution.out"
  # A FIFO: any process that opens state.jsonl for reading blocks forever, so
  # the timeout around the digest turns a §5.3 violation into a failure.
  mkfifo "$rd/state.jsonl"
}

A="$FX/repo-alpha"; B="$FX/repo-beta"
mkrun "$A" live    a1 11 1 "EVOLUTION_RESULT: FIXED — \`orchestrate.sh\` lacked a test"
mkrun "$B" archive b1 21 3 "EVOLUTION_DELTA_PSI: orchestrate.sh has no unit test seam" "EVOLUTION_RESULT: CLEAN"
mkrun "$A" archive a2 12 2 "EVOLUTION_RESULT: FIXED — missing \`.env.example\` entry"
mkrun "$A" live    a3 13 4 "EVOLUTION_RESULT: FIXED — again no \`.env.example\` update"
mkrun "$B" live    b2 22 5 "EVOLUTION_RESULT: NEEDS_FOLLOWUP — \`src/cache.ts\` races"
mkrun "$B" archive b3 23 6 "EVOLUTION_DELTA_PSI: src/cache.ts invalidation is ad hoc" "EVOLUTION_RESULT: CLEAN"
mkrun "$A" live    a4 14 2 "EVOLUTION_RESULT: FIXED — one-off in \`lonely.sh\`"
mkrun "$A" archive old 99 90 "EVOLUTION_RESULT: FIXED — ancient \`orchestrate.sh\` thing"
# The old run's files are also old on disk, like a real archived run.
touch -t 202001010000 "$A/.claude/run-issues-archive/old/run.json"

WL="$FX/watchlist.json"
jq -n --arg a "$A" --arg b "$B" '{repos: [{path: $a}, {path: $b}, {path: "/nonexistent/repo"}]}' > "$WL"

TO=""
command -v timeout >/dev/null 2>&1 && TO="timeout 30"
command -v gtimeout >/dev/null 2>&1 && TO="gtimeout 30"

snapshot() { (cd "$FX" && find repo-alpha repo-beta -type f -exec cksum {} \; | sort); }
BEFORE="$(snapshot)"

run() { OUT="$(RUN_ISSUES_WATCHLIST="$WL" $TO bash "$DIGEST" "$@" 2>"$FX/err")"; RC=$?; }

# ---- 2–6. human report ----
run
check "human: exit 0 (no state.jsonl read, no hang)" "$RC" "0"
has   "window: run count in header" "$OUT" "ajoja jaksossa: 7"
lacks "window: run outside window excluded" "$OUT" "ancient"
has   "cross-repo key grouped" "$OUT" '`orchestrate.sh` — 2 ajoa'
has   "cross-repo → implementer prompt" "$OUT" "Implementerin prompti (prompts/02-implementer.md) — toistuu 2 repossa"
has   "one repo FIXED → CLAUDE.md" "$OUT" "kohderepon CLAUDE.md (repo-alpha)"
has   "one repo follow-ups → new issue" "$OUT" "uusi issue (repo-beta)"
has   "archived run read" "$OUT" "repo-beta#21 (Δψ)"
has   "single-run key listed as other finding" "$OUT" "repo-alpha#14 (korjattu): one-off"
lacks "single-run key not a topic" "$OUT" '`lonely.sh` —'

# ---- 7. --json, --claude ----
run --json
check "json: exit 0" "$RC" "0"
check "json: group count" "$(printf '%s' "$OUT" | jq '.groups | length')" "3"
check "json: targets" "$(printf '%s' "$OUT" | jq -r '[.groups[].target] | sort | join(",")')" \
  "implementer_prompt,new_issue,repo_claude_md"
check "json: findings" "$(printf '%s' "$OUT" | jq '.findings | length')" "7"

run --min-count 3 --json
check "min-count 3: no group" "$(printf '%s' "$OUT" | jq '.groups | length')" "0"

STUB="$FX/claude-stub"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
# Echo a marker plus proof that the findings reached the prompt.
for a in "$@"; do last="$a"; done
printf 'STUB-REPORT\n'
printf '%s' "$last" | grep -q 'src/cache.ts' && printf 'FINDINGS-SEEN\n'
printf '%s' "$last" | grep -q '{{' && printf 'UNRENDERED\n'
exit 0
SH
chmod +x "$STUB"
OUT="$(RUN_ISSUES_WATCHLIST="$WL" RUN_ISSUES_CLAUDE_CMD="$STUB" RUN_ISSUES_ENV_FILE="/nonexistent" \
  $TO bash "$DIGEST" --claude 2>"$FX/err")"; RC=$?
check "claude: exit 0" "$RC" "0"
has   "claude: agent output in report" "$OUT" "STUB-REPORT"
has   "claude: findings reached the prompt" "$OUT" "FINDINGS-SEEN"
lacks "claude: no unrendered placeholder" "$OUT" "UNRENDERED"

printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB"
OUT="$(RUN_ISSUES_WATCHLIST="$WL" RUN_ISSUES_CLAUDE_CMD="$STUB" RUN_ISSUES_ENV_FILE="/nonexistent" \
  $TO bash "$DIGEST" --claude 2>"$FX/err")"; RC=$?
check "claude failure: exit 3" "$RC" "3"
has   "claude failure: deterministic report instead" "$OUT" "## Toistuvat aiheet"

run --out "$FX/report.md"
check "--out: exit 0, nothing on stdout" "$RC|$OUT" "0|"
has   "--out: report in file" "$(cat "$FX/report.md")" "## Toistuvat aiheet"

# ---- 8. read-only ----
if [ "$(snapshot)" = "$BEFORE" ]; then ok "fixture tree unchanged"; else bad "fixture tree changed"; fi

# ---- 9. errors ----
run --since x;            check "bad --since → 1" "$RC" "1"
run --min-count 1;        check "--min-count 1 → 1" "$RC" "1"
run --json --claude;      check "--json --claude → 1" "$RC" "1"
run --bogus;              check "unknown flag → 1" "$RC" "1"
OUT="$(RUN_ISSUES_WATCHLIST="$FX/none.json" bash "$DIGEST" 2>/dev/null)"; RC=$?
check "missing watchlist → 2" "$RC" "2"

printf '\nevolution-digest: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
