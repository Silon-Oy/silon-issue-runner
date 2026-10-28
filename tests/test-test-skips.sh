#!/usr/bin/env bash
# test-test-skips.sh — added test skips are visible, skipped counts recorded (#410).
#
# A green suite is S9's and CI's evidence, but a suite whose tests were skipped
# is green too. lib/test-skips.sh reports skip and focus markers a branch adds;
# lib/evolution-findings.sh parses evolution's EVOLUTION_TEST_RUN lines.
#
# Cases (fixture diffs in a throwaway git repo):
#   (a) justified skips: comment on the previous line, comment on the same line,
#       the marker's own reason argument -> justified=1
#   (b) unjustified skips in every framework -> justified=0
#   (c) focus markers (.only, fdescribe) -> kind=only, even with a comment
#   (d) application code (`arr.skip(`), commented-out markers -> no hit
#   (e) a removed skip -> no hit
#   (f) line numbers are the new file's, across several hunks
#   (g) git error -> no output, rc 0, one stderr line
#   (h) evolution_test_runs_json: counts, `?` -> null, `|` inside the command,
#       CRLF, no lines -> []
#   (i) state_set_json stores JSON, rejects invalid JSON untouched
#   (j) orchestrate.sh: unjustified skip -> draft + "Added test skips" section
#       with file:line; justified only -> no draft, no section; .only -> draft;
#       test_runs lands in run.json; no lines -> [] and no draft
#
# Run: bash tests/test-test-skips.sh   (exit 0 = all pass)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Hermetic: never source this machine's real env file (CLAUDE.md §5.5, #358).
export RUN_ISSUES_ENV_FILE="$HERE/.no-such-machine-env"
export RUN_ISSUES_CLAIM_VERIFY_DELAY=0
ROOT="$(cd "$HERE/.." && pwd)"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

# shellcheck source=lib/test-skips.sh
. "$ROOT/lib/test-skips.sh"
# shellcheck source=lib/evolution-findings.sh
. "$ROOT/lib/evolution-findings.sh"
# shellcheck source=lib/state.sh
. "$ROOT/lib/state.sh"

WORK=$(mktemp -d -t test-skips.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAIL=1; }

g() { git -C "$FX" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }

# Expect exactly one hit "<file>\t<line>\t<kind>\t<justified>".
expect_hit() {
  local label="$1" want="$2"
  if printf '%s\n' "$OUT" | cut -f1-4 | grep -qxF "$want"; then
    pass "$label"
  else
    fail "$label (want '$want')"
    printf '%s\n' "$OUT" | sed 's/^/      /'
  fi
}
expect_no_hit_in() {
  local label="$1" file="$2"
  if printf '%s\n' "$OUT" | cut -f1 | grep -qxF "$file"; then
    fail "$label"
    printf '%s\n' "$OUT" | sed 's/^/      /'
  else
    pass "$label"
  fi
}

FX="$WORK/fx"
git init -q "$FX"
mkdir -p "$FX/e2e" "$FX/tests" "$FX/src"
cat > "$FX/e2e/old.spec.ts" <<'EOF'
test('a', () => {});
it.skip('removed later', () => {});
test('b', () => {});
test('c', () => {});
test('d', () => {});
test('e', () => {});
test('f', () => {});
test('g', () => {});
test('h', () => {});
test('i', () => {});
EOF
g add -A && g commit -qm base
BASE=$(g rev-parse HEAD)

cat > "$FX/e2e/a.spec.ts" <<'EOF'
test('a', () => {});
// flaky on CI until #12 lands
test.skip('b', () => {});
it.skip('c', () => {}); // waits for API v2
it.skip('d', () => {});
xit('e', () => {});
test.describe.only('f', () => {});
// focusing on purpose
fdescribe('g', () => {});
// it.skip('h', () => {});
test.fixme('i', () => {});
EOF
cat > "$FX/src/util.js" <<'EOF'
const rest = arr.skip(1);
it.skip('not a test file', () => {});
EOF
cat > "$FX/tests/FooTest.php" <<'EOF'
<?php
    /**
     * @group skip
     */
    public function testA() { $this->markTestSkipped(); }
    public function testB() { $this->markTestSkipped('needs redis'); }
    // $this->markTestSkipped();
