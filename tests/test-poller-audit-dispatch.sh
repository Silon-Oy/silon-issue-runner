#!/usr/bin/env bash
# test-poller-audit-dispatch.sh — the poller's scheduled whole-repo audit pass
# (issue #340), run end to end through poller.sh with gh and tmux stubbed and
# HOME redirected (the isolation rules of test-poller-portability.sh).
#
# Cases:
#   a  interval not yet passed        → no audit spawn
#   b  interval passed                → exactly one spawn, state updated
#   c  GLOBAL_MAX full at the audit   → no spawn, nothing recorded
#   d  interval unset                 → no spawn, no state file
#   e  the audit pass costs zero gh calls (call count equal with and without it)
#   f  the repo's .security.audit_interval_days wins (schedules / switches off)
#   g  a repo the watchlist does not list is never audited; a foreign host
#      spawns nothing
#   h  a usage-limited tick starts no audit
#   k  the coherence kind (#342): its own interval and session, the same
#      spawn arguments; each kind's interval schedules only that kind
#
# Run: bash tests/test-poller-audit-dispatch.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

for req in jq git; do
  if ! command -v "$req" >/dev/null 2>&1; then
    echo "SKIP: $req not installed"
    exit 0
  fi
done

WORK=$(mktemp -d -t poller-audit.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAIL=1; }

TMUX_LOG="$WORK/tmux.log"
GH_LOG="$WORK/gh.log"
# One line per `tmux ls` call: how many run-issues-* sessions that call sees.
# The last line repeats. The first call is the poller's pre-loop cap check.
LS_SEQ="$WORK/ls-seq"
LS_CALLS="$WORK/ls-calls"

BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
echo "gh \$*" >> "$GH_LOG"
exit 0
SH
cat > "$BIN/tmux" <<SH
#!/usr/bin/env bash
echo "tmux \$*" >> "$TMUX_LOG"
case "\${1:-}" in
  ls|list-sessions)
    n=\$(( \$(cat "$LS_CALLS" 2>/dev/null || echo 0) + 1 ))
    echo "\$n" > "$LS_CALLS"
    k=\$(sed -n "\${n}p" "$LS_SEQ")
    [ -n "\$k" ] || k=\$(tail -n 1 "$LS_SEQ")
    [ "\${k:-0}" -gt 0 ] || exit 1
    i=0; while [ "\$i" -lt "\$k" ]; do echo "run-issues-busy-\$i: 1 windows"; i=\$((i+1)); done
    ;;
  has-session) exit 1 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN/gh" "$BIN/tmux"

GIT_ENV=(HOME="$WORK/git-home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
         GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com)
mkdir -p "$WORK/git-home" "$WORK/tmp"

# mk_repo <path> [<run-issues.json>] — a clone whose origin/HEAD points at a
# commit carrying the given .claude/run-issues.json (none when omitted).
mk_repo() {
  mkdir -p "$1"
  env "${GIT_ENV[@]}" git -C "$1" init -q
  env "${GIT_ENV[@]}" git -C "$1" remote add origin "git@github.com:example-org/$(basename "$1").git"
  if [ -n "${2:-}" ]; then
    mkdir -p "$1/.claude"
    printf '%s\n' "$2" > "$1/.claude/run-issues.json"
    env "${GIT_ENV[@]}" git -C "$1" add .claude/run-issues.json
  fi
  env "${GIT_ENV[@]}" git -C "$1" commit -q --allow-empty -m init
  env "${GIT_ENV[@]}" git -C "$1" update-ref refs/remotes/origin/main HEAD
  env "${GIT_ENV[@]}" git -C "$1" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}

mk_watchlist() {  # <path> <repo-path>
  cat > "$1" <<JSON
{ "global_max_concurrent": 2, "repos": [ { "path": "$2", "remotes": ["origin"] } ] }
JSON
}

