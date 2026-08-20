#!/usr/bin/env bash
# test-run-epic.sh — /run-epic's backing script run-epic.sh (issue #82).
#
# WHAT IS PINNED HERE (the acceptance criteria of #82):
#   - Validation refuses BEFORE any write and names the reason: not-open epic
#     (exit 2), empty epic (exit 3), cyclic dependency graph (exit 4, cycle
#     named), unreadable graph (exit 5, fail-closed).
#   - --dry-run writes NOTHING (no labels_add / labels_ensure recorded) yet
#     prints the full report (AC2).
#   - A successful apply propagates the run labels to the OPEN children through
#     the SHARED propagate_run_labels (AC4 — no second propagation copy) and adds
#     the `epic` label when it is missing (docs §5.2 avoin päätös I).
#   - The report answers the four questions: first runnable child, blocked +
#     behind what, chain length, what was labelled.
#   - --start-now launches orchestrate.sh for the first runnable child.
#
# `gh` is a STATEFUL mock modelled on test-epic.sh: it serves issue objects,
# native sub-issues and blocked_by graphs from fixtures, and records label writes
# and comments, so a dry-run's "wrote nothing" is verified end to end.
#
# Run: bash tests/test-run-epic.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RUN_EPIC="$ROOT/run-epic.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed — run-epic exercises real jq filters"
  exit 0
fi

