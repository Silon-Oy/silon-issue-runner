#!/usr/bin/env bash
# tests/test-case-workdir.sh — guards tests/case-workdir.sh (#426).
#
#   A  a missing root: non-zero exit at once, nothing created, the line after
#      the call never runs (no test continues with WORK="")
#   B  consecutive cases survive a TMPDIR pointing into a removed WORK — the
#      leak that turned the Linux portability run red
#
# Each case runs once with the system mktemp and, when GNU coreutils is
# installed as `gmktemp` (macOS), once more with a `mktemp` shim pointing at it,
# so the GNU path is exercised on the macOS PR gate too. On Linux the system
# mktemp already is GNU.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL=0
bad() { echo "FAIL $1: $2"; FAIL=1; }
ok()  { echo "PASS $1: $2"; }

T=$(mktemp -d "${TMPDIR:-/tmp}/case-workdir-test.XXXXXX") || { echo "FATAL: mktemp" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

FLAVOURS=("system:$PATH")
if GM=$(command -v gmktemp 2>/dev/null) && [ -n "$GM" ]; then
  mkdir -p "$T/gnu-shim"; ln -s "$GM" "$T/gnu-shim/mktemp"
  FLAVOURS+=("gnu:$T/gnu-shim:$PATH")
fi

for fl in "${FLAVOURS[@]}"; do
  name=${fl%%:*}; path=${fl#*:}

  # --- A: missing root ---
  mkdir -p "$T/$name-a"
  out=$(PATH="$path" CASE_TMPDIR_ROOT="$T/$name-a/missing" bash -c '
    . "$1/case-workdir.sh"
    case_workdir probe
    echo "CONTINUED WORK=[$WORK]"' _ "$HERE" 2>&1)
  rc=$?
  [ "$rc" != 0 ] || bad "A-$name" "exit 0 with a missing root"
  case "$out" in *CONTINUED*) bad "A-$name" "ran on after the failure: $out" ;; esac
  case "$out" in *FATAL:*) ;; *) bad "A-$name" "no FATAL line: $out" ;; esac
  [ -z "$(ls -A "$T/$name-a")" ] || bad "A-$name" "something was created: $(ls -A "$T/$name-a")"
  [ "$rc" != 0 ] && [ -z "$(ls -A "$T/$name-a")" ] && ok "A-$name" "missing root fails closed"

  # --- B: leaked TMPDIR from a removed case ---
  mkdir -p "$T/$name-b"
  out=$(PATH="$path" TMPDIR="$T/$name-b" bash -c '
    . "$1/case-workdir.sh"
    for c in one two three; do
      case_workdir "leak-$c"
      echo "$WORK"
      export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
      rm -rf "$WORK"
    done' _ "$HERE" 2>&1)
  rc=$?
  n=$(printf '%s\n' "$out" | grep -c "^$T/$name-b/leak-")
  if [ "$rc" = 0 ] && [ "$n" = 3 ]; then
    ok "B-$name" "three consecutive cases under the original root"
  else
    bad "B-$name" "rc $rc, $n/3 under the root: $out"
  fi
done

[ "$FAIL" = 0 ] && echo "ALL PASS" || exit 1
