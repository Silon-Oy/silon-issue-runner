#!/usr/bin/env bash
# coherence-audit.sh — review the runner's recently merged PRs TOGETHER; findings
# become refactoring issues (issue #342).
#
# The runner works issues in parallel and every run sees only its own change.
# Two runs can build the same thing twice, add an abstraction next to an
# existing one, or settle on conflicting conventions. The merge gate cannot see
# it (it compares one PR's diff, at most against one other PR), and it never
# sees a PR a human merged by hand. This audit looks at what reached the default
# branch since the last coherence audit, as a whole:
#
#   1. the review set: every merged PR of the runner (head branch `auto-run/`)
#      whose merged_at is after this audit's cursor — regardless of epic
#   2. their combined change surface (lib/pr-surface.sh, shared with the epic
#      review)
#   3. one agent pass over the repo at <remote>/<default-branch>
#      (prompts/09-coherence-audit.md), with the merge gate's result format
#   4. every finding → one issue with the `coherence` label and a fingerprint
#      marker (lib/finding-issues.sh). NEVER pickup labels: whether and when to
#      refactor is a human's choice.
#
# The skeleton (detached worktree, read-only gate, "not a result", finding
# loop) is the security audit's (lib/repo-audit.sh). The audit never changes
# code.
#
# THE CURSOR is this audit's own: $RUN_ISSUES_LOG_DIR/.audit-coherence-cursor-<slug>
# holds the merged_at of the newest PR a SUCCESSFUL audit reviewed, and moves
# only on exit 0 (never on --dry-run). The poller's schedule file cannot serve:
# it records when an audit STARTED, so a failed audit would silently drop its
# PRs from review. Without a cursor the window is the audit interval (repo
# `.coherence.audit_interval_days` > RUN_ISSUES_COHERENCE_AUDIT_INTERVAL_DAYS >
# 7 days) back from now.
#
# No new PRs => exit 0 BEFORE any worktree or agent call.
#
# Usage:
#   coherence-audit.sh <repo> [--remote <name>] [--dry-run] [--watchlist <path>]
#
#   <repo>             a local clone of the audited repository
#   --remote <name>    the remote to audit and to file issues in (default origin)
#   --dry-run          print the findings and the planned action per finding
#                      (create / exists / reopen / dismissed); no GitHub write,
#                      the cursor does not move
#   --watchlist <path> accepted so the poller can call every audit kind alike;
#                      unused — coherence issues never get pickup labels
#
# Output (stdout): the review set, one line per finding — action, severity,
# location, text — then a summary line. Diagnostics go to stderr.
#
# Exit codes (own space):
#   0  audit done, issues written (also: no findings, or no new PRs); or --dry-run done
#   1  usage error
#   2  repo, remote or its default branch does not resolve, or git/jq/gh is missing
#   3  the audit did not happen: agent launch failure, empty or unparseable result, or the worktree changed — nothing written
#   4  GitHub read or write failed (PR set, change surface, issue index or an issue write) — issues may be partially written
#
# Env:
#   RUN_ISSUES_COHERENCE_AUDIT_INTERVAL_DAYS  the first window when no cursor
#        exists (and the poller's schedule). Read from the environment, else from
#        poller.env; the repo's `.coherence.audit_interval_days` wins. Default 7.
#   RUN_ISSUES_COHERENCE_AUDIT_TIMEOUT        agent call time cap in seconds (default 3600)
#   RUN_ISSUES_COHERENCE_AUDIT_FETCH_TIMEOUT  git fetch time cap (default 300)
#   RUN_ISSUES_COHERENCE_AUDIT_MAX            change-surface size cap in the prompt,
#        bytes (default 60000); a cut is named in the material itself
#   RUN_ISSUES_LOG_DIR                        where the cursor lives
#   RUN_ISSUES_CLAUDE_CMD and the rest of lib/claude-call.sh's settings. The
#   machine env file is sourced like orchestrate.sh does (lib/machine-env.sh).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Snapshot the caller's environment before any library assigns defaults
# (lib/machine-env.sh, CLAUDE.md §5.5).
# shellcheck source=lib/machine-env.sh
. "$SCRIPT_DIR/lib/machine-env.sh"
machine_env_capture
# Windows/Git Bash: LF jq output (lib/jq-binary.sh).
# shellcheck source=lib/jq-binary.sh
. "$SCRIPT_DIR/lib/jq-binary.sh"

AUDIT_KIND="coherence"
# The label every coherence issue carries — also the finding kind in the marker.
COHERENCE_AUDIT_LABEL="coherence"
AUDIT_STEP="09-coherence-audit"
RUNNER_BRANCH_PREFIX="auto-run/"
DEFAULT_WINDOW_DAYS=7