WORK=$(mktemp -d -t runepictest.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
fail() { echo "FAIL: $*"; FAIL=1; }
pass() { echo "PASS: $*"; }

# --- stateful fixture store ------------------------------------------------
STATE="$WORK/state"
mkdir -p "$STATE/labels" "$STATE/body" "$STATE/title" "$STATE/state" \
         "$STATE/comments" "$STATE/subissues" "$STATE/blockers" \
         "$STATE/exists" "$STATE/subissues_fail" "$STATE/blockers_fail"
REC="$WORK/rec"; mkdir -p "$REC"
: > "$REC/labels_add"     # <number>:<csv>
: > "$REC/labels_ensure"  # <label>
: > "$REC/labels_remove"  # <number>:<label>
: > "$REC/orchestrate"    # start-now shim arg line
: > "$REC/stoprun"        # stop-run shim arg line

THISHOST="$(hostname -s 2>/dev/null || echo unknown)"

# seed_run <dir-id> <issue> <host> <status> [remote] — write a run.json fixture
# under the repo's run-issues dir so run-epic's --stop scan can find (and classify)
# a live/foreign/terminal run of a child.
seed_run() {
  mkdir -p "$REPO/.claude/run-issues/$1"
  jq -n --argjson n "$2" --arg h "$3" --arg s "$4" --arg r "${5:-origin}" \
    '{issue_number:$n, host:$h, status:$s, remote:$r}' \
    > "$REPO/.claude/run-issues/$1/run.json"
}

seed()          { printf '%s' "$3" > "$STATE/$1/$2"; touch "$STATE/exists/$2"; }
seed_labels()   { seed labels "$1" "$2"; }
seed_body()     { seed body "$1" "$2"; }
seed_title()    { seed title "$1" "$2"; }
seed_state()    { seed state "$1" "$2"; }         # OPEN / CLOSED
seed_subs()     { seed subissues "$1" "$2"; }     # JSON array
seed_blockers() { printf '%s' "$2" > "$STATE/blockers/$1"; }  # JSON array

# A GitHub repository is a git dir; run-epic checks for .git.
REPO="$WORK/repo"; mkdir -p "$REPO/.git"

# --- gh mock ---------------------------------------------------------------
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
set -u
STATE="$STATE"; REC="$REC"

build_obj() {
  local n="\$1"
  local csv=""; [ -f "\$STATE/labels/\$n" ] && csv="\$(cat "\$STATE/labels/\$n")"
  local body=""; [ -f "\$STATE/body/\$n" ] && body="\$(cat "\$STATE/body/\$n")"
  local title=""; [ -f "\$STATE/title/\$n" ] && title="\$(cat "\$STATE/title/\$n")"
  local st="OPEN"; [ -f "\$STATE/state/\$n" ] && st="\$(cat "\$STATE/state/\$n")"
  local labels_json comments_json
  labels_json=\$(jq -cn --arg csv "\$csv" '\$csv | split(",") | map(select(length>0) | {name:.})')
  if [ -s "\$STATE/comments/\$n.jsonl" ]; then comments_json=\$(jq -s '.' "\$STATE/comments/\$n.jsonl"); else comments_json='[]'; fi
  jq -n --argjson labels "\$labels_json" --arg body "\$body" --arg title "\$title" \\
        --argjson comments "\$comments_json" --arg st "\$st" \\
        '{title:\$title, body:\$body, labels:\$labels, comments:\$comments, state:\$st, author:{login:"tester"}}'
}

sub="\$1"
case "\$sub" in
  repo) printf 'silon-oy/demo\n' ;;
  issue)
    action="\$2"
    case "\$action" in
      view)
        n="\$3"; expr=""; prev=""
        for a in "\$@"; do case "\$prev" in --jq) expr="\$a";; esac; prev="\$a"; done
        # A non-existent issue makes gh fail (mimics "not found") → exit 1.
        [ -f "\$STATE/exists/\$n" ] || exit 1
        obj="\$(build_obj "\$n")"
        if [ -n "\$expr" ]; then printf '%s' "\$obj" | jq -r "\$expr"; else printf '%s' "\$obj"; fi ;;
      comment)
        n="\$3"; file=""; prev=""
        for a in "\$@"; do case "\$prev" in --body-file) file="\$a";; esac; prev="\$a"; done
        body=""; if [ "\$file" = "-" ] || [ -z "\$file" ]; then body="\$(cat)"; else body="\$(cat "\$file")"; fi
        jq -n --arg b "\$body" '{body:\$b}' >> "\$STATE/comments/\$n.jsonl" ;;
    esac ;;
  api)
    path=""; expr=""; prev=""
    for a in "\$@"; do
      case "\$a" in repos/*) [ -z "\$path" ] && path="\$a";; esac
      case "\$prev" in --jq) expr="\$a";; esac
      prev="\$a"
    done
    case "\$path" in
      *"/issues/"*"/labels/"*)
        # DELETE repos/o/r/issues/N/labels/<label> — labels_remove. Record it so
        # the order invariant (epic before children) is verifiable.
        n="\${path##*/issues/}"; n="\${n%%/*}"
        lbl="\${path##*/labels/}"
        printf '%s:%s\n' "\$n" "\$lbl" >> "\$REC/labels_remove" ;;
      *"/sub_issues")
        n="\${path##*/issues/}"; n="\${n%%/*}"
        [ -f "\$STATE/subissues_fail/\$n" ] && exit 1
        if [ -f "\$STATE/subissues/\$n" ]; then cat "\$STATE/subissues/\$n"; else echo '[]'; fi ;;
      *"/dependencies/blocked_by")
        n="\${path##*/issues/}"; n="\${n%%/*}"
        [ -f "\$STATE/blockers_fail/\$n" ] && exit 1
        arr='[]'; [ -f "\$STATE/blockers/\$n" ] && arr="\$(cat "\$STATE/blockers/\$n")"
        if [ -n "\$expr" ]; then printf '%s' "\$arr" | jq -r "\$expr"; else printf '%s' "\$arr"; fi ;;
      *"/issues/"*"/labels")
        n="\${path##*/issues/}"; n="\${n%%/*}"
        added=""; prev=""
        for a in "\$@"; do
          if [ "\$prev" = "-f" ]; then case "\$a" in labels\\[\\]=*) lbl="\${a#labels[]=}"; [ -z "\$added" ] && added="\$lbl" || added="\$added,\$lbl";; esac; fi
          prev="\$a"
        done
        printf '%s:%s\n' "\$n" "\$added" >> "\$REC/labels_add"
        cur=""; [ -f "\$STATE/labels/\$n" ] && cur="\$(cat "\$STATE/labels/\$n")"
        IFS=','; for lbl in \$added; do case ",\$cur," in *",\$lbl,"*) : ;; *) [ -z "\$cur" ] && cur="\$lbl" || cur="\$cur,\$lbl";; esac; done; unset IFS
        printf '%s' "\$cur" > "\$STATE/labels/\$n" ;;
      *"/labels")
        name=""; prev=""
        for a in "\$@"; do if [ "\$prev" = "-f" ]; then case "\$a" in name=*) name="\${a#name=}";; esac; fi; prev="\$a"; done
        printf '%s\n' "\$name" >> "\$REC/labels_ensure" ;;
    esac ;;
