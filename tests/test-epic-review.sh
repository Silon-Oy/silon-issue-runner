#!/usr/bin/env bash
# test-epic-review.sh — lib/epic-review.sh's epic_review_collect (issue #272).
#
# WHAT IS PINNED HERE:
#   - a successful collection carries every section: criteria, children with
#     state, PR references and the combined change surface;
#   - an epic body without a criteria heading says so out loud (no invention);
#   - FAIL-CLOSED: an unreadable child set, child PR references or PR file list
#     => rc != 0 AND empty stdout (never partial material);
#   - the size cap: output stays within RUN_ISSUES_EPIC_REVIEW_MAX and the cut is
#     visible in the material itself;
#   - the module is self-sufficient (sources alone in a clean shell);
#   - _epic_child_pr_refs's new error code does not leak into epic_process_one's
#     best-effort completion summary.
#
# Run: bash tests/test-epic-review.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW_LIB="$HERE/../lib/epic-review.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed — epic helpers exercise real jq filters"
  exit 0
fi

WORK=$(mktemp -d -t epicreviewtest.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"

FAIL=0
fail() { echo "FAIL: $*"; FAIL=1; }
pass() { echo "PASS: $*"; }

# --- fixture store ---------------------------------------------------------
# body/<n>, title/<n>     the issue
# subissues/<n>           JSON array for the sub_issues API
# prs/<n>                 JSON array of PR numbers closing child <n>
# files/<pr>              newline-separated filenames for PR <pr>
# fail/<kind>             presence => that read fails (sub_issues|graphql|files)
STATE="$WORK/state"
mkdir -p "$STATE/body" "$STATE/title" "$STATE/subissues" "$STATE/prs" "$STATE/files" "$STATE/fail"

BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
set -u
STATE="$STATE"
expr=""; prev=""
for a in "\$@"; do case "\$prev" in --jq) expr="\$a";; esac; prev="\$a"; done
case "\$1" in
  repo) printf 'silon-oy/demo\n' ;;
  issue)
    case "\$2" in
      view)
        n="\$3"
        jq -n --arg t "\$(cat "\$STATE/title/\$n" 2>/dev/null)" --arg b "\$(cat "\$STATE/body/\$n" 2>/dev/null)" \\
          '{title:\$t, body:\$b, labels:[], comments:[], state:"OPEN", author:{login:"tester"}}' ;;
      list) echo '[]' ;;
    esac ;;
  api)
    path=""; graphql=0; child=""
    for a in "\$@"; do
      case "\$a" in
        graphql) graphql=1 ;;
        n=*) child="\${a#n=}" ;;
        repos/*) [ -z "\$path" ] && path="\$a" ;;
      esac
    done
    if [ "\$graphql" = 1 ]; then
      [ -e "\$STATE/fail/graphql" ] && { echo "graphql boom" >&2; exit 1; }
      prs='[]'; [ -f "\$STATE/prs/\$child" ] && prs="\$(cat "\$STATE/prs/\$child")"
      jq -n --argjson p "\$prs" '{data:{repository:{issue:{closedByPullRequestsReferences:{nodes:(\$p|map({number:.}))}}}}}' \\
        | jq -r "\${expr:-.}"
      exit 0
    fi
    case "\$path" in
      *"/sub_issues")
        [ -e "\$STATE/fail/sub_issues" ] && { echo "sub_issues boom" >&2; exit 1; }
        n="\${path##*/issues/}"; n="\${n%%/*}"
        if [ -f "\$STATE/subissues/\$n" ]; then cat "\$STATE/subissues/\$n"; else echo '[]'; fi ;;
      *"/pulls/"*"/files")
        [ -e "\$STATE/fail/files" ] && { echo "files boom" >&2; exit 1; }
        pr="\${path##*/pulls/}"; pr="\${pr%%/*}"
        [ -f "\$STATE/files/\$pr" ] || exit 0
        jq -R . "\$STATE/files/\$pr" | jq -s 'map({filename:.})' | jq -r "\${expr:-.}" ;;
      *) : ;;
    esac ;;
esac
exit 0
SH
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

REPO="$WORK/repo"; mkdir -p "$REPO"

child() { # child <n> <state> <title>
  printf '{"number":%s,"state":"%s","title":"%s","labels":[],"repository_url":"https://api.github.com/repos/silon-oy/demo"}' "$1" "$2" "$3"
}

seed_epic() {
  printf '%s' "Epic title" > "$STATE/title/100"
  printf '%s' "$1" > "$STATE/body/100"
  printf '[%s,%s]' "$(child 101 closed 'First child')" "$(child 102 open 'Second child')" > "$STATE/subissues/100"
  echo '[11,12]' > "$STATE/prs/101"
  echo '[]'      > "$STATE/prs/102"
  printf 'lib/a.sh\nlib/shared.sh\n'       > "$STATE/files/11"
  printf 'docs/b.md\nlib/shared.sh\n'      > "$STATE/files/12"
}

BODY_WITH='## Tavoite

Do the thing.

## Hyväksyntäkriteerit

- [ ] criterion one
- [ ] criterion two

```
## not a heading inside a fence
```

## Rajaukset

- out of scope line'

BODY_WITHOUT='## Tavoite

Do the thing without a criteria heading.'

collect() { # collect [env...] — run in a fresh shell so set -e cannot leak
  env "$@" bash -c '. "$1" && epic_review_collect "$2" 100 silon-oy/demo' _ "$REVIEW_LIB" "$REPO"
}

# --- (a) successful collection -----------------------------------------------
seed_epic "$BODY_WITH"
out=$(collect); rc=$?
[ "$rc" -eq 0 ] && pass "a: rc 0" || fail "a: rc=$rc"
for want in '## Epic #100: Epic title' '### Hyväksyntäkriteerit' '- [ ] criterion one' \
            '- [ ] criterion two' '## not a heading inside a fence' \
            '- #101 (closed) — First child — PR: #11 #12' \
            '- #102 (open) — Second child — PR: ei PR-viitteitä' \
            '### Muutospinta' '- `lib/a.sh` (#101)' '- `docs/b.md` (#101)' '- `lib/shared.sh` (#101)'; do
  printf '%s\n' "$out" | grep -qF -- "$want" && pass "a: contains '$want'" || fail "a: missing '$want'"
done
printf '%s\n' "$out" | grep -qF 'out of scope line' && fail "a: criteria leaked past next heading" || pass "a: criteria stop at next heading"
[ "$(printf '%s\n' "$out" | grep -c 'lib/shared.sh')" -eq 1 ] && pass "a: surface deduplicated" || fail "a: lib/shared.sh not deduplicated"
printf '%s\n' "$out" | grep -qF 'katkaistu' && fail "a: unexpected truncation notice" || pass "a: no truncation under default cap"

# --- (b) missing criteria section --------------------------------------------
seed_epic "$BODY_WITHOUT"
out=$(collect); rc=$?
[ "$rc" -eq 0 ] && pass "b: rc 0" || fail "b: rc=$rc"
printf '%s\n' "$out" | grep -qF 'Epicin rungossa ei ole hyväksyntäkriteerejä' \
  && pass "b: missing criteria said out loud" || fail "b: no explicit missing-criteria line"
crit=$(printf '%s\n' "$out" | awk '/^### Hyväksyntäkriteerit/{f=1;next} /^### /{f=0} f')
printf '%s\n' "$crit" | grep -q '^- ' && fail "b: criteria section has list lines" || pass "b: no invented criteria"

# --- (c) fail-closed variants ------------------------------------------------
seed_epic "$BODY_WITH"
for kind in sub_issues graphql files; do
  : > "$STATE/fail/$kind"
  out=$(collect 2>/dev/null); rc=$?
  rm -f "$STATE/fail/$kind"
  [ "$rc" -ne 0 ] && pass "c/$kind: rc != 0 ($rc)" || fail "c/$kind: rc 0 on unreadable read"
  [ -z "$out" ] && pass "c/$kind: empty stdout" || fail "c/$kind: partial output: $out"
done

# --- (d) size cap --------------------------------------------------------------
seed_epic "$BODY_WITH"
for i in $(seq 1 200); do printf 'src/generated/file-%03d.ts\n' "$i"; done > "$STATE/files/11"
full=$(collect)
full_bytes=$(printf '%s\n' "$full" | LC_ALL=C wc -c | tr -d ' ')
cap=2000
[ "$full_bytes" -gt "$cap" ] && pass "d: fixture exceeds cap ($full_bytes > $cap)" || fail "d: fixture too small ($full_bytes)"
out=$(collect RUN_ISSUES_EPIC_REVIEW_MAX=$cap); rc=$?
bytes=$(printf '%s\n' "$out" | LC_ALL=C wc -c | tr -d ' ')
[ "$rc" -eq 0 ] && pass "d: rc 0" || fail "d: rc=$rc"
[ "$bytes" -le "$cap" ] && pass "d: output within cap ($bytes <= $cap)" || fail "d: output $bytes > $cap"
printf '%s\n' "$out" | grep -qF 'RUN_ISSUES_EPIC_REVIEW_MAX=2000' && pass "d: truncation visible" || fail "d: no truncation notice"
printf '%s\n' "$out" | grep -qE 'näytetään [0-9]+/202 tiedostoa' && pass "d: notice counts files" || fail "d: notice lacks counts"
printf '%s\n' "$out" | grep -qF -- '- [ ] criterion one' && pass "d: criteria survive the cut" || fail "d: criteria lost"
printf '%s\n' "$out" | grep -qF -- '- #102 (open)' && pass "d: children survive the cut" || fail "d: children lost"

# Cap smaller than criteria + children: head is cut too, still visible.
out=$(collect RUN_ISSUES_EPIC_REVIEW_MAX=300); rc=$?
bytes=$(printf '%s\n' "$out" | LC_ALL=C wc -c | tr -d ' ')
[ "$rc" -eq 0 ] && pass "d2: rc 0" || fail "d2: rc=$rc"
[ "$bytes" -le 300 ] && pass "d2: output within cap ($bytes <= 300)" || fail "d2: output $bytes > 300"
printf '%s\n' "$out" | grep -qF 'RUN_ISSUES_EPIC_REVIEW_MAX=300' && pass "d2: truncation visible" || fail "d2: no truncation notice"

# --- self-sufficient module ----------------------------------------------------
if env -i HOME="$HOME" PATH="$PATH" bash -c '. "$1" && declare -F epic_review_collect list_epic_children _epic_child_pr_refs >/dev/null' _ "$REVIEW_LIB"; then
  pass "module sources alone"
else
  fail "module does not source alone"
fi

# --- _epic_child_pr_refs: distinguishable error, best-effort caller -------------
seed_epic "$BODY_WITH"
bash -c '. "$1" && _epic_child_pr_refs "$2" 102 silon-oy/demo' _ "$REVIEW_LIB" "$REPO" >/dev/null 2>&1 \
  && pass "pr_refs: rc 0 on 'no PRs'" || fail "pr_refs: nonzero on a good empty read"
: > "$STATE/fail/graphql"
bash -c '. "$1" && _epic_child_pr_refs "$2" 102 silon-oy/demo' _ "$REVIEW_LIB" "$REPO" >/dev/null 2>&1 \
  && fail "pr_refs: rc 0 on failed read" || pass "pr_refs: rc != 0 on failed read"
# All children closed => epic_process_one announces completion; the failing PR
# read must degrade to "no PR", not abort.
printf '[%s]' "$(child 101 closed 'First child')" > "$STATE/subissues/100"
bash -c '. "$1" && epic_process_one "$2" 100 auto-run silon-oy/demo' _ "$REVIEW_LIB" "$REPO" >/dev/null 2>&1 \
  && pass "epic_process_one survives a failing PR read" || fail "epic_process_one aborted on a failing PR read"
rm -f "$STATE/fail/graphql"

if [ "$FAIL" -eq 0 ]; then echo "ALL PASS"; else exit 1; fi
