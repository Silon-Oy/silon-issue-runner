#!/usr/bin/env bash
# test-pr-watch-security-gate.sh — the security merge gate in pr-watch.sh
# (issue #334). A green, mergeable, labelled PR (pr_decide => MERGE) with the gate
# ON first gets an agent review of its final diff. The agent is stubbed through
# RUN_ISSUES_CLAUDE_CMD (CLAUDE.md §5.5) and gh is a PATH shim — no network.
#
#   A) clean                 -> merge (bound to the reviewed head), 1 agent call
#   B) finding fixed         -> fix commit, push, CI revalidated, new head
#                               reviewed clean -> merge, 3 agent calls
#   C) fix fails             -> hold: needs-human + comment listing the finding,
#                               exit 10, no merge; a held PR is skipped while the
#                               label is on, and once removed the SAME head is held
#                               again without a second review
#   D) launch failure (127)  -> hold, exit 10, no merge
#   E) unparseable result    -> hold, exit 10, no merge
#   F) same head             -> a head already reviewed clean is not reviewed
#                               again (0 agent calls) and merges
#   G) gate off              -> no agent call, merge, no gate events
#   H) below threshold       -> medium finding at the default threshold: reported
#                               in a comment, merged, no fix
#   I) repo threshold wins   -> base-branch config `low` beats machine `critical`:
#                               a medium finding holds
#   J) PR cannot lower it    -> a config on the PR head saying `critical` is
#                               ignored: a high finding holds
#   M..R) Codex reviewer (issue #335), stubbed through PR_WATCH_CODEX_CMD — no
#      real Codex is ever called:
#   M) codex clean           -> merge; codex reviewed, claude never did
#   N) codex fixes via claude-> a codex finding is fixed by the CLAUDE agent
#   O) codex missing         -> hold, no claude fall back, no merge
#   P) codex fails (rc=3)    -> hold; the real rc=3 is logged
#   Q) codex unparseable     -> hold
#   R) unknown reviewer      -> hold, nobody called
#
# Runs use a FOREIGN host so P9 local cleanup is skipped and the run-dir survives
# for assertions.
#
# Run: bash tests/test-pr-watch-security-gate.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRWATCH="$HERE/../pr-watch.sh"
STATE_LIB="$HERE/../lib/state.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available"
  exit 0
fi

FAIL=0
bad() { echo "FAIL $1: $2"; FAIL=1; }
ok()  { echo "PASS $1: $2"; }

# setup <name> — origin + repo + feature worktree + completed run (FOREIGN host),
# a gh shim and the stub agent. Sets WORK REPO WT ORIGIN RD BIN.
setup() {
  WORK=$(mktemp -d -t prwatch-secgate-"$1".XXXXXX)
  ORIGIN="$WORK/origin.git"; REPO="$WORK/repo"; WT="$WORK/wt-feature"
  git init -q --bare "$ORIGIN"
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  git init -q "$REPO"
  git -C "$REPO" symbolic-ref HEAD refs/heads/main
  (
    cd "$REPO"
    git config user.email t@t.t; git config user.name t
    git remote add origin "$ORIGIN"
    echo "v0" > f.txt
    git add f.txt; git commit -qm init
    git push -q origin main
    git checkout -q -b feature/x
    echo "feature (vulnerable)" > f.txt
    git commit -qam feature
    git push -q origin feature/x
    git checkout -q main
  )
  ( cd "$REPO" && git worktree add -q "$WT" feature/x )

  RD="$REPO/.claude/run-issues/20261023-1200-issue-5"
  # shellcheck source=../lib/state.sh
  . "$STATE_LIB"
  state_init "$RD" "20261023-1200-issue-5" "$REPO" "5"
  state_set "$RD" "pr_url" "https://github.com/Silon-Oy/x/pull/55"
  state_set "$RD" "worktree_path" "$WT"
  state_set "$RD" "branch" "feature/x"
  local tmp; tmp=$(mktemp); jq '.host = "some-other-host"' "$RD/run.json" > "$tmp"; mv "$tmp" "$RD/run.json"
  state_finalize "$RD" "completed"

  BIN="$WORK/bin"; mkdir -p "$BIN"
  : > "$WORK/labels.log"; : > "$WORK/comments.log"; : > "$WORK/calls.log"
  echo '[{"name":"auto-merge"}]' > "$WORK/pr_labels"
  cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
case "\$1" in
  api) printf '%s\n' "\$*" >> "$WORK/labels.log"; exit 0 ;;
  auth) exit 0 ;;