esac
exit 0
SH
chmod +x "$BIN/gh"

# orchestrate shim for --start-now: record the invocation.
cat > "$BIN/orch-shim" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$REC/orchestrate"
exit 0
SH
chmod +x "$BIN/orch-shim"

# stop-run shim for --stop: record the invocation, exit with STOPRUN_RC (default
# 0 = stopped). This is the delegate run-epic --stop must call for live runs —
# recording it end-to-end proves the teardown is delegated, not reimplemented.
cat > "$BIN/stoprun-shim" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$REC/stoprun"
exit \${STOPRUN_RC:-0}
SH
chmod +x "$BIN/stoprun-shim"

run_epic() { PATH="$BIN:$PATH" RUN_EPIC_ORCHESTRATE="$BIN/orch-shim" RUN_EPIC_STOP_RUN="$BIN/stoprun-shim" bash "$RUN_EPIC" "$@"; }
# grep -c prints the count on stdout and exits 1 on zero matches; the count is
# what we want, so capture stdout and ignore the exit status (a `|| echo 0` would
# append a SECOND "0" and break the numeric compare).
adds_for() { grep -c "^$1:" "$REC/labels_add" 2>/dev/null; true; }
removes_for() { grep -c "^$1:" "$REC/labels_remove" 2>/dev/null; true; }
# first line number in the labels_remove record whose issue is $1 (0 if absent).
remove_line() { grep -n "^$1:" "$REC/labels_remove" 2>/dev/null | head -1 | cut -d: -f1; }
reset_rec() { : > "$REC/labels_add"; : > "$REC/labels_ensure"; : > "$REC/labels_remove"; : > "$REC/orchestrate"; : > "$REC/stoprun"; }

# ===========================================================================
# 1. Happy path — dry-run reports and writes nothing (AC2)
# ===========================================================================
# Epic 100: epic-labelled, open. Children 201 (runnable), 202 (blocked_by 201),
# 203 (blocked_by 202), 204 (closed).
seed_title 100 "Statusnäkymä-epic"; seed_labels 100 "epic,auto-run"; seed_state 100 OPEN
seed_subs 100 '[
  {"number":201,"state":"open","title":"Base","labels":[],"repository_url":"https://api.github.com/repos/silon-oy/demo"},
  {"number":202,"state":"open","title":"Middle","labels":[{"name":"auto-run"}],"repository_url":"https://api.github.com/repos/silon-oy/demo"},
  {"number":203,"state":"open","title":"Top","labels":[],"repository_url":"https://api.github.com/repos/silon-oy/demo"},
  {"number":204,"state":"closed","title":"Done","labels":[],"repository_url":"https://api.github.com/repos/silon-oy/demo"}
]'
touch "$STATE/exists/201" "$STATE/exists/202" "$STATE/exists/203" "$STATE/exists/204"
seed_blockers 202 '[{"number":201,"state":"open"}]'
seed_blockers 203 '[{"number":202,"state":"open"}]'

