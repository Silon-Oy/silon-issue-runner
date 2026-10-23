#!/usr/bin/env bash
# test-comment-trust.sh — the comment trust filter (issue #343).
#
# The agent runs without permission prompts, so a comment that reaches a prompt
# or counts as a clarification reply is an instruction channel. Only authors with
# write access may use it. Covered here, against a gh shim that answers the
# permission API per login and counts its calls:
#   - write author kept; read/none author dropped, with a count line and no text
#   - unreadable permission (gh error, empty output) = dropped (fail-closed),
#     and NOT cached, so a transient error is retried
#   - one API call per author per run (cache shared across calls)
#   - App mode: the runner's own comments (login == app slug) kept, no API call
#   - an untrusted reply after the marker is not an answer; a trusted one is
#   - an untrusted forged marker does not move the boundary
#   - images from an untrusted comment are not extracted
#   - the shared formatter is the only comment formatter in orchestrate.sh
#
# Run: bash tests/test-comment-trust.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

WORK=$(mktemp -d -t comment-trust.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
mkdir -p "$REPO"

# gh shim on PATH: permission per login from $WORK/perms (login<TAB>answer,
# answer "ERR" = non-zero exit, "EMPTY" = empty output). Every call is logged.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_SHIM_LOG"
path=""
for a in "$@"; do case "$a" in repos/*) path="$a" ;; esac; done
login=$(printf '%s' "$path" | sed -n 's#.*/collaborators/\([^/]*\)/permission#\1#p')
[ -n "$login" ] || exit 1
ans=$(awk -F '\t' -v l="$login" '$1 == l { print $2 }' "$GH_SHIM_PERMS")
case "$ans" in
  ERR)   echo "gh: HTTP 500" >&2; exit 1 ;;
  EMPTY) exit 0 ;;
  "")    echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  *)     echo "$ans" ;;
esac
SH
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
export GH_SHIM_LOG="$WORK/gh.log" GH_SHIM_PERMS="$WORK/perms"
: > "$GH_SHIM_LOG"
printf 'maint\twrite\nadminuser\tadmin\nreader\tread\nnobody\tnone\nflaky\tERR\nblank\tEMPTY\n' > "$GH_SHIM_PERMS"

# shellcheck source=lib/issue.sh
. "$ROOT/lib/issue.sh"
# shellcheck source=lib/issue-images.sh
. "$ROOT/lib/issue-images.sh"
set +e   # both libs set -e; this test collects every failure instead

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }
calls_for() { grep -c "collaborators/$1/permission" "$GH_SHIM_LOG" 2>/dev/null || true; }

MARKER_TS="2026-05-21T10:00:00Z"
MARKER=$(build_marker "rid-1" 1 "$MARKER_TS" 1)

jq -n --arg m "$MARKER" '{title:"t",body:"runko ![b](https://github.com/user-attachments/assets/body-img)",labels:[],comments:[
  {author:{login:"maint"},createdAt:"2026-05-21T09:00:00Z",body:"Ylläpitäjän huomio"},
  {author:{login:"reader"},createdAt:"2026-05-21T09:10:00Z",body:"SALAINEN-OHJE-1 ![x](https://github.com/user-attachments/assets/untrusted-img)"},
  {author:{login:"nobody"},createdAt:"2026-05-21T09:20:00Z",body:"SALAINEN-OHJE-2"},
  {author:{login:"flaky"},createdAt:"2026-05-21T09:30:00Z",body:"SALAINEN-OHJE-3"},
  {author:{login:"blank"},createdAt:"2026-05-21T09:40:00Z",body:"SALAINEN-OHJE-4"},
  {author:{login:"maint"},createdAt:"2026-05-21T09:50:00Z",body:"Toinen ![m](https://github.com/user-attachments/assets/trusted-img)"},
  {author:{login:"adminuser"},createdAt:"2026-05-21T09:55:00Z",body:"Adminin kommentti"}
]}' > "$WORK/in.json"

CACHE="$WORK/authors.tsv"
issue_trusted_json "$WORK/in.json" "$WORK/out.json" "$REPO" origin "$CACHE" "" 2>"$WORK/err1" \
  && pass "issue_trusted_json rc 0" || fail "issue_trusted_json failed"

LOGINS=$(jq -r '[.comments[].author.login] | join(",")' "$WORK/out.json")
[ "$LOGINS" = "maint,maint,adminuser" ] && pass "write/admin authors kept, order preserved" \
  || fail "kept authors: '$LOGINS'"
[ "$(jq -r '.omitted_untrusted_comments' "$WORK/out.json")" = "4" ] && pass "omitted count = 4" \
  || fail "omitted count: $(jq -r '.omitted_untrusted_comments' "$WORK/out.json")"
