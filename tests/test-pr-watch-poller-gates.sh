#!/usr/bin/env bash
# test-pr-watch-poller-gates.sh — the PR-watch poller must switch the merge
# gates ON (issue #372).
#
# pr-watch.sh defaults every PR_WATCH_ENABLE_* switch OFF; the poller flips them
# ON by splicing them into the per-repo tmux command. If a refactor drops one,
# every other test stays green and auto-merge PRs merge in production without
# the gate — a failure that looks like a pass. This test reads the command the
# poller actually launches.
#
# The switch set is DERIVED from the poller's `"${PR_WATCH_ENABLE_X:-1}"`
# defaults, not listed here, and the derivation is fail-closed: fewer than four
# switches or a missing anchor fails the test instead of passing on an empty set.
#
# Cases:
#   1  default run: every derived switch reaches the command as X='1'
#   2  per switch: `export X=0` in poller.env reaches the command as X='0',
#      and every other switch stays '1'
#
# Offline: gh and tmux are PATH shims, git runs only on a fixture repo.
# Run: bash tests/test-pr-watch-poller-gates.sh   (exit 0 = all pass)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

for req in jq git; do
  if ! command -v "$req" >/dev/null 2>&1; then
    echo "SKIP: $req not installed"
    exit 0
  fi
done

WORK=$(mktemp -d -t prwatch-gates.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAIL=1; }

# ---- derive the switch set from the code ------------------------------------
ANCHOR=PR_WATCH_ENABLE_SECURITY_GATE
SWITCHES="$(grep -oE '"\$\{PR_WATCH_ENABLE_[A-Z_]+:-1\}"' "$ROOT/pr-watch-poller.sh" \
  | sed 's/^"\${//; s/:-1}"$//' | sort -u)"
COUNT="$(printf '%s\n' "$SWITCHES" | grep -c '[A-Z]')"
if [ "$COUNT" -lt 4 ] || ! printf '%s\n' "$SWITCHES" | grep -qx "$ANCHOR"; then
  bad "switch derivation broke — got $COUNT switch(es), anchor '$ANCHOR' missing?"
  printf '%s\n' "$SWITCHES" | sed 's/^/      derived: /'
  exit 1
fi
ok "derived $COUNT switches from pr-watch-poller.sh ($(printf '%s' "$SWITCHES" | tr '\n' ' '))"

# ---- stubs ------------------------------------------------------------------
mkdir -p "$WORK/tmp" "$WORK/git-home" "$WORK/home"
BIN="$WORK/bin"; mkdir -p "$BIN"
CMDLOG="$WORK/tmux-cmd.log"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH

# tmux: no sessions exist; new-session records its last argument (the command).
cat > "$BIN/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  ls|list-sessions|has-session) exit 1 ;;
  new-session) for a in "\$@"; do last="\$a"; done; printf '%s\n' "\$last" >> "$CMDLOG" ;;
esac
exit 0
SH
chmod +x "$BIN/gh" "$BIN/tmux"

# ---- fixture ----------------------------------------------------------------
REPO="$WORK/repos/gated"
mkdir -p "$REPO"
HOME="$WORK/git-home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
  git -C "$REPO" init -q >/dev/null 2>&1
HOME="$WORK/git-home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
  git -C "$REPO" remote add origin git@github.com:example-org/gated.git >/dev/null 2>&1

WL="$WORK/watchlist.json"
cat > "$WL" <<JSON
{ "global_max_concurrent": 2,
  "repos": [ {"path":"$REPO","labels":["auto-run"],"remotes":["origin"]} ] }
JSON

# run_tick <poller.env path> — one poller invocation from an empty environment;
# prints the single launched command.
run_tick() {
  : > "$CMDLOG"
  env -i \
    PATH="$BIN:$PATH" \
    HOME="$WORK/home" \
    TMPDIR="$WORK/tmp" \
    RUN_ISSUES_LOCK_ROOT="$WORK/locks" \
    RUN_ISSUES_POLLER_HOSTS='*' \
    RUN_ISSUES_LOG_DIR="$WORK/logs" \
    RUN_ISSUES_WATCHLIST="$WL" \
    RUN_ISSUES_POLLER_ENV_FILE="$1" \
    bash "$ROOT/pr-watch-poller.sh" >/dev/null 2>&1
  cat "$CMDLOG"
}

# expect <cmd> <switch> <value> <label>
expect() {
  case " $1" in
    *" $2='$3'"*) ok "$4: $2='$3'" ;;
    *) bad "$4: command lacks $2='$3' — got: ${1:-<no launch>}" ;;
  esac
}

# ---- case 1: defaults --------------------------------------------------------
CMD="$(run_tick "$WORK/no-such-poller.env")"
while IFS= read -r sw; do
  expect "$CMD" "$sw" 1 "default"
done <<< "$SWITCHES"

# ---- case 2: poller.env =0 disables exactly that switch ----------------------
while IFS= read -r off; do
  ENVF="$WORK/poller-$off.env"
  printf 'export %s=0\n' "$off" > "$ENVF"
  CMD="$(run_tick "$ENVF")"
  while IFS= read -r sw; do
    if [ "$sw" = "$off" ]; then
      expect "$CMD" "$sw" 0 "poller.env $off=0"
    else
      expect "$CMD" "$sw" 1 "poller.env $off=0"
    fi
  done <<< "$SWITCHES"
done <<< "$SWITCHES"

# ---- case 3: every non-empty PR_WATCH_* setting in poller.env rides along ----
# One rule over the namespace (issue #375): a setting the poller does not name
# still reaches pr-watch.sh, an empty one does not (it would mask the machine
# env file), and a quote in a value stays inside its word.
ENVF="$WORK/poller-settings.env"
cat > "$ENVF" <<'ENV'
export PR_WATCH_SECURITY_REVIEWER=codex
export PR_WATCH_SEMANTIC_HOLD_MIN_SEVERITY=high
export PR_WATCH_SEMANTIC_REVIEW_TIMEOUT=900
export PR_WATCH_CI_POLL_SECS=
export PR_WATCH_TEST_QUOTED="it's; touch /tmp/never"
ENV
CMD="$(run_tick "$ENVF")"
expect "$CMD" PR_WATCH_SECURITY_REVIEWER codex "poller.env setting"
expect "$CMD" PR_WATCH_SEMANTIC_HOLD_MIN_SEVERITY high "poller.env setting"
expect "$CMD" PR_WATCH_SEMANTIC_REVIEW_TIMEOUT 900 "poller.env setting"
case "$CMD" in
  *PR_WATCH_CI_POLL_SECS=*) bad "empty setting forwarded — would mask the env file: $CMD" ;;
  *) ok "empty setting not forwarded" ;;
esac
# The launched command's prefixes, run by a shell (with `env` in place of the
# watcher), must hand over the quoted value intact.
GOT="$(bash -c "${CMD% \'*/pr-watch.sh\' --remote*} env" 2>/dev/null | sed -n 's/^PR_WATCH_TEST_QUOTED=//p')"
if [ "$GOT" = "it's; touch /tmp/never" ]; then
  ok "quoted value reaches the watcher as one word"
else
  bad "quoted value broke the command line — got '$GOT' from: $CMD"
fi

exit "$FAIL"
