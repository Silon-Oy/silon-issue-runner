#!/usr/bin/env bash
# test-issue-assignee.sh — the issue-writing commands must assign the created
# issue to the account gh is authenticated as, in the SAME create call.
#
# Issue #239: assignee-based pickup makes the assignee the routing handle. An
# issue created without one still runs, but its routing is invisible in the
# GitHub UI and cannot be moved to another machine until a human assigns it by
# hand — the silent-failure shape these commands exist to prevent.
#
# Why the payload and not just a grep: two regressions are invisible to a reader
# and to every other test.
#
#   1. A SECOND call (`gh issue edit --add-assignee`) reads as equivalent, but
#      on failure it leaves an unassigned issue behind. One call means either a
#      routed issue or no issue at all.
#   2. An UNCONDITIONAL `assignees: [$login]` looks correct until `gh api user`
#      fails: the payload then carries `[""]`, GitHub answers 422 and NO issue
#      is created — a lookup failure escalated into a total one. The commands
#      say the empty login must degrade to "created, not assigned".
#
# Both are asserted against the payload the command actually pipes to `gh api`,
# extracted from the command markdown and executed here, so the guard cannot
# drift from the documented snippet the way a hand-copied assertion would.
#
# Cases:
#   (1) both commands look the login up once, with bare gh (an App cannot be an
#       assignee — lib/issue.sh makes the same exclusion for verify_claim)
#   (2) neither command carries a separate assign call
#   (3) login set   -> exactly one POST, payload carries assignees: [<login>]
#   (4) login empty -> exactly one POST, payload carries NO assignees key
#   (5) both report sections name the assignee
#
# Run: bash tests/test-issue-assignee.sh   (exit 0 = all pass)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
NEW_ISSUE="$ROOT/commands/issue-runner/new-issue.md"
NEW_EPIC="$ROOT/commands/issue-runner/new-epic.md"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

FAIL=0
ok()   { echo "PASS: $1"; }
bad()  { echo "FAIL: $1"; FAIL=1; }
check(){ if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected '$2', got '$1')"; fi; }

WORK=$(mktemp -d -t issue-assignee.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Extract one ```bash fence containing <marker> from a command file.
extract_block() {   # <file> <marker>
  awk -v marker="$2" '
    /^```bash$/ { inb = 1; buf = ""; next }
    /^```$/ && inb { if (index(buf, marker)) { printf "%s", buf; exit } inb = 0; next }
    inb { buf = buf $0 "\n" }
  ' "$1"
}

# Extract the ASSIGNEES_JSON assignment (one continued statement) from a file.
extract_assignees_expr() {   # <file>
  awk '/^ASSIGNEES_JSON=/ { p = 1 } p { print } p && /\)$/ { exit }' "$1"
}

# ---------------------------------------------------------------- case 1 + 2
for f in "$NEW_ISSUE" "$NEW_EPIC"; do
  b=$(basename "$f")

  n=$(grep -cF 'gh api user --jq .login' "$f")
  check "$n" 1 "case1 $b looks the login up exactly once"

  if grep -qE 'gha_with_token[^\n]*api user' "$f"; then
    bad "case1 $b routes the login lookup through the App identity"
  else
    ok "case1 $b keeps the login lookup on bare gh"
  fi

  if grep -qE -- '--add-assignee|issues/[^ ]*/assignees' "$f"; then
    bad "case2 $b carries a separate assign call"
  else
    ok "case2 $b has no separate assign call"
  fi
done

# ------------------------------------------------------------------ case 3+4
# A gh stub that records every POST body and answers as the real API would.
BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
# Only the create call reaches this stub; record its stdin, answer via --jq.
cat >> "$GH_PAYLOADS"
echo "1" >> "$GH_CALLS"
# Mirror GitHub: the response lists the assignees that were actually set.
printf '{"number":7,"id":901,"assignees":%s}\n' \
  "$(jq -c '[(.assignees // [])[] | {login: .}]' "$GH_PAYLOADS")" \
  | jq -r "${*: -1}"
SH
chmod +x "$BIN/gh"

run_create() {   # <file> <marker> <login> ; prints payload to $PAYLOAD
  local file="$1" marker="$2" login="$3"
  GH_PAYLOADS="$WORK/payload.json"; : > "$GH_PAYLOADS"
  GH_CALLS="$WORK/calls";           : > "$GH_CALLS"
  export GH_PAYLOADS GH_CALLS

  local block expr
  expr=$(extract_assignees_expr "$file")
  block=$(extract_block "$file" "$marker")
  [ -n "$expr" ]  || { bad "no ASSIGNEES_JSON expression in $(basename "$file")"; return 1; }
  [ -n "$block" ] || { bad "no '$marker' block in $(basename "$file")"; return 1; }

  (
    PATH="$BIN:$PATH"
    OWNER_REPO="acme/widgets"
    PICK_LABELS="auto-run"
    ISSUE_TITLE="Otsikko"
    EPIC_TITLE="Otsikko"
    RUNNER_LOGIN="$login"
    LEDGER="$WORK/ledger"
    eval "$expr"
    eval "$block"
    # new-epic defines create_issue but does not call it; new-issue creates inline.
    if declare -F create_issue >/dev/null 2>&1 && [ ! -s "$GH_PAYLOADS" ]; then
      body="$WORK/body.md"; printf '## Tavoite\n\nrunko\n' > "$body"
      create_issue "$EPIC_TITLE" "$body"
    fi
  ) >/dev/null 2>&1
}

for spec in "$NEW_ISSUE|CREATED=\$(jq -n" "$NEW_EPIC|create_issue() {"; do
  file="${spec%%|*}"; marker="${spec#*|}"; b=$(basename "$file")

  if run_create "$file" "$marker" "octocat"; then
    check "$(wc -l < "$WORK/calls" | tr -d ' ')" 1 "case3 $b creates the issue with one call"
    check "$(jq -r '(.assignees // []) | join(",")' "$WORK/payload.json")" "octocat" \
      "case3 $b payload assigns the authenticated login"
  fi

  if run_create "$file" "$marker" ""; then
    check "$(wc -l < "$WORK/calls" | tr -d ' ')" 1 \
      "case4 $b still creates the issue with one call when the login is empty"
    check "$(jq -r 'has("assignees")' "$WORK/payload.json")" "false" \
      "case4 $b omits the assignees key when the login is empty"
  fi
done

# -------------------------------------------------------------------- case 5
for f in "$NEW_ISSUE" "$NEW_EPIC"; do
  b=$(basename "$f")
  if grep -qiE '^\| *assignee *\|' "$f"; then
    ok "case5 $b reports the assignee"
  else
    bad "case5 $b does not report the assignee"
  fi
done

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "issue-assignee: all passed" || echo "issue-assignee: FAILURES"
[ "$FAIL" -eq 0 ]