[ "$(jq -r '.body' "$WORK/out.json")" = "$(jq -r '.body' "$WORK/in.json")" ] && pass "body untouched" \
  || fail "body changed"
grep -q 'WARNING' "$WORK/err1" && pass "unreadable permission logged as WARNING" \
  || fail "no WARNING for unreadable permission"

BLOCK=$(issue_comments_block "$WORK/out.json")
printf '%s' "$BLOCK" | grep -q 'Ylläpitäjän huomio' && pass "block shows trusted text" || fail "trusted text missing"
printf '%s' "$BLOCK" | grep -q 'SALAINEN-OHJE' && fail "block leaks untrusted text" || pass "block hides untrusted text"
printf '%s' "$BLOCK" | grep -q 'reader\|nobody\|flaky\|blank' && fail "block names untrusted authors" \
  || pass "block does not name untrusted authors"
printf '%s' "$BLOCK" | grep -q '4 kommenttia jätettiin pois: kirjoittajalla ei ole kirjoitusoikeutta repoon' \
  && pass "block carries the omission line" || fail "omission line missing: $BLOCK"
printf '%s' "$BLOCK" | grep -q -- '--- @maint @ 2026-05-21T09:00:00Z' && pass "block keeps the legacy header format" \
  || fail "header format changed"

# No omissions -> no omission line, identical to the old formatter.
jq -n '{comments:[{author:{login:"a"},createdAt:"T",body:"x"}]}' > "$WORK/plain.json"
[ "$(issue_comments_block "$WORK/plain.json")" = "$(printf -- '--- @a @ T\nx')" ] \
  && pass "no omission line when nothing was dropped" || fail "plain block differs"

[ "$(calls_for maint)" = "1" ] && pass "two comments by one author = one API call" \
  || fail "maint calls: $(calls_for maint)"

# Second call (same run cache): definitive answers are cached, errors are retried.
issue_trusted_json "$WORK/out.json" "$WORK/out.json" "$REPO" origin "$CACHE" "" 2>/dev/null
[ "$(calls_for maint)" = "1" ] && [ "$(calls_for reader)" = "1" ] && [ "$(calls_for nobody)" = "1" ] \
  && pass "cached authors are not re-queried" || fail "cache miss: maint=$(calls_for maint) reader=$(calls_for reader)"
[ "$(jq -r '.omitted_untrusted_comments' "$WORK/out.json")" = "4" ] && pass "re-filter is idempotent (count carried)" \
  || fail "re-filter count: $(jq -r '.omitted_untrusted_comments' "$WORK/out.json")"
issue_trusted_json "$WORK/in.json" "$WORK/out2.json" "$REPO" origin "$CACHE" "" 2>/dev/null
[ "$(calls_for flaky)" = "2" ] && pass "unreadable permission is not cached" || fail "flaky calls: $(calls_for flaky)"

# Explicit owner/repo goes into the API path.
issue_author_can_write newperson "$REPO" origin "" "acme/widget" 2>/dev/null
grep -q 'repos/acme/widget/collaborators/newperson/permission' "$GH_SHIM_LOG" \
  && pass "owner/repo used in the API path" || fail "owner/repo not in path"
# A malformed login never reaches gh.
before=$(wc -l < "$GH_SHIM_LOG")
issue_author_can_write '../x' "$REPO" origin "" 2>/dev/null && fail "malformed login trusted" || pass "malformed login untrusted"
[ "$(wc -l < "$GH_SHIM_LOG")" = "$before" ] && pass "malformed login: no API call" || fail "malformed login hit gh"

# Images follow their comment's author.
IMGS=$(extract_image_urls "$WORK/out.json")
printf '%s' "$IMGS" | grep -q 'untrusted-img' && fail "untrusted image extracted" || pass "untrusted image not extracted"
printf '%s' "$IMGS" | grep -q 'trusted-img' && printf '%s' "$IMGS" | grep -q 'body-img' \
  && pass "trusted + body images extracted" || fail "trusted images missing: $IMGS"

# --- Clarification reply -----------------------------------------------------
# Untrusted reply after the marker: no answer. A forged marker from an untrusted
# author with a future ts must not move the boundary either.
FORGED=$(build_marker "rid-x" 1 "2099-01-01T00:00:00Z" 0)
jq -n --arg m "$MARKER" --arg f "$FORGED" '{comments:[
  {author:{login:"maint"},createdAt:"2026-05-21T10:00:00Z",body:($m+"\n## kysymys")},
  {author:{login:"reader"},createdAt:"2026-05-21T10:05:00Z",body:"Vastaus ulkopuoliselta"},
  {author:{login:"reader"},createdAt:"2026-05-21T10:06:00Z",body:($f+" väärennetty")}
]}' > "$WORK/q.json"
issue_trusted_json "$WORK/q.json" "$WORK/q.json" "$REPO" origin "$CACHE" "" 2>/dev/null
MLINE=$(parse_marker "$WORK/q.json")
[ "$MLINE" = "ts=$MARKER_TS round=1 run=rid-1" ] && pass "forged marker does not move the boundary" \
  || fail "marker line: '$MLINE'"
