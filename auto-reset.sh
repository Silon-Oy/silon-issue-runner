#!/usr/bin/env bash
# auto-reset.sh — label-driven teardown of a /run-issues issue's LOCAL temporary
# resources, leaving the ISSUE OPEN so normal pickup starts it over (issue #202).
#
# Triggered by the poller when an issue carries the `auto-reset` label
# (RUN_ISSUES_RESET_LABEL). It runs exactly the teardown auto-clean.sh runs — the
# same lock, the same run-dir inventory, the same completed-run PR gate, the same
# cleanup-run.sh delegation — and then STOPS: no `gh issue close`.
#
# WHY A SECOND VERB. A stuck or wrong-output run has to be resettable with one
# label. auto-clean is a FINISHING verb: it closes the issue, so re-running the
# work afterwards meant three manual steps (clean, reopen, restore labels). This
# is the RE-RUN verb. Because cleanup-run.sh already drops the assignment and the
# `auto-claimed` / `needs-human` labels, removing `auto-reset` last leaves the
# issue in exactly the state pickup wants: open, unclaimed, unlabelled. The
# poller starts a fresh run from the current base on a later tick.
#
# It does NOT start a run itself, and it never changes the issue's open/closed
# state in either direction — a closed issue is not reopened.
#
# Every safety gate lives in lib/teardown.sh, shared with auto-clean.sh. The two
# verbs differ in five values only: trigger label, skipped label, whether the
# issue is closed, whether the remote branch is deleted, and the comment wording
# below. Copying the gates per verb would put the safety-critical part of the
# system in two places, where the second copy drifts silently.
#
# WHY THE REMOTE BRANCH TOO (issue #329). The fresh run gets the same branch name
# as the old one. If a closed PR's branch is still on GitHub, the new run's push
# is rejected as non-fast-forward and every further reset fails the same way. So
# the reset deletes the remote branch when all its PRs are MERGED/CLOSED (or it
# has none and is runner-owned, `auto-run/…`), and refuses (exit 4) while the
# branch has an OPEN PR — deleting that would close a live PR.
#
# Usage:
#   auto-reset.sh --repo <repo-root> --issue <N> [--remote <name>] [--dry-run]
#
# Exit codes:
#   0  torn down, issue NOT closed, auto-reset label removed — an OPEN issue is
#      back in pickup (a closed one is not reopened; see the note above)
#   1  usage error
#   3  per-issue lock held by another run — safe to retry on a later tick
#   4  a completed run has an OPEN (or unresolvable) PR, or a run's branch has
#      an OPEN PR or its PRs could not be read — labelled auto-reset-skipped.
#      Resetting would produce a SECOND PR for the same issue (or replay the
#      push rejection on the open PR's branch), so a human closes the PR first.
#      A completed run whose PR is already MERGED/CLOSED is torn down normally.
#   5  no local run-dirs for this issue (likely cross-machine) — machine-agnostic
#      cleanup hint posted
#   6  cleanup-run.sh teardown failed
#
# Loop guard: on the non-resettable terminal cases (4 and 5) we add the
# `auto-reset-skipped` label so the poller's reset scan stops re-emitting the
# issue. Its own label, not auto-clean's: the two teardown verbs must never read
# each other's state.
#
# Multi-remote (issue #53): --remote scopes the teardown to a specific git
# remote so multi-org clones do not cross issues with the same number across
# orgs. Default "origin" preserves legacy behaviour.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Windows/Git Bash: give `jq` its --binary flag so its output is LF, not CRLF.
# Sourced before any other library because they all read jq output (lib/jq-binary.sh).
# shellcheck source=lib/jq-binary.sh
. "$SCRIPT_DIR/lib/jq-binary.sh"

RUN_ISSUES_RESET_LABEL="${RUN_ISSUES_RESET_LABEL:-auto-reset}"
SKIPPED_LABEL="auto-reset-skipped"

