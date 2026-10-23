#!/usr/bin/env bash
# test-pr-watch-semantic-gate.sh — the semantic-conflict merge gate in
# pr-watch.sh (issue #341), run through the generic merge-gate mechanism (#334).
# A green, mergeable, labelled PR with the gate ON first asks whether a sibling
# runner PR (auto-run/ head) merged into the base since the run started touches
# the same directories; only then is an agent called. The agent is stubbed
# through RUN_ISSUES_CLAUDE_CMD (CLAUDE.md §5.5) and gh is a PATH shim.
#
#   A) no sibling merges        -> 0 agent calls, merge (+ base untouched: 0 REST)
#   B) sibling in another dir   -> 0 agent calls, merge
#   C) overlapping sibling      -> review (1 call) whose prompt carries the
#                                  sibling's diff; exactly 1 REST listing
#   D) fix succeeds             -> fix commit, push, CI revalidated, new head
#                                  reviewed clean, merge bound to it
#   E) fix fails                -> needs-human, comment names the conflict and the
#                                  sibling PR, exit 10, no merge
#   F) listing fails            -> no agent, no merge, rc 4
#   G) gate off                 -> no gate events, no listing
#   H) same head, new base      -> a new overlapping sibling makes the head
#                                  reviewed again; an unchanged base does not
#   I) both gates               -> a semantic fix moves the head, so the security
#                                  gate reviews the new head too
#
# Runs use a FOREIGN host so P9 local cleanup is skipped and the run-dir survives.
#
# Run: bash tests/test-pr-watch-semantic-gate.sh

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

OLD_DATE="2026-01-01T00:00:00Z"
STARTED="2026-06-01T00:00:00Z"
SIB_DATE="2026-07-01T00:00:00Z"

# setup <name> — origin + repo + feature worktree (changes lib/) + completed run
# started at $STARTED (FOREIGN host), gh shim, stub agent.
setup() {
  WORK=$(mktemp -d -t prwatch-semgate-"$1".XXXXXX)
  ORIGIN="$WORK/origin.git"; REPO="$WORK/repo"; WT="$WORK/wt-feature"
  git init -q --bare "$ORIGIN"
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  git init -q "$REPO"
  git -C "$REPO" symbolic-ref HEAD refs/heads/main
  (
    cd "$REPO"
    git config user.email t@t.t; git config user.name t
    git remote add origin "$ORIGIN"
    mkdir -p lib docs
    echo "v0" > lib/a.sh; echo "v0" > docs/x.md
    git add -A
    GIT_COMMITTER_DATE="$OLD_DATE" GIT_AUTHOR_DATE="$OLD_DATE" git commit -qm init
    git push -q origin main
    git checkout -q -b auto-run/x-5
    printf 'v0\nretry_helper() { :; }\n' > lib/a.sh
    GIT_COMMITTER_DATE="$OLD_DATE" git commit -qam feature
    git push -q origin auto-run/x-5
    git checkout -q main
  )
  ( cd "$REPO" && git worktree add -q "$WT" auto-run/x-5 )

  RD="$REPO/.claude/run-issues/20261023-1200-issue-5"
  # shellcheck source=../lib/state.sh
  . "$STATE_LIB"
  state_init "$RD" "20261023-1200-issue-5" "$REPO" "5"
  state_set "$RD" "pr_url" "https://github.com/Silon-Oy/x/pull/55"
  state_set "$RD" "worktree_path" "$WT"
  state_set "$RD" "branch" "auto-run/x-5"
  state_set "$RD" "owner_repo" "Silon-Oy/x"
  local tmp; tmp=$(mktemp)
  jq --arg s "$STARTED" '.host = "some-other-host" | .started_at = $s' "$RD/run.json" > "$tmp"; mv "$tmp" "$RD/run.json"
  state_finalize "$RD" "completed"

  BIN="$WORK/bin"; mkdir -p "$BIN"
  : > "$WORK/labels.log"; : > "$WORK/comments.log"; : > "$WORK/calls.log"; : > "$WORK/api.log"
  echo '[]' > "$WORK/pulls.json"
  echo '[{"name":"auto-merge"}]' > "$WORK/pr_labels"
  cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
case "\$1" in
  api)
    if printf '%s' "\$*" | grep -q 'pulls?state=closed'; then
      printf '%s\n' "\$*" >> "$WORK/api.log"
      [ -f "$WORK/pulls-fail" ] && { echo "HTTP 502" >&2; exit 1; }
      cat "$WORK/pulls.json"; exit 0
    fi
    printf '%s\n' "\$*" >> "$WORK/labels.log"; exit 0 ;;
  auth) exit 0 ;;
