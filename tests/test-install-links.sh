#!/usr/bin/env bash
# test-install-links.sh — install.sh places per-file symlinks into
# ~/.claude/{agents,commands} without ever touching a path it does not own.
#
# The ownership invariant is a safety property, not a convenience: the target
# directories are shared with other sources (dotfiles ships its own agents
# there), and deleting or overwriting a foreign file is irreversible. Every
# case below asserts one half of that invariant — what the installer must do,
# and what it must leave alone.
#
# Cases:
#   1. Fresh home: one symlink per shipped agents/*.md and commands/*.md
#   3. A foreign file in the target dir survives byte-identically, unlinked
#      and un-backed-up
#   4. A second run is a no-op (linked=relinked=pruned=0, tree unchanged)
#   5. A foreign file shadowing a shipped name -> CONFLICT, preserved, exit 4
#   6. Prune removes package-owned dangling links only; foreign dangling
#      links survive
#   7. --dry-run writes nothing at all
#   9. A foreign ~/.claude/skills directory symlink -> CONFLICT (not a refusal),
#      exit 4, agents/commands still installed, skills left untouched
#  10. Prune/foreign handling for skills: a package-owned skill link no longer
#      shipped is pruned; a foreign real skill dir survives
#
# (Case 1 also asserts that skills link at directory level on a fresh home.)
#
# (Case 2 — the ~/.claude/scripts/run-issues binding — lives further down.)
#
# Every invocation runs against a throwaway $HOME. The installer must never
# read the real home directory: this suite is expected to run on the machine
# whose live ~/.claude the pollers use.
#
# Run: bash tests/test-install-links.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
INSTALL="$ROOT/install.sh"

if [ ! -f "$INSTALL" ]; then
  echo "FAIL: install.sh missing at the package root"
  exit 1
fi

WORK=$(mktemp -d -t install-links.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0

# run_install <fake-home> [args...] — every path the installer touches is
# redirected into the throwaway home.
run_install() {
  local home="$1"; shift
  HOME="$home" \
  RUN_ISSUES_CLAUDE_HOME="$home/.claude" \
  RUN_ISSUES_LAUNCH_AGENTS_DIR="$home/Library/LaunchAgents" \
  bash "$INSTALL" "$@"
}

# tree_signature <dir> — a stable description of the tree: every path plus,
# for symlinks, the exact target. Detects additions, removals and retargets.
tree_signature() {
  local dir="$1" p
  [ -d "$dir" ] || { printf '(absent)\n'; return 0; }
  find "$dir" | sort | while IFS= read -r p; do
    if [ -L "$p" ]; then
      printf '%s -> %s\n' "$p" "$(readlink "$p")"
    else
      printf '%s\n' "$p"
    fi
  done
}

# ---- Case 1: fresh home gets one symlink per shipped file ----
H1="$WORK/home1"
mkdir -p "$H1"
out1=$(run_install "$H1" 2>&1)
rc1=$?
if [ "$rc1" -eq 0 ]; then
  echo "PASS: case1 clean install exits 0"
else
  echo "FAIL: case1 clean install exited $rc1"
  printf '%s\n' "$out1" | sed 's/^/      /'
  FAIL=1
fi

for d in agents commands; do
  for src in "$ROOT/$d"/*.md; do
    [ -e "$src" ] || continue
    base="$(basename "$src")"
    dst="$H1/.claude/$d/$base"
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
      echo "PASS: case1 $d/$base linked to the package"
    else
      echo "FAIL: case1 $d/$base not linked (readlink='$( [ -L "$dst" ] && readlink "$dst" )')"
      FAIL=1
    fi
  done
done

# A newly shipped command must arrive via the glob with no installer change
# (#82: /run-epic). This is the acceptance criterion "install.sh linkittää uuden
# komennon (globi kattaa — todennettava testissä)" made explicit for run-epic.md.
if [ -L "$H1/.claude/commands/run-epic.md" ] \
   && [ "$(readlink "$H1/.claude/commands/run-epic.md")" = "$ROOT/commands/run-epic.md" ]; then
  echo "PASS: case1 commands/run-epic.md linked via the glob (no installer change)"
else
  echo "FAIL: case1 commands/run-epic.md not linked — the command glob missed a new command"
  FAIL=1
fi

if [ -d "$H1/.claude/agents" ] && [ ! -L "$H1/.claude/agents" ]; then
  echo "PASS: case1 \$HOME/.claude/agents is a real directory, not a directory symlink"
else
  echo "FAIL: case1 \$HOME/.claude/agents is not a real directory"; FAIL=1
fi

# Skills are linked at directory level, not per file: $CLAUDE_HOME/skills/<name>
# -> $PKG_ROOT/skills/<name>. This is the acceptance criterion "clean install
# creates the skill link, exit 0".
for src in "$ROOT/skills"/*/; do
  [ -f "${src}SKILL.md" ] || continue
  base="$(basename "$src")"
  dst="$H1/.claude/skills/$base"
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "${src%/}" ]; then
    echo "PASS: case1 skills/$base linked to the package at directory level"
  else
    echo "FAIL: case1 skills/$base not linked (readlink='$( [ -L "$dst" ] && readlink "$dst" )')"
    FAIL=1
  fi