esac
case "\$1 \$2" in
  "pr view")
    if printf '%s' "\$*" | grep -q mergeable; then
      jq -n --argjson l "\$(cat "$WORK/pr_labels")" '{state:"OPEN",mergeable:"MERGEABLE",mergeStateStatus:"CLEAN",labels:\$l,
        statusCheckRollup:[{__typename:"CheckRun",name:"ci",status:"COMPLETED",conclusion:"SUCCESS"}],
        headRefName:"feature/x",baseRefName:"main"}'
    else
      echo '{"statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}'
    fi
    ;;
  "pr merge")   printf '%s\n' "\$*" >> "$WORK/merge.log"; echo "merged (mock)" ;;
  "pr comment") { cat; echo; echo "-----"; } >> "$WORK/comments.log" ;;
  "issue view") echo '{"state":"CLOSED"}' ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$BIN/gh"

  # The stub agent. Every call is logged as REVIEW or FIX (told apart by the
  # rendered prompt); the review answer comes from review-<n>.txt (n = review
  # call number, falling back to review.txt), and fix.sh (if any) is run as
  # the fix.
  cat > "$BIN/claude-mock" <<SH
#!/usr/bin/env bash
if printf '%s' "\$*" | grep -q 'tietoturvakorjaaja'; then
  echo FIX >> "$WORK/calls.log"
  [ -f "$WORK/fix.sh" ] && bash "$WORK/fix.sh"
  echo "MERGE_GATE_FIX_RESULT: FIXED"
  exit 0
fi
echo REVIEW >> "$WORK/calls.log"
n=\$(grep -c REVIEW "$WORK/calls.log")
if [ -f "$WORK/review-\$n.txt" ]; then cat "$WORK/review-\$n.txt"; else cat "$WORK/review.txt"; fi
[ -f "$WORK/review-rc" ] && exit "\$(cat "$WORK/review-rc")"
exit 0
SH
  chmod +x "$BIN/claude-mock"
  printf 'MERGE_GATE_RESULT: CLEAN\n' > "$WORK/review.txt"

  # The stub Codex: logs CODEX (+ its argv), reads the prompt from stdin and
  # writes codex-review.txt to the --output-last-message file, like codex exec.
  cat > "$BIN/codex-mock" <<SH
#!/usr/bin/env bash
echo CODEX >> "$WORK/calls.log"
printf '%s\n' "\$*" > "$WORK/codex-argv"
cat > /dev/null
o=""
while [ \$# -gt 0 ]; do
  [ "\$1" = "--output-last-message" ] && o="\$2"
  shift
done
[ -n "\$o" ] && [ -f "$WORK/codex-review.txt" ] && cp "$WORK/codex-review.txt" "\$o"
[ -f "$WORK/codex-rc" ] && exit "\$(cat "$WORK/codex-rc")"
exit 0
SH
  chmod +x "$BIN/codex-mock"
  printf 'MERGE_GATE_RESULT: CLEAN\n' > "$WORK/codex-review.txt"
}

# run_watch [ENV=VAL...] — run pr-watch on PR 55 with the gate ON; sets RC, OUT.
run_watch() {
  set +e
  OUT=$( env PATH="$BIN:$PATH" \
    RUN_ISSUES_LOCK_ROOT="$WORK/locks" \
    RUN_ISSUES_CLAUDE_CMD="$BIN/claude-mock" \
    PR_WATCH_ENABLE_SECURITY_GATE=1 PR_WATCH_ENABLE_SEMANTIC_CHECK=0 \
    PR_WATCH_SECURITY_REVIEW_TIMEOUT=30 PR_WATCH_SECURITY_FIX_TIMEOUT=30 \
    PR_WATCH_CI_MAX_POLLS=1 PR_WATCH_CI_POLL_SECS=1 \
    "$@" "$PRWATCH" "$REPO" 55 2>&1 )
  RC=$?
}

