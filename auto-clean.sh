#!/usr/bin/env bash
# auto-clean.sh — label-driven teardown of a /run-issues issue's LOCAL
# temporary resources, then close the issue.
#
# Triggered by the Studio poller when an issue carries the `auto-clean` label
# (RUN_ISSUES_CLEAN_LABEL). It tears down the run artefacts for the issue via
# cleanup-run.sh, closes the GitHub issue (NOT deletes), and posts a Finnish
# situation summary.
#
# Usage:
#   auto-clean.sh --repo <repo-root> --issue <N> [--remote <name>] [--dry-run]
#
# Exit codes:
#   0  cleaned + issue closed + label removed
#   1  usage error
#   3  per-issue lock held by another run — safe to retry on a later tick
#   4  a completed run has an OPEN (or unresolvable) PR — labelled
#      auto-clean-skipped. A completed run whose PR is already MERGED/CLOSED is
#      cleaned normally (issue #116); only a live PR earns the precaution.
#   5  no local run-dirs for this issue (likely cross-machine) — machine-agnostic
#      cleanup hint posted
#   6  cleanup-run.sh teardown failed
#
# Loop guard: on the non-cleanable terminal cases (4 and 5) we add the
# `auto-clean-skipped` label so the poller's scan_clean stops re-emitting the
# issue. We deliberately do NOT reuse `needs-human` here — auto-clean-skipped is
# a distinct, auto-clean-specific signal so the two concerns never collide.
#
# PR merge-state (issue #116): auto-clean used to refuse on ANY completed run,
# assuming its PR might be open. It never checked. A merged PR does not close its
# issue unless the PR body carries `Closes #N`, so a merged-PR issue stayed open
# + reserved and its dependents stalled silently. We now read each completed
# run's PR state (from run.json .pr_url) and refuse ONLY for a genuinely OPEN (or
# unresolvable — fail-closed) PR.
#
# Multi-remote (issue #53): --remote scopes the teardown to a specific git
# remote so multi-org clones do not cross issues with the same number across
# orgs. Default "origin" preserves legacy behaviour.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUN_ISSUES_CLEAN_LABEL="${RUN_ISSUES_CLEAN_LABEL:-auto-clean}"
SKIPPED_LABEL="auto-clean-skipped"

# ---------- argument parsing ----------
REPO_ROOT=""
ISSUE_NUM=""
REMOTE_NAME="origin"
DRY_RUN=0

usage() {
  cat >&2 <<'USAGE'
auto-clean.sh --repo <repo-root> --issue <N> [--remote <name>] [--dry-run]
USAGE
  exit "${1:-1}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)    REPO_ROOT="${2:-}"; shift 2 ;;
    --issue)   ISSUE_NUM="${2:-}"; shift 2 ;;
    --remote)  REMOTE_NAME="${2:-origin}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    *)         echo "auto-clean: unexpected argument '$1'" >&2; usage 1 ;;
  esac
done

[ -n "$REPO_ROOT" ] || { echo "auto-clean: --repo is required" >&2; usage 1; }
[ -n "$ISSUE_NUM" ] || { echo "auto-clean: --issue is required" >&2; usage 1; }
[ -n "$REMOTE_NAME" ] || REMOTE_NAME="origin"
[ -d "$REPO_ROOT/.git" ] || { echo "auto-clean: not a git repo: $REPO_ROOT" >&2; exit 1; }

# ---------- libs ----------
# locking.sh provides lock_issue / unlock_issue and defines RUN_ISSUES_LOCK_ROOT
# (honouring any env override). issue.sh provides comment_issue.
# git-remote.sh provides resolve_remote_to_owner_repo for routing gh calls.
# shellcheck source=lib/git-remote.sh
. "$SCRIPT_DIR/lib/git-remote.sh"
# shellcheck source=lib/locking.sh
. "$SCRIPT_DIR/lib/locking.sh"
# shellcheck source=lib/issue.sh
. "$SCRIPT_DIR/lib/issue.sh"
# labels.sh provides labels_add / labels_remove / labels_ensure — REST-based
# label writes that avoid the read:project scope `gh issue edit` requires.
# shellcheck source=lib/labels.sh
. "$SCRIPT_DIR/lib/labels.sh"