done

# ---- Case 2: the scripts binding the slash commands depend on ----
# commands/{run-issues,cleanup-run,pr-watch}.md and prompts/02-implementer.md
# all invoke "$HOME/.claude/scripts/run-issues/<script>". On the maintainer's
# machine dotfiles creates that path; on any other machine nothing does, so a clean
# clone would install commands pointing at a script that does not exist. This
# assertion is the acceptance criterion "clone -> install.sh -> /run-issues
# works" reduced to something a test can check.
if [ -x "$H1/.claude/scripts/run-issues/orchestrate.sh" ]; then
  echo "PASS: case2 \$HOME/.claude/scripts/run-issues/orchestrate.sh is reachable"
else
  echo "FAIL: case2 the slash commands' script path does not resolve after install"
  FAIL=1
fi

# ---- Case 3: a foreign file survives byte-identically ----
H3="$WORK/home3"
mkdir -p "$H3/.claude/agents"
FOREIGN="$H3/.claude/agents/business-context.md"
printf 'foreign agent owned by dotfiles\nline two\n' > "$FOREIGN"
cp "$FOREIGN" "$WORK/foreign.expected"
out3=$(run_install "$H3" 2>&1)
rc3=$?
if [ "$rc3" -eq 0 ]; then
  echo "PASS: case3 install exits 0 alongside a foreign file"
else
  echo "FAIL: case3 install exited $rc3"
  printf '%s\n' "$out3" | sed 's/^/      /'
  FAIL=1
fi
if [ -L "$FOREIGN" ]; then
  echo "FAIL: case3 foreign file was replaced by a symlink"; FAIL=1
elif cmp -s "$FOREIGN" "$WORK/foreign.expected"; then
  echo "PASS: case3 foreign file is byte-identical after install"
else
  echo "FAIL: case3 foreign file content changed"; FAIL=1
fi
strays=$(find "$H3/.claude" \( -name '*.backup' -o -name '*.bak' -o -name '*~' \) 2>/dev/null)
if [ -z "$strays" ]; then
  echo "PASS: case3 no backup copies were created"
else
  echo "FAIL: case3 installer created backups: $strays"; FAIL=1
fi

# ---- Case 4: second run is a no-op ----
sig_before=$(tree_signature "$H1/.claude")
out4=$(run_install "$H1" 2>&1)
rc4=$?
sig_after=$(tree_signature "$H1/.claude")
if [ "$rc4" -eq 0 ]; then
  echo "PASS: case4 second run exits 0"
else
  echo "FAIL: case4 second run exited $rc4"; FAIL=1
fi
if [ "$sig_before" = "$sig_after" ]; then
  echo "PASS: case4 tree unchanged after the second run"
else
  echo "FAIL: case4 tree changed on re-run"
  diff <(printf '%s\n' "$sig_before") <(printf '%s\n' "$sig_after") | sed 's/^/      /'
  FAIL=1
fi
# A relink is invisible in the signature (same target), so assert the counters
# too: a re-run that unlinks and recreates is not idempotent.
if printf '%s\n' "$out4" | grep -q '^summary: linked=0 relinked=0 pruned=0'; then
  echo "PASS: case4 second run reports no write actions"
else
  echo "FAIL: case4 summary reports work on an idempotent re-run:"
  printf '%s\n' "$out4" | grep '^summary:' | sed 's/^/      /'
  FAIL=1
fi