calls() { grep -c "^$1$" "$WORK/calls.log" 2>/dev/null || true; }
merged() { [ -s "$WORK/merge.log" ]; }
events() { grep -c "\"event\":\"$1\"" "$RD/state.jsonl" 2>/dev/null || true; }
show() { echo "$OUT" | sed "s/^/$1| /"; echo "$1| (rc=$RC)"; }

FINDING_HIGH='FINDING: high | high | f.txt:1 | user input reaches a shell command unescaped'

# ===========================================================================
echo "=== A: clean -> merge ==="
setup A
SHA=$(git -C "$WT" rev-parse HEAD)
run_watch; show A
[ "$RC" = 0 ] || bad A "rc $RC, want 0"
merged || bad A "not merged"
grep -q -- "--match-head-commit $SHA" "$WORK/merge.log" 2>/dev/null || bad A "merge not bound to the reviewed head $SHA"
[ "$(calls REVIEW)" = 1 ] || bad A "review calls $(calls REVIEW), want 1"
[ "$(calls FIX)" = 0 ] || bad A "unexpected fix call"
grep -q "\"event\":\"merge_gate_reviewed\".*\"sha\":\"$SHA\".*\"result\":\"clean\"" "$RD/state.jsonl" || bad A "clean result not recorded against the head"
[ "$(jq -r .status "$RD/run.json")" = merged ] || bad A "status not merged"
[ "$FAIL" = 0 ] && ok A "clean head merged"
[ -n "${KEEP:-}" ] || rm -rf "$WORK"

# ===========================================================================
echo "=== B: finding fixed -> revalidate -> re-review -> merge ==="
FAIL_BEFORE=$FAIL
setup B
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$FINDING_HIGH" > "$WORK/review-1.txt"
printf 'MERGE_GATE_RESULT: CLEAN\n' > "$WORK/review-2.txt"
cat > "$WORK/fix.sh" <<'SH'
echo "feature (escaped)" > f.txt
git add f.txt
git -c user.email=s@t.t -c user.name=s commit -qm "fix: escape shell argument"
SH
SHA0=$(git -C "$WT" rev-parse HEAD)
run_watch; show B
SHA1=$(git -C "$WT" rev-parse HEAD)
[ "$RC" = 0 ] || bad B "rc $RC, want 0"
merged || bad B "not merged"
[ "$SHA1" != "$SHA0" ] || bad B "head did not move"
[ "$(git --git-dir="$ORIGIN" rev-parse feature/x)" = "$SHA1" ] || bad B "fix not pushed"
[ "$(tr '\n' ' ' < "$WORK/calls.log")" = "REVIEW FIX REVIEW " ] || bad B "calls '$(tr '\n' ' ' < "$WORK/calls.log")', want review, fix, review"
grep -q -- "--match-head-commit $SHA1" "$WORK/merge.log" 2>/dev/null || bad B "merge not bound to the fixed head"
[ "$(events merge_gate_fix_attempted)" = 1 ] || bad B "fix attempts $(events merge_gate_fix_attempted), want 1"
[ "$(events merge_gate_fix_pushed)" = 1 ] || bad B "no merge_gate_fix_pushed"
grep -q 'f.txt:1' "$RD/07-security-fix.prompt" || bad B "fix prompt does not carry the finding"
[ "$(events merge_gate_held)" = 0 ] || bad B "unexpected hold"
[ "$FAIL" = "$FAIL_BEFORE" ] && ok B "finding fixed, revalidated, re-reviewed, merged"
[ -n "${KEEP:-}" ] || rm -rf "$WORK"

# ===========================================================================
echo "=== C: fix fails -> hold; held while labelled; same head re-held unreviewed ==="
FAIL_BEFORE=$FAIL
setup C
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$FINDING_HIGH" > "$WORK/review.txt"
# no fix.sh: the fix agent makes no commit
run_watch; show C
[ "$RC" = 10 ] || bad C "rc $RC, want 10"
merged && bad C "merged despite a held finding"
grep -q 'labels\[\]=needs-human' "$WORK/labels.log" || bad C "needs-human not added"
grep -q 'f.txt:1' "$WORK/comments.log" || bad C "comment does not list the finding"
grep -q 'ei tuottanut korjaavaa committia' "$WORK/comments.log" || bad C "comment does not say why"
[ "$(jq -r .status "$RD/run.json")" = blocked ] || bad C "status not blocked"
[ "$(jq -r .blocked_reason "$RD/run.json")" = security_gate_failed_pr_55 ] || bad C "blocked_reason '$(jq -r .blocked_reason "$RD/run.json")'"
[ "$(tr '\n' ' ' < "$WORK/calls.log")" = "REVIEW FIX " ] || bad C "calls '$(tr '\n' ' ' < "$WORK/calls.log")'"

