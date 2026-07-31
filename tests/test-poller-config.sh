#!/usr/bin/env bash
# test-poller-config.sh — lib/poller-config.sh plus the static path hygiene of
# the two pollers.
#
# The unit half covers the two decisions both pollers make before they touch
# anything: which hosts may run, and which watchlist to read. Both are
# fail-safe by design (unknown host -> no-op, explicit override never falls
# back), and both failure directions are silent in production, so they are
# asserted here rather than left to a code read.
#
# Cases:
#   1. Both pollers and the lib parse
#   2. poller_host_allowed: matching, non-matching, wildcard, empty, sloppy list
#   3. The legacy default is evaluated against this machine without crashing
#   4. The legacy default's contents (the non-regression invariant)
#   5. poller_resolve_watchlist: precedence, and no fallback for an override
#
# Run: bash tests/test-poller-config.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/lib/poller-config.sh"

if [ ! -f "$LIB" ]; then
  echo "FAIL: lib/poller-config.sh missing"
  exit 1
fi

WORK=$(mktemp -d -t poller-config.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0

# shellcheck source=lib/poller-config.sh
. "$LIB"
# The lib sets -e for its production callers; a test must collect every failure.
set +e

ok()   { echo "PASS: $1"; }
bad()  { echo "FAIL: $1"; FAIL=1; }

# ---- Case 1: everything parses ----
for f in "$ROOT/poller.sh" "$ROOT/pr-watch-poller.sh" "$LIB"; do
  if bash -n "$f" 2>"$WORK/syntax.err"; then
    ok "case1 $(basename "$f") parses"
  else
    bad "case1 $(basename "$f") does not parse:"
    sed 's/^/      /' "$WORK/syntax.err"
  fi
done

# ---- Case 2: poller_host_allowed ----
host_case() {
  local want="$1" host="$2" list="$3" desc="$4" rc
  poller_host_allowed "$host" "$list"; rc=$?
  if [ "$rc" -eq "$want" ]; then
    ok "case2 $desc"
  else
    bad "case2 $desc (rc=$rc, expected $want)"
  fi
}

host_case 0 'host-a'  '*host-a*'              'single pattern matches'
host_case 0 'host-a'  'laptop,*host-a*'       'a later pattern in the list matches'
host_case 1 'some-laptop' '*host-a*,*host-a*' 'a foreign host does not match'
host_case 0 'some-laptop' '*'                         'the wildcard allows any host'
host_case 1 'some-laptop' ''                          'an empty list allows nothing'
host_case 1 'anything'    '   '                       'a whitespace-only list allows nothing'
host_case 0 'b-host'      'a-host,,b-host'            'empty list elements are ignored'
host_case 0 'b-host'      'a-host, b-host'            'whitespace after a comma is tolerated'
host_case 1 'host-a'  'host-a'                'matching is case-sensitive and exact'

# A pattern must be matched as a glob against the host, never expanded against
# the working directory: a stray file named like the pattern must not decide it.
( cd "$WORK" && : > 'host-a-decoy' ) 2>/dev/null
( cd "$WORK" && poller_host_allowed 'some-laptop' '*host-a*' )
if [ $? -eq 1 ]; then
  ok "case2 patterns are not glob-expanded against the working directory"
else
  bad "case2 a file in the working directory changed the host decision"
fi

# ---- Case 3: the legacy default is evaluated on this machine ----
# Deliberately does not assert the outcome: the suite must behave the same on
# every machine. What matters is that the call completes with a clean 0/1.
poller_host_allowed "$(hostname -s)" "$POLLER_HOSTS_LEGACY_DEFAULT"
rc=$?
if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
  ok "case3 legacy default evaluates cleanly on this host (rc=$rc)"
else
  bad "case3 legacy default evaluation returned $rc"
fi

# ---- Case 4: the legacy default's contents ----
# This is the non-regression invariant for the machine that runs the auto-run
# setup today: it must keep working without setting RUN_ISSUES_POLLER_HOSTS.
# Changing this value is a deliberate decision, never an accident.
case "$POLLER_HOSTS_LEGACY_DEFAULT" in
  *'*host-a*'*) ok "case4 legacy default still covers the current auto-run host" ;;
  *)                bad "case4 legacy default no longer covers the current auto-run host" ;;
esac
case "$POLLER_HOSTS_LEGACY_DEFAULT" in
  *maintainers-host-a*) bad "case4 the dead maintainers-host-a glob is back" ;;
  *)                   ok "case4 no dead patterns in the legacy default" ;;
esac

# ---- Case 5: poller_resolve_watchlist ----
EXPL="$WORK/explicit.json"
CONF="$WORK/config.json"
LEG="$WORK/legacy.json"
: > "$EXPL"; : > "$CONF"; : > "$LEG"
MISS="$WORK/nope.json"

wl_case() {
  local desc="$1" want="$2"; shift 2
  local got rc
  got=$(poller_resolve_watchlist "$@"); rc=$?
  if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then
    ok "case5 $desc"
  else
    bad "case5 $desc (rc=$rc, got='$got', expected '$want')"
  fi
}

wl_case "an existing override wins"        "$EXPL" "$EXPL" "$CONF" "$LEG"
wl_case "config wins over legacy"          "$CONF" ""      "$CONF" "$LEG"
wl_case "legacy is used when config is absent" "$LEG" ""   "$MISS" "$LEG"

got=$(poller_resolve_watchlist "$MISS" "$CONF" "$LEG"); rc=$?
if [ "$rc" -eq 1 ] && [ -z "$got" ]; then
  ok "case5 a missing override never falls back"
else
  bad "case5 a missing override fell back (rc=$rc, got='$got')"
fi

got=$(poller_resolve_watchlist "" "$MISS" "$MISS"); rc=$?
if [ "$rc" -eq 1 ] && [ -z "$got" ]; then
  ok "case5 no candidate at all returns 1 and prints nothing"
else
  bad "case5 no-candidate case returned rc=$rc, got='$got'"
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "poller-config: all passed" || echo "poller-config: FAILURES"
[ "$FAIL" -eq 0 ]
