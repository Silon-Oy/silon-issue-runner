#!/usr/bin/env bash
# test-jq-binary.sh — guard for lib/jq-binary.sh, the Windows CRLF shim.
#
# The shim exists because jq under Git Bash writes `\r\n` where the package
# expects `\n`, and the resulting failures are silent: a path that exists tests
# as absent, a watchlist entry stops matching its own repo, a count reads as
# non-numeric. Twelve test files were red on windows-latest for that one reason.
#
# The shim only helps a script that SOURCES it, so the coverage claim is what
# this file guards, and it guards it the way test-skill-labels.sh guards the
# label vocabulary: the entry-point set is DERIVED FROM DISK, not listed here.
# A new executable added to the package root is covered on the day it is added
# or this test is red — a hand-written list would have gone stale instead.
# Fail-closed: if the derivation returns implausibly few entry points, that is a
# broken test, not a passing one.
#
# Run: bash tests/test-jq-binary.sh   (exit 0 = all pass)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SHIM="$ROOT/lib/jq-binary.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }

# ---- 1. the shim exists and is side-effect free to source --------------------
if [ -f "$SHIM" ]; then ok "lib/jq-binary.sh exists"; else bad "lib/jq-binary.sh is missing"; fi

# ---- 2. entry-point coverage, derived from disk ------------------------------
# An entry point is an executable *.sh that is NOT a library and NOT a test: the
# package root plus db-clone/db-clone.sh, which is spawned as its own process.
# Every one of them must source the shim, because a bash function does not cross
# a process boundary on its own.
ENTRY_POINTS=()
while IFS= read -r f; do
  ENTRY_POINTS+=("$f")