reset_rec
out=$(run_epic 100 --repo "$REPO" --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && pass "dry-run exits 0" || fail "dry-run exited $rc (out: $out)"
[ ! -s "$REC/labels_add" ] && [ ! -s "$REC/labels_ensure" ] \
  && pass "dry-run wrote nothing (no labels_add/ensure)" \
  || fail "dry-run wrote labels: add=[$(cat "$REC/labels_add")] ensure=[$(cat "$REC/labels_ensure")]"
printf '%s\n' "$out" | grep -q "first to run:  #201" && pass "report: first runnable child is #201" \
  || fail "report: first runnable not #201 (out: $out)"
printf '%s\n' "$out" | grep -q "4 total (3 open, 1 closed)" && pass "report: chain length 4 (3 open, 1 closed)" \
  || fail "report: chain length wrong (out: $out)"
printf '%s\n' "$out" | grep -q "#203 Top — blocked by #202" && pass "report: #203 shown blocked behind #202" \
  || fail "report: blocked-behind missing (out: $out)"
printf '%s\n' "$out" | grep -qi "dry-run" && pass "report: dry-run banner present" \
  || fail "report: no dry-run banner"

# ===========================================================================
# 2. Happy path — apply propagates to open children lacking the labels (AC4)
# ===========================================================================
reset_rec
out=$(run_epic 100 --repo "$REPO" 2>&1); rc=$?
[ "$rc" = 0 ] && pass "apply exits 0" || fail "apply exited $rc (out: $out)"
# 201 & 203 lacked auto-run → labelled; 202 already had it → not re-added; 204 closed → skipped.
[ "$(adds_for 201)" -ge 1 ] && pass "apply: auto-run propagated to bare open child 201" \
  || fail "apply: 201 not labelled"
[ "$(adds_for 203)" -ge 1 ] && pass "apply: auto-run propagated to bare open child 203" \
  || fail "apply: 203 not labelled"
[ "$(adds_for 202)" = 0 ] && pass "apply idempotent: already-labelled child 202 not re-added" \
  || fail "apply: 202 was re-labelled"
[ "$(adds_for 204)" = 0 ] && pass "apply: closed child 204 skipped" || fail "apply: closed 204 labelled"

# ===========================================================================
# 3. Missing epic label → added on apply (docs §5.2 avoin päätös I)
# ===========================================================================
seed_title 110 "Aggregating issue"; seed_labels 110 "enhancement"; seed_state 110 OPEN
seed_subs 110 '[{"number":211,"state":"open","title":"child","labels":[],"repository_url":"https://api.github.com/repos/silon-oy/demo"}]'
touch "$STATE/exists/211"
reset_rec
out=$(run_epic 110 --repo "$REPO" 2>&1); rc=$?
[ "$rc" = 0 ] && pass "apply on non-epic-labelled issue exits 0" || fail "exited $rc (out: $out)"
grep -q "^110:.*epic" "$REC/labels_add" && pass "apply: 'epic' label added to #110 (convert-to-epic)" \
  || fail "apply: epic label not added to 110 (add rec: $(cat "$REC/labels_add"))"
# A FRESH non-epic-labelled issue 111 (so the earlier apply on 110 does not
# taint the mock state) — dry-run must NOT add the label but must report it.
seed_title 111 "Another aggregating issue"; seed_labels 111 "enhancement"; seed_state 111 OPEN
seed_subs 111 '[{"number":221,"state":"open","title":"c","labels":[],"repository_url":"https://api.github.com/repos/silon-oy/demo"}]'
touch "$STATE/exists/221"
reset_rec
out=$(run_epic 111 --repo "$REPO" --dry-run 2>&1)
[ ! -s "$REC/labels_add" ] && pass "dry-run does not add the missing epic label" \
  || fail "dry-run added epic label: $(cat "$REC/labels_add")"
printf '%s\n' "$out" | grep -qi "epic label:    MISSING" && pass "dry-run reports the epic label would be added" \
  || fail "dry-run did not report missing epic label (out: $out)"

# ===========================================================================
# 4. Empty epic → exit 3, no writes
# ===========================================================================
seed_title 120 "Empty epic"; seed_labels 120 "epic,auto-run"; seed_state 120 OPEN
seed_subs 120 '[]'; seed_body 120 "No task-list here"
reset_rec
out=$(run_epic 120 --repo "$REPO" 2>&1); rc=$?
[ "$rc" = 3 ] && pass "empty epic exits 3" || fail "empty epic exited $rc (out: $out)"
[ ! -s "$REC/labels_add" ] && pass "empty epic wrote nothing" || fail "empty epic wrote labels"
printf '%s\n' "$out" | grep -qi "no sub-issues" && pass "empty epic names the reason" \
  || fail "empty epic reason not named (out: $out)"

# ===========================================================================
# 5. Cyclic dependency graph → exit 4, cycle named (AC3)
# ===========================================================================
seed_title 130 "Cyclic epic"; seed_labels 130 "epic,auto-run"; seed_state 130 OPEN
seed_subs 130 '[
  {"number":301,"state":"open","title":"A","labels":[],"repository_url":"https://api.github.com/repos/silon-oy/demo"},
  {"number":302,"state":"open","title":"B","labels":[],"repository_url":"https://api.github.com/repos/silon-oy/demo"}
]'
touch "$STATE/exists/301" "$STATE/exists/302"
seed_blockers 301 '[{"number":302,"state":"open"}]'
seed_blockers 302 '[{"number":301,"state":"open"}]'
reset_rec
out=$(run_epic 130 --repo "$REPO" 2>&1); rc=$?
[ "$rc" = 4 ] && pass "cyclic graph exits 4" || fail "cyclic graph exited $rc (out: $out)"
[ ! -s "$REC/labels_add" ] && pass "cyclic graph wrote nothing (refused before apply)" \
  || fail "cyclic graph wrote labels"