# ---- Case 5: a foreign file shadowing a shipped name ----
H5="$WORK/home5"
mkdir -p "$H5/.claude/agents"
SHADOW="$H5/.claude/agents/architect.md"
printf 'someone elses architect\n' > "$SHADOW"
cp "$SHADOW" "$WORK/shadow.expected"
out5=$(run_install "$H5" 2>&1)
rc5=$?
if [ "$rc5" -eq 4 ]; then
  echo "PASS: case5 name conflict exits 4"
else
  echo "FAIL: case5 name conflict exited $rc5 (expected 4)"
  printf '%s\n' "$out5" | sed 's/^/      /'
  FAIL=1
fi
if printf '%s\n' "$out5" | grep -q '^CONFLICT: '; then
  echo "PASS: case5 conflict is reported on a CONFLICT: line"
else
  echo "FAIL: case5 no CONFLICT: line in the output"; FAIL=1
fi
if [ ! -L "$SHADOW" ] && cmp -s "$SHADOW" "$WORK/shadow.expected"; then
  echo "PASS: case5 shadowing file left untouched"
else
  echo "FAIL: case5 shadowing file was overwritten"; FAIL=1
fi
# The conflict must not block the rest of the install.
if [ -L "$H5/.claude/commands/run-issues.md" ]; then
  echo "PASS: case5 unaffected files still installed"
else
  echo "FAIL: case5 conflict blocked unrelated links"; FAIL=1
fi

# ---- Case 6: prune only what the package owns ----
H6="$WORK/home6"
mkdir -p "$H6/.claude/agents"
ln -s "$ROOT/agents/ghost.md" "$H6/.claude/agents/ghost.md"       # package-owned, dangling
ln -s "/nonexistent/foreign.md" "$H6/.claude/agents/foreign.md"   # foreign, dangling
out6=$(run_install "$H6" 2>&1)
rc6=$?
if [ "$rc6" -eq 0 ]; then
  echo "PASS: case6 prune run exits 0"
else
  echo "FAIL: case6 prune run exited $rc6"
  printf '%s\n' "$out6" | sed 's/^/      /'
  FAIL=1
fi
if [ ! -L "$H6/.claude/agents/ghost.md" ]; then
  echo "PASS: case6 dangling package-owned link pruned"
else
  echo "FAIL: case6 dangling package-owned link survived"; FAIL=1
fi
if [ -L "$H6/.claude/agents/foreign.md" ]; then
  echo "PASS: case6 dangling foreign link left untouched"
else
  echo "FAIL: case6 installer removed a foreign symlink"; FAIL=1
fi

# A shipped name whose package-owned link points at a path that has moved
# inside the package must be repaired, not pruned. Prune and relink both match
# such a link, and the plan is applied in order, so a prune rule keyed on
# "dangles" instead of "no longer shipped" would silently delete it.
H6B="$WORK/home6b"
mkdir -p "$H6B/.claude/agents"
ln -s "$ROOT/agents/moved-away/architect.md" "$H6B/.claude/agents/architect.md"
out6b=$(run_install "$H6B" 2>&1)
rc6b=$?
if [ "$rc6b" -eq 0 ] && [ -L "$H6B/.claude/agents/architect.md" ] \
   && [ "$(readlink "$H6B/.claude/agents/architect.md")" = "$ROOT/agents/architect.md" ]; then
  echo "PASS: case6b stale package-owned link for a shipped name is repaired"
else
  echo "FAIL: case6b stale link not repaired (rc=$rc6b, readlink='$( [ -L "$H6B/.claude/agents/architect.md" ] && readlink "$H6B/.claude/agents/architect.md" )')"
  FAIL=1
fi

# ---- Case 7: --dry-run writes nothing ----
H7="$WORK/home7"
mkdir -p "$H7"
out7=$(run_install "$H7" --dry-run 2>&1)
rc7=$?
if [ "$rc7" -eq 0 ]; then
  echo "PASS: case7 --dry-run exits 0"
else
  echo "FAIL: case7 --dry-run exited $rc7"
  printf '%s\n' "$out7" | sed 's/^/      /'
  FAIL=1
fi
if [ ! -e "$H7/.claude" ]; then
  echo "PASS: case7 --dry-run created nothing"
else
  echo "FAIL: case7 --dry-run created $H7/.claude"; FAIL=1