# Held: the needs-human label is on the PR -> skipped, nothing called.
echo '[{"name":"auto-merge"},{"name":"needs-human"}]' > "$WORK/pr_labels"
run_watch; show C2
[ "$RC" = 4 ] || bad C2 "rc $RC, want 4 while needs-human is on"
[ "$(wc -l < "$WORK/calls.log" | tr -d ' ')" = 2 ] || bad C2 "agent called while held"

# The scan re-emits the held run (otherwise it would be stranded). The scan
# host-gates runs, so the run is made local (empty host) for this one call.
cp "$RD/run.json" "$WORK/run.json.bak"
TMPJ=$(mktemp); jq '.host = ""' "$RD/run.json" > "$TMPJ"; mv "$TMPJ" "$RD/run.json"
SCAN=$( env PATH="$BIN:$PATH" RUN_ISSUES_LOCK_ROOT="$WORK/locks" RUN_ISSUES_CLAUDE_CMD="$BIN/claude-mock" \
  PR_WATCH_ENABLE_SECURITY_GATE=1 "$PRWATCH" "$REPO" scan 2>&1 )
cp "$WORK/run.json.bak" "$RD/run.json"
echo "$SCAN" | grep -q 'candidates=1' || bad C2 "held run not re-emitted by the scan"
echo "$SCAN" | grep -q 'held by needs-human' || bad C2 "re-emitted held run not skipped by the hold gate"

# Label removed, head unchanged: the head is NOT reviewed again; held again.
echo '[{"name":"auto-merge"}]' > "$WORK/pr_labels"
: > "$WORK/comments.log"
run_watch; show C3
[ "$RC" = 10 ] || bad C3 "rc $RC, want 10 for the same held head"
[ "$(wc -l < "$WORK/calls.log" | tr -d ' ')" = 2 ] || bad C3 "same head reviewed or fixed again"
merged && bad C3 "merged the held head"
grep -q 'f.txt:1' "$WORK/comments.log" || bad C3 "re-hold comment does not list the finding"
[ "$FAIL" = "$FAIL_BEFORE" ] && ok C "failed fix held for a human; same head not reviewed twice"
[ -n "${KEEP:-}" ] || rm -rf "$WORK"

# ===========================================================================
echo "=== D: launch failure (rc=127) -> hold ==="
FAIL_BEFORE=$FAIL
setup D
: > "$WORK/review.txt"
echo 127 > "$WORK/review-rc"
run_watch; show D
[ "$RC" = 10 ] || bad D "rc $RC, want 10"
merged && bad D "merged without a review"
grep -q 'ei toteutunut' "$WORK/comments.log" || bad D "comment does not say the review did not happen"
grep -q 'labels\[\]=needs-human' "$WORK/labels.log" || bad D "needs-human not added"
grep -q '"result":"launch_failed"' "$RD/state.jsonl" || bad D "launch_failed not recorded"
[ "$(calls FIX)" = 0 ] || bad D "fix attempted without findings"
[ "$FAIL" = "$FAIL_BEFORE" ] && ok D "launch failure held, never clean"
[ -n "${KEEP:-}" ] || rm -rf "$WORK"

# ===========================================================================
echo "=== E: unparseable result -> hold ==="
FAIL_BEFORE=$FAIL
setup E
printf 'Everything looks fine to me!\n' > "$WORK/review.txt"
run_watch; show E
[ "$RC" = 10 ] || bad E "rc $RC, want 10"
merged && bad E "merged on an unparseable review"
grep -q 'jäsentymätön' "$WORK/comments.log" || bad E "comment does not name the parse failure"
[ "$FAIL" = "$FAIL_BEFORE" ] && ok E "unparseable result held"
[ -n "${KEEP:-}" ] || rm -rf "$WORK"

