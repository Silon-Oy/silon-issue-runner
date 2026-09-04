#!/usr/bin/env bash
# test-install-launchagents.sh — the opt-in LaunchAgent deploy.
#
# Two properties are being protected here.
#
# The plists' ProgramArguments point at $HOME/.claude/scripts/run-issues/
# <poller>.sh — the path the installer's own scripts binding provides. That
# binding is planned in the same run that deploys the plists and applied only
# afterwards, so case 4 is the one that proves the installer looks at the
# binding it is about to create rather than at the empty disk in front of it.
# Where the program genuinely will not resolve, the installer must refuse:
# launchd would load a broken agent and fail on every StartInterval tick
# without reporting anything.
#
# The installer must also never call launchctl. launchd mutates a live user
# session, so a test could not undo it, and the com.legacy ->
# com.claude-issue-runner rename needs a deliberate one-off bootout
# (CLAUDE.md, section 11). Case 5 asserts this with a PATH shim rather than
# trusting a code review.
#
# Cases:
#   1. Without the flag: no LaunchAgents work at all
#   2. Without plutil: the suite skips (macOS-only machinery)
#   3. With the flag but a binding built somewhere else: exit 2, nothing deployed
#   4. With the flag on a clean home: both plists symlinked, program resolves
#   5. launchctl is never invoked; the commands are printed instead
#
# Run: bash tests/test-install-launchagents.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
INSTALL="$ROOT/install.sh"

if [ ! -f "$INSTALL" ]; then
  echo "FAIL: install.sh missing at the package root"
  exit 1
fi

if ! command -v plutil >/dev/null 2>&1; then
  echo "SKIP: plutil not available — LaunchAgent deploy is macOS-only"
  exit 0
fi

