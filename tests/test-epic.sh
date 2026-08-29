#!/usr/bin/env bash
# test-epic.sh — epic-level auto-run automation (issue #81): lib/issue.sh's
# is_epic / list_epic_children and lib/epic.sh's epic_list_open /
# epic_process_one.
#
# WHAT IS PINNED HERE (the acceptance criteria of #81):
#   - is_epic contract: 1/0 on a good read, fail-closed (rc 2) on an unreadable
#     one — the claim-time gate (orchestrate.sh S2c) is only as safe as this.
#   - list_epic_children: native sub-issues are canonical; the body task-list is
#     a fallback used only when there are zero native children; cross-repo
#     children are excluded.
#   - epic_list_open pins the epic search string (is:open label:epic + run
#     labels), the sibling of test-issue-pick.sh's pickup-search pin.
#   - epic_process_one: propagation adds auto-run to OPEN children that lack it,
#     is IDEMPOTENT (already-labelled / wip / closed children are skipped),
#     escalates a needs-human child to the epic exactly ONCE, and announces
#     completion (summary comment + epic-complete label) exactly ONCE.
#
# `gh` is a STATEFUL mock: labels added and comments posted are written back into
# the fixture state, so a SECOND epic_process_one call on the same epic sees the
# first call's marker/label — that is how the "exactly once" idempotency is
# verified end to end, not just asserted on a single pass.
#
# Run: bash tests/test-epic.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISSUE_LIB="$HERE/../lib/issue.sh"
EPIC_LIB="$HERE/../lib/epic.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed — epic helpers exercise real jq filters"
  exit 0
fi