esac
case "\$1 \$2" in
  "pr view")
    if printf '%s' "\$*" | grep -q mergeable; then
      jq -n --argjson l "\$(cat "$WORK/pr_labels")" '{state:"OPEN",mergeable:"MERGEABLE",mergeStateStatus:"CLEAN",labels:\$l,
        statusCheckRollup:[{__typename:"CheckRun",name:"ci",status:"COMPLETED",conclusion:"SUCCESS"}],
        headRefName:"auto-run/x-5",baseRefName:"main"}'
    else
      echo ci-poll >> "$WORK/ci.log"
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

  # Stub agent: calls logged as SREVIEW / SFIX (semantic) or REVIEW / FIX
  # (security), told apart by the rendered prompt. Semantic review answers come
  # from sreview-<n>.txt (falling back to sreview.txt); sfix.sh is the fix.
  cat > "$BIN/claude-mock" <<SH
#!/usr/bin/env bash
a="\$*"
case "\$a" in
  *"semanttisen konfliktin korjaaja"*)
    echo SFIX >> "$WORK/calls.log"
    [ -f "$WORK/sfix.sh" ] && bash "$WORK/sfix.sh"
    echo "MERGE_GATE_FIX_RESULT: FIXED"; exit 0 ;;
  *"semanttisen konfliktin tarkistaja"*)
    echo SREVIEW >> "$WORK/calls.log"
    n=\$(grep -c '^SREVIEW\$' "$WORK/calls.log")
    if [ -f "$WORK/sreview-\$n.txt" ]; then cat "$WORK/sreview-\$n.txt"; else cat "$WORK/sreview.txt"; fi
    exit 0 ;;
  *tietoturvakorjaaja*)
    echo FIX >> "$WORK/calls.log"; echo "MERGE_GATE_FIX_RESULT: FIXED"; exit 0 ;;
  *)
    echo REVIEW >> "$WORK/calls.log"; echo "MERGE_GATE_RESULT: CLEAN"; exit 0 ;;
esac
SH
  chmod +x "$BIN/claude-mock"
  printf 'MERGE_GATE_RESULT: CLEAN\n' > "$WORK/sreview.txt"
}

# sibling <pr-number> <file> [<head-ref>] — merge a sibling into origin/main
# (one rebase-style commit, dated inside the run's window) and list it in the
# closed-PR listing the gh shim serves.
sibling() {
  local num="$1" file="$2" ref="${3:-auto-run/sibling-$1}" sha
  (
    cd "$REPO"
    git checkout -q main
    git pull -q origin main
    mkdir -p "$(dirname "$file")"
    printf 'retry_with_backoff() { :; }  # sibling %s\n' "$num" >> "$file"
    git add -A
    GIT_COMMITTER_DATE="$SIB_DATE" GIT_AUTHOR_DATE="$SIB_DATE" git commit -qm "feat: sibling $num"
    git push -q origin main
  )
  sha=$(git -C "$REPO" rev-parse HEAD)
  local tmp; tmp=$(mktemp)
  jq --argjson n "$num" --arg r "$ref" --arg s "$sha" \
    '. + [{number:$n, merged_at:"2026-07-01T00:00:00Z", merge_commit_sha:$s, head:{ref:$r}}]' \
    "$WORK/pulls.json" > "$tmp" && mv "$tmp" "$WORK/pulls.json"
}

