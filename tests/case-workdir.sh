#!/usr/bin/env bash
# tests/case-workdir.sh — a fresh per-case work directory that cannot inherit a
# previous case's TMPDIR. Not a test: the suite runner globs `test-*.sh`, so
# this name keeps it out of the run and available to `.`-source.
#
# WHY. A test file whose setup() does `WORK=$(mktemp -d -t …)` and then
# `export TMPDIR="$WORK/tmp"` leaks that TMPDIR into the next case, after
# done_case has removed $WORK. GNU `mktemp -t` requires $TMPDIR to exist and
# fails; BSD `mktemp -t` silently falls back to the system default. So on Linux
# every other case ran with an empty WORK, and its paths collapsed onto the
# filesystem root (`/repo`, `/created`, `/bin/claude-mock`) — while macOS stayed
# green (#426).
#
# The fix has two halves: the root is captured ONCE, at source time, before any
# case exports its own TMPDIR; and the template is an explicit path (no `-t`),
# which GNU and BSD read the same way. A failed or empty result exits the test
# file at once instead of continuing with WORK="".
#
# Source this before the first setup(). Functions only, apart from the root.

CASE_TMPDIR_ROOT="${CASE_TMPDIR_ROOT:-${TMPDIR:-/tmp}}"
CASE_TMPDIR_ROOT="${CASE_TMPDIR_ROOT%/}"

# case_workdir <prefix> — sets WORK to a new directory under CASE_TMPDIR_ROOT.
# Assigns WORK directly rather than printing it: inside `$(…)` the exit below
# would only leave the subshell, and the caller would carry on with WORK="".
case_workdir() {
  WORK=$(mktemp -d "$CASE_TMPDIR_ROOT/$1.XXXXXX") || WORK=""
  if [ -z "$WORK" ] || [ ! -d "$WORK" ]; then
    echo "FATAL: cannot create a work directory under '$CASE_TMPDIR_ROOT' for '$1'" >&2
    exit 1
  fi
}
