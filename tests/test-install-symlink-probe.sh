#!/usr/bin/env bash
# test-install-symlink-probe.sh — install.sh refuses where `ln -s` copies.
#
# INV-OWN reads ownership from a symlink's target (install.sh:is_pkg_owned_link).
# Git Bash on Windows accepts `ln -s` and silently produces a copy unless
# Developer Mode is on and MSYS=winsymlinks:nativestrict is set. An installer
# that runs there would report success and leave behind files that the *next*
# run reads as foreign — refusing at a different path, naming the wrong cause.
# Refusing up front, with the fix named, is the only correct state.
#
# The copying `ln` is simulated with a PATH shim rather than requiring Windows,
# so both cases run everywhere and neither needs a SKIP branch.
#
# Cases:
#   1. A copying `ln` -> exit 2, a REFUSED line naming the Windows fix, and
#      nothing at all created under $HOME
#   2. A real `ln` -> the probe passes and --dry-run reports the result
#
# Run: bash tests/test-install-symlink-probe.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
INSTALL="$ROOT/install.sh"

if [ ! -f "$INSTALL" ]; then
  echo "FAIL: install.sh missing at the package root"
  exit 1
fi

WORK=$(mktemp -d -t install-symlink-probe.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0

# run_install <fake-home> [args...] — every path the installer touches is
# redirected into the throwaway home, as in the other installer suites.
run_install() {
  local home="$1"; shift
  HOME="$home" \
  RUN_ISSUES_CLAUDE_HOME="$home/.claude" \
  RUN_ISSUES_LAUNCH_AGENTS_DIR="$home/Library/LaunchAgents" \
  bash "$INSTALL" "$@"
}

# ---- The shim: an `ln` that accepts -s and copies, like Git Bash's default ----
SHIM_BIN="$WORK/shimbin"
mkdir -p "$SHIM_BIN"
cat >"$SHIM_BIN/ln" <<'SHIM'
#!/usr/bin/env bash
# Git Bash without winsymlinks:nativestrict: -s is accepted, a copy appears.
args=()
for a in "$@"; do
  [ "$a" = "-s" ] && continue
  args+=("$a")
done
exec cp -R "${args[@]}"
SHIM
chmod +x "$SHIM_BIN/ln"

# ---- Case 1: a copying `ln` is refused before anything is written ----
H1="$WORK/home1"
mkdir -p "$H1"
out1=$(PATH="$SHIM_BIN:$PATH" run_install "$H1" 2>&1)
rc1=$?

if [ "$rc1" -eq 2 ]; then
  echo "PASS: case1 copying ln exits 2"
else
  echo "FAIL: case1 copying ln exited $rc1 (expected 2)"
  printf '%s\n' "$out1" | sed 's/^/      /'
  FAIL=1
fi

if printf '%s\n' "$out1" | grep -q '^REFUSED: '; then
  echo "PASS: case1 prints a REFUSED: line"
else
  echo "FAIL: case1 printed no REFUSED: line"
  printf '%s\n' "$out1" | sed 's/^/      /'
  FAIL=1
fi

# The refusal is only useful if it names the fix. Both halves are required:
# Developer Mode alone still leaves MSYS defaulting to a copy.
for needle in 'Developer Mode' 'MSYS=winsymlinks:nativestrict'; do
  if printf '%s\n' "$out1" | grep -qF "$needle"; then
    echo "PASS: case1 refusal names '$needle'"
  else
    echo "FAIL: case1 refusal does not name '$needle'"; FAIL=1
  fi
done

# The whole point of refusing at planning time: zero writes. $HOME/.claude is
# the tree every later run reads ownership from, so its absence is the
# assertion that matters.
if [ ! -e "$H1/.claude" ]; then
  echo "PASS: case1 created nothing under \$HOME/.claude"
else
  echo "FAIL: case1 wrote into \$HOME/.claude:"
  find "$H1/.claude" | sed 's/^/      /'
  FAIL=1
fi

# ---- Case 2: a real `ln` passes the probe and the plan reports it ----
H2="$WORK/home2"
mkdir -p "$H2"
out2=$(run_install "$H2" --dry-run 2>&1)
rc2=$?

if [ "$rc2" -eq 0 ]; then
  echo "PASS: case2 real ln completes --dry-run (exit 0)"
else
  echo "FAIL: case2 real ln exited $rc2 (expected 0)"
  printf '%s\n' "$out2" | sed 's/^/      /'
  FAIL=1
fi

if printf '%s\n' "$out2" | grep -q '^symlink capability: ok'; then
  echo "PASS: case2 --dry-run reports the probe result"
else
  echo "FAIL: case2 --dry-run does not report the probe result"
  printf '%s\n' "$out2" | sed 's/^/      /'
  FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
  echo "ALL PASS: test-install-symlink-probe.sh"
  exit 0
fi
echo "FAILURES in test-install-symlink-probe.sh"
exit 1
