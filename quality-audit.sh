#!/usr/bin/env bash
# quality-audit.sh — whole-repository quality audit; findings become issues
# (issue #395).
#
# The security audit (#339) looks for vulnerabilities and the coherence audit
# (#342) for what parallel runs built twice. Neither looks for the faults that
# made up most of a measured whole-repo review: writes that are not idempotent,
# a rule enforced two different ways, a deny-list that lets every new field
# through, a background job with no end state, a test that skips itself
# silently. This audits the repository as it stands on its remote's default
# branch:
#
#   1. one agent pass over the whole repo (prompts/14-quality-audit.md) in seven
#      classes, with the merge gate's result format and severity scale
#      (lib/merge-gate.sh)
#   2. every finding → one issue with the `quality` label and a fingerprint
#      marker (lib/finding-issues.sh): an open issue is not duplicated, a
#      completed one is reopened only when the finding recurs, one closed as
#      not planned is never reopened
#   3. findings at or above the auto-run threshold get this machine's pickup
#      labels (poller_pick_labels) and the routed assignee, as in the security
#      audit — but the threshold defaults to `none`: a quality fix is a human's
#      choice unless the machine or the repo opts in.
#
# The audit never changes code. The skeleton (detached worktree, read-only
# gate, "not a result", refutation pass, finding loop) is lib/repo-audit.sh;
# this file holds what is the quality audit's own: the prompt, the auto-run
# default and the issue text. No scanners and no change cursor: quality is a
# property of the whole repo, not of what was merged recently.
#
# Usage:
#   quality-audit.sh <repo> [--remote <name>] [--dry-run] [--watchlist <path>] [--group [--write]]
#
#   <repo>             a local clone of the audited repository
#   --remote <name>    the remote to audit and to file issues in (default origin)
#   --dry-run          print the findings and the planned action per finding
#                      (create / exists / reopen / dismissed); no GitHub write
#   --group            group the new confirmed findings into fix-sized issues and
#                      those into epics by severity (prompts/15-finding-group.md,
#                      lib/repo-audit.sh); alone it prints the plan (markdown and
#                      a JSON file) and writes nothing, like --dry-run
#   --write            with --group: write the plan — epic, children, sub-issue
#                      links, dependencies (lib/epic-write.sh). No pickup label
#                      and no assignee on anything; a finding that already has an
#                      issue, or an unsure one, keeps its single-finding issue
#   --watchlist <path> where the pickup labels come from (poller semantics: the
#                      ONLY candidate). A repo the watchlist does not list gets
#                      the built-in default pickup label. Its `assignees` key
#                      routes the auto-run issues to the first allowed login.
#
# Output (stdout): one line per finding — action, severity, location, text —
# then a summary line. Diagnostics go to stderr.
#
# Exit codes (own space; 0-4 mean what they mean in security-audit.sh, its
# scanner codes 5-7 do not exist here because this audit runs no scanner):
#   0  audit done, issues written (also: no findings); or --dry-run done
#   1  usage error (also --write without --group, or with --dry-run)
#   2  repo, remote or its default branch does not resolve, or git/jq/gh is missing
#   3  the audit did not happen: agent launch failure, empty or unparseable result, or the worktree changed; with --group also a failed grouping agent or a rejected plan — nothing written
#   4  GitHub read or write failed — issues may be partially written
#
# Env:
#   RUN_ISSUES_QUALITY_AUDIT_AUTO_RUN_MIN_SEVERITY  mildest severity whose issue
#        gets the pickup labels: critical|high|medium|low|none (default none).
#        Read from the environment, else from poller.env (RUN_ISSUES_POLLER_ENV_FILE,
#        default $HOME/.config/run-issues/poller.env). The repo's
#        `.quality.audit_auto_run_min_severity` in .claude/run-issues.json
#        (default branch) wins. Unknown => none.
#   RUN_ISSUES_QUALITY_AUDIT_INTERVAL_DAYS  the poller's schedule (lib/audit-schedule.sh);
#        the watchlist entry's `quality_audit_interval_days` wins over it and the
#        repo's `.quality.audit_interval_days` over both. Unset => not scheduled.
#   RUN_ISSUES_QUALITY_AUDIT_TIMEOUT        agent call time cap in seconds (default 3600)
#   RUN_ISSUES_QUALITY_AUDIT_FETCH_TIMEOUT  git fetch time cap (default 300)
#   RUN_ISSUES_WATCHLIST                    watchlist override (poller semantics)
#   RUN_ISSUES_AUDIT_VERIFY                 1 = every agent finding is first checked by
#        a verifier agent that tries to refute it (prompts/13-finding-verify.md):
#        refuted ones are dropped, unsure ones filed without pickup labels or
#        assignee (default 0; the poller sets 1)
#   RUN_ISSUES_AUDIT_VERIFY_TIMEOUT         time cap per verifier call in seconds (default 600)
#   RUN_ISSUES_AUDIT_GROUP_TIMEOUT          time cap of the grouping agent (--group) in seconds (default 1800)
#   RUN_ISSUES_CLAUDE_CMD and the rest of lib/claude-call.sh's settings. The
#   machine env file is sourced like orchestrate.sh does (lib/machine-env.sh,
#   caller wins in RUN_ISSUES_*).

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