run_watch() {
  set +e
  OUT=$( env PATH="$BIN:$PATH" \
    RUN_ISSUES_LOCK_ROOT="$WORK/locks" \
    RUN_ISSUES_CLAUDE_CMD="$BIN/claude-mock" \
    PR_WATCH_ENABLE_SEMANTIC_CHECK=1 PR_WATCH_ENABLE_SECURITY_GATE=0 \
    PR_WATCH_SEMANTIC_REVIEW_TIMEOUT=30 PR_WATCH_SEMANTIC_FIX_TIMEOUT=30 \
    PR_WATCH_SECURITY_REVIEW_TIMEOUT=30 PR_WATCH_SECURITY_FIX_TIMEOUT=30 \
    PR_WATCH_CI_MAX_POLLS=1 PR_WATCH_CI_POLL_SECS=1 \
    "$@" "$PRWATCH" "$REPO" 55 2>&1 )
  RC=$?
}

calls() { grep -c "^$1$" "$WORK/calls.log" 2>/dev/null || true; }
seq_calls() { tr '\n' ' ' < "$WORK/calls.log"; }
listings() { grep -c . "$WORK/api.log" 2>/dev/null || true; }
merged() { [ -s "$WORK/merge.log" ]; }
events() { grep -c "\"event\":\"$1\"" "$RD/state.jsonl" 2>/dev/null || true; }
show() { echo "$OUT" | sed "s/^/$1| /"; echo "$1| (rc=$RC)"; }
done_case() { [ -n "${KEEP:-}" ] || rm -rf "$WORK"; }

FINDING_DUP='FINDING: high | high | lib/a.sh:2 | #77: retry_helper duplicates retry_with_backoff from lib/b.sh'

# ===========================================================================
echo "=== A: no sibling merges -> no agent, merge ==="
FB=$FAIL
setup A
run_watch; show A1
[ "$RC" = 0 ] || bad A1 "rc $RC, want 0"
merged || bad A1 "not merged"
[ -s "$WORK/calls.log" ] && bad A1 "agent called: $(seq_calls)"
[ "$(listings)" = 0 ] || bad A1 "listed PRs although the base gained no commit ($(listings))"
[ "$(events merge_gate_not_triggered)" = 1 ] || bad A1 "no merge_gate_not_triggered event"
# A human commit lands on the base, but no runner PR was merged.
( cd "$REPO" && echo h >> lib/h.sh && git add -A && GIT_COMMITTER_DATE="$SIB_DATE" git commit -qm human && git push -q origin main )
echo '[{"number":70,"merged_at":"2026-07-01T00:00:00Z","merge_commit_sha":"'"$(git -C "$REPO" rev-parse HEAD)"'","head":{"ref":"feature/human"}},{"number":71,"merged_at":null,"merge_commit_sha":"abc","head":{"ref":"auto-run/closed"}}]' > "$WORK/pulls.json"
: > "$WORK/merge.log"
run_watch; show A2
[ "$RC" = 0 ] || bad A2 "rc $RC, want 0"
merged || bad A2 "not merged"
[ -s "$WORK/calls.log" ] && bad A2 "agent called for a non-runner / unmerged PR"
[ "$(listings)" = 1 ] || bad A2 "listings $(listings), want 1"
[ "$FAIL" = "$FB" ] && ok A "no sibling merges -> no agent call"
done_case

# ===========================================================================
echo "=== B: sibling in another directory -> no agent, merge ==="
FB=$FAIL
setup B
sibling 77 docs/y.md
run_watch; show B
[ "$RC" = 0 ] || bad B "rc $RC, want 0"
merged || bad B "not merged"
[ -s "$WORK/calls.log" ] && bad B "agent called: $(seq_calls)"
echo "$OUT" | grep -q 'shares no directory' || bad B "non-overlap not logged"
[ "$FAIL" = "$FB" ] && ok B "sibling elsewhere -> no agent call"
done_case