REPO_AUDIT_NAME="coherence-audit"

die_usage() { printf 'coherence-audit.sh: %s\n' "$1" >&2; exit 1; }

REPO=""
REMOTE="origin"
DRY_RUN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --remote)    shift; [ "$#" -gt 0 ] || die_usage "--remote needs a value"; REMOTE="$1" ;;
    --dry-run)   DRY_RUN=1 ;;
    --watchlist) shift; [ "$#" -gt 0 ] || die_usage "--watchlist needs a value" ;;
    -h|--help)   sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)          die_usage "unknown argument: $1" ;;
    *)           [ -z "$REPO" ] || die_usage "only one <repo> may be given"; REPO="$1" ;;
  esac
  shift
done
[ -n "$REPO" ] || die_usage "usage: coherence-audit.sh <repo> [--remote <name>] [--dry-run] [--watchlist <path>]"

# Libraries. claude-call.sh (via repo-audit.sh) carries `set -e`; this script
# does not (every failure below is an explicit exit code), so it is switched
# off again after sourcing.
source_machine_env
# shellcheck source=lib/repo-audit.sh
. "$SCRIPT_DIR/lib/repo-audit.sh"
# shellcheck source=lib/pr-surface.sh
. "$SCRIPT_DIR/lib/pr-surface.sh"
# shellcheck source=lib/audit-schedule.sh
. "$SCRIPT_DIR/lib/audit-schedule.sh"
# shellcheck source=lib/paths.sh
. "$SCRIPT_DIR/lib/paths.sh"
set +e

say() { repo_audit_say "$@"; }

repo_audit_require_tools || exit $?
repo_audit_set_repo "$REPO" || exit $?

AUDIT_TIMEOUT="${RUN_ISSUES_COHERENCE_AUDIT_TIMEOUT:-3600}"
FETCH_TIMEOUT="${RUN_ISSUES_COHERENCE_AUDIT_FETCH_TIMEOUT:-300}"
SURFACE_MAX="${RUN_ISSUES_COHERENCE_AUDIT_MAX:-60000}"
case "$SURFACE_MAX" in ''|*[!0-9]*) SURFACE_MAX=60000 ;; esac
INTERVAL_MACHINE="${RUN_ISSUES_COHERENCE_AUDIT_INTERVAL_DAYS:-$(repo_audit_poller_env_value RUN_ISSUES_COHERENCE_AUDIT_INTERVAL_DAYS)}"
LOG_DIR="${RUN_ISSUES_LOG_DIR:-$(default_log_dir)}"

repo_audit_resolve "$FETCH_TIMEOUT" || exit $?

# ---- the cursor ---------------------------------------------------------------
CURSOR_FILE="$LOG_DIR/.audit-coherence-cursor-$(repo_slug "$REPO" "$REMOTE")"
CURSOR_EPOCH=$(deadline_file_read "$CURSOR_FILE")
CURSOR_EPOCH="${CURSOR_EPOCH%% *}"
NOW=$(date +%s)
if [ "$CURSOR_EPOCH" -gt 0 ] && [ "$CURSOR_EPOCH" -le "$NOW" ]; then
  SINCE_EPOCH="$CURSOR_EPOCH"
  SINCE_FROM="cursor"
else
  CFG=$(git -C "$REPO" show "$HEAD_SHA:.claude/run-issues.json" 2>/dev/null || true)
  DAYS=$(audit_interval_days "$CFG" "$AUDIT_KIND" "$INTERVAL_MACHINE")
  DAYS="${DAYS:-$DEFAULT_WINDOW_DAYS}"
  SINCE_EPOCH=$((NOW - DAYS * 86400))
  SINCE_FROM="no cursor: last ${DAYS} day(s)"
fi
SINCE=$(jq -rn --argjson e "$SINCE_EPOCH" '$e | todate')

# ---- the review set -------------------------------------------------------------

