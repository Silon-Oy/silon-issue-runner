#!/usr/bin/env bash
# test-install-refusals.sh — install.sh refuses foreign layouts, and a refusal
# costs zero writes.
#
# On the machine this package was extracted from, $HOME/.claude/{agents,
# commands,scripts} are all whole-directory symlinks into dotfiles. Refusing is
# therefore the *default* path there, not an edge case, and it has to be as
# well covered as a successful install.
#
# The atomicity assertions are the point of the plan/apply split: a refusal
# raised while planning the second directory must leave the first one
# untouched. Checking and writing in one loop would pass every other case here
# and still leave a half-installed tree.
#
# Cases:
#   1. agents/ is a directory symlink   -> exit 2, commands/ never created
#   2. commands/ is a directory symlink -> exit 2, agents/ never created
#   3. scripts/ is a directory symlink without run-issues -> exit 2, no writes
#   4. scripts/ is a directory symlink WITH a working run-issues -> exit 0 and
#      the symlink is not retargeted (the no-regression case for the dotfiles
#      + submodule install)
#   5. a foreign file occupies scripts/run-issues -> exit 2
#
# Run: bash tests/test-install-refusals.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
INSTALL="$ROOT/install.sh"

if [ ! -f "$INSTALL" ]; then
  echo "FAIL: install.sh missing at the package root"
  exit 1
fi