# ===========================================================================
echo "=== F: same head already reviewed clean -> no review, merge ==="
FAIL_BEFORE=$FAIL
setup F
SHA=$(git -C "$WT" rev-parse HEAD)
state_event "$RD" merge_gate_reviewed gate=security pr=55 "sha=$SHA" result=clean holding=0 hold_min=high
run_watch; show F
[ "$RC" = 0 ] || bad F "rc $RC, want 0"
merged || bad F "not merged"
[ "$(calls REVIEW)" = 0 ] || bad F "head reviewed twice"
[ "$(events merge_gate_reviewed)" = 1 ] || bad F "a second review was recorded"
[ "$FAIL" = "$FAIL_BEFORE" ] && ok F "reviewed head not reviewed again"
[ -n "${KEEP:-}" ] || rm -rf "$WORK"

# ===========================================================================
echo "=== G: gate off -> unchanged behaviour ==="
FAIL_BEFORE=$FAIL
setup G
run_watch PR_WATCH_ENABLE_SECURITY_GATE=0; show G
[ "$RC" = 0 ] || bad G "rc $RC, want 0"
merged || bad G "not merged"
[ -s "$WORK/calls.log" ] && bad G "agent called with the gate off"
grep -q -- '--match-head-commit' "$WORK/merge.log" && bad G "merge bound to a head with the gate off"
[ "$(events merge_gate_reviewed)" = 0 ] || bad G "gate event written with the gate off"
[ "$FAIL" = "$FAIL_BEFORE" ] && ok G "gate off leaves the merge path unchanged"
[ -n "${KEEP:-}" ] || rm -rf "$WORK"

# ===========================================================================
echo "=== H: medium finding at the default threshold -> report + merge ==="
FAIL_BEFORE=$FAIL
setup H
printf 'FINDING: medium | low | f.txt:1 | verbose error message\nMERGE_GATE_RESULT: FINDINGS\n' > "$WORK/review.txt"
run_watch; show H
[ "$RC" = 0 ] || bad H "rc $RC, want 0"
merged || bad H "not merged"
[ "$(calls FIX)" = 0 ] || bad H "fix attempted below the threshold"
grep -q 'verbose error message' "$WORK/comments.log" || bad H "finding not reported in a comment"
grep -q 'labels\[\]=needs-human' "$WORK/labels.log" && bad H "needs-human added below the threshold"
[ "$FAIL" = "$FAIL_BEFORE" ] && ok H "sub-threshold finding reported, merged"
[ -n "${KEEP:-}" ] || rm -rf "$WORK"

# ===========================================================================
echo "=== I: repo threshold (base branch) wins over the machine's ==="
FAIL_BEFORE=$FAIL
setup I
( cd "$REPO" && mkdir -p .claude && echo '{"security":{"hold_min_severity":"low"}}' > .claude/run-issues.json \
  && git add .claude/run-issues.json && git commit -qm cfg && git push -q origin main )
printf 'FINDING: medium | low | f.txt:1 | verbose error message\nMERGE_GATE_RESULT: FINDINGS\n' > "$WORK/review.txt"
run_watch PR_WATCH_SECURITY_HOLD_MIN_SEVERITY=critical PR_WATCH_MAX_SECURITY_FIXES=0; show I
[ "$RC" = 10 ] || bad I "rc $RC, want 10 (repo 'low' should beat machine 'critical')"
merged && bad I "merged a finding the repo threshold holds"
grep -q '"hold_min":"low"' "$RD/state.jsonl" || bad I "threshold 'low' not recorded"
[ "$FAIL" = "$FAIL_BEFORE" ] && ok I "repo threshold wins"
[ -n "${KEEP:-}" ] || rm -rf "$WORK"

# ===========================================================================
echo "=== J: the PR under review cannot lower its own threshold ==="
FAIL_BEFORE=$FAIL
setup J
( cd "$WT" && mkdir -p .claude && echo '{"security":{"hold_min_severity":"critical"}}' > .claude/run-issues.json \
  && git add .claude/run-issues.json && git -c user.email=t@t.t -c user.name=t commit -qm cfg && git push -q origin feature/x )
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$FINDING_HIGH" > "$WORK/review.txt"
run_watch PR_WATCH_MAX_SECURITY_FIXES=0; show J
[ "$RC" = 10 ] || bad J "rc $RC, want 10 (head config must be ignored)"
merged && bad J "merged a high finding"
[ "$FAIL" = "$FAIL_BEFORE" ] && ok J "head config ignored"
[ -n "${KEEP:-}" ] || rm -rf "$WORK"

