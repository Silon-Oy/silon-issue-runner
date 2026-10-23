#!/usr/bin/env bash
# test-env-hermeticity.sh — no test reads this machine's env file, and no test
# hangs on an open stdin (issue #358, CLAUDE.md §5.5 and §12).
#
# Three leaks this guards, each invisible on CI and real on a developer machine:
#
#   1. The machine env file. orchestrate.sh, pr-watch.sh and the audit entry
#      points source $RUN_ISSUES_ENV_FILE, default $HOME/.config/run-issues/env.
#      A test that does not pin it loads the machine's secrets into the test
#      process and lets the machine's settings decide the result. Pinning means
#      a path that does NOT exist — an empty value falls back to the default,
#      because the lookup is `${RUN_ISSUES_ENV_FILE:-…}`.
#   2. An inherited stdin. claude_call's agent used to inherit the caller's
#      stdin, and the stub agents read it with `cat`; under a tool whose stdin
#      is a pipe that never reaches EOF the whole suite stalled (280 s of
#      silence from test-serialize.sh). The agent now gets /dev/null.
#   3. S3's fixed 5 s claim-verify wait, now RUN_ISSUES_CLAIM_VERIFY_DELAY,
#      which every orchestrator-driving test sets to 0.
#
# Static half, derived from disk and fail-closed like test-jq-binary.sh: the
# entry points are the root scripts that call source_machine_env, the tests are
# every tests/test-*.sh that references one of them by its real path. A new
# test is covered the day it is added or this file is red.
#
# Dynamic half: representatives run with HOME pointed at a tree whose
# .config/run-issues/env is a canary (sourcing it leaves a mark) and with stdin
# an open FIFO whose writer never closes, under a watchdog.
#
# Run: bash tests/test-env-hermeticity.sh   (exit 0 = all pass)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SELF="$(basename "${BASH_SOURCE[0]}")"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }

# ---- 1. entry points that source the machine env file -----------------------
ENTRIES=()
while IFS= read -r f; do
  ENTRIES+=("$f")
