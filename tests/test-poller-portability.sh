#!/usr/bin/env bash
# test-poller-portability.sh — runs both pollers end to end against a
# redirected HOME, with no ~/dotfiles anywhere, to prove that every path they
# use is resolved rather than hard-coded.
#
# This is the only test that executes a poller top-level. The four scan_*
# tests extract single function bodies with awk, so the whole configuration
# block — host gate, env channel, watchlist precedence, log directory, package
# root — had no coverage at all before this file. Every one of those defaults
# is silent when it is wrong: the poller simply exits 0 and does nothing.
#
# Isolation, and why it is strict:
#   - Every run gets HOME under $WORK, and run_poller REFUSES to start if it
#     does not. The machine running this suite may be the machine running the
#     live auto-run setup; a poller that escaped to the real HOME could read
#     the real watchlist and start real orchestrators against real repos.
#   - Every run starts from an empty environment (env -i), so a RUN_ISSUES_*
#     variable exported in the developer's shell cannot decide a test.
#   - gh and tmux are stubbed at the front of PATH. git is real, but only ever
#     touches fixture repos under $WORK.
#
# Cases:
#   1  unknown host is a no-op that creates nothing, not even the log dir
#   2  allowed host writes its logs under RUN_ISSUES_LOG_DIR, not under $HOME
#   3  the `*` host pattern works with no special casing
#   4-6 watchlist precedence: legacy < config < RUN_ISSUES_WATCHLIST
#   7  an override pointing at a missing file never falls back
#   8  no watchlist at all is logged with every candidate that was tried
#   9  acceptance: a full spawn with no ~/dotfiles present
#   10 the same for pr-watch-poller.sh
#   11 poller.env is a working configuration channel (no env vars at all)
#   12 RUN_ISSUES_POLLER_ENV_FILE redirects that channel
#   13 the file wins over the environment
#   14 RUN_ISSUES_HOME is a working injection point
#
# Run: bash tests/test-poller-portability.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

for req in jq git; do
  if ! command -v "$req" >/dev/null 2>&1; then
    echo "SKIP: $req not installed"
    exit 0
  fi
done

WORK=$(mktemp -d -t poller-portability.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAIL=1; }

TMUX_LOG="$WORK/tmux.log"
GH_LOG="$WORK/gh.log"
GH_ISSUE="$WORK/gh-issue"   # contents = what `gh issue list` prints; empty = none
: > "$GH_ISSUE"

# ---- stubs ------------------------------------------------------------------
BIN="$WORK/bin"; mkdir -p "$BIN"

cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
echo "gh \$*" >> "$GH_LOG"
if [ "\${1:-}" = "issue" ] && [ "\${2:-}" = "list" ]; then
  cat "$GH_ISSUE"
fi
exit 0
SH

cat > "$BIN/tmux" <<SH
#!/usr/bin/env bash
echo "tmux \$*" >> "$TMUX_LOG"
case "\${1:-}" in
  # No sessions: \`tmux ls\` must exit non-zero with no output so the poller's
  # ACTIVE counter lands on 0, and has-session must say "not running".
  ls|list-sessions|has-session) exit 1 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN/gh" "$BIN/tmux"

# ---- fixtures ---------------------------------------------------------------
mk_home() {  # <name> -> prints an empty fake home under $WORK
  local h="$WORK/$1"
  mkdir -p "$h"
  printf '%s' "$h"
}

mk_watchlist() {  # <watchlist-path> <repo-path>
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<JSON
{
  "default_labels": ["auto-run"],
  "global_max_concurrent": 2,
  "repos": [ { "path": "$2", "labels": ["auto-run"], "remotes": ["origin"] } ]
}
JSON
}

# A real clone, so resolve_remote_to_owner_repo and repo_slug run for real.
# git runs with its own scratch HOME and no global config so the developer's
# gitconfig cannot influence the fixture.
mk_repo() {  # <path>
  mkdir -p "$1"
  HOME="$WORK/git-home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    git -C "$1" init -q >/dev/null 2>&1
  HOME="$WORK/git-home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    git -C "$1" remote add origin "git@github.com:example-org/example-repo.git" >/dev/null 2>&1
}
mkdir -p "$WORK/git-home" "$WORK/tmp"