# ===========================================================================
echo "=== K: worktree gone -> hold, not a silent skip on every tick ==="
FAIL_BEFORE=$FAIL
setup K
( cd "$REPO" && git worktree remove --force "$WT" )
run_watch; show K
[ "$RC" = 10 ] || bad K "rc $RC, want 10"
merged && bad K "merged without a review"
[ "$(calls REVIEW)" = 0 ] || bad K "reviewed without a worktree"
grep -q 'labels\[\]=needs-human' "$WORK/labels.log" || bad K "needs-human not added"
grep -q 'ei toteutunut' "$WORK/comments.log" || bad K "no hold comment"
[ "$FAIL" = "$FAIL_BEFORE" ] && ok K "missing worktree held for a human"
[ -n "${KEEP:-}" ] || rm -rf "$WORK"

# ===========================================================================
echo "=== L: worktree ahead of the PR head -> hold, never review the local commit ==="
FAIL_BEFORE=$FAIL
setup L
( cd "$WT" && echo local > g.txt && git add g.txt && git -c user.email=t@t.t -c user.name=t commit -qm local-only )
run_watch; show L
[ "$RC" = 10 ] || bad L "rc $RC, want 10"
merged && bad L "merged although the worktree is not the PR head"
[ "$(calls REVIEW)" = 0 ] || bad L "reviewed a head GitHub would not merge"
grep -q 'labels\[\]=needs-human' "$WORK/labels.log" || bad L "needs-human not added"
grep -q 'ei ole PR:n head' "$WORK/comments.log" || bad L "hold comment does not name the head mismatch"
[ "$FAIL" = "$FAIL_BEFORE" ] && ok L "worktree ahead of the PR head held for a human"
[ -n "${KEEP:-}" ] || rm -rf "$WORK"

# ===========================================================================
echo "=== M: codex reviewer, clean -> merge, claude never reviews ==="
FAIL_BEFORE=$FAIL
setup M
SHA=$(git -C "$WT" rev-parse HEAD)
run_watch PR_WATCH_SECURITY_REVIEWER=codex PR_WATCH_CODEX_CMD="$BIN/codex-mock"; show M
[ "$RC" = 0 ] || bad M "rc $RC, want 0"
merged || bad M "not merged"
[ "$(calls CODEX)" = 1 ] || bad M "codex calls $(calls CODEX), want 1"
[ "$(calls REVIEW)" = 0 ] || bad M "claude reviewed although codex was selected"
grep -q -- '--sandbox read-only' "$WORK/codex-argv" 2>/dev/null || bad M "codex not run read-only: $(cat "$WORK/codex-argv" 2>/dev/null)"
grep -q "\"event\":\"merge_gate_reviewed\".*\"sha\":\"$SHA\".*\"result\":\"clean\"" "$RD/state.jsonl" || bad M "clean result not recorded"
[ "$(tr -d '[:space:]' < "$RD/06-security-review.exit")" = 0 ] || bad M ".exit not written"
[ "$FAIL" = "$FAIL_BEFORE" ] && ok M "codex review merged a clean head"
[ -n "${KEEP:-}" ] || rm -rf "$WORK"

# ===========================================================================
echo "=== N: codex finding -> claude fixes -> codex re-reviews -> merge ==="
FAIL_BEFORE=$FAIL
setup N
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$FINDING_HIGH" > "$WORK/codex-review.txt"
cat > "$WORK/fix.sh" <<SH
echo "feature (escaped)" > f.txt
git add f.txt
git -c user.email=s@t.t -c user.name=s commit -qm "fix: escape shell argument"
printf 'MERGE_GATE_RESULT: CLEAN\n' > "$WORK/codex-review.txt"
SH
run_watch PR_WATCH_SECURITY_REVIEWER=codex PR_WATCH_CODEX_CMD="$BIN/codex-mock"; show N
[ "$RC" = 0 ] || bad N "rc $RC, want 0"
merged || bad N "not merged"
[ "$(tr '\n' ' ' < "$WORK/calls.log")" = "CODEX FIX CODEX " ] || bad N "calls '$(tr '\n' ' ' < "$WORK/calls.log")', want codex, claude fix, codex"
[ "$FAIL" = "$FAIL_BEFORE" ] && ok N "codex finding fixed by the claude agent"
[ -n "${KEEP:-}" ] || rm -rf "$WORK"

