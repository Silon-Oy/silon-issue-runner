#!/usr/bin/env bash
# test-pr-watch-ci-repair-recovery.sh — issue #45 recovery behaviours for the
# P5b CI-repair path. Three faults it pins down:
#
#   Symptom A — the CI-repair agent never launched (rc=127, the claude CLI's
#     silent 127 the orchestrator's S0 gate already catches), yet the PR comment read
#     "the agent produced no fix", so a human studied a CI error the agent never
#     looked at. Fixes: a classify-time preflight downgrades FIX_CI to WAIT_CI
#     when the CLI is unusable (E), and a rc=127 that slips past it is reported
#     honestly as a launch failure (F).
#
#   Symptom B — a CI-repair handover left the run blocked FOREVER: scan_candidates
#     only emitted `completed` runs, so a PR whose CI later went green was never
#     re-examined. Fixes: blocked ci_repair_failed* runs are re-emitted into the
#     scan (I), held while needs-human is present (G), and merged once a human
#     removes needs-human and CI is green (H).
#
# Plain-bash, mocked `gh` + claude, no network. SKIP if jq is unavailable.
# Runs use a FOREIGN host (except the scan test) so P9 local cleanup is skipped
# and the run-dir survives for assertions.
#
# Run: bash tests/test-pr-watch-ci-repair-recovery.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The host name comes from the SAME primitive the code under test uses.
# `hostname -s` is not portable — Windows' hostname has no -s — and issue #213
# moved the four-step fallback into runner_host for exactly that reason. A test
# that re-derives it by hand disagrees with the code on any machine where the
# short flag fails, and then reports a host mismatch that does not exist.
# shellcheck source=../lib/host.sh
. "$HERE/../lib/host.sh"
PRWATCH="$HERE/../pr-watch.sh"
STATE_LIB="$HERE/../lib/state.sh"
THIS_HOST="$(runner_host)"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available"
  exit 0
fi

FAIL=0

# build_repo <work> — origin + repo + feature worktree; echoes "REPO WT ORIGIN".
build_repo() {
  local work="$1"
  local origin="$work/origin.git" repo="$work/repo"
  git init -q --bare "$origin"
  # Force `main` regardless of the machine's init.defaultBranch.
  git -C "$origin" symbolic-ref HEAD refs/heads/main
  git init -q "$repo"
  git -C "$repo" symbolic-ref HEAD refs/heads/main
  (
    cd "$repo"
    git config user.email t@t.t; git config user.name t
    git remote add origin "$origin"
    echo "v0" > f.txt
    git add f.txt; git commit -qm init
    git push -q origin main
    git checkout -q -b feature/x
    echo "feature (buggy)" > f.txt
    git commit -qam feature
    git push -q origin feature/x
    git checkout -q main
  )
  local wt="$work/wt-feature"
  ( cd "$repo" && git worktree add -q "$wt" feature/x )
  printf '%s %s %s' "$repo" "$wt" "$origin"
}

# seed_run <repo> <wt> <rid> <issue> <pr> <status> [<blocked-reason>] [<host>]
# status "completed" or "blocked"; host defaults to a FOREIGN host. echoes run-dir.
seed_run() {
  local repo="$1" wt="$2" rid="$3" issue="$4" pr="$5" status="$6"
  local reason="${7:-}" host="${8:-some-other-host}"
  local rd="$repo/.claude/run-issues/$rid"
  # shellcheck source=../lib/state.sh
  . "$STATE_LIB"
  state_init "$rd" "$rid" "$repo" "$issue"
  state_set "$rd" "pr_url" "https://github.com/Silon-Oy/x/pull/$pr"
  state_set "$rd" "worktree_path" "$wt"
  state_set "$rd" "branch" "feature/x"
  local tmp; tmp=$(mktemp); jq --arg h "$host" '.host = $h' "$rd/run.json" > "$tmp"; mv "$tmp" "$rd/run.json"
  if [ -n "$reason" ]; then
    state_finalize "$rd" "$status" "$reason"
  else
    state_finalize "$rd" "$status"
  fi
  printf '%s' "$rd"
}