# _coherence_merged_prs <since-iso> — the runner's PRs into BASE_BRANCH merged
# after <since-iso>, one TSV row each: number, merged_at, head branch, title.
# REST, not search (CLAUDE.md §5.2). Sorted by update time, newest first, and
# paged by hand: merging updates a PR, so once a page reaches PRs last updated
# before <since-iso> no later page can hold a newer merge — the cost is the
# work since the cursor, not the repo's PR history (§5.4). rc 1 on any read
# failure.
_coherence_merged_prs() {
  local since="$1" base page=1 raw rows n oldest
  base=$(jq -rn --arg s "$BASE_BRANCH" '$s|@uri') || return 1
  while :; do
    raw=$(labels_gh api "repos/$OWNER_REPO/pulls?state=closed&base=$base&sort=updated&direction=desc&per_page=100&page=$page" 2>/dev/null) || return 1
    rows=$(jq -r --arg s "$since" --arg p "$RUNNER_BRANCH_PREFIX" '
      .[] | select(.merged_at != null and .merged_at > $s
                   and ((.head.ref // "") | startswith($p)))
      | [(.number | tostring), .merged_at, .head.ref, ((.title // "") | gsub("[\t\r\n]"; " "))]
      | @tsv' <<<"$raw" 2>/dev/null) || return 1
    [ -n "$rows" ] && printf '%s\n' "$rows"
    n=$(jq -r 'length' <<<"$raw" 2>/dev/null) || return 1
    [ "$n" -lt 100 ] && return 0
    oldest=$(jq -r '[.[].updated_at] | min // ""' <<<"$raw" 2>/dev/null) || return 1
    [[ "$oldest" < "$since" ]] && return 0
    page=$((page + 1))
  done
}

if ! PRS=$(_coherence_merged_prs "$SINCE"); then
  say "listing the merged PRs of $OWNER_REPO failed — nothing written"
  exit 4
fi
PRS=$(printf '%s\n' "$PRS" | awk -F'\t' 'NF && !seen[$1]++' | LC_ALL=C sort -t$'\t' -k2,2)
if [ -z "$PRS" ]; then
  say "no runner PRs merged into $BASE_BRANCH since $SINCE ($SINCE_FROM) — nothing to audit"
  printf 'coherence-audit: no new PRs since %s\n' "$SINCE"
  exit 0
fi
N_PRS=$(printf '%s\n' "$PRS" | wc -l | tr -d ' ')
NEWEST=$(printf '%s\n' "$PRS" | awk -F'\t' '$2 > m { m = $2 } END { print m }')
PR_LIST=$(printf '%s\n' "$PRS" | awk -F'\t' '{ printf "- #%s (%s, %s) %s\n", $1, $2, $3, $4 }')
printf 'review set: %s PR(s) merged since %s (%s)\n%s\n' "$N_PRS" "$SINCE" "$SINCE_FROM" "$PR_LIST"

# ---- the combined change surface ------------------------------------------------
if ! SURFACE=$(printf '%s\n' "$PRS" | awk -F'\t' -v r="$OWNER_REPO" '{ printf "%s\t%s\t#%s\n", r, $1, $1 }' | review_pr_surface); then
  say "reading the changed files of the review set failed — nothing written"
  exit 4
fi
[ -n "$SURFACE" ] || SURFACE="_Ei muuttuneita tiedostoja._"
if [ "$(printf '%s' "$SURFACE" | LC_ALL=C wc -c | tr -d ' ')" -gt "$SURFACE_MAX" ]; then
  TOTAL=$(printf '%s\n' "$SURFACE" | wc -l | tr -d ' ')
  SURFACE=$(printf '%s\n' "$SURFACE" | LC_ALL=C awk -v b="$SURFACE_MAX" '{ used += length($0) + 1; if (used > b) exit; print }')
  KEPT=0; [ -z "$SURFACE" ] || KEPT=$(printf '%s\n' "$SURFACE" | wc -l | tr -d ' ')
  SURFACE="${SURFACE:+$SURFACE
}
_Muutospinta katkaistu kokokattoon (RUN_ISSUES_COHERENCE_AUDIT_MAX=${SURFACE_MAX} tavua): näytetään ${KEPT}/${TOTAL} tiedostoa. Lue loput PR:ien merge-commiteista._"
fi

# ---- work area, launch check, known findings ------------------------------------
repo_audit_worktree || exit $?
say "auditing $OWNER_REPO at $BASE_REF ($HEAD_SHA): $N_PRS runner PR(s) merged since $SINCE"
repo_audit_preflight || exit $?
repo_audit_index "$COHERENCE_AUDIT_LABEL" || exit $?

# ---- the agent ----------------------------------------------------------------
PROMPT="$WORK/$AUDIT_STEP.prompt"
render_prompt "$SCRIPT_DIR/prompts/$AUDIT_STEP.md" "$PROMPT" \
  REPO="$OWNER_REPO" HEAD_SHA="$HEAD_SHA" REMOTE="$REMOTE" BASE_REF="$BASE_BRANCH" \
  SINCE="$SINCE" PR_LIST="$PR_LIST" CHANGE_SURFACE="$SURFACE" KNOWN_FINDINGS="$KNOWN"
repo_audit_agent "$AUDIT_STEP" "$PROMPT" "$AUDIT_TIMEOUT" || exit $?

FINDINGS=""
[ "$RESULT" = "findings" ] && FINDINGS=$(merge_gate_findings "$WORK/$AUDIT_STEP.out" | sed 's/^/agent|/' | awk 'NF && !seen[$0]++')

# ---- one finding → fingerprint, title, body -----------------------------------

# _coherence_key <origin> <description> — "agent\t<key>": the [category] slug
# the prompt asks for. Without one the whole text keys the finding: unstable,
# so the worst case is a duplicate issue, never two findings merged into one.
_coherence_key() {
  local key
  key=$(printf '%s' "$2" | sed -nE 's/^\[([A-Za-z0-9_-]+)\].*/\1/p')
  printf 'agent\t%s' "${key:-$2}"
}

# _coherence_labels <severity> — the coherence label and nothing else, at any
# severity: a refactoring is a human's choice, so no finding is picked up.
_coherence_labels() {
  printf '%s' "$COHERENCE_AUDIT_LABEL"
}

_coherence_title() {
  local sev="$1" loc="$2" desc="$3" short file
  file=$(finding_location_file "$loc")
  short=$(printf '%s' "$desc" | cut -c1-90)
  [ "${#desc}" -gt 90 ] && short="$short…"
  printf 'Koherenssi (%s): %s%s' "$sev" "$short" "${file:+ — $file}"
}

_coherence_body() {
  local sev="$1" conf="$2" loc="$3" desc="$4" fp="$6"
  cat <<EOF
## Tavoite

Yhtenäistä rinnakkaisten runner-ajojen tuottama epäkoherenssi, jonka koherenssiauditointi (\`coherence-audit.sh\`) löysi katselmoidessaan mainiin tulleet runnerin PR:t yhdessä.

- **Vakavuus:** $sev
- **Varmuus:** $conf
- **Sijainti:** \`$loc\`
- **Kuvaus:** $desc

Auditoitu commit: \`$HEAD_SHA\` (\`$BASE_REF\`). Katselmoidut PR:t (mergetty $SINCE jälkeen):

$PR_LIST

## Hyväksyntäkriteerit

- [ ] Kuvatulle asialle on yksi toteutus, yksi abstraktio tai yksi konventio, ja muut kutsupaikat käyttävät sitä.
- [ ] Käytös ei muutu: olemassa olevat testit pysyvät vihreinä, ja yhdistetylle polulle on testi, jos projektissa on testejä.

## Rajaukset

- Vain tämä yksi löydös. Auditoinnin muut löydökset ovat omia issueitaan.
- Refaktorointi on ihmisen valinta: issue ei saa poimintalabelia automaattisesti.
- Jos löydös osoittautuu vääräksi, älä muuta koodia: kirjaa perustelu ja pysähdy. Ihminen sulkee issuen tilaan *not planned*, jolloin auditointi ei avaa sitä uudelleen.

$(finding_marker "$AUDIT_KIND" "$fp")
EOF
}

# ---- apply --------------------------------------------------------------------
REOPEN_COMMENT="Löydös toistui koherenssiauditoinnissa (\`coherence-audit.sh\`, commit \`$HEAD_SHA\`), joten issue avattiin uudelleen."
repo_audit_apply "$AUDIT_KIND" "$DRY_RUN" "$REOPEN_COMMENT" \
  _coherence_key _coherence_labels _coherence_title _coherence_body <<EOF
$FINDINGS
EOF

printf 'coherence-audit: %s PR(s), %s finding(s)%s%s\n' "$N_PRS" "$REPO_AUDIT_FINDINGS" \
  "$([ "$DRY_RUN" = 1 ] && echo ' (dry run: nothing written)')" \
  "$([ "$REPO_AUDIT_WRITE_FAILED" -gt 0 ] && echo "; $REPO_AUDIT_WRITE_FAILED GitHub write(s) failed")"

[ "$REPO_AUDIT_WRITE_FAILED" -gt 0 ] && exit 4
[ "$DRY_RUN" = 1 ] && exit 0

# ---- advance the cursor: only now, after a complete audit -----------------------
# A cursor that cannot be written costs a repeated review of the same PRs, which
# the fingerprint dedup absorbs — not a lost one.
NEWEST_EPOCH=$(jq -rn --arg t "$NEWEST" '$t | fromdateiso8601' 2>/dev/null)
if [ -z "$NEWEST_EPOCH" ] || ! { mkdir -p "$LOG_DIR" 2>/dev/null && deadline_file_write "$CURSOR_FILE" "$NEWEST_EPOCH" "$AUDIT_KIND"; }; then
  say "cannot record the cursor in $CURSOR_FILE — the next audit reviews these PRs again"
fi
exit 0