WORK=$(mktemp -d -t epictest.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
fail() { echo "FAIL: $*"; FAIL=1; }
pass() { echo "PASS: $*"; }

# --- stateful fixture store ------------------------------------------------
STATE="$WORK/state"; mkdir -p "$STATE/labels" "$STATE/body" "$STATE/title" "$STATE/comments" "$STATE/subissues"
REC="$WORK/rec";     mkdir -p "$REC"
: > "$REC/labels_add"      # lines: <number>:<csv>
: > "$REC/labels_add_repo" # lines: <owner/repo>#<number>:<csv> (issue #92)
: > "$REC/labels_ensure"   # lines: <label>
: > "$REC/comment_post"    # lines: <number>
: > "$REC/search"          # lines: the epic_list_open --search string

seed_labels()    { printf '%s' "$2" > "$STATE/labels/$1"; }
seed_body()      { printf '%s' "$2" > "$STATE/body/$1"; }
seed_title()     { printf '%s' "$2" > "$STATE/title/$1"; }
seed_subissues() { printf '%s' "$2" > "$STATE/subissues/$1"; }   # JSON array
seed_open()      { printf '%s' "$1" > "$STATE/open"; }           # JSON [{number}]
# comments/<n>.jsonl: one JSON object per line

# --- gh mock ---------------------------------------------------------------
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
set -u
STATE="$STATE"
REC="$REC"

# Build a full issue object for issue \$1 from the mutable state.
build_obj() {
  local n="\$1"
  local csv=""; [ -f "\$STATE/labels/\$n" ] && csv="\$(cat "\$STATE/labels/\$n")"
  local body=""; [ -f "\$STATE/body/\$n" ] && body="\$(cat "\$STATE/body/\$n")"
  local title=""; [ -f "\$STATE/title/\$n" ] && title="\$(cat "\$STATE/title/\$n")"
  local labels_json comments_json
  labels_json=\$(jq -cn --arg csv "\$csv" '\$csv | split(",") | map(select(length>0) | {name:.})')
  if [ -s "\$STATE/comments/\$n.jsonl" ]; then
    comments_json=\$(jq -s '.' "\$STATE/comments/\$n.jsonl")
  else
    comments_json='[]'
  fi
  jq -n --argjson labels "\$labels_json" --arg body "\$body" --arg title "\$title" \\
        --argjson comments "\$comments_json" \\
        '{title:\$title, body:\$body, labels:\$labels, comments:\$comments, state:"OPEN", author:{login:"tester"}}'
}

sub="\$1"
case "\$sub" in
  repo)
    # repo view --json nameWithOwner --jq .nameWithOwner
    printf 'silon-oy/demo\n' ;;

  issue)
    action="\$2"
    case "\$action" in
      list)
        # issue list --search S --limit N --json number --jq E
        # Two distinct callers land here:
        #   - epic_list_open: has --search "is:open label:epic …" → epic fixture.
        #   - list_epic_children's authoritative open-issue-set fetch (issue #91):
        #     --state open, NO --search → return the seeded open set (\$STATE/open).
        search=""; expr=""; prev=""
        for a in "\$@"; do
          case "\$prev" in --search) search="\$a";; --jq) expr="\$a";; esac
          prev="\$a"
        done
        if [ -n "\$search" ]; then
          printf '%s\n' "\$search" >> "\$REC/search"
          # Fixture: epics 100 and 200 exist and carry the run labels.
          echo '[{"number":100},{"number":200}]' | jq -r "\$expr"
        else
          open="[]"; [ -f "\$STATE/open" ] && open="\$(cat "\$STATE/open")"
          if [ -n "\$expr" ]; then printf '%s' "\$open" | jq -r "\$expr"; else printf '%s\n' "\$open"; fi
        fi ;;
      view)
        n="\$3"; expr=""; prev=""
        for a in "\$@"; do case "\$prev" in --jq) expr="\$a";; esac; prev="\$a"; done
        obj="\$(build_obj "\$n")"
        if [ -n "\$expr" ]; then printf '%s' "\$obj" | jq -r "\$expr"; else printf '%s' "\$obj"; fi ;;
      comment)
        # issue comment N --body-file (-|FILE)
        n="\$3"; file=""; prev=""
        for a in "\$@"; do case "\$prev" in --body-file) file="\$a";; esac; prev="\$a"; done
        body=""
        if [ "\$file" = "-" ] || [ -z "\$file" ]; then body="\$(cat)"; else body="\$(cat "\$file")"; fi
        jq -n --arg b "\$body" '{body:\$b}' >> "\$STATE/comments/\$n.jsonl"
        printf '%s\n' "\$n" >> "\$REC/comment_post" ;;
    esac ;;

  api)
    # Detect graphql, and the REST path (the first repos/… argument). This is
    # robust to --method/--paginate ordering, unlike positional scanning.
    path=""; graphql=0
    for a in "\$@"; do
      case "\$a" in
        graphql)  graphql=1 ;;
        repos/*)  [ -z "\$path" ] && path="\$a" ;;
      esac
    done

    if [ "\$graphql" = 1 ]; then
      # _epic_child_pr_refs: no PRs in fixtures → empty.
      expr=""; prev=""
      for a in "\$@"; do case "\$prev" in --jq) expr="\$a";; esac; prev="\$a"; done
      echo '{"data":{"repository":{"issue":{"closedByPullRequestsReferences":{"nodes":[]}}}}}' | jq -r "\${expr:-.}"
      exit 0
    fi

    case "\$path" in
      *"/issues?"*)
        # epic_list_open (issue #133): REST, not `gh issue list --search`. The
        # `--label` form is what routes gh's issue list through the GraphQL
        # search connection, which was blocked for 27 hours on 2026-08-28/29.
        printf '%s\n' "\$path" >> "\$REC/search"
        expr=""; prev=""
        for a in "\$@"; do case "\$prev" in --jq) expr="\$a";; esac; prev="\$a"; done
        echo '[{"number":100},{"number":200}]' | jq -r "\${expr:-.}"
        exit 0 ;;
      *"/sub_issues")
        n="\${path##*/issues/}"; n="\${n%%/*}"
        if [ -f "\$STATE/subissues/\$n" ]; then cat "\$STATE/subissues/\$n"; else echo '[]'; fi ;;
      *"/issues/"*"/labels")
        # labels_add: -f labels[]=X ...
        n="\${path##*/issues/}"; n="\${n%%/*}"
        # owner/repo segment of the path, so a test can assert a cross-repo child
        # (issue #92) was labelled in its OWN repo, not the epic's.
        orepo="\${path#repos/}"; orepo="\${orepo%%/issues/*}"
        added=""; prev=""
        for a in "\$@"; do
          if [ "\$prev" = "-f" ]; then
            case "\$a" in labels\\[\\]=*) lbl="\${a#labels[]=}"; [ -z "\$added" ] && added="\$lbl" || added="\$added,\$lbl";; esac
          fi
          prev="\$a"
        done
        printf '%s:%s\n' "\$n" "\$added" >> "\$REC/labels_add"
        printf '%s#%s:%s\n' "\$orepo" "\$n" "\$added" >> "\$REC/labels_add_repo"
        # Persist into state so a later read reflects the add (idempotency).
        cur=""; [ -f "\$STATE/labels/\$n" ] && cur="\$(cat "\$STATE/labels/\$n")"
        IFS=','; for lbl in \$added; do
          case ",\$cur," in *",\$lbl,"*) : ;; *) [ -z "\$cur" ] && cur="\$lbl" || cur="\$cur,\$lbl";; esac
        done; unset IFS
        printf '%s' "\$cur" > "\$STATE/labels/\$n" ;;
      *"/labels")
        # labels_ensure: -f name=X (repo-level)
        name=""; prev=""
        for a in "\$@"; do
          if [ "\$prev" = "-f" ]; then case "\$a" in name=*) name="\${a#name=}";; esac; fi
          prev="\$a"
        done
        printf '%s\n' "\$name" >> "\$REC/labels_ensure" ;;
      *) : ;;
    esac ;;
esac
exit 0
SH
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# shellcheck source=../lib/issue.sh
. "$ISSUE_LIB"
# shellcheck source=../lib/epic.sh
. "$EPIC_LIB"

REPO="$WORK"  # any dir; gh is mocked

added_for() { grep -c "^$1:" "$REC/labels_add"; }              # count add calls for issue
added_has() { grep -q "^$1:.*$2" "$REC/labels_add"; }          # add for issue included label
# add for a child in a SPECIFIC repo included label (issue #92 cross-repo target).
added_repo_has() { grep -q "^$1#$2:.*$3" "$REC/labels_add_repo"; }
comments_for() { grep -c "^$1\$" "$REC/comment_post"; }        # count comments posted to issue

# ===========================================================================
# 1. is_epic contract (the claim-gate's authoritative read)
# ===========================================================================
seed_labels 300 "epic,auto-run"
seed_labels 301 "auto-run,bug"
set +e
o=$(is_epic "$REPO" 300); r=$?; set -e
{ [ "$r" = 0 ] && [ "$o" = 1 ]; } && pass "is_epic: epic-labelled issue → 1" \
  || fail "is_epic: expected 1/rc0 for epic, got [$o]/rc$r"
set +e
o=$(is_epic "$REPO" 301); r=$?; set -e
{ [ "$r" = 0 ] && [ "$o" = 0 ]; } && pass "is_epic: non-epic issue → 0" \
  || fail "is_epic: expected 0/rc0 for non-epic, got [$o]/rc$r"
# Unreadable → fail-closed (rc 2). Point gh at a missing binary path element by
# asking for an issue the mock errors on: simulate by removing the labels file
# and making build_obj fail is hard; instead call with a bogus repo that makes
# `cd` fail is also awkward — use a dedicated unreadable shim.
set +e
o=$(PATH="/nonexistent" is_epic "$REPO" 300 2>/dev/null); r=$?; set -e
{ [ "$r" = 2 ] && [ -z "$o" ]; } && pass "is_epic: unreadable labels → rc 2, empty (fail-closed)" \
  || fail "is_epic: expected rc2/empty when gh absent, got [$o]/rc$r"

# ===========================================================================
# 2. list_epic_children — native canonical + cross-repo INCLUSION (issue #92)
# TSV is now <number>\t<state>\t<labels-csv>\t<owner/repo>\t<title>: a cross-repo
# child is KEPT with its own owner/repo rather than dropped.
# ===========================================================================
seed_subissues 400 '[
  {"number":401,"state":"open","title":"A","labels":[{"name":"auto-run"}],"repository_url":"https://api.github.com/repos/silon-oy/demo"},
  {"number":402,"state":"closed","title":"B","labels":[],"repository_url":"https://api.github.com/repos/silon-oy/demo"},
  {"number":403,"state":"open","title":"X","labels":[],"repository_url":"https://api.github.com/repos/other/repo"}
]'
out=$(list_epic_children "$REPO" 400 "silon-oy/demo")
echo "$out" | grep -q "^401	open	auto-run	silon-oy/demo	A$" || fail "list_epic_children native: missing 401 line (got: $out)"
echo "$out" | grep -q "^402	closed		silon-oy/demo	B$"       || fail "list_epic_children native: missing 402 line"
echo "$out" | grep -q "^403	open		other/repo	X$"           || fail "list_epic_children native: cross-repo 403 missing its own repo"
n=$(printf '%s\n' "$out" | grep -c '^[0-9]')
[ "$n" = 3 ] && pass "list_epic_children native: cross-repo child included with its own repo (issue #92)" \
  || fail "list_epic_children native: expected 3 children (incl cross-repo), got $n"

# Fallback: zero native → parse task-list from the body. State is resolved
# AUTHORITATIVELY against the open-issue set, NEVER the checkbox (issue #91, AC3).
# The checkboxes below are DELIBERATELY WRONG to prove the open set decides:
#   #501 box [x] but IS open  → open     (open set overrides a checked box)
#   #502 box [ ] but NOT open → SKIPPED  (a [ ] mark on a non-open issue is not
#                                         "open" — the old bug this fixes)
#   #503 box [x] and NOT open → closed   (genuinely done; absent from open list)
#   owner/repo#999 box [ ]    → cross-repo, resolved against that repo's open set;
#                               the mock's open set lacks 999 → skipped (not open)
seed_subissues 410 '[]'
seed_body 410 $'- [x] First #501\n- [ ] Second #502\n- [x] Third #503\n- [ ] Cross owner/repo#999\nplain line'
seed_open '[{"number":501}]'   # only 501 is open (all repos in the mock share this)
out=$(list_epic_children "$REPO" 410 "silon-oy/demo")
echo "$out" | grep -q "^501	open		silon-oy/demo	First$"  || fail "list_epic_children fallback: 501 must be open (map wins over [x]) (got: $out)"
echo "$out" | grep -q "^502"                       && fail "list_epic_children fallback: 502 ([ ] + not open) must be skipped, not reported"
echo "$out" | grep -q "^503	closed		silon-oy/demo	Third$" || fail "list_epic_children fallback: 503 ([x] + not open) must be closed"
echo "$out" | grep -q "999"                        && fail "list_epic_children fallback: cross-repo 999 ([ ] + not open) must be skipped"
n=$(printf '%s\n' "$out" | grep -c '^[0-9]')
[ "$n" = 2 ] && pass "list_epic_children fallback: state authoritative, same-repo carries its repo, cross-repo not-open skipped" \
  || fail "list_epic_children fallback: expected 2 children (501 open, 503 closed), got $n"

# Fallback cross-repo INCLUSION: an owner/repo#N that IS open in its repo is kept
# with that repo (issue #92). The mock's shared open set now contains 777, so the
# cross-repo ref resolves to open and is emitted with other/repo.
seed_subissues 411 '[]'
seed_body 411 $'- [ ] Cross open other/repo#777\n- [ ] Local open #501'
seed_open '[{"number":501},{"number":777}]'
out=$(list_epic_children "$REPO" 411 "silon-oy/demo")
echo "$out" | grep -q "^777	open		other/repo	Cross open$" \
  && pass "list_epic_children fallback: cross-repo open child kept with its own repo (issue #92)" \
  || fail "list_epic_children fallback: cross-repo 777 not emitted with other/repo (got: $out)"
seed_open '[{"number":501}]'   # restore the default open set for later sections

# Fail-closed on the run side: an unreadable native graph → rc 2, no fallback,
# no output (AC4). Simulate with gh absent from PATH.
set +e
o=$(PATH="/nonexistent" list_epic_children "$REPO" 400 "silon-oy/demo" 2>/dev/null); r=$?
set -e
{ [ "$r" = 2 ] && [ -z "$o" ]; } && pass "list_epic_children: unreadable native graph → rc 2, empty (fail-closed)" \
  || fail "list_epic_children: expected rc2/empty when gh absent, got [$o]/rc$r"

# ===========================================================================
# 3. epic_list_open — pins the REST query (issue #133)
# ===========================================================================
# The epic list used to be `gh issue list --search "is:open label:epic …"`. A
# `--label`-filtered issue list routes through GitHub's GraphQL search
# connection, which was blocked for 27 hours on 2026-08-28/29 while REST
# answered normally, so the query moved to REST. The terms pinned here are the
# faithful translation: REST ANDs the labels= list exactly like the separate
# label:"x" search terms did (measured: labels=auto-run,epic → 0 while
# labels=auto-run → 5).
epics=$(epic_list_open "$REPO" "auto-run")
printf '%s' "$epics" | grep -q '^100$' || fail "epic_list_open: expected epic 100 in output (got: $epics)"
s=$(tail -n1 "$REC/search")
case "$s" in
  repos/*/issues\?*) : ;;
  *) fail "epic_list_open is not on the REST issues endpoint: $s" ;;
