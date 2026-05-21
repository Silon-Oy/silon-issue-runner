#!/usr/bin/env bash
# run-all.sh — run every /run-issues test in this directory.
#
# Plain bash, no test framework. Each test-*.sh exits 0 on pass, non-zero on
# failure (or prints SKIP and exits 0 when its prerequisites are absent, e.g.
# no local DB). Returns non-zero if any test fails.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
