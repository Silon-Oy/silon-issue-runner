#!/usr/bin/env bash
# run-all.sh — run every /run-issues test in this directory.
#
# Plain bash, no test framework. Each test-*.sh exits 0 on pass, non-zero on
# failure (or prints SKIP and exits 0 when its prerequisites are absent, e.g.
# no local DB). Returns non-zero if any test fails.
#
# WHY THE FILES RUN IN PARALLEL
# -----------------------------
# The suite is bound by process creation, not by CPU. Measured on one CI run of
# the same 92 files: 4.1 min on macOS, 20.3 min on Windows, and the 63 files
# that finish in under a second on macOS still averaged 6.3 s each under Git
# Bash. A tax that lands on a file doing nothing is not the file's work — it is
# the per-spawn cost of MSYS emulating fork(), paid once per jq, git, grep and
# gh shim, of which every assertion here spawns several. The runner cannot make
# a spawn cheaper; the only lever it owns is overlapping the waiting.
#
# Overlapping is safe by construction rather than by convention: every test
# builds its own mktemp tree, points HOME and the RUN_ISSUES_* paths inside it,
# and asks the kernel for an ephemeral port where it binds one. No test writes a
# fixed path outside its own tree — that is also what keeps the suite runnable
# on a machine where the poller is live, so it is a property the suite already
# had to have.
#
# RUN_ISSUES_TEST_JOBS=1 restores serial execution AND live, unbuffered output:
# in parallel a file's output is held back and printed as one block when it
# finishes, which is right for reading results and wrong for watching a test
# that hangs. Reach for it when you are debugging one, not when you are running
# the suite.
#
# Run: bash tests/run-all.sh   (exit 0 = all passed)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Windows/Git Bash: jq's output is CRLF unless it is given --binary, and the
# tests read jq output as heavily as the code does — both directly and through
# the `gh` shims they write and then execute. The shim exports itself on that
# platform, so sourcing it once here reaches every test process and every
# process a test spawns. On macOS and Linux this line defines nothing.
# A single test run BY HAND on Windows (`bash tests/test-x.sh`) does not pass
# through here; run it as `bash tests/run-all.sh` or source the shim first.
# shellcheck source=../lib/jq-binary.sh
. "$HERE/../lib/jq-binary.sh"

# ---------------------------------------------------------------------------
# Pool size
# ---------------------------------------------------------------------------
# Default to TWICE the machine's cores, because the work is waiting rather than
# computing: a worker blocked in fork()/exec() leaves its core idle, so one
# worker per core leaves the machine half asleep. Measured on a 14-core machine,
# same 92 files: 7 workers 40 s, 14 workers 34 s, 28 workers 30 s. The cap of 32
# is a guard rather than a measured optimum — past it the wall clock is bounded
# by the slowest single file anyway, which the summary line names.
#
# Five probes, the HIGHEST valid answer wins, and the winner is named in the
# summary line. The naming is the part that earns its keep: the pool ran two
# files at a time on the Windows runner for two runs, and "2" is
# indistinguishable between a two-core machine and a probe that answered wrong —
# only the source told us which (nproc, and the runner really does have two
# cores against macOS's three). Taking the highest answer rather than the first
# is the cheap half of the same idea: no single probe can pin the pool low.
#
# Caveat the override exists for: under a CPU-quota'd container the highest
# answer can exceed the quota, because /proc/cpuinfo counts the host's cores.
# There RUN_ISSUES_TEST_JOBS is the answer.
JOBS_DETECTED=0
JOBS_SOURCE=floor
detect_jobs() {
  local probe label value
  for probe in "nproc:$(nproc 2>/dev/null || true)" \
               "getconf:$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)" \
               "sysctl:$(sysctl -n hw.ncpu 2>/dev/null || true)" \
               "cpuinfo:$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || true)" \
               "env:${NUMBER_OF_PROCESSORS:-}"; do
    label="${probe%%:*}"
    value="${probe#*:}"
    case "$value" in ''|*[!0-9]*) continue ;; esac
    [ "$value" -gt "$JOBS_DETECTED" ] || continue
    JOBS_DETECTED="$value"
    JOBS_SOURCE="$label x2"
  done
}
detect_jobs
JOBS_DETECTED=$((JOBS_DETECTED * 2))
[ "$JOBS_DETECTED" -lt 2 ]  && JOBS_DETECTED=2
[ "$JOBS_DETECTED" -gt 32 ] && JOBS_DETECTED=32

JOBS="${RUN_ISSUES_TEST_JOBS:-$JOBS_DETECTED}"
# An unreadable value must not silently pick a pool size for the operator: fall
# back to the one mode that behaves exactly like no pool at all.
case "$JOBS" in ''|*[!0-9]*|0) JOBS=1; JOBS_SOURCE=fallback ;; esac
[ -n "${RUN_ISSUES_TEST_JOBS:-}" ] && [ "$JOBS_SOURCE" != fallback ] \
  && JOBS_SOURCE=RUN_ISSUES_TEST_JOBS

