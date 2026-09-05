#!/usr/bin/env bash
# wake-run.example.sh — one drain window on a sleeping host.
#
# Copy to ~/bin/wake-run.sh on the runner host and edit the two HOST SETUP
# blocks below. This file is an example, not an installed script: everything a
# host needs beyond "merge, drain, merge again" is specific to that host, and a
# shipped script would only pretend otherwise.
#
# Start it synchronously from outside:
#
#   sprite exec -s <sprite> -- bash -lc '~/bin/wake-run.sh'
#
# The connection must stay open for the whole window. On a Sprite, "idle" means
# no external session, not idle CPU — the machine freezes ~30 s after the last
# one closes even with work in flight. See docs/sprite-runner.md.
#
# Repos and pickup labels are NOT listed here: drain-queue.sh reads them from
# ~/.config/run-issues/watchlist.json, the same file and the same resolver the
# poller uses. Keeping a second list here is how the two drift apart.

set -euo pipefail

# Survive a dropped connection. The host freezes when the last external session
# closes, and when it is woken again the dead session's SIGHUP lands on whatever
# this script started — killing the orchestrator mid-phase, which is NOT
# resumable (only the worktree's commits survive). Ignoring HUP here and running
# the window in its own session keeps the drain alive across a timed-out exec;
# reconnect with a keepalive and it is still there.
#
# This MUST come before the host-setup blocks below: those start background
# daemons of their own, and a SIGHUP arriving later would take them down too.
#
#   Keepalive for an already-detached window:
#   sprite exec -s <sprite> -- bash -lc \
#     'while pgrep -f orchestrate.sh >/dev/null; do sleep 20; done'
trap "" HUP
if [ "${WAKE_RUN_DETACHED:-0}" != "1" ] && command -v setsid >/dev/null 2>&1; then
  export WAKE_RUN_DETACHED=1
  # New session, stdio kept: the caller still sees the log and gets the exit
  # code (`-w` waits), but the tty going away no longer signals the group.
  exec setsid -w "$0" "$@"
fi

RUNNER="${RUNNER_DIR:-$HOME/.claude/scripts/run-issues}"
DRAIN="$RUNNER/drain-queue.sh"

# Let an agent resolve a rebase conflict or repair red CI instead of stalling
# the chain — the same defaults the pr-watch poller applies.
export PR_WATCH_ENABLE_CONFLICT_RESOLUTION="${PR_WATCH_ENABLE_CONFLICT_RESOLUTION:-1}"
export PR_WATCH_ENABLE_CI_REPAIR="${PR_WATCH_ENABLE_CI_REPAIR:-1}"

# Post-drain retry budget while CI is still running: attempts × interval.
PR_WATCH_POST_ATTEMPTS="${PR_WATCH_POST_ATTEMPTS:-8}"
PR_WATCH_POST_INTERVAL="${PR_WATCH_POST_INTERVAL:-120}"

log() { printf '[wake-run %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

# Repos to scan for mergeable PRs, read from the watchlist so this file needs
# no list of its own.
mapfile -t REPOS < <(
  jq -r '.repos[]?.path // empty' \
    "${RUN_ISSUES_WATCHLIST:-$HOME/.config/run-issues/watchlist.json}" 2>/dev/null || true
)

# has_merge_candidate <repo> — 0 if the repo has an open PR carrying the merge
# label. pr-watch returns rc 4 both for "CI still pending" and for "no merge
# label", so the retry loop must not wait on PRs a human chose to review by hand.
#
# The label match happens HERE, not in the query: `gh pr list --label X` goes
# through GitHub's search index, which lags ~25 s behind reality. A PR the drain
# opened seconds ago is invisible to it, so the loop concludes "nothing to wait
# for" and skips the merge of the very PR this window just created — observed
# with a PR labelled at 07:26:50 that the search still missed at 07:26:54.
# Listing without a filter uses the plain PR endpoint, which is current.
has_merge_candidate() {
  local slug n label="${PR_WATCH_MERGE_LABEL:-auto-merge}"
  # Single quotes: in double quotes bash would expand the `$#` in `\.git$##` to
  # the positional-parameter count and hand sed a broken expression.
  slug=$(git -C "$1" remote get-url origin | sed -E 's#.*github\.com[:/]##; s#\.git$##')
  n=$(gh pr list -R "$slug" --state open --limit 100 --json labels \
        --jq "[.[] | select(.labels | any(.name == \"$label\"))] | length" 2>/dev/null || echo 0)
  [ "${n:-0}" -gt 0 ]
}

# pr_watch_scan <repo> — one scan; rc 0 (merged / nothing to do) and rc 2 (no
# candidate) are quiet successes, rc 4 means "CI pending, retry later", anything
# else is reported and left for a human (pr-watch has already commented/labelled).
pr_watch_scan() {
  local repo="$1" rc=0
  "$RUNNER/pr-watch.sh" "$repo" scan || rc=$?
  case "$rc" in
    0|2) return 0 ;;
    4)   return 4 ;;
    *)   log "pr-watch $repo: rc=$rc — needs a human (see PR comment / needs-human label)"; return "$rc" ;;
  esac
}

# ---------------------------------------------------------------------------
# HOST SETUP 1 — services that do not come back by themselves
#
# A checkpoint/restore host does not restart daemons on wake, so anything a
# target repo's provision hook or test suite needs must be started here, before
# the drain. Delete what does not apply; add what does.
#
# Postgres (a repo whose provision hook reaches the database over TCP):
#   pg_isready -h 127.0.0.1 -p 5433 -q || sudo pg_ctlcluster 18 main start
#   pg_isready -h 127.0.0.1 -p 5433 -q
#
# Docker (a Compose-based repo whose implementer runs the stack):
#   if ! docker info >/dev/null 2>&1; then
#     sudo dockerd >/tmp/dockerd.log 2>&1 &
#     for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
#   fi
#   docker info >/dev/null   # hard fail if it did not come up (see /tmp/dockerd.log)
# ---------------------------------------------------------------------------

rc=0

# --- 1. Merge what earlier windows left behind ---
for repo in "${REPOS[@]:-}"; do
  [ -n "$repo" ] || continue
  log "pre-drain pr-watch scan: $repo"
  pr_watch_scan "$repo" || true   # pending CI or a human handover must not block the drain
done

# --- 2. Drain. No arguments: drain-queue.sh takes the repos and their pickup
#        labels straight from the watchlist. ---
"$DRAIN" || rc=$?

# --- 3. Merge this window's PRs once their CI is green ---
for repo in "${REPOS[@]:-}"; do
  [ -n "$repo" ] || continue
  attempt=0
  while :; do
    attempt=$((attempt + 1))
    log "post-drain pr-watch scan ($attempt/$PR_WATCH_POST_ATTEMPTS): $repo"
    src=0; pr_watch_scan "$repo" || src=$?
    [ "$src" = 4 ] || break                      # merged, nothing to do, or handed to a human
    has_merge_candidate "$repo" || { log "pr-watch $repo: no open PR with the merge label — nothing to wait for"; break; }
    [ "$attempt" -lt "$PR_WATCH_POST_ATTEMPTS" ] || { log "pr-watch $repo: CI still pending after $attempt attempts — next window retries"; break; }
    sleep "$PR_WATCH_POST_INTERVAL"
  done
done

exit "$rc"
