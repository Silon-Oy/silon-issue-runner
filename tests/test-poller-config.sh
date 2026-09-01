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
#   3. The host gate has no built-in default anywhere (#152)
#   4. An unset host list runs nothing, explains itself in one line, and puts
#      that line somewhere launchd cannot swallow — without repeating it
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

# ---- Case 3: the gate has no built-in default ----
# The package used to ship a list of the machine names the pollers happened to
# run on, so that one particular machine kept working without configuration
# (issue #152 removed it). A default is the one thing that could quietly bring
# back both problems it caused: the package knowing a machine by name, and a
# misconfigured machine being indistinguishable from a foreign one. A grep,
# not a variable read, because the point is that no such name exists any more.
for f in "$ROOT/poller.sh" "$ROOT/pr-watch-poller.sh" "$ROOT/action-server.sh" "$LIB"; do
  if hits=$(grep -nE 'host-a|host-a|POLLER_HOSTS_LEGACY_DEFAULT' "$f" 2>/dev/null); then
    bad "case3 $(basename "$f") still carries a built-in host default:"
    printf '%s\n' "$hits" | sed 's/^/      /'
  else
    ok "case3 $(basename "$f") carries no built-in host default"
  fi
done

# The three gates must read their variable with no `:-` fallback of any kind.
for f in "$ROOT/poller.sh" "$ROOT/pr-watch-poller.sh" "$ROOT/action-server.sh"; do
  if hits=$(grep -nE 'poller_host_allowed .*(POLLER|ACTION)_HOSTS:-[^}]' "$f" 2>/dev/null); then
    bad "case3 $(basename "$f") gives the host gate a default value:"
    printf '%s\n' "$hits" | sed 's/^/      /'
  else
    ok "case3 $(basename "$f") passes the host list through with no default"
  fi
done