printf '%s\n' "$out" | grep -q "#301" && printf '%s\n' "$out" | grep -q "#302" \
  && pass "cyclic graph names both participants (#301, #302)" \
  || fail "cyclic graph did not name participants (out: $out)"

# ===========================================================================
# 6. Not-open / not-found epic → exit 2
# ===========================================================================
seed_title 140 "Closed epic"; seed_labels 140 "epic"; seed_state 140 CLOSED
reset_rec
out=$(run_epic 140 --repo "$REPO" 2>&1); rc=$?
[ "$rc" = 2 ] && pass "closed epic exits 2" || fail "closed epic exited $rc (out: $out)"
out=$(run_epic 999 --repo "$REPO" 2>&1); rc=$?
[ "$rc" = 2 ] && pass "non-existent epic exits 2" || fail "non-existent epic exited $rc (out: $out)"
[ ! -s "$REC/labels_add" ] && pass "exit-2 paths wrote nothing" || fail "exit-2 path wrote labels"

# ===========================================================================
# 7. Unreadable graph → exit 5 (fail-closed)
# ===========================================================================
# 7a. sub_issues read fails.
seed_title 150 "Unreadable children"; seed_labels 150 "epic,auto-run"; seed_state 150 OPEN
touch "$STATE/subissues_fail/150"
reset_rec
out=$(run_epic 150 --repo "$REPO" 2>&1); rc=$?
[ "$rc" = 5 ] && pass "unreadable sub_issues exits 5 (fail-closed)" || fail "exited $rc (out: $out)"
# 7b. a child's blocked_by read fails.
seed_title 160 "Unreadable blockers"; seed_labels 160 "epic,auto-run"; seed_state 160 OPEN
seed_subs 160 '[{"number":401,"state":"open","title":"c","labels":[],"repository_url":"https://api.github.com/repos/silon-oy/demo"}]'
touch "$STATE/exists/401" "$STATE/blockers_fail/401"
reset_rec
out=$(run_epic 160 --repo "$REPO" 2>&1); rc=$?
[ "$rc" = 5 ] && pass "unreadable blocked_by graph exits 5 (fail-closed)" || fail "exited $rc (out: $out)"
[ ! -s "$REC/labels_add" ] && pass "exit-5 paths wrote nothing" || fail "exit-5 path wrote labels"

# ===========================================================================
# 7c. All sub-issues closed → completion report, no writes (edge case)
# ===========================================================================
seed_title 170 "Finished epic"; seed_labels 170 "epic,auto-run"; seed_state 170 OPEN
seed_subs 170 '[
  {"number":501,"state":"closed","title":"a","labels":[],"repository_url":"https://api.github.com/repos/silon-oy/demo"},
  {"number":502,"state":"closed","title":"b","labels":[],"repository_url":"https://api.github.com/repos/silon-oy/demo"}
]'
touch "$STATE/exists/501" "$STATE/exists/502"
reset_rec
out=$(run_epic 170 --repo "$REPO" 2>&1); rc=$?
[ "$rc" = 0 ] && pass "all-closed epic exits 0" || fail "all-closed epic exited $rc (out: $out)"
[ ! -s "$REC/labels_add" ] && pass "all-closed epic writes nothing (no labelling)" \
  || fail "all-closed epic wrote labels: $(cat "$REC/labels_add")"
