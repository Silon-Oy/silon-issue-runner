#!/usr/bin/env bash
# test-pr-watch-review-gate.sh — the code review merge gate in pr-watch.sh. It
# has no switch: it runs on every PR whose run's issue carried heavy-run (the
# run-dir's issue.json, read by issue_run_path), and stands where the human
# merge of a heavy-run PR used to. The mechanism is the shared merge gate
# (tests/test-pr-watch-security-gate.sh covers it in depth); these cases pin what
# is this gate's own: when it runs, what its prompts get, its default threshold.
#
#   A) heavy, clean          -> merge, 1 review; the prompt carries the issue,
#                               the confirmed hypothesis and the evolution
#                               step's review guide
#   B) standard issue        -> no agent call, merge, no gate events
#   C) no issue.json         -> not heavy: no agent call, merge
#   D) heavy, fix fails      -> hold: needs-human, exit 10, no merge, the
#                               comment says the gate runs because of heavy-run
#   E) heavy, low finding    -> below the default threshold (medium): reported
#                               in a comment, merged, no fix
#   F) heavy, finding fixed  -> review, fix, review -> merge on the fixed head;
#                               the fix prompt carries the finding and the issue
#
# The agent is stubbed through RUN_ISSUES_CLAUDE_CMD (CLAUDE.md §5.5) and gh is a
# PATH shim — no network. Runs use a FOREIGN host so P9 local cleanup is skipped
# and the run-dir survives for assertions.
#
# Run: bash tests/test-pr-watch-review-gate.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Hermetic: never source this machine's real env file (CLAUDE.md §5.5, #358).
export RUN_ISSUES_ENV_FILE="$HERE/.no-such-machine-env"
PRWATCH="$HERE/../pr-watch.sh"
STATE_LIB="$HERE/../lib/state.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available"
  exit 0
fi

FAIL=0
bad() { echo "FAIL $1: $2"; FAIL=1; }
ok()  { echo "PASS $1: $2"; }

HEAVY_LABELS='[{"name":"auto-run"},{"name":"auto-merge"},{"name":"heavy-run"}]'

# setup <name> [<issue-labels-json>|none] — origin + repo + feature worktree +
# completed run (FOREIGN host) whose issue.json carries the labels (default:
# heavy-run; `none` writes no issue.json), a gh shim and the stub agent. Sets
# WORK REPO WT ORIGIN RD BIN.
setup() {
  WORK=$(mktemp -d -t prwatch-reviewgate-"$1".XXXXXX)
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
    echo "feature (off by one)" > f.txt
    git commit -qam feature
    git push -q origin feature/x
    git checkout -q main
  )
  ( cd "$REPO" && git worktree add -q "$WT" feature/x )

  RD="$REPO/.claude/run-issues/20261030-1200-issue-5"
  # shellcheck source=../lib/state.sh
  . "$STATE_LIB"
  state_init "$RD" "20261030-1200-issue-5" "$REPO" "5"
  state_set "$RD" "pr_url" "https://github.com/Silon-Oy/x/pull/55"
  state_set "$RD" "worktree_path" "$WT"
  state_set "$RD" "branch" "feature/x"
  state_set "$RD" "confirmed_hypothesis" "H2 the loop bound is inclusive"
  local tmp; tmp=$(mktemp); jq '.host = "some-other-host"' "$RD/run.json" > "$tmp"; mv "$tmp" "$RD/run.json"
  state_finalize "$RD" "completed"
  local labels="${2:-$HEAVY_LABELS}"
  if [ "$labels" != none ]; then
    jq -n --argjson l "$labels" \
      '{title:"Pagination drops the last row",body:"Hyväksymiskriteeri: viimeinen rivi näkyy.",comments:[],labels:$l}' \
      > "$RD/issue.json"
  fi

  BIN="$WORK/bin"; mkdir -p "$BIN"
  : > "$WORK/labels.log"; : > "$WORK/comments.log"; : > "$WORK/calls.log"
  cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
case "\$1" in
  api) printf '%s\n' "\$*" >> "$WORK/labels.log"; exit 0 ;;
  auth) exit 0 ;;
