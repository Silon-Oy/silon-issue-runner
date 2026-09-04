#!/usr/bin/env bash
# test-host.sh — lib/host.sh: the one resolver for this machine's short hostname.
#
# WHY THIS IS TESTED AT ALL. run.json.host is the base of every ownership gate
# (CLAUDE.md section 5.6), and those gates are fail-closed: an EMPTY host reads
# as "another machine's run", not as "unknown", so every gate then leaves the
# run's artefacts on disk without a word. `hostname -s` is not portable — the
# flag does not exist on Windows — so the fallback chain, and the guarantee that
# the function never returns empty, is what keeps the gates working off macOS.
#
# The three fallback branches cannot be reached on the machine running the
# tests, so `hostname` is replaced with a PATH shim per case — the same idiom
# tests/test-stop-run.sh uses to give its sandbox a deterministic identity.
#
# Cases:
#   1. lib/host.sh parses and is side-effect-free to re-source
#   2. `hostname -s` works        -> its output, verbatim
#   3. `-s` fails, bare works     -> bare output, truncated at the first dot
#   4. neither works, COMPUTERNAME set -> COMPUTERNAME
#   5. nothing works at all       -> "unknown", never empty
#   6. a `hostname` that exits 0 with a usage message is not mistaken for a name
#   7. CRLF output is trimmed
#   8. every caller in the run code goes through runner_host
#
# Run: bash tests/test-host.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/lib/host.sh"

if [ ! -f "$LIB" ]; then
  echo "FAIL: lib/host.sh missing"
  exit 1
fi

WORK=$(mktemp -d -t host-lib.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

FAIL=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAIL=1; }

# ---- Case 1: parses, and sourcing it twice changes nothing ----
if bash -n "$LIB" 2>"$WORK/syntax.err"; then
  ok "case1 lib/host.sh parses"
else
  bad "case1 lib/host.sh does not parse:"
  sed 's/^/      /' "$WORK/syntax.err"
fi

# Re-sourcing has to be harmless: the callers form a chain (orchestrate.sh and
# lib/state.sh both source it), so the file is loaded more than once per process.
if out=$(bash -c '. "$1"; . "$1"; runner_host' _ "$LIB" 2>&1) && [ -n "$out" ]; then
  ok "case1 re-sourcing is side-effect-free (got '$out')"
else
  bad "case1 re-sourcing failed: $out"
fi

# run_case <description> <expected> <hostname-shim-body> [env-assignment…]
# Runs runner_host in a child shell whose PATH puts a stub `hostname` first, so
# the real command is unreachable. Asserts stdout AND rc, because a caller that
# has `set -e` on must not be aborted by the fallback path.
run_case() {
  local desc="$1" want="$2" body="$3"; shift 3
  local got rc
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$WORK/bin/hostname"
  chmod +x "$WORK/bin/hostname"
  got=$(env "$@" PATH="$WORK/bin:$PATH" bash -c '. "$1"; runner_host' _ "$LIB" 2>/dev/null)
  rc=$?
  if [ "$got" = "$want" ] && [ "$rc" -eq 0 ]; then
    ok "$desc"
  else
    bad "$desc (got '$got' rc=$rc, expected '$want' rc=0)"
  fi
}

# ---- Case 2: `hostname -s` works — the unchanged macOS/Linux path ----
run_case "case2 hostname -s wins" "short-name" '
if [ "${1:-}" = "-s" ]; then echo short-name; else echo short-name.example.test; fi
' -u COMPUTERNAME

# ---- Case 3: `-s` unsupported, bare `hostname` gives an FQDN ----
# Windows hostname.exe has no -s. The FQDN is cut at the first dot so the value
# still matches the short-name globs RUN_ISSUES_POLLER_HOSTS is written with.
run_case "case3 bare hostname, truncated at the first dot" "fqdn-box" '
if [ "${1:-}" = "-s" ]; then echo "hostname: invalid option -- s" >&2; exit 1; fi
echo fqdn-box.corp.example
' -u COMPUTERNAME

# ---- Case 4: hostname unusable entirely, COMPUTERNAME set ----
run_case "case4 COMPUTERNAME is the third branch" "WINBOX" '
echo "hostname: not available" >&2
exit 1
' COMPUTERNAME=WINBOX

# ---- Case 5: nothing resolves -> "unknown", and never the empty string ----
# The last resort makes all such machines share one host value, which the gate
# cannot tell apart. That is deliberate and strictly better than an empty field,
# which makes every machine foreign to its own runs.
run_case "case5 unknown is the last resort" "unknown" '
exit 1
' -u COMPUTERNAME

# ---- Case 6: a usage message printed on stdout with rc 0 is not a hostname ----
# This is the failure mode that motivates validating the candidate rather than
# just testing it for emptiness: a `hostname` that does not know the flag but
# still exits 0 would otherwise put its own error text into run.json.host.
run_case "case6 a usage message on stdout is rejected" "WINBOX" '
if [ "${1:-}" = "-s" ]; then echo "hostname: illegal option -- s"; exit 0; fi
echo "usage: hostname [-s]"
' COMPUTERNAME=WINBOX

# ---- Case 7: CRLF from a Windows-built tool is trimmed ----
# Command substitution strips the trailing LF but not the CR, and a stray CR in
# run.json.host would make every string comparison in the gates miss.
run_case "case7 a trailing CR is stripped" "crlf-box" '
if [ "${1:-}" = "-s" ]; then printf "crlf-box\r\n"; else printf "crlf-box.example\r\n"; fi
' -u COMPUTERNAME

# ---- Case 8: no caller in the run code calls `hostname -s` itself ----
# The point of the module is that the host gate and the run.json write can never
# disagree, which only holds while every call goes through it. The search is
# restricted to shell sources: prose that NAMES the command (this file's own
# header, CLAUDE.md, README.md, docs/) is not a call. Tests are out of scope too
# — a fixture computing its own identity is not run code.
strays=$(cd "$ROOT" && git grep -ln 'hostname -s' -- '*.sh' 2>/dev/null \
  | grep -v -e '^tests/' -e '^lib/host\.sh$')
if [ -z "$strays" ]; then
  ok "case8 lib/host.sh is the only run-code caller of hostname -s"
else
  bad "case8 these files still call hostname -s directly:"
  printf '      %s\n' $strays
fi

# The gate's own comparison must use it too, or the gate and the record could
# disagree about what this machine is called.
gate_callers=$(cd "$ROOT" && grep -l 'poller_host_allowed' -- *.sh 2>/dev/null | grep -v '^install.sh$')
for f in $gate_callers; do
  if grep -q 'runner_host' "$ROOT/$f"; then
    ok "case8 $f gates on runner_host"
  else
    bad "case8 $f calls poller_host_allowed without runner_host"
  fi
done

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "host: all passed" || echo "host: FAILURES"
[ "$FAIL" -eq 0 ]
