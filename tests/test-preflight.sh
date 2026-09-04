#!/usr/bin/env bash
# test-preflight.sh — lib/preflight.sh, the shared dependency probe.
#
# The module is deliberately pure (no writes, no exits, no globals) so that two
# very different callers can share it without either constraining the other:
# install.sh treats every finding as advisory, while the orchestrator's S0 gate
# treats a required miss as fatal. The return-code contract below (0 / 1 / 2) is
# what makes that split possible, so it is asserted explicitly.
#
# Cases:
#   1. preflight_have: PATH shim -> 0, unknown command -> 1, never prints
#   2. preflight_timeout_bin: reports timeout|gtimeout|"", empty PATH is not an
#      error (an unset variable here would abort a caller running `set -u`),
#      and acceptance is a `--version` probe rather than a name on PATH — the
#      name `timeout` belongs to a Windows delay tool that Git Bash puts on
#      PATH via System32, so an existence check would wrap claude calls in it
#   3. preflight_report_tool: line format and the 0/1/2 return-code contract
#   4. preflight_install_hint: exact fix commands (install.sh and the S0 gate
#      both quote these, so the strings are part of the module's contract)
#   5. preflight_gate_report have: every required miss is reported and fatal
#   6. preflight_gate_report probe: a present npx with an absent package is the
#      failure `command -v` cannot see, so it must still be fatal
#   7. preflight_gate_report: an absent timeout binary is a WARNING, never
#      fatal — regression guard for the pre-gate behaviour (unbounded claude
#      calls are allowed to keep running)
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

# A binary that merely carries the name is not enough. The absolute interpreter
# path is required for the same reason as in case 6: PATH holds only the shim
# dir, so `env bash` would not resolve.
mkdir -p "$WORK/gnu"
printf '#!/bin/bash\nexit 1\n' > "$WORK/gnu/timeout"
chmod +x "$WORK/gnu/timeout"

tb_bad=$(PATH="$WORK/gnu" preflight_timeout_bin)
if [ -z "$tb_bad" ]; then
  echo "PASS: case2 a 'timeout' that rejects --version is not accepted"
else
  echo "FAIL: case2 accepted a non-GNU 'timeout' as '$tb_bad'"; FAIL=1
fi

printf '#!/bin/bash\n[ "$1" = "--version" ] && { echo "timeout (GNU coreutils) 9.9"; exit 0; }\nshift\nexec "$@"\n' \
  > "$WORK/gnu/gtimeout"
chmod +x "$WORK/gnu/gtimeout"

tb_fallback=$(PATH="$WORK/gnu" preflight_timeout_bin)
if [ "$tb_fallback" = "gtimeout" ]; then
  echo "PASS: case2 falls through a rejecting 'timeout' to a GNU 'gtimeout'"
else
  echo "FAIL: case2 reported '$tb_fallback' (expected 'gtimeout')"; FAIL=1
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

# ---- Case 4: preflight_install_hint ----
check_hint() {
  local key="$1" want="$2" got
  got=$(preflight_install_hint "$key")
  if [ "$got" = "$want" ]; then
    echo "PASS: case4 hint for '$key' is '$want'"
  else
    echo "FAIL: case4 hint for '$key' was '$got' (expected '$want')"; FAIL=1
  fi
}
check_hint jq 'brew install jq'
check_hint claude 'npm i -g @anthropic-ai/claude-code'
check_hint gh-auth 'gh auth login'
check_hint timeout 'brew install coreutils (Git Bash on Windows: scoop install coreutils)'