# A red, BLOCKED, labelled PR (=> FIX_CI when repair is ON).
PR_VIEW_RED='{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED",
 "labels":[{"name":"auto-merge"}],
 "statusCheckRollup":[{"__typename":"CheckRun","name":"e2e","status":"COMPLETED","conclusion":"FAILURE"}],
 "headRefName":"feature/x","baseRefName":"main"}'

# Same red PR but ALSO carrying needs-human (the CI-repair hold flag).
PR_VIEW_RED_HELD='{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED",
 "labels":[{"name":"auto-merge"},{"name":"needs-human"}],
 "statusCheckRollup":[{"__typename":"CheckRun","name":"e2e","status":"COMPLETED","conclusion":"FAILURE"}],
 "headRefName":"feature/x","baseRefName":"main"}'

# A green, CLEAN, labelled PR (=> MERGE). needs-human already removed by a human.
PR_VIEW_GREEN='{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN",
 "labels":[{"name":"auto-merge"}],
 "statusCheckRollup":[{"__typename":"CheckRun","name":"e2e","status":"COMPLETED","conclusion":"SUCCESS"}],
 "headRefName":"feature/x","baseRefName":"main"}'

# ===========================================================================
# Scenario E — CLI unusable at classify time => FIX_CI downgraded to WAIT_CI.
# No agent, no attempt event, no label/comment; run stays completed (issue #45 A).
# ===========================================================================
echo "=== scenario E: preflight downgrades FIX_CI -> WAIT_CI ==="
FAIL_E=0
WORK_E=$(mktemp -d -t prwatch-recov-E.XXXXXX)
read -r REPO WT ORIGIN <<<"$(build_repo "$WORK_E")"
RD=$(seed_run "$REPO" "$WT" "20260601-1500-issue-51" "51" "511" "completed")

BIN="$WORK_E/bin"; mkdir -p "$BIN"
LABELS_LOG="$WORK_E/labels.log"; : > "$LABELS_LOG"
COMMENT_FLAG="$WORK_E/comment_called"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
case "\$1" in
  api) printf '%s\n' "\$*" >> "$LABELS_LOG"; exit 0 ;;
esac
case "\$1 \$2" in
  "pr view")   cat <<'JSON'
$PR_VIEW_RED
JSON
    ;;
  "pr comment") cat > /dev/null; touch "$COMMENT_FLAG" ;;
  "pr merge")  touch "$WORK_E/merge_called" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN/gh"

set +e
OUT=$( PATH="$BIN:$PATH" \
  RUN_ISSUES_LOCK_ROOT="$WORK_E/locks" \
  PR_WATCH_ENABLE_CI_REPAIR=1 \
  PR_WATCH_MAX_CI_REPAIRS=1 \
  RUN_ISSUES_CLAUDE_CMD="$WORK_E/bin/does-not-exist-claude" \
  "$PRWATCH" "$REPO" 511 2>&1 )
RC=$?
set -e
echo "$OUT" | sed 's/^/E| /'
echo "E| (rc=$RC)"

[ "$RC" = "4" ] || { echo "FAIL E: expected rc 4 (WAIT_CI), got $RC"; FAIL_E=1; }
echo "$OUT" | grep -q "classified: WAIT_CI" || { echo "FAIL E: not reclassified WAIT_CI"; FAIL_E=1; }
echo "$OUT" | grep -q "CI-repair unavailable" || { echo "FAIL E: no 'CI-repair unavailable' reason logged"; FAIL_E=1; }
grep -q '"event":"pr_ci_repair_attempted"' "$RD/state.jsonl" && { echo "FAIL E: an attempt was recorded"; FAIL_E=1; }
[ ! -f "$COMMENT_FLAG" ] || { echo "FAIL E: PR was commented"; FAIL_E=1; }
[ ! -f "$WORK_E/merge_called" ] || { echo "FAIL E: PR merged on red CI"; FAIL_E=1; }
grep -q 'labels\[\]=needs-human' "$LABELS_LOG" && { echo "FAIL E: needs-human attached"; FAIL_E=1; }
[ "$(jq -r '.status' "$RD/run.json")" = "completed" ] || { echo "FAIL E: status changed from completed"; FAIL_E=1; }
[ "$FAIL_E" = "0" ] && echo "PASS E: unusable CLI leaves red PR as WAIT_CI, no side effects"
[ "$FAIL_E" = "0" ] || FAIL=1
rm -rf "$WORK_E"

