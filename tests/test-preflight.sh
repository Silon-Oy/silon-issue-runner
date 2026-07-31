#!/usr/bin/env bash
# test-preflight.sh — lib/preflight.sh, the shared dependency probe.
#
# The module is deliberately pure (no writes, no exits, no globals) so that two
# very different callers can share it without either constraining the other:
# install.sh treats every finding as advisory, while the planned doctor command
# treats a required miss as fatal. The return-code contract below (0 / 1 / 2) is
# what makes that split possible, so it is asserted explicitly.
#
# Cases:
#   1. preflight_have: PATH shim -> 0, unknown command -> 1, never prints
#   2. preflight_timeout_bin: reports timeout|gtimeout|"", empty PATH is not an
#      error (an unset variable here would abort a caller running `set -u`)
#   3. preflight_report_tool: line format and the 0/1/2 return-code contract
#
# Run: bash tests/test-preflight.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFLIGHT_LIB="$HERE/../lib/preflight.sh"

if [ ! -f "$PREFLIGHT_LIB" ]; then
  echo "FAIL: lib/preflight.sh missing"
  exit 1
fi

# shellcheck source=lib/preflight.sh
. "$PREFLIGHT_LIB"
# The lib sets -e for its production callers; a test must collect every failure.
set +e

WORK=$(mktemp -d -t preflight.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0

mkdir -p "$WORK/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/faketool"
chmod +x "$WORK/bin/faketool"
PATH="$WORK/bin:$PATH"

# ---- Case 1: preflight_have ----
preflight_have faketool
if [ $? -eq 0 ]; then
  echo "PASS: case1 preflight_have finds a PATH command"
else
  echo "FAIL: case1 preflight_have did not find faketool on PATH"; FAIL=1
fi

preflight_have run-issues-no-such-command
if [ $? -eq 1 ]; then
  echo "PASS: case1 preflight_have returns 1 for an unknown command"
else
  echo "FAIL: case1 preflight_have should return 1 for an unknown command"; FAIL=1
fi

out=$(preflight_have faketool 2>&1)
if [ -z "$out" ]; then
  echo "PASS: case1 preflight_have is silent"
else
  echo "FAIL: case1 preflight_have printed '$out' (callers own the output)"; FAIL=1
fi

# ---- Case 2: preflight_timeout_bin ----
tb=$(preflight_timeout_bin)
case "$tb" in
  timeout|gtimeout|"")
    echo "PASS: case2 preflight_timeout_bin reports a known value ('$tb')" ;;
  *)
    echo "FAIL: case2 preflight_timeout_bin reported '$tb'"; FAIL=1 ;;
esac

# An empty PATH must yield an empty string, not an unbound-variable abort.
tb_empty=$(PATH="" preflight_timeout_bin 2>"$WORK/tb.err")
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$tb_empty" ] && [ ! -s "$WORK/tb.err" ]; then
  echo "PASS: case2 empty PATH yields an empty result without error output"
else
  echo "FAIL: case2 empty PATH: rc=$rc out='$tb_empty' err='$(cat "$WORK/tb.err")'"; FAIL=1
fi

# ---- Case 3: preflight_report_tool ----
line=$(preflight_report_tool faketool required "should not matter")
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "PASS: case3 present tool returns 0"
else
  echo "FAIL: case3 present tool returned $rc (expected 0)"; FAIL=1
fi
if printf '%s\n' "$line" | grep -q '^ok: faketool$'; then
  echo "PASS: case3 present tool prints 'ok: <cmd>'"
else
  echo "FAIL: case3 present tool printed '$line'"; FAIL=1
fi

line=$(preflight_report_tool run-issues-no-such-command optional "only the pollers need it")
rc=$?
if [ "$rc" -eq 1 ]; then
  echo "PASS: case3 missing optional tool returns 1"
else
  echo "FAIL: case3 missing optional tool returned $rc (expected 1)"; FAIL=1
fi
if printf '%s\n' "$line" | grep -q '^MISSING (optional): run-issues-no-such-command '; then
  echo "PASS: case3 missing optional tool prints the optional marker"
else
  echo "FAIL: case3 missing optional tool printed '$line'"; FAIL=1
fi
if printf '%s\n' "$line" | grep -q 'only the pollers need it'; then
  echo "PASS: case3 hint is carried into the output"
else
  echo "FAIL: case3 hint missing from '$line'"; FAIL=1
fi

line=$(preflight_report_tool run-issues-no-such-command required "needed by orchestrate.sh")
rc=$?
if [ "$rc" -eq 2 ]; then
  echo "PASS: case3 missing required tool returns 2"
else
  echo "FAIL: case3 missing required tool returned $rc (expected 2)"; FAIL=1
fi
if printf '%s\n' "$line" | grep -q '^MISSING (required): run-issues-no-such-command '; then
  echo "PASS: case3 missing required tool prints the required marker"
else
  echo "FAIL: case3 missing required tool printed '$line'"; FAIL=1
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "preflight: all passed" || echo "preflight: FAILURES"
[ "$FAIL" -eq 0 ]