printf '%s\n' "$out" | grep -qi "already complete" && pass "all-closed epic reports completion + close suggestion" \
  || fail "all-closed epic did not report completion (out: $out)"

# ===========================================================================
# 8. --start-now launches orchestrate.sh for the first runnable child
# ===========================================================================
reset_rec
out=$(run_epic 100 --repo "$REPO" --start-now 2>&1); rc=$?
[ "$rc" = 0 ] && pass "--start-now exits 0" || fail "--start-now exited $rc (out: $out)"
grep -q "$REPO 201" "$REC/orchestrate" && pass "--start-now invoked orchestrate.sh for first runnable #201" \
  || fail "--start-now did not launch orchestrate for #201 (rec: $(cat "$REC/orchestrate"))"

# ===========================================================================
# 9. AC4 static guard — a single propagation implementation
# ===========================================================================
defs=$(grep -c '^_epic_propagate_child()' "$ROOT/lib/epic.sh")
[ "$defs" = 1 ] && pass "AC4: _epic_propagate_child defined exactly once" \
  || fail "AC4: _epic_propagate_child defined $defs times"
grep -q 'propagate_run_labels' "$RUN_EPIC" \
  && pass "AC4: run-epic.sh delegates propagation to propagate_run_labels" \
  || fail "AC4: run-epic.sh does not use the shared propagate_run_labels"

# ===========================================================================
# 10. --stop mode (issue #90)
# ===========================================================================

# 10a. --stop + --start-now → usage error (exit 1), no guessing which was meant.
out=$(run_epic 100 --repo "$REPO" --stop --start-now 2>&1); rc=$?
[ "$rc" = 1 ] && pass "stop: --stop + --start-now is a usage error (exit 1)" \
  || fail "stop: --stop --start-now exited $rc (out: $out)"

# 10b–c. --stop on a MIXED epic: live + foreign + closed + wip + no-run.
#   601 open auto-run     — LIVE run on this host   → stop + release
#   602 open auto-run     — run on a FOREIGN host   → not stopped, release, partial
#   603 closed            — skipped entirely
#   604 open auto-run,wip — human opt-out           → untouched
#   605 open auto-run     — NO live run             → release only
seed_title 300 "Cancel-me epic"; seed_labels 300 "epic,auto-run"; seed_state 300 OPEN
seed_subs 300 '[
  {"number":601,"state":"open","title":"Live","labels":[{"name":"auto-run"}],"repository_url":"https://api.github.com/repos/silon-oy/demo"},
  {"number":602,"state":"open","title":"Foreign","labels":[{"name":"auto-run"}],"repository_url":"https://api.github.com/repos/silon-oy/demo"},
  {"number":603,"state":"closed","title":"Done","labels":[],"repository_url":"https://api.github.com/repos/silon-oy/demo"},
  {"number":604,"state":"open","title":"Parked","labels":[{"name":"auto-run"},{"name":"wip"}],"repository_url":"https://api.github.com/repos/silon-oy/demo"},
  {"number":605,"state":"open","title":"Queued","labels":[{"name":"auto-run"}],"repository_url":"https://api.github.com/repos/silon-oy/demo"}
]'
touch "$STATE/exists/601" "$STATE/exists/602" "$STATE/exists/603" "$STATE/exists/604" "$STATE/exists/605"
seed_run r601 601 "$THISHOST" initialized
seed_run r602 602 "otherhost-xyz" initialized