# ===========================================================================
echo "=== C: overlapping sibling -> review with the sibling's diff ==="
FB=$FAIL
setup C
sibling 76 docs/y.md
sibling 77 lib/b.sh
SHA=$(git -C "$WT" rev-parse HEAD)
BASE=$(git --git-dir="$ORIGIN" rev-parse main)
run_watch; show C
[ "$RC" = 0 ] || bad C "rc $RC, want 0"
merged || bad C "not merged"
[ "$(seq_calls)" = "SREVIEW " ] || bad C "calls '$(seq_calls)', want one semantic review"
[ "$(listings)" = 1 ] || bad C "REST listings $(listings), want exactly 1"
P="$RD/08-semantic-review.prompt"
grep -q 'Sisar-PR #77' "$P" || bad C "prompt does not name sibling #77"
grep -q '+retry_with_backoff() { :; }  # sibling 77' "$P" || bad C "prompt does not carry the sibling's diff"
grep -q 'Sisar-PR #76' "$P" && bad C "prompt names the non-overlapping sibling #76"
grep -q '{{GATE_CONTEXT}}' "$P" && bad C "placeholder left unrendered"
grep -q "\"event\":\"merge_gate_reviewed\".*\"gate\":\"semantic\".*\"sha\":\"$SHA\".*\"result\":\"clean\".*\"base_sha\":\"$BASE\"" "$RD/state.jsonl" \
  || bad C "review not recorded against head + base"
grep -q -- "--match-head-commit $SHA" "$WORK/merge.log" || bad C "merge not bound to the reviewed head"
[ "$FAIL" = "$FB" ] && ok C "overlap reviewed with the sibling diff, one REST call"
done_case

# ===========================================================================
echo "=== D: fix succeeds -> revalidate -> re-review -> merge ==="
FB=$FAIL
setup D
sibling 77 lib/b.sh
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$FINDING_DUP" > "$WORK/sreview-1.txt"
printf 'MERGE_GATE_RESULT: CLEAN\n' > "$WORK/sreview-2.txt"
cat > "$WORK/sfix.sh" <<'SH'
echo "v0" > lib/a.sh
git add lib/a.sh
git -c user.email=s@t.t -c user.name=s commit -qm "refactor: use the merged retry_with_backoff"
SH
SHA0=$(git -C "$WT" rev-parse HEAD)
run_watch; show D
SHA1=$(git -C "$WT" rev-parse HEAD)
[ "$RC" = 0 ] || bad D "rc $RC, want 0"
merged || bad D "not merged"
[ "$SHA1" != "$SHA0" ] || bad D "head did not move"
[ "$(git --git-dir="$ORIGIN" rev-parse auto-run/x-5)" = "$SHA1" ] || bad D "fix not pushed"
[ "$(seq_calls)" = "SREVIEW SFIX SREVIEW " ] || bad D "calls '$(seq_calls)'"
[ -s "$WORK/ci.log" ] || bad D "CI not revalidated after the fix"
[ "$(events merge_gate_fix_pushed)" = 1 ] || bad D "no merge_gate_fix_pushed"
grep -q 'lib/a.sh:2' "$RD/09-semantic-fix.prompt" || bad D "fix prompt does not carry the finding"
grep -q 'Sisar-PR #77' "$RD/09-semantic-fix.prompt" || bad D "fix prompt does not carry the sibling"
grep -q -- "--match-head-commit $SHA1" "$WORK/merge.log" || bad D "merge not bound to the fixed head"
[ "$FAIL" = "$FB" ] && ok D "conflict fixed, revalidated, re-reviewed, merged"
done_case

# ===========================================================================
echo "=== E: fix fails -> hold naming the conflict and the sibling ==="
FB=$FAIL
setup E
sibling 77 lib/b.sh
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$FINDING_DUP" > "$WORK/sreview.txt"
run_watch; show E
[ "$RC" = 10 ] || bad E "rc $RC, want 10"
merged && bad E "merged despite a semantic conflict"
grep -q 'labels\[\]=needs-human' "$WORK/labels.log" || bad E "needs-human not added"
grep -q 'retry_helper duplicates retry_with_backoff' "$WORK/comments.log" || bad E "comment does not name the conflict"
grep -q '#77 (`auto-run/sibling-77`)' "$WORK/comments.log" || bad E "comment does not name the sibling PR"
[ "$(jq -r .blocked_reason "$RD/run.json")" = semantic_gate_failed_pr_55 ] || bad E "blocked_reason '$(jq -r .blocked_reason "$RD/run.json")'"
[ "$(seq_calls)" = "SREVIEW SFIX " ] || bad E "calls '$(seq_calls)'"
[ "$FAIL" = "$FB" ] && ok E "failed fix held with the conflict and the sibling named"
done_case

