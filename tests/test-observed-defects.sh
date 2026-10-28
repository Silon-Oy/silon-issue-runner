#!/usr/bin/env bash
# test-observed-defects.sh — unit tests for lib/observed-defects.sh (issue
# #391): the cycle review's CYCLE_REVIEW_OBSERVED_DEFECT lines → `observed`
# issues through lib/finding-issues.sh. labels_gh is a stateful function stub
# (created issues are listed back by the next index), so dedup across two runs
# is exercised end to end; no network.
#
# Run: bash tests/test-observed-defects.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# Only greps and an extracted function of orchestrate.sh run here, but pin the
# machine env file and the S3 wait anyway (test-env-hermeticity.sh).
export RUN_ISSUES_ENV_FILE="$HERE/.no-such-machine-env"
export RUN_ISSUES_CLAIM_VERIFY_DELAY=0

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available"
  exit 0
fi

# shellcheck source=../lib/observed-defects.sh
. "$ROOT/lib/observed-defects.sh"

FAIL=0
check() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 — got '$2', want '$3'"; FAIL=1; fi
}
contains() { # <label> <haystack> <needle>
  case "$2" in *"$3"*) echo "PASS: $1" ;; *) echo "FAIL: $1 — '$3' not in: $2"; FAIL=1 ;; esac
}
lacks() { # <label> <haystack> <needle>
  case "$2" in *"$3"*) echo "FAIL: $1 — '$3' found in: $2"; FAIL=1 ;; *) echo "PASS: $1" ;; esac
}

WORK=$(mktemp -d -t observed-defects.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ---- gh stub -----------------------------------------------------------------
# $WORK/issues.json: the issues the "repo" has. A POST to /issues appends one;
# a GET listing returns them. $WORK/fail-list / $WORK/fail-post force failures.
CALLS="$WORK/gh.calls"
POSTS="$WORK/posts"
echo '[]' > "$WORK/issues.json"
labels_gh() {
  printf '%s\n' "$*" >> "$CALLS"
  local method=GET path="" title="" body="" a
  local -a labels=()
  while [ $# -gt 0 ]; do
    a="$1"; shift
    case "$a" in
      api) ;;
      --method) method="$1"; shift ;;
      --paginate) ;;
      -f)
        case "$1" in
          title=*) title="${1#title=}" ;;
          body=*) body="${1#body=}" ;;
          labels\[\]=*) labels+=("${1#labels[]=}") ;;
        esac
        shift ;;
      *) path="$a" ;;
    esac
  done
  case "$method $path" in
    "POST repos/"*/labels) return 0 ;;
    "GET repos/"*/issues\?*)
      [ -f "$WORK/fail-list" ] && return 1
      cat "$WORK/issues.json" ;;
    "POST repos/"*/issues)
      [ -f "$WORK/fail-post" ] && { echo "HTTP 500" >&2; return 1; }
      local n
      n=$(( $(jq 'length' "$WORK/issues.json") + 100 ))
      printf '%s\n' "${labels[*]-}" >> "$POSTS.labels"
      printf '%s\n----\n' "$body" >> "$POSTS.bodies"
      jq --argjson n "$n" --arg t "$title" --arg b "$body" \
        '. + [{number: $n, state: "open", title: $t, body: $b}]' "$WORK/issues.json" > "$WORK/i.tmp" \
        && mv "$WORK/i.tmp" "$WORK/issues.json"
      printf '{"number":%s}' "$n" ;;
    *) return 0 ;;
  esac
}
post_count() { grep -c -- '--method POST repos/o/r/issues ' "$CALLS" 2>/dev/null || true; }
reset_repo() { echo '[]' > "$WORK/issues.json"; : > "$CALLS"; rm -f "$POSTS".*; }

# ---- parse -------------------------------------------------------------------
CR="$WORK/cr.out"
cat > "$CR" <<'OUT'
## χ — facts
CYCLE_REVIEW_OBSERVED_DEFECT: High | src/login.php:42 | Login link is not single-use | a replay works
CYCLE_REVIEW_OBSERVED_DEFECT: severe | src/a.php:1 | bad severity
CYCLE_REVIEW_OBSERVED_DEFECT: low | src/a.php:1
CYCLE_REVIEW_OBSERVED_DEFECT: low |  | empty location
CYCLE_REVIEW_OBSERVED_DEFECT: <critical|high|medium|low> | <tiedosto:rivi> | <kuvaus>
CYCLE_REVIEW_OBSERVED_DEFECT: medium | <tiedosto:rivi> | placeholder location
  CYCLE_REVIEW_OBSERVED_DEFECT: low | x.php:1 | indented, not a machine line
CYCLE_REVIEW_DECISION: PROCEED
OUT
parsed=$(observed_defects_parse "$CR" 2>"$WORK/parse.err")
check "parse: one well-formed line" "$(printf '%s\n' "$parsed" | grep -c .)" 1
check "parse: severity lower-cased, | kept in the description" "$parsed" \
  "$(printf 'high\tsrc/login.php:42\tLogin link is not single-use | a replay works')"