AUDIT_KIND="quality"
# The label every quality issue carries — also the finding kind in the marker.
QUALITY_AUDIT_LABEL="quality"
AUDIT_STEP="14-quality-audit"
# The machine default of the auto-run threshold. Not finding_issues_auto_run_min's
# own default (`high`, the security audit's): a quality finding starts no run
# unless someone opts in.
QUALITY_AUTO_RUN_DEFAULT="none"

REPO_AUDIT_NAME="quality-audit"

die_usage() { printf 'quality-audit.sh: %s\n' "$1" >&2; exit 1; }

REPO=""
REMOTE="origin"
DRY_RUN=0
GROUP=0
GROUP_WRITE=0
WATCHLIST_OVERRIDE="${RUN_ISSUES_WATCHLIST:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --remote)    shift; [ "$#" -gt 0 ] || die_usage "--remote needs a value"; REMOTE="$1" ;;
    --dry-run)   DRY_RUN=1 ;;
    --group)     GROUP=1 ;;
    --write)     GROUP_WRITE=1 ;;
    --watchlist) shift; [ "$#" -gt 0 ] || die_usage "--watchlist needs a value"; WATCHLIST_OVERRIDE="$1" ;;
    -h|--help)   sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)          die_usage "unknown argument: $1" ;;
    *)           [ -z "$REPO" ] || die_usage "only one <repo> may be given"; REPO="$1" ;;
  esac
  shift
done
[ -n "$REPO" ] || die_usage "usage: quality-audit.sh <repo> [--remote <name>] [--dry-run] [--watchlist <path>] [--group [--write]]"
[ "$GROUP_WRITE" = 0 ] || [ "$GROUP" = 1 ] || die_usage "--write needs --group"
[ "$GROUP_WRITE" = 0 ] || [ "$DRY_RUN" = 0 ] || die_usage "--write and --dry-run contradict each other"
# The grouping plan alone writes nothing: it is a dry run in every other respect.
[ "$GROUP" = 1 ] && [ "$GROUP_WRITE" = 0 ] && DRY_RUN=1

# Libraries. claude-call.sh (via repo-audit.sh) carries `set -e`; this script
# does not (every failure below is an explicit exit code), so it is switched
# off again after sourcing.
source_machine_env
# shellcheck source=lib/repo-audit.sh
. "$SCRIPT_DIR/lib/repo-audit.sh"
# shellcheck source=lib/poller-config.sh
. "$SCRIPT_DIR/lib/poller-config.sh"
# shellcheck source=lib/issue.sh
. "$SCRIPT_DIR/lib/issue.sh"
set +e

say() { repo_audit_say "$@"; }

repo_audit_require_tools || exit $?
repo_audit_set_repo "$REPO" || exit $?

