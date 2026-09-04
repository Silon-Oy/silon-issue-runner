#!/usr/bin/env bash
# run-all.sh — run every /run-issues test in this directory.
#
# Plain bash, no test framework. Each test-*.sh exits 0 on pass, non-zero on
# failure (or prints SKIP and exits 0 when its prerequisites are absent, e.g.
# no local DB). Returns non-zero if any test fails.

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

FAIL=0

for t in "$HERE"/test-*.sh; do
  echo "================================================================"
  echo "RUN  $(basename "$t")"
  echo "================================================================"
  if bash "$t"; then
    echo ">>> $(basename "$t"): OK"
  else
    echo ">>> $(basename "$t"): FAILED"
    FAIL=1
  fi
  echo
done

[ "$FAIL" -eq 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit "$FAIL"