check "parse: five malformed lines logged" "$(grep -c '^observed-defect: unparseable line: ' "$WORK/parse.err")" 5
observed_defects_parse "$WORK/missing.out" >/dev/null 2>&1; check "parse: missing file is rc 0" "$?" 0

# ---- key ---------------------------------------------------------------------
check "key normalises case and whitespace" "$(observed_defects_key "  Login   LINK is	not ")" "login link is not"

# ---- cap -----------------------------------------------------------------------
check "max: default" "$(observed_defects_max "")" 3
check "max: invalid => default" "$(observed_defects_max "-1")" 3
check "max: numeric" "$(observed_defects_max 1)" 1

CAP="$WORK/cap.out"
for i in 1 2 3 4; do
  printf 'CYCLE_REVIEW_OBSERVED_DEFECT: medium | src/f%s.php:%s | defect number %s\n' "$i" "$i" "$i"
done > "$CAP"
reset_repo
res=$(observed_defects_record "$CAP" o/r 7 "" "$WORK/idx1.tsv" 2>&1); rc=$?
check "cap: rc 0" "$rc" 0
check "cap: three issues created" "$(post_count)" 3
check "cap: three created lines" "$(printf '%s\n' "$res" | grep -c '^observed-defect: created #')" 3
contains "cap: the fourth is logged" "$res" "observed-defect: over cap (3), not recorded: medium src/f4.php:4 — defect number 4"

reset_repo
res=$(RUN_ISSUES_OBSERVED_DEFECT_MAX=1; observed_defects_record "$CAP" o/r 7 "$RUN_ISSUES_OBSERVED_DEFECT_MAX" "$WORK/idx2.tsv" 2>&1)
check "cap: max 1 creates one" "$(post_count)" 1
check "cap: max 1 logs three over cap" "$(printf '%s\n' "$res" | grep -c 'over cap (1)')" 3

# ---- dedup across two runs, labels, body ----------------------------------------
ONE="$WORK/one.out"
printf 'CYCLE_REVIEW_OBSERVED_DEFECT: high | src/login.php:42 | Login link is not single-use\nCYCLE_REVIEW_DECISION: PROCEED\n' > "$ONE"
TWO="$WORK/two.out"
# The second run sees the same defect at a moved line, in other case/whitespace,
# and twice in one output.
printf 'CYCLE_REVIEW_OBSERVED_DEFECT: HIGH | ./src/login.php:57 | login link  is not single-use\nCYCLE_REVIEW_OBSERVED_DEFECT: high | src/login.php:58 | Login link is not single-use\nCYCLE_REVIEW_DECISION: BLOCKER\n' > "$TWO"
reset_repo
r1=$(observed_defects_record "$ONE" o/r 11 3 "$WORK/run1.idx" 2>&1)
r2=$(observed_defects_record "$TWO" o/r 12 3 "$WORK/run2.idx" 2>&1)
check "dedup: one POST over two runs" "$(post_count)" 1
contains "dedup: first run creates" "$r1" "observed-defect: created #100"
check "dedup: second run sees exists, once" "$(printf '%s\n' "$r2" | grep -c '^observed-defect: exists #100 ')" 1
check "dedup: second run writes nothing" "$(printf '%s\n' "$r2" | grep -c 'created\|reopened')" 0

check "labels: only observed" "$(cat "$POSTS.labels")" "observed"
lacks "labels: no auto-run" "$(cat "$POSTS.labels")" "auto-run"
grep -q -- 'issues?labels=observed&state=all' "$CALLS" && echo "PASS: index lists the observed label over all states" \
  || { echo "FAIL: index call: $(cat "$CALLS")"; FAIL=1; }
body=$(cat "$POSTS.bodies")
contains "body: location" "$body" '`src/login.php:42`'
contains "body: description" "$body" "Login link is not single-use"
contains "body: severity" "$body" "high"
contains "body: link to the run's issue" "$body" "https://github.com/o/r/issues/11"
contains "body: marker" "$body" "<!-- run-issues:finding kind=observed fp="
contains "title: observed defect" "$(jq -r '.[0].title' "$WORK/issues.json")" "Havaittu vika (high): Login link is not single-use — src/login.php"

# Another defect in the same file is another issue (the loss this issue ends).
printf 'CYCLE_REVIEW_OBSERVED_DEFECT: medium | src/login.php:90 | Portal payload is filtered with a denylist\n' > "$WORK/three.out"
observed_defects_record "$WORK/three.out" o/r 13 3 "$WORK/run3.idx" >/dev/null 2>&1
check "dedup: another defect in the same file is a new issue" "$(post_count)" 2

