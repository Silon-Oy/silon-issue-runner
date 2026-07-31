#!/usr/bin/env bash
# test-install-portability.sh — install.sh must resolve every path it writes
# from $HOME, and from nothing else.
#
# This is a safety property before it is a portability one. The suite runs on
# the machine whose live $HOME/.claude the pollers use, and issue runs execute
# with --dangerously-skip-permissions; an installer that reached the real home
# through tilde expansion, dscl or getent would be untestable and could damage
# a working setup. The dynamic case below therefore checks the plan itself:
# every path the installer would write must lie under the redirected home,
# whatever it printed on the way there.
#
# Cases:
#   1. install.sh and lib/preflight.sh parse
#   2. No absolute /Users/ path is hard-coded
#   3. No tilde expansion
#   4. No alternative home lookup (eval echo ~, dscl, getent)
#   5. Under a redirected $HOME, every planned write targets that home
#
# Run: bash tests/test-install-portability.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
INSTALL="$ROOT/install.sh"
PREFLIGHT="$ROOT/lib/preflight.sh"

if [ ! -f "$INSTALL" ]; then
  echo "FAIL: install.sh missing at the package root"
  exit 1
fi

WORK=$(mktemp -d -t install-portability.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0

# ---- Case 1: both files parse ----
for f in "$INSTALL" "$PREFLIGHT"; do
  if bash -n "$f" 2>"$WORK/syntax.err"; then
    echo "PASS: case1 $(basename "$f") parses"
  else
    echo "FAIL: case1 $(basename "$f") does not parse:"
    sed 's/^/      /' "$WORK/syntax.err"
    FAIL=1
  fi
done

# ---- Case 2: no hard-coded absolute user paths ----
if hits=$(grep -n '/Users/' "$INSTALL" "$PREFLIGHT" 2>/dev/null); then
  echo "FAIL: case2 hard-coded /Users/ path:"
  printf '%s\n' "$hits" | sed 's/^/      /'
  FAIL=1
else
  echo "PASS: case2 no hard-coded /Users/ path"
fi

# ---- Case 3: no tilde expansion ----
# A tilde is resolved from the passwd database, not from $HOME, so it would
# silently escape the redirected home the tests rely on.
if hits=$(grep -nE '(^|[^"'"'"'$[:alnum:]_])~/' "$INSTALL" "$PREFLIGHT" 2>/dev/null); then
  echo "FAIL: case3 tilde expansion present:"
  printf '%s\n' "$hits" | sed 's/^/      /'
  FAIL=1
else
  echo "PASS: case3 no tilde expansion"
fi

# ---- Case 4: no alternative home lookup ----
if hits=$(grep -nE 'eval[[:space:]]+echo[[:space:]]+~|[^[:alnum:]_]dscl[^[:alnum:]_]|[^[:alnum:]_]getent[^[:alnum:]_]' "$INSTALL" "$PREFLIGHT" 2>/dev/null); then
  echo "FAIL: case4 alternative home lookup present:"
  printf '%s\n' "$hits" | sed 's/^/      /'
  FAIL=1
else
  echo "PASS: case4 no alternative home lookup"
fi

# ---- Case 5: every planned write stays inside the redirected home ----
FAKE="$WORK/fake-home"
mkdir -p "$FAKE"
plan=$(HOME="$FAKE" \
       RUN_ISSUES_CLAUDE_HOME="$FAKE/.claude" \
       RUN_ISSUES_LAUNCH_AGENTS_DIR="$FAKE/Library/LaunchAgents" \
       bash "$INSTALL" --dry-run 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "PASS: case5 --dry-run against a redirected home exits 0"
else
  echo "FAIL: case5 --dry-run exited $rc"
  printf '%s\n' "$plan" | sed 's/^/      /'
  FAIL=1
fi

escapes=$(printf '%s\n' "$plan" \
  | awk -v home="$FAKE/" '
      $1 == "plan:" && ($2 == "mkdir" || $2 == "link" || $2 == "relink" || $2 == "unlink") {
        if (index($3, home) != 1) print
      }')
if [ -z "$escapes" ]; then
  echo "PASS: case5 every planned write targets the redirected home"
else
  echo "FAIL: case5 planned writes escape the redirected home:"
  printf '%s\n' "$escapes" | sed 's/^/      /'
  FAIL=1
fi

# The plan must not be empty, or case 5 would pass vacuously.
if printf '%s\n' "$plan" | grep -q '^plan: link '; then
  echo "PASS: case5 the plan is non-empty"
else
  echo "FAIL: case5 no planned links — the escape check would be vacuous"; FAIL=1
fi

if [ ! -e "$FAKE/.claude" ]; then
  echo "PASS: case5 --dry-run wrote nothing"
else
  echo "FAIL: case5 --dry-run created $FAKE/.claude"; FAIL=1
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "install-portability: all passed" || echo "install-portability: FAILURES"
[ "$FAIL" -eq 0 ]