# ===========================================================================
# Scenario F — agent launch fails (rc=127) => honest launch-failure handover.
# The comment says "ei voitu käynnistää (rc=127)", NOT "ei tuottanut committia"
# (issue #45 A). Preflight passes because the driver file exists; the call itself
# returns 127.
# ===========================================================================
echo "=== scenario F: rc=127 reported as a launch failure ==="
FAIL_F=0
WORK_F=$(mktemp -d -t prwatch-recov-F.XXXXXX)
read -r REPO WT ORIGIN <<<"$(build_repo "$WORK_F")"
RD=$(seed_run "$REPO" "$WT" "20260601-1600-issue-52" "52" "522" "completed")

BIN="$WORK_F/bin"; mkdir -p "$BIN"
LABELS_LOG="$WORK_F/labels.log"; : > "$LABELS_LOG"
COMMENT_FILE="$WORK_F/comment.md"; : > "$COMMENT_FILE"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
case "\$1" in
  api) printf '%s\n' "\$*" >> "$LABELS_LOG"; exit 0 ;;
esac
case "\$1 \$2" in
  "pr view")   cat <<'JSON'
$PR_VIEW_RED
JSON
    ;;
  "run list")  echo '[{"databaseId":9101,"conclusion":"failure"}]' ;;
  "run view")  echo "e2e failing" ;;
  "pr comment") cat > "$COMMENT_FILE" ;;
  "pr merge")  touch "$WORK_F/merge_called" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN/gh"

# A driver that EXISTS (so preflight passes) but exits 127 when actually invoked.
CLAUDE_F="$WORK_F/bin/claude-127"
cat > "$CLAUDE_F" <<'SH'
#!/usr/bin/env bash
exit 127
SH
chmod +x "$CLAUDE_F"

HEAD_BEFORE=$( cd "$WT" && git rev-parse HEAD )
set +e
OUT=$( PATH="$BIN:$PATH" \
  RUN_ISSUES_LOCK_ROOT="$WORK_F/locks" \
  PR_WATCH_ENABLE_CI_REPAIR=1 \
  PR_WATCH_MAX_CI_REPAIRS=1 \
  RUN_ISSUES_CLAUDE_CMD="$CLAUDE_F" \
  PR_WATCH_CI_REPAIR_TIMEOUT=30 \
  "$PRWATCH" "$REPO" 522 2>&1 )
RC=$?
set -e
echo "$OUT" | sed 's/^/F| /'
echo "F| (rc=$RC)"

[ "$RC" = "8" ] || { echo "FAIL F: expected rc 8, got $RC"; FAIL_F=1; }
echo "$OUT" | grep -q "could not be launched for PR #522 (rc=127)" || { echo "FAIL F: no launch-failure log"; FAIL_F=1; }
[ ! -f "$WORK_F/merge_called" ] || { echo "FAIL F: merged despite launch failure"; FAIL_F=1; }
[ "$( cd "$WT" && git rev-parse HEAD )" = "$HEAD_BEFORE" ] || { echo "FAIL F: branch moved despite launch failure"; FAIL_F=1; }
grep -q 'labels\[\]=needs-human' "$LABELS_LOG" || { echo "FAIL F: needs-human not attached"; FAIL_F=1; }
grep -q "ei voitu käynnistää" "$COMMENT_FILE" || { echo "FAIL F: comment does not say the agent could not launch"; FAIL_F=1; }
grep -q "rc=127" "$COMMENT_FILE" || { echo "FAIL F: comment omits rc=127"; FAIL_F=1; }
grep -q "ei tuottanut korjaavaa committia" "$COMMENT_FILE" && { echo "FAIL F: comment falsely says 'produced no commit'"; FAIL_F=1; }
grep -q '"event":"pr_ci_repair_handover"' "$RD/state.jsonl" || { echo "FAIL F: no handover event"; FAIL_F=1; }
[ "$(jq -r '.status' "$RD/run.json")" = "blocked" ] || { echo "FAIL F: status not blocked"; FAIL_F=1; }
[ "$(jq -r '.blocked_reason' "$RD/run.json")" = "ci_repair_failed_pr_522" ] || { echo "FAIL F: blocked_reason not ci_repair_failed_pr_522"; FAIL_F=1; }
[ "$FAIL_F" = "0" ] && echo "PASS F: rc=127 handed over as an honest launch failure"
[ "$FAIL_F" = "0" ] || FAIL=1
rm -rf "$WORK_F"