# 10b. dry-run writes nothing (AC4) yet classifies every child.
reset_rec
out=$(run_epic 300 --repo "$REPO" --stop --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && pass "stop --dry-run exits 0" || fail "stop dry-run exited $rc (out: $out)"
[ ! -s "$REC/labels_remove" ] && [ ! -s "$REC/stoprun" ] \
  && pass "stop --dry-run wrote nothing (no labels_remove/stoprun)" \
  || fail "stop dry-run wrote: remove=[$(cat "$REC/labels_remove")] stoprun=[$(cat "$REC/stoprun")]"
printf '%s\n' "$out" | grep -q "#601 Live — live run" && pass "stop dry-run: #601 classified live → stop" \
  || fail "stop dry-run: #601 not shown live (out: $out)"
printf '%s\n' "$out" | grep -q "#602 Foreign — run on 'otherhost-xyz' NOT stopped" \
  && pass "stop dry-run: #602 classified foreign host" \
  || fail "stop dry-run: #602 not shown foreign (out: $out)"
printf '%s\n' "$out" | grep -q "#604 Parked — wip" && pass "stop dry-run: #604 shown as wip opt-out" \
  || fail "stop dry-run: #604 not shown wip (out: $out)"

# 10c. apply: order invariant + classifications + partial exit.
reset_rec
out=$(run_epic 300 --repo "$REPO" --stop 2>&1); rc=$?
[ "$rc" = 6 ] && pass "stop apply exits 6 (partial — #602 on a foreign host)" \
  || fail "stop apply exited $rc (out: $out)"
# ordering (AC1/AC6): epic 300's label removed BEFORE any child's.
ep=$(remove_line 300); c1=$(remove_line 601); c5=$(remove_line 605)
if [ -n "$ep" ] && [ -n "$c1" ] && [ -n "$c5" ] && [ "$ep" -lt "$c1" ] && [ "$ep" -lt "$c5" ]; then
  pass "stop apply: epic label removed BEFORE children (order invariant)"
else
  fail "stop apply: epic-before-children order broken (epic@$ep 601@$c1 605@$c5; rec: $(cat "$REC/labels_remove"))"
fi
grep -q "issue 601" "$REC/stoprun" && pass "stop apply: live #601 stopped via stop-run.sh (delegated)" \
  || fail "stop apply: #601 not delegated to stop-run (rec: $(cat "$REC/stoprun"))"
grep -q "issue 602" "$REC/stoprun" && fail "stop apply: #602 foreign run was (wrongly) stopped" \
  || pass "stop apply: foreign #602 NOT stopped (host gate respected)"
if [ "$(removes_for 601)" -ge 1 ] && [ "$(removes_for 602)" -ge 1 ] && [ "$(removes_for 605)" -ge 1 ]; then
  pass "stop apply: auto-run removed from open children 601/602/605"
else
  fail "stop apply: open children not released (rec: $(cat "$REC/labels_remove"))"
fi
[ "$(removes_for 603)" = 0 ] && pass "stop apply: closed child 603 not de-labelled" \
  || fail "stop apply: closed 603 was de-labelled"
[ "$(removes_for 604)" = 0 ] && pass "stop apply: wip child 604 left untouched (no de-label)" \
  || fail "stop apply: wip 604 was de-labelled"
grep -q "issue 604" "$REC/stoprun" && fail "stop apply: wip #604 was stopped" \
  || pass "stop apply: wip #604 not stopped"

# 10d. Clean stop — every child stoppable/no-run/closed → exit 0.
seed_title 310 "Clean stop epic"; seed_labels 310 "epic,auto-run"; seed_state 310 OPEN
seed_subs 310 '[
  {"number":611,"state":"open","title":"Live","labels":[{"name":"auto-run"}],"repository_url":"https://api.github.com/repos/silon-oy/demo"},
  {"number":612,"state":"open","title":"Queued","labels":[{"name":"auto-run"}],"repository_url":"https://api.github.com/repos/silon-oy/demo"},
  {"number":613,"state":"closed","title":"Done","labels":[],"repository_url":"https://api.github.com/repos/silon-oy/demo"}
]'
touch "$STATE/exists/611" "$STATE/exists/612" "$STATE/exists/613"
seed_run r611 611 "$THISHOST" initialized
reset_rec
out=$(run_epic 310 --repo "$REPO" --stop 2>&1); rc=$?
[ "$rc" = 0 ] && pass "stop: clean stop exits 0 (nothing left running)" || fail "clean stop exited $rc (out: $out)"
grep -q "issue 611" "$REC/stoprun" && pass "stop: clean stop delegated live #611 to stop-run" \
  || fail "clean stop: #611 not delegated (rec: $(cat "$REC/stoprun"))"

