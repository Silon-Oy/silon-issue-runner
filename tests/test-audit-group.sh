#!/usr/bin/env bash
# test-audit-group.sh — the grouping mode of the whole-repo audits (issue #396):
# repo_audit_group (lib/repo-audit.sh) through security-audit.sh, and the epic
# writer (lib/epic-write.sh) on its own. The agents are stubbed through
# RUN_ISSUES_CLAUDE_CMD (CLAUDE.md §5.5), gh is a PATH shim that records every
# call, and a git shim routes `fetch` to a local bare repo — no network.
#
#   A) --group                -> the plan as markdown and a JSON file; ZERO
#                                GitHub writes; bodies carry every member's
#                                finding marker and the issue format
#   B) --group --write        -> new-epic's order: epic → children → sub-issue
#                                links → blocked_by; epic labels epic + kind,
#                                child the kind; no pickup label, no assignee
#   C) dedup through a group issue -> its members are exists / reopen /
#                                dismissed and are not grouped again; a reopen
#                                in --write gets no pickup label
#   D) a rejected plan        -> cycle, missing member, member twice, unknown
#                                dependency, no result line: exit 3, no write
#   E) usage                  -> --write without --group, --write --dry-run:
#                                exit 1 (both audits)
#   F) an UNSURE finding      -> kept out of the groups, filed alone
#   G) epic_write_plan failures -> an epic that fails skips its children; a
#                                failed child does not stop its siblings; a
#                                dependency on an unwritten child is reported
#
# Run: bash tests/test-audit-group.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Hermetic: never source this machine's real env file (CLAUDE.md §5.5, #358).
export RUN_ISSUES_ENV_FILE="$HERE/.no-such-machine-env"
AUDIT="$HERE/../security-audit.sh"
COHERENCE="$HERE/../coherence-audit.sh"
QUALITY="$HERE/../quality-audit.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available"
  exit 0
fi

FAIL=0
bad() { echo "FAIL $1: $2"; FAIL=1; }
ok()  { echo "PASS $1: $2"; }

REAL_GIT=$(command -v git)
TMPDIR_ORIG="${TMPDIR:-/tmp}"

setup() {
  WORK=$(mktemp -d -t auditgroup-"$1".XXXXXX)
  export HOME="$WORK/home"; mkdir -p "$HOME"
  export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
  ORIGIN="$WORK/origin.git"; REPO="$WORK/repo"; BIN="$WORK/bin"
  mkdir -p "$BIN"
  git init -q --bare "$ORIGIN"
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  git init -q "$REPO"
  (
    cd "$REPO"
    git symbolic-ref HEAD refs/heads/main
    git config user.email t@t.t; git config user.name t
    mkdir -p src; echo a > src/a.php; echo b > src/b.php; echo c > src/c.php
    git add .; git commit -qm init
    git push -q "$ORIGIN" main
    git remote add origin https://github.com/Silon-Oy/app.git
  )
  cat > "$BIN/git" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = fetch ]; then
    exec "$REAL_GIT" -c "url.$ORIGIN.insteadOf=https://github.com/Silon-Oy/app.git" "\$@"
  fi
done
exec "$REAL_GIT" "\$@"
SH
  chmod +x "$BIN/git"
  PATH="$BIN:$PATH" git -C "$REPO" fetch -q origin
  git -C "$REPO" remote set-head origin main >/dev/null

  echo '[]' > "$WORK/issues.json"
  echo '[{"number":7,"title":"Existing open work","state":"open"}]' > "$WORK/open.json"
  : > "$WORK/gh.log"; : > "$WORK/calls.log"; echo 100 > "$WORK/next"
  mkdir -p "$WORK/created"
  # Every write is one line in writes.log: <kind> <target>.
  cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/gh.log"