esac
case "\$1 \$2" in
  "pr view")
    if printf '%s' "\$*" | grep -q mergeable; then
      jq -n '{state:"OPEN",mergeable:"MERGEABLE",mergeStateStatus:"CLEAN",labels:[{name:"auto-merge"}],
        statusCheckRollup:[{__typename:"CheckRun",name:"ci",status:"COMPLETED",conclusion:"SUCCESS"}],
        headRefName:"feature/x",baseRefName:"main"}'
    else
      echo '{"headRefOid":"'"\$(git -C "$WT" rev-parse HEAD)"'","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}'
    fi
    ;;
  "pr merge")   printf '%s\n' "\$*" >> "$WORK/merge.log"; echo "merged (mock)" ;;
  "pr comment") { cat; echo; echo "-----"; } >> "$WORK/comments.log" ;;
  "issue view") echo '{"state":"CLOSED"}' ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$BIN/gh"

  # Stub agent: REVIEW or FIX by the rendered prompt; the review answer comes
  # from review-<n>.txt (falling back to review.txt), fix.sh (if any) is the fix.
  cat > "$BIN/claude-mock" <<SH
#!/usr/bin/env bash
if printf '%s' "\$*" | grep -q 'koodikatselmuksen korjaaja'; then
  echo FIX >> "$WORK/calls.log"
  [ -f "$WORK/fix.sh" ] && bash "$WORK/fix.sh"
  echo "MERGE_GATE_FIX_RESULT: FIXED"
  exit 0
fi
echo REVIEW >> "$WORK/calls.log"
n=\$(grep -c REVIEW "$WORK/calls.log")
if [ -f "$WORK/review-\$n.txt" ]; then cat "$WORK/review-\$n.txt"; else cat "$WORK/review.txt"; fi
exit 0
SH
  chmod +x "$BIN/claude-mock"
  printf 'MERGE_GATE_RESULT: CLEAN\n' > "$WORK/review.txt"
}

# run_watch — pr-watch on PR 55, the other two gates OFF; sets RC, OUT.
run_watch() {
  set +e
  OUT=$( env PATH="$BIN:$PATH" \
    RUN_ISSUES_LOCK_ROOT="$WORK/locks" \
    RUN_ISSUES_CLAUDE_CMD="$BIN/claude-mock" \
    PR_WATCH_ENABLE_SECURITY_GATE=0 PR_WATCH_ENABLE_SEMANTIC_CHECK=0 \
    PR_WATCH_REVIEW_TIMEOUT=30 PR_WATCH_REVIEW_FIX_TIMEOUT=30 \
    PR_WATCH_CI_MAX_POLLS=1 PR_WATCH_CI_POLL_SECS=1 \
    "$PRWATCH" "$REPO" 55 2>&1 )
  RC=$?
}

calls() { grep -c "^$1$" "$WORK/calls.log" 2>/dev/null || true; }
merged() { [ -s "$WORK/merge.log" ]; }
events() { grep -c "\"event\":\"$1\"" "$RD/state.jsonl" 2>/dev/null || true; }
show() { echo "$OUT" | sed "s/^/$1| /"; echo "$1| (rc=$RC)"; }
done_case() { [ -n "${KEEP:-}" ] || rm -rf "$WORK"; }

FINDING_HIGH='FINDING: high | high | f.txt:1 | the last row is dropped when the page is full'

# ===========================================================================
echo "=== A: heavy-run, clean -> merge ==="
P=$FAIL
setup A
printf '## Katselmointiohje\n\n### Mihin katsoa\nlist.sh:12 the page boundary\n\nEVOLUTION_RESULT: DONE\n' > "$RD/03-evolution.out"
SHA=$(git -C "$WT" rev-parse HEAD)
run_watch; show A
[ "$RC" = 0 ] || bad A "rc $RC, want 0"
merged || bad A "not merged"
grep -q -- "--match-head-commit $SHA" "$WORK/merge.log" 2>/dev/null || bad A "merge not bound to the reviewed head"
[ "$(calls REVIEW)" = 1 ] || bad A "review calls $(calls REVIEW), want 1"
grep -q "\"event\":\"merge_gate_reviewed\".*\"gate\":\"review\".*\"result\":\"clean\"" "$RD/state.jsonl" \
  || bad A "clean review gate result not recorded"
grep -q 'Pagination drops the last row' "$RD/16-code-review.prompt" || bad A "prompt lacks the issue title"
grep -q 'viimeinen rivi näkyy' "$RD/16-code-review.prompt" || bad A "prompt lacks the issue body"
grep -q 'H2 the loop bound is inclusive' "$RD/16-code-review.prompt" || bad A "prompt lacks the confirmed hypothesis"
grep -q 'list.sh:12 the page boundary' "$RD/16-code-review.prompt" || bad A "prompt lacks the review guide"
grep -q '{{GATE_CONTEXT}}' "$RD/16-code-review.prompt" && bad A "placeholder not rendered"
[ "$FAIL" = "$P" ] && ok A "heavy-run PR reviewed with its issue, then merged"
done_case