EOF
cat > "$FX/tests/test_x.py" <<'EOF'
@pytest.mark.skip
def test_a(): pass
@pytest.mark.skip(reason="slow on CI")
def test_b(): pass
@pytest.mark.skipif(sys.platform == "win32")
def test_c(): pass
EOF
cat > "$FX/tests/x.bats" <<'EOF'
@test "a" {
  skip
}
@test "b" {
  skip "no docker on the runner"
}
EOF
# (e) remove the old skip; (f) add one far below it, in a second hunk.
sed -i.bak '2d' "$FX/e2e/old.spec.ts" && rm -f "$FX/e2e/old.spec.ts.bak"
printf '%s\n' "it.skip('late', () => {});" >> "$FX/e2e/old.spec.ts"
g add -A && g commit -qm change

OUT=$(cd "$FX" && test_skips_added "$BASE" HEAD)

# === (a) justified ==========================================================
expect_hit "(a): comment on the previous line justifies" $'e2e/a.spec.ts\t3\tskip\t1'
expect_hit "(a): comment on the same line justifies" $'e2e/a.spec.ts\t4\tskip\t1'
expect_hit "(a): markTestSkipped('why') carries its reason" $'tests/FooTest.php\t6\tskip\t1'
expect_hit "(a): @pytest.mark.skip(reason=…) carries its reason" $'tests/test_x.py\t3\tskip\t1'
expect_hit "(a): bats skip \"why\" carries its reason" $'tests/x.bats\t5\tskip\t1'

# === (b) unjustified ========================================================
expect_hit "(b): bare it.skip" $'e2e/a.spec.ts\t5\tskip\t0'
expect_hit "(b): xit" $'e2e/a.spec.ts\t6\tskip\t0'
expect_hit "(b): commented-out marker above is no reason; test.fixme" $'e2e/a.spec.ts\t11\tskip\t0'
expect_hit "(b): @group skip" $'tests/FooTest.php\t3\tskip\t0'
expect_hit "(b): markTestSkipped()" $'tests/FooTest.php\t5\tskip\t0'
expect_hit "(b): @pytest.mark.skip" $'tests/test_x.py\t1\tskip\t0'
expect_hit "(b): @pytest.mark.skipif without reason" $'tests/test_x.py\t5\tskip\t0'
expect_hit "(b): bats skip" $'tests/x.bats\t2\tskip\t0'

# === (c) focus ==============================================================
expect_hit "(c): .only" $'e2e/a.spec.ts\t7\tonly\t0'
expect_hit "(c): fdescribe with a comment is still kind=only" $'e2e/a.spec.ts\t9\tonly\t1'

# === (d) no false positives =================================================
expect_no_hit_in "(d): application code is not scanned" "src/util.js"
if printf '%s\n' "$OUT" | awk -F '\t' '$1 == "e2e/a.spec.ts" && $2 == 10' | grep -q .; then
  fail "(d): commented-out it.skip counted"
else
  pass "(d): commented-out it.skip is not a hit"
fi
if printf '%s\n' "$OUT" | awk -F '\t' '$1 == "tests/FooTest.php" && $2 == 7' | grep -q .; then
  fail "(d): commented-out markTestSkipped counted"
else
  pass "(d): commented-out markTestSkipped is not a hit"
fi

# === (e)/(f) removal and line numbers =======================================
old_hits=$(printf '%s\n' "$OUT" | awk -F '\t' '$1 == "e2e/old.spec.ts"')
if [ "$old_hits" = $'e2e/old.spec.ts\t10\tskip\t0\tit.skip(\'late\', () => {});' ]; then
  pass "(e)/(f): removed skip not reported; added one at new-file line 10"
else
  fail "(e)/(f): old.spec.ts hits wrong"
  printf '%s\n' "$old_hits" | sed 's/^/      /'
fi

