#!/usr/bin/env bash
# test-evolution-context.sh — S9 evolution sees what the change was FOR.
#
# Issue #310: evolution used to see only the implementer log tail, so it could
# judge hygiene but not whether the change solves the issue. It now receives the
# issue body and the cycle review output (with its Ω verification plan) under
# the same placeholders as the implementer, and its Δψ lines reach the PR body.
#
# Driven like test-language-declaration.sh: orchestrate.sh in resume mode
# (PROCEED) with claude, git and gh shimmed; assertions read the rendered
# $RD/03-evolution.prompt and $RD/pr-body.md from disk.
#
# Cases:
#   (a) cycle review with an Ω section, issue body carrying a literal {{…}}
#       -> both reach the prompt verbatim; the Δψ line lands in the PR body
#   (b) no 01-cycle-review.out (older run / restart) -> evolution still runs,
#       PR body is written, no Δψ section when evolution emits none
#   (c) the draft decision still follows EVOLUTION_RESULT alone
#
# Run: bash tests/test-evolution-context.sh   (exit 0 = all pass)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ORCH="$ROOT/orchestrate.sh"
STATE_LIB="$ROOT/lib/state.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

WORK=$(mktemp -d -t evo-ctx.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
git -C "$WORK" init -q "repo"
WORKTREE="$WORK/worktree"
mkdir -p "$WORKTREE"

BIN="$WORK/bin"
mkdir -p "$BIN"

cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
if [ "\$1" = "pr" ] && [ "\$2" = "create" ]; then
  printf '%s\n' "\$*" > "$WORK/gh-pr-create.args"
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

# The evolution reply is read from a file so each case can choose it.
cat > "$BIN/claude" <<SH
#!/usr/bin/env bash
echo "IMPLEMENTER_RESULT: SUCCESS"
cat "$WORK/evo-reply" 2>/dev/null
SH
chmod +x "$BIN/claude"

# shellcheck source=lib/state.sh
. "$STATE_LIB"

RID="20261015-1000-issue-310"
RD="$REPO/.claude/run-issues/$RID"

BODY_MARK='Goal: evolution judges the root cause {{BRANCH}}'
OMEGA_MARK='## Ω — todennussuunnitelma'

setup_run() {
  rm -rf "$RD" "$WORK/gh-pr-create.args"
  state_init "$RD" "$RID" "$REPO" "310"
  state_set "$RD" "branch" "auto-run/issue-310-x"
  state_set "$RD" "worktree_path" "$WORKTREE"
  state_set "$RD" "cycle_review_decision" "PROCEED"
  jq -n --arg b "$BODY_MARK" '{title:"t",body:$b,comments:[],labels:[]}' > "$RD/issue.json"
}

run_orch() {
  ( cd "$REPO" && \
    PATH="$BIN:$PATH" \
    RUN_ISSUES_AUTO=1 RUN_ISSUES_REVIEW_GATE=auto \
    RUN_ISSUES_CLAUDE_CMD="$BIN/claude" \
    RUN_ISSUES_LOCK_ROOT="$WORK/locks" \
    "$ORCH" --resume "$RD" --decision PROCEED ) >/dev/null 2>&1
}

FAIL=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAIL=1; }

# === (a) Ω present, Δψ emitted =============================================
setup_run
printf '%s\n' "## Σ — goal" "$OMEGA_MARK" "- bash tests/run-all.sh" "CYCLE_REVIEW_DECISION: PROCEED" \
  > "$RD/01-cycle-review.out"
printf '%s\n' "EVOLUTION_DELTA_PSI: lock files leak on every timeout" "EVOLUTION_RESULT: CLEAN" > "$WORK/evo-reply"
run_orch
P="$RD/03-evolution.prompt"
if [ ! -f "$P" ]; then
  fail "(a): 03-evolution.prompt was never rendered"
else
  grep -qF "$BODY_MARK" "$P" && pass "(a): issue body reaches the prompt verbatim (no {{…}} expansion)" \
    || fail "(a): issue body missing or expanded in the evolution prompt"
  grep -qF "$OMEGA_MARK" "$P" && pass "(a): cycle review Ω section reaches the prompt" \
    || fail "(a): cycle review output missing from the evolution prompt"
  if grep -qE '\{\{(ISSUE_BODY|CYCLE_REVIEW_OUTPUT)\}\}' "$P"; then
    fail "(a): placeholder left unrendered"
  else
    pass "(a): no unrendered placeholders"
  fi
fi
if grep -qF -- '- lock files leak on every timeout' "$RD/pr-body.md" 2>/dev/null \
   && grep -qF 'Δψ' "$RD/pr-body.md"; then
  pass "(a): Δψ line lands in the PR body as its own row"
else
  fail "(a): Δψ line did not reach pr-body.md"
fi
if grep -qF -- '--draft' "$WORK/gh-pr-create.args" 2>/dev/null; then
  fail "(c): a Δψ line must not turn the PR into a draft"
else
  pass "(c): CLEAN + Δψ still opens a ready PR"
fi

# === (b) no cycle review output, no Δψ =====================================
setup_run
echo "EVOLUTION_RESULT: CLEAN" > "$WORK/evo-reply"
run_orch
if [ -f "$RD/03-evolution.prompt" ] && [ -f "$RD/pr-body.md" ]; then
  pass "(b): evolution runs and the PR body is written without 01-cycle-review.out"
else
  fail "(b): missing cycle review output broke S9/S10"
fi
if grep -qF 'Δψ' "$RD/pr-body.md" 2>/dev/null; then
  fail "(b): Δψ section appeared although evolution emitted none"
else
  pass "(b): no Δψ section when evolution emits none"
fi

# === (c) NEEDS_FOLLOWUP still drafts =======================================
setup_run
echo "CYCLE_REVIEW_DECISION: PROCEED" > "$RD/01-cycle-review.out"
echo "EVOLUTION_RESULT: NEEDS_FOLLOWUP — goal not met" > "$WORK/evo-reply"
run_orch
if grep -qF -- '--draft' "$WORK/gh-pr-create.args" 2>/dev/null; then
  pass "(c): NEEDS_FOLLOWUP still opens a draft PR"
else
  fail "(c): NEEDS_FOLLOWUP no longer drafts"
fi

# === The prompt carries the instructions the issue asks for ===============
PROMPT_SRC="$ROOT/prompts/03-evolution.md"
for needle in '{{ISSUE_BODY}}' '{{CYCLE_REVIEW_OUTPUT}}' 'Ω' 'juurisy' 'Δψ' 'EVOLUTION_DELTA_PSI:' 'Ω-osiota ei ole'; do
  grep -qF "$needle" "$PROMPT_SRC" && pass "prompt carries '$needle'" || fail "prompt lost '$needle'"
done

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "evolution-context: all passed" || echo "evolution-context: FAILURES"
[ "$FAIL" -eq 0 ]
