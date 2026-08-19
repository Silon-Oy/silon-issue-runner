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
#   6. Path hygiene: no absolute user paths, no tilde expansion in code
#   7. The dotfiles tree appears only as a named fallback
#   8. The pollers never source the secrets env file
#   9. examples/run-issues-poller.env.example documents real variables only
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

# ---- Case 6: path hygiene in both pollers ----
POLLERS=("$ROOT/poller.sh" "$ROOT/pr-watch-poller.sh")

for f in "${POLLERS[@]}"; do
  if hits=$(grep -n '/Users/' "$f" 2>/dev/null); then
    bad "case6 $(basename "$f") hard-codes an absolute user path:"
    printf '%s\n' "$hits" | sed 's/^/      /'
  else
    ok "case6 $(basename "$f") has no hard-coded /Users/ path"
  fi
done

# A tilde is resolved from the passwd database, not from $HOME, so in code it
# would escape the redirected home the tests rely on — and, worse, the home the
# operator actually configured. Two exemptions, both about text rather than
# paths: comment lines, and lines the poller PRINTS for a human to paste into
# their own shell, where `~/...` is the correct thing to show.
for f in "${POLLERS[@]}"; do
  hits=$(grep -nE '(^|[^"'"'"'$[:alnum:]_])~/' "$f" 2>/dev/null \
         | grep -vE '^[0-9]+:[[:space:]]*#' \
         | grep -vE '^[0-9]+:[[:space:]]*(echo|printf)[[:space:]]')
  if [ -n "$hits" ]; then
    bad "case6 $(basename "$f") expands a tilde in code:"
    printf '%s\n' "$hits" | sed 's/^/      /'
  else
    ok "case6 $(basename "$f") expands no tilde outside comments and printed text"
  fi
done

# ---- Case 7: the dotfiles tree is a fallback, never a primary path ----
# Every dotfiles-derived path must go through the one named variable, so that
# "does this still depend on the pre-package layout?" is a single-line answer.
for f in "${POLLERS[@]}"; do
  hits=$(grep -n 'dotfiles' "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#')
  count=$(printf '%s' "$hits" | grep -c . )
  if [ "$count" -eq 1 ] && printf '%s' "$hits" | grep -q 'LEGACY_DOTFILES_DIR="\${HOME}/dotfiles"'; then
    ok "case7 $(basename "$f") reaches the dotfiles tree only via LEGACY_DOTFILES_DIR"
  else
    bad "case7 $(basename "$f") references dotfiles outside the named fallback:"
    printf '%s\n' "$hits" | sed 's/^/      /'
  fi
done

# ---- Case 8: the pollers never read the secrets env file ----
# ~/.config/run-issues/env holds tokens and app keys. orchestrate.sh and
# pr-watch.sh source it themselves because they need them; a poller does not,
# and it logs copiously. The word boundary keeps RUN_ISSUES_POLLER_ENV_FILE —
# the pollers' own, secret-free channel — from matching.
for f in "${POLLERS[@]}"; do
  if hits=$(grep -nE '(^|[^A-Z_])RUN_ISSUES_ENV_FILE' "$f" 2>/dev/null); then
    bad "case8 $(basename "$f") reaches for the secrets env file:"
    printf '%s\n' "$hits" | sed 's/^/      /'
  else
    ok "case8 $(basename "$f") does not read the secrets env file"
  fi
done

# ---- Case 9: the example env file documents variables that exist ----
# An example is the only documentation an operator reads before editing, and a
# variable named there that nothing reads is indistinguishable from a working
# setting that silently does nothing. poller.env is the shared LaunchAgent config
# channel: the pollers, status-render.sh (#78) AND action-server.sh (#77) all
# source it, so a variable is "read" if any of them (or the lib) reads it. The
# action service also passes several vars to lib/action-service.py, which is the
# real reader — count it too so the action env vars are not flagged as unread.
EXAMPLE_READERS=("${POLLERS[@]}" "$LIB" "$ROOT/status-render.sh" \
  "$ROOT/action-server.sh" "$ROOT/lib/action-service.py")
EXAMPLE="$ROOT/examples/run-issues-poller.env.example"
if [ ! -f "$EXAMPLE" ]; then
  bad "case9 examples/run-issues-poller.env.example is missing"
else
  ok "case9 examples/run-issues-poller.env.example exists"

  if hits=$(grep -n '/Users/' "$EXAMPLE" 2>/dev/null); then
    bad "case9 the example hard-codes an absolute user path:"
    printf '%s\n' "$hits" | sed 's/^/      /'
  else
    ok "case9 the example has no hard-coded /Users/ path"
  fi

  unknown=""
  while IFS= read -r var; do
    [ -n "$var" ] || continue
    if ! grep -q "$var" "${EXAMPLE_READERS[@]}" 2>/dev/null; then
      unknown="$unknown $var"
    fi
  done < <(grep -oE 'RUN_ISSUES_[A-Z0-9_]+' "$EXAMPLE" | sort -u)
  if [ -n "$unknown" ]; then
    bad "case9 the example names variables nothing reads:$unknown"
  else
    ok "case9 every variable the example names is read by a poller or the lib"
  fi
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "poller-config: all passed" || echo "poller-config: FAILURES"
[ "$FAIL" -eq 0 ]
