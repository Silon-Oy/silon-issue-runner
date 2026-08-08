#!/usr/bin/env bash
# test-pr-watch-poller-rotation.sh — the PR-watch poller must reach the WHOLE
# watchlist, not just its first PR_WATCH_MAX repos (issue #47).
#
# The bug: iteration restarted from index 0 every tick and broke on the shared
# concurrency cap, so with short scans (cap empty again by the next tick) only
# the head of the list was ever visited. A watchlist-tail repo's auto-merge PR
# stayed open forever with no error anywhere.
#
# This test drives the poller's top-level loop across several ticks against a
# STATEFUL tmux stub, so the cap binds deterministically within a tick and is
# clear again between ticks (modelling scans that finish before the next tick).
# It is offline: gh and tmux are PATH shims, git runs only on fixture repos.
#
# Cases (map to the issue's acceptance criteria):
#   1  rotation reaches every repo of a (cap+1)-repo watchlist within ceil(N/cap)
#      ticks — the starved tail repo IS launched (criterion 1)
#   2  a missing pr_watch_max_concurrent key keeps the cap at global_max_concurrent
#      exactly: tick 1 launches exactly `cap` repos and logs a cap hit (criterion 4)
#   3  the cap-hit log line names how many repos went unvisited (criterion 5)
#   4  the pr_watch_max_concurrent watchlist key raises the cap (optional cap)
#   5  the PR_WATCH_GLOBAL_MAX env var raises the cap and wins (optional cap)
#   6  a corrupt cursor file does not crash the poller — it restarts from the head
#      and rewrites a valid cursor (criterion 3)
#   7  editing the watchlist (removing a repo) skips no remaining repo and does
#      not crash; removing the cursor's target restarts cleanly (criterion 2)
#
# Run: bash tests/test-pr-watch-poller-rotation.sh   (exit 0 = all pass)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

for req in jq git; do
  if ! command -v "$req" >/dev/null 2>&1; then
    echo "SKIP: $req not installed"
    exit 0
  fi
done

WORK=$(mktemp -d -t prwatch-rotation.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAIL=1; }

mkdir -p "$WORK/tmp" "$WORK/git-home"

SESS_DIR="$WORK/sessions"; mkdir -p "$SESS_DIR"
NEWLOG="$WORK/tmux-new.log"; : > "$NEWLOG"

# ---- stubs ------------------------------------------------------------------
BIN="$WORK/bin"; mkdir -p "$BIN"

# gh: everything is a no-op exit 0. `gh repo view --jq .isArchived` therefore
# prints nothing, so the best-effort archived warning never fires.
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH

# tmux: stateful. Each session is a file under $SESS_DIR, so `new-session`
# accumulates within a tick (driving the cap) and `ls`/`has-session` read live
# state. `ls` exits 1 with no output when there are no sessions, exactly like
# real tmux, so the poller's `|| ACTIVE=0` fallback lands on a clean integer.
cat > "$BIN/tmux" <<SH
#!/usr/bin/env bash
sd="$SESS_DIR"
newlog="$NEWLOG"
case "\${1:-}" in
  ls|list-sessions)
    shopt -s nullglob
    found=0
    for f in "\$sd"/*; do printf '%s: 1 windows\n' "\$(basename "\$f")"; found=1; done
    [ "\$found" -eq 1 ] || exit 1
    ;;
  has-session)
    name="\${3#=}"
    [ -e "\$sd/\$name" ] && exit 0 || exit 1
    ;;
  new-session)
    shift
    name=""
    while [ \$# -gt 0 ]; do
      case "\$1" in
        -s) name="\$2"; shift 2 ;;
        *)  shift ;;
      esac
    done
    : > "\$sd/\$name"
    printf '%s\n' "\$name" >> "\$newlog"
    ;;
  *) exit 0 ;;
esac
exit 0
SH
chmod +x "$BIN/gh" "$BIN/tmux"

# ---- fixtures ---------------------------------------------------------------
# mk_repo <path> — a real clone with an origin remote so resolve_remote_to_owner_repo
# runs for real. git uses a scratch HOME + no global/system config so the
# developer's gitconfig cannot influence the fixture.
mk_repo() {
  local p="$1"
  mkdir -p "$p"
  HOME="$WORK/git-home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    git -C "$p" init -q >/dev/null 2>&1
  HOME="$WORK/git-home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    git -C "$p" remote add origin "git@github.com:example-org/$(basename "$p").git" >/dev/null 2>&1
}

# write_watchlist <path> <global_max> <pr_watch_max|-> <repo-path>... — a
# watchlist with one origin-only entry per repo path.
write_watchlist() {
  local wl="$1" gmax="$2" pmax="$3"; shift 3
  mkdir -p "$(dirname "$wl")"
  local repos=""
  local first=1 r
  for r in "$@"; do
    [ "$first" -eq 1 ] || repos+=","
    first=0
    repos+="{\"path\":\"$r\",\"labels\":[\"auto-run\"],\"remotes\":[\"origin\"]}"
  done
  local pr_line=""
  [ "$pmax" != "-" ] && pr_line="\"pr_watch_max_concurrent\": $pmax,"
  cat > "$wl" <<JSON
{
  "global_max_concurrent": $gmax,
  $pr_line
  "repos": [ $repos ]
}
JSON
}

# run_tick <home> <logdir> <watchlist> [VAR=value...] — one poller invocation
# from an empty environment. SESS_DIR and NEWLOG are cleared first: the previous
# tick's scans have finished, so the next tick starts at ACTIVE=0.
run_tick() {
  local home="$1" logdir="$2" wl="$3"; shift 3
  rm -rf "${SESS_DIR:?}"/* 2>/dev/null || true
  : > "$NEWLOG"
  env -i \
    PATH="$BIN:$PATH" \
    HOME="$home" \
    TMPDIR="$WORK/tmp" \
    RUN_ISSUES_LOCK_ROOT="$WORK/locks" \
    RUN_ISSUES_POLLER_HOSTS='*' \
    RUN_ISSUES_LOG_DIR="$logdir" \
    RUN_ISSUES_WATCHLIST="$wl" \
    "$@" \
    bash "$ROOT/pr-watch-poller.sh"
}

# launched_this_tick <session-name> — did the last tick spawn this session?
launched_this_tick() { grep -qx "$1" "$NEWLOG"; }

# sess_of <repo-path> — the tmux session name the poller derives for this repo's
# origin remote. Mirrors the poller's `basename | tr` idiom exactly, INCLUDING
# the trailing '_' it appends (the basename's newline is folded to '_'); the
# poller's own has-session check derives the name the same way, so the shape is
# internally consistent and not this issue's concern.
sess_of() { printf 'pr-watch-%s' "$(basename "$1" | tr -c '[:alnum:]_' '_')"; }

# launched_repo_this_tick <repo-path> — did the last tick spawn this repo's scan?
launched_repo_this_tick() { launched_this_tick "$(sess_of "$1")"; }

# launched_repo_ever <logdir> <repo-path> — did any tick log a launch for it?
launched_repo_ever() { grep -q "launching $(sess_of "$2") " "$1/pr-watch-poller.log"; }

mk_home() { local h="$WORK/$1"; mkdir -p "$h"; printf '%s' "$h"; }

# Four repos reused across cases.
for n in 0 1 2 3; do mk_repo "$WORK/repo$n"; done
R0="$WORK/repo0"; R1="$WORK/repo1"; R2="$WORK/repo2"; R3="$WORK/repo3"

# ===========================================================================
# Case 1 + 2 + 3: N = cap + 1, default cap = global_max_concurrent = 3.
# ===========================================================================
H1=$(mk_home home1); L1="$WORK/logs1"
WL1="$WORK/wl1.json"
write_watchlist "$WL1" 3 - "$R0" "$R1" "$R2" "$R3"

# --- Tick 1: START at index 0. Launches repo0,1,2, hits cap at repo3. ---
run_tick "$H1" "$L1" "$WL1"; rc=$?
[ "$rc" -eq 0 ] && ok "case1 tick1 exits 0" || bad "case1 tick1 exited $rc"

T1_COUNT=$(grep -c . "$NEWLOG" 2>/dev/null || echo 0)
[ "$T1_COUNT" -eq 3 ] \
  && ok "case2 tick1 launched exactly 3 (default cap == global_max_concurrent=3)" \
  || bad "case2 tick1 launched $T1_COUNT sessions, expected 3 (default cap should equal global_max)"

for r in "$R0" "$R1" "$R2"; do
  launched_repo_this_tick "$r" && ok "case1 tick1 launched $(sess_of "$r")" \
    || bad "case1 tick1 did not launch $(sess_of "$r")"
done
launched_repo_this_tick "$R3" \
  && bad "case1 tick1 launched repo3 (should have starved this tick, cap=3)" \
  || ok "case1 tick1 correctly deferred repo3 (cap reached)"

# criterion 5: the cap-hit line names the unvisited count (N - i = 4 - 3 = 1).
if grep -q "hit cap during loop (3/3) — 1 repo(s) not visited this tick" "$L1/pr-watch-poller.log"; then
  ok "case3 cap-hit log line reports 1 repo not visited"
else
  bad "case3 cap-hit log line missing/wrong (expected '(3/3) — 1 repo(s) not visited')"
  grep "hit cap" "$L1/pr-watch-poller.log" 2>/dev/null | sed 's/^/      /'
fi

# The cursor now pins the resume point at repo3.
CURSOR="$L1/.pr-watch-cursor"
[ -f "$CURSOR" ] && [ "$(cat "$CURSOR")" = "$R3" ] \
  && ok "case1 cursor pinned to the deferred repo3" \
  || bad "case1 cursor is '$(cat "$CURSOR" 2>/dev/null)', expected '$R3'"

# --- Tick 2: START at repo3. The previously starved repo IS launched now. ---
run_tick "$H1" "$L1" "$WL1"; rc=$?
[ "$rc" -eq 0 ] && ok "case1 tick2 exits 0" || bad "case1 tick2 exited $rc"
launched_repo_this_tick "$R3" \
  && ok "case1 tick2 launched the previously starved repo3 (no starvation)" \
  || bad "case1 tick2 STILL did not launch repo3 — starvation not fixed"

# Union over the two ticks: every repo reached at least once.
ALL_OK=1
for r in "$R0" "$R1" "$R2" "$R3"; do
  launched_repo_ever "$L1" "$r" || { ALL_OK=0; bad "case1 $(sess_of "$r") never launched across 2 ticks"; }
done
[ "$ALL_OK" -eq 1 ] && ok "case1 all 4 repos launched within ceil(4/3)=2 ticks"

# ===========================================================================
# Case 4: pr_watch_max_concurrent raises the cap above global_max_concurrent.
# ===========================================================================
H4=$(mk_home home4); L4="$WORK/logs4"
WL4="$WORK/wl4.json"
write_watchlist "$WL4" 2 4 "$R0" "$R1" "$R2" "$R3"
run_tick "$H4" "$L4" "$WL4"; rc=$?
[ "$rc" -eq 0 ] && ok "case4 exits 0" || bad "case4 exited $rc"
C4=$(grep -c . "$NEWLOG" 2>/dev/null || echo 0)
[ "$C4" -eq 4 ] \
  && ok "case4 pr_watch_max_concurrent=4 let all 4 repos launch in one tick" \
  || bad "case4 launched $C4, expected 4 (the separate cap was not honoured)"
grep -q "hit cap" "$L4/pr-watch-poller.log" \
  && bad "case4 hit the cap despite pr_watch_max_concurrent=4" \
  || ok "case4 no cap hit with the higher pr_watch_max_concurrent"

# ===========================================================================
# Case 5: PR_WATCH_GLOBAL_MAX env var raises the cap (and wins over the file's
# global_max_concurrent=2).
# ===========================================================================
H5=$(mk_home home5); L5="$WORK/logs5"
WL5="$WORK/wl5.json"
write_watchlist "$WL5" 2 - "$R0" "$R1" "$R2" "$R3"
run_tick "$H5" "$L5" "$WL5" PR_WATCH_GLOBAL_MAX=4; rc=$?
[ "$rc" -eq 0 ] && ok "case5 exits 0" || bad "case5 exited $rc"
C5=$(grep -c . "$NEWLOG" 2>/dev/null || echo 0)
[ "$C5" -eq 4 ] \
  && ok "case5 PR_WATCH_GLOBAL_MAX=4 raised the cap for all 4 repos" \
  || bad "case5 launched $C5, expected 4 (PR_WATCH_GLOBAL_MAX ignored)"

# ===========================================================================
# Case 6: a corrupt cursor file must not crash — restart from the head.
# ===========================================================================
H6=$(mk_home home6); L6="$WORK/logs6"
mkdir -p "$L6"
printf 'this-is-not-a-valid-repo-path\x00garbage\n' > "$L6/.pr-watch-cursor"
WL6="$WORK/wl6.json"
write_watchlist "$WL6" 3 - "$R0" "$R1" "$R2" "$R3"
run_tick "$H6" "$L6" "$WL6"; rc=$?
[ "$rc" -eq 0 ] && ok "case6 corrupt cursor did not crash the poller (exit 0)" || bad "case6 exited $rc"
launched_repo_this_tick "$R0" \
  && ok "case6 restarted from the head (repo0) on a corrupt cursor" \
  || bad "case6 did not restart from the head on a corrupt cursor"
[ "$(cat "$L6/.pr-watch-cursor" 2>/dev/null)" = "$R3" ] \
  && ok "case6 rewrote a valid cursor after the corrupt one" \
  || bad "case6 did not rewrite a valid cursor (got '$(cat "$L6/.pr-watch-cursor" 2>/dev/null)')"

# ===========================================================================
# Case 7: editing the watchlist skips no remaining repo and never crashes.
# ===========================================================================
H7=$(mk_home home7); L7="$WORK/logs7"
WL7="$WORK/wl7.json"
# Tick 1 with 4 repos -> cursor pins repo3.
write_watchlist "$WL7" 3 - "$R0" "$R1" "$R2" "$R3"
run_tick "$H7" "$L7" "$WL7" >/dev/null 2>&1
[ "$(cat "$L7/.pr-watch-cursor" 2>/dev/null)" = "$R3" ] \
  && ok "case7 setup: cursor pinned to repo3 before the edit" \
  || bad "case7 setup: cursor is '$(cat "$L7/.pr-watch-cursor" 2>/dev/null)', expected repo3"

# Edit: remove repo1 (NOT the cursor target). New list: repo0, repo2, repo3.
write_watchlist "$WL7" 3 - "$R0" "$R2" "$R3"
run_tick "$H7" "$L7" "$WL7"; rc=$?
[ "$rc" -eq 0 ] && ok "case7 tick after edit exits 0 (no crash)" || bad "case7 tick after edit exited $rc"
E_OK=1
for r in "$R0" "$R2" "$R3"; do
  launched_repo_this_tick "$r" || { E_OK=0; bad "case7 remaining $(sess_of "$r") not launched after edit"; }
done
[ "$E_OK" -eq 1 ] && ok "case7 all remaining repos launched after removing repo1 (cap=3, N=3)"
launched_repo_this_tick "$R1" \
  && bad "case7 launched the removed repo1" \
  || ok "case7 did not launch the removed repo1"

# Edit: remove the cursor's target (repo3). Cursor now points at a missing path.
write_watchlist "$WL7" 3 - "$R0" "$R2" "$R3"
run_tick "$H7" "$L7" "$WL7" >/dev/null 2>&1   # re-pin cursor to a valid target first
# Force the cursor to a path that no longer exists in a shrunken list.
printf '%s\n' "$R3" > "$L7/.pr-watch-cursor"
write_watchlist "$WL7" 3 - "$R0" "$R2"        # repo3 gone
run_tick "$H7" "$L7" "$WL7"; rc=$?
[ "$rc" -eq 0 ] && ok "case7 removed-cursor-target tick exits 0 (restart from head, no crash)" \
               || bad "case7 removed-cursor-target tick exited $rc"
launched_repo_this_tick "$R0" \
  && ok "case7 restarted from the head when the cursor target was removed" \
  || bad "case7 did not restart from the head when the cursor target was removed"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "pr-watch-poller-rotation: all passed" || echo "pr-watch-poller-rotation: FAILURES"
[ "$FAIL" -eq 0 ]
