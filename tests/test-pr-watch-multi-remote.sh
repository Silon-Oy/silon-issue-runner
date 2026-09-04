#!/usr/bin/env bash
# test-pr-watch-multi-remote.sh — the watcher routes gh + scan at the PR's OWN
# remote (issue #33).
#
# Before the fix pr-watch.sh let `gh` resolve the repo from the working dir's
# origin, so a clone whose issues/PRs live in a NON-origin remote had its clean,
# mergeable auto-merge PRs silently ignored — the last link of the autoflow chain
# (PR → merge → issue closed) broke with no error. This test pins the two halves
# of the fix, all offline against a mocked `gh` (PATH shim) + a real local clone:
#
#   1. Routing: a completed run whose run.json records .remote + .owner_repo makes
#      the watcher pass `--repo <owner/repo>` to its gh calls, so the merge is
#      addressed at the right org. Covers: recorded owner_repo; owner_repo ABSENT
#      but resolvable from the clone (fallback for a run.json predating the field);
#      and the origin/legacy run where NO --repo is added (gh cwd inference).
#
#   2. Scan filter: `pr-watch.sh --remote <name> <repo> scan` processes only the
#      runs whose recorded .remote matches, and logs a per-remote candidate count.
#
# Run: bash tests/test-pr-watch-multi-remote.sh   (exit 0 = all pass)

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

PASS=0
FAIL=0

# setup_repo <workdir> — sets globals REPO / BIN / CALL_LOG: a clone with origin +
# partner remotes (real github URLs, never dialled) and a gh mock that records every
# call and serves a green, labelled, mergeable PR + a successful merge.
setup_repo() {
  local work="$1"
  REPO="$work/repo"
  git init -q "$REPO"
  (
    cd "$REPO" || exit 1
    git config user.email t@t.t; git config user.name t
    git remote add origin "git@github.com:Silon-Oy/app.git"
    git remote add partner  "https://github.com/partner-org/app.git"
  )
  BIN="$work/bin"; mkdir -p "$BIN"
  CALL_LOG="$work/gh-calls.log"; : > "$CALL_LOG"
  cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
echo "gh \$*" >> "$CALL_LOG"
case "\$1 \$2" in
  "pr view")
    cat <<'JSON'
{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN",
 "labels":[{"name":"auto-merge"}],"statusCheckRollup":[],
 "headRefName":"feature/x","baseRefName":"main"}
JSON
    ;;
  "pr merge")    echo "merged (mock)" ;;
  "pr checks")   exit 0 ;;
  "issue view")  echo '{"state":"CLOSED"}' ;;   # already closed -> no explicit close
  *) exit 0 ;;
esac
SH
  chmod +x "$BIN/gh"
}

# make_run <repo> <rid> <issue> <pr> <remote|-> <owner_repo|-> <host> — a
# completed run. <host> "foreign" writes a non-local host so P9 cleanup is
# skipped and the run-dir survives (used by the named-PR routing cases, which
# only inspect the recorded gh calls); "self" writes this host so scan_candidates
# — which host-gates — emits the run (used by the scan-filter case). Leaves
# `set +e` on return so a following non-zero command in the caller's subshell
# does not abort it (state.sh enables -e).
make_run() {
  local repo="$1" rid="$2" issue="$3" pr="$4" remote="$5" owner="$6" host="$7"
  local rd="$repo/.claude/run-issues/$rid"
  # shellcheck source=../lib/state.sh
  . "$STATE_LIB"
  state_init "$rd" "$rid" "$repo" "$issue"
  state_set "$rd" "pr_url" "https://github.com/x/y/pull/$pr"
  [ "$remote" != "-" ] && state_set "$rd" "remote" "$remote"
  [ "$owner"  != "-" ] && state_set "$rd" "owner_repo" "$owner"
  local host_val="some-other-host"
  [ "$host" = "self" ] && host_val="$(runner_host)"
  local tmp; tmp=$(mktemp); jq --arg h "$host_val" '.host = $h' "$rd/run.json" > "$tmp"; mv "$tmp" "$rd/run.json"
  state_finalize "$rd" "completed"
  set +e
}

ok() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }

# ===========================================================================
# 1a. Recorded .remote + .owner_repo -> gh routed via --repo partner-org/app
# ===========================================================================
(
  WORK=$(mktemp -d -t prwatch-mr.XXXXXX); trap 'rm -rf "$WORK"' EXIT
  setup_repo "$WORK"
  make_run "$REPO" "20260806-1200-partner-issue-77" 77 501 partner "partner-org/app" foreign
  PATH="$BIN:$PATH" RUN_ISSUES_LOCK_ROOT="$WORK/locks" PR_WATCH_ENABLE_CONFLICT_RESOLUTION=0 \
    "$PRWATCH" "$REPO" 501 >/dev/null 2>&1
  grep -q '^gh pr view .*--repo partner-org/app'  "$CALL_LOG" || exit 11
  grep -q '^gh pr merge .*--repo partner-org/app' "$CALL_LOG" || exit 12
  exit 0
)
case $? in
  0)  ok "recorded owner_repo -> gh pr view/merge routed via --repo partner-org/app" ;;
  11) no "gh pr view was not routed via --repo partner-org/app" ;;
  12) no "gh pr merge was not routed via --repo partner-org/app" ;;
  *)  no "recorded-owner_repo case crashed" ;;