done < <(cd "$ROOT" && grep -lE '^[[:space:]]*source_machine_env([[:space:]]|$)' ./*.sh 2>/dev/null \
           | sed 's|^\./||; s|\.sh$||')

has_entry() { local e; for e in "${ENTRIES[@]}"; do [ "$e" = "$1" ] && return 0; done; return 1; }
if [ "${#ENTRIES[@]}" -ge 4 ] && has_entry orchestrate && has_entry pr-watch; then
  ok "derived ${#ENTRIES[@]} env-sourcing entry points from disk (${ENTRIES[*]})"
else
  bad "entry-point derivation collapsed to '${ENTRIES[*]}' — the grep is broken, not the package"
fi

ENTRY_RE=$(IFS='|'; printf '%s' "${ENTRIES[*]}")
REF_RE='(\$HERE/\.\.|\$ROOT)/('"$ENTRY_RE"')\.sh'
ORCH_RE='(\$HERE/\.\.|\$ROOT)/orchestrate\.sh'

# ---- 2. every test referencing one pins the env file ------------------------
TESTS=()
while IFS= read -r f; do
  [ "$f" = "$SELF" ] && continue
  TESTS+=("$f")
done < <(cd "$HERE" && grep -lE "$REF_RE" test-*.sh 2>/dev/null)

if [ "${#TESTS[@]}" -ge 30 ]; then
  ok "derived ${#TESTS[@]} tests that reference an env-sourcing entry point"
else
  bad "test derivation collapsed to ${#TESTS[@]} — the grep is broken, not the suite"
fi

# first_line <file> <ERE> — line number of the first non-comment match, or 0.
first_line() {
  grep -nE "$2" "$1" | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1 | grep . || echo 0
}

for t in "${TESTS[@]}"; do
  f="$HERE/$t"
  pin=$(grep -nE '^export RUN_ISSUES_ENV_FILE="\$HERE/[^"$]+"$' "$f" | head -1)
  if [ -z "$pin" ]; then
    bad "$t: no top-level 'export RUN_ISSUES_ENV_FILE=\"\$HERE/…\"' — it reads \$HOME/.config/run-issues/env"
    continue
  fi
  pin_line=${pin%%:*}
  rel=$(printf '%s' "$pin" | sed -E 's|^[0-9]+:export RUN_ISSUES_ENV_FILE="\$HERE/([^"]+)"$|\1|')
  ref_line=$(first_line "$f" "$REF_RE")
  if [ -e "$HERE/$rel" ]; then
    bad "$t: pinned env file \$HERE/$rel exists — a pin must point at nothing"
  elif grep -qE '^[[:space:]]*unset([[:space:]].*)?[[:space:]]RUN_ISSUES_ENV_FILE([[:space:]]|$)' "$f"; then
    bad "$t: unsets RUN_ISSUES_ENV_FILE after pinning it"
  elif [ "$ref_line" -ne 0 ] && [ "$pin_line" -gt "$ref_line" ]; then
    bad "$t: the pin (line $pin_line) comes after the first entry-point reference (line $ref_line)"
  else
    ok "$t pins the env file"
  fi
  if grep -qE "$ORCH_RE" "$f"; then
    if grep -qE '^export RUN_ISSUES_CLAIM_VERIFY_DELAY=0$' "$f"; then
      ok "$t zeroes the S3 claim-verify wait"
    else
      bad "$t references orchestrate.sh but does not export RUN_ISSUES_CLAIM_VERIFY_DELAY=0"
    fi
  fi
done

# ---- 3. the production sides of the fix --------------------------------------
if grep -qF 'sleep "${RUN_ISSUES_CLAIM_VERIFY_DELAY:-5}"' "$ROOT/orchestrate.sh" \
   && ! grep -qE '^[[:space:]]*sleep 5$' "$ROOT/orchestrate.sh"; then
  ok "orchestrate.sh S3 waits RUN_ISSUES_CLAIM_VERIFY_DELAY, default 5"
else
  bad "orchestrate.sh S3 wait is not RUN_ISSUES_CLAIM_VERIFY_DELAY with default 5"
fi
if grep -qF '`RUN_ISSUES_CLAIM_VERIFY_DELAY` | `5` |' "$ROOT/docs/env-reference.md"; then
  ok "docs/env-reference.md documents RUN_ISSUES_CLAIM_VERIFY_DELAY"
else
  bad "docs/env-reference.md has no RUN_ISSUES_CLAIM_VERIFY_DELAY row"
fi
exec_line=$(grep -E '^[[:space:]]*exec "\$\{cmd\[@\]\}"' "$ROOT/lib/claude-call.sh")
case "$exec_line" in
  *'< /dev/null') ok "claude_call's agent exec reads stdin from /dev/null" ;;
  *)              bad "claude_call's agent exec inherits the caller's stdin" ;;
esac

# ---- 4. dynamic: canary HOME, open stdin, watchdog ---------------------------
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "SKIP  dynamic half: no FIFO semantics under MSYS; the static half still ran" ;;
  *)
    WORK=$(mktemp -d -t env-hermeticity.XXXXXX)
    HOLDERS=()
    cleanup() { local p; for p in ${HOLDERS[@]+"${HOLDERS[@]}"}; do kill "$p" 2>/dev/null; done; rm -rf "$WORK"; }
    trap cleanup EXIT
    LIMIT=240

    # run_rep <test-file> — sets RC (124 = watchdog) and the per-test canary/log.
    run_rep() {
      local t="$1" home="$WORK/home-${1%.sh}" fifo="$WORK/stdin-${1%.sh}" pid holder waited=0
      CANARY="$WORK/canary-${t%.sh}"; LOG="$WORK/log-${t%.sh}"
      mkdir -p "$home/.config/run-issues"
      printf ': > "%s"\n' "$CANARY" > "$home/.config/run-issues/env"
      chmod 600 "$home/.config/run-issues/env"
      mkfifo "$fifo"
      # The writer holds the FIFO open and never writes: a reader of stdin
      # blocks forever, exactly as under a tool that keeps the pipe open.
      sleep 3600 > "$fifo" &
      holder=$!; HOLDERS+=("$holder")
      # `set -m` puts the test in its own process group, so the watchdog can
      # kill the whole tree — a hung stub agent is a grandchild, and a kill of
      # the test alone would orphan it holding an hour-long agent timeout.
      set -m
      env -u RUN_ISSUES_ENV_FILE -u RUN_ISSUES_CLAIM_VERIFY_DELAY HOME="$home" \
        bash "$HERE/$t" < "$fifo" > "$LOG" 2>&1 &
      pid=$!
      set +m
      while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$LIMIT" ]; do
        sleep 1; waited=$((waited + 1))
      done
      if kill -0 "$pid" 2>/dev/null; then
        kill -TERM -- "-$pid" 2>/dev/null
        wait "$pid" 2>/dev/null; RC=124
      else
        wait "$pid"; RC=$?
      fi
      { kill "$holder"; wait "$holder"; } 2>/dev/null
    }

    # One orchestrator run through S8 (stub agent reads stdin with `cat`) and
    # one PR-watcher run.
    for rep in test-serialize.sh test-pr-watch-merge-fallback.sh; do
      [ -f "$HERE/$rep" ] || { bad "representative $rep is missing"; continue; }
      run_rep "$rep"
      if [ "$RC" = 124 ]; then
        bad "$rep hung on an open stdin (killed after ${LIMIT}s)"
      elif [ "$RC" != 0 ]; then
        bad "$rep failed (rc=$RC) under a canary HOME and open stdin — last lines: $(tail -3 "$LOG" | tr '\n' ' ')"
      else
        ok "$rep finishes with an open stdin"
      fi
      if [ -e "$CANARY" ]; then
        bad "$rep sourced \$HOME/.config/run-issues/env"
      else
        ok "$rep never sourced \$HOME/.config/run-issues/env"
      fi
    done ;;
esac

echo "----------------------------------------"
echo "env-hermeticity: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
