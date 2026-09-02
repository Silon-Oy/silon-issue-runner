#!/usr/bin/env bash
# test-coding-standard-adoption.sh — the runner must make an unadopted coding
# standard visible where a human already looks.
#
# Issue #195: principles/coding.md reaches the orchestrated agent as a system
# prompt (#175), but not the co-developer who codes by hand in the target repo
# with a plain session. #178 designed the fix — a copy at .claude/principles.md
# plus one `@` import in the repo's own CLAUDE.md, documented in README.md §5 —
# and deliberately scoped adoption out. Adoptions are therefore zero, and nothing
# said so. S10 now says it, once, in the PR body.
#
# The check is deliberately NOT fail-closed, exactly like the language reader
# next to it: adoption is a reviewed human change in the target repo, and a run
# must not stop because it has not been made yet. That asymmetry is the whole
# point, so the test asserts BOTH directions — a note that never appears and a
# note that always appears are equally broken.
#
# Cases:
#   (a) import present and target file exists -> note absent
#   (b) CLAUDE.md exists, no import           -> note present
#   (c) no CLAUDE.md at all                   -> note present
#   (d) import present, target file missing   -> note present
#       (d) separates "the import line is there" from "the standard loads"; a
#       reader that only grepped for the line would pass (a)–(c) and still be
#       wrong, because an import to a file that was never committed loads
#       nothing.
#
# Driven the same way as test-language-declaration.sh: orchestrate.sh in resume
# mode (PROCEED) jumps straight to phase_b/S10 with claude, git and gh mocked via
# PATH shims, and the assertion is made against $RD/pr-body.md on disk because
# that is the artefact the orchestrator builds.
#
# Run: bash tests/test-coding-standard-adoption.sh   (exit 0 = all pass)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ORCH="$ROOT/orchestrate.sh"
STATE_LIB="$ROOT/lib/state.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

WORK=$(mktemp -d -t coding-std.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
git -C "$WORK" init -q "repo"
WORKTREE="$WORK/worktree"
mkdir -p "$WORKTREE/.claude"

BIN="$WORK/bin"
mkdir -p "$BIN"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
  echo "https://github.com/acme/widgets/pull/42"
fi
exit 0
SH
chmod +x "$BIN/gh"

cat > "$BIN/git" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$BIN/git"

cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
echo "IMPLEMENTER_RESULT: SUCCESS"
echo "EVOLUTION_RESULT: OK"
SH
chmod +x "$BIN/claude"

# shellcheck source=lib/state.sh
. "$STATE_LIB"

RID="20260902-1000-issue-195"
RD="$REPO/.claude/run-issues/$RID"

setup_run() {
  rm -rf "$RD"
  state_init "$RD" "$RID" "$REPO" "195"
  state_set "$RD" "branch" "auto-run/issue-195-x"
  state_set "$RD" "worktree_path" "$WORKTREE"
  state_set "$RD" "cycle_review_decision" "PROCEED"
  printf '{"title":"t","body":"b","comments":[],"labels":[]}\n' > "$RD/issue.json"
  echo "CYCLE_REVIEW_DECISION: PROCEED" > "$RD/01-cycle-review.out"
}

run_orch() {
  ( cd "$REPO" && \
    PATH="$BIN:$PATH" \
    RUN_ISSUES_AUTO=1 RUN_ISSUES_REVIEW_GATE=auto \
    RUN_ISSUES_CLAUDE_CMD="$BIN/claude" \
    RUN_ISSUES_LOCK_ROOT="$WORK/locks" \
    "$ORCH" --resume "$RD" --decision PROCEED ) >/dev/null 2>&1
}

# The note's stable fingerprint. Kept as one variable so a reworded note breaks
# in one place, not four.
NOTE_MARK='Coding standard not loaded'

FAIL=0

# === (a) import present, target file exists -> note absent =================
cat > "$WORKTREE/CLAUDE.md" <<'MD'
# Widgets

@.claude/principles.md
MD
echo "# copy of the coding standard" > "$WORKTREE/.claude/principles.md"
setup_run
run_orch
if [ ! -f "$RD/pr-body.md" ]; then
  echo "FAIL (a): pr-body.md was never written"; FAIL=1
elif grep -qF "$NOTE_MARK" "$RD/pr-body.md"; then
  echo "FAIL (a): note appeared even though the repo loads the standard"
  sed -n '1,8p' "$RD/pr-body.md" | sed 's/^/      /'
  FAIL=1
else
  echo "PASS (a): no note when the import resolves to an existing copy"
fi

# The documented line is bare, but a leading ./ or indentation is the same
# import; the path is what counts.
cat > "$WORKTREE/CLAUDE.md" <<'MD'
# Widgets

  @./.claude/principles.md
MD
setup_run
run_orch
if grep -qF "$NOTE_MARK" "$RD/pr-body.md" 2>/dev/null; then
  echo "FAIL (a2): an indented ./-prefixed import was not recognised"; FAIL=1
else
  echo "PASS (a2): indentation and a ./ prefix do not change the import"
fi

# === (b) CLAUDE.md exists, no import -> note present =======================
cat > "$WORKTREE/CLAUDE.md" <<'MD'
# Widgets

## Testing

Run the suite before pushing.
MD
setup_run
run_orch
if grep -qF "$NOTE_MARK" "$RD/pr-body.md" 2>/dev/null; then
  echo "PASS (b): note present when CLAUDE.md carries no import"
else
  echo "FAIL (b): a CLAUDE.md without the import must get the note"; FAIL=1
fi

# === (c) no CLAUDE.md at all -> note present ===============================
rm -f "$WORKTREE/CLAUDE.md"
setup_run
run_orch
if grep -qF "$NOTE_MARK" "$RD/pr-body.md" 2>/dev/null; then
  echo "PASS (c): note present when the repo has no CLAUDE.md"
else
  echo "FAIL (c): a missing CLAUDE.md is a missing import, so the note is due"
  FAIL=1
fi

# === (d) import present, target file missing -> note present ===============
cat > "$WORKTREE/CLAUDE.md" <<'MD'
# Widgets

@.claude/principles.md
MD
rm -f "$WORKTREE/.claude/principles.md"
setup_run
run_orch
if grep -qF "$NOTE_MARK" "$RD/pr-body.md" 2>/dev/null; then
  echo "PASS (d): note present when the import points at a missing file"
else
  echo "FAIL (d): an import to a file that does not exist loads nothing"
  FAIL=1
fi

# === The run is never blocked by the check =================================
# Not fail-closed: the note is advisory, so the PR body must still be complete.
if grep -qF "Closes #195" "$RD/pr-body.md" 2>/dev/null; then
  echo "PASS: the run finished the PR body despite the missing adoption"
else
  echo "FAIL: the check must not stop the run"; FAIL=1
fi

# === The documented shape and the reader agree =============================
# Two ideas of "what counts as adoption" is the duplication CLAUDE.md §7 forbids,
# so README.md §5 must actually document the path the reader resolves.
if grep -qF '@.claude/principles.md' "$ROOT/README.md" \
   && grep -qF 'CODING_STANDARD_IMPORT_PATH' "$ORCH"; then
  echo "PASS: README.md §5 documents the import orchestrate.sh reads"
else
  echo "FAIL: the documented shape and the reader have drifted apart"; FAIL=1
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "coding-standard-adoption: all passed" || echo "coding-standard-adoption: FAILURES"
[ "$FAIL" -eq 0 ]
