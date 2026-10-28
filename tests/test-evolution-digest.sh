#!/usr/bin/env bash
# test-evolution-digest.sh — behavioural tests for evolution-digest.sh (issue
# #315) and its shared parser lib/evolution-findings.sh, against fixture run-dirs
# in a temp watchlist. No network, no gh; the --claude path runs a stub agent
# through RUN_ISSUES_CLAUDE_CMD, and HOME is a temp dir so neither the real
# watchlist nor the machine env file is read.
#
# Cases:
#   1. parser: FIXED / NEEDS_FOLLOWUP / Δψ extraction, CLEAN yields only Δψ;
#      Δψ class: tooling / product, a classless (pre-#392) or unknown-class line
#      reads as unclassified with its whole text kept
#   2. live + archived runs in the window are read; a run outside it is not
#   3. a key shared by two runs in two repos → implementer-prompt target
#   4. one repo, FIXED → CLAUDE.md target; one repo, only follow-ups → new issue
#   5. a single-run key is not a recurring topic
#   6. state.jsonl is never opened (a FIFO would hang any reader)
#   7. --json shape; --claude with a stub agent; --claude failure → exit 3
#   8. read-only: the fixture tree is byte-identical afterwards
#   9. usage errors → exit 1; no watchlist → exit 2
#  10. tooling Δψ forms its own lane: not merged with a product finding on the
#      same file, target is the test environment / provisioning or the runner
#  11. --escapes (issue #390): without it the output is byte-identical to a
#      golden taken before the flag existed, and to a run whose file has no
#      runner rows; runner rows become ESCAPE findings → stage_or_gate; a bad
#      file → exit 1; still no gh call and no state.jsonl read
#
# Run: bash tests/test-evolution-digest.sh   (exit 0 = all pass)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Hermetic: never source this machine's real env file (CLAUDE.md §5.5, #358).
export RUN_ISSUES_ENV_FILE="$HERE/.no-such-machine-env"
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
  "FIXED|-|added missing test;DELTA_PSI|unclassified|lock leaks in \`lib/locking.sh\`;"
printf '%s\n' "EVOLUTION_RESULT: NEEDS_FOLLOWUP -- goal not met" > "$P"
check "parser: -- separator" "$(evolution_findings "$P" | tr '\t' '|')" "NEEDS_FOLLOWUP|-|goal not met"
printf '%s\n' "EVOLUTION_DELTA_PSI: x" "EVOLUTION_RESULT: CLEAN" > "$P"
check "parser: CLEAN keeps only Δψ" "$(evolution_findings "$P" | tr '\t' '|')" "DELTA_PSI|unclassified|x"
printf '%s\n' "EVOLUTION_DELTA_PSI: tooling | x" "EVOLUTION_DELTA_PSI: product|y" \
  "EVOLUTION_DELTA_PSI: infra | z" "EVOLUTION_DELTA_PSI: productive w" > "$P"
check "parser: Δψ classes" "$(evolution_findings "$P" | tr '\t' '|' | tr '\n' ';')" \
  "DELTA_PSI|tooling|x;DELTA_PSI|product|y;DELTA_PSI|unclassified|infra | z;DELTA_PSI|unclassified|productive w;"
check "parser: classified helper" "$(evolution_delta_psi_classified "$P" | sed -n 1p | tr '\t' '|')" "tooling|x"
check "parser: missing file is empty, rc 0" "$(evolution_findings "$FX/nope"; echo "rc=$?")" "rc=0"
# Review guide (#413): the last heading wins, the section ends at `## ` or the
# first EVOLUTION_ line, blank edges trimmed, a missing file is nothing.
printf '%s\n' "## Katselmointiohje" "quoted early" "## Katselmointiohje" "" "### Mihin katsoa" \
  "lib/x.sh:3" "" "## Muu" "outside" > "$P"
check "parser: guide last heading, ends at ##" "$(evolution_review_guide "$P" | tr '\n' ';')" \
  "### Mihin katsoa;lib/x.sh:3;"
printf '%s\n' "## Katselmointiohje" "g1" "EVOLUTION_DELTA_PSI: tooling | x" "after" "EVOLUTION_RESULT: CLEAN" > "$P"
check "parser: guide ends at EVOLUTION_" "$(evolution_review_guide "$P" | tr '\n' ';')" "g1;"
printf '%s\n' "## Katselmointiohje" "" "EVOLUTION_RESULT: CLEAN" > "$P"
check "parser: empty guide is nothing" "$(evolution_review_guide "$P")" ""
check "parser: guide missing file is empty, rc 0" "$(evolution_review_guide "$FX/nope"; echo "rc=$?")" "rc=0"

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
has   "archived run read" "$OUT" "repo-beta#21 (Δψ/unclassified)"
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