esac

# ===========================================================================
# 1b. .remote recorded but .owner_repo ABSENT -> resolved from the clone
# ===========================================================================
(
  WORK=$(mktemp -d -t prwatch-mr.XXXXXX); trap 'rm -rf "$WORK"' EXIT
  setup_repo "$WORK"
  make_run "$REPO" "20260806-1201-partner-issue-77" 77 502 partner "-" foreign
  PATH="$BIN:$PATH" RUN_ISSUES_LOCK_ROOT="$WORK/locks" PR_WATCH_ENABLE_CONFLICT_RESOLUTION=0 \
    "$PRWATCH" "$REPO" 502 >/dev/null 2>&1
  grep -q '^gh pr merge .*--repo partner-org/app' "$CALL_LOG" || exit 11
  exit 0
)
case $? in
  0)  ok "absent owner_repo -> resolved from clone, gh routed via --repo partner-org/app" ;;
  *)  no "absent-owner_repo fallback did not route gh via --repo" ;;
esac

# ===========================================================================
# 1c. origin/legacy run -> NO --repo appended (gh cwd inference preserved)
# ===========================================================================
(
  WORK=$(mktemp -d -t prwatch-mr.XXXXXX); trap 'rm -rf "$WORK"' EXIT
  setup_repo "$WORK"
  make_run "$REPO" "20260806-1202-issue-77" 77 503 "-" "-" foreign
  PATH="$BIN:$PATH" RUN_ISSUES_LOCK_ROOT="$WORK/locks" PR_WATCH_ENABLE_CONFLICT_RESOLUTION=0 \
    "$PRWATCH" "$REPO" 503 >/dev/null 2>&1
  # No gh line for this run may carry --repo (legacy cwd inference), but the
  # merge must still happen.
  grep -q '^gh .*--repo ' "$CALL_LOG" && exit 11
  grep -q '^gh pr merge'  "$CALL_LOG" || exit 12
  exit 0
)
case $? in
  0)  ok "origin run -> no --repo added (legacy cwd inference), merge still happens" ;;
  11) no "origin run wrongly added a --repo flag" ;;
  12) no "origin run did not merge" ;;
  *)  no "origin-run case crashed" ;;
esac

# ===========================================================================
# 2. scan --remote <name> filters runs by recorded remote + logs candidates
# ===========================================================================
(
  WORK=$(mktemp -d -t prwatch-mr.XXXXXX); trap 'rm -rf "$WORK"' EXIT
  setup_repo "$WORK"
  make_run "$REPO" "20260806-1300-issue-78"        78 601 "-"    "-"              self  # origin run
  make_run "$REPO" "20260806-1301-partner-issue-79"  79 602 partner  "partner-org/app" self  # partner run

  OUT=$(PATH="$BIN:$PATH" RUN_ISSUES_LOCK_ROOT="$WORK/locks" PR_WATCH_ENABLE_CONFLICT_RESOLUTION=0 \
        "$PRWATCH" --remote partner "$REPO" scan 2>&1)
  # Only the partner PR (#602) is examined; #601 (origin) is filtered out.
  echo "$OUT" | grep -q 'processing PR #602' || exit 11
  echo "$OUT" | grep -q 'processing PR #601' && exit 12
  echo "$OUT" | grep -q "remote=partner candidates=1" || exit 13

  # The complementary origin scan sees only #601.
  OUT2=$(PATH="$BIN:$PATH" RUN_ISSUES_LOCK_ROOT="$WORK/locks" PR_WATCH_ENABLE_CONFLICT_RESOLUTION=0 \
         "$PRWATCH" --remote origin "$REPO" scan 2>&1)
  echo "$OUT2" | grep -q 'processing PR #601' || exit 14
  echo "$OUT2" | grep -q 'processing PR #602' && exit 15
  echo "$OUT2" | grep -q "remote=origin candidates=1" || exit 16
  exit 0
)
case $? in
  0)  ok "scan --remote filters runs by recorded remote + logs per-remote candidate count" ;;
  11) no "scan --remote partner did not process the partner PR #602" ;;
  12) no "scan --remote partner leaked the origin PR #601" ;;
  13) no "scan --remote partner did not log 'remote=partner candidates=1'" ;;
  14) no "scan --remote origin did not process the origin PR #601" ;;
  15) no "scan --remote origin leaked the partner PR #602" ;;
  16) no "scan --remote origin did not log 'remote=origin candidates=1'" ;;
  *)  no "scan-filter case crashed" ;;
esac

echo "----------------------------------------"
printf 'pr-watch-multi-remote: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
