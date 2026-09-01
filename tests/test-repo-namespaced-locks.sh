#!/usr/bin/env bash
# test-repo-namespaced-locks.sh — repo component in the run identity (issue #67).
#
# Before this fix the isolation key was (remote, issue), so two repos' issue #42
# collided on `issue-42.lock` and `run-issues-42`. Three consequences, all
# covered here:
#   1. Silent starvation — the poller's tmux duplicate check matched across repos.
#   2. Cross-repo lock theft — finalize_stalled deleted another repo's live lock.
#   3. Stale steal from the wrong repo — the mtime read belonged to a foreign run.
#
# Sections:
#   (a) slugify_repo_component / repo_slug — filename-safe, deterministic,
#       owner/repo preferred, repo-dir basename as fallback.
#   (b) remote_label / session_suffix — repo-namespaced shapes, and the legacy
#       shapes reproduced exactly when no slug is passed.
#   (c) locks: two repos' issue #42 coexist; same (repo, issue) still excludes.
#   (d) transition window: a FRESH legacy lock blocks a repo-namespaced acquire;
#       a stale one does not and is garbage-collected.
#   (e) finalize_stalled never touches another repo's lock or tmux session, and
#       still finalizes legacy runs under their legacy names.
#   (f) _running_session_name sees both the current and the legacy session name
#       (rollout safety), and never another repo's.
#   (g) cleanup-run.sh removes the repo-namespaced lock of a post-#67 run.
#
# Verkoton ja deterministinen: aidot paikalliset git-repot, stubattu tmux + gh.
# Run: bash tests/test-repo-namespaced-locks.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GR_LIB="$HERE/../lib/git-remote.sh"
LOCKING_LIB="$HERE/../lib/locking.sh"
STATE_LIB="$HERE/../lib/state.sh"
POLLER="$HERE/../poller.sh"
CLEANUP="$HERE/../cleanup-run.sh"

