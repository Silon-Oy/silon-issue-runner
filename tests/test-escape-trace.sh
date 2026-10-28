#!/usr/bin/env bash
# test-escape-trace.sh — escape-trace.sh and lib/escape-trace.sh (issue #389).
# gh is a PATH shim that records every call and serves issues, commit → PR
# associations and PRs from fixtures; the repo is a local fixture whose origin
# is a github.com URL that is never fetched.
#
#   A) pure parsers: locations, audited SHA, subject references, branch issue,
#      the class decision
#   B) one trace over a fixture covering every class: an inherited commit, a
#      runner commit (pr-api), a squash-merged `Auto:` commit (auto-prefix), a
#      rebase-merged `(#N)` commit (msg-ref) and a human one, a deleted file and
#      a line that is no longer there; summary counts, shares and the blame
#      limitation line
#   C) read-only: only GET `gh api` calls, no search, the work tree unchanged
#   D) cost: one commits/<sha>/pulls call per UNIQUE commit, pulls/<N> only for
#      the msg-ref fallback
#   E) the blamed commit: default branch tip, the body's audited SHA, --at
#   F) --label: one paginated REST listing, PRs dropped
#   G) a rate-limit refusal stops further calls; usage and setup exit codes
#   H) --json: the same rows, summary and gh calls as the table
#
# Run: bash tests/test-escape-trace.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TRACE="$ROOT/escape-trace.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available"
  exit 0
fi

FAIL=0
bad() { echo "FAIL $1: $2"; FAIL=1; }
ok()  { echo "PASS $1: $2"; }
expect() { if [ "$3" = "$4" ]; then ok "$1" "$2"; else bad "$1" "$2 — expected [$4], got [$3]"; fi; }

# ---- A) pure parsers ------------------------------------------------------------
# shellcheck source=../lib/escape-trace.sh
. "$ROOT/lib/escape-trace.sh"
TAB=$(printf '\t')

body='Löydös `lib/a.sh:12` ja ./b/c.php:3-5, myös d.js:L7.
Toisto lib/a.sh:12. Kello 12:30 ei ole viittaus, eikä https://github.com/o/r/blob/main/x.sh:9.'
expect A refs "$(escape_trace_refs "$body" | tr '\t\n' ':,')" "lib/a.sh:12,b/c.php:3,d.js:7,"
expect A "refs of an empty body" "$(escape_trace_refs '')" ""
expect A "audited sha" "$(escape_trace_audited_sha 'x
Auditoitu commit: `abc1234def` (`origin/main`).')" "abc1234def"
expect A "no audited sha" "$(escape_trace_audited_sha 'no such line abc1234')" ""
expect A "Auto: squash subject" "$(escape_trace_msg_link 'Auto: do it (#7) (#12)')" "auto-prefix 7 12"
expect A "Auto: without PR ref" "$(escape_trace_msg_link 'Auto: do it (#7)')" "auto-prefix 7 -"
expect A "plain (#N)" "$(escape_trace_msg_link 'fix: x (#3) (#12)')" "msg-ref 12"
expect A "no reference" "$(escape_trace_msg_link 'fix: x')" ""
expect A "branch issue" "$(escape_trace_issue_from_branch 'auto-run/20261028-silon-oy-claude-issue-runner-issue-389-slug-issue-5')" "389"
expect A "branch issue at end" "$(escape_trace_issue_from_branch 'auto-run/x-issue-42')" "42"
expect A "non-runner branch" "$(escape_trace_issue_from_branch 'feature/x-issue-5-y')" ""
expect A "classify pr-api" "$(escape_trace_classify ok ok auto-run/x - -)" "runner pr-api"
expect A "classify human PR" "$(escape_trace_classify ok ok feature/x msg-ref auto-run/y)" "peritty -"
expect A "classify auto-prefix" "$(escape_trace_classify ok ok - auto-prefix -)" "runner auto-prefix"
expect A "classify msg-ref runner" "$(escape_trace_classify ok ok - msg-ref auto-run/y)" "runner msg-ref"
expect A "classify msg-ref unreadable" "$(escape_trace_classify ok ok - msg-ref '?')" "tuntematon -"
expect A "classify no link" "$(escape_trace_classify ok ok - - -)" "peritty -"
expect A "classify blame fail" "$(escape_trace_classify fail ok - - -)" "tuntematon -"
expect A "classify api fail" "$(escape_trace_classify ok fail - - -)" "tuntematon -"