# ===========================================================================
echo "=== F: listing fails -> no agent, no merge ==="
FB=$FAIL
setup F
sibling 77 lib/b.sh
touch "$WORK/pulls-fail"
run_watch; show F
[ "$RC" = 4 ] || bad F "rc $RC, want 4"
merged && bad F "merged without knowing the siblings"
[ -s "$WORK/calls.log" ] && bad F "agent called"
grep -q '"reason":"gate_trigger_failed"' "$RD/state.jsonl" || bad F "trigger failure not recorded"
[ "$(events merge_gate_reviewed)" = 0 ] || bad F "a review was recorded"
[ "$FAIL" = "$FB" ] && ok F "failed listing is not a pass"
done_case

# ===========================================================================
echo "=== G: gate off -> no gate events, no listing ==="
FB=$FAIL
setup G
sibling 77 lib/b.sh
run_watch PR_WATCH_ENABLE_SEMANTIC_CHECK=0; show G
[ "$RC" = 0 ] || bad G "rc $RC, want 0"
merged || bad G "not merged"
[ -s "$WORK/calls.log" ] && bad G "agent called with the gate off"
[ "$(listings)" = 0 ] || bad G "listed PRs with the gate off"
grep -q '"event":"merge_gate_' "$RD/state.jsonl" && bad G "gate event written with the gate off"
[ "$FAIL" = "$FB" ] && ok G "gate off leaves the merge path unchanged"
done_case

# ===========================================================================
echo "=== H: same head, new base -> reviewed again; same base -> not ==="
FB=$FAIL
setup H
sibling 77 lib/b.sh
run_watch; show H1
[ "$(calls SREVIEW)" = 1 ] || bad H1 "first review missing"
: > "$WORK/merge.log"
run_watch; show H2
[ "$(calls SREVIEW)" = 1 ] || bad H2 "same head + same base reviewed again"
merged || bad H2 "not merged"
sibling 78 lib/c.sh
: > "$WORK/merge.log"
run_watch; show H3
[ "$(calls SREVIEW)" = 2 ] || bad H3 "same head against a new base not reviewed again ($(calls SREVIEW))"
grep -q 'Sisar-PR #78' "$RD/08-semantic-review.prompt" || bad H3 "new sibling not in the prompt"
merged || bad H3 "not merged"
[ "$FAIL" = "$FB" ] && ok H "record keyed by head and base"
done_case

# ===========================================================================
echo "=== I: both gates -> a semantic fix makes security re-review ==="
FB=$FAIL
setup I
sibling 77 lib/b.sh
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$FINDING_DUP" > "$WORK/sreview-1.txt"
printf 'MERGE_GATE_RESULT: CLEAN\n' > "$WORK/sreview-2.txt"
cat > "$WORK/sfix.sh" <<'SH'
echo "v0" > lib/a.sh
git add lib/a.sh
git -c user.email=s@t.t -c user.name=s commit -qm "refactor: use the merged retry_with_backoff"
SH
run_watch PR_WATCH_ENABLE_SECURITY_GATE=1; show I
SHA1=$(git -C "$WT" rev-parse HEAD)
[ "$RC" = 0 ] || bad I "rc $RC, want 0"
merged || bad I "not merged"
[ "$(seq_calls)" = "REVIEW SREVIEW SFIX SREVIEW REVIEW " ] || bad I "calls '$(seq_calls)'"
grep -q -- "--match-head-commit $SHA1" "$WORK/merge.log" || bad I "merge not bound to the final head"
[ "$FAIL" = "$FB" ] && ok I "both gates reviewed the final head"
done_case

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "pr-watch-semantic-gate: all passed" || echo "pr-watch-semantic-gate: FAILURES"
[ "$FAIL" -eq 0 ]