# ---- failures are logged, rc 0 -------------------------------------------------
reset_repo
touch "$WORK/fail-list"
res=$(observed_defects_record "$ONE" o/r 11 3 "$WORK/f1.idx" 2>&1); rc=$?
check "failed index: rc 0" "$rc" 0
contains "failed index: logged" "$res" "nothing recorded"
check "failed index: no POST" "$(post_count)" 0
rm -f "$WORK/fail-list"

touch "$WORK/fail-post"
res=$(observed_defects_record "$ONE" o/r 11 3 "$WORK/f2.idx" 2>&1); rc=$?
check "failed POST: rc 0" "$rc" 0
contains "failed POST: logged" "$res" "observed-defect: FAILED high src/login.php:42"
rm -f "$WORK/fail-post"

: > "$CALLS"
res=$(observed_defects_record "$WORK/missing.out" o/r 11 3 "$WORK/f3.idx" 2>&1); rc=$?
check "no lines: rc 0 and no gh call" "$rc:$(grep -c . "$CALLS")" "0:0"

# ---- the orchestrator wiring -----------------------------------------------------
# Grep-level guards: the opt-in default, the call site after the decision is
# recorded, and the poller turning it on.
grep -q 'RUN_ISSUES_OBSERVED_DEFECTS:-0' "$ROOT/orchestrate.sh" \
  && echo "PASS: orchestrator defaults OFF" || { echo "FAIL: orchestrator default"; FAIL=1; }
cr_body=$(awk '/^run_cycle_review\(\)/,/^}/' "$ROOT/orchestrate.sh")
check "record_observed_defects is the last step of run_cycle_review" \
  "$(printf '%s\n' "$cr_body" | grep -v '^}' | tail -1 | tr -d ' ')" "record_observed_defects"
light_line=$(printf '%s\n' "$cr_body" | grep -n 'run_light_review && return 0' | cut -d: -f1)
call_line=$(printf '%s\n' "$cr_body" | grep -n '^ *record_observed_defects$' | cut -d: -f1)
[ -n "$light_line" ] && [ -n "$call_line" ] && [ "$light_line" -lt "$call_line" ] \
  && echo "PASS: the light review returns before the defect step" || { echo "FAIL: light-path order"; FAIL=1; }
grep -q 'RUN_ISSUES_OBSERVED_DEFECTS="${RUN_ISSUES_OBSERVED_DEFECTS:-1}"' "$ROOT/poller.sh" \
  && grep -q "ORCH_ENV=\"\$ORCH_ENV RUN_ISSUES_OBSERVED_DEFECTS=" "$ROOT/poller.sh" \
  && echo "PASS: poller turns it on and passes it in ORCH_ENV" || { echo "FAIL: poller wiring"; FAIL=1; }

# record_observed_defects itself, extracted and driven with stubs: OFF does no
# work, ON never changes CR_DECISION or fails under set -e.
eval "$(awk '/^record_observed_defects\(\)/,/^}/' "$ROOT/orchestrate.sh")"
LOGF="$WORK/orch.log"; EVENTS="$WORK/events"
log() { printf '%s\n' "$*" >> "$LOGF"; }
state_event() { shift; printf '%s\n' "$*" >> "$EVENTS"; }
RUN_DIR="$WORK/run"; mkdir -p "$RUN_DIR"; cp "$ONE" "$RUN_DIR/01-cycle-review.out"
OWNER_REPO=o/r; ISSUE_NUM=11; CR_DECISION=PROCEED
reset_repo
( set -e; unset RUN_ISSUES_OBSERVED_DEFECTS; record_observed_defects; echo "$CR_DECISION" ) > "$WORK/off.out"; rc=$?
check "orchestrator OFF: rc 0, decision kept" "$rc:$(cat "$WORK/off.out")" "0:PROCEED"
check "orchestrator OFF: no gh call" "$(grep -c . "$CALLS")" 0
( set -e; RUN_ISSUES_OBSERVED_DEFECTS=1; record_observed_defects; echo "$CR_DECISION" ) > "$WORK/on.out"; rc=$?
check "orchestrator ON: rc 0, decision kept" "$rc:$(cat "$WORK/on.out")" "0:PROCEED"
check "orchestrator ON: one issue" "$(post_count)" 1
contains "orchestrator ON: logged" "$(cat "$LOGF")" "S6_CycleReview: observed-defect: created #100"
check "orchestrator ON: state event" "$(tail -1 "$EVENTS")" "observed_defects count=1 written=1"
touch "$WORK/fail-list"
( set -e; RUN_ISSUES_OBSERVED_DEFECTS=1; record_observed_defects; echo "$CR_DECISION" ) > "$WORK/fail.out"; rc=$?
check "orchestrator ON, failed index: rc 0, decision kept" "$rc:$(cat "$WORK/fail.out")" "0:PROCEED"
rm -f "$WORK/fail-list"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "observed-defects: all passed" || echo "observed-defects: FAILURES"
[ "$FAIL" -eq 0 ]