# ---- 11. --escapes ----
# Golden: the output of evolution-digest.sh before --escapes existed (#390),
# with the run-relative `at` timestamps dropped from the JSON.
GOLDEN_HUMAN=$(cat <<'EOF'
# Evolutionin havaintojen kooste

Jakso: 30 vrk · repoja: 2 · ajoja jaksossa: 7 · havaintoja: 7
Toistuvaksi lasketaan aihe, joka esiintyy vähintään 2 eri ajossa. Ryhmittely on mekaaninen (mainitut tiedostot ja tunnisteet); --claude ryhmittelee merkityksen perusteella.

## Toistuvat aiheet — tuote

### `.env.example` — 2 ajoa
Ehdotettu kohde: kohderepon CLAUDE.md (repo-alpha) — Evolution korjasi saman asian toistuvasti
  - repo-alpha#13 (korjattu): again no `.env.example` update
  - repo-alpha#12 (korjattu): missing `.env.example` entry

### `orchestrate.sh` — 2 ajoa
Ehdotettu kohde: Implementerin prompti (prompts/02-implementer.md) — toistuu 2 repossa
  - repo-beta#21 (Δψ/unclassified): orchestrate.sh has no unit test seam
  - repo-alpha#11 (korjattu): `orchestrate.sh` lacked a test

### `src/cache.ts` — 2 ajoa
Ehdotettu kohde: uusi issue (repo-beta) — korjaamaton rakenteellinen havainto
  - repo-beta#23 (Δψ/unclassified): src/cache.ts invalidation is ad hoc
  - repo-beta#22 (jatkotoimi): `src/cache.ts` races

## Toistuvat aiheet — testiympäristö ja runner

Ei toistuvia aiheita.

## Muut havainnot

### repo-alpha
  - repo-alpha#14 (korjattu): one-off in `lonely.sh`
EOF
)
GOLDEN_JSON=$(cat <<'EOF'
{"findings":[{"class":"unclassified","issue":"23","kind":"DELTA_PSI","repo":"repo-beta","run_id":"b3","text":"src/cache.ts invalidation is ad hoc"},{"class":null,"issue":"22","kind":"NEEDS_FOLLOWUP","repo":"repo-beta","run_id":"b2","text":"`src/cache.ts` races"},{"class":null,"issue":"13","kind":"FIXED","repo":"repo-alpha","run_id":"a3","text":"again no `.env.example` update"},{"class":"unclassified","issue":"21","kind":"DELTA_PSI","repo":"repo-beta","run_id":"b1","text":"orchestrate.sh has no unit test seam"},{"class":null,"issue":"14","kind":"FIXED","repo":"repo-alpha","run_id":"a4","text":"one-off in `lonely.sh`"},{"class":null,"issue":"12","kind":"FIXED","repo":"repo-alpha","run_id":"a2","text":"missing `.env.example` entry"},{"class":null,"issue":"11","kind":"FIXED","repo":"repo-alpha","run_id":"a1","text":"`orchestrate.sh` lacked a test"}],"groups":[{"findings":[{"class":null,"issue":"13","kind":"FIXED","repo":"repo-alpha","run_id":"a3","text":"again no `.env.example` update"},{"class":null,"issue":"12","kind":"FIXED","repo":"repo-alpha","run_id":"a2","text":"missing `.env.example` entry"}],"keys":[".env.example"],"lane":"product","repos":["repo-alpha"],"run_count":2,"target":"repo_claude_md"},{"findings":[{"class":"unclassified","issue":"21","kind":"DELTA_PSI","repo":"repo-beta","run_id":"b1","text":"orchestrate.sh has no unit test seam"},{"class":null,"issue":"11","kind":"FIXED","repo":"repo-alpha","run_id":"a1","text":"`orchestrate.sh` lacked a test"}],"keys":["orchestrate.sh"],"lane":"product","repos":["repo-alpha","repo-beta"],"run_count":2,"target":"implementer_prompt"},{"findings":[{"class":"unclassified","issue":"23","kind":"DELTA_PSI","repo":"repo-beta","run_id":"b3","text":"src/cache.ts invalidation is ad hoc"},{"class":null,"issue":"22","kind":"NEEDS_FOLLOWUP","repo":"repo-beta","run_id":"b2","text":"`src/cache.ts` races"}],"keys":["src/cache.ts"],"lane":"product","repos":["repo-beta"],"run_count":2,"target":"new_issue"}],"min_count":2,"repos_scanned":2,"runs_read":7,"ungrouped":[{"class":null,"issue":"14","kind":"FIXED","repo":"repo-alpha","run_id":"a4","text":"one-off in `lonely.sh`"}],"window_days":30}
EOF
)
nojq_at() { jq -cS 'del(.findings[].at, .groups[].findings[].at, .ungrouped[].at)'; }
run;        check "golden: human output unchanged" "$(printf '%s' "$OUT" | cksum)" "$(printf '%s' "$GOLDEN_HUMAN" | cksum)"
run --json; check "golden: --json unchanged" "$(printf '%s' "$OUT" | nojq_at)" "$GOLDEN_JSON"