# `wait -n` (bash >= 4.3) blocks until one worker finishes without spawning
# anything. The macOS runner ships bash 3.2, which has no such builtin, so there
# the pool polls instead — a spawn per 0.2 s is affordable on the platform where
# spawns are cheap, which is the same platform that lacks the builtin.
HAVE_WAIT_N=0
if [ "${BASH_VERSINFO[0]}" -gt 4 ] \
  || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 3 ]; }; then
  HAVE_WAIT_N=1
fi

TESTS=()
for t in "$HERE"/test-*.sh; do TESTS+=("$t"); done
TOTAL=${#TESTS[@]}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/run-issues-suite.XXXXXX")" || exit 1
mkdir -p "$WORK/log" "$WORK/rc" "$WORK/running"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# An interrupted run must name the files that were still going: in parallel the
# output of an unfinished file has not been printed yet, so without this the
# hang is invisible.
on_signal() {
  trap - INT TERM
  echo
  echo "interrupted — still running:"
  ls "$WORK/running" 2>/dev/null | sed 's/^/  /'
  # shellcheck disable=SC2046  # word splitting is the point: one kill per pid
  kill $(jobs -p) 2>/dev/null
  cleanup
  exit 130
}
trap on_signal INT TERM

header() {
  echo "================================================================"
  echo "RUN  $1"
  echo "================================================================"
}
footer() {
  if [ "$2" -eq 0 ]; then echo ">>> $1: OK (${3}s)"; else echo ">>> $1: FAILED (${3}s)"; fi
  echo
}

# One writer at a time, so a block cannot be interleaved with another's. The
# bound matters more than the lock: a worker killed mid-print would otherwise
# wedge every remaining file behind a directory nobody will remove.
emit() {
  local name="$1" rc="$2" secs="$3" waited=0
  while ! mkdir "$WORK/print.lock" 2>/dev/null; do
    sleep 0.05
    waited=$((waited + 1))
    [ "$waited" -gt 400 ] && break
  done
  header "$name"
  cat "$WORK/log/$name"
  # A file whose last write has no newline would otherwise glue the footer onto
  # it, and the footer is the line a reader greps for at the start of a line.
  if [ -s "$WORK/log/$name" ] && [ "$(tail -c1 "$WORK/log/$name" | wc -l)" -eq 0 ]; then
    echo
  fi
  footer "$name" "$rc" "$secs"
  rmdir "$WORK/print.lock" 2>/dev/null
}

run_one() {
  local t="$1" name rc
  name="$(basename "$t")"
  : > "$WORK/running/$name"
  SECONDS=0
  if [ "$JOBS" -eq 1 ]; then
    header "$name"
    bash "$t" < /dev/null
    rc=$?
    footer "$name" "$rc" "$SECONDS"
  else
    bash "$t" < /dev/null > "$WORK/log/$name" 2>&1
    rc=$?
    emit "$name" "$rc" "$SECONDS"
  fi
  printf '%s %s\n' "$rc" "$SECONDS" > "$WORK/rc/$name"
  rm -f "$WORK/running/$name"
}

throttle() {
  if [ "$HAVE_WAIT_N" -eq 1 ]; then
    [ "$RUNNING" -ge "$JOBS" ] || return 0
    wait -n >/dev/null 2>&1
    RUNNING=$((RUNNING - 1))
  else
    while [ "$(jobs -pr | wc -l | tr -d '[:space:]')" -ge "$JOBS" ]; do sleep 0.2; done
    RUNNING="$(jobs -pr | wc -l | tr -d '[:space:]')"
  fi
}

START="$(date +%s)"
RUNNING=0
for t in "${TESTS[@]}"; do
  throttle
  run_one "$t" &
  RUNNING=$((RUNNING + 1))
done
wait

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
# Read back in glob order, so the tally is deterministic even though the blocks
# above arrived in completion order.
ELAPSED=$(( $(date +%s) - START ))
FAIL=0
FAILED_NAMES=""
SLOWEST=""
for t in "${TESTS[@]}"; do
  name="$(basename "$t")"
  if [ -r "$WORK/rc/$name" ]; then
    read -r rc secs < "$WORK/rc/$name"
  else
    # No result file: the worker died without recording one. Unknown is a
    # failure here — a file that did not report cannot be called green.
    rc=1; secs=0
    echo ">>> $name: NO RESULT (worker died before recording one)"
  fi
  [ "$rc" -eq 0 ] || { FAIL=1; FAILED_NAMES="$FAILED_NAMES $name"; }
  SLOWEST="$SLOWEST$secs $name
"
done

echo "----------------------------------------"
printf '%s files, %ss wall, %s at a time (%s)\n' "$TOTAL" "$ELAPSED" "$JOBS" "$JOBS_SOURCE"
# The three that set the floor: with a pool, the wall clock cannot drop below
# the slowest single file, so this line is where the next speedup is visible.
printf 'slowest: %s\n' "$(printf '%s' "$SLOWEST" | sort -rn | head -3 \
  | awk '{ printf "%s%s %ss", (NR > 1 ? ", " : ""), $2, $1 }')"
if [ "$FAIL" -eq 0 ]; then
  echo "ALL TESTS PASSED"
else
  echo "FAILED:$FAILED_NAMES"
  echo "SOME TESTS FAILED"
fi
exit "$FAIL"
