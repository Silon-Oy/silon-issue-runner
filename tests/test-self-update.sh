#!/usr/bin/env bash
# test-self-update.sh — self-update.sh (issue #112): the unattended keep-current
# LaunchAgent. Drives the real script against synthetic git repos and a stub
# installer, so the pull guards, the idle port and the install call are all
# observable without a network or a real ~/.claude.
#
# The script targets RUN_ISSUES_HOME for every git op / version summary / install
# (SCRIPT_DIR in production, injected here), sources its libs from there, and
# calls RUN_ISSUES_SELF_UPDATE_INSTALL (default $RUN_ISSUES_HOME/install.sh) — a
# recording stub here, the same injection idiom run-epic.sh uses for
# RUN_EPIC_ORCHESTRATE / RUN_EPIC_STOP_RUN.
#
# Cases:
#   1. Clean main + even origin -> pull attempted, install called with
#      --with-launchagents --quiet
#   2. Dirty tree -> no pull; install still runs
#   3. Branch != main -> no pull; install still runs
#   4. Submodule (git-shim'd superproject) -> no pull; install still runs
#   5. Diverged main -> ff-only refuses, the local-only commit survives
#   6. Live run (run.json initialized, this host) -> whole tick skipped, no install
#
# Run: bash tests/test-self-update.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SELF_UPDATE="$ROOT/self-update.sh"
FAIL=0

if ! command -v git >/dev/null 2>&1; then
  echo "SKIP: git not in PATH"
  exit 0
fi
REAL_GIT="$(command -v git)"

WORK=$(mktemp -d -t self-update.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
# Defence in depth: run entirely inside $WORK so that a stray bare git command —
# or an empty path variable feeding `cd ""` (which succeeds and stays put) — can
# never touch the real repository this test lives in.
cd "$WORK" || { echo "FAIL: cannot cd into WORK"; exit 1; }

# make_home <path> — build a throwaway package root at <path>: a git repo on
# `main` whose lib/ is a committed symlink to the real package lib (so the libs
# resolve AND `git status --porcelain` is clean). Writes nothing to stdout.
make_home() {
  local home="$1"
  mkdir -p "$home"
  git init -q "$home"
  (
    cd "$home"
    git config user.email t@t; git config user.name t
    # Force `main` regardless of the machine's init.defaultBranch.
    git symbolic-ref HEAD refs/heads/main
    ln -s "$ROOT/lib" lib
    printf 'seed\n' > seed.txt
    git add lib seed.txt
    git commit -q -m seed
  )
}

# recording install stub: appends its args to $1 and exits with ${2:-0}.
make_install_stub() {
  local path="$1" record="$2" code="${3:-0}"
  cat > "$path" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$record"
exit $code
STUB
  chmod +x "$path"
}

# run_self_update <home> <record> [extra env assignments as KEY=VAL ...]
# Runs the script in a clean, redirected environment. Extra args are exported
# for the child only.
run_self_update() {
  local home="$1" record="$2"; shift 2
  local tmp_home="$WORK/fakehome"
  mkdir -p "$tmp_home"
  local install_stub="$WORK/install-stub.sh"
  [ -f "$install_stub" ] || make_install_stub "$install_stub" "$record"
  env -i \
    PATH="$PATH" \
    HOME="$tmp_home" \
    RUN_ISSUES_HOME="$home" \
    RUN_ISSUES_LOG_DIR="$WORK/logs" \
    RUN_ISSUES_LAUNCH_AGENTS_DIR="$WORK/launchagents" \
    RUN_ISSUES_POLLER_ENV_FILE="$WORK/nonexistent.env" \
    RUN_ISSUES_SELF_UPDATE_INSTALL="$install_stub" \
    "$@" \
    bash "$SELF_UPDATE" >/dev/null 2>&1
}

SELF_LOG="$WORK/logs/run-issues-self-update.log"
reset_log() { rm -f "$SELF_LOG"; }
log_has() { grep -qi -- "$1" "$SELF_LOG" 2>/dev/null; }

# === Case 1: clean main + even origin -> pull attempted, install called =======
reset_log
H1="$WORK/home1"; make_home "$H1"
ORIGIN1="$WORK/origin1.git"
git init -q --bare "$ORIGIN1"
( cd "$H1" && git remote add origin "$ORIGIN1" && git push -q -u origin main )
REC1="$WORK/rec1.txt"; : > "$REC1"
make_install_stub "$WORK/install-stub.sh" "$REC1" 0
run_self_update "$H1" "$REC1"
if log_has "guards pass"; then
  echo "PASS: case1 clean main -> pull guards pass"
else
  echo "FAIL: case1 pull guards did not pass on a clean main clone"; FAIL=1
fi
if grep -q -- '--with-launchagents --quiet' "$REC1"; then
  echo "PASS: case1 install called with --with-launchagents --quiet"
else
  echo "FAIL: case1 install not called with expected args (got: $(cat "$REC1"))"; FAIL=1
fi

# === Case 2: dirty tree -> no pull; install still runs ========================
reset_log
H2="$WORK/home2"; make_home "$H2"
printf 'dirt\n' > "$H2/uncommitted.txt"
REC2="$WORK/rec2.txt"; : > "$REC2"
make_install_stub "$WORK/install-stub.sh" "$REC2" 0
run_self_update "$H2" "$REC2"
if log_has "working tree not clean" && ! log_has "guards pass"; then
  echo "PASS: case2 dirty tree -> pull skipped"
else
  echo "FAIL: case2 dirty tree did not skip pull"; FAIL=1
fi
if grep -q -- '--with-launchagents --quiet' "$REC2"; then
  echo "PASS: case2 install still runs when pull is skipped"
else
  echo "FAIL: case2 install did not run"; FAIL=1
fi

# === Case 3: branch != main -> no pull; install still runs ====================
reset_log
H3="$WORK/home3"; make_home "$H3"
( cd "$H3" && git checkout -q -b feature/x )
REC3="$WORK/rec3.txt"; : > "$REC3"
make_install_stub "$WORK/install-stub.sh" "$REC3" 0
run_self_update "$H3" "$REC3"
if log_has "not main" && ! log_has "guards pass"; then
  echo "PASS: case3 non-main branch -> pull skipped"
else
  echo "FAIL: case3 non-main branch did not skip pull"; FAIL=1
fi
if grep -q -- '--with-launchagents' "$REC3"; then
  echo "PASS: case3 install still runs on a non-main branch"
else
  echo "FAIL: case3 install did not run"; FAIL=1
fi

# === Case 4: submodule (git-shim'd superproject) -> no pull; install runs =====
# A git shim intercepts `rev-parse --show-superproject-working-tree` and echoes a
# fake path (so the guard sees a submodule), passing every other git call
# through. This avoids needing file-protocol submodule support.
reset_log
H4="$WORK/home4"; make_home "$H4"
SHIMBIN="$WORK/shimbin"
mkdir -p "$SHIMBIN"
cat > "$SHIMBIN/git" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "--show-superproject-working-tree" ]; then
    echo "$WORK/fake-super"; exit 0
  fi