fi
if printf '%s\n' "$out7" | grep -q '^plan: link .*agents/architect\.md'; then
  echo "PASS: case7 --dry-run prints the planned links"
else
  echo "FAIL: case7 --dry-run did not print a plan:"
  printf '%s\n' "$out7" | sed 's/^/      /'
  FAIL=1
fi

# ---- Case 9: a foreign skills directory symlink is a conflict, not a refusal ----
# On the maintainer's machine ~/.claude/skills is a directory symlink -> dotfiles
# (agents/commands were split per-file, skills was not, see CLAUDE.md §13). A
# refusal there would abort the WHOLE install, taking agents/commands with it
# over an optional extra. So skills must degrade to a CONFLICT (exit 4) while the
# core links still install.
H9="$WORK/home9"
mkdir -p "$H9/.claude" "$H9/foreign-skills"
ln -s "$H9/foreign-skills" "$H9/.claude/skills"
out9=$(run_install "$H9" 2>&1)
rc9=$?
if [ "$rc9" -eq 4 ]; then
  echo "PASS: case9 foreign skills symlink exits 4 (conflict, not refuse)"
else
  echo "FAIL: case9 foreign skills symlink exited $rc9 (expected 4)"
  printf '%s\n' "$out9" | sed 's/^/      /'
  FAIL=1
fi
if printf '%s\n' "$out9" | grep -qi '^CONFLICT: .*skills'; then
  echo "PASS: case9 conflict is reported on a CONFLICT: line"
else
  echo "FAIL: case9 no skills CONFLICT: line in the output"
  printf '%s\n' "$out9" | sed 's/^/      /'
  FAIL=1
fi
# The core install must not be blocked by the skills conflict.
if [ -L "$H9/.claude/agents/architect.md" ] && [ -L "$H9/.claude/commands/run-issues.md" ]; then
  echo "PASS: case9 agents and commands still installed alongside the skills conflict"
else
  echo "FAIL: case9 skills conflict blocked the core agents/commands links"; FAIL=1
fi
# The foreign symlink and the tree behind it are left exactly as they were.
if [ -L "$H9/.claude/skills" ] && [ "$(readlink "$H9/.claude/skills")" = "$H9/foreign-skills" ]; then
  echo "PASS: case9 foreign skills symlink left untouched"
else
  echo "FAIL: case9 foreign skills symlink was modified"; FAIL=1
fi
if [ ! -e "$H9/foreign-skills/claude-issue-runner" ]; then
  echo "PASS: case9 nothing was written through the foreign symlink"
else
  echo "FAIL: case9 the installer wrote through the foreign skills symlink"; FAIL=1
fi

# ---- Case 10: prune and foreign handling for skills ----
# A package-owned skill link whose name the package no longer ships is pruned;
# a foreign real skill directory is left alone (it is not a package-owned link).
H10="$WORK/home10"
mkdir -p "$H10/.claude/skills/foreign-skill"
printf 'name: foreign\n' > "$H10/.claude/skills/foreign-skill/SKILL.md"
ln -s "$ROOT/skills/ghost-skill" "$H10/.claude/skills/ghost-skill"   # package-owned, unshipped
out10=$(run_install "$H10" 2>&1)
rc10=$?
if [ "$rc10" -eq 0 ]; then
  echo "PASS: case10 skills prune run exits 0"
else
  echo "FAIL: case10 skills prune run exited $rc10"
  printf '%s\n' "$out10" | sed 's/^/      /'
  FAIL=1
fi
if [ ! -L "$H10/.claude/skills/ghost-skill" ]; then
  echo "PASS: case10 unshipped package-owned skill link pruned"
else
  echo "FAIL: case10 unshipped package-owned skill link survived"; FAIL=1
fi
if [ -d "$H10/.claude/skills/foreign-skill" ] && [ ! -L "$H10/.claude/skills/foreign-skill" ]; then
  echo "PASS: case10 foreign real skill directory left untouched"
else
  echo "FAIL: case10 foreign real skill directory was modified"; FAIL=1
fi
if [ -L "$H10/.claude/skills/claude-issue-runner" ]; then
  echo "PASS: case10 shipped skill still linked"
else
  echo "FAIL: case10 shipped skill not linked"; FAIL=1
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "install-links: all passed" || echo "install-links: FAILURES"
[ "$FAIL" -eq 0 ]