esac
for term in 'labels=epic' 'auto-run' 'state=open'; do
  case "$s" in *"$term"*) : ;; *) fail "epic_list_open query missing '$term': $s" ;; esac
done
case "$s" in *'--search'*|*'is:open'*) fail "epic_list_open drifted back to a search query: $s" ;; esac
[ "$FAIL" = 0 ] && pass "epic_list_open: REST query carries labels=epic,auto-run + state=open" || true

# ===========================================================================
# 4. epic_process_one — propagation + idempotency + escalation
# ===========================================================================
seed_title 100 "Demo epic"
seed_labels 100 "epic,auto-run"
: > "$STATE/comments/100.jsonl"
seed_subissues 100 '[
  {"number":101,"state":"open","title":"needs label","labels":[],"repository_url":"https://api.github.com/repos/silon-oy/demo"},
  {"number":102,"state":"open","title":"already","labels":[{"name":"auto-run"}],"repository_url":"https://api.github.com/repos/silon-oy/demo"},
  {"number":103,"state":"closed","title":"done","labels":[],"repository_url":"https://api.github.com/repos/silon-oy/demo"},
  {"number":104,"state":"open","title":"parked","labels":[{"name":"wip"}],"repository_url":"https://api.github.com/repos/silon-oy/demo"},
  {"number":105,"state":"open","title":"stuck","labels":[{"name":"needs-human"}],"repository_url":"https://api.github.com/repos/silon-oy/demo"},
  {"number":106,"state":"open","title":"cross needs label","labels":[],"repository_url":"https://api.github.com/repos/other/repo"},
  {"number":107,"state":"open","title":"cross stuck","labels":[{"name":"needs-human"}],"repository_url":"https://api.github.com/repos/other/repo"}
]'