# run_poller <home> <log-dir> <watchlist> [VAR=value ...]
run_poller() {
  local home="$1" logs="$2" wl="$3"; shift 3
  case "$home" in "$WORK"/*) ;; *) bad "SAFETY: HOME=$home outside $WORK"; return 99 ;; esac
  mkdir -p "$home"
  : > "$TMUX_LOG"; : > "$GH_LOG"; rm -f "$LS_CALLS"
  [ -s "$LS_SEQ" ] || echo 0 > "$LS_SEQ"
  env -i PATH="$BIN:$PATH" HOME="$home" TMPDIR="$WORK/tmp" \
    RUN_ISSUES_LOCK_ROOT="$WORK/locks" RUN_ISSUES_POLLER_HOSTS='*' \
    RUN_ISSUES_LOG_DIR="$logs" RUN_ISSUES_WATCHLIST="$wl" \
    "$@" bash "$ROOT/poller.sh"
}

audit_spawns() { grep -c "new-session -d -s run-issues-audit-" "$TMUX_LOG" 2>/dev/null || true; }
state_of() { cat "$1/.audit-last-security-example-org-$2" 2>/dev/null; }

REPO="$WORK/repoa"
mk_repo "$REPO"
WL="$WORK/wl.json"
mk_watchlist "$WL" "$REPO"
NOW=$(date +%s)

# ---- d: interval unset ----------------------------------------------------------
echo 0 > "$LS_SEQ"
run_poller "$WORK/hd" "$WORK/logs-d" "$WL"
[ "$(audit_spawns)" = 0 ] && ok "d unset interval: no audit spawn" || bad "d unset interval spawned an audit"
[ -z "$(find "$WORK/logs-d" -name '.audit-last-*')" ] && ok "d unset interval: no state file" \
                                                      || bad "d unset interval wrote a state file"
GH_CALLS_WITHOUT=$(wc -l < "$GH_LOG" | tr -d ' ')

# ---- b: interval passed (never audited) -----------------------------------------
run_poller "$WORK/hb" "$WORK/logs-b" "$WL" RUN_ISSUES_SECURITY_AUDIT_INTERVAL_DAYS=7
[ "$(audit_spawns)" = 1 ] && ok "b due: exactly one audit spawn" || bad "b due: $(audit_spawns) spawns"
line=$(grep "run-issues-audit-" "$TMUX_LOG" || true)
case "$line" in
  *"-s run-issues-audit-security-example-org-repoa "*) ok "b session name counts against the run-issues- cap" ;;
  *) bad "b unexpected session name: $line" ;;
esac
case "$line" in
  *"'$ROOT/security-audit.sh' '$REPO' --remote 'origin' --watchlist '$WL'"*) ok "b spawns security-audit.sh for the repo, remote and watchlist" ;;
  *) bad "b unexpected command: $line" ;;
esac
case "$line" in *"RUN_ISSUES_LOG_DIR='$WORK/logs-b'"*) ok "b the log dir is passed to the audit" ;; *) bad "b log dir missing: $line" ;; esac
st=$(state_of "$WORK/logs-b" repoa)
last="${st%% *}"
if [ -n "$last" ] && [ "$last" -ge "$NOW" ] && [ "${st#* }" = security ]; then
  ok "b the start was recorded"
else
  bad "b state not recorded: '$st'"
fi
# e: the audit pass made no gh call — same count as the run without it.
GH_CALLS_WITH=$(wc -l < "$GH_LOG" | tr -d ' ')
[ "$GH_CALLS_WITH" = "$GH_CALLS_WITHOUT" ] \
  && ok "e the audit pass costs zero gh calls ($GH_CALLS_WITH = $GH_CALLS_WITHOUT)" \
  || bad "e gh calls with audit $GH_CALLS_WITH != without $GH_CALLS_WITHOUT"

# ---- a: interval not passed -------------------------------------------------------
run_poller "$WORK/hb" "$WORK/logs-b" "$WL" RUN_ISSUES_SECURITY_AUDIT_INTERVAL_DAYS=7
[ "$(audit_spawns)" = 0 ] && ok "a not due: no audit spawn" || bad "a not due: spawned anyway"
[ "$(state_of "$WORK/logs-b" repoa)" = "$st" ] && ok "a not due: state unchanged" || bad "a state changed"
# ... and due again once the interval has elapsed.
echo "$((NOW - 8 * 86400)) security" > "$WORK/logs-b/.audit-last-security-example-org-repoa"
run_poller "$WORK/hb" "$WORK/logs-b" "$WL" RUN_ISSUES_SECURITY_AUDIT_INTERVAL_DAYS=7
[ "$(audit_spawns)" = 1 ] && ok "a elapsed interval spawns again" || bad "a elapsed interval: $(audit_spawns) spawns"

# ---- c: cap full at the audit ---------------------------------------------------
# The pre-loop check sees 0 sessions, the audit's own check sees GLOBAL_MAX.
printf '0\n2\n' > "$LS_SEQ"
run_poller "$WORK/hc" "$WORK/logs-c" "$WL" RUN_ISSUES_SECURITY_AUDIT_INTERVAL_DAYS=7
echo 0 > "$LS_SEQ"
[ "$(audit_spawns)" = 0 ] && ok "c cap full: no audit spawn" || bad "c cap full: spawned"
[ -z "$(state_of "$WORK/logs-c" repoa)" ] && ok "c cap full: nothing recorded (retried next tick)" \
                                          || bad "c cap full: start recorded without a spawn"
grep -qF "deferring security audit" "$WORK/logs-c/run-issues-poller.log" 2>/dev/null \
  && ok "c the deferral is logged" || bad "c no deferral line"

# ---- f: repo config wins --------------------------------------------------------
REPOF="$WORK/repof"
mk_repo "$REPOF" '{"security":{"audit_interval_days":30}}'
mk_watchlist "$WORK/wlf.json" "$REPOF"
run_poller "$WORK/hf" "$WORK/logs-f" "$WORK/wlf.json"
[ "$(audit_spawns)" = 1 ] && ok "f repo interval schedules without a machine value" || bad "f repo interval ignored"
grep -qF "every 30d" "$WORK/logs-f/run-issues-poller.log" && ok "f repo interval is the one in effect" \
                                                           || bad "f interval not logged as 30d"
REPOF0="$WORK/repof0"
mk_repo "$REPOF0" '{"security":{"audit_interval_days":0}}'
mk_watchlist "$WORK/wlf0.json" "$REPOF0"
run_poller "$WORK/hf0" "$WORK/logs-f0" "$WORK/wlf0.json" RUN_ISSUES_SECURITY_AUDIT_INTERVAL_DAYS=1
[ "$(audit_spawns)" = 0 ] && ok "f repo 0 switches the machine schedule off" || bad "f repo 0 ignored"

# ---- g: watchlist and host gate -------------------------------------------------
REPOG="$WORK/repog"   # exists, but no watchlist lists it
mk_repo "$REPOG" '{"security":{"audit_interval_days":1}}'
run_poller "$WORK/hg" "$WORK/logs-g" "$WL" RUN_ISSUES_SECURITY_AUDIT_INTERVAL_DAYS=1
if grep -q "repog" "$TMUX_LOG"; then bad "g an unlisted repo was audited"; else ok "g an unlisted repo is never audited"; fi
run_poller "$WORK/hg2" "$WORK/logs-g2" "$WL" RUN_ISSUES_SECURITY_AUDIT_INTERVAL_DAYS=1 \
  RUN_ISSUES_POLLER_HOSTS="definitely-not-a-host-$$"
[ "$(audit_spawns)" = 0 ] && [ ! -d "$WORK/logs-g2" ] && ok "g a foreign host spawns no audit" \
                                                     || bad "g a foreign host did something"

# ---- h: usage limit -------------------------------------------------------------
# The Claude usage-limit gate's state file (lib/usage-limit.sh) in the log dir.
mkdir -p "$WORK/logs-h"
echo "$((NOW + 3600)) test" > "$WORK/logs-h/.claude-usage-limit"
run_poller "$WORK/hh" "$WORK/logs-h" "$WL" RUN_ISSUES_SECURITY_AUDIT_INTERVAL_DAYS=1
[ "$(audit_spawns)" = 0 ] && ok "h a usage-limited tick starts no audit" || bad "h audit started under the usage limit"
grep -qF "Claude usage limit in force" "$WORK/logs-h/run-issues-poller.log" \
  && ok "h the usage limit was in force" || bad "h the usage limit fixture did not take effect"

# ---- k: the coherence kind --------------------------------------------------------
echo 0 > "$LS_SEQ"
run_poller "$WORK/hk" "$WORK/logs-k" "$WL" RUN_ISSUES_COHERENCE_AUDIT_INTERVAL_DAYS=7
[ "$(audit_spawns)" = 1 ] && ok "k coherence interval: exactly one audit spawn" || bad "k coherence: $(audit_spawns) spawns"
line=$(grep "run-issues-audit-" "$TMUX_LOG" || true)
case "$line" in
  *"-s run-issues-audit-coherence-example-org-repoa "*"'$ROOT/coherence-audit.sh' '$REPO' --remote 'origin' --watchlist '$WL'"*)
    ok "k spawns coherence-audit.sh in its own session with the shared arguments" ;;
  *) bad "k unexpected spawn: $line" ;;
esac
[ -s "$WORK/logs-k/.audit-last-coherence-example-org-repoa" ] && ok "k coherence start recorded under its own kind" \
                                                              || bad "k no coherence state file"
[ ! -e "$WORK/logs-k/.audit-last-security-example-org-repoa" ] && ok "k the coherence interval does not schedule security" \
                                                              || bad "k security scheduled by the coherence interval"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "poller-audit-dispatch: all passed" || echo "poller-audit-dispatch: FAILURES"
[ "$FAIL" -eq 0 ]
