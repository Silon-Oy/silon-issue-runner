#!/usr/bin/env bash
# test-install-host-gate.sh — install.sh reports a missing host-gate setting
# while the human is still watching (issue #170).
#
# The host gate is fail-closed and has no default (#152): a machine whose
# poller.env does not set RUN_ISSUES_POLLER_HOSTS runs nothing at all. #160
# moved that line to a place where it can be read, but it is still produced
# only at run time — a moment when nobody is looking. Installing is the one
# moment somebody is. This test guards that earlier observation point.
#
# Two properties matter more than the wording:
#
#   a) the report is ADVISORY. poller.env is machine configuration and may
#      legitimately be written after the install, so the warning must not move
#      the exit code and must not change the plan by one line. The plist gate
#      refuses (exit 2) because a broken program path cannot fix itself; this
#      one cannot borrow that severity.
#
#   b) the warning is not silenced by the installing shell's environment. Under
#      a LaunchAgent — the only production mode — there is no inherited
#      environment, so a variable that exists only in the operator's shell is a
#      false all-clear for a machine that will still fail the gate.
#
# Cases:
#   1. no poller.env            -> warns, names variable + file + this host
#   2. poller.env sets it       -> no warning
#   3. ACTION_BASE unset        -> no ACTION_HOSTS warning (the service is opt-in)
#   4. ACTION_BASE set, HOSTS unset -> ACTION_HOSTS warning
#   5. ACTION_BASE set, HOSTS set   -> no ACTION_HOSTS warning
#   6. exit code identical whether or not the warning appears
#   7. the plan is byte-identical whether or not the warning appears
#   8. an inherited RUN_ISSUES_POLLER_HOSTS does not silence the warning
#   9. --quiet suppresses it (self-update.sh runs the installer hourly)
#
# Run: bash tests/test-install-host-gate.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
INSTALL="$ROOT/install.sh"

if [ ! -f "$INSTALL" ]; then
  echo "FAIL: install.sh missing at the package root"
  exit 1
fi

WORK=$(mktemp -d -t install-host-gate.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
HOST="$(hostname -s 2>/dev/null || echo unknown)"

# run_install <home> [args...] — a throwaway home, so the suite never touches
# the live ~/.claude the pollers use on this very machine.
run_install() {
  local home="$1"; shift
  env HOME="$home" \
      RUN_ISSUES_CLAUDE_HOME="$home/.claude" \
      RUN_ISSUES_LAUNCH_AGENTS_DIR="$home/Library/LaunchAgents" \
      RUN_ISSUES_POLLER_ENV_FILE="$home/.config/run-issues/poller.env" \
      bash "$INSTALL" "$@"
}

# make_home <name> [poller.env contents] — an empty home, optionally carrying a
# poller.env. No contents argument means no file at all.
make_home() {
  local name="$1"
  local home="$WORK/$name"
  mkdir -p "$home/.claude"
  if [ "$#" -ge 2 ]; then
    mkdir -p "$home/.config/run-issues"
    printf '%s\n' "$2" > "$home/.config/run-issues/poller.env"
  fi
  printf '%s' "$home"
}

# assert_warns <label> <output> <var>
assert_warns() {
  local label="$1" out="$2" var="$3"
  if printf '%s\n' "$out" | grep -qF "$var is not set"; then
    echo "PASS: $label warns about $var"
  else
    echo "FAIL: $label did not warn about $var"
    printf '%s\n' "$out" | sed 's/^/      /'
    FAIL=1
  fi
}

# assert_silent <label> <output> <var>
assert_silent() {
  local label="$1" out="$2" var="$3"
  if printf '%s\n' "$out" | grep -qF "$var is not set"; then
    echo "FAIL: $label warned about $var but should not have"
    printf '%s\n' "$out" | sed 's/^/      /'
    FAIL=1
  else
    echo "PASS: $label stays silent about $var"
  fi
}

# ---- Case 1: no poller.env at all ----
# The warning has to carry the same three facts as the run-time line — the
# variable, the file it belongs in and this machine's name — because that is
# what makes the two recognisably the same thing rather than two reports of
# two problems.
H1="$(make_home home1)"
out1=$(run_install "$H1" --dry-run 2>&1); rc1=$?
assert_warns "case1" "$out1" "RUN_ISSUES_POLLER_HOSTS"
for needle in "$H1/.config/run-issues/poller.env" "$HOST"; do
  if printf '%s\n' "$out1" | grep -qF "$needle"; then
    echo "PASS: case1 names '$needle'"
  else
    echo "FAIL: case1 does not name '$needle'"; FAIL=1
  fi
done
if printf '%s\n' "$out1" | grep -qF "does not exist yet"; then
  echo "PASS: case1 says the file is missing"
else
  echo "FAIL: case1 does not say the file is missing"; FAIL=1
fi

# ---- Case 2: poller.env sets the variable ----
H2="$(make_home home2 "export RUN_ISSUES_POLLER_HOSTS=\"$HOST\"")"
out2=$(run_install "$H2" --dry-run 2>&1); rc2=$?
assert_silent "case2" "$out2" "RUN_ISSUES_POLLER_HOSTS"

