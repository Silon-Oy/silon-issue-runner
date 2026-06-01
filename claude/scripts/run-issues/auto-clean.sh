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
#   4  any completed run exists (PR likely open) — labelled auto-clean-skipped
#   5  no local run-dirs for this issue (likely cross-machine) — ssh hint posted
#   6  cleanup-run.sh teardown failed
#
# Loop guard: on the non-cleanable terminal cases (4 and 5) we add the
# `auto-clean-skipped` label so the poller's scan_clean stops re-emitting the
# issue. We deliberately do NOT reuse `needs-human` here — auto-clean-skipped is
# a distinct, auto-clean-specific signal so the two concerns never collide.
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
  local repo_args=""
  [ -n "$OWNER_REPO" ] && repo_args="--repo $OWNER_REPO"
  # shellcheck disable=SC2086
  (
    cd "$REPO_ROOT"
    gh label create "$SKIPPED_LABEL" $repo_args \
      --color "ededed" \
      --description "auto-clean skipped this issue; needs human attention" \
      >/dev/null 2>&1 || true
    gh issue edit "$ISSUE_NUM" $repo_args --add-label "$SKIPPED_LABEL" >/dev/null 2>&1 || true
  )
}

# ---------- 1. lock ----------
# Acquire the per-issue lock BEFORE any teardown. The lock is namespaced by
# remote so customer-d#5 and Silon-Oy#5 hold distinct locks and never block each
# other.
if ! lock_issue "$ISSUE_NUM" "$REMOTE_NAME"; then
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
shopt -s nullglob
for rj in "$RUNS_DIR"/*/run.json; do
  n=$(jq -r '.issue_number // empty' "$rj" 2>/dev/null || echo "")
  [ "$n" = "$ISSUE_NUM" ] || continue
  r=$(jq -r '.remote // "origin"' "$rj" 2>/dev/null || echo "origin")
  [ "$r" = "$REMOTE_NAME" ] || continue
  total=$((total + 1))
  s=$(jq -r '.status // ""' "$rj" 2>/dev/null || echo "")
  [ "$s" = "completed" ] && completed=$((completed + 1))
done

if [ "$total" -eq 0 ]; then
  # Cross-machine fallback: this issue has no run-dirs on this host. The
  # resources (if any) live on another machine. Post an ssh hint and mark the
  # issue auto-clean-skipped so we stop re-emitting it.
  log "no local run-dirs for issue #$ISSUE_NUM (remote=$REMOTE_NAME, cross-machine?)"
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry] would post cross-machine ssh hint + label $SKIPPED_LABEL"
  else
    comment_issue "$REPO_ROOT" "$ISSUE_NUM" \
"## auto-clean: ei paikallisia ajoresursseja

Tällä koneella (\`$(hostname -s)\`) ei löytynyt issueen #$ISSUE_NUM liittyviä run-direjä (remote \`$REMOTE_NAME\`). Resurssit ovat todennäköisesti toisella koneella.

Aja siivous siellä:

\`\`\`bash
ssh studio '~/.claude/scripts/run-issues/cleanup-run.sh --issue $ISSUE_NUM --force --yes'
\`\`\`

Issueen on lisätty label \`$SKIPPED_LABEL\` jotta auto-clean ei poimi sitä uudelleen." \
      "$OWNER_REPO" "$REMOTE_NAME" \
      || log "comment post failed (non-fatal)"
  fi
  add_skipped_label
  unlock_issue "$ISSUE_NUM" "$REMOTE_NAME"
  exit 5
fi

if [ "$completed" -gt 0 ]; then
  # ANY completed run for this issue means a PR is likely open. We refuse to
  # touch the issue at all — closing it (or tearing down sibling non-completed
  # runs) could orphan an open PR.
  log "$completed of $total run-dir(s) for issue #$ISSUE_NUM are completed — skipping (PR may be open)"
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry] would post completed-present notice + label $SKIPPED_LABEL"
  else
    comment_issue "$REPO_ROOT" "$ISSUE_NUM" \
"## auto-clean: completed-ajo(ja) läsnä

Issuella #$ISSUE_NUM on completed-ajo(ja) ($completed/$total), joilla voi olla avoin PR — ei siivottu eikä suljettu. auto-clean ei kosketa issuea turvallisuussyistä.

Sulje PR ensin tai aja käsin:

\`\`\`bash
~/.claude/scripts/run-issues/cleanup-run.sh --issue $ISSUE_NUM --force
\`\`\`

Issueen on lisätty label \`$SKIPPED_LABEL\` jotta auto-clean ei poimi sitä uudelleen." \
      "$OWNER_REPO" "$REMOTE_NAME" \
      || log "comment post failed (non-fatal)"
  fi
  add_skipped_label
  unlock_issue "$ISSUE_NUM" "$REMOTE_NAME"
  exit 4
fi

# ---------- 3. teardown ----------
# Reached only when completed == 0: every run-dir for this issue is
# non-completed, so there is no open PR to protect. cleanup-run.sh WITHOUT
# --force tears them down and also removes the per-issue lock.
log "tearing down issue #$ISSUE_NUM remote=$REMOTE_NAME ($total non-completed run-dir(s))"
CLEANUP_ARGS=(--repo "$REPO_ROOT" --issue "$ISSUE_NUM" --remote "$REMOTE_NAME" --yes)
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
  unlock_issue "$ISSUE_NUM" "$REMOTE_NAME"
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

comment_issue "$REPO_ROOT" "$ISSUE_NUM" \
"## auto-clean: siivous valmis

Issueen #$ISSUE_NUM liittyvät paikalliset väliaikaisresurssit on siivottu koneella \`$(hostname -s)\` (remote \`$REMOTE_NAME\`):

- Siivotut run-dirit: $total (joista $completed completed-tilassa ohitettiin)
- Worktree ja branch poistettu
- DB-klooni dropattu (jos käytössä, best-effort)
- Issue suljettu

Olennaiset artefaktit on arkistoitu hakemistoon \`.claude/run-issues-archive/\`." \
  "$OWNER_REPO" "$REMOTE_NAME" \
  || log "summary comment post failed (non-fatal)"

# Remove the trigger label so a reopened issue is not immediately re-cleaned.
# shellcheck disable=SC2086
(
  cd "$REPO_ROOT"
  gh issue edit "$ISSUE_NUM" $REPO_ARGS --remove-label "$RUN_ISSUES_CLEAN_LABEL" >/dev/null 2>&1 || true
)

log "done: issue #$ISSUE_NUM remote=$REMOTE_NAME cleaned and closed"
exit 0
