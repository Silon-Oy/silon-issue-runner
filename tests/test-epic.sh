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
: > "$REC/labels_ensure"   # lines: <label>
: > "$REC/comment_post"    # lines: <number>
: > "$REC/search"          # lines: the epic_list_open --search string

seed_labels()    { printf '%s' "$2" > "$STATE/labels/$1"; }
seed_body()      { printf '%s' "$2" > "$STATE/body/$1"; }
seed_title()     { printf '%s' "$2" > "$STATE/title/$1"; }
seed_subissues() { printf '%s' "$2" > "$STATE/subissues/$1"; }   # JSON array
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
        search=""; expr=""; prev=""
        for a in "\$@"; do
          case "\$prev" in --search) search="\$a";; --jq) expr="\$a";; esac
          prev="\$a"
        done
        printf '%s\n' "\$search" >> "\$REC/search"
        # Fixture: epics 100 and 200 exist and carry the run labels.
        echo '[{"number":100},{"number":200}]' | jq -r "\$expr" ;;
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
      *"/sub_issues")
        n="\${path##*/issues/}"; n="\${n%%/*}"
        if [ -f "\$STATE/subissues/\$n" ]; then cat "\$STATE/subissues/\$n"; else echo '[]'; fi ;;
      *"/issues/"*"/labels")
        # labels_add: -f labels[]=X ...
        n="\${path##*/issues/}"; n="\${n%%/*}"
        added=""; prev=""
        for a in "\$@"; do
          if [ "\$prev" = "-f" ]; then
            case "\$a" in labels\\[\\]=*) lbl="\${a#labels[]=}"; [ -z "\$added" ] && added="\$lbl" || added="\$added,\$lbl";; esac
          fi
          prev="\$a"
        done
        printf '%s:%s\n' "\$n" "\$added" >> "\$REC/labels_add"
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
# 2. list_epic_children — native canonical + cross-repo exclusion
# ===========================================================================
seed_subissues 400 '[
  {"number":401,"state":"open","title":"A","labels":[{"name":"auto-run"}],"repository_url":"https://api.github.com/repos/silon-oy/demo"},
  {"number":402,"state":"closed","title":"B","labels":[],"repository_url":"https://api.github.com/repos/silon-oy/demo"},
  {"number":403,"state":"open","title":"X","labels":[],"repository_url":"https://api.github.com/repos/other/repo"}
]'
out=$(list_epic_children "$REPO" 400 "silon-oy/demo")
echo "$out" | grep -q "^401	open	auto-run	A$" || fail "list_epic_children native: missing 401 line (got: $out)"
echo "$out" | grep -q "^402	closed		B$"       || fail "list_epic_children native: missing 402 line"
echo "$out" | grep -q "^403"                       && fail "list_epic_children native: cross-repo 403 NOT excluded"
n=$(printf '%s\n' "$out" | grep -c '^[0-9]')
[ "$n" = 2 ] && pass "list_epic_children native: 2 same-repo children, cross-repo excluded" \
  || fail "list_epic_children native: expected 2 children, got $n"

# Fallback: zero native → parse task-list from the body.
seed_subissues 410 '[]'
seed_body 410 $'- [ ] First #501\n- [x] Second #502\n- [ ] Cross owner/repo#503\nplain line'
out=$(list_epic_children "$REPO" 410)
echo "$out" | grep -q "^501	open		First$"   || fail "list_epic_children fallback: missing open 501 (got: $out)"
echo "$out" | grep -q "^502	closed		Second$" || fail "list_epic_children fallback: missing closed 502"
echo "$out" | grep -q "503"                        && fail "list_epic_children fallback: cross-repo 503 NOT excluded"
n=$(printf '%s\n' "$out" | grep -c '^[0-9]')
[ "$n" = 2 ] && pass "list_epic_children fallback: parses checkboxes, excludes cross-repo" \
  || fail "list_epic_children fallback: expected 2 children, got $n"

# ===========================================================================
# 3. epic_list_open — pins the epic search string
# ===========================================================================
epics=$(epic_list_open "$REPO" "auto-run")
printf '%s' "$epics" | grep -q '^100$' || fail "epic_list_open: expected epic 100 in output (got: $epics)"
s=$(tail -n1 "$REC/search")
for term in 'is:open' 'label:epic' 'label:"auto-run"'; do
  case "$s" in *"$term"*) : ;; *) fail "epic_list_open search missing '$term': $s" ;; esac
done
[ "$FAIL" = 0 ] && pass "epic_list_open: search carries is:open label:epic label:\"auto-run\"" || true

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
  {"number":105,"state":"open","title":"stuck","labels":[{"name":"needs-human"}],"repository_url":"https://api.github.com/repos/silon-oy/demo"}
]'

epic_process_one "$REPO" 100 "auto-run" "" origin

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

# Escalation: 105 has needs-human → one comment on the epic + epic-attention label
[ "$(comments_for 100)" = 1 ] && pass "escalation: stalled child 105 escalated to epic (1 comment)" \
  || fail "escalation: expected 1 epic comment, got $(comments_for 100)"
grep -q '^epic-attention$' "$REC/labels_ensure" && pass "escalation: epic-attention label ensured" \
  || fail "escalation: epic-attention label not ensured"
# The posted comment must carry the per-child marker.
grep -q 'epic-attention child=105' "$STATE/comments/100.jsonl" \
  && pass "escalation: comment carries per-child marker" \
  || fail "escalation: per-child marker missing from comment"

# Second tick: idempotent — no new escalation comment for 105.
epic_process_one "$REPO" 100 "auto-run" "" origin
[ "$(comments_for 100)" = 1 ] && pass "escalation idempotent: no repeat comment on 2nd tick" \
  || fail "escalation idempotent: comment count rose to $(comments_for 100)"

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
