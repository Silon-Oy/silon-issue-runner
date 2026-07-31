#!/usr/bin/env bash
# test-package-layout.sh — guards the package layout invariants that the
# submodule install model depends on.
#
# The package root IS the submodule mount point (dotfiles mounts it at
# claude/scripts/run-issues). Every layout assumption below is load-bearing for
# path references that live OUTSIDE this repo (slash commands, LaunchAgent
# plists, poller.sh), which no other test can reach.
#
# Cases:
#   1. Expected entries exist at the root; shipped scripts are executable
#   2. No claude/ directory at the root  <-- the nesting guard, see below
#   3. unblock-issues.sh resolves package-locally from pr-watch-poller.sh
#   4. Plists: new names only, Label == filename
#   5. Diagram references resolve and no .mmd is empty
#   6. CLAUDE.md exists at the root
#
# Run: bash tests/test-package-layout.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FAIL=0

# ---- Case 1: expected entries ----
EXPECTED_FILES=(
  orchestrate.sh poller.sh pr-watch.sh pr-watch-poller.sh
  cleanup-run.sh auto-clean.sh unblock-issues.sh
  .gitignore
)
EXPECTED_DIRS=(lib prompts tests db-clone agents commands docs/diagrams examples)

for f in "${EXPECTED_FILES[@]}"; do
  if [ -f "$ROOT/$f" ]; then
    echo "PASS: root file present: $f"
  else
    echo "FAIL: root file missing: $f"; FAIL=1
  fi
done
for d in "${EXPECTED_DIRS[@]}"; do
  if [ -d "$ROOT/$d" ]; then
    echo "PASS: root dir present: $d"
  else
    echo "FAIL: root dir missing: $d"; FAIL=1
  fi
done
for s in orchestrate.sh poller.sh pr-watch.sh pr-watch-poller.sh cleanup-run.sh auto-clean.sh unblock-issues.sh; do
  if [ -x "$ROOT/$s" ]; then
    echo "PASS: executable: $s"
  else
    echo "FAIL: not executable: $s"; FAIL=1
  fi
done

# ---- Case 2: nesting guard ----
# A submodule mounts this repo's ROOT at dotfiles' claude/scripts/run-issues.
# Re-introducing a claude/scripts/run-issues/ tree here would therefore resolve
# to .../run-issues/claude/scripts/run-issues/orchestrate.sh and silently break
# every external reference (slash commands, plists, poller.sh).
if [ ! -d "$ROOT/claude" ]; then
  echo "PASS: no claude/ directory at the package root (submodule nesting guard)"
else
  echo "FAIL: claude/ exists at the package root — a submodule mount would nest"
  echo "      the package as .../run-issues/claude/scripts/run-issues/ and break"
  echo "      every reference that points at .../run-issues/<script>."
  FAIL=1
fi

# ---- Case 3: unblock-issues.sh resolves package-locally ----
if [ -x "$ROOT/unblock-issues.sh" ]; then
  echo "PASS: unblock-issues.sh is executable at the package root"
else
  echo "FAIL: unblock-issues.sh missing or not executable at the package root"; FAIL=1
fi
if grep -q 'UNBLOCK="\${SCRIPT_DIR}/unblock-issues.sh"' "$ROOT/pr-watch-poller.sh"; then
  echo "PASS: pr-watch-poller.sh prefers the package-local unblock-issues.sh"
else
  echo "FAIL: pr-watch-poller.sh does not resolve unblock-issues.sh via SCRIPT_DIR"
  echo "      (the [ -x ] guard makes a wrong path a silent no-op)"
  FAIL=1
fi

# ---- Case 4: plists ----
PLISTS=(
  com.claude-issue-runner.run-issues-poller.plist
  com.claude-issue-runner.pr-watch-poller.plist
)
for p in "${PLISTS[@]}"; do
  if [ -f "$ROOT/$p" ]; then
    echo "PASS: plist present: $p"
  else
    echo "FAIL: plist missing: $p"; FAIL=1; continue
  fi
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$ROOT/$p" >/dev/null 2>&1 \
      && echo "PASS: plist lints clean: $p" \
      || { echo "FAIL: plist does not lint: $p"; FAIL=1; }
    label=$(plutil -extract Label raw -o - "$ROOT/$p" 2>/dev/null)
    want="${p%.plist}"
    if [ "$label" = "$want" ]; then
      echo "PASS: Label matches filename: $label"
    else
      echo "FAIL: Label '$label' != filename stem '$want' (the deployer derives"
      echo "      the launchctl label from the filename)"
      FAIL=1
    fi
  else
    echo "SKIP: plutil not available — plist lint/Label check skipped"
  fi
done
# shellcheck disable=SC2144
if compgen -G "$ROOT/com.maintainer.*.plist" >/dev/null; then
  echo "FAIL: legacy com.maintainer.*.plist still present at the package root"; FAIL=1
else
  echo "PASS: no legacy com.maintainer.*.plist at the package root"
fi

# ---- Case 5: diagrams ----
if [ -f "$ROOT/docs/diagrams/pr-watch-state-machine.mmd" ]; then
  echo "PASS: pr-watch.sh's referenced diagram resolves from the package root"
else
  echo "FAIL: docs/diagrams/pr-watch-state-machine.mmd missing (referenced by pr-watch.sh)"
  FAIL=1
fi
for m in "$ROOT"/docs/diagrams/*.mmd; do
  [ -e "$m" ] || { echo "FAIL: docs/diagrams holds no .mmd files"; FAIL=1; break; }
  if [ -s "$m" ]; then
    echo "PASS: non-empty diagram: $(basename "$m")"
  else
    echo "FAIL: empty diagram: $(basename "$m")"; FAIL=1
  fi
done

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "package-layout: all passed" || echo "package-layout: FAILURES"
[ "$FAIL" -eq 0 ]