# ===========================================================================
# Scenario G — a blocked ci-repair run whose PR still carries needs-human is
# HELD: the watcher skips it (rc 4) without re-deciding or re-commenting, so it
# does not spam the PR every poll (issue #45 B).
# ===========================================================================
echo "=== scenario G: needs-human holds the run ==="
FAIL_G=0
WORK_G=$(mktemp -d -t prwatch-recov-G.XXXXXX)
read -r REPO WT ORIGIN <<<"$(build_repo "$WORK_G")"
RD=$(seed_run "$REPO" "$WT" "20260601-1700-issue-53" "53" "533" "blocked" "ci_repair_failed_pr_533")

BIN="$WORK_G/bin"; mkdir -p "$BIN"
LABELS_LOG="$WORK_G/labels.log"; : > "$LABELS_LOG"
COMMENT_FLAG="$WORK_G/comment_called"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
case "\$1" in
  api) printf '%s\n' "\$*" >> "$LABELS_LOG"; exit 0 ;;
esac
case "\$1 \$2" in
  "pr view")   cat <<'JSON'
$PR_VIEW_RED_HELD
JSON
    ;;
  "pr comment") cat > /dev/null; touch "$COMMENT_FLAG" ;;
  "pr merge")  touch "$WORK_G/merge_called" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN/gh"

set +e
OUT=$( PATH="$BIN:$PATH" \
  RUN_ISSUES_LOCK_ROOT="$WORK_G/locks" \
  PR_WATCH_ENABLE_CI_REPAIR=1 \
  "$PRWATCH" "$REPO" 533 2>&1 )
RC=$?
set -e
echo "$OUT" | sed 's/^/G| /'
echo "G| (rc=$RC)"

[ "$RC" = "4" ] || { echo "FAIL G: expected rc 4 (held), got $RC"; FAIL_G=1; }
echo "$OUT" | grep -q "held by needs-human" || { echo "FAIL G: no 'held by needs-human' log"; FAIL_G=1; }
[ ! -f "$COMMENT_FLAG" ] || { echo "FAIL G: re-commented while held"; FAIL_G=1; }
[ ! -f "$WORK_G/merge_called" ] || { echo "FAIL G: merged while held/red"; FAIL_G=1; }
grep -q '"event":"pr_watch_skipped".*needs_human_held' "$RD/state.jsonl" || { echo "FAIL G: no needs_human_held skip event"; FAIL_G=1; }
[ "$(jq -r '.status' "$RD/run.json")" = "blocked" ] || { echo "FAIL G: status changed from blocked"; FAIL_G=1; }
[ "$FAIL_G" = "0" ] && echo "PASS G: needs-human holds the run, no re-comment"
[ "$FAIL_G" = "0" ] || FAIL=1
rm -rf "$WORK_G"

# ===========================================================================
# Scenario H — needs-human removed + CI now green => the blocked run is re-armed
# and MERGES (issue #45 B: the core "permanently stuck" fault). This is the exact
# state the report describes: CLEAN / SUCCESS / auto-merge / no needs-human.
# ===========================================================================
echo "=== scenario H: re-armed after needs-human removed => merge ==="
FAIL_H=0
WORK_H=$(mktemp -d -t prwatch-recov-H.XXXXXX)
read -r REPO WT ORIGIN <<<"$(build_repo "$WORK_H")"
RD=$(seed_run "$REPO" "$WT" "20260601-1800-issue-54" "54" "544" "blocked" "ci_repair_failed_pr_544")

BIN="$WORK_H/bin"; mkdir -p "$BIN"
MERGE_FLAG="$WORK_H/merge_called"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
case "\$1" in
  api) exit 0 ;;
