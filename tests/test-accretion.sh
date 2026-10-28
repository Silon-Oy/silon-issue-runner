#!/usr/bin/env bash
# test-accretion.sh — unit tests for lib/accretion.sh (issue #411): the file
# accretion meter on a fixture repo, its markdown and JSON shapes, and the
# orchestrator's promise that the meter never touches the draft flag.
#
# Run: bash tests/test-accretion.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# Only greps of orchestrate.sh run here, but pin the machine env file and the
# S3 wait anyway (test-env-hermeticity.sh).
export RUN_ISSUES_ENV_FILE="$HERE/.no-such-machine-env"
export RUN_ISSUES_CLAIM_VERIFY_DELAY=0

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available"
  exit 0
fi

# shellcheck source=../lib/accretion.sh
. "$ROOT/lib/accretion.sh"

FAIL=0
check() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 — got '$2', want '$3'"; FAIL=1; fi
}

WORK=$(mktemp -d -t accretion.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"

lines() { seq 1 "$1"; } # <n> — n lines of text

R="$WORK/repo"
git init -q "$R"
git -C "$R" config user.email t@example.invalid
git -C "$R" config user.name test
mkdir -p "$R/.claude" "$R/src/__snapshots__"
echo '{"accretion":{"max_lines":10}}' > "$R/.claude/run-issues.json"
printf 'gen/* linguist-generated\n' > "$R/.gitattributes"
mkdir -p "$R/gen"
lines 12 > "$R/src/grow.ts"       # over, will grow
lines 20 > "$R/src/shrink.ts"     # over, will shrink
lines 5  > "$R/src/small.ts"      # under, will grow but stay under
lines 12 > "$R/gen/out.ts"        # generated, will grow
lines 12 > "$R/yarn.lock"         # lock file, will grow
lines 12 > "$R/src/__snapshots__/a.ts.snap"
git -C "$R" add -A && git -C "$R" commit -q -m base
BASE=$(git -C "$R" rev-parse HEAD)

lines 15 > "$R/src/grow.ts"
lines 18 > "$R/src/shrink.ts"
lines 9  > "$R/src/small.ts"
lines 30 > "$R/gen/out.ts"
lines 30 > "$R/yarn.lock"
lines 30 > "$R/src/__snapshots__/a.ts.snap"
lines 11 > "$R/src/new.ts"        # new file over the threshold
printf '\x00\x01binary' > "$R/blob.bin"
git -C "$R" add -A && git -C "$R" commit -q -m head

got=$(accretion_findings "$BASE" HEAD "$R" | sort)
want=$(printf 'src/grow.ts\t15\t3\t10\nsrc/new.ts\t11\t11\t10\n')
check "growing over threshold and new file hit; shrinking, under, generated, lock, snapshot, binary do not" "$got" "$want"

check "max_lines override" "$(accretion_max_lines "$R")" "10"
echo '{"accretion":{"max_lines":"lots"}}' > "$R/.claude/run-issues.json"
check "non-numeric max_lines falls back to default" "$(accretion_max_lines "$R")" "1000"
echo '{"accretion":{"max_lines":0}}' > "$R/.claude/run-issues.json"
check "zero max_lines falls back to default" "$(accretion_max_lines "$R")" "1000"
rm -f "$R/.claude/run-issues.json"
check "missing config uses default" "$(accretion_max_lines "$R")" "1000"
check "default threshold: no hits on small files" "$(accretion_findings "$BASE" HEAD "$R")" ""

lines 1001 > "$R/src/grow.ts"
git -C "$R" commit -q -am big
check "default threshold: 1001 lines hit" \
  "$(accretion_findings "$BASE" HEAD "$R")" "$(printf 'src/grow.ts\t1001\t989\t1000')"

check "git error is rc != 0 with empty output" \
  "$(accretion_findings no-such-ref HEAD "$R"; echo "rc=$?")" "rc=1"

md=$(printf 'src/grow.ts\t15\t3\t10\n' | accretion_format_markdown)
check "markdown row is verbatim" "$md" '- `src/grow.ts`: 15 riviä (+3), kynnys 10'

json=$(printf 'src/grow.ts\t15\t3\t10\nsrc/new.ts\t11\t11\t10\n' | accretion_to_json)
check "JSON is an array of objects" \
  "$(jq -c '.[0]' <<< "$json")" '{"path":"src/grow.ts","lines":15,"growth":3,"threshold":10}'
check "JSON length" "$(jq 'length' <<< "$json")" "2"
check "empty input is an empty array" "$(printf '\n' | accretion_to_json)" "[]"

# run.json gets the array as JSON, not as a string; invalid JSON leaves it intact.
# shellcheck source=../lib/state.sh
. "$ROOT/lib/state.sh"
set +e # state.sh sets -e; this file collects every failure (CLAUDE.md §12)
RD="$WORK/run"; mkdir -p "$RD"; echo '{"issue":1}' > "$RD/run.json"
state_set_json "$RD" accretion "$json"
check "state_set_json writes an array" "$(jq -r '.accretion | type' "$RD/run.json")" "array"
state_set_json "$RD" accretion "not json" 2>/dev/null
check "state_set_json rejects invalid JSON without clobbering" "$(jq -r '.accretion | length' "$RD/run.json")" "2"

# The meter is advisory: the draft flag derives from imp/evo results only.
draft_case=$(grep -A2 'local pr_draft_flag=""' "$ROOT/orchestrate.sh")
case "$draft_case" in
  *accretion*) echo "FAIL: draft flag references the accretion meter"; FAIL=1 ;;
  *'${imp_result}${evo_result}'*) echo "PASS: draft flag derives from imp/evo results only" ;;
  *) echo "FAIL: draft flag shape changed: $draft_case"; FAIL=1 ;;
esac
grep -q '### Structural (file accretion)' "$ROOT/orchestrate.sh" \
  && echo "PASS: PR body has the accretion subheading" \
  || { echo "FAIL: accretion subheading missing from orchestrate.sh"; FAIL=1; }
grep -q 'state_set_json "$RUN_DIR" accretion' "$ROOT/orchestrate.sh" \
  && echo "PASS: run.json gets the accretion key" \
  || { echo "FAIL: run.json accretion write missing"; FAIL=1; }

exit "$FAIL"