WORK=$(mktemp -d -t install-refusals.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0

run_install() {
  local home="$1"; shift
  HOME="$home" \
  RUN_ISSUES_CLAUDE_HOME="$home/.claude" \
  RUN_ISSUES_LAUNCH_AGENTS_DIR="$home/Library/LaunchAgents" \
  bash "$INSTALL" "$@"
}

# assert_refused <label> <rc> <output> <path-that-must-appear>
assert_refused() {
  local label="$1" rc="$2" out="$3" needle="$4"
  if [ "$rc" -eq 2 ]; then
    echo "PASS: $label exits 2"
  else
    echo "FAIL: $label exited $rc (expected 2)"
    printf '%s\n' "$out" | sed 's/^/      /'
    FAIL=1
  fi
  if printf '%s\n' "$out" | grep -q '^REFUSED: '; then
    echo "PASS: $label prints a REFUSED: line"
  else
    echo "FAIL: $label printed no REFUSED: line"; FAIL=1
  fi
  if printf '%s\n' "$out" | grep -qF "$needle"; then
    echo "PASS: $label names the offending path"
  else
    echo "FAIL: $label does not name '$needle'"; FAIL=1
  fi
}

FOREIGN_DIR="$WORK/foreign-assets"
mkdir -p "$FOREIGN_DIR"
printf 'someone elses agent\n' > "$FOREIGN_DIR/other.md"

# ---- Case 1: agents/ is a directory symlink ----
H1="$WORK/home1"
mkdir -p "$H1/.claude"
ln -s "$FOREIGN_DIR" "$H1/.claude/agents"
out1=$(run_install "$H1" 2>&1)
rc1=$?
assert_refused "case1" "$rc1" "$out1" "$H1/.claude/agents"
if [ ! -e "$H1/.claude/commands" ]; then
  echo "PASS: case1 no commands/ directory was created (plan/apply split holds)"
else
  echo "FAIL: case1 refusal still created $H1/.claude/commands"; FAIL=1
fi
if [ ! -e "$H1/.claude/scripts" ]; then
  echo "PASS: case1 no scripts/ directory was created"
else
  echo "FAIL: case1 refusal still created $H1/.claude/scripts"; FAIL=1
fi
if [ -L "$H1/.claude/agents" ] && [ "$(readlink "$H1/.claude/agents")" = "$FOREIGN_DIR" ]; then
  echo "PASS: case1 foreign directory symlink left as it was"
else
  echo "FAIL: case1 foreign directory symlink was modified"; FAIL=1
fi

# ---- Case 2: commands/ is a directory symlink ----
H2="$WORK/home2"
mkdir -p "$H2/.claude"
ln -s "$FOREIGN_DIR" "$H2/.claude/commands"
out2=$(run_install "$H2" 2>&1)
rc2=$?
assert_refused "case2" "$rc2" "$out2" "$H2/.claude/commands"
if [ ! -e "$H2/.claude/agents" ]; then
  echo "PASS: case2 no agents/ directory was created"
else
  echo "FAIL: case2 refusal still created $H2/.claude/agents"; FAIL=1
fi

# ---- Case 3: scripts/ is a directory symlink without run-issues ----
H3="$WORK/home3"
mkdir -p "$H3/.claude" "$WORK/empty-scripts"
ln -s "$WORK/empty-scripts" "$H3/.claude/scripts"
out3=$(run_install "$H3" 2>&1)
rc3=$?
assert_refused "case3" "$rc3" "$out3" "$H3/.claude/scripts"
if [ ! -e "$H3/.claude/agents" ] && [ ! -e "$WORK/empty-scripts/run-issues" ]; then
  echo "PASS: case3 nothing was written into either tree"
else
  echo "FAIL: case3 refusal still wrote something"; FAIL=1
fi

# ---- Case 4: scripts/ is a directory symlink WITH a working run-issues ----
# This is the shape produced by dotfiles (directory symlink) plus the package
# mounted as a submodule. It must stay a no-op: retargeting the symlink here
# would break maintainer's working install.
OTHER_PKG="$WORK/other-pkg"
mkdir -p "$OTHER_PKG/run-issues"
printf '#!/usr/bin/env bash\nexit 0\n' > "$OTHER_PKG/run-issues/orchestrate.sh"
chmod +x "$OTHER_PKG/run-issues/orchestrate.sh"
H4="$WORK/home4"
mkdir -p "$H4/.claude"
ln -s "$OTHER_PKG" "$H4/.claude/scripts"
out4=$(run_install "$H4" 2>&1)
rc4=$?
if [ "$rc4" -eq 0 ]; then
  echo "PASS: case4 an already working scripts path is accepted"
else
  echo "FAIL: case4 exited $rc4 (expected 0)"
  printf '%s\n' "$out4" | sed 's/^/      /'
  FAIL=1
fi
if [ -L "$H4/.claude/scripts" ] && [ "$(readlink "$H4/.claude/scripts")" = "$OTHER_PKG" ]; then
  echo "PASS: case4 existing scripts symlink not retargeted"
else
  echo "FAIL: case4 scripts symlink was modified"; FAIL=1
fi
if [ ! -e "$OTHER_PKG/run-issues/agents" ]; then
  echo "PASS: case4 nothing written inside the foreign scripts tree"
else
  echo "FAIL: case4 wrote into the foreign scripts tree"; FAIL=1
fi
if printf '%s\n' "$out4" | grep -q "run-issues"; then
  echo "PASS: case4 reports what it did with the scripts path"
else
  echo "FAIL: case4 said nothing about the scripts path"; FAIL=1
fi
# The rest of the install must still have happened.
if [ -L "$H4/.claude/agents/architect.md" ]; then
  echo "PASS: case4 agents still installed"
else
  echo "FAIL: case4 agents were not installed"; FAIL=1
fi

# ---- Case 5: a foreign file occupies scripts/run-issues ----
H5="$WORK/home5"
mkdir -p "$H5/.claude/scripts"
printf 'not a package\n' > "$H5/.claude/scripts/run-issues"
out5=$(run_install "$H5" 2>&1)
rc5=$?
assert_refused "case5" "$rc5" "$out5" "$H5/.claude/scripts/run-issues"
if [ -f "$H5/.claude/scripts/run-issues" ] && [ ! -L "$H5/.claude/scripts/run-issues" ]; then
  echo "PASS: case5 foreign file left in place"
else
  echo "FAIL: case5 foreign file was replaced"; FAIL=1
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "install-refusals: all passed" || echo "install-refusals: FAILURES"
[ "$FAIL" -eq 0 ]