esac
case "\$1 \$2" in
  "pr view")   cat <<'JSON'
$PR_VIEW_GREEN
JSON
    ;;
  "pr merge")  touch "$MERGE_FLAG"; echo "merged (mock)" ;;
  "pr comment") cat > /dev/null ;;
  "issue view") echo '{"state":"CLOSED"}' ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN/gh"

set +e
OUT=$( PATH="$BIN:$PATH" \
  RUN_ISSUES_LOCK_ROOT="$WORK_H/locks" \
  PR_WATCH_ENABLE_CI_REPAIR=1 \
  "$PRWATCH" "$REPO" 544 2>&1 )
RC=$?
set -e
echo "$OUT" | sed 's/^/H| /'
echo "H| (rc=$RC)"

[ "$RC" = "0" ] || { echo "FAIL H: expected rc 0 (merged), got $RC"; FAIL_H=1; }
echo "$OUT" | grep -q "re-armed after handover" || { echo "FAIL H: no re-armed log"; FAIL_H=1; }
[ -f "$MERGE_FLAG" ] || { echo "FAIL H: PR not merged after re-arm"; FAIL_H=1; }
[ "$(jq -r '.status' "$RD/run.json")" = "merged" ] || { echo "FAIL H: status not merged"; FAIL_H=1; }
[ "$FAIL_H" = "0" ] && echo "PASS H: re-armed run merges once CI green + needs-human removed"
[ "$FAIL_H" = "0" ] || FAIL=1
rm -rf "$WORK_H"

# ===========================================================================
# Scenario I — scan_candidates re-emits a blocked ci_repair_failed* run but NOT
# other blocked states (env_bootstrap_failed). Uses THIS host so both runs pass
# the scan host gate; the ci-repair PR is HELD (needs-human) so nothing merges.
# ===========================================================================
echo "=== scenario I: scan re-emits only ci_repair_failed* blocked runs ==="
FAIL_I=0
WORK_I=$(mktemp -d -t prwatch-recov-I.XXXXXX)
read -r REPO WT ORIGIN <<<"$(build_repo "$WORK_I")"
# Emitted: ci_repair_failed on THIS host.
seed_run "$REPO" "$WT" "20260601-1900-issue-55" "55" "551" "blocked" "ci_repair_failed_pr_551" "$THIS_HOST" >/dev/null
# NOT emitted: a different blocked reason on THIS host.
seed_run "$REPO" "$WT" "20260601-1901-issue-56" "56" "552" "blocked" "env_bootstrap_failed" "$THIS_HOST" >/dev/null

BIN="$WORK_I/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
case "\$1" in
  api) exit 0 ;;
esac
case "\$1 \$2" in
  "pr view")   cat <<'JSON'
$PR_VIEW_RED_HELD
JSON
    ;;
  "pr comment") cat > /dev/null ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN/gh"

set +e
OUT=$( PATH="$BIN:$PATH" \
  RUN_ISSUES_LOCK_ROOT="$WORK_I/locks" \
  PR_WATCH_ENABLE_CI_REPAIR=1 \
  "$PRWATCH" "$REPO" scan 2>&1 )
RC=$?
set -e
echo "$OUT" | sed 's/^/I| /'
echo "I| (rc=$RC)"

echo "$OUT" | grep -q "candidates=1" || { echo "FAIL I: expected exactly 1 candidate (the ci_repair_failed run)"; FAIL_I=1; }
echo "$OUT" | grep -q "scan: processing PR #551" || { echo "FAIL I: ci_repair_failed run not processed"; FAIL_I=1; }
echo "$OUT" | grep -q "PR #552" && { echo "FAIL I: env_bootstrap_failed run was re-emitted"; FAIL_I=1; }
[ "$FAIL_I" = "0" ] && echo "PASS I: scan re-emits ci_repair_failed* only, not other blocked states"
[ "$FAIL_I" = "0" ] || FAIL=1
rm -rf "$WORK_I"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "pr-watch-ci-repair-recovery: all passed" || echo "pr-watch-ci-repair-recovery: FAILURES"
[ "$FAIL" -eq 0 ]