# A gh that fails and records: the digest must not call it, with --escapes too.
mkdir -p "$FX/bin"
printf '#!/usr/bin/env bash\necho "$*" >> "%s"\nexit 1\n' "$FX/gh-calls" > "$FX/bin/gh"
chmod +x "$FX/bin/gh"
erun() { OUT="$(PATH="$FX/bin:$PATH" RUN_ISSUES_WATCHLIST="$WL" $TO bash "$DIGEST" "$@" 2>"$FX/err")"; RC=$?; }
# esc <file> <repo-path> <location|pr|class|method|issue|source>...
esc() {
  local f="$1" repo="$2"; shift 2
  printf '%s\n' "$@" | jq -Rn --arg repo "$repo" '
    {repo: $repo, owner_repo: "o/r",
     locations: [inputs | split("|") | {location: .[0], commit: "abc", pr: .[1], class: .[2],
                 method: .[3], issue: .[4], source: .[5], note: ""}],
     summary: {}, limitation: ""}' > "$f"
}
esc "$FX/esc-none.json" "$A" "lib/x.sh:3|-|peritty|-|-|#301" "lib/y.sh:9|-|tuntematon|-|-|#301"
erun --escapes "$FX/esc-none.json"
check "no runner rows: exit 0" "$RC" "0"
check "no runner rows: human output unchanged" "$(printf '%s' "$OUT" | cksum)" "$(printf '%s' "$GOLDEN_HUMAN" | cksum)"
erun --escapes "$FX/esc-none.json" --json
check "no runner rows: --json unchanged" "$(printf '%s' "$OUT" | nojq_at)" "$GOLDEN_JSON"

esc "$FX/esc.json" "$A/" "lib/x.sh:3|5|runner|pr-api|7|#301" "lib/x.sh:40|13|runner|auto-prefix|8|#302" \
  "lib/z.sh:1|-|peritty|-|-|#301" ".env.example:2|9|runner|msg-ref|4|#303"
erun --escapes "$FX/esc.json" --json
check "escapes: exit 0" "$RC" "0"
check "escapes: only runner rows join" "$(printf '%s' "$OUT" | jq '[.findings[] | select(.kind == "ESCAPE")] | length')" "3"
check "escapes: finding shape" \
  "$(printf '%s' "$OUT" | jq -c '[.findings[] | select(.kind == "ESCAPE")][0] | [.repo, .issue, .run_id, .at]')" \
  '["repo-alpha","7","pr-5",""]'
check "escapes: two runner PRs, one file → stage_or_gate" \
  "$(printf '%s' "$OUT" | jq -r '.groups[] | select(.keys == ["lib/x.sh"]) | "\(.target) \(.run_count)"')" "stage_or_gate 2"
check "escapes: ESCAPE outranks FIXED" \
  "$(printf '%s' "$OUT" | jq -r '.groups[] | select(.keys == [".env.example"]) | .target')" "stage_or_gate"
erun --escapes "$FX/esc.json"
has   "escapes: human target text" "$OUT" "vaiheen prompti tai merge-portti (cycle review, toteutus, Evolution, tietoturva- tai semanttinen portti)"
has   "escapes: human row" "$OUT" 'repo-alpha#7 (läpi päässyt): `lib/x.sh` rivi 3 — löydös #301, runner-PR #5 (pr-api)'
erun --escapes "$FX/esc.json" --repo "$B" --json
check "escapes: --repo of another repo skips the file" \
  "$(printf '%s' "$OUT" | jq '[.findings[] | select(.kind == "ESCAPE")] | length')" "0"

STUB2="$FX/claude-stub2"
printf '#!/usr/bin/env bash\nfor a in "$@"; do last="$a"; done\nprintf "%%s" "$last" | grep -q ESCAPE && echo ESCAPE-SEEN\nexit 0\n' > "$STUB2"
chmod +x "$STUB2"
OUT="$(PATH="$FX/bin:$PATH" RUN_ISSUES_WATCHLIST="$WL" RUN_ISSUES_CLAUDE_CMD="$STUB2" RUN_ISSUES_ENV_FILE="/nonexistent" \
  $TO bash "$DIGEST" --claude --escapes "$FX/esc.json" 2>"$FX/err")"; RC=$?