# 10e. Epic with NO live run — labels removed, no stop-run call, exit 0.
seed_title 320 "Quiet epic"; seed_labels 320 "epic,auto-run"; seed_state 320 OPEN
seed_subs 320 '[
  {"number":621,"state":"open","title":"A","labels":[{"name":"auto-run"}],"repository_url":"https://api.github.com/repos/silon-oy/demo"},
  {"number":622,"state":"open","title":"B","labels":[{"name":"auto-run"}],"repository_url":"https://api.github.com/repos/silon-oy/demo"}
]'
touch "$STATE/exists/621" "$STATE/exists/622"
reset_rec
out=$(run_epic 320 --repo "$REPO" --stop 2>&1); rc=$?
[ "$rc" = 0 ] && pass "stop: no-live-run epic exits 0" || fail "no-live-run stop exited $rc (out: $out)"
[ ! -s "$REC/stoprun" ] && pass "stop: no-live-run epic never calls stop-run.sh" \
  || fail "no-live-run stop called stop-run (rec: $(cat "$REC/stoprun"))"
if [ "$(removes_for 621)" -ge 1 ] && [ "$(removes_for 622)" -ge 1 ] && [ "$(removes_for 320)" -ge 1 ]; then
  pass "stop: no-live-run epic released epic 320 and both children"
else
  fail "stop: no-live-run epic did not release fully (rec: $(cat "$REC/labels_remove"))"
fi

# 10f. Terminal-status run → not stopped without --force, partial exit 6, still released.
seed_title 330 "Terminal-run epic"; seed_labels 330 "epic,auto-run"; seed_state 330 OPEN
seed_subs 330 '[
  {"number":631,"state":"open","title":"Completed","labels":[{"name":"auto-run"}],"repository_url":"https://api.github.com/repos/silon-oy/demo"}
]'
touch "$STATE/exists/631"
seed_run r631 631 "$THISHOST" completed
reset_rec
out=$(run_epic 330 --repo "$REPO" --stop 2>&1); rc=$?
[ "$rc" = 6 ] && pass "stop: terminal-status run → partial exit 6 (not forced)" \
  || fail "terminal-run stop exited $rc (out: $out)"
grep -q "issue 631" "$REC/stoprun" && fail "stop: terminal #631 was force-stopped" \
  || pass "stop: terminal #631 NOT stopped (stop does not --force)"
[ "$(removes_for 631)" -ge 1 ] && pass "stop: terminal #631 still released from pickup" \
  || fail "stop: terminal #631 not released"

# 10g. Static guards — AC2 (shared removal primitive) / AC3 (delegated teardown).
grep -q 'labels_remove' "$RUN_EPIC" \
  && pass "AC2: run-epic.sh removes labels via labels_remove (labels_add's sister, no new impl)" \
  || fail "AC2: run-epic.sh does not use labels_remove"
# Strip comment lines first — the header prose legitimately NAMES the teardown it
# delegates; the guard is about CODE, not documentation.
if grep -vE '^[[:space:]]*#' "$RUN_EPIC" | grep -Eq 'tmux|state_finalize|run_terminate'; then
  fail "AC3: run-epic.sh reimplements teardown (tmux/state_finalize/run_terminate in code)"
else
  pass "AC3: run-epic.sh has no tmux/state_finalize/run_terminate in code (teardown delegated)"
fi
grep -q 'stop-run.sh' "$RUN_EPIC" && pass "AC3: run-epic.sh delegates live-run stop to stop-run.sh" \
  || fail "AC3: run-epic.sh does not reference stop-run.sh"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "run-epic: all passed" || echo "run-epic: FAILURES"
[ "$FAIL" -eq 0 ]