# ===========================================================================
echo "=== B: standard issue -> no review ==="
P=$FAIL
setup B '[{"name":"auto-run"},{"name":"auto-merge"}]'
run_watch; show B
[ "$RC" = 0 ] || bad B "rc $RC, want 0"
merged || bad B "not merged"
[ -s "$WORK/calls.log" ] && bad B "agent called: $(tr '\n' ' ' < "$WORK/calls.log")"
[ "$(events merge_gate_reviewed)" = 0 ] || bad B "a gate review was recorded"
[ "$FAIL" = "$P" ] && ok B "standard PR merges without the review gate"
done_case

# ===========================================================================
echo "=== C: no issue.json -> not heavy ==="
P=$FAIL
setup C none
run_watch; show C
[ "$RC" = 0 ] || bad C "rc $RC, want 0"
merged || bad C "not merged"
[ -s "$WORK/calls.log" ] && bad C "agent called without a heavy-run issue"
[ "$FAIL" = "$P" ] && ok C "run without issue.json is not classified heavy"
done_case

# ===========================================================================
echo "=== D: heavy-run, fix fails -> hold ==="
P=$FAIL
setup D
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$FINDING_HIGH" > "$WORK/review.txt"
run_watch; show D
[ "$RC" = 10 ] || bad D "rc $RC, want 10"
merged && bad D "merged despite a held finding"
grep -q 'labels\[\]=needs-human' "$WORK/labels.log" || bad D "needs-human not added"
grep -q 'f.txt:1' "$WORK/comments.log" || bad D "comment does not list the finding"
grep -q 'heavy-run`-label' "$WORK/comments.log" || bad D "comment does not say why the gate ran"
[ "$(jq -r .blocked_reason "$RD/run.json")" = review_gate_failed_pr_55 ] \
  || bad D "blocked_reason '$(jq -r .blocked_reason "$RD/run.json")'"
[ "$(tr '\n' ' ' < "$WORK/calls.log")" = "REVIEW FIX " ] || bad D "calls '$(tr '\n' ' ' < "$WORK/calls.log")'"
[ "$FAIL" = "$P" ] && ok D "unfixed finding held for a human"
done_case

# ===========================================================================
echo "=== E: heavy-run, low finding -> reported, merged ==="
P=$FAIL
setup E
printf 'FINDING: low | medium | f.txt:1 | an unused variable shadows a parameter\nMERGE_GATE_RESULT: FINDINGS\n' > "$WORK/review.txt"
run_watch; show E
[ "$RC" = 0 ] || bad E "rc $RC, want 0"
merged || bad E "not merged"
[ "$(calls FIX)" = 0 ] || bad E "a finding below the threshold was fixed"
grep -q 'pidätysrajan `medium` alle' "$WORK/comments.log" || bad E "report comment does not name the default threshold"
[ "$FAIL" = "$P" ] && ok E "finding below the default threshold reported, merged"
done_case

# ===========================================================================
echo "=== F: heavy-run, finding fixed -> re-review -> merge ==="
P=$FAIL
setup F
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$FINDING_HIGH" > "$WORK/review-1.txt"
printf 'MERGE_GATE_RESULT: CLEAN\n' > "$WORK/review-2.txt"
cat > "$WORK/fix.sh" <<'SH'
echo "feature (bound fixed)" > f.txt
git add f.txt
git -c user.email=s@t.t -c user.name=s commit -qm "fix: exclusive loop bound"
SH
run_watch; show F
SHA1=$(git -C "$WT" rev-parse HEAD)
[ "$RC" = 0 ] || bad F "rc $RC, want 0"
merged || bad F "not merged"
[ "$(tr '\n' ' ' < "$WORK/calls.log")" = "REVIEW FIX REVIEW " ] || bad F "calls '$(tr '\n' ' ' < "$WORK/calls.log")'"
grep -q -- "--match-head-commit $SHA1" "$WORK/merge.log" 2>/dev/null || bad F "merge not bound to the fixed head"
grep -q 'f.txt:1' "$RD/17-code-review-fix.prompt" || bad F "fix prompt does not carry the finding"
grep -q 'Pagination drops the last row' "$RD/17-code-review-fix.prompt" || bad F "fix prompt lacks the issue"
[ "$FAIL" = "$P" ] && ok F "finding fixed, re-reviewed, merged"
done_case

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "pr-watch-review-gate: all passed" || echo "pr-watch-review-gate: FAILURES"
[ "$FAIL" -eq 0 ]