[ "\$1" = api ] || exit 0
case "\$*" in
  *"--paginate"*"state=open"*) cat "$WORK/open.json"; exit 0 ;;
  *--paginate*) cat "$WORK/issues.json"; exit 0 ;;
  *"--method POST repos/Silon-Oy/app/labels "*)
    echo "label" >> "$WORK/writes.log"; exit 0 ;;
  *"--method POST repos/Silon-Oy/app/issues --input -"*)
    n=\$(cat "$WORK/next"); echo \$((n + 1)) > "$WORK/next"
    cat > "$WORK/created/\$n.json"
    echo "issue \$n" >> "$WORK/writes.log"
    if [ -f "$WORK/fail-create" ] && grep -qF "\$(cat "$WORK/fail-create")" "$WORK/created/\$n.json"; then
      echo "HTTP 500" >&2; exit 1
    fi
    printf '{"number":%s,"id":%s}\n' "\$n" "\$((n * 1000))"; exit 0 ;;
  *"/sub_issues "*)
    echo "sub_issue \$*" >> "$WORK/writes.log"; exit 0 ;;
  *"/dependencies/blocked_by "*)
    echo "blocked_by \$*" >> "$WORK/writes.log"; exit 0 ;;
  *"--method PATCH repos/Silon-Oy/app/issues/"*)
    echo "reopen" >> "$WORK/writes.log"; echo '{"assignees":[]}'; exit 0 ;;
  *"--method POST repos/Silon-Oy/app/issues/"*"/comments"*)
    echo "comment" >> "$WORK/writes.log"; exit 0 ;;
  *"--method POST repos/Silon-Oy/app/issues/"*"/labels"*)
    echo "add_labels \$*" >> "$WORK/writes.log"; exit 0 ;;
  *"--method POST repos/Silon-Oy/app/issues -f"*)
    n=\$(cat "$WORK/next"); echo \$((n + 1)) > "$WORK/next"
    for a in "\$@"; do
      case "\$a" in body=*) printf '%s' "\${a#body=}" > "$WORK/created/\$n.single" ;; esac
    done
    echo "single \$n" >> "$WORK/writes.log"
    printf '{"number":%s,"assignees":[]}\n' "\$n"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$BIN/gh"

  cat > "$BIN/claude-mock" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"GROUP_RESULT: OK"*)
    echo GROUP >> "$WORK/calls.log"
    printf '%s\n' "\$*" > "$WORK/group-prompt-seen"
    cat "$WORK/group.txt"; exit 0 ;;
  *"VERIFY_RESULT: CONFIRMED|REFUTED|UNSURE"*)
    case "\$*" in *"[csrf]"*) [ -f "$WORK/csrf-unsure" ] && { echo 'VERIFY_RESULT: UNSURE'; exit 0; } ;; esac
    echo 'VERIFY_RESULT: CONFIRMED'; exit 0 ;;
esac
echo AUDIT >> "$WORK/calls.log"
cat "$WORK/review.txt"
SH
  chmod +x "$BIN/claude-mock"
  cat > "$WORK/review.txt" <<'TXT'
FINDING: high | high | src/a.php:3 | [xss] GET parameter q is echoed unescaped
FINDING: high | medium | src/b.php:9 | [xss-attr] attribute value is echoed unescaped
FINDING: medium | high | src/c.php:1 | [csrf] form posts without a token
MERGE_GATE_RESULT: FINDINGS
TXT
  group_plan '["g1"]'
}