done
exec "$REAL_GIT" "\$@"
SH
chmod +x "$SHIMBIN/git"
REC4="$WORK/rec4.txt"; : > "$REC4"
make_install_stub "$WORK/install-stub.sh" "$REC4" 0
run_self_update "$H4" "$REC4" PATH="$SHIMBIN:$PATH"
if log_has "submodule" && ! log_has "guards pass"; then
  echo "PASS: case4 submodule -> pull skipped"
else
  echo "FAIL: case4 submodule did not skip pull"; FAIL=1
fi
if grep -q -- '--with-launchagents' "$REC4"; then
  echo "PASS: case4 install still runs on a submodule clone (the whole point)"
else
  echo "FAIL: case4 install did not run on a submodule clone"; FAIL=1
fi

# === Case 5: diverged main -> ff-only refuses, local commit survives ==========
reset_log
H5="$WORK/home5"; make_home "$H5"
ORIGIN5="$WORK/origin5.git"
git init -q --bare "$ORIGIN5"
( cd "$H5" && git remote add origin "$ORIGIN5" && git push -q -u origin main )
# origin advances by one commit; local advances by a DIFFERENT commit -> diverge.
CLONE5="$WORK/clone5"
git clone -q "$ORIGIN5" "$CLONE5"
( cd "$CLONE5" && git config user.email t@t && git config user.name t \
  && git commit -q --allow-empty -m origin-side && git push -q origin main )
( cd "$H5" && git commit -q --allow-empty -m local-side )
LOCAL_SHA=$( cd "$H5" && git rev-parse HEAD )
REC5="$WORK/rec5.txt"; : > "$REC5"
make_install_stub "$WORK/install-stub.sh" "$REC5" 0
run_self_update "$H5" "$REC5"
AFTER_SHA=$( cd "$H5" && git rev-parse HEAD )
# here-string, not a pipe: `git log | grep -q` would SIGPIPE git log under pipefail.
H5_LOG=$( cd "$H5" && git log --oneline )
if [ "$LOCAL_SHA" = "$AFTER_SHA" ] && grep -q 'local-side' <<<"$H5_LOG"; then
  echo "PASS: case5 ff-only refused -> local commit survived (nothing destroyed)"
else
  echo "FAIL: case5 local commit was moved/destroyed by the pull (before=$LOCAL_SHA after=$AFTER_SHA)"; FAIL=1
fi
if log_has "did not apply"; then
  echo "PASS: case5 pull logged fail-soft (did not apply)"
else
  echo "FAIL: case5 pull did not log the fail-soft NOTE"; FAIL=1
fi

# === Case 6: live run -> whole tick skipped, no install =======================
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: case6 needs jq (idle-port reads run.json)"
else
  reset_log
  H6="$WORK/home6"; make_home "$H6"
  # A watched repo carrying a live run.json for THIS host.
  WREPO="$WORK/watched"
  mkdir -p "$WREPO/.claude/run-issues/run-abc"
  THIS_HOST=$(hostname -s)
  cat > "$WREPO/.claude/run-issues/run-abc/run.json" <<JSON
{"status":"initialized","host":"$THIS_HOST","issue_number":7}
JSON
  WATCHLIST6="$WORK/watchlist6.json"
  cat > "$WATCHLIST6" <<JSON
{"repos":[{"path":"$WREPO"}]}
JSON
  REC6="$WORK/rec6.txt"; : > "$REC6"
  make_install_stub "$WORK/install-stub.sh" "$REC6" 0
  run_self_update "$H6" "$REC6" RUN_ISSUES_WATCHLIST="$WATCHLIST6"
  if log_has "live run present"; then
    echo "PASS: case6 live run detected -> tick skipped"
  else
    echo "FAIL: case6 live run was not detected"; FAIL=1
  fi
  if [ ! -s "$REC6" ]; then
    echo "PASS: case6 install NOT called under a live run"
  else
    echo "FAIL: case6 install was called despite a live run (got: $(cat "$REC6"))"; FAIL=1
  fi
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "self-update: all passed" || echo "self-update: FAILURES"
[ "$FAIL" -eq 0 ]