done < <(cd "$ROOT" && ls -1 ./*.sh 2>/dev/null | sed 's|^\./||')
ENTRY_POINTS+=("db-clone/db-clone.sh")

# Fail-closed derivation: the package has had well over a dozen root scripts
# since the layout was fixed (CLAUDE.md section 2). A collapse to a handful
# means the glob stopped matching, and an empty set must not pass silently.
if [ "${#ENTRY_POINTS[@]}" -ge 12 ]; then
  ok "derived ${#ENTRY_POINTS[@]} entry points from disk"
else
  bad "entry-point derivation collapsed to ${#ENTRY_POINTS[@]} — the glob is broken, not the package"
fi

for f in "${ENTRY_POINTS[@]}"; do
  [ -f "$ROOT/$f" ] || { bad "$f: listed but absent"; continue; }
  if grep -q 'lib/jq-binary\.sh' "$ROOT/$f"; then
    ok "$f sources the shim"
  else
    bad "$f does not source lib/jq-binary.sh — its jq reads are CRLF on Windows"
  fi
done

# The suite runner carries it for every test process (and for the gh shims the
# tests write and execute).
if grep -q 'lib/jq-binary\.sh' "$ROOT/tests/run-all.sh"; then
  ok "tests/run-all.sh sources the shim"
else
  bad "tests/run-all.sh does not source lib/jq-binary.sh"
fi

# ---- 3. behaviour on this platform ------------------------------------------
# Sourcing must be side-effect free and must NOT shadow jq off Windows: `-b`
# is a hard error on jq < 1.7, so the shim must stay out of the way where the
# streams are already binary.
# `unset -f jq` first, in every probe below: tests/run-all.sh sources this same
# shim and it EXPORTS itself on Windows, so an inherited BASH_FUNC_jq would
# answer these questions instead of the source line under test.
BEHAVIOUR=$(bash -c 'unset -f jq; . "$1"; if declare -F jq >/dev/null 2>&1; then echo shadowed; else echo bare; fi' _ "$SHIM" 2>&1)
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) EXPECT=shadowed ;;
  *)                    EXPECT=bare ;;
esac
if [ "$BEHAVIOUR" = "$EXPECT" ]; then
  ok "on $(uname -s) the shim is '$EXPECT'"
else
  bad "on $(uname -s) expected '$EXPECT', got '$BEHAVIOUR'"
fi

# ---- 4. the Windows branch, simulated ---------------------------------------
# `uname` is called through PATH, so a stub is enough to take the MINGW branch
# on any machine. This is the only way the branch is exercised in a suite whose
# gate runs on macOS.
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed — the simulated Windows branch needs a real jq"
elif ! jq -b -n 1 >/dev/null 2>&1; then
  echo "SKIP: this jq has no --binary (jq < 1.7) — nothing to simulate against"
else
  STUB=$(mktemp -d "${TMPDIR:-/tmp}/jqbin.XXXXXX")
  trap 'rm -rf "$STUB"' EXIT
  # /bin/sh, not `env bash`: the no-jq case below runs with a PATH that holds
  # nothing but this stub, and a `#!/usr/bin/env` shebang would need `env` on it.
  printf '#!/bin/sh\necho MINGW64_NT-10.0-26100\n' > "$STUB/uname"
  chmod +x "$STUB/uname"

  SIM=$(PATH="$STUB:$PATH" bash -c 'unset -f jq; . "$1"; declare -F jq >/dev/null 2>&1 && echo shadowed || echo bare' _ "$SHIM" 2>&1)
  if [ "$SIM" = "shadowed" ]; then ok "simulated MINGW: jq is shadowed"; else bad "simulated MINGW: expected shadowed, got '$SIM'"; fi

  # The shadow must pass --binary through and keep jq's exit status, because
  # `jq -e` is used as a gate: a pipe-based fallback would report the pipe's.
  SIM_ARGS=$(PATH="$STUB:$PATH" bash -c '
    unset -f jq
    . "$1"
    printf "%s\n" "$(declare -f jq)"' _ "$SHIM" 2>&1)
  case "$SIM_ARGS" in
    *"command jq -b"*) ok "the shadow calls 'command jq -b'" ;;
    *)                 bad "the shadow does not pass -b: $SIM_ARGS" ;;
  esac

  RC_TRUE=$(PATH="$STUB:$PATH" bash -c 'unset -f jq; . "$1"; jq -e ".a" <<< "{\"a\":1}" >/dev/null 2>&1; echo $?' _ "$SHIM")
  RC_FALSE=$(PATH="$STUB:$PATH" bash -c 'unset -f jq; . "$1"; jq -e ".missing" <<< "{\"a\":1}" >/dev/null 2>&1; echo $?' _ "$SHIM")
  if [ "$RC_TRUE" = "0" ] && [ "$RC_FALSE" = "1" ]; then
    ok "the shadow preserves jq -e's exit status (0 / 1)"
  else
    bad "the shadow lost jq -e's exit status (present=$RC_TRUE, missing=$RC_FALSE)"
  fi

  # A machine with no jq at all must NOT get a function: `command -v jq` is the
  # package's installed-check in five places and would answer yes for one.
  EMPTY=$(mktemp -d "${TMPDIR:-/tmp}/jqnone.XXXXXX")
  cp "$STUB/uname" "$EMPTY/uname"
  NOJQ=$(PATH="$EMPTY" /bin/bash -c 'unset -f jq; . "$1"; declare -F jq >/dev/null 2>&1 && echo shadowed || echo bare' _ "$SHIM" 2>/dev/null | tail -1)
  rm -rf "$EMPTY"
  if [ "$NOJQ" = "bare" ]; then
    ok "no jq on PATH => no shadow (the installed-check stays honest)"
  else
    bad "no jq on PATH but the shim still shadowed it: '$NOJQ'"
  fi
fi

# ---- 5. preflight names an unusable jq --------------------------------------
# shellcheck source=../lib/preflight.sh
if ( set +u; . "$ROOT/lib/preflight.sh"; declare -F preflight_jq_binary_ok >/dev/null 2>&1 ); then
  ok "lib/preflight.sh defines preflight_jq_binary_ok"
else
  bad "lib/preflight.sh has no preflight_jq_binary_ok"
fi
if bash -c '. "$1"; preflight_jq_binary_ok' _ "$ROOT/lib/preflight.sh" >/dev/null 2>&1; then
  ok "preflight_jq_binary_ok passes on this platform"
else
  bad "preflight_jq_binary_ok failed on $(uname -s)"
fi
if bash -c '. "$1"; preflight_install_hint jq-binary' _ "$ROOT/lib/preflight.sh" | grep -qi '1\.7'; then
  ok "the jq-binary install hint names the version that has the flag"
else
  bad "preflight_install_hint jq-binary does not name jq 1.7"
fi

printf -- '----------------------------------------\n'
printf 'jq-binary: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