# ---- Case 3: the action service is opt-in ----
# Without RUN_ISSUES_ACTION_BASE an unset RUN_ISSUES_ACTION_HOSTS is the
# correct state, not an error; warning anyway would put a line about Ohjaamo in
# front of every machine that does not run it.
assert_silent "case3" "$out2" "RUN_ISSUES_ACTION_HOSTS"

# ---- Case 4: ACTION_BASE set, ACTION_HOSTS unset ----
H4="$(make_home home4 "$(printf 'export RUN_ISSUES_POLLER_HOSTS="%s"\nexport RUN_ISSUES_ACTION_BASE="http://127.0.0.1:8787"\n' "$HOST")")"
out4=$(run_install "$H4" --dry-run 2>&1); rc4=$?
assert_warns "case4" "$out4" "RUN_ISSUES_ACTION_HOSTS"
assert_silent "case4" "$out4" "RUN_ISSUES_POLLER_HOSTS"

# ---- Case 5: both set ----
H5="$(make_home home5 "$(printf 'export RUN_ISSUES_POLLER_HOSTS="%s"\nexport RUN_ISSUES_ACTION_BASE="http://127.0.0.1:8787"\nexport RUN_ISSUES_ACTION_HOSTS="%s"\n' "$HOST" "$HOST")")"
out5=$(run_install "$H5" --dry-run 2>&1); rc5=$?
assert_silent "case5" "$out5" "RUN_ISSUES_ACTION_HOSTS"
assert_silent "case5" "$out5" "RUN_ISSUES_POLLER_HOSTS"

# ---- Case 6: the exit code does not move ----
# This is the whole difference between an advisory report and a gate. Compared
# against the configured run rather than against a constant, so that a future
# change to the installer's normal exit code cannot silently make this pass.
for pair in "case6 warning:$rc1" "case6 action-warning:$rc4" "case6 configured:$rc5"; do
  label="${pair%%:*}"; rc="${pair##*:}"
  if [ "$rc" -eq "$rc2" ]; then
    echo "PASS: $label exits $rc, same as a fully configured machine"
  else
    echo "FAIL: $label exited $rc, a configured machine exited $rc2"; FAIL=1
  fi
done

# ---- Case 7: the plan is unchanged ----
# The report must sit outside ownership and planning: it reads, and its result
# feeds neither PLAN, REFUSALS nor CONFLICTS. Comparing the plan lines of the
# warned and the configured run proves that structurally. The homes differ only
# in poller.env, so the plan lines differ only by the home prefix.
plan_of() { printf '%s\n' "$1" | grep -E '^plan: ' | sed "s#$2#HOME#g"; }
p1=$(plan_of "$out1" "$H1")
p2=$(plan_of "$out2" "$H2")
if [ -n "$p1" ] && [ "$p1" = "$p2" ]; then
  echo "PASS: case7 the plan is identical with and without the warning"
else
  echo "FAIL: case7 the warning changed the plan"
  diff <(printf '%s\n' "$p1") <(printf '%s\n' "$p2") | sed 's/^/      /'
  FAIL=1
fi

# ---- Case 8: an inherited variable is not an all-clear ----
# launchd hands an agent no environment, so only the file counts.
H8="$(make_home home8 "# deliberately sets nothing")"
out8=$(env RUN_ISSUES_POLLER_HOSTS="$HOST" \
           HOME="$H8" \
           RUN_ISSUES_CLAUDE_HOME="$H8/.claude" \
           RUN_ISSUES_LAUNCH_AGENTS_DIR="$H8/Library/LaunchAgents" \
           RUN_ISSUES_POLLER_ENV_FILE="$H8/.config/run-issues/poller.env" \
           bash "$INSTALL" --dry-run 2>&1)
assert_warns "case8" "$out8" "RUN_ISSUES_POLLER_HOSTS"

# ---- Case 9: --quiet suppresses it ----
# self-update.sh runs `install.sh --with-launchagents --quiet` every hour and
# captures the output. An advisory line on a channel --quiet does not silence
# would be 24 identical lines a day in that log — the noise CLAUDE.md 5.7 exists
# to prevent — while adding nothing, because no human reads that stream.
H9="$(make_home home9)"
out9=$(run_install "$H9" --dry-run --quiet 2>&1); rc9=$?
assert_silent "case9" "$out9" "RUN_ISSUES_POLLER_HOSTS"
if [ "$rc9" -eq "$rc2" ]; then
  echo "PASS: case9 --quiet exits $rc9, unchanged"
else
  echo "FAIL: case9 --quiet exited $rc9, expected $rc2"; FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
  echo "OK: test-install-host-gate"
else
  echo "FAILURES in test-install-host-gate"
fi
exit "$FAIL"