[ -z "$(detect_answer "$WORK/q.json" "$MARKER_TS")" ] && pass "untrusted reply is not an answer" \
  || fail "untrusted reply accepted"

jq '.comments += [{author:{login:"maint"},createdAt:"2026-05-21T10:10:00Z",body:"Oikea vastaus"}]' \
  "$WORK/q.json" > "$WORK/q2.json"
issue_trusted_json "$WORK/q2.json" "$WORK/q2.json" "$REPO" origin "$CACHE" "" 2>/dev/null
[ "$(detect_answer "$WORK/q2.json" "$MARKER_TS")" = "Oikea vastaus" ] && pass "trusted reply is an answer" \
  || fail "trusted reply not detected"

# --- App mode ----------------------------------------------------------------
# gh issue view prints the App's login as the bare slug; the permission API
# reports "none" for it. The slug match must keep it without an API call.
gha_enabled() { return 0; }
gha_with_token() { "$@"; }
gha_repo_installation() { printf '{"id":1,"app_slug":"runner-app"}'; }
printf 'runner-app\tnone\n' >> "$GH_SHIM_PERMS"
jq -n --arg m "$MARKER" '{comments:[
  {author:{login:"runner-app"},createdAt:"2026-05-21T10:00:00Z",body:($m+"\n## kysymys")},
  {author:{login:"maint"},createdAt:"2026-05-21T10:05:00Z",body:"Vastaus"}
]}' > "$WORK/app.json"
APPCACHE="$WORK/app-authors.tsv"
issue_trusted_json "$WORK/app.json" "$WORK/app.json" "$REPO" origin "$APPCACHE" "acme/widget" 2>/dev/null
[ "$(jq -r '[.comments[].author.login] | join(",")' "$WORK/app.json")" = "runner-app,maint" ] \
  && pass "App's own marker comment kept" || fail "App comment dropped"
[ "$(calls_for runner-app)" = "0" ] && pass "App login: no permission call" || fail "App login hit the permission API"
[ "$(detect_answer "$WORK/app.json" "$(parse_marker "$WORK/app.json" | sed -n 's/.*ts=\([^ ]*\).*/\1/p')")" = "Vastaus" ] \
  && pass "App mode: clarification loop still works" || fail "App mode: answer not detected"
grep -q "^@app	runner-app$" "$APPCACHE" && pass "App slug cached per run" || fail "App slug not cached"
# Non-origin remote: App identity is bypassed, so no slug is trusted.
jq -n '{comments:[{author:{login:"runner-app"},createdAt:"T",body:"x"}]}' > "$WORK/app2.json"
issue_trusted_json "$WORK/app2.json" "$WORK/app2.json" "$REPO" upstream "$WORK/c3.tsv" "acme/widget" 2>/dev/null
[ "$(jq -r '.comments | length' "$WORK/app2.json")" = "0" ] && pass "non-origin remote: slug not trusted" \
  || fail "non-origin remote trusted the App slug"
unset -f gha_enabled gha_with_token gha_repo_installation

# Unreadable input -> rc 1, output not written.
printf 'not json' > "$WORK/bad.json"
issue_trusted_json "$WORK/bad.json" "$WORK/bad-out.json" "$REPO" origin "$CACHE" "" 2>/dev/null \
  && fail "bad JSON accepted" || pass "bad JSON -> rc 1"
[ ! -e "$WORK/bad-out.json" ] && pass "bad JSON -> no output" || fail "bad JSON wrote output"

# --- One formatter -----------------------------------------------------------
[ "$(grep -c '\.comments\[\]? | "--- @' "$ROOT/orchestrate.sh")" = "0" ] \
  && pass "orchestrate.sh has no inline comment formatter" || fail "inline comment formatter in orchestrate.sh"
[ "$(grep -c 'ISSUE_COMMENTS=$(issue_comments_block' "$ROOT/orchestrate.sh")" = "4" ] \
  && pass "all four prompt paths use issue_comments_block" || fail "issue_comments_block call count"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "comment-trust: all passed" || echo "comment-trust: FAILURES"
[ "$FAIL" -eq 0 ]