out=$(preflight_install_hint run-issues-no-such-key 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && [ -z "$out" ]; then
  echo "PASS: case4 unknown key returns 1 without output"
else
  echo "FAIL: case4 unknown key: rc=$rc out='$out'"; FAIL=1
fi

# ---- Case 5: preflight_gate_report, have mode ----
# An empty PATH makes the case machine-independent: it must not matter where
# this machine happens to keep jq.
out=$(PATH="" preflight_gate_report have /nonexistent/claude)
rc=$?
if [ "$rc" -eq 2 ]; then
  echo "PASS: case5 missing required tools return 2"
else
  echo "FAIL: case5 returned $rc (expected 2)"; FAIL=1
fi
for want in 'MISSING (required): git' 'MISSING (required): gh' 'MISSING (required): jq' \
            'MISSING (required): /nonexistent/claude'; do
  if printf '%s\n' "$out" | grep -qF "$want"; then
    echo "PASS: case5 reports '$want'"
  else
    echo "FAIL: case5 did not report '$want' — got: $out"; FAIL=1
  fi
done
if printf '%s\n' "$out" | grep -qF 'npm i -g @anthropic-ai/claude-code'; then
  echo "PASS: case5 carries the claude fix command"
else
  echo "FAIL: case5 lost the claude fix command — got: $out"; FAIL=1
fi
if printf '%s\n' "$out" | grep -q '^ok: '; then
  echo "FAIL: case5 printed an 'ok:' line (findings only)"; FAIL=1
else
  echo "PASS: case5 prints findings only, no 'ok:' noise"
fi

# ---- Case 6: preflight_gate_report, probe mode ----
# The probe mode EXECUTES its stubs, and these cases run with a PATH that
# contains nothing but the stub dir (case 7 needs a PATH with no timeout binary
# at all, which rules out borrowing /usr/bin). A `#!/usr/bin/env bash` shebang
# would then fail with 127 because `env` resolves `bash` through that same
# empty PATH — an interpreter failure indistinguishable from the missing-package
# 127 this case is about. Hence the absolute interpreter path.
mkdir -p "$WORK/probe"
for tool in git gh jq; do
  printf '#!/bin/bash\nexit 0\n' > "$WORK/probe/$tool"
  chmod +x "$WORK/probe/$tool"
done
# A real timeout must forward the probed command's exit code, otherwise the
# stub would mask the very 127 under test. It must also answer `--version`
# explicitly: preflight_timeout_bin only accepts a GNU binary, and leaving that
# to `shift; exec` with no arguments (which returns 0 by accident) would make
# case 6's subject depend on a coincidence.
printf '#!/bin/bash\n[ "$1" = "--version" ] && { echo "timeout (GNU coreutils) 9.9"; exit 0; }\nshift\nexec "$@"\n' \
  > "$WORK/probe/timeout"
chmod +x "$WORK/probe/timeout"
# npx present but the package absent: exactly the silent 127 that a
# `command -v npx` check cannot detect.
printf '#!/bin/bash\nexit 127\n' > "$WORK/probe/npx"
chmod +x "$WORK/probe/npx"

out=$(PATH="$WORK/probe" preflight_gate_report probe npx --no-install @anthropic-ai/claude-code)
rc=$?
if [ "$rc" -eq 2 ]; then
  echo "PASS: case6 an installed npx with a missing package is still fatal"
else
  echo "FAIL: case6 returned $rc (expected 2) — out: $out"; FAIL=1
fi
if printf '%s\n' "$out" | grep -qF 'npm i -g @anthropic-ai/claude-code'; then
  echo "PASS: case6 names the package fix command"
else
  echo "FAIL: case6 did not name the package fix command — got: $out"; FAIL=1
fi

printf '#!/bin/bash\nexit 0\n' > "$WORK/probe/npx"
chmod +x "$WORK/probe/npx"
out=$(PATH="$WORK/probe" preflight_gate_report probe npx --no-install @anthropic-ai/claude-code)
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  echo "PASS: case6 a complete environment reports nothing and returns 0"
else
  echo "FAIL: case6 complete environment: rc=$rc out='$out'"; FAIL=1
fi

# ---- Case 7: a missing timeout binary warns but never blocks ----
rm -f "$WORK/probe/timeout"
out=$(PATH="$WORK/probe" preflight_gate_report probe npx --no-install @anthropic-ai/claude-code)
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "PASS: case7 a missing timeout binary is not fatal"
else
  echo "FAIL: case7 returned $rc (expected 0) — a missing timeout must stay a warning"; FAIL=1
fi
if printf '%s\n' "$out" | grep -qF 'MISSING (optional): timeout/gtimeout'; then
  echo "PASS: case7 warns about the missing timeout binary"
else
  echo "FAIL: case7 did not warn about the timeout binary — got: $out"; FAIL=1
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "preflight: all passed" || echo "preflight: FAILURES"
[ "$FAIL" -eq 0 ]