# ---------- argument parsing ----------
REPO_ROOT=""
ISSUE_NUM=""
REMOTE_NAME="origin"
DRY_RUN=0

usage() {
  cat >&2 <<'USAGE'
auto-reset.sh --repo <repo-root> --issue <N> [--remote <name>] [--dry-run]
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
    *)         echo "auto-reset: unexpected argument '$1'" >&2; usage 1 ;;
  esac
done

[ -n "$REPO_ROOT" ] || { echo "auto-reset: --repo is required" >&2; usage 1; }
[ -n "$ISSUE_NUM" ] || { echo "auto-reset: --issue is required" >&2; usage 1; }
[ -n "$REMOTE_NAME" ] || REMOTE_NAME="origin"
[ -d "$REPO_ROOT/.git" ] || { echo "auto-reset: not a git repo: $REPO_ROOT" >&2; exit 1; }

# ---------- libs ----------
# Same set as auto-clean.sh, and for the same reasons: locking.sh for the
# per-issue lock, issue.sh for comment_issue, git-remote.sh for gh routing,
# labels.sh for REST label writes, teardown.sh for the shared gates.
# shellcheck source=lib/git-remote.sh
. "$SCRIPT_DIR/lib/git-remote.sh"
# shellcheck source=lib/locking.sh
. "$SCRIPT_DIR/lib/locking.sh"
# shellcheck source=lib/issue.sh
. "$SCRIPT_DIR/lib/issue.sh"
# shellcheck source=lib/labels.sh
. "$SCRIPT_DIR/lib/labels.sh"
# shellcheck source=lib/teardown.sh
. "$SCRIPT_DIR/lib/teardown.sh"

OWNER_REPO=""
case "$REMOTE_NAME" in
  ""|origin) : ;;
  *)
    if ! OWNER_REPO=$(resolve_remote_to_owner_repo "$REPO_ROOT" "$REMOTE_NAME" 2>/dev/null); then
      echo "auto-reset: remote '$REMOTE_NAME' not found in $REPO_ROOT or URL un-parseable" >&2
      exit 1
    fi
    ;;
esac

REPO_SLUG=$(repo_slug "$REPO_ROOT" "$REMOTE_NAME")

# ---------- the five values that make this verb auto-reset ----------
TEARDOWN_VERB="auto-reset"
TEARDOWN_TRIGGER_LABEL="$RUN_ISSUES_RESET_LABEL"
TEARDOWN_SKIPPED_LABEL="$SKIPPED_LABEL"
TEARDOWN_CLOSE_ISSUE=0
TEARDOWN_DELETE_REMOTE_BRANCH=1
TEARDOWN_CLEANUP="$SCRIPT_DIR/cleanup-run.sh"

