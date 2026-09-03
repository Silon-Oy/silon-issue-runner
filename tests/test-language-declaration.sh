#!/usr/bin/env bash
# test-language-declaration.sh — the runner must not assert which human language
# a target repo speaks.
#
# Issue #177: the language of human-visible text (PR descriptions, issue
# comments, docs) used to arrive from the operator's personal instructions. That
# is their choice, not a property of the package, and a correct hit on a
# same-language repo is a coincidence rather than a derivation. The declaration
# now lives in the TARGET repo's own CLAUDE.md, and its shape is documented once
# in principles/coding.md: a heading line carrying the word `Languages`.
#
# The gate that closes the hole sits at issue-writing time (/new-issue,
# /new-epic), where a human is present. S10 is deliberately NOT fail-closed: a
# repo that has not been asked yet still gets its run, plus one line in the PR
# body saying the declaration is missing. That asymmetry is the whole point, so
# the test asserts BOTH directions — a note that never appears and a note that
# always appears are equally broken, and neither shows up in any other test.
#
# The assertion is made against $RD/pr-body.md on disk rather than the `gh pr
# create` call, because the body file is the artefact the orchestrator builds
# and the gh mock only ever sees a --body-file path.
#
# Driven the same way as test-pr-label-propagation.sh: orchestrate.sh in resume
# mode (PROCEED) jumps straight to phase_b/S10 with claude, git and gh mocked
# via PATH shims.
#
# Cases:
#   (a) worktree has no CLAUDE.md at all      -> note present
#   (b) worktree CLAUDE.md declares Languages -> note absent
#   (c) worktree CLAUDE.md exists, no heading -> note present
#       (c) separates "file exists" from "file declares"; a reader that only
#       checked for the file would pass (a) and (b) and still be wrong.
#
# Run: bash tests/test-language-declaration.sh   (exit 0 = all pass)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ORCH="$ROOT/orchestrate.sh"
STATE_LIB="$ROOT/lib/state.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

WORK=$(mktemp -d -t lang-decl.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
git -C "$WORK" init -q "repo"
WORKTREE="$WORK/worktree"
mkdir -p "$WORKTREE"

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

RID="20260902-1000-issue-177"
RD="$REPO/.claude/run-issues/$RID"

setup_run() {
  rm -rf "$RD"
  state_init "$RD" "$RID" "$REPO" "177"
  state_set "$RD" "branch" "auto-run/issue-177-x"
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
# in one place, not three.
NOTE_MARK='No language declaration'

FAIL=0

# === (a) no CLAUDE.md in the worktree -> note present ======================
rm -f "$WORKTREE/CLAUDE.md"
setup_run
run_orch
if [ ! -f "$RD/pr-body.md" ]; then
  echo "FAIL (a): pr-body.md was never written"; FAIL=1
elif grep -qF "$NOTE_MARK" "$RD/pr-body.md"; then
  echo "PASS (a): note present when the repo has no CLAUDE.md"
else
  echo "FAIL (a): expected the missing-declaration note in pr-body.md"
  sed -n '1,6p' "$RD/pr-body.md" | sed 's/^/      /'
  FAIL=1
fi

# === (b) CLAUDE.md declares the languages -> note absent ===================
cat > "$WORKTREE/CLAUDE.md" <<'MD'
# Widgets

## Languages

- Code and comments: English
- PR descriptions: Portuguese
MD
setup_run
run_orch
if grep -qF "$NOTE_MARK" "$RD/pr-body.md" 2>/dev/null; then
  echo "FAIL (b): note appeared even though the repo declares its languages"
  sed -n '1,6p' "$RD/pr-body.md" | sed 's/^/      /'
  FAIL=1
else
  echo "PASS (b): no note when the declaration is present"
fi

# The declaration is a heading, at any level and in any wording that carries the
# word — the shape documented in principles/coding.md, not a fixed line.
cat > "$WORKTREE/CLAUDE.md" <<'MD'
# Widgets

### Kielet (Languages)

- Documentation: Finnish
MD
setup_run
run_orch
if grep -qF "$NOTE_MARK" "$RD/pr-body.md" 2>/dev/null; then
  echo "FAIL (b2): heading variant not recognised as a declaration"; FAIL=1
else
  echo "PASS (b2): heading level and wording are free, the word is what counts"
fi

# === (c) CLAUDE.md exists but declares nothing -> note present =============
cat > "$WORKTREE/CLAUDE.md" <<'MD'
# Widgets

## Testing

Run the suite before pushing.
MD
setup_run
run_orch
if grep -qF "$NOTE_MARK" "$RD/pr-body.md" 2>/dev/null; then
  echo "PASS (c): note present when CLAUDE.md exists but declares no languages"
else
  echo "FAIL (c): a CLAUDE.md without a Languages heading must still get the note"
  FAIL=1
fi

# === The documented shape and the reader agree =============================
# Two ideas of "what counts as a declaration" is the duplication CLAUDE.md §7
# forbids, so the guarded page must actually document the word the reader greps.
PRINCIPLES="$ROOT/principles/coding.md"
if grep -qF 'Languages' "$PRINCIPLES" && grep -qF 'repo_declares_languages' "$ORCH"; then
  echo "PASS: principles/coding.md documents the shape orchestrate.sh reads"
else
  echo "FAIL: the documented shape and the reader have drifted apart"; FAIL=1
fi

# Both issue-writing commands must carry the gate; that is the primary port,
# and losing it silently would leave only the advisory note behind.
for cmd in "$ROOT/commands/issue-runner/new-issue.md" "$ROOT/commands/issue-runner/new-epic.md"; do
  if grep -qF 'languages' "$cmd"; then
    echo "PASS: $(basename "$cmd") carries the language gate"
  else
    echo "FAIL: $(basename "$cmd") lost the language gate"; FAIL=1
  fi
done

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "language-declaration: all passed" || echo "language-declaration: FAILURES"
[ "$FAIL" -eq 0 ]