# ---- runner -----------------------------------------------------------------
# run_poller <script> <home> [VAR=value ...] — runs a poller from an empty
# environment. RUN_ISSUES_LOCK_ROOT is always set here and never left to the
# file under test: it is a containment measure, not a case fixture.
run_poller() {
  local script="$1" home="$2"; shift 2
  case "$home" in
    "$WORK"/*) ;;
    *) bad "SAFETY: refused to run $script with HOME=$home outside $WORK"; return 99 ;;
  esac
  : > "$TMUX_LOG"; : > "$GH_LOG"
  env -i \
    PATH="$BIN:$PATH" \
    HOME="$home" \
    TMPDIR="$WORK/tmp" \
    RUN_ISSUES_LOCK_ROOT="$WORK/locks" \
    "$@" \
    bash "$ROOT/$script"
}

log_has() {  # <file> <needle> <desc>
  if [ -f "$1" ] && grep -qF -- "$2" "$1"; then
    ok "$3"
  else
    bad "$3 (log $1 does not mention '$2')"
    [ -f "$1" ] && sed 's/^/      /' "$1"
  fi
}

# ---- Case 1: unknown host writes nothing ------------------------------------
# The host gate runs before the log directory is created on purpose: deploying
# the LaunchAgent on a machine that was never configured must leave no trace.
H1=$(mk_home home1)
mk_watchlist "$WORK/wl1.json" "$WORK/nonexistent-repo-1"
run_poller poller.sh "$H1" \
  RUN_ISSUES_POLLER_HOSTS="definitely-not-a-host-$$" \
  RUN_ISSUES_LOG_DIR="$WORK/logs1" \
  RUN_ISSUES_WATCHLIST="$WORK/wl1.json"
rc=$?
[ "$rc" -eq 0 ] && ok "case1 unknown host exits 0" || bad "case1 unknown host exited $rc"
[ ! -d "$WORK/logs1" ] && ok "case1 no log directory was created" \
                       || bad "case1 the log directory was created on a foreign host"
if [ -z "$(find "$H1" -mindepth 1 2>/dev/null)" ]; then
  ok "case1 nothing was written into the home"
else
  bad "case1 files appeared in the home: $(find "$H1" -mindepth 1)"
fi

# ---- Case 2: allowed host logs into RUN_ISSUES_LOG_DIR ----------------------
H2=$(mk_home home2)
mk_watchlist "$WORK/wl2.json" "$WORK/nonexistent-repo-2"
run_poller poller.sh "$H2" \
  RUN_ISSUES_POLLER_HOSTS="$(hostname -s)" \
  RUN_ISSUES_LOG_DIR="$WORK/logs2" \
  RUN_ISSUES_WATCHLIST="$WORK/wl2.json"
rc=$?
[ "$rc" -eq 0 ] && ok "case2 allowed host exits 0" || bad "case2 allowed host exited $rc"
[ -f "$WORK/logs2/run-issues-poller.log" ] && ok "case2 run-issues-poller.log is in the override dir" \
                                           || bad "case2 run-issues-poller.log missing"
# Not a TTY, so the poller redirects its own stdout/stderr — the plists carry
# no StandardOutPath/StandardErrorPath keys any more.
[ -f "$WORK/logs2/run-issues-poller.stdout.log" ] && ok "case2 stdout is redirected by the poller itself" \
                                                  || bad "case2 stdout.log missing"
[ ! -d "$H2/Library/Logs" ] && ok "case2 the default log path under \$HOME stayed untouched" \
                            || bad "case2 the poller wrote under \$HOME/Library/Logs anyway"

# ---- Case 3: the wildcard host pattern --------------------------------------
H3=$(mk_home home3)
mk_watchlist "$WORK/wl3.json" "$WORK/nonexistent-repo-3"
run_poller poller.sh "$H3" \
  RUN_ISSUES_POLLER_HOSTS='*' \
  RUN_ISSUES_LOG_DIR="$WORK/logs3" \
  RUN_ISSUES_WATCHLIST="$WORK/wl3.json"
rc=$?
[ "$rc" -eq 0 ] && [ -f "$WORK/logs3/run-issues-poller.log" ] \
  && ok "case3 the wildcard pattern allows this host" \
  || bad "case3 the wildcard pattern did not allow this host (rc=$rc)"

# ---- Cases 4-6: watchlist precedence ----------------------------------------
# Each candidate names a DIFFERENT repo path, and none of them exists, so the
# poller's "skip invalid repo entry" line reveals which file it actually read.
H4=$(mk_home home4)
mk_watchlist "$H4/dotfiles/machine-studio/run-issues-watchlist.json" "$WORK/repo-from-legacy"
run_poller poller.sh "$H4" RUN_ISSUES_POLLER_HOSTS='*' RUN_ISSUES_LOG_DIR="$WORK/logs4"
log_has "$WORK/logs4/run-issues-poller.log" "$WORK/repo-from-legacy" \
  "case4 the legacy dotfiles watchlist is still found"

mk_watchlist "$H4/.config/run-issues/watchlist.json" "$WORK/repo-from-config"
run_poller poller.sh "$H4" RUN_ISSUES_POLLER_HOSTS='*' RUN_ISSUES_LOG_DIR="$WORK/logs5"
log_has "$WORK/logs5/run-issues-poller.log" "$WORK/repo-from-config" \
  "case5 the config watchlist wins over the legacy one"

mk_watchlist "$WORK/wl-explicit.json" "$WORK/repo-from-env"
run_poller poller.sh "$H4" RUN_ISSUES_POLLER_HOSTS='*' RUN_ISSUES_LOG_DIR="$WORK/logs6" \
  RUN_ISSUES_WATCHLIST="$WORK/wl-explicit.json"
log_has "$WORK/logs6/run-issues-poller.log" "$WORK/repo-from-env" \
  "case6 RUN_ISSUES_WATCHLIST wins over both"

# ---- Case 7: a missing override never falls back ----------------------------
# Falling back here would poll a different repo set than the operator asked
# for, and would do it silently. Both other candidates exist in $H4.
run_poller poller.sh "$H4" RUN_ISSUES_POLLER_HOSTS='*' RUN_ISSUES_LOG_DIR="$WORK/logs7" \
  RUN_ISSUES_WATCHLIST="$WORK/no-such-watchlist.json"
rc=$?
[ "$rc" -eq 0 ] && ok "case7 a missing override exits 0" || bad "case7 exited $rc"
log_has "$WORK/logs7/run-issues-poller.log" "watchlist missing" \
  "case7 a missing override is reported, not silently replaced"
if grep -qF "$WORK/repo-from-config" "$WORK/logs7/run-issues-poller.log" 2>/dev/null; then
  bad "case7 the poller fell back to the config watchlist"
else
  ok "case7 no fallback to an existing candidate"
fi

# ---- Case 8: no watchlist at all --------------------------------------------
H8=$(mk_home home8)
run_poller poller.sh "$H8" RUN_ISSUES_POLLER_HOSTS='*' RUN_ISSUES_LOG_DIR="$WORK/logs8"
log_has "$WORK/logs8/run-issues-poller.log" "$H8/.config/run-issues/watchlist.json" \
  "case8 the config candidate is named in the log"
log_has "$WORK/logs8/run-issues-poller.log" "$H8/dotfiles/machine-studio/run-issues-watchlist.json" \
  "case8 the legacy candidate is named in the log"

# ---- Case 9: acceptance — a full spawn with no ~/dotfiles -------------------
# The single assertion that proves the issue: on a machine with no dotfiles
# tree the poller sources all four libs, resolves the orchestrator and the runs
# log from the package root, and spawns. One tmux command line carries all
# three facts, so it is asserted as three separate needles.
H9=$(mk_home home9)
REPO9="$WORK/repo9"
mk_repo "$REPO9"
mk_watchlist "$H9/.config/run-issues/watchlist.json" "$REPO9"
echo "4242" > "$GH_ISSUE"
run_poller poller.sh "$H9" RUN_ISSUES_POLLER_HOSTS='*' RUN_ISSUES_LOG_DIR="$WORK/logs9"
rc=$?
: > "$GH_ISSUE"
[ "$rc" -eq 0 ] && ok "case9 exits 0 with no dotfiles tree present" || bad "case9 exited $rc"
[ ! -d "$H9/dotfiles" ] && ok "case9 the run really had no dotfiles tree" \
                        || bad "case9 a dotfiles tree existed after all"
log_has "$TMUX_LOG" "new-session" "case9 a session was spawned"
log_has "$TMUX_LOG" "RUN_ISSUES_AUTO=1" "case9 the spawn runs in auto mode"
log_has "$TMUX_LOG" "$ROOT/orchestrate.sh" "case9 the orchestrator resolves to the package root"
log_has "$TMUX_LOG" "$WORK/logs9/run-issues-poller.runs.log" \
  "case9 the runs log resolves to RUN_ISSUES_LOG_DIR"

# ---- Case 10: the same for pr-watch-poller.sh -------------------------------
H10=$(mk_home home10)
REPO10="$WORK/repo10"
mk_repo "$REPO10"
mk_watchlist "$H10/.config/run-issues/watchlist.json" "$REPO10"
run_poller pr-watch-poller.sh "$H10" RUN_ISSUES_POLLER_HOSTS='*' RUN_ISSUES_LOG_DIR="$WORK/logs10"
rc=$?
[ "$rc" -eq 0 ] && ok "case10 pr-watch-poller exits 0 with no dotfiles tree" || bad "case10 exited $rc"
[ -f "$WORK/logs10/pr-watch-poller.log" ] && ok "case10 pr-watch-poller.log is in the override dir" \
                                          || bad "case10 pr-watch-poller.log missing"
[ -f "$WORK/logs10/pr-watch-poller.stdout.log" ] && ok "case10 pr-watch-poller redirects its own stdout" \
                                                 || bad "case10 pr-watch-poller stdout.log missing"
log_has "$TMUX_LOG" "$ROOT/pr-watch.sh" "case10 pr-watch.sh resolves to the package root"
log_has "$TMUX_LOG" "$WORK/logs10/pr-watch-poller.runs.log" \
  "case10 the runs log resolves to RUN_ISSUES_LOG_DIR"

# ---- Case 11: poller.env is a working channel -------------------------------
# The point of the whole exercise: under launchd there is no environment, so if
# this file did not work, every variable above would be unreachable in the only
# mode that runs in production. Note that NO RUN_ISSUES_* variable is passed in
# (RUN_ISSUES_LOCK_ROOT is containment, set by the runner for every case).
H11=$(mk_home home11)
mk_watchlist "$WORK/wl11.json" "$WORK/repo-from-poller-env"
mkdir -p "$H11/.config/run-issues"
cat > "$H11/.config/run-issues/poller.env" <<ENV
RUN_ISSUES_POLLER_HOSTS='*'
RUN_ISSUES_LOG_DIR="$WORK/envlogs"
RUN_ISSUES_WATCHLIST="$WORK/wl11.json"
ENV
run_poller poller.sh "$H11"
rc=$?
[ "$rc" -eq 0 ] && ok "case11 exits 0 configured purely from poller.env" || bad "case11 exited $rc"
log_has "$WORK/envlogs/run-issues-poller.log" "$WORK/repo-from-poller-env" \
  "case11 host, log dir and watchlist all came from poller.env"

# ---- Case 12: RUN_ISSUES_POLLER_ENV_FILE redirects the channel --------------
cat > "$WORK/alt-poller.env" <<ENV
RUN_ISSUES_POLLER_HOSTS='*'
RUN_ISSUES_LOG_DIR="$WORK/altlogs"
RUN_ISSUES_WATCHLIST="$WORK/wl11.json"
ENV
run_poller poller.sh "$H11" RUN_ISSUES_POLLER_ENV_FILE="$WORK/alt-poller.env"
rc=$?
[ "$rc" -eq 0 ] && ok "case12 exits 0 with a redirected env file" || bad "case12 exited $rc"
[ -f "$WORK/altlogs/run-issues-poller.log" ] && ok "case12 the alternative env file took effect" \
                                             || bad "case12 the alternative env file was ignored"

# ---- Case 13: the file wins over the environment ----------------------------
# Documented precedence, not an accident: the file is sourced after the
# environment is read, and under launchd the file is the only channel there is.
H13=$(mk_home home13)
mkdir -p "$H13/.config/run-issues"
cat > "$H13/.config/run-issues/poller.env" <<ENV
RUN_ISSUES_LOG_DIR="$WORK/fromfile"
ENV
run_poller poller.sh "$H13" \
  RUN_ISSUES_POLLER_HOSTS='*' \
  RUN_ISSUES_LOG_DIR="$WORK/fromenv" \
  RUN_ISSUES_WATCHLIST="$WORK/wl11.json"
rc=$?
[ "$rc" -eq 0 ] && ok "case13 exits 0" || bad "case13 exited $rc"
[ -d "$WORK/fromfile" ] && ok "case13 the file's log dir won" || bad "case13 the file's log dir was ignored"
[ ! -d "$WORK/fromenv" ] && ok "case13 the environment's log dir was overridden" \
                         || bad "case13 the environment's log dir was used too"

# ---- Case 14: RUN_ISSUES_HOME is a working injection point ------------------
# Not user configuration — it exists so a test can point a poller at a package
# root other than its own directory, the way RUN_ISSUES_CLAUDE_HOME does for
# install.sh. Setting it to the real root must change nothing.
H14=$(mk_home home14)
mk_watchlist "$H14/.config/run-issues/watchlist.json" "$WORK/nonexistent-repo-14"
run_poller poller.sh "$H14" RUN_ISSUES_POLLER_HOSTS='*' RUN_ISSUES_LOG_DIR="$WORK/logs14" \
  RUN_ISSUES_HOME="$ROOT"
rc=$?
[ "$rc" -eq 0 ] && ok "case14 an explicit RUN_ISSUES_HOME exits 0" || bad "case14 exited $rc"
log_has "$WORK/logs14/run-issues-poller.log" "$WORK/nonexistent-repo-14" \
  "case14 behaviour is identical to the default"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "poller-portability: all passed" || echo "poller-portability: FAILURES"
[ "$FAIL" -eq 0 ]
