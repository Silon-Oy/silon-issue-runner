#!/usr/bin/env bash
# test-readme.sh — README.md is the only human-facing document in this package,
# and the only place where the security model (what a user consents to when
# running install.sh) is written down. Prose cannot be verified automatically,
# so this test guards STRUCTURE and FRESHNESS instead of wording:
#
#   a) the sections a first-hour reader needs are present as headings
#   b) the documented exit codes are DERIVED FROM THE SOURCE, not from memory —
#      the exit-code lists live in three separate spaces (orchestrator,
#      installer, PR watcher) that must never be conflated, and every one of
#      them has grown a code before (orchestrator gained 8 in #7). Adding a code
#      to a script without documenting it turns this test red.
#   c) every relative link resolves to a file that exists in the repo
#   d) no personal absolute path or token shape leaks into a shared document
#   e) the security model still names every consent surface it covers
#
# This test WRITES NOTHING: no temp dirs, no $HOME access. It only reads files
# from the repository.
#
# Cases:
#   1. README.md exists and is non-empty
#   2. Required sections are present as '## ' headings
#   3. Exit-code freshness: every code in orchestrate.sh / install.sh /
#      pr-watch.sh / status.sh has a table row, and four separate tables exist
#   4. Relative links resolve to existing paths
#   5. No leaked absolute paths or token shapes
#   6. Security-model identifiers are present
#
# Run: bash tests/test-readme.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FAIL=0

README="$ROOT/README.md"

# ---- Case 1: README exists ----
# Exit immediately when it is missing: every later case would otherwise report a
# failure that has the same single cause, drowning the real signal.
if [ ! -s "$README" ]; then
  echo "FAIL: README.md missing or empty at $README"
  echo "----------------------------------------"
  echo "readme: FAILURES"
  exit 1
fi
echo "PASS: README.md exists and is non-empty"

# ---- Case 2: required sections ----
# Only heading lines are searched. A section name mentioned in prose must not
# satisfy the requirement — the reader needs a section, not a sentence.
HEADINGS="$(grep '^## ' "$README")"
for s in Riippuvuudet Asennus Konfigurointi Käyttö Turvamalli Perehdytys Vianetsintä; do
  if printf '%s\n' "$HEADINGS" | grep -qi -- "$s"; then
    echo "PASS: section heading present: $s"
  else
    echo "FAIL: no '## ' heading matches: $s"; FAIL=1
  fi
done

# ---- Case 3: exit-code freshness ----
# The expectation is extracted from the scripts' own header comments, so this
# case cannot go stale: a new exit code in a script becomes a red test here.
assert_exit_codes() {
  local label="$1" file="$2"
  shift 2
  local codes
  codes="$(printf '%s\n' "$@" | sed '/^$/d')"
  if [ -z "$codes" ]; then
    echo "FAIL: exit code extraction from $file produced nothing — the header format changed"
    FAIL=1
    return
  fi
  local c missing=""
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if grep -qE "^\| *$c *\|" "$README"; then
      : # documented
    else
      missing="$missing $c"
    fi
  done <<< "$codes"
  if [ -z "$missing" ]; then
    echo "PASS: $label exit codes documented ($(printf '%s' "$codes" | tr '\n' ' '))"
  else
    echo "FAIL: $label exit codes missing from README:$missing (source: $file)"; FAIL=1
  fi
}

ORCH_CODES="$(sed -n '/^# Exit codes:/,/^#$/p' "$ROOT/orchestrate.sh" \
  | sed -n 's/^#[[:space:]]\{1,\}\([0-9]\{1,\}\)[[:space:]].*/\1/p')"
INST_CODES="$(sed -n '/^Exit codes:/,/^EOF$/p' "$ROOT/install.sh" \
  | sed -n 's/^[[:space:]]*\([0-9]\{1,\}\)[[:space:]].*/\1/p')"
PRW_CODES="$(sed -n '/^# Exit codes:/,/^$/p' "$ROOT/pr-watch.sh" \
  | sed -n 's/^#[[:space:]]\{1,\}\([0-9]\{1,\}\)[[:space:]].*/\1/p')"
STATUS_CODES="$(sed -n '/^# Exit codes:/,/^$/p' "$ROOT/status.sh" \
  | sed -n 's/^#[[:space:]]\{1,\}\([0-9]\{1,\}\)[[:space:]].*/\1/p')"

assert_exit_codes "orchestrator" "orchestrate.sh" "$ORCH_CODES"
assert_exit_codes "installer" "install.sh" "$INST_CODES"
assert_exit_codes "pr-watch" "pr-watch.sh" "$PRW_CODES"
assert_exit_codes "status" "status.sh" "$STATUS_CODES"

# The four spaces must stay four tables. One merged table would document the
# codes but lose the fact that code 5 means something different in each script.
TABLES=$(grep -c '^| *Koodi *|' "$README")
if [ "$TABLES" -ge 4 ]; then
  echo "PASS: $TABLES separate exit-code tables (>= 4 required)"
else
  echo "FAIL: only $TABLES exit-code table(s); the four exit-code spaces must not be merged"; FAIL=1
fi

# ---- Case 4: relative links resolve ----
while IFS= read -r target; do
  [ -n "$target" ] || continue
  case "$target" in
    http*|mailto:*|'#'*) continue ;;
  esac
  target="${target%%#*}"
  [ -n "$target" ] || continue
  if [ -e "$ROOT/$target" ]; then
    echo "PASS: link resolves: $target"
  else
    echo "FAIL: link target does not exist: $target"; FAIL=1
  fi
done < <(grep -o '](\([^)]*\))' "$README" | sed 's/^](//; s/)$//')

# ---- Case 5: no leaks ----
for pat in '/Users/' 'ghp_' 'github_pat_'; do
  if grep -q -- "$pat" "$README"; then
    echo "FAIL: README contains '$pat' (personal path or token leak)"; FAIL=1
  else
    echo "PASS: no '$pat' in README"
  fi
done

# ---- Case 6: security-model identifiers ----
# Each identifier stands for one consent surface described in the security
# model. Dropping a description silently would narrow what the reader agrees to.
for id in \
  '--dangerously-skip-permissions' \
  'RUN_ISSUES_AUTO=1' \
  'INV-OWN' \
  'PR_WATCH_ENABLE_CONFLICT_RESOLUTION' \
  'provision-test-env.sh' \
  'db-clone.json' \
  'post-merge-migrate.sh' \
  'run-issues.json'
do
  if grep -qF -- "$id" "$README"; then
    echo "PASS: security-model identifier present: $id"
  else
    echo "FAIL: security-model identifier missing: $id"; FAIL=1
  fi
done

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "readme: all passed" || echo "readme: FAILURES"
[ "$FAIL" -eq 0 ]
