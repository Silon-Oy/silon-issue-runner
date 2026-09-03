#!/usr/bin/env bash
# auto-clean.sh — label-driven teardown of a /run-issues issue's LOCAL
# temporary resources, then close the issue.
#
# Triggered by the poller when an issue carries the `auto-clean` label
# (RUN_ISSUES_CLEAN_LABEL). It tears down the run artefacts for the issue via
# cleanup-run.sh, closes the GitHub issue (NOT deletes), and posts a Finnish
# situation summary.
#
# This script is a thin OUTCOME layer over lib/teardown.sh (issue #202), which
# owns every safety gate: the per-issue lock, the run-dir inventory, the
# completed-run PR gate and the cleanup-run.sh delegation. auto-clean is the
# FINISHING verb — it closes the issue. Its sibling auto-reset.sh runs the very
# same teardown and leaves the issue open so pickup starts it over. The gates are
# not copied between them; only these four values differ: trigger label, skipped
# label, whether the issue is closed, and the comment wording below.
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
# a distinct, auto-clean-specific signal so the two concerns never collide, and
# for the same reason auto-reset has a skipped label of its own.
#
# PR merge-state (issue #116): auto-clean used to refuse on ANY completed run,
# assuming its PR might be open. It never checked. A merged PR does not close its
# issue unless the PR body carries `Closes #N`, so a merged-PR issue stayed open
# + reserved and its dependents stalled silently. The shared layer now reads each
# completed run's PR state (from run.json .pr_url) and refuses ONLY for a
# genuinely OPEN (or unresolvable — fail-closed) PR.
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
# teardown.sh provides the shared gates + teardown_run.
# shellcheck source=lib/teardown.sh
. "$SCRIPT_DIR/lib/teardown.sh"

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

# ---------- the four values that make this verb auto-clean ----------
TEARDOWN_VERB="auto-clean"
TEARDOWN_TRIGGER_LABEL="$RUN_ISSUES_CLEAN_LABEL"
TEARDOWN_SKIPPED_LABEL="$SKIPPED_LABEL"
TEARDOWN_CLOSE_ISSUE=1
TEARDOWN_CLEANUP="$SCRIPT_DIR/cleanup-run.sh"

# The comment bodies. Context comes from the TD_* variables the shared layer
# sets before calling these.
teardown_comment_no_rundirs() {
  # The hint names no machine on purpose. This branch runs precisely because
  # there is no run.json here to read a host from, so any machine name would be
  # a guess dressed up as instruction.
  cat <<EOF
## auto-clean: ei paikallisia ajoresursseja

Tällä koneella (\`$TD_HOST\`) ei löytynyt issueen #$TD_ISSUE liittyviä run-direjä (remote \`$TD_REMOTE\`). Resurssit ovat todennäköisesti toisella koneella.

Aja siivous sillä koneella, jolla ajo tehtiin (ota siihen tarvittaessa ensin yhteys):

\`\`\`bash
~/.claude/scripts/run-issues/cleanup-run.sh --issue $TD_ISSUE --force --yes
\`\`\`

Issueen on lisätty label \`$TEARDOWN_SKIPPED_LABEL\` jotta auto-clean ei poimi sitä uudelleen.
EOF
}

teardown_comment_open_pr() {
  cat <<EOF
## auto-clean: avoin PR läsnä

Issuella #$TD_ISSUE on completed-ajo(ja) ($TD_BLOCKING/$TD_COMPLETED), joiden PR on yhä avoin tai sen tilaa ei saatu selvitettyä — ei siivottu eikä suljettu. auto-clean ei kosketa issuea, jottei avointa PR:ää orvoteta.

Kun PR on mergetty (tai suljettu), auto-clean siivoaa ja sulkee issuen itse seuraavalla tikillä. Voit myös ajaa siivouksen käsin:

\`\`\`bash
~/.claude/scripts/run-issues/cleanup-run.sh --issue $TD_ISSUE --force
\`\`\`

Issueen on lisätty label \`$TEARDOWN_SKIPPED_LABEL\` jotta auto-clean ei poimi sitä uudelleen.
EOF
}

teardown_comment_success() {
  # Completed run-dirs are torn down here (not skipped) only because their PRs
  # are merged/closed — note that in the summary so the count is not misread as
  # "an open PR was cleaned".
  local completed_note=""
  [ "$TD_COMPLETED" -gt 0 ] && completed_note=" (näistä $TD_COMPLETED completed-tilassa; PR mergetty/suljettu)"
  cat <<EOF
## auto-clean: siivous valmis

Issueen #$TD_ISSUE liittyvät paikalliset väliaikaisresurssit on siivottu koneella \`$TD_HOST\` (remote \`$TD_REMOTE\`):

- Siivotut run-dirit: $TD_TOTAL$completed_note
- Worktree ja branch poistettu
- DB-klooni dropattu (jos käytössä, best-effort)
- Issue suljettu

Olennaiset artefaktit on arkistoitu hakemistoon \`.claude/run-issues-archive/\`.
EOF
}

# ---------- run ----------
set +e
teardown_run "$REPO_ROOT" "$ISSUE_NUM" "$REMOTE_NAME" "$OWNER_REPO" "$REPO_SLUG" "$DRY_RUN"
RC=$?
set -e

if [ "$RC" -eq 0 ]; then
  teardown_log "done: issue #$ISSUE_NUM remote=$REMOTE_NAME cleaned and closed"
fi
exit "$RC"