WORK=$(mktemp -d -t repo-ns-locks.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0

eq() {  # eq <got> <want> <tag>
  if [ "$1" = "$2" ]; then
    echo "PASS $3"
  else
    echo "FAIL $3: got '$1' want '$2'"
    FAIL=1
  fi
}

# ===========================================================================
# (a) slugify_repo_component / repo_slug
# ===========================================================================
# shellcheck source=../lib/git-remote.sh
. "$GR_LIB"

eq "$(slugify_repo_component 'Silon-Oy/data-report')" "silon-oy-data-report" \
  "(a) owner/repo -> slug (slash + case folded)"
# tmux rejects '.' and ':' in session names, and repo names carry dots in
# practice — the whitelist must fold them, not pass them through.
eq "$(slugify_repo_component 'Silon-Oy/foo.dev_v2')" "silon-oy-foo-dev-v2" \
  "(a) dots/underscores folded to single dashes"
eq "$(slugify_repo_component '--Weird__Name--')" "weird-name" \
  "(a) leading/trailing separators trimmed"
eq "$(slugify_repo_component '')" "" "(a) empty input -> empty"
# Cap: truncation must not leave a trailing dash (it would produce two names
# for one repo depending on where the cut landed).
eq "$(RUN_ISSUES_REPO_SLUG_MAX=10 slugify_repo_component 'abcdefghi-jklmno')" "abcdefghi" \
  "(a) cap applied, no trailing dash"

# repo_slug against a real clone with two remotes.
CLONE="$WORK/clone"
git init -q "$CLONE"
(
  cd "$CLONE"
  git config user.email t@t.t
  git config user.name t
  echo v0 > f.txt
  git add f.txt
  git commit -qm init
  git branch -M main
  git remote add origin "git@github.com:Silon-Oy/map-api.git"
  git remote add partner "https://github.com/partner-org/map-api.git"
)
eq "$(repo_slug "$CLONE" origin)" "silon-oy-map-api" \
  "(a) repo_slug prefers owner/repo from the remote URL"
# The owner half is what keeps two orgs' same-named repos apart — the remote
# name alone cannot, because both are usually called 'origin' in their clone.
eq "$(repo_slug "$CLONE" partner)" "partner-org-map-api" \
  "(a) repo_slug is per-remote (different owner -> different slug)"

NOREMOTE="$WORK/Plain.Repo"
mkdir -p "$NOREMOTE/.git"
eq "$(repo_slug "$NOREMOTE")" "plain-repo" \
  "(a) fallback to repo-dir basename when no remote resolves"
eq "$(repo_slug '')" "" "(a) empty repo root -> empty slug (legacy naming)"

# ===========================================================================
# (b) remote_label / session_suffix
# ===========================================================================
eq "$(remote_label origin 42 silon-oy-app)" "silon-oy-app-issue-42" \
  "(b) remote_label origin + slug"
eq "$(remote_label partner 42 partner-org-map)" "partner-org-map-partner-issue-42" \
  "(b) remote_label non-origin + slug"
eq "$(session_suffix origin 42 silon-oy-app)" "silon-oy-app-42" \
  "(b) session_suffix origin + slug"
eq "$(session_suffix partner 42 partner-org-map)" "partner-org-map-partner-issue-42" \
  "(b) session_suffix non-origin + slug"
# Legacy shapes: reproduced EXACTLY when no slug is passed. This is not just
# back-compat cosmetics — the poller and the lock guard use these to address
# runs started by the previous version.
eq "$(remote_label origin 42)" "issue-42" "(b) legacy remote_label origin"
eq "$(remote_label partner 42)" "partner-issue-42" "(b) legacy remote_label non-origin"
eq "$(session_suffix origin 42)" "42" "(b) legacy session_suffix origin"
eq "$(session_suffix partner 42)" "partner-issue-42" "(b) legacy session_suffix non-origin"

# The core acceptance property, at the naming layer.
A_LABEL=$(remote_label origin 42 repo-a)
B_LABEL=$(remote_label origin 42 repo-b)
if [ "$A_LABEL" != "$B_LABEL" ]; then
  echo "PASS (b) two repos' issue #42 derive different labels ($A_LABEL vs $B_LABEL)"
else
  echo "FAIL (b) two repos' issue #42 collided on '$A_LABEL'"
  FAIL=1
fi

# ===========================================================================
# (c) locks: cross-repo coexistence, same-repo exclusion
# ===========================================================================
(
  export RUN_ISSUES_LOCK_ROOT="$WORK/locks-c"
  # shellcheck source=../lib/locking.sh
  . "$LOCKING_LIB"

  lock_issue 42 origin repo-a || { echo "FAIL (c) repo-a acquire"; exit 1; }
  [ -d "$RUN_ISSUES_LOCK_ROOT/repo-a-issue-42.lock" ] \
    || { echo "FAIL (c) repo-a lock dir missing"; exit 1; }

  # THE regression: this used to fail (same issue-42.lock) and starve repo-b.
  lock_issue 42 origin repo-b || { echo "FAIL (c) repo-b acquire collided with repo-a"; exit 1; }
  [ -d "$RUN_ISSUES_LOCK_ROOT/repo-b-issue-42.lock" ] \
    || { echo "FAIL (c) repo-b lock dir missing"; exit 1; }

  # Same (repo, issue) must still be mutually exclusive.
  if lock_issue 42 origin repo-a; then
    echo "FAIL (c) re-acquiring repo-a's own lock succeeded"; exit 1
  fi

  # Unlock is scoped to the caller's own name.
  unlock_issue 42 origin repo-a
  [ ! -d "$RUN_ISSUES_LOCK_ROOT/repo-a-issue-42.lock" ] \
    || { echo "FAIL (c) repo-a lock not removed"; exit 1; }
  [ -d "$RUN_ISSUES_LOCK_ROOT/repo-b-issue-42.lock" ] \
    || { echo "FAIL (c) repo-a unlock removed repo-b's lock"; exit 1; }
  echo "PASS (c) repo-namespaced locks coexist; same repo still excluded; unlock scoped"
) || FAIL=1

# ===========================================================================
# (d) transition window: legacy (unqualified) lock
# ===========================================================================
(
  export RUN_ISSUES_LOCK_ROOT="$WORK/locks-d1"
  # shellcheck source=../lib/locking.sh
  . "$LOCKING_LIB"

  # A run started by the PREVIOUS version holds the unqualified lock. The new
  # code cannot tell which repo it belongs to, so it must refuse — otherwise the
  # rollout would start a second orchestrator against a live run.
  lock_issue 42 || { echo "FAIL (d1) legacy acquire"; exit 1; }
  if lock_issue 42 origin repo-a; then
    echo "FAIL (d1) acquired despite a fresh legacy lock"; exit 1
  fi
  # And it must not leave its own half-taken lock behind.
  [ ! -d "$RUN_ISSUES_LOCK_ROOT/repo-a-issue-42.lock" ] \
    || { echo "FAIL (d1) repo-namespaced lock left behind after refusal"; exit 1; }
  [ -d "$RUN_ISSUES_LOCK_ROOT/issue-42.lock" ] \
    || { echo "FAIL (d1) legacy lock was stolen"; exit 1; }
  echo "PASS (d1) fresh legacy lock blocks a repo-namespaced acquire"
) || FAIL=1

(
  export RUN_ISSUES_LOCK_ROOT="$WORK/locks-d2"
  export RUN_ISSUES_LOCK_STALE_SECS=1
  # shellcheck source=../lib/locking.sh
  . "$LOCKING_LIB"

  lock_issue 42 || { echo "FAIL (d2) legacy acquire"; exit 1; }
  touch -t 202001010000 "$RUN_ISSUES_LOCK_ROOT/issue-42.lock"
  lock_issue 42 origin repo-a || { echo "FAIL (d2) stale legacy lock blocked acquire"; exit 1; }
  [ ! -d "$RUN_ISSUES_LOCK_ROOT/issue-42.lock" ] \
    || { echo "FAIL (d2) stale legacy lock not garbage-collected"; exit 1; }
  echo "PASS (d2) stale legacy lock ignored + removed"
) || FAIL=1

(
  export RUN_ISSUES_LOCK_ROOT="$WORK/locks-d3"
  # shellcheck source=../lib/locking.sh
  . "$LOCKING_LIB"

  # Documented asymmetry: an OLD process (legacy name) cannot see a new
  # repo-namespaced lock — it predates the name and cannot be retrofitted. The
  # guard therefore only runs in the new -> old direction. Assert it explicitly
  # so the limitation is a decision, not a surprise.
  lock_issue 42 origin repo-a || { echo "FAIL (d3) repo-a acquire"; exit 1; }
  lock_issue 42 || { echo "FAIL (d3) legacy caller blocked (unexpected)"; exit 1; }
  echo "PASS (d3) legacy caller unaffected by repo-namespaced locks (known, bounded)"
) || FAIL=1

# ===========================================================================
# (e)/(f) poller: finalize_stalled + _running_session_name
# ===========================================================================
# poller.sh exits at source time off-Studio, so extract the functions (same
# harness as test-poller-stale-detection.sh).
# shellcheck source=../lib/state.sh
. "$STATE_LIB"
set +e   # state.sh enables -e; the assertions below rely on plain if/else
# shellcheck source=../lib/labels.sh
. "$HERE/../lib/labels.sh"

extract_fn() {
  awk -v fname="$1" '
    $0 ~ "^"fname"\\(\\) \\{" { p=1 }
    p { print }
    p && /^\}/ { exit }
  ' "$POLLER"
}
eval "$(extract_fn _running_session_name)"
eval "$(extract_fn finalize_stalled)"