total=$(printf '%s\n' "$OUT" | grep -c .)
[ "$total" = 16 ] && pass "(a-f): exactly 16 hits" || { fail "(a-f): $total hits, want 16"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

# === (g) git error ==========================================================
err_out=$(cd "$FX" && test_skips_added no-such-ref HEAD 2>"$WORK/err"); rc=$?
if [ "$rc" = 0 ] && [ -z "$err_out" ] && [ "$(grep -c . "$WORK/err")" = 1 ]; then
  pass "(g): git error -> no hits, rc 0, one stderr line"
else
  fail "(g): rc=$rc out='$err_out' err=$(cat "$WORK/err")"
fi

# === (h) evolution_test_runs_json ===========================================
printf '%s\n' "noise" \
  "EVOLUTION_TEST_RUN: bash tests/run-all.sh | passed=12 | skipped=0 | failed=1" \
  "EVOLUTION_TEST_RUN: npx playwright test | tee log | passed=? | skipped=3 | failed=0" \
  "EVOLUTION_RESULT: CLEAN" > "$WORK/evo.out"
got=$(evolution_test_runs_json "$WORK/evo.out")
want='[{"command":"bash tests/run-all.sh","passed":12,"skipped":0,"failed":1},{"command":"npx playwright test | tee log","passed":null,"skipped":3,"failed":0}]'
[ "$got" = "$want" ] && pass "(h): counts, ? -> null, | inside the command" || fail "(h): got $got"
printf 'EVOLUTION_TEST_RUN: a | passed=1 | skipped=2 | failed=3\r\nEVOLUTION_RESULT: CLEAN\r\n' > "$WORK/evo-crlf.out"
got=$(evolution_test_runs_json "$WORK/evo-crlf.out")
[ "$got" = '[{"command":"a","passed":1,"skipped":2,"failed":3}]' ] && pass "(h): CRLF output" || fail "(h): CRLF got $got"
printf '%s\n' "EVOLUTION_RESULT: CLEAN" > "$WORK/evo-old.out"
got=$(evolution_test_runs_json "$WORK/evo-old.out"); rc=$?
[ "$got" = '[]' ] && [ "$rc" = 0 ] && pass "(h): no lines -> [] rc 0" || fail "(h): no lines got '$got' rc=$rc"
got=$(evolution_test_runs_json "$WORK/missing.out"); rc=$?
[ "$got" = '[]' ] && [ "$rc" = 0 ] && pass "(h): missing file -> [] rc 0" || fail "(h): missing got '$got' rc=$rc"

# === (i) state_set_json =====================================================
SD="$WORK/state"
state_init "$SD" "rid" "$WORK" "1"
state_set_json "$SD" test_runs '[{"command":"x","passed":1}]'
[ "$(jq -c '.test_runs' "$SD/run.json")" = '[{"command":"x","passed":1}]' ] \
  && pass "(i): state_set_json stores JSON" || fail "(i): stored $(jq -c '.test_runs' "$SD/run.json")"
before=$(cat "$SD/run.json")
if state_set_json "$SD" test_runs 'not json' 2>/dev/null; then
  fail "(i): invalid JSON accepted"
elif [ "$(cat "$SD/run.json")" = "$before" ] && ! compgen -G "$SD/.run.json.*" >/dev/null; then
  pass "(i): invalid JSON -> rc 1, run.json untouched, no temp file"
else
  fail "(i): run.json changed or temp file left"
fi

# === (j) orchestrate.sh integration =========================================
# Driven like test-evolution-context.sh, except that `git diff` reaches the real
# git so the scan reads a real worktree whose origin/main is the base.
REAL_GIT=$(command -v git)
REPO="$WORK/repo"
"$REAL_GIT" init -q "$REPO"
WT="$WORK/worktree"
"$REAL_GIT" init -q "$WT"
mkdir -p "$WT/tests"
echo "test('a', () => {});" > "$WT/tests/a.test.js"
"$REAL_GIT" -C "$WT" add -A
"$REAL_GIT" -C "$WT" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm base
"$REAL_GIT" -C "$WT" update-ref refs/remotes/origin/main HEAD

BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
if [ "\$1" = "pr" ] && [ "\$2" = "create" ]; then
  printf '%s\n' "\$*" > "$WORK/gh-pr-create.args"
  echo "https://github.com/acme/widgets/pull/42"
fi
exit 0
SH
cat > "$BIN/git" <<SH
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = diff ] && exec "$REAL_GIT" "\$@"; done
exit 0
SH
cat > "$BIN/claude" <<SH
#!/usr/bin/env bash
echo "IMPLEMENTER_RESULT: SUCCESS"
cat "$WORK/evo-reply" 2>/dev/null
SH
chmod +x "$BIN/gh" "$BIN/git" "$BIN/claude"