# group_plan <g2-depends-on-json> [<g1-members-json>] [<g2-members-json>] — the
# grouping agent's answer: one epic, g1 = the two xss findings, g2 = csrf.
group_plan() {
  local deps="$1" m1="${2:-[1,2]}" m2="${3:-[3]}" g1deps="${4:-[]}"
  cat > "$WORK/group.txt" <<TXT
Two fixes: escaping first, then the token that uses the escaping helper.
\`\`\`json
{"epics":[{"title":"Output escaping and forms","goal":"Close the injection paths.",
  "overlaps":[{"issue":7,"note":"touches the same form"}],
  "human_tasks":["Decide the CSP policy"],
  "groups":[
   {"id":"g1","title":"Escape output","goal":"No unescaped output.","members":$m1,
    "implementation":"Add an escaping helper and use it.","acceptance":["Output is escaped"],
    "out_of_scope":["Templates"],"depends_on":$g1deps},
   {"id":"g2","title":"CSRF token","goal":"Forms carry a token.","members":$m2,
    "implementation":"Add a token via the helper.","acceptance":["Token checked"],
    "out_of_scope":[],"depends_on":$deps}]}]}
\`\`\`
GROUP_RESULT: OK
TXT
}

run_audit() {
  set +e
  OUT=$( env PATH="$BIN:$PATH" HOME="$HOME" \
    RUN_ISSUES_CLAUDE_CMD="$BIN/claude-mock" \
    RUN_ISSUES_SECURITY_AUDIT_TIMEOUT=60 \
    RUN_ISSUES_WATCHLIST="$WORK/no-watchlist.json" \
    RUN_ISSUES_GITLEAKS_BIN="$WORK/no-gitleaks" RUN_ISSUES_OSV_SCANNER_BIN="$WORK/no-osv" \
    ${AUDIT_ENV:-} "$AUDIT" "$REPO" "$@" 2>&1 )
  RC=$?
}

writes() { [ -f "$WORK/writes.log" ] && wc -l < "$WORK/writes.log" | tr -d ' ' || echo 0; }
show() { echo "$OUT" | sed "s/^/$1| /"; echo "$1| (rc=$RC)"; }
done_case() { [ -n "${KEEP:-}" ] || rm -rf "$WORK"; }
fp_of() { ( . "$HERE/../lib/finding-issues.sh"; finding_fingerprint "$@" ); }
FP1=$(fp_of agent src/a.php xss)
FP2=$(fp_of agent src/b.php xss-attr)
FP3=$(fp_of agent src/c.php csrf)

# ===========================================================================
echo "=== A: --group prints the plan, writes nothing ==="
F0=$FAIL; setup A
group_plan '["g1"]'
run_audit --group
[ "$RC" = 0 ] || { show A; bad A "rc $RC, want 0"; }
[ "$(writes)" = 0 ] || bad A "$(writes) GitHub write(s), want 0"
grep -q -- '--method' "$WORK/gh.log" && bad A "a --method call in plan mode"
grep -q '^# Ryhmittelysuunnitelma (security): 3 löydöstä → 2 issueta, 1 epiciä' <<<"$OUT" || bad A "markdown plan header missing"
grep -q 'odottaa: g1' <<<"$OUT" || bad A "dependency not shown in the plan"
grep -q 'dry run: nothing written' <<<"$OUT" || bad A "summary does not say nothing was written"
PLAN=$(sed -n 's/^plan JSON: //p' <<<"$OUT")
if [ -n "$PLAN" ] && jq -e '.epics | length == 1' "$PLAN" >/dev/null 2>&1; then
  G1=$(jq -r '.epics[0].children[] | select(.key == "g1") | .body' "$PLAN")
  for fp in "$FP1" "$FP2"; do
    grep -qF "<!-- run-issues:finding kind=security fp=$fp -->" <<<"$G1" || bad A "g1 lacks the marker of $fp"
  done
  grep -qF "fp=$FP3" <<<"$G1" && bad A "g1 carries a marker of another group's finding"
  for h in '## Tavoite' '## Löydökset' '## Toteutus' '## Hyväksyntäkriteerit' '## Rajaukset'; do
    grep -qx "$h" <<<"$G1" || bad A "group body lacks '$h'"
  done
  grep -qF -- '- `src/a.php:3` — high' <<<"$G1" || bad A "finding not listed with file:line"
  EB=$(jq -r '.epics[0].body' "$PLAN")
  for h in '## Päällekkäisyydet avoimien issueiden kanssa' '## Ihmisen tehtävät'; do
    grep -qx "$h" <<<"$EB" || bad A "epic body lacks '$h'"
  done
  grep -qF -- '- #7 — touches the same form' <<<"$EB" || bad A "overlap not named in the epic body"
  grep -qF -- '- [ ] Decide the CSP policy' <<<"$EB" || bad A "human task not in the epic body"
  [ "$(jq -r '.epics[0].title' "$PLAN")" = "Tietoturva (high): Output escaping and forms" ] || bad A "epic title: $(jq -r '.epics[0].title' "$PLAN")"
else
  show A; bad A "no readable plan JSON ('$PLAN')"
fi
grep -q '#7 Existing open work' "$WORK/group-prompt-seen" 2>/dev/null || bad A "open issues not given to the grouping agent"
[ "$FAIL" = "$F0" ] && ok A "plan without writes"
done_case

# ===========================================================================
echo "=== B: --group --write writes in new-epic's order ==="
F0=$FAIL; setup B
run_audit --group --write
[ "$RC" = 0 ] || { show B; bad B "rc $RC, want 0"; }
ORDER=$(awk '{ print $1 }' "$WORK/writes.log" 2>/dev/null | grep -v '^label$' | paste -sd' ' -)
[ "$ORDER" = "issue issue issue sub_issue sub_issue blocked_by" ] || bad B "write order '$ORDER'"
[ "$(grep -n . "$WORK/writes.log" | grep -m1 -v ':label$' | cut -d: -f1)" -gt "$(grep -c '^label$' "$WORK/writes.log")" ] \
  || bad B "a label was ensured after the first create"
[ "$(jq -c '.labels' "$WORK/created/100.json" 2>/dev/null)" = '["epic","security"]' ] || bad B "epic labels $(jq -c '.labels' "$WORK/created/100.json" 2>/dev/null)"
[ "$(jq -c '.labels' "$WORK/created/101.json" 2>/dev/null)" = '["security"]' ] || bad B "child labels $(jq -c '.labels' "$WORK/created/101.json" 2>/dev/null)"
grep -q 'Escape output' "$WORK/created/101.json" || bad B "first child is not the g1 issue"
grep -q 'auto-run' "$WORK/gh.log" "$WORK/created/"*.json && bad B "a pickup label was written"
grep -q 'assignee' "$WORK/gh.log" "$WORK/created/"*.json && bad B "an assignee was written"
grep -q 'issues/100/sub_issues -F sub_issue_id=101000' "$WORK/writes.log" || bad B "child 101 not linked to epic 100 by id"
grep -q 'issues/100/sub_issues -F sub_issue_id=102000' "$WORK/writes.log" || bad B "child 102 not linked to epic 100 by id"
grep -q 'issues/102/dependencies/blocked_by -F issue_id=101000' "$WORK/writes.log" || bad B "g2 not blocked by g1's id"
grep -q '^created epic #100' <<<"$OUT" || bad B "output does not report the epic"
[ "$FAIL" = "$F0" ] && ok B "write order, labels and links"
done_case

# ===========================================================================
echo "=== C: dedup through a group issue ==="
F0=$FAIL; setup C
# group_issue <number> <state> <state_reason> — one issue carrying all three markers.
group_issue() {
  jq -n --argjson n "$1" --arg s "$2" --arg r "$3" --arg a "$FP1" --arg b "$FP2" --arg c "$FP3" \
    '[{number:$n, state:$s, state_reason:(if $r == "" then null else $r end), title:"group",
       body:("x\n<!-- run-issues:finding kind=security fp=" + $a + " -->\n<!-- run-issues:finding kind=security fp=" + $b + " -->\n<!-- run-issues:finding kind=security fp=" + $c + " -->")}]'
}
group_issue 50 open "" > "$WORK/issues.json"
run_audit --group
if [ "$RC" = 0 ] && [ "$(grep -c '^exists 50' <<<"$OUT")" = 3 ] && ! grep -q GROUP "$WORK/calls.log" \
   && grep -q 'no new confirmed findings to group' <<<"$OUT"; then ok C1 "open group issue: every member exists, nothing grouped"
else show C1; bad C1 "open group issue not recognised"; fi
done_case
setup C2; group_issue 50 closed completed > "$WORK/issues.json"
run_audit --group
if [ "$RC" = 0 ] && [ "$(grep -c '^reopen 50 \[security\]' <<<"$OUT")" = 3 ] && [ "$(writes)" = 0 ]; then ok C2 "completed group issue: reopen planned, kind label only"
else show C2; bad C2 "completed group issue not planned as reopen"; fi
done_case
setup C3; group_issue 50 closed not_planned > "$WORK/issues.json"
run_audit --group --write
if [ "$RC" = 0 ] && [ "$(grep -c '^dismissed #50' <<<"$OUT")" = 3 ] && [ "$(writes)" = 0 ]; then ok C3 "dismissed group issue is never reopened"
else show C3; bad C3 "dismissed group issue mishandled"; fi
done_case
setup C4   # one member already filed and completed: reopened without pickup; the rest grouped
jq -n --arg a "$FP3" '[{number:60, state:"closed", state_reason:"completed", title:"csrf",
  body:("<!-- run-issues:finding kind=security fp=" + $a + " -->")}]' > "$WORK/issues.json"
group_plan '[]' '[1]' '[2]'
run_audit --group --write
if [ "$RC" = 0 ] && grep -q '^reopened #60' <<<"$OUT" && grep -q 'add_labels .*issues/60/labels -f labels\[\]=security$' "$WORK/writes.log" \
   && ! grep -q 'auto-run' "$WORK/gh.log" && [ "$(grep -c '^issue ' "$WORK/writes.log")" = 3 ]; then
  ok C4 "reopen keeps its path without a pickup label; the new findings are grouped"
else show C4; cat "$WORK/writes.log" 2>/dev/null; bad C4 "mixed reopen + group"; fi
done_case
[ "$FAIL" = "$F0" ] && ok C "dedup through the group issue"

# ===========================================================================
echo "=== D: a rejected plan writes nothing ==="
F0=$FAIL
reject_case() { # <name> <why> — group.txt already set
  run_audit --group --write
  if [ "$RC" = 3 ] && [ "$(writes)" = 0 ] && grep -q "$2" <<<"$OUT"; then ok "$1" "rejected: $2"
  else show "$1"; bad "$1" "rc $RC, $(writes) write(s), want 3 and 0 with '$2'"; fi
  done_case
}
setup D1; group_plan '["g1"]' '[1,2]' '[3]' '["g2"]'; reject_case D1 "cycle"
setup D2; group_plan '[]' '[1]' '[3]';                 reject_case D2 "exactly one group"
setup D3; group_plan '[]' '[1,2]' '[2,3]';             reject_case D3 "exactly one group"
setup D4; group_plan '["g9"]';                         reject_case D4 "names no group"
setup D5; group_plan '[]' '[1,2]' '[3,4]';             reject_case D5 "not a finding number"
setup D6; printf 'no plan today\n' > "$WORK/group.txt"; reject_case D6 "no result"
setup D7; printf 'GROUP_RESULT: OK\n' > "$WORK/group.txt"; reject_case D7 "rejected"
[ "$FAIL" = "$F0" ] && ok D "validation"

# ===========================================================================
echo "=== E: usage ==="
F0=$FAIL; setup E
run_audit --write
[ "$RC" = 1 ] && grep -q -- '--write needs --group' <<<"$OUT" || { show E1; bad E1 "--write alone: rc $RC"; }
run_audit --group --write --dry-run
[ "$RC" = 1 ] || { show E2; bad E2 "--group --write --dry-run: rc $RC"; }
set +e; OUT=$("$COHERENCE" "$REPO" --write 2>&1); RC=$?
[ "$RC" = 1 ] || { show E3; bad E3 "coherence --write alone: rc $RC"; }
set +e; OUT=$("$QUALITY" "$REPO" --write 2>&1); RC=$?
[ "$RC" = 1 ] && grep -q -- '--write needs --group' <<<"$OUT" || { show E5; bad E5 "quality --write alone: rc $RC"; }
for f in "$AUDIT" "$COHERENCE" "$QUALITY"; do grep -q -- '--group' "$f" || bad E4 "flag missing from $(basename "$f")"; done
[ "$(writes)" = 0 ] || bad E "a usage error wrote something"
[ "$FAIL" = "$F0" ] && ok E "usage errors"
done_case

# ===========================================================================
echo "=== F: an UNSURE finding is not grouped ==="
F0=$FAIL; setup F
touch "$WORK/csrf-unsure"
group_plan '[]' '[1,2]' '[]'
# Only two candidates: the plan of one group.
cat > "$WORK/group.txt" <<'TXT'
```json
{"epics":[{"title":"Escaping","goal":"g","overlaps":[],"human_tasks":[],
  "groups":[{"id":"g1","title":"Escape output","goal":"g","members":[1,2],"implementation":"i",
             "acceptance":[],"out_of_scope":[],"depends_on":[]}]}]}
```
GROUP_RESULT: OK
TXT
AUDIT_ENV="RUN_ISSUES_AUDIT_VERIFY=1" run_audit --group --write
if [ "$RC" = 0 ] && grep -q '^created #[0-9]*.*src/c.php' <<<"$OUT" \
   && [ "$(grep -c '^single ' "$WORK/writes.log")" = 1 ] && [ "$(grep -c '^issue ' "$WORK/writes.log")" = 2 ] \
   && ! grep -q '\[csrf\]' "$WORK/group-prompt-seen"; then ok F "unsure finding filed alone, not grouped"
else show F; cat "$WORK/writes.log" 2>/dev/null; bad F "unsure finding handling"; fi
done_case

# ===========================================================================
echo "=== G: epic_write_plan failures ==="
F0=$FAIL
export TMPDIR="${TMPDIR_ORIG:-/tmp}"
G=$(mktemp -d "$TMPDIR/epicwrite.XXXXXX")
(
  export TMPDIR="$G"
  . "$HERE/../lib/epic-write.sh"
  : > "$G/log"; echo 1 > "$G/next"
  labels_gh() {
    printf '%s\n' "$*" >> "$G/log"
    case "$*" in
      *"--input -"*)
        local body n; body=$(cat)
        case "$body" in *FAILME*) return 1 ;; esac
        n=$(cat "$G/next"); echo $((n + 1)) > "$G/next"
        printf '{"number":%s,"id":%s}' "$n" "$((n * 10))" ;;
    esac
    return 0
  }
  jq -n '{epics: [
    {key: "e1", title: "FAILME epic", body: "b", labels: ["k"],
     children: [{key: "a", title: "a", body: "b", labels: ["k"], blocked_by: []}]},
    {key: "e2", title: "ok epic", body: "b", labels: ["k"],
     children: [{key: "b", title: "FAILME child", body: "b", labels: ["k"], blocked_by: []},
                {key: "c", title: "c", body: "b", labels: ["k"], blocked_by: ["b"]},
                {key: "d", title: "d", body: "b", labels: ["k"], blocked_by: ["c"]}]}]}' > "$G/plan.json"
  epic_write_plan o/r "$G/plan.json" "$G/ledger" > "$G/out"; echo $? > "$G/rc"
)
[ "$(cat "$G/rc")" = 1 ] || bad G1 "rc $(cat "$G/rc"), want 1"
grep -q '^FAIL epic: FAILME epic' "$G/out" || bad G2 "failed epic not reported"
grep -q '"title":"a"' "$G/log" && bad G3 "a child of the failed epic was written"
grep -q '^FAIL child: FAILME child' "$G/out" || bad G4 "failed child not reported"
[ "$(grep -c '^child' "$G/ledger")" = 2 ] || bad G5 "the failed child stopped its siblings"
grep -q '^FAIL blocked_by: c waits for b' "$G/out" || bad G6 "dependency on an unwritten child not reported"
grep -q 'issues/3/dependencies/blocked_by -F issue_id=20' "$G/log" || bad G7 "d not blocked by c ($(cat "$G/out"))"
[ "$(grep -c '^sub_issue' "$G/ledger")" = 2 ] || bad G8 "written children not linked"
rm -rf "$G"
[ "$FAIL" = "$F0" ] && ok G "partial failures"

# ===========================================================================
echo "=== H: a finding with an id set is not grouped (#397) ==="
# A package version's advisories ride as "<key>\t<ids>" from the key-fn. The
# grouping mode splits them off exactly as repo_audit_apply does, so the
# fingerprint matches the ordinary audit's, and passes the finding through to
# its single-finding path with <after-fn>: no grouping agent is called.
F0=$FAIL
export TMPDIR="${TMPDIR_ORIG:-/tmp}"
H=$(mktemp -d "$TMPDIR/auditgroup-H.XXXXXX")
HFP=$(fp_of osv-scanner-pkg package-lock.json npm/left-pad@1.0.0)
(
  export TMPDIR="$H"
  . "$HERE/../lib/repo-audit.sh"
  set +e
  WORK="$H"; OWNER_REPO=Silon-Oy/app; HEAD_SHA=abc; BASE_REF=main
  INDEX="$H/index.tsv"
  # An open issue of the same package version, covering both ids already.
  printf '%s\tsecurity\t42\topen\tleft-pad\tGHSA-1,GHSA-2\n' "$HFP" > "$INDEX"
  FINDINGS="scanner|high|high|package-lock.json:1|left-pad advisories
scanner|high|high|package-lock.json:1|left-pad advisories, new id"
  k_fn() { case "$2" in *"new id"*) printf 'osv-scanner-pkg\tnpm/left-pad@1.0.0\tGHSA-1,GHSA-2,GHSA-3' ;;
                        *) printf 'osv-scanner-pkg\tnpm/left-pad@1.0.0\tGHSA-1,GHSA-2' ;; esac; }
  l_fn() { printf 'security,auto-run'; }
  t_fn() { printf 'T'; }
  b_fn() { printf 'B'; }
  a_fn() { printf 'AFTER %s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >> "$H/after.log"; }
  call_claude() { echo CALLED >> "$H/calls.log"; return 1; }
  repo_audit_group security 0 Tietoturva c k_fn l_fn t_fn b_fn a_fn > "$H/out" 2>&1
  echo $? > "$H/rc"
)
[ "$(cat "$H/rc")" = 0 ] || bad H1 "rc $(cat "$H/rc"), want 0 ($(cat "$H/out"))"
[ -s "$H/calls.log" ] && bad H2 "the grouping agent was called for a finding with an id set"
grep -q '^exists 42' "$H/out" || bad H3 "the stripped key did not match the open issue's fingerprint ($(cat "$H/out"))"
[ "$(grep -c '^AFTER osv-scanner-pkg|npm/left-pad@1.0.0|' "$H/after.log" 2>/dev/null)" = 1 ] \
  || bad H4 "<after-fn> did not run once for the passed-through finding ($(cat "$H/after.log" 2>/dev/null))"
grep -q '^duplicate' "$H/out" || bad H5 "the second row of the same fingerprint is not a duplicate"
rm -rf "$H"
[ "$FAIL" = "$F0" ] && ok H "id-set findings pass through with the ordinary fingerprint"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "audit-group: all passed" || echo "audit-group: FAILURES"
[ "$FAIL" -eq 0 ]