# The machine's auto-run threshold: the environment (caller or the machine env
# file) first, then poller.env, then this kind's own default — never empty, so
# finding_issues_auto_run_min's `high` cannot apply.
AUTO_RUN_MACHINE="${RUN_ISSUES_QUALITY_AUDIT_AUTO_RUN_MIN_SEVERITY:-$(repo_audit_poller_env_value RUN_ISSUES_QUALITY_AUDIT_AUTO_RUN_MIN_SEVERITY)}"
AUTO_RUN_MACHINE="${AUTO_RUN_MACHINE:-$QUALITY_AUTO_RUN_DEFAULT}"
AUDIT_TIMEOUT="${RUN_ISSUES_QUALITY_AUDIT_TIMEOUT:-3600}"
FETCH_TIMEOUT="${RUN_ISSUES_QUALITY_AUDIT_FETCH_TIMEOUT:-300}"

repo_audit_resolve "$FETCH_TIMEOUT" || exit $?

# ---- work area: a temporary detached worktree of the default branch ----------
repo_audit_worktree || exit $?

# ---- policy: repo (default branch) > machine > default ----------------------
CFG=$(git -C "$REPO" show "$HEAD_SHA:.claude/run-issues.json" 2>/dev/null || true)
AUTO_RUN_MIN=$(finding_issues_auto_run_min "$CFG" "$AUDIT_KIND" "$AUTO_RUN_MACHINE")
WATCHLIST=$(poller_resolve_watchlist "$WATCHLIST_OVERRIDE" \
  "$HOME/.config/run-issues/watchlist.json" \
  "$HOME/dotfiles/machine-studio/run-issues-watchlist.json") || WATCHLIST=""
PICK_LABELS=$(poller_watchlist_pick_labels "$WATCHLIST" "$REPO") \
  || say "$REPO is not in a watchlist — using the default pickup labels ($PICK_LABELS)"
# The assignee axis of pickup (#238), resolved as in security-audit.sh.
PICK_ASSIGNEES=$(poller_watchlist_pick_assignees "$WATCHLIST" "$REPO")
ROUTE_ASSIGNEE=$(pick_assignee_route "$PICK_ASSIGNEES")
say "auditing $OWNER_REPO at $BASE_REF ($HEAD_SHA); auto-run threshold '$AUTO_RUN_MIN', pickup labels '$PICK_LABELS'${PICK_ASSIGNEES:+, assignees '$PICK_ASSIGNEES' → '${ROUTE_ASSIGNEE:-(none)}'}"

# ---- launch check, known findings ---------------------------------------------
repo_audit_preflight || exit $?
repo_audit_index "$QUALITY_AUDIT_LABEL" || exit $?

# ---- the agent ----------------------------------------------------------------
PROMPT="$WORK/$AUDIT_STEP.prompt"
render_prompt "$SCRIPT_DIR/prompts/$AUDIT_STEP.md" "$PROMPT" \
  REPO="$OWNER_REPO" HEAD_SHA="$HEAD_SHA" REMOTE="$REMOTE" BASE_REF="$BASE_BRANCH" \
  KNOWN_FINDINGS="$KNOWN"
repo_audit_agent "$AUDIT_STEP" "$PROMPT" "$AUDIT_TIMEOUT" || exit $?

FINDINGS=""
[ "$RESULT" = "findings" ] && FINDINGS=$(merge_gate_findings "$WORK/$AUDIT_STEP.out" | sed 's/^/agent|/' | awk 'NF && !seen[$0]++')

# The refutation pass (opt-in, lib/repo-audit.sh).
repo_audit_verify "$AUDIT_KIND" || exit $?

# ---- one finding → fingerprint, title, body -----------------------------------

# _quality_class <description> — the [class] tag the prompt puts first, or
# nothing.
_quality_class() {
  printf '%s' "$1" | sed -nE 's/^\[([A-Za-z0-9_-]+)\].*/\1/p'
}

# _quality_key <origin> <description> — "agent\t<class>". The class alone is
# enough: finding_fingerprint keys on the location's file too, so two findings
# of one class in different files stay two issues, and only one class in one
# file merges (one issue per file and class is the intended granularity).
# Without a tag the whole text keys the finding: unstable, so the worst case is
# a duplicate issue, never two findings merged into one.
_quality_key() {
  local key
  key=$(_quality_class "$2")
  printf 'agent\t%s' "${key:-$2}"
}