# ---- Case 4: an unset host list is fail-closed AND says so ----
# This replaces the old assertion that pinned the built-in list's contents.
# What matters now is the behaviour that took its place: with the variable
# unset the poller runs nothing on any machine, and — unlike the old silent
# exit 0 — it prints exactly one line naming both the variable and the file it
# belongs in. A silent no-op made a wrong configuration invisible, which is the
# failure this case exists to catch.
#
# Runs the pollers for real (from an empty environment, HOME redirected under
# $WORK) because the message is assembled at the call site, not in the lib.
run_gate() {  # <script> <home> [VAR=value ...] — echoes stderr, returns its rc
  local script="$1" home="$2"; shift 2
  case "$home" in
    "$WORK"/*) ;;
    *) bad "SAFETY: refused to run $script with HOME=$home outside $WORK"; return 99 ;;
  esac
  env -i PATH="$PATH" HOME="$home" TMPDIR="$WORK/tmp" \
    RUN_ISSUES_LOCK_ROOT="$WORK/locks" "$@" \
    bash "$ROOT/$script" 2>&1 >/dev/null
}

mkdir -p "$WORK/tmp"
for script in poller.sh pr-watch-poller.sh; do
  GHOME="$WORK/gate-home-${script%.sh}"; mkdir -p "$GHOME"
  err=$(run_gate "$script" "$GHOME" RUN_ISSUES_LOG_DIR="$WORK/gate-logs-$script"); rc=$?

  [ "$rc" -eq 0 ] && ok "case4 $script exits 0 with RUN_ISSUES_POLLER_HOSTS unset" \
                  || bad "case4 $script exited $rc with RUN_ISSUES_POLLER_HOSTS unset"

  # Fail-closed: no default of `*`, so the tick itself never ran. The poller
  # writes its four log files only after the gate, so the log directory holding
  # nothing but the notice is what "nothing ran" looks like from out here.
  if [ -z "$(find "$GHOME" -mindepth 1 2>/dev/null)" ]; then
    ok "case4 $script wrote nothing into the home"
  else
    bad "case4 $script wrote into the home: $(find "$GHOME" -mindepth 1)"
  fi

  lines=$(printf '%s' "$err" | grep -c .)
  [ "$lines" -eq 1 ] && ok "case4 $script explains itself in exactly one line" \
                     || bad "case4 $script printed $lines lines, expected 1: $err"

  case "$err" in
    *RUN_ISSUES_POLLER_HOSTS*) ok "case4 $script names the variable" ;;
    *)                         bad "case4 $script does not name the variable: $err" ;;
  esac
  case "$err" in
    *"$GHOME/.config/run-issues/poller.env"*) ok "case4 $script names the poller.env path" ;;
    *) bad "case4 $script does not name the poller.env path: $err" ;;
  esac

  # Stderr is not where the line can be read in production: the plists carry no
  # StandardErrorPath key and the redirect that opens one is BELOW the gate, so
  # under launchd this branch reported into a closed fd. The line must therefore
  # also reach the poller's own log — the file a human opens to ask why nothing
  # has run.
  notice_log="$WORK/gate-logs-$script/${script%.sh}.log"
  case "$script" in poller.sh) notice_log="$WORK/gate-logs-$script/run-issues-poller.log" ;; esac
  if [ -s "$notice_log" ]; then
    ok "case4 $script records the notice in its own log, not only on stderr"
  else
    bad "case4 $script left no notice in $notice_log (launchd would swallow stderr)"
  fi
  logged=$(grep -c . "$notice_log" 2>/dev/null || echo 0)
  [ "$logged" -eq 1 ] && ok "case4 $script logs the notice exactly once" \
                      || bad "case4 $script logged $logged lines, expected 1"

  # And it must not repeat. Both pollers tick every 300s, so an unconditional
  # append is 288 identical lines a day into the file being read — the noise
  # failure CLAUDE.md section 5.7 exists to prevent.
  run_gate "$script" "$GHOME" RUN_ISSUES_LOG_DIR="$WORK/gate-logs-$script" >/dev/null 2>&1
  logged=$(grep -c . "$notice_log" 2>/dev/null || echo 0)
  [ "$logged" -eq 1 ] && ok "case4 $script does not repeat the notice on the next tick" \
                      || bad "case4 $script logged $logged lines after a second tick, expected 1"
done

# The other direction, and the reason the two cases must stay distinct: a host
# list that IS set but matches nothing is a foreign machine, and a foreign
# machine must still be silent. Otherwise every laptop with the package
# installed would start reporting a configuration error it does not have.
GHOME="$WORK/gate-home-foreign"; mkdir -p "$GHOME"
err=$(run_gate poller.sh "$GHOME" RUN_ISSUES_POLLER_HOSTS="definitely-not-a-host-$$" \
      RUN_ISSUES_LOG_DIR="$WORK/gate-logs-foreign"); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$err" ]; then
  ok "case4 a set-but-non-matching list is still a silent no-op"
else
  bad "case4 a foreign host was not silent (rc=$rc, stderr='$err')"
fi

# Silent means silent on disk too: the notice belongs to the misconfigured
# machine, never to the foreign one, so this branch must still create nothing.
[ ! -d "$WORK/gate-logs-foreign" ] && ok "case4 a foreign host creates no log directory" \
                                   || bad "case4 a foreign host created $WORK/gate-logs-foreign"

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
# channel: the pollers, status-render.sh (#78), action-server.sh (#77) AND
# self-update.sh (#112) all source it, so a variable is "read" if any of them
# (or the lib) reads it. The action service also passes several vars to
# lib/action-service.py, which is the real reader — count it too so the action
# env vars are not flagged as unread. poller.sh sources lib/github-app-auth.sh
# (#127) so the poller's own pickup reads can route through the App, so the
# RUN_ISSUES_GITHUB_APP_* identity vars the example documents are read there.
EXAMPLE_READERS=("${POLLERS[@]}" "$LIB" "$ROOT/status-render.sh" \
  "$ROOT/action-server.sh" "$ROOT/lib/action-service.py" "$ROOT/self-update.sh" \
  "$ROOT/lib/github-app-auth.sh")
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