check "escapes --claude: exit 0" "$RC" "0"
has   "escapes --claude: ESCAPE reached the prompt" "$OUT" "ESCAPE-SEEN"

erun --escapes "$FX/no-such.json";        check "escapes: missing file → 1" "$RC" "1"
printf 'not json\n' > "$FX/bad.json"
erun --escapes "$FX/bad.json";            check "escapes: not JSON → 1" "$RC" "1"
printf '{"repo":"x"}\n' > "$FX/bad.json"
erun --escapes "$FX/bad.json";            check "escapes: no locations → 1" "$RC" "1"
erun --escapes;                           check "escapes: no value → 1" "$RC" "1"
if [ -e "$FX/gh-calls" ]; then bad "escapes: gh was called: $(cat "$FX/gh-calls")"; else ok "escapes: no gh call"; fi

PROMPT_MD="$(cat "$ROOT/prompts/evolution-digest.md")"
has "prompt: ESCAPE kind" "$PROMPT_MD" '`ESCAPE`: vika'
has "prompt: stage-or-gate target" "$PROMPT_MD" "Vaiheen prompti tai merge-portti** (cycle review, toteutus, Evolution, tietoturva- tai semanttinen portti)"
has "prompt: mechanical check line" "$PROMPT_MD" "- Mekaaninen tarkistus:"

# ---- 8. read-only ----
if [ "$(snapshot)" = "$BEFORE" ]; then ok "fixture tree unchanged"; else bad "fixture tree changed"; fi

# ---- 9. errors ----
run --since x;            check "bad --since → 1" "$RC" "1"
run --min-count 1;        check "--min-count 1 → 1" "$RC" "1"
run --json --claude;      check "--json --claude → 1" "$RC" "1"
run --bogus;              check "unknown flag → 1" "$RC" "1"
OUT="$(RUN_ISSUES_WATCHLIST="$FX/none.json" bash "$DIGEST" 2>/dev/null)"; RC=$?
check "missing watchlist → 2" "$RC" "2"

# ---- 10. tooling lane ----
C="$FX/repo-gamma"
mkrun "$C" live c1 31 1 "EVOLUTION_DELTA_PSI: tooling | Playwright needs \`e2e/.env\` before the run" "EVOLUTION_RESULT: CLEAN"
mkrun "$C" live c2 32 1 "EVOLUTION_DELTA_PSI: tooling | again no \`e2e/.env\` for Playwright" "EVOLUTION_RESULT: CLEAN"
mkrun "$C" live c3 33 1 "EVOLUTION_DELTA_PSI: product | \`e2e/.env\` is read by the app at runtime" "EVOLUTION_RESULT: CLEAN"
mkrun "$C" live c4 34 1 "EVOLUTION_RESULT: NEEDS_FOLLOWUP — \`e2e/.env\` parsing is brittle"
WL2="$FX/watchlist2.json"
jq -n --arg c "$C" '{repos: [{path: $c}]}' > "$WL2"
OUT="$(RUN_ISSUES_WATCHLIST="$WL2" $TO bash "$DIGEST" --json 2>"$FX/err")"; RC=$?
check "lane json: exit 0" "$RC" "0"
check "lane json: two groups, one per lane" \
  "$(printf '%s' "$OUT" | jq -r '[.groups[] | "\(.lane):\(.run_count):\(.target)"] | sort | join(",")')" \
  "product:2:new_issue,tooling:2:test_env_or_runner"
check "lane json: class carried" "$(printf '%s' "$OUT" | jq -r '[.findings[] | .class // "-"] | sort | join(",")')" \
  "-,product,tooling,tooling"
OUT="$(RUN_ISSUES_WATCHLIST="$WL2" $TO bash "$DIGEST" 2>"$FX/err")"
has   "lane human: product section" "$OUT" "## Toistuvat aiheet — tuote"
has   "lane human: tooling section" "$OUT" "## Toistuvat aiheet — testiympäristö ja runner"
has   "lane human: tooling target" "$OUT" "kohderepon testiympäristö tai provisiointi (\`.claude/provision-test-env.sh\`, repo-gamma) tai runnerin paketti"
has   "lane human: class in row" "$OUT" "repo-gamma#31 (Δψ/tooling)"
OUT="$(RUN_ISSUES_WATCHLIST="$WL" $TO bash "$DIGEST" 2>"$FX/err")"
has   "lane human: empty tooling section says so" "$OUT" "## Toistuvat aiheet — testiympäristö ja runner

Ei toistuvia aiheita."

printf '\nevolution-digest: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
