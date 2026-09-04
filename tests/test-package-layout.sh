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
#   3. Plists: new names only, Label == filename
#   4. Diagram references resolve and no .mmd is empty
#   5. CLAUDE.md and README.md exist at the root
#
# Run: bash tests/test-package-layout.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FAIL=0

# ---- Case 1: expected entries ----
EXPECTED_FILES=(
  orchestrate.sh poller.sh pr-watch.sh pr-watch-poller.sh
  cleanup-run.sh auto-clean.sh install.sh status.sh status-render.sh
  action-server.sh action-dispatch.sh self-update.sh
  .gitignore CLAUDE.md README.md
)
EXPECTED_DIRS=(lib prompts tests db-clone commands skills docs/diagrams examples)

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
for s in orchestrate.sh poller.sh pr-watch.sh pr-watch-poller.sh cleanup-run.sh auto-clean.sh install.sh status.sh status-render.sh action-server.sh action-dispatch.sh self-update.sh; do
  if [ -x "$ROOT/$s" ]; then
    echo "PASS: executable: $s"
  else
    echo "FAIL: not executable: $s"; FAIL=1
  fi
done

# publish-release.sh is the maintainer tool: present in the upstream, deliberately
# absent from the public mirror it produces (it carries the denylist). Its absence
# is therefore a SKIP, not a failure — the same tests must pass in both trees.
if [ -f "$ROOT/publish-release.sh" ]; then
  if [ -x "$ROOT/publish-release.sh" ]; then
    echo "PASS: executable: publish-release.sh"
  else
    echo "FAIL: not executable: publish-release.sh"; FAIL=1
  fi
else
  echo "SKIP: publish-release.sh not shipped in this tree (public mirror)"
fi

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

# ---- Case 3: plists ----
PLISTS=(
  com.claude-issue-runner.run-issues-poller.plist
  com.claude-issue-runner.pr-watch-poller.plist
  com.claude-issue-runner.status-render.plist
  com.claude-issue-runner.action-server.plist
  com.claude-issue-runner.self-update.plist
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
    # launchd expands no variables in StandardOutPath / StandardErrorPath, so a
    # literal $HOME in them would write to a directory of that name. The
    # pollers redirect their own stdout/stderr instead, which is also what puts
    # all four log paths under RUN_ISSUES_LOG_DIR.
    for key in StandardOutPath StandardErrorPath; do
      if plutil -extract "$key" raw -o - "$ROOT/$p" >/dev/null 2>&1; then
        echo "FAIL: $p carries a $key key that launchd cannot expand"; FAIL=1
      else
        echo "PASS: $p has no $key key"
      fi
    done
    # install.sh's scripts binding is what makes this path exist on a machine
    # without dotfiles; a plist pointing anywhere else could not be deployed.
    argc=$(plutil -extract ProgramArguments raw -o - "$ROOT/$p" 2>/dev/null)
    prog=$(plutil -extract "ProgramArguments.$((argc - 1))" raw -o - "$ROOT/$p" 2>/dev/null)
    case "$prog" in
      '$HOME/.claude/scripts/run-issues/'*)
        echo "PASS: $p runs a program under the installer's scripts binding" ;;
      *)
        echo "FAIL: $p runs '$prog', outside \$HOME/.claude/scripts/run-issues/"; FAIL=1 ;;
    esac
  else
    echo "SKIP: plutil not available — plist lint/Label check skipped"
  fi
done
# Every plist at the package root must carry the package label prefix. A plist
# under any other prefix is a leftover from before the label rename (CLAUDE.md,
# section 10): launchd would load it as a second agent from the same code.
STRAY_PLISTS=""
for p in "$ROOT"/*.plist; do
  [ -e "$p" ] || continue
  case "$(basename "$p")" in
    com.claude-issue-runner.*) ;;
    *) STRAY_PLISTS="$STRAY_PLISTS $(basename "$p")" ;;
  esac
done
if [ -n "$STRAY_PLISTS" ]; then
  echo "FAIL: plist(s) outside the com.claude-issue-runner.* label prefix at the package root:$STRAY_PLISTS"; FAIL=1
else
  echo "PASS: every plist at the package root carries the com.claude-issue-runner.* label prefix"
fi

# ---- Case 4: diagrams ----
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