# ===========================================================================
echo "=== O: codex selected but not installed -> hold, no claude fall back ==="
FAIL_BEFORE=$FAIL
setup O
run_watch PR_WATCH_SECURITY_REVIEWER=codex PR_WATCH_CODEX_CMD="$WORK/no-such-codex"; show O
[ "$RC" = 10 ] || bad O "rc $RC, want 10"
merged && bad O "merged without a review"
[ -s "$WORK/calls.log" ] && bad O "an agent was called: $(tr '\n' ' ' < "$WORK/calls.log")"
grep -q 'Codex-katselmoijaa ei voitu käynnistää' "$WORK/comments.log" || bad O "comment does not name the missing Codex"
grep -q 'labels\[\]=needs-human' "$WORK/labels.log" || bad O "needs-human not added"
grep -q '"result":"launch_failed"' "$RD/state.jsonl" || bad O "launch_failed not recorded"
[ "$FAIL" = "$FAIL_BEFORE" ] && ok O "missing codex held, claude not used instead"
[ -n "${KEEP:-}" ] || rm -rf "$WORK"

# ===========================================================================
echo "=== P: codex fails (rc=3) -> hold, the real rc is logged ==="
FAIL_BEFORE=$FAIL
setup P
echo 3 > "$WORK/codex-rc"
run_watch PR_WATCH_SECURITY_REVIEWER=codex PR_WATCH_CODEX_CMD="$BIN/codex-mock"; show P
[ "$RC" = 10 ] || bad P "rc $RC, want 10"
merged && bad P "merged on a failed review"
echo "$OUT" | grep -q 'codex review call for PR #55 returned rc=3' || bad P "real rc=3 not logged"
[ "$(tr -d '[:space:]' < "$RD/06-security-review.exit")" = 3 ] || bad P ".exit does not hold rc=3"
grep -q 'rc=3' "$WORK/comments.log" || bad P "comment does not carry rc=3"
[ "$(calls REVIEW)" = 0 ] || bad P "claude reviewed after codex failed"
[ "$FAIL" = "$FAIL_BEFORE" ] && ok P "failed codex held with its real rc"
[ -n "${KEEP:-}" ] || rm -rf "$WORK"

# ===========================================================================
echo "=== Q: codex unparseable result -> hold ==="
FAIL_BEFORE=$FAIL
setup Q
printf 'Looks good to me.\n' > "$WORK/codex-review.txt"
run_watch PR_WATCH_SECURITY_REVIEWER=codex PR_WATCH_CODEX_CMD="$BIN/codex-mock"; show Q
[ "$RC" = 10 ] || bad Q "rc $RC, want 10"
merged && bad Q "merged on an unparseable review"
grep -q 'jäsentymätön' "$WORK/comments.log" || bad Q "comment does not name the parse failure"
[ "$(calls REVIEW)" = 0 ] || bad Q "claude reviewed after codex"
[ "$FAIL" = "$FAIL_BEFORE" ] && ok Q "unparseable codex result held"
[ -n "${KEEP:-}" ] || rm -rf "$WORK"

# ===========================================================================
echo "=== R: unknown reviewer -> hold, nobody called ==="
FAIL_BEFORE=$FAIL
setup R
run_watch PR_WATCH_SECURITY_REVIEWER=gpt PR_WATCH_CODEX_CMD="$BIN/codex-mock"; show R
[ "$RC" = 10 ] || bad R "rc $RC, want 10"
merged && bad R "merged without a review"
[ -s "$WORK/calls.log" ] && bad R "an agent was called: $(tr '\n' ' ' < "$WORK/calls.log")"
grep -q 'tuntematon' "$WORK/comments.log" || bad R "comment does not name the unknown reviewer"
[ "$FAIL" = "$FAIL_BEFORE" ] && ok R "unknown reviewer held"
[ -n "${KEEP:-}" ] || rm -rf "$WORK"

# ===========================================================================
echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "pr-watch-security-gate: all passed" || echo "pr-watch-security-gate: FAILURES"
[ "$FAIL" -eq 0 ]