# shellcheck disable=SC2034
THIS_HOST="test-host"
# shellcheck disable=SC2034
RUN_ISSUES_STALE_AFTER=1800
LOG="$WORK/poller.log"
export RUN_ISSUES_LOCK_ROOT="$WORK/locks-e"
mkdir -p "$RUN_ISSUES_LOCK_ROOT"

# tmux + gh stubs (exact-match `=name` syntax, as poller.sh uses).
mkdir -p "$WORK/tmux-sessions" "$WORK/bin"
TMUX_LOG="$WORK/tmux-calls.log"
cat > "$WORK/bin/tmux" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$TMUX_LOG"
case "\$1" in
  has-session)
    shift; while [ "\$1" != "-t" ] && [ \$# -gt 0 ]; do shift; done
    name="\${2#=}"
    [ -f "$WORK/tmux-sessions/\$name" ]
    ;;
  kill-session)
    shift; while [ "\$1" != "-t" ] && [ \$# -gt 0 ]; do shift; done
    name="\${2#=}"
    rm -f "$WORK/tmux-sessions/\$name"
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$WORK/bin/tmux"
cat > "$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"--body-file"*) : ;;
esac
exit 0
SH
chmod +x "$WORK/bin/gh"
PATH="$WORK/bin:$PATH"

REPO_A="$WORK/repo-a"
REPO_B="$WORK/repo-b"
mkdir -p "$REPO_A/.git" "$REPO_B/.git"

# repo-a: a post-#67 run for issue 42, stalled. repo-b: a LIVE run for its own
# issue 42 (same number, different repo) holding its own lock and session.
RID_A="20260730-1200-repo-a-issue-42"
RD_A="$REPO_A/.claude/run-issues/$RID_A"
state_init "$RD_A" "$RID_A" "$REPO_A" 42
state_set "$RD_A" "repo_slug" "repo-a"
TMP=$(mktemp); jq '.host = "test-host" | .current_state = "S8_Implementer"' "$RD_A/run.json" > "$TMP"; mv "$TMP" "$RD_A/run.json"

mkdir -p "$RUN_ISSUES_LOCK_ROOT/repo-a-issue-42.lock" \
         "$RUN_ISSUES_LOCK_ROOT/repo-b-issue-42.lock" \
         "$RUN_ISSUES_LOCK_ROOT/issue-42.lock"
touch "$WORK/tmux-sessions/run-issues-repo-a-42" \
      "$WORK/tmux-sessions/run-issues-repo-b-42" \
      "$WORK/tmux-sessions/run-issues-42"

# (f) session lookup, before anything is killed.
GOT=$(_running_session_name "run-issues-" origin repo-b 42)
eq "$GOT" "run-issues-repo-b-42" "(f) finds the repo-namespaced session"
# Rollout safety: a session started by the previous poller version carries the
# legacy name; missing it would spawn a duplicate orchestrator.
GOT=$(_running_session_name "run-issues-" origin repo-c 42)
eq "$GOT" "run-issues-42" "(f) falls back to the legacy session name"
rm -f "$WORK/tmux-sessions/run-issues-42"
if _running_session_name "run-issues-" origin repo-c 42 >/dev/null; then
  echo "FAIL (f) matched another repo's session for repo-c"
  FAIL=1
else
  echo "PASS (f) another repo's session is not treated as this repo's"
fi
touch "$WORK/tmux-sessions/run-issues-42"

# (e) finalize repo-a's stalled run.
finalize_stalled 42 "$RD_A"

[ ! -d "$RUN_ISSUES_LOCK_ROOT/repo-a-issue-42.lock" ] \
  && echo "PASS (e) own lock released" \
  || { echo "FAIL (e) own lock not released"; FAIL=1; }
[ -d "$RUN_ISSUES_LOCK_ROOT/repo-b-issue-42.lock" ] \
  && echo "PASS (e) other repo's LIVE lock untouched (no cross-repo lock theft)" \
  || { echo "FAIL (e) deleted repo-b's lock — cross-repo lock theft"; FAIL=1; }
[ -d "$RUN_ISSUES_LOCK_ROOT/issue-42.lock" ] \
  && echo "PASS (e) unrelated legacy lock untouched by a post-#67 run" \
  || { echo "FAIL (e) removed an unqualified lock it does not own"; FAIL=1; }
[ ! -f "$WORK/tmux-sessions/run-issues-repo-a-42" ] \
  && echo "PASS (e) own tmux session killed" \
  || { echo "FAIL (e) own tmux session survived"; FAIL=1; }
[ -f "$WORK/tmux-sessions/run-issues-repo-b-42" ] \
  && echo "PASS (e) other repo's tmux session untouched" \
  || { echo "FAIL (e) killed repo-b's tmux session"; FAIL=1; }
ST=$(jq -r '.status' "$RD_A/run.json")
RE=$(jq -r '.blocked_reason' "$RD_A/run.json")
eq "$ST" "blocked" "(e) run finalized as blocked"
eq "$RE" "stalled_in_S8_Implementer" "(e) blocked_reason records the stalled state"

# Legacy run: no repo_slug -> its lock and session carry the legacy names, and
# finalize must still reach them (an in-flight pre-#67 run must not orphan).
RID_L="20260730-1300-issue-55"
RD_L="$REPO_A/.claude/run-issues/$RID_L"
state_init "$RD_L" "$RID_L" "$REPO_A" 55
TMP=$(mktemp); jq '.host = "test-host" | .current_state = "S6_CycleReview"' "$RD_L/run.json" > "$TMP"; mv "$TMP" "$RD_L/run.json"
mkdir -p "$RUN_ISSUES_LOCK_ROOT/issue-55.lock"
touch "$WORK/tmux-sessions/run-issues-55" \
      "$WORK/tmux-sessions/run-issues-restart-repo-a-55"
finalize_stalled 55 "$RD_L"
[ ! -d "$RUN_ISSUES_LOCK_ROOT/issue-55.lock" ] \
  && echo "PASS (e) legacy run's legacy lock released" \
  || { echo "FAIL (e) legacy lock not released — pre-#67 run orphaned"; FAIL=1; }
[ ! -f "$WORK/tmux-sessions/run-issues-55" ] \
  && echo "PASS (e) legacy run's legacy session killed" \
  || { echo "FAIL (e) legacy session survived"; FAIL=1; }
# A legacy run restarted by THIS poller version carries the new session shape;
# both must die or the run keeps holding a GLOBAL_MAX slot.
[ ! -f "$WORK/tmux-sessions/run-issues-restart-repo-a-55" ] \
  && echo "PASS (e) legacy run's repo-namespaced restart session also killed" \
  || { echo "FAIL (e) repo-namespaced restart session of a legacy run survived"; FAIL=1; }

# ===========================================================================
# (g) cleanup-run.sh removes the repo-namespaced lock of a post-#67 run
# ===========================================================================
REPO_G="$WORK/repo-g"
mkdir -p "$REPO_G/.git"
export RUN_ISSUES_LOCK_ROOT="$WORK/locks-g"
RID_G="20260730-1400-repo-g-issue-77"
RD_G="$REPO_G/.claude/run-issues/$RID_G"
state_init "$RD_G" "$RID_G" "$REPO_G" 77
state_set "$RD_G" "repo_slug" "repo-g"
state_finalize "$RD_G" "blocked"
mkdir -p "$RUN_ISSUES_LOCK_ROOT/repo-g-issue-77.lock"
# A different repo's live lock for the same issue number must survive teardown.
mkdir -p "$RUN_ISSUES_LOCK_ROOT/repo-h-issue-77.lock"

RUN_ISSUES_LOCK_ROOT="$RUN_ISSUES_LOCK_ROOT" \
  bash "$CLEANUP" --repo "$REPO_G" --issue 77 --yes >/dev/null 2>&1
RC_G=$?
eq "$RC_G" "0" "(g) cleanup-run.sh exit code"
[ ! -d "$RUN_ISSUES_LOCK_ROOT/repo-g-issue-77.lock" ] \
  && echo "PASS (g) cleanup-run.sh removed the repo-namespaced lock" \
  || { echo "FAIL (g) repo-namespaced lock survived cleanup"; FAIL=1; }
[ -d "$RUN_ISSUES_LOCK_ROOT/repo-h-issue-77.lock" ] \
  && echo "PASS (g) cleanup-run.sh left another repo's lock alone" \
  || { echo "FAIL (g) cleanup removed another repo's lock"; FAIL=1; }

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "repo-namespaced-locks: all passed" || echo "repo-namespaced-locks: FAILURES"
[ "$FAIL" -eq 0 ]