# Resolve owner/repo for --repo routing on the closing gh calls. Empty -> use
# gh's cwd resolution (origin default). For non-origin a resolution failure is
# fatal: we cannot reliably target the right org.
OWNER_REPO=""
case "$REMOTE_NAME" in
  ""|origin) : ;;
  *)
    if ! OWNER_REPO=$(resolve_remote_to_owner_repo "$REPO_ROOT" "$REMOTE_NAME" 2>/dev/null); then
      echo "auto-clean: remote '$REMOTE_NAME' not found in $REPO_ROOT or URL un-parseable" >&2
      exit 1
    fi
    ;;
esac

# Repo component of the advisory lock (issue #67): the lock is a global
# namespace, so it must be repo-scoped or a teardown here would block (or steal
# from) another repo's run with the same issue number.
REPO_SLUG=$(repo_slug "$REPO_ROOT" "$REMOTE_NAME")

CLEANUP="$SCRIPT_DIR/cleanup-run.sh"
RUNS_DIR="$REPO_ROOT/.claude/run-issues"

log() { printf '%s auto-clean: %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

# add_skipped_label — best-effort: ensure the label exists, then add it. Any
# failure is non-fatal (logged only). Skipped under --dry-run.
add_skipped_label() {
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry] add label $SKIPPED_LABEL to #$ISSUE_NUM"
    return 0
  fi
  (
    cd "$REPO_ROOT"
    labels_ensure "$OWNER_REPO" "$SKIPPED_LABEL" "ededed" \
      "auto-clean skipped this issue; needs human attention" || true
    labels_add "$OWNER_REPO" "$ISSUE_NUM" "$SKIPPED_LABEL" || true
  ) 2>&1 | while IFS= read -r l; do log "$l"; done || true
}

# pr_state_of <pr-url> — prints the PR's GitHub state (OPEN/MERGED/CLOSED),
# upper-cased, or empty on any failure (no URL, gh missing, network/API error).
# The URL carries its own owner/repo, so gh needs no --repo routing. Read-only —
# it never mutates. Plain `gh`, matching the rest of auto-clean.sh (gh issue
# close); the completed-run gate treats an empty result as fail-closed.
pr_state_of() {
  local url="$1"
  [ -n "$url" ] || { printf ''; return 0; }
  gh pr view "$url" --json state --jq '(.state // "") | ascii_upcase' 2>/dev/null || printf ''
}

# ---------- 1. lock ----------
# Acquire the per-issue lock BEFORE any teardown. The lock is namespaced by repo
# AND remote so two orgs' #5 and another repo's #5 hold distinct locks and
# never block each other.
if ! lock_issue "$ISSUE_NUM" "$REMOTE_NAME" "$REPO_SLUG"; then
  log "lock held for issue #$ISSUE_NUM (remote=$REMOTE_NAME) — a run is in progress; will retry later"
  exit 3
fi

# IMPORTANT: cleanup-run.sh removes the per-issue lock as part of its teardown
# (it sources lib/locking.sh and rm -rf's the lock dir). So once we hand
# off to cleanup-run.sh on the success path, the lock is already gone. We must
# NOT call unlock_issue afterwards in a way that could fail under set -e —
# unlock_issue is idempotent (rm -rf ignores a missing dir), so it is safe, but
# we simply never call it on the success path. On the early-exit cases below we
# release the lock explicitly before exiting.