# _quality_labels <severity> — the quality label, plus the pickup labels when
# the severity reaches the auto-run threshold (default none: never).
_quality_labels() {
  if finding_issues_auto_runs "$AUTO_RUN_MIN" "$1"; then
    printf '%s,%s' "$QUALITY_AUDIT_LABEL" "$PICK_LABELS"
  else
    printf '%s' "$QUALITY_AUDIT_LABEL"
  fi
}

# _quality_assignee <severity> — the routed assignee, on the same condition as
# the pickup labels.
_quality_assignee() {
  finding_issues_auto_runs "$AUTO_RUN_MIN" "$1" && printf '%s' "$ROUTE_ASSIGNEE"
  return 0
}

_quality_title() {
  local sev="$1" loc="$2" desc="$3" short file
  file=$(finding_location_file "$loc")
  short=$(printf '%s' "$desc" | cut -c1-90)
  [ "${#desc}" -gt 90 ] && short="$short…"
  printf 'Laatu (%s): %s%s' "$sev" "$short" "${file:+ — $file}"
}

# _quality_class_name <class> — the class as the issue body names it.
_quality_class_name() {
  case "$1" in
    data-integrity)   printf 'datan eheys (`data-integrity`)' ;;
    rule-consistency) printf 'sääntöjen johdonmukaisuus (`rule-consistency`)' ;;
    default-allow)    printf 'oletuksena salliva rajaus (`default-allow`)' ;;
    resilience)       printf 'sietokyky (`resilience`)' ;;
    test-reliability) printf 'testien luotettavuus (`test-reliability`)' ;;
    maintainability)  printf 'ylläpidettävyys (`maintainability`)' ;;
    accessibility)    printf 'saavutettavuus (`accessibility`)' ;;
    '')               printf 'ei luokiteltu' ;;
    *)                printf '`%s`' "$1" ;;
  esac
}

_quality_body() {
  local sev="$1" conf="$2" loc="$3" desc="$4" fp="$6"
  cat <<EOF
## Tavoite

Korjaa koko repon laatuauditoinnin (\`quality-audit.sh\`) löytämä laatuvika.

- **Luokka:** $(_quality_class_name "$(_quality_class "$desc")")
- **Vakavuus:** $sev
- **Varmuus:** $conf
- **Sijainti:** \`$loc\`
- **Kuvaus:** $desc

Auditoitu commit: \`$HEAD_SHA\` (\`$BASE_REF\`).

## Hyväksyntäkriteerit

- [ ] Kuvattu ongelma on korjattu sijainnissa \`$loc\`, eikä sama vika toistu saman tiedoston muissa kohdissa.
- [ ] Korjaukselle on testi, jos projektissa on testejä.

## Rajaukset

- Vain tämä yksi löydös. Auditoinnin muut löydökset ovat omia issueitaan.
- Jos löydös osoittautuu vääräksi, älä muuta koodia: kirjaa perustelu ja pysähdy. Ihminen sulkee issuen tilaan *not planned*, jolloin auditointi ei avaa sitä uudelleen.

$(finding_marker "$AUDIT_KIND" "$fp")
EOF
}

# ---- apply --------------------------------------------------------------------
REOPEN_COMMENT="Löydös toistui koko repon laatuauditoinnissa (\`quality-audit.sh\`, commit \`$HEAD_SHA\`), joten issue avattiin uudelleen."
if [ "$GROUP" = 1 ]; then
  repo_audit_group "$AUDIT_KIND" "$GROUP_WRITE" "Laatu" "$REOPEN_COMMENT" \
    _quality_key _quality_labels _quality_title _quality_body || exit $?
else
  repo_audit_apply "$AUDIT_KIND" "$DRY_RUN" "$REOPEN_COMMENT" \
    _quality_key _quality_labels _quality_title _quality_body _quality_assignee <<EOF
$FINDINGS
EOF
fi

printf 'quality-audit: %s finding(s)%s%s\n' "$REPO_AUDIT_FINDINGS" \
  "$([ "$DRY_RUN" = 1 ] && echo ' (dry run: nothing written)')" \
  "$([ "$REPO_AUDIT_WRITE_FAILED" -gt 0 ] && echo "; $REPO_AUDIT_WRITE_FAILED GitHub write(s) failed")"

[ "$REPO_AUDIT_WRITE_FAILED" -gt 0 ] && exit 4
exit 0