RID="20261028-1000-issue-410"
RD="$REPO/.claude/run-issues/$RID"

# set_branch <content of tests/a.test.js> — the branch's one commit on top of base.
set_branch() {
  "$REAL_GIT" -C "$WT" reset -q --hard refs/remotes/origin/main
  printf '%s\n' "$@" > "$WT/tests/a.test.js"
  "$REAL_GIT" -C "$WT" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qam change
}

run_orch() {
  rm -rf "$RD" "$WORK/gh-pr-create.args"
  state_init "$RD" "$RID" "$REPO" "410"
  state_set "$RD" "branch" "auto-run/issue-410-x"
  state_set "$RD" "worktree_path" "$WT"
  state_set "$RD" "base_branch" "main"
  state_set "$RD" "cycle_review_decision" "PROCEED"
  jq -n '{title:"t",body:"b",comments:[],labels:[]}' > "$RD/issue.json"
  echo "CYCLE_REVIEW_DECISION: PROCEED" > "$RD/01-cycle-review.out"
  ( cd "$REPO" && \
    PATH="$BIN:$PATH" \
    RUN_ISSUES_AUTO=1 RUN_ISSUES_REVIEW_GATE=auto \
    RUN_ISSUES_CLAUDE_CMD="$BIN/claude" \
    RUN_ISSUES_LOCK_ROOT="$WORK/locks" \
    "$ROOT/orchestrate.sh" --resume "$RD" --decision PROCEED ) >/dev/null 2>&1
}
drafted() { grep -qF -- '--draft' "$WORK/gh-pr-create.args" 2>/dev/null; }

# Unjustified skip, with test-run lines.
set_branch "test('a', () => {});" "it.skip('b', () => {});"
printf '%s\n' "EVOLUTION_TEST_RUN: npm test | passed=1 | skipped=1 | failed=0" "EVOLUTION_RESULT: CLEAN" > "$WORK/evo-reply"
run_orch
if [ ! -f "$WORK/gh-pr-create.args" ]; then
  fail "(j): gh pr create never ran"
else
  drafted && pass "(j): unjustified skip -> draft PR" || fail "(j): unjustified skip did not draft"
fi
if grep -qF '## Added test skips' "$RD/pr-body.md" 2>/dev/null && grep -qF '`tests/a.test.js:2`' "$RD/pr-body.md"; then
  pass "(j): PR body lists the skip at file:line"
else
  fail "(j): Added test skips section missing or without file:line"
fi
[ "$(jq -c '.test_runs' "$RD/run.json" 2>/dev/null)" = '[{"command":"npm test","passed":1,"skipped":1,"failed":0}]' ] \
  && pass "(j): test_runs recorded in run.json" || fail "(j): test_runs = $(jq -c '.test_runs' "$RD/run.json" 2>/dev/null)"

# Justified skip, old evolution output (no test-run lines).
set_branch "test('a', () => {});" "// blocked by #12" "it.skip('b', () => {});"
printf '%s\n' "EVOLUTION_RESULT: CLEAN" > "$WORK/evo-reply"
run_orch
if [ ! -f "$WORK/gh-pr-create.args" ]; then
  fail "(j): gh pr create never ran (justified)"
else
  drafted && fail "(j): justified skip drafted the PR" || pass "(j): justified skip and no test-run lines -> not a draft"
fi
grep -qF '## Added test skips' "$RD/pr-body.md" 2>/dev/null \
  && fail "(j): section printed for a justified skip only" || pass "(j): no section for a justified skip only"
[ "$(jq -c '.test_runs' "$RD/run.json" 2>/dev/null)" = '[]' ] \
  && pass "(j): no test-run lines -> test_runs []" || fail "(j): test_runs = $(jq -c '.test_runs' "$RD/run.json" 2>/dev/null)"

# .only, even explained.
set_branch "test('a', () => {});" "// focusing while debugging" "test.only('b', () => {});"
run_orch
drafted && pass "(j): .only -> draft PR even with a comment" || fail "(j): .only did not draft"
grep -qF 'tests/a.test.js:3' "$RD/pr-body.md" 2>/dev/null \
  && pass "(j): .only listed at file:line" || fail "(j): .only missing from the PR body"

[ "$FAIL" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$FAIL"