WORK=$(mktemp -d -t install-launchagents.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0

PLISTS="com.claude-issue-runner.run-issues-poller.plist com.claude-issue-runner.pr-watch-poller.plist"

# A launchctl shim that records every call. It must stay empty.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/launchctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/launchctl.log"
exit 0
EOF
chmod +x "$WORK/bin/launchctl"

# run_install_at <fake-home> <claude-home> [args...]
run_install_at() {
  local home="$1" claude_home="$2"; shift 2
  HOME="$home" \
  PATH="$WORK/bin:$PATH" \
  RUN_ISSUES_CLAUDE_HOME="$claude_home" \
  RUN_ISSUES_LAUNCH_AGENTS_DIR="$home/Library/LaunchAgents" \
  bash "$INSTALL" "$@"
}

run_install() {
  local home="$1"; shift
  run_install_at "$home" "$home/.claude" "$@"
}

# ---- Case 1: no flag, no LaunchAgents work ----
H1="$WORK/home1"
mkdir -p "$H1/Library"
out1=$(run_install "$H1" 2>&1)
rc1=$?
if [ "$rc1" -eq 0 ]; then
  echo "PASS: case1 default install exits 0"
else
  echo "FAIL: case1 default install exited $rc1"
  printf '%s\n' "$out1" | sed 's/^/      /'
  FAIL=1
fi
if [ ! -e "$H1/Library/LaunchAgents" ]; then
  echo "PASS: case1 LaunchAgents directory not even created without the flag"
else
  echo "FAIL: case1 default install touched $H1/Library/LaunchAgents"; FAIL=1
fi

# ---- Case 3: flag set, the binding is built outside the plists' path ----
# RUN_ISSUES_CLAUDE_HOME points somewhere the plists do not reference, so this
# run's scripts binding cannot make $HOME/.claude/scripts/run-issues/poller.sh
# executable. Deploying anyway would install an agent that fails on every tick.
H3="$WORK/home3"
mkdir -p "$H3/Library"
out3=$(run_install_at "$H3" "$H3/elsewhere" --with-launchagents 2>&1)
rc3=$?
if [ "$rc3" -eq 2 ]; then
  echo "PASS: case3 unresolvable program path refuses with exit 2"
else
  echo "FAIL: case3 exited $rc3 (expected 2)"
  printf '%s\n' "$out3" | sed 's/^/      /'
  FAIL=1
fi
if printf '%s\n' "$out3" | grep -qF "$H3/.claude/scripts/run-issues/poller.sh"; then
  echo "PASS: case3 refusal names the unresolvable program path"
else
  echo "FAIL: case3 refusal does not name the program path"; FAIL=1
fi
if printf '%s\n' "$out3" | grep -q 'RUN_ISSUES_CLAUDE_HOME'; then
  echo "PASS: case3 refusal names the knob that would make the path resolve"
else
  echo "FAIL: case3 refusal does not say how to make the program resolve"; FAIL=1
fi
if [ -z "$(find "$H3/Library" -name 'com.claude-issue-runner.*' 2>/dev/null)" ]; then
  echo "PASS: case3 no plist was deployed"
else
  echo "FAIL: case3 deployed a plist despite refusing"; FAIL=1
fi

# ---- Case 4: flag set on a clean home ----
# No dotfiles tree, no .claude tree: the plists' program is provided by the
# scripts binding this same run plans. This is the clean-machine case the
# deploy exists for.
H4="$WORK/home4"
mkdir -p "$H4/Library"
out4=$(run_install "$H4" --with-launchagents 2>&1)
rc4=$?
if [ "$rc4" -eq 0 ]; then
  echo "PASS: case4 deploy exits 0"
else
  echo "FAIL: case4 deploy exited $rc4"
  printf '%s\n' "$out4" | sed 's/^/      /'
  FAIL=1
fi
for p in $PLISTS; do
  dst="$H4/Library/LaunchAgents/$p"
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$ROOT/$p" ]; then
    echo "PASS: case4 $p symlinked to the package"
  else
    echo "FAIL: case4 $p not symlinked (readlink='$( [ -L "$dst" ] && readlink "$dst" )')"
    FAIL=1
  fi
done
# The probe that produced this whole change: the deploy must leave the plists'
# program actually executable. Planning the binding and deploying the plists
# happen in one run but in two passes, and only this assertion keeps that
# ordering dependency visible.
if [ -x "$H4/.claude/scripts/run-issues/poller.sh" ]; then
  echo "PASS: case4 the deployed plist's program is executable afterwards"
else
  echo "FAIL: case4 $H4/.claude/scripts/run-issues/poller.sh is not executable"; FAIL=1
fi
if printf '%s\n' "$out4" | grep -q 'RUN_ISSUES_POLLER_HOSTS'; then
  echo "PASS: case4 the instructions mention the host gate"
else
  echo "FAIL: case4 the instructions do not mention the host gate"; FAIL=1
fi
if printf '%s\n' "$out4" | grep -q 'launchctl bootstrap'; then
  echo "PASS: case4 prints the launchctl bootstrap command"
else
  echo "FAIL: case4 did not print launchctl instructions"; FAIL=1
fi
if printf '%s\n' "$out4" | grep -q 'launchctl bootout'; then
  echo "PASS: case4 prints the bootout step the label rename requires"
else
  echo "FAIL: case4 did not print the bootout step"; FAIL=1
fi

# A second deploy must be a no-op.
out4b=$(run_install "$H4" --with-launchagents 2>&1)
rc4b=$?
if [ "$rc4b" -eq 0 ] && printf '%s\n' "$out4b" | grep -q '^summary: linked=0 relinked=0 pruned=0'; then
  echo "PASS: case4 repeated deploy is a no-op"
else
  echo "FAIL: case4 repeated deploy did work (rc=$rc4b)"
  printf '%s\n' "$out4b" | grep '^summary:' | sed 's/^/      /'
  FAIL=1
fi

# ---- Case 5: launchctl never invoked ----
if [ ! -s "$WORK/launchctl.log" ]; then
  echo "PASS: case5 launchctl was never invoked"
else
  echo "FAIL: case5 installer called launchctl:"
  sed 's/^/      /' "$WORK/launchctl.log"
  FAIL=1
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "install-launchagents: all passed" || echo "install-launchagents: FAILURES"
[ "$FAIL" -eq 0 ]