# ---------- 2. pre-check run-dirs for this issue ----------
# Count run-dirs whose run.json .issue_number matches AND whose .remote matches
# (legacy run.json without .remote is treated as "origin" so the default
# REMOTE_NAME picks them up). bash 3.2 compatible — plain counters.
total=0
completed=0
completed_prs=()
TEARDOWN_FORCE=0
shopt -s nullglob
for rj in "$RUNS_DIR"/*/run.json; do
  n=$(jq -r '.issue_number // empty' "$rj" 2>/dev/null || echo "")
  [ "$n" = "$ISSUE_NUM" ] || continue
  r=$(jq -r '.remote // "origin"' "$rj" 2>/dev/null || echo "origin")
  [ "$r" = "$REMOTE_NAME" ] || continue
  total=$((total + 1))
  s=$(jq -r '.status // ""' "$rj" 2>/dev/null || echo "")
  if [ "$s" = "completed" ]; then
    completed=$((completed + 1))
    # Record the run's PR URL (empty if legacy/unset) so the completed-run gate
    # below can resolve each PR's merge state. orchestrate.sh S12 writes pr_url.
    completed_prs+=("$(jq -r '.pr_url // ""' "$rj" 2>/dev/null || echo "")")
  fi
done

if [ "$total" -eq 0 ]; then
  # Cross-machine fallback: this issue has no run-dirs on this host. The
  # resources (if any) live on another machine. Post a hint and mark the issue
  # auto-clean-skipped so we stop re-emitting it.
  #
  # The hint names no machine on purpose. This branch runs precisely because
  # there is no run.json here to read a host from, so any machine name would be
  # a guess dressed up as instruction.
  log "no local run-dirs for issue #$ISSUE_NUM (remote=$REMOTE_NAME, cross-machine?)"
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry] would post cross-machine cleanup hint + label $SKIPPED_LABEL"
  else
    comment_issue "$REPO_ROOT" "$ISSUE_NUM" \
"## auto-clean: ei paikallisia ajoresursseja

Tällä koneella (\`$(hostname -s)\`) ei löytynyt issueen #$ISSUE_NUM liittyviä run-direjä (remote \`$REMOTE_NAME\`). Resurssit ovat todennäköisesti toisella koneella.

Aja siivous sillä koneella, jolla ajo tehtiin (ota siihen tarvittaessa ensin yhteys):

\`\`\`bash
~/.claude/scripts/run-issues/cleanup-run.sh --issue $ISSUE_NUM --force --yes
\`\`\`

Issueen on lisätty label \`$SKIPPED_LABEL\` jotta auto-clean ei poimi sitä uudelleen." \
      "$OWNER_REPO" "$REMOTE_NAME" \
      || log "comment post failed (non-fatal)"
  fi
  add_skipped_label
  unlock_issue "$ISSUE_NUM" "$REMOTE_NAME" "$REPO_SLUG"
  exit 5
fi

if [ "$completed" -gt 0 ]; then
  # A completed run normally has an OPEN PR, and closing the issue or tearing
  # down the run-dir could orphan it — the original blanket refusal. But once
  # that PR is MERGED (or CLOSED) there is nothing left to orphan: the work is
  # in, the issue should close, and any issues blocked on it must be unblocked.
  # Refusing regardless left merged-PR issues open + reserved and silently
  # stalled their dependency chains (issue #116).
  #
  # So resolve each completed run's PR state from its recorded pr_url and refuse
  # ONLY if some PR is still OPEN, or its state cannot be determined. The latter
  # is FAIL-CLOSED on purpose: an unresolvable state (missing pr_url on a legacy
  # run, a network/gh error) must never be mistaken for "merged" and orphan a
  # live PR — an unnecessary skip is recoverable, a torn-down open PR is not.
  blocking=0
  for pr in "${completed_prs[@]}"; do
    st=$(pr_state_of "$pr")
    case "$st" in
      MERGED|CLOSED) : ;;  # not open — safe to tear down
      OPEN)
        blocking=$((blocking + 1))
        log "issue #$ISSUE_NUM: a completed run's PR is OPEN ($pr) — protecting it"
        ;;
      *)
        blocking=$((blocking + 1))
        log "issue #$ISSUE_NUM: completed-run PR state unresolved (${pr:-no pr_url}) — fail-closed, protecting"
        ;;
    esac
  done

  if [ "$blocking" -gt 0 ]; then
    log "$blocking of $completed completed run-dir(s) for issue #$ISSUE_NUM have an open/unknown PR — skipping"
    if [ "$DRY_RUN" = "1" ]; then
      log "[dry] would post open-PR notice + label $SKIPPED_LABEL"
    else
      comment_issue "$REPO_ROOT" "$ISSUE_NUM" \
"## auto-clean: avoin PR läsnä

Issuella #$ISSUE_NUM on completed-ajo(ja) ($blocking/$completed), joiden PR on yhä avoin tai sen tilaa ei saatu selvitettyä — ei siivottu eikä suljettu. auto-clean ei kosketa issuea, jottei avointa PR:ää orvoteta.

Kun PR on mergetty (tai suljettu), auto-clean siivoaa ja sulkee issuen itse seuraavalla tikillä. Voit myös ajaa siivouksen käsin:

\`\`\`bash
~/.claude/scripts/run-issues/cleanup-run.sh --issue $ISSUE_NUM --force
\`\`\`

Issueen on lisätty label \`$SKIPPED_LABEL\` jotta auto-clean ei poimi sitä uudelleen." \
        "$OWNER_REPO" "$REMOTE_NAME" \
        || log "comment post failed (non-fatal)"
    fi
    add_skipped_label
    unlock_issue "$ISSUE_NUM" "$REMOTE_NAME" "$REPO_SLUG"
    exit 4
  fi

  # Every completed run's PR is MERGED/CLOSED — nothing to orphan. Fall through
  # to teardown, forcing cleanup-run.sh to include the completed run-dirs (it
  # skips completed runs without --force).
  log "$completed completed run-dir(s) for issue #$ISSUE_NUM all have a merged/closed PR — cleaning"
  TEARDOWN_FORCE=1
fi

# ---------- 3. teardown ----------
# Reached when no completed run needs protecting: either every run-dir is
# non-completed (no PR to orphan), or every completed run's PR is already
# MERGED/CLOSED (issue #116). In the latter case cleanup-run.sh needs --force to
# include the completed run-dirs (it skips them otherwise). cleanup-run.sh also
# removes the per-issue lock as part of its teardown.
log "tearing down issue #$ISSUE_NUM remote=$REMOTE_NAME ($total run-dir(s), force=$TEARDOWN_FORCE)"
CLEANUP_ARGS=(--repo "$REPO_ROOT" --issue "$ISSUE_NUM" --remote "$REMOTE_NAME" --yes)
[ "$TEARDOWN_FORCE" = "1" ] && CLEANUP_ARGS+=(--force)
[ "$DRY_RUN" = "1" ] && CLEANUP_ARGS+=(--dry-run)

if bash "$CLEANUP" "${CLEANUP_ARGS[@]}"; then
  cleanup_rc=0
else
  cleanup_rc=$?
fi

if [ "$cleanup_rc" -ne 0 ]; then
  log "cleanup-run.sh failed (rc=$cleanup_rc) for issue #$ISSUE_NUM"
  # cleanup-run.sh may or may not have removed the lock depending on where it
  # failed; unlock_issue is idempotent so this is safe either way.
  unlock_issue "$ISSUE_NUM" "$REMOTE_NAME" "$REPO_SLUG"
  exit 6
fi

# ---------- 4. success: close issue, comment, remove label ----------
# The lock was already removed by cleanup-run.sh's teardown — see the IMPORTANT
# note above. We do NOT call unlock_issue here.
if [ "$DRY_RUN" = "1" ]; then
  log "[dry] would close issue #$ISSUE_NUM, post summary, remove label $RUN_ISSUES_CLEAN_LABEL"
  exit 0
fi

REPO_ARGS=""
[ -n "$OWNER_REPO" ] && REPO_ARGS="--repo $OWNER_REPO"
# shellcheck disable=SC2086
(
  cd "$REPO_ROOT"
  gh issue close "$ISSUE_NUM" $REPO_ARGS >/dev/null 2>&1 || true
)

# Completed run-dirs are torn down here (not skipped) only because their PRs are
# merged/closed — note that in the summary so the count is not misread as "an
# open PR was cleaned".
completed_note=""
[ "$completed" -gt 0 ] && completed_note=" (näistä $completed completed-tilassa; PR mergetty/suljettu)"

comment_issue "$REPO_ROOT" "$ISSUE_NUM" \
"## auto-clean: siivous valmis

Issueen #$ISSUE_NUM liittyvät paikalliset väliaikaisresurssit on siivottu koneella \`$(hostname -s)\` (remote \`$REMOTE_NAME\`):

- Siivotut run-dirit: $total$completed_note
- Worktree ja branch poistettu
- DB-klooni dropattu (jos käytössä, best-effort)
- Issue suljettu

Olennaiset artefaktit on arkistoitu hakemistoon \`.claude/run-issues-archive/\`." \
  "$OWNER_REPO" "$REMOTE_NAME" \
  || log "summary comment post failed (non-fatal)"

# Remove the trigger label so a reopened issue is not immediately re-cleaned.
(
  cd "$REPO_ROOT"
  labels_remove "$OWNER_REPO" "$ISSUE_NUM" "$RUN_ISSUES_CLEAN_LABEL" || true
) 2>&1 | while IFS= read -r l; do log "$l"; done || true

log "done: issue #$ISSUE_NUM remote=$REMOTE_NAME cleaned and closed"
exit 0