# ---- fixture --------------------------------------------------------------------
WORK=$(mktemp -d -t escape-trace.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
REPO="$WORK/repo"; BIN="$WORK/bin"; FX="$WORK/fx"
mkdir -p "$BIN" "$FX/issues" "$FX/commits" "$FX/pulls"

g() { git -C "$REPO" "$@"; }
commit_file() { # <file> <content> <subject> — prints the new commit's SHA
  printf '%b' "$2" >"$REPO/$1"; g add -A; g commit -qm "$3"; g rev-parse HEAD
}
git init -q "$REPO"
g symbolic-ref HEAD refs/heads/main
g config user.email t@t.t; g config user.name t
printf 'gone\n' >"$REPO/old.txt"
C1=$(commit_file a.txt 'one\ntwo\nthree\n' "init")
C2=$(commit_file b.txt 'r1\nr2\n' "feat: runner work")
C3=$(commit_file c.txt 'squash\n' "Auto: fix thing (#8) (#13)")
C4=$(commit_file d.txt 'rebased\n' "fix: x (#12)")
C5=$(commit_file e.txt 'human\n' "chore: human (#14)")
C8=$(commit_file f.txt 'carried\n' "feat: from another repo (#47)")
g rm -q old.txt; g commit -qm "remove old"; C6=$(g rev-parse HEAD)
C7=$(commit_file a.txt 'later\ntwo\nthree\n' "edit a")
g remote add origin https://github.com/o/app.git
g update-ref refs/remotes/origin/main "$C7"
g symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

issue() { jq -n --argjson n "$1" --arg b "$2" '{number: $n, body: $b, title: "t"}' >"$FX/issues/$1.json"; }
issue 101 'Löydökset: `a.txt:2`, `b.txt:1`, b.txt:2, c.txt:1, d.txt:1, e.txt:1, f.txt:1, old.txt:1, a.txt:99'
issue 102 "Auditoitu commit: \`${C6:0:10}\` (\`origin/main\`).
Löydös: \`a.txt:1\`"
issue 103 'Löydös: `a.txt:1`'
issue 104 "Auditoitu commit: \`deadbeefdeadbeef\` (\`origin/main\`).
Löydös: \`a.txt:1\`"
jq -s '. + [{number: 105, body: "pr", pull_request: {url: "x"}}]' \
  "$FX/issues/101.json" "$FX/issues/103.json" >"$FX/issues/list.json"

echo '[]' >"$FX/commits/$C1"
jq -n '[{number: 5, head: {ref: "auto-run/20261001-o-app-issue-7-x"}}]' >"$FX/commits/$C2"
echo '[]' >"$FX/commits/$C3"
echo '[]' >"$FX/commits/$C4"
echo '[]' >"$FX/commits/$C5"
echo '[]' >"$FX/commits/$C8"
jq -n '[{number: 20, head: {ref: "human/branch"}}]' >"$FX/commits/$C7"
jq -n '{number: 12, head: {ref: "auto-run/20261002-o-app-issue-9-y"}}' >"$FX/pulls/12"
jq -n '{number: 14, head: {ref: "feature/z"}}' >"$FX/pulls/14"

cat >"$BIN/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$WORK/calls.log"
[ "\${1:-}" = api ] || { echo "shim: unsupported \$*" >&2; exit 9; }
shift
path="" filter="."
while [ \$# -gt 0 ]; do
  case "\$1" in
    --jq) filter="\$2"; shift 2 ;;
    --paginate) shift ;;
    -*) echo "shim: unsupported flag \$1" >&2; exit 9 ;;
    *) path="\$1"; shift ;;
  esac
done
if [ -n "\${SHIM_RATE_LIMIT_SHA:-}" ] && [ "\$path" = "repos/o/app/commits/\$SHIM_RATE_LIMIT_SHA/pulls" ]; then
  echo "gh: API rate limit exceeded for user" >&2; exit 1
fi
case "\$path" in
  repos/o/app/issues/*)    f="$FX/issues/\${path##*/}.json" ;;
  repos/o/app/issues\?*)   f="$FX/issues/list.json" ;;
  repos/o/app/commits/*/pulls) s="\${path#repos/o/app/commits/}"; f="$FX/commits/\${s%/pulls}" ;;
  repos/o/app/pulls/*)     f="$FX/pulls/\${path##*/}" ;;
  *) f="" ;;
esac
[ -n "\$f" ] && [ -f "\$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
jq -c "\$filter" "\$f"
SH
chmod +x "$BIN/gh"

run() { : >"$WORK/calls.log"; OUT=$(PATH="$BIN:$PATH" bash "$TRACE" "$@" 2>"$WORK/stderr"); RC=$?; }
row() { printf '%s\n' "$OUT" | awk -F'\t' -v l="$1" -v s="$2" '$1 == l && $7 == s' | cut -f2-6,8; }
calls() { grep -c -- "$1" "$WORK/calls.log"; }

# ---- B) one trace, every class --------------------------------------------------
STATUS_BEFORE=$(g status --porcelain; g for-each-ref)
run --repo "$REPO" --issues 101
expect B "exit code" "$RC" 0
expect B header "$(printf '%s\n' "$OUT" | head -n1)" "location${TAB}commit${TAB}pr${TAB}class${TAB}method${TAB}issue${TAB}source${TAB}note"
expect B "inherited commit" "$(row a.txt:2 '#101')" "${C1:0:12}${TAB}-${TAB}peritty${TAB}-${TAB}-${TAB}"
expect B "runner commit (pr-api)" "$(row b.txt:1 '#101')" "${C2:0:12}${TAB}5${TAB}runner${TAB}pr-api${TAB}7${TAB}"
expect B "second line of the same commit" "$(row b.txt:2 '#101')" "${C2:0:12}${TAB}5${TAB}runner${TAB}pr-api${TAB}7${TAB}"
expect B "squash commit (auto-prefix)" "$(row c.txt:1 '#101')" "${C3:0:12}${TAB}13${TAB}runner${TAB}auto-prefix${TAB}8${TAB}"
expect B "rebase commit (msg-ref)" "$(row d.txt:1 '#101')" "${C4:0:12}${TAB}12${TAB}runner${TAB}msg-ref${TAB}9${TAB}"
expect B "human (#N) commit" "$(row e.txt:1 '#101')" "${C5:0:12}${TAB}14${TAB}peritty${TAB}-${TAB}-${TAB}"
expect B "(#N) that is no PR here (404)" "$(row f.txt:1 '#101')" "${C8:0:12}${TAB}-${TAB}peritty${TAB}-${TAB}-${TAB}"
expect B "deleted file" "$(row old.txt:1 '#101')" "-${TAB}-${TAB}tuntematon${TAB}-${TAB}-${TAB}ei-tiedostoa"
expect B "line no longer there" "$(row a.txt:99 '#101')" "-${TAB}-${TAB}tuntematon${TAB}-${TAB}-${TAB}ei-riviä"
summary=$(printf '%s\n' "$OUT" | sed -n '/^Yhteenveto/,$p')
expect B "summary total" "$(printf '%s\n' "$summary" | head -n1)" "Yhteenveto (9 viittausta):"
expect B "summary runner" "$(printf '%s\n' "$summary" | awk '$1 == "runner" {print $2, $3}')" "4 44.4"
expect B "summary peritty" "$(printf '%s\n' "$summary" | awk '$1 == "peritty" {print $2, $3}')" "3 33.3"
expect B "summary tuntematon" "$(printf '%s\n' "$summary" | awk '$1 == "tuntematon" {print $2, $3}')" "2 22.2"
if printf '%s\n' "$summary" | grep -q 'blame kertoo viimeisimmän muuttajan, ei aina vian aiheuttajaa; puuttuvalla tarkistuksella ei ole riviä'; then
  ok B "blame limitation line"
else bad B "blame limitation line missing"; fi

# ---- C) read-only ----------------------------------------------------------------
if grep -Eq -- '(^| )(-X|--method|-f|-F|--field|--raw-field|--input)( |$)|POST|PATCH|PUT|DELETE|search|issue (edit|comment|create|close)|pr (edit|comment|create|merge)' "$WORK/calls.log"; then
  bad C "a non-GET or search call was made: $(cat "$WORK/calls.log")"
elif [ "$(grep -vc '^api ' "$WORK/calls.log")" != 0 ]; then
  bad C "a call other than gh api was made: $(cat "$WORK/calls.log")"
else ok C "only GET gh api calls, no search"; fi
expect C "repo unchanged" "$(g status --porcelain; g for-each-ref)" "$STATUS_BEFORE"

# ---- D) cost -----------------------------------------------------------------------
expect D "commits/<sha>/pulls calls = unique commits" "$(calls '/pulls$')" 6
expect D "the shared commit is asked once" "$(calls "commits/$C2/pulls")" 1
expect D "pulls/<N> only for msg-ref subjects" "$(calls 'repos/o/app/pulls/')" 3
expect D "the Auto: subject needs no PR read" "$(calls 'pulls/13')" 0
expect D "one read per issue" "$(calls 'issues/101')" 1

# Runs after C and D, which read the calls.log of the first B run.
# The summary must not follow the machine's locale: a Finnish LC_NUMERIC turns 44.4 into 44,4.
FI_LOCALE=$(locale -a 2>/dev/null | grep -Eix 'fi_FI\.utf-?8' | head -n1)
if [ -n "$FI_LOCALE" ]; then
  LC_ALL=$FI_LOCALE run --repo "$REPO" --issues 101
  summary_fi=$(printf '%s\n' "$OUT" | sed -n '/^Yhteenveto/,$p')
  expect B "summary under $FI_LOCALE" "$(printf '%s\n' "$summary_fi" | awk '$1 == "runner" {print $2, $3}')" "4 44.4"
else
  echo "SKIP B: Finnish locale (fi_FI.UTF-8) not installed — locale-independence case not run"
fi

# ---- E) the blamed commit ------------------------------------------------------------
run --repo "$REPO" --issues 103
expect E "default: the default branch tip" "$(row a.txt:1 '#103')" "${C7:0:12}${TAB}20${TAB}peritty${TAB}-${TAB}-${TAB}"
run --repo "$REPO" --issues 102
expect E "the body's audited SHA" "$(row a.txt:1 '#102')" "${C1:0:12}${TAB}-${TAB}peritty${TAB}-${TAB}-${TAB}"
run --repo "$REPO" --issues 103 --at "$C6"
expect E "--at overrides the default" "$(row a.txt:1 '#103')" "${C1:0:12}${TAB}-${TAB}peritty${TAB}-${TAB}-${TAB}"
run --repo "$REPO" --issues 102 --at "$C7"
expect E "--at overrides the body SHA" "$(row a.txt:1 '#102')" "${C7:0:12}${TAB}20${TAB}peritty${TAB}-${TAB}-${TAB}"
run --repo "$REPO" --issues 104
expect E "unknown body SHA: default branch" "$(row a.txt:1 '#104')" "${C7:0:12}${TAB}20${TAB}peritty${TAB}-${TAB}-${TAB}"
if grep -q 'deadbeefdeadbeef is not in' "$WORK/stderr"; then ok E "unknown body SHA warns"; else bad E "no warning for an unknown body SHA"; fi

# ---- F) --label ------------------------------------------------------------------------
run --repo "$REPO" --label 'security audit'
expect F "exit code" "$RC" 0
expect F "one listing call" "$(calls 'issues?labels=security%20audit&state=all')" 1
expect F "no per-issue reads" "$(calls 'repos/o/app/issues/')" 0
expect F "listed issues traced" "$(printf '%s\n' "$OUT" | cut -f7 | grep '^#' | sort -u | tr '\n' ' ')" "#101 #103 "

# ---- G) rate limit and exit codes --------------------------------------------------------
: >"$WORK/calls.log"
OUT=$(SHIM_RATE_LIMIT_SHA="$C1" PATH="$BIN:$PATH" bash "$TRACE" --repo "$REPO" --issues 101 2>"$WORK/stderr"); RC=$?
expect G "rate limit: exit 0" "$RC" 0
expect G "rate limit: no calls after the refusal" "$(calls '/pulls$')" 1
expect G "rate limit: refused commit" "$(row a.txt:2 '#101')" "${C1:0:12}${TAB}-${TAB}tuntematon${TAB}-${TAB}-${TAB}kutsuraja"
expect G "rate limit: later commit" "$(row b.txt:1 '#101')" "${C2:0:12}${TAB}-${TAB}tuntematon${TAB}-${TAB}-${TAB}kutsuraja"

run --repo "$REPO"; expect G "neither --issues nor --label" "$RC" 1
run --repo "$REPO" --issues 1 --label x; expect G "--issues with --label" "$RC" 1
run --repo "$REPO" --issues 1,x; expect G "bad --issues" "$RC" 1
run --repo "$REPO" --issues 101 --at nosuchrev; expect G "bad --at" "$RC" 1
run --repo "$REPO" --issues 101 --bogus; expect G "unknown flag" "$RC" 1
run --repo "$WORK/nope" --issues 101; expect G "not a work tree" "$RC" 2
run --repo "$REPO" --issues 101 --remote upstream; expect G "unknown remote" "$RC" 2
run --repo "$REPO" --issues 999; expect G "issue read fails" "$RC" 3
g symbolic-ref --delete refs/remotes/origin/HEAD
run --repo "$REPO" --issues 103; expect G "no origin/HEAD" "$RC" 2
if grep -q "git remote set-head origin -a" "$WORK/stderr"; then ok G "set-head hint"; else bad G "no set-head hint"; fi
run --repo "$REPO" --issues 103 --at "$C7"; expect G "--at needs no origin/HEAD" "$RC" 0

# ---- H) --json ----------------------------------------------------------------------------
run --repo "$REPO" --issues 101 --at "$C7"
TABLE="$OUT" TABLE_CALLS=$(sort "$WORK/calls.log")
run --repo "$REPO" --issues 101 --at "$C7" --json
expect H "exit code" "$RC" 0
if printf '%s' "$OUT" | jq -e 'type == "object"' >/dev/null 2>&1; then ok H "valid JSON"; else bad H "not JSON: $OUT"; fi
expect H "nine locations" "$(printf '%s' "$OUT" | jq '.locations | length')" 9
expect H "rows = table rows" \
  "$(printf '%s' "$OUT" | jq -r '.locations[] | [.location, .commit, .pr, .class, .method, .issue, .source, .note] | @tsv')" \
  "$(printf '%s\n' "$TABLE" | sed -n '2,/^$/p' | sed '/^$/d')"
expect H "summary = table summary" "$(printf '%s' "$OUT" | jq -r '.summary | "\(.total) \(.runner) \(.peritty) \(.tuntematon)"')" \
  "$(printf '%s\n' "$TABLE" | awk '/^Yhteenveto/ {gsub(/[(]/, "", $2); t = $2} $1 == "runner" {r = $2} $1 == "peritty" {p = $2} $1 == "tuntematon" {u = $2} END {print t, r, p, u}')"
expect H "repo is absolute, owner_repo" "$(printf '%s' "$OUT" | jq -r '"\(.repo) \(.owner_repo)"')" "$(cd "$REPO" && pwd) o/app"
expect H "same gh calls as the table" "$(sort "$WORK/calls.log")" "$TABLE_CALLS"
OUT=$(cd "$WORK" && PATH="$BIN:$PATH" bash "$TRACE" --repo repo --issues 103 --at "$C7" --json 2>/dev/null)
expect H "relative --repo made absolute" "$(printf '%s' "$OUT" | jq -r '.repo')" "$(cd "$REPO" && pwd)"

[ "$FAIL" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$FAIL"