epic_process_one "$REPO" 100 "auto-run" "silon-oy/demo" origin

# 101 (open, no label) → auto-run added
added_has 101 "auto-run" && pass "propagate: auto-run added to bare open child 101" \
  || fail "propagate: 101 did not receive auto-run"
# 105 (open, needs-human, no auto-run) → auto-run added too
added_has 105 "auto-run" || fail "propagate: 105 did not receive auto-run"
# 102 (already auto-run) → NO add
[ "$(added_for 102)" = 0 ] && pass "idempotent: already-labelled child 102 not re-added" \
  || fail "idempotent: 102 was re-labelled ($(added_for 102) times)"
# 103 (closed) → NO add
[ "$(added_for 103)" = 0 ] && pass "closed child 103 skipped" \
  || fail "closed child 103 was labelled"
# 104 (wip) → NO add
[ "$(added_for 104)" = 0 ] && pass "wip child 104 skipped (opt-out)" \
  || fail "wip child 104 was labelled"

# Escalation: 105 + 107 have needs-human → two comments on the epic + epic-attention label
[ "$(comments_for 100)" = 2 ] && pass "escalation: stalled children 105 + 107 escalated to epic (2 comments)" \
  || fail "escalation: expected 2 epic comments, got $(comments_for 100)"
grep -q '^epic-attention$' "$REC/labels_ensure" && pass "escalation: epic-attention label ensured" \
  || fail "escalation: epic-attention label not ensured"