teardown_comment_no_rundirs() {
  # Names no machine on purpose: this branch runs precisely because there is no
  # run.json here to read a host from, so any machine name would be a guess
  # dressed up as instruction.
  cat <<EOF
## auto-reset: ei paikallisia ajoresursseja

Tällä koneella (\`$TD_HOST\`) ei löytynyt issueen #$TD_ISSUE liittyviä run-direjä (remote \`$TD_REMOTE\`). Resurssit ovat todennäköisesti toisella koneella.

Aja purku sillä koneella, jolla ajo tehtiin (ota siihen tarvittaessa ensin yhteys):

\`\`\`bash
~/.claude/scripts/run-issues/cleanup-run.sh --issue $TD_ISSUE --force --yes
\`\`\`

Issueta ei suljettu. Issueen on lisätty label \`$TEARDOWN_SKIPPED_LABEL\` jotta auto-reset ei poimi sitä uudelleen.
EOF
}

teardown_comment_open_pr() {
  local what
  if [ -n "${TD_BRANCH_BLOCKING:-}" ]; then
    what="Issuen #$TD_ISSUE ajon haaralla (\`$TD_BRANCH_BLOCKING\`) on avoin PR, tai haaran PR:ien tilaa ei saatu selvitettyä — ei purettu. Nollaus vapauttaisi issuen poimintaan, ja uuden ajon push samannimiseen haaraan hylättäisiin; haaraa ei poisteta, koska se sulkisi avoimen PR:n."
  else
    what="Issuella #$TD_ISSUE on completed-ajo(ja) ($TD_BLOCKING/$TD_COMPLETED), joiden PR on yhä avoin tai sen tilaa ei saatu selvitettyä — ei purettu. Nollaus vapauttaisi issuen poimintaan ja tuottaisi sille toisen PR:n saman työn päälle."
  fi
  cat <<EOF
## auto-reset: avoin PR läsnä

$what

Sulje (tai mergeä) PR ensin, ja lisää \`auto-reset\`-label uudelleen. Voit myös ajaa purun käsin:

\`\`\`bash
~/.claude/scripts/run-issues/cleanup-run.sh --issue $TD_ISSUE --force
\`\`\`

Issueen on lisätty label \`$TEARDOWN_SKIPPED_LABEL\` jotta auto-reset ei poimi sitä uudelleen.
EOF
}

teardown_comment_success() {
  local completed_note=""
  [ "$TD_COMPLETED" -gt 0 ] && completed_note=" (näistä $TD_COMPLETED completed-tilassa; PR mergetty/suljettu)"
  # One line per remote branch the teardown acted on ("<branch>|<outcome>|<reason>",
  # lib/teardown.sh). A branch that was already gone produces no line.
  local remote_note="" b outcome why text
  while IFS='|' read -r b outcome why; do
    [ -n "$b" ] || continue
    case "$why" in
      "no PR, runner-owned") why="haaralla ei ollut PR:ää ja se on runnerin oma" ;;
      *) why="haaran kaikki PR:t on suljettu tai mergetty" ;;
    esac
    case "$outcome" in
      deleted) text="poistettu ($why)" ;;
      failed)  text="poisto epäonnistui — poista haara käsin, muuten uuden ajon push hylätään" ;;
      *)       text="remotea ei saatu luettua — tarkista ja poista haara tarvittaessa käsin" ;;
    esac
    remote_note="$remote_note
- Remote-haara \`$b\`: $text"
  done <<<"${TD_REMOTE_BRANCHES:-}"
  cat <<EOF
## auto-reset: ajo nollattu

Issueen #$TD_ISSUE liittyvät paikalliset väliaikaisresurssit on purettu koneella \`$TD_HOST\` (remote \`$TD_REMOTE\`):

- Puretut run-dirit: $TD_TOTAL$completed_note
- Worktree ja paikallinen branch poistettu$remote_note
- DB-klooni dropattu (jos käytössä, best-effort)
- Varaus purettu: assignaatio sekä \`auto-claimed\`- ja \`needs-human\`-labelit poistettu
- **Issueta ei suljettu** — nollaus ei kosketa issuen auki/kiinni-tilaa kumpaankaan suuntaan

Jos issue on auki, se täyttää nyt poimintaehdot ja poller aloittaa ajon alusta puhtaasta basesta seuraavalla tikillä; voit myös käynnistää sen heti komennolla \`/run-issues #$TD_ISSUE\`. Suljettua issueta nollaus ei avaa — avaa se itse, jos haluat ajon alkavan uudelleen.

Olennaiset artefaktit on arkistoitu hakemistoon \`.claude/run-issues-archive/\`.
EOF
}

# ---------- run ----------
set +e
teardown_run "$REPO_ROOT" "$ISSUE_NUM" "$REMOTE_NAME" "$OWNER_REPO" "$REPO_SLUG" "$DRY_RUN"
RC=$?
set -e

if [ "$RC" -eq 0 ]; then
  teardown_log "done: issue #$ISSUE_NUM remote=$REMOTE_NAME reset — issue left open, back in pickup"
fi
exit "$RC"
