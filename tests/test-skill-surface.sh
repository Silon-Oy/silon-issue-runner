#!/usr/bin/env bash
# test-skill-surface.sh — the claude-issue-runner skill names slash commands and
# operator scripts to a reader who is in a FOREIGN repo and cannot check whether
# any of them exist. A renamed command or a dropped script would turn the skill
# into confident wrong instructions with no error anywhere — the same silent
# failure mode the skill itself warns about.
#
# This test pins the skill's COMMAND and SCRIPT surface to the package, in both
# directions (test-skill-labels.sh does the same for the label vocabulary):
#
#   Case 1  the skill exists and is non-empty
#   Case 2  forward — every `/name` the skill names has a commands/name.md
#   Case 3  backward — every shipped command (minus a justified exclusion list)
#           is named in the skill
#   Case 4  forward — every `name.sh` the skill names is an executable file at
#           the package root
#   Case 5  the seven operator scripts are each named (the skill's whole point
#           is knowing which one to reach for)
#   Case 6  the skill states where the code and full documentation live
#
# This test WRITES NOTHING and needs no $HOME. It only reads repository files.
#
# Run: bash tests/test-skill-surface.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FAIL=0

SKILL="$ROOT/skills/claude-issue-runner/SKILL.md"

# ---- Case 1: skill exists ----
# Exit immediately if it is missing: every later case would report the same
# single cause otherwise, drowning the real signal.
if [ ! -s "$SKILL" ]; then
  echo "FAIL: skill missing or empty at $SKILL"
  echo "----------------------------------------"
  echo "skill-surface: FAILURES"
  exit 1
fi
echo "PASS: claude-issue-runner/SKILL.md exists and is non-empty"

# Tokens are read from inside backtick spans only: prose may mention a name in
# passing, but a backticked token is the skill telling the reader to TYPE it.
# Splitting each span on whitespace keeps `cleanup-run.sh --issue <N>` usable
# while a path token (anything containing a slash) is dropped by the callers —
# `$HOME/.claude/scripts/run-issues/orchestrate.sh` is a location, not a name.
skill_tokens() {
  grep -oE '`[^`]+`' "$SKILL" \
    | tr -d '`' | tr ' ' '\n' \
    | sed 's/[.,;:()]*$//' \
    | grep -v '^$'
}

# ---- Case 2: every slash command the skill names is shipped ----
CMD_TOKENS="$(skill_tokens | grep -E '^/[a-z][a-z0-9-]*$' | sed 's|^/||' | sort -u)"
if [ -z "$CMD_TOKENS" ]; then
  echo "FAIL: the skill names no slash commands at all — token extraction broke?"; FAIL=1
else
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    if [ -f "$ROOT/commands/$cmd.md" ]; then
      echo "PASS: skill command '/$cmd' is shipped as commands/$cmd.md"
    else
      echo "FAIL: skill names '/$cmd' but commands/$cmd.md does not exist"; FAIL=1
    fi
  done <<< "$CMD_TOKENS"
fi

# ---- Case 3: every shipped command the skill should cover is named ----
# Exclusions, each because the command is NOT part of this system:
#   refresh — a generic "bring the repo up to date" helper, usable with or
#             without the runner
EXCLUDE_CMDS="refresh"
for f in "$ROOT"/commands/*.md; do
  [ -f "$f" ] || continue
  base="$(basename "$f" .md)"
  skip=0
  for ex in $EXCLUDE_CMDS; do [ "$base" = "$ex" ] && skip=1; done
  if [ "$skip" -eq 1 ]; then
    echo "PASS: shipped command '/$base' excluded by design (not part of this system)"
    continue
  fi
  if grep -qF -- "\`/$base\`" "$SKILL"; then
    echo "PASS: shipped command '/$base' is named in the skill"
  else
    echo "FAIL: shipped command '/$base' is not named in the skill"; FAIL=1
  fi
done

# ---- Case 4: every script the skill names exists and is executable ----
SH_TOKENS="$(skill_tokens | grep -v '/' | grep -E '^[a-z][a-z0-9-]*\.sh$' | sort -u)"
if [ -z "$SH_TOKENS" ]; then
  echo "FAIL: the skill names no scripts at all — token extraction broke?"; FAIL=1
else
  while IFS= read -r sh; do
    [ -n "$sh" ] || continue
    if [ -x "$ROOT/$sh" ]; then
      echo "PASS: skill script '$sh' exists and is executable at the package root"
    else
      echo "FAIL: skill names '$sh' but it is not an executable file at the package root"; FAIL=1
    fi
  done <<< "$SH_TOKENS"
fi

# ---- Case 5: the operator scripts are each named ----
# The skill's job is telling a reader WHICH script to reach for. These seven are
# the ones a human runs by hand; the pollers, the installer, the status renderer
# and self-update are LaunchAgent/setup surface and deliberately out of scope.
#   orchestrate.sh  one issue -> one run -> one PR
#   run-epic.sh     launch / stop a whole epic
#   pr-watch.sh     CI wait, conflict resolution, auto-merge
#   status.sh       read-only aggregate state of every run
#   stop-run.sh     stop one live run without tearing it down
#   cleanup-run.sh  tear down one run's artefacts
#   auto-clean.sh   the same teardown, label-driven, and close the issue
for sh in orchestrate.sh run-epic.sh pr-watch.sh status.sh stop-run.sh cleanup-run.sh auto-clean.sh; do
  if grep -qF -- "\`$sh\`" "$SKILL"; then
    echo "PASS: operator script '$sh' is named in the skill"
  else
    echo "FAIL: operator script '$sh' is not named in the skill"; FAIL=1
  fi
done

# ---- Case 6: the skill says where the code and full documentation live ----
# Without this pointer the skill is a dead end: a reader who needs the state
# machine, the exit codes or the security model has nowhere to go. The pointer
# is deliberately a local install path, not a repository URL: the package must
# stay readable when it is installed outside the organisation that hosts it.
for ptr in '$HOME/.claude/scripts/run-issues'; do
  if grep -qF -- "$ptr" "$SKILL"; then
    echo "PASS: skill points at '$ptr'"
  else
    echo "FAIL: skill does not point at '$ptr'"; FAIL=1
  fi
done

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "skill-surface: all passed" || echo "skill-surface: FAILURES"
[ "$FAIL" -eq 0 ]