# The posted comment must carry the per-child marker.
grep -q 'epic-attention child=105' "$STATE/comments/100.jsonl" \
  && pass "escalation: comment carries per-child marker" \
  || fail "escalation: per-child marker missing from comment"

# --- cross-repo child propagation + escalation (issue #92) ---
# 106 (open, no label, in other/repo) → auto-run added IN other/repo, not the epic's.
added_repo_has "other/repo" 106 "auto-run" \
  && pass "cross-repo: 106 labelled in its OWN repo (other/repo), not the epic's" \
  || fail "cross-repo: 106 not labelled in other/repo (rec: $(cat "$REC/labels_add_repo"))"
# 101 (same-repo) still labelled in the epic's repo.
added_repo_has "silon-oy/demo" 101 "auto-run" \
  && pass "same-repo: 101 labelled in the epic's repo (silon-oy/demo)" \
  || fail "same-repo: 101 not labelled in silon-oy/demo"
# 107 (needs-human, cross-repo) → escalation comment carries a REPO-QUALIFIED marker.
grep -q 'epic-attention child=other/repo#107' "$STATE/comments/100.jsonl" \
  && pass "cross-repo escalation: marker is repo-qualified (child=other/repo#107)" \
  || fail "cross-repo escalation: repo-qualified marker missing"
# and the comment body names the child as owner/repo#N.
grep -q 'other/repo#107' "$STATE/comments/100.jsonl" \
  && pass "cross-repo escalation: comment names child as other/repo#107" \
  || fail "cross-repo escalation: owner/repo#N reference missing from comment"

# Second tick: idempotent — no new escalation comment for 105 or 107.
epic_process_one "$REPO" 100 "auto-run" "silon-oy/demo" origin
[ "$(comments_for 100)" = 2 ] && pass "escalation idempotent: no repeat comment on 2nd tick (105 + 107 = 2)" \
  || fail "escalation idempotent: comment count is $(comments_for 100) (expected 2)"

# ===========================================================================
# 5. epic_process_one — completion announced exactly once
# ===========================================================================
seed_title 200 "Done epic"
seed_labels 200 "epic,auto-run"
: > "$STATE/comments/200.jsonl"
seed_subissues 200 '[
  {"number":201,"state":"closed","title":"one","labels":[],"repository_url":"https://api.github.com/repos/silon-oy/demo"},
  {"number":202,"state":"closed","title":"two","labels":[],"repository_url":"https://api.github.com/repos/silon-oy/demo"}
]'

epic_process_one "$REPO" 200 "auto-run" "" origin
[ "$(comments_for 200)" = 1 ] && pass "completion: summary comment posted once" \
  || fail "completion: expected 1 summary comment, got $(comments_for 200)"
grep -q '^epic-complete$' "$REC/labels_ensure" && pass "completion: epic-complete label ensured" \
  || fail "completion: epic-complete label not ensured"
grep -q "^200:.*epic-complete" "$REC/labels_add" && pass "completion: epic-complete label added to epic" \
  || fail "completion: epic-complete not added to epic 200"
# Summary lists both children.
grep -q '#201' "$STATE/comments/200.jsonl" && grep -q '#202' "$STATE/comments/200.jsonl" \
  && pass "completion: summary lists sub-issues #201 and #202" \
  || fail "completion: summary does not list both children"

# Second tick: epic-complete now on the epic → no repeat.
epic_process_one "$REPO" 200 "auto-run" "" origin
[ "$(comments_for 200)" = 1 ] && pass "completion idempotent: no repeat on 2nd tick" \
  || fail "completion idempotent: comment count rose to $(comments_for 200)"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "epic: all passed" || echo "epic: FAILURES"
[ "$FAIL" -eq 0 ]
