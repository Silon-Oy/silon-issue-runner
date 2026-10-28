#!/usr/bin/env bash
# security-audit.sh — whole-repository security audit; findings become issues
# (issue #339).
#
# The merge gate (pr-watch.sh, #334) reviews one PR's diff. Two things never
# show up in a diff: a new vulnerability in a dependency (it needs no commit at
# all) and a weakness assembled from several individually approved changes (an
# unauthenticated route nobody added on its own). This audits the repository as
# it stands on its remote's default branch:
#
#   1. the optional scanners in audit mode (lib/security-scan.sh)
#   2. one agent threat-model pass over the whole repo (prompts/08-security-audit.md),
#      with the merge gate's result format and severity scale (lib/merge-gate.sh)
#   3. every finding → one issue with the `security` label and a fingerprint
#      marker (lib/finding-issues.sh): an open issue is not duplicated, a
#      completed one is reopened only when the finding recurs, one closed as
#      not planned is never reopened
#   4. findings at or above the auto-run threshold get this machine's pickup
#      labels (poller_pick_labels), so the runner fixes them like any issue —
#      and, when the repo's watchlist entry routes by `assignees`, the first
#      allowed login as assignee (pick_assignee_route, issue #374): the issue
#      is written by the runner's own identity, which the list does not name.
#
# The audit never changes code. It runs in a temporary detached worktree of
# <remote>/<default-branch> (removed on exit); the operator's working tree is
# never touched. The agent's read-only promise is checked afterwards. That
# skeleton is shared with the coherence audit (lib/repo-audit.sh); this file
# holds what is the security audit's own: the scanners, the threat-model prompt,
# the auto-run policy and the issue text.
#
# Unchanged code is not reviewed twice (#382): when the poller runs this
# (audit_run sets RUN_ISSUES_AUDIT_STATE_FILE) and the default branch is still
# at the commit of the last SUCCESSFUL full audit (audit_sha_file), the agent
# pass is skipped and only the scanners run — a known-vulnerable dependency
# needs no commit to appear. Exit 6 says so. A full audit that is accepted
# leaves its commit for audit_run to record. A hand run (no state file) and
# --dry-run always audit in full and record nothing.
#
# --scanners-only runs the same scanners and the same issue policy with no
# agent at all — dependency-scan.sh is this mode, scheduled on its own denser
# interval. Findings carry the security audit's fingerprint, so the two never
# file the same finding twice. With nothing but the scanners, none installed
# means nothing was checked: exit 7, never a clean result.
#
# Not a result, and nothing is written (CLAUDE.md §9): the agent could not
# start, the result is empty or unparseable, or the worktree changed (exit 3).
# A scanner that FAILED does not become an issue (one missing network must not
# file an issue per audit); it is reported and turns the exit code into 5.
#
# Usage:
#   security-audit.sh <repo> [--remote <name>] [--dry-run] [--watchlist <path>] [--scanners-only]
#
#   <repo>             a local clone of the audited repository
#   --remote <name>    the remote to audit and to file issues in (default origin)
#   --dry-run          print the findings and the planned action per finding
#                      (create / exists / reopen / dismissed); no GitHub write
#   --watchlist <path> where the pickup labels come from (poller semantics: the
#                      ONLY candidate). A repo the watchlist does not list gets
#                      the built-in default pickup label. Its `assignees` key
#                      routes the auto-run issues to the first allowed login.
#   --scanners-only    the scanners alone: no agent call, no launch check
#
# Output (stdout): one line per finding — action, severity, location, text —
# then a summary line. Diagnostics go to stderr.
#
# Exit codes (own space):
#   0  audit done, issues written (also: no findings); or --dry-run done
#   1  usage error
#   2  repo, remote or its default branch does not resolve, or git/jq/gh is missing
#   3  the audit did not happen: agent launch failure, empty or unparseable result, or the worktree changed — nothing written
#   4  GitHub read or write failed — issues may be partially written
#   5  audit done, but at least one scanner failed (its class was not checked deterministically)
#   6  code unchanged since the last successful audit: the agent pass was skipped, the scanners ran
#   7  only the scanners were to run (--scanners-only, or unchanged code) and none is installed — nothing was checked
#
# Env:
#   RUN_ISSUES_SECURITY_AUDIT_AUTO_RUN_MIN_SEVERITY  mildest severity whose issue
#        gets the pickup labels: critical|high|medium|low|none (default high).
#        Read from the environment, else from poller.env (RUN_ISSUES_POLLER_ENV_FILE,
#        default $HOME/.config/run-issues/poller.env). The repo's `.security.audit_auto_run_min_severity` in
#        .claude/run-issues.json (default branch) wins. Unknown => none.
#   RUN_ISSUES_SECURITY_AUDIT_TIMEOUT   agent call time cap in seconds (default 3600)
#   RUN_ISSUES_SECURITY_AUDIT_FETCH_TIMEOUT  git fetch time cap (default 300)
#   RUN_ISSUES_WATCHLIST                watchlist override (poller semantics)
#   RUN_ISSUES_AUDIT_VERIFY             1 = every agent finding is first checked by
#        a verifier agent that tries to refute it (prompts/13-finding-verify.md):
#        refuted ones are dropped, unsure ones filed without pickup labels or
#        assignee (default 0; the poller sets 1)
#   RUN_ISSUES_AUDIT_VERIFY_TIMEOUT     time cap per verifier call in seconds (default 600)
#   RUN_ISSUES_AUDIT_STATE_FILE         internal: set by audit_run (lib/audit-schedule.sh)
#        for a scheduled run — where the last successfully audited commit is kept
#   RUN_ISSUES_CLAUDE_CMD and the rest of lib/claude-call.sh's settings; the
#   scanners' RUN_ISSUES_GITLEAKS_BIN / RUN_ISSUES_OSV_SCANNER_BIN /
#   RUN_ISSUES_SECURITY_SCAN_TIMEOUT. The machine env file is sourced like
#   orchestrate.sh does (lib/machine-env.sh, caller wins in RUN_ISSUES_*).

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

AUDIT_KIND="security"
# The label every audit issue carries — also the finding kind in the marker.
SECURITY_AUDIT_LABEL="security"
AUDIT_STEP="08-security-audit"

REPO_AUDIT_NAME="security-audit"

die_usage() { printf 'security-audit.sh: %s\n' "$1" >&2; exit 1; }

REPO=""
REMOTE="origin"
DRY_RUN=0
SCANNERS_ONLY=0
WATCHLIST_OVERRIDE="${RUN_ISSUES_WATCHLIST:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --remote)    shift; [ "$#" -gt 0 ] || die_usage "--remote needs a value"; REMOTE="$1" ;;
    --dry-run)   DRY_RUN=1 ;;
    --scanners-only) SCANNERS_ONLY=1 ;;
    --watchlist) shift; [ "$#" -gt 0 ] || die_usage "--watchlist needs a value"; WATCHLIST_OVERRIDE="$1" ;;
    -h|--help)   sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)          die_usage "unknown argument: $1" ;;
    *)           [ -z "$REPO" ] || die_usage "only one <repo> may be given"; REPO="$1" ;;
  esac
  shift
done
[ -n "$REPO" ] || die_usage "usage: security-audit.sh <repo> [--remote <name>] [--dry-run] [--watchlist <path>] [--scanners-only]"

# Libraries. claude-call.sh (via repo-audit.sh) carries `set -e`; this script
# does not (every failure below is an explicit exit code), so it is switched
# off again after sourcing.
source_machine_env
# shellcheck source=lib/repo-audit.sh
. "$SCRIPT_DIR/lib/repo-audit.sh"
# shellcheck source=lib/poller-config.sh
. "$SCRIPT_DIR/lib/poller-config.sh"
# shellcheck source=lib/security-scan.sh
. "$SCRIPT_DIR/lib/security-scan.sh"
# shellcheck source=lib/issue.sh
. "$SCRIPT_DIR/lib/issue.sh"
# shellcheck source=lib/audit-schedule.sh
. "$SCRIPT_DIR/lib/audit-schedule.sh"
set +e

say() { repo_audit_say "$@"; }

repo_audit_require_tools || exit $?
repo_audit_set_repo "$REPO" || exit $?

# The machine's auto-run threshold: the environment (caller or the machine env
# file) first, then poller.env — the file the poller of #340 runs this under,
# so a hand run and a scheduled run of one machine agree.
AUTO_RUN_MACHINE="${RUN_ISSUES_SECURITY_AUDIT_AUTO_RUN_MIN_SEVERITY:-$(repo_audit_poller_env_value RUN_ISSUES_SECURITY_AUDIT_AUTO_RUN_MIN_SEVERITY)}"
AUDIT_TIMEOUT="${RUN_ISSUES_SECURITY_AUDIT_TIMEOUT:-3600}"
FETCH_TIMEOUT="${RUN_ISSUES_SECURITY_AUDIT_FETCH_TIMEOUT:-300}"

repo_audit_resolve "$FETCH_TIMEOUT" || exit $?

# ---- mode: full, unchanged code (scanners only) or --scanners-only -----------
# SHA_FILE is set only for a scheduled full audit; the scanners-only kind has a
# state file of its own and neither reads nor records the audited commit.
SKIP_AGENT=""
SHA_FILE=""
if [ "$SCANNERS_ONLY" = 1 ]; then
  SKIP_AGENT="scanners_only"
elif [ -n "${RUN_ISSUES_AUDIT_STATE_FILE:-}" ] && [ "$DRY_RUN" = 0 ]; then
  SHA_FILE=$(audit_sha_file "$RUN_ISSUES_AUDIT_STATE_FILE")
  if [ -n "$HEAD_SHA" ] && [ "$(head -n 1 "$SHA_FILE" 2>/dev/null)" = "$HEAD_SHA" ]; then
    SKIP_AGENT="unchanged"
    say "code unchanged since last successful audit ($HEAD_SHA) — scanners only"
  fi
fi

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
# The assignee axis of pickup (#238): read with the poller's own reader and
# resolved with the pickup filter's own split, so the issue matches this
# machine's pickup. Empty when the repo does not route by assignee.
PICK_ASSIGNEES=$(poller_watchlist_pick_assignees "$WATCHLIST" "$REPO")
ROUTE_ASSIGNEE=$(pick_assignee_route "$PICK_ASSIGNEES")
say "auditing $OWNER_REPO at $BASE_REF ($HEAD_SHA); auto-run threshold '$AUTO_RUN_MIN', pickup labels '$PICK_LABELS'${PICK_ASSIGNEES:+, assignees '$PICK_ASSIGNEES' → '${ROUTE_ASSIGNEE:-(none)}'}"

# ---- launch check before anything costs ---------------------------------------
# Not when no agent runs: the scanners need no CLI.
[ -n "$SKIP_AGENT" ] || repo_audit_preflight || exit $?

# ---- known findings (also the dedup index) ------------------------------------
repo_audit_index "$SECURITY_AUDIT_LABEL" || exit $?

# ---- scanners -----------------------------------------------------------------
SCAN_DIR="$WORK/scan"
security_scan audit "$WT" "$SCAN_DIR" >&2 \
  || { say "security scan did not start — recorded as a failed scan"; rm -rf "$SCAN_DIR"; }
[ -f "$SCAN_DIR/scan.summary" ] && say "scan: $(tr '\n' ';' < "$SCAN_DIR/scan.summary")"
SCANNER_RESULTS=$(security_scan_prompt_text "$SCAN_DIR")

# ---- the agent ----------------------------------------------------------------
OUT="$WORK/$AUDIT_STEP.out"
if [ -n "$SKIP_AGENT" ]; then
  RESULT="clean"
else
  PROMPT="$WORK/$AUDIT_STEP.prompt"
  render_prompt "$SCRIPT_DIR/prompts/$AUDIT_STEP.md" "$PROMPT" \
    REPO="$OWNER_REPO" HEAD_SHA="$HEAD_SHA" REMOTE="$REMOTE" BASE_REF="$BASE_BRANCH" \
    SCANNER_RESULTS="$SCANNER_RESULTS" KNOWN_FINDINGS="$KNOWN"
  repo_audit_agent "$AUDIT_STEP" "$PROMPT" "$AUDIT_TIMEOUT" || exit $?
  # The review was accepted: audit_run records this commit if the run counts
  # as an audit that happened (exit 0 or 5).
  [ -n "$SHA_FILE" ] && { printf '%s\n' "$HEAD_SHA" > "$SHA_FILE.pending"; } 2>/dev/null
fi

# Scanner rows join AFTER parsing, as in the merge gate. Failed scanners are
# not findings here: they are reported and set exit 5.
FINDINGS=""
[ "$RESULT" = "findings" ] && FINDINGS=$(merge_gate_findings "$OUT" | sed 's/^/agent|/')
if [ -s "$SCAN_DIR/scan.findings" ]; then
  FINDINGS=$(printf '%s\n%s\n' "$FINDINGS" "$(sed 's/^/scanner|/' "$SCAN_DIR/scan.findings")")
fi
FINDINGS=$(printf '%s\n' "$FINDINGS" | awk 'NF && !seen[$0]++')
SCAN_FAILED=""
if [ ! -f "$SCAN_DIR/scan.summary" ]; then
  SCAN_FAILED="security-scan"
elif [ -s "$SCAN_DIR/scan.failed" ]; then
  SCAN_FAILED=$(cut -d'|' -f1 "$SCAN_DIR/scan.failed" | paste -sd, -)
fi

# The refutation pass over the agent's rows (opt-in, lib/repo-audit.sh).
repo_audit_verify "$AUDIT_KIND" || exit $?

# ---- one finding → fingerprint, title, body -----------------------------------

# _audit_source_key <origin> <description> — "<source>\t<key>": the stable class
# of a finding. Scanner rows carry their rule / advisory id; an agent row its
# [slug]. An agent row without a slug keys on the whole text: unstable, so the
# worst case is a duplicate issue, never two findings merged into one.
_audit_source_key() {
  local origin="$1" desc="$2" key
  if [ "$origin" = scanner ]; then
    case "$desc" in
      "gitleaks: "*)
        key=$(printf '%s' "$desc" | sed -E 's/^gitleaks: ([^ ]+).*/\1/')
        printf 'gitleaks\t%s' "$key"; return 0 ;;
      "osv-scanner: "*)
        # package (without the version) and the advisory ids
        key=$(printf '%s' "$desc" | sed -E 's/^osv-scanner: (.*)@[^ ]* \([^)]*\): ([^ ]+).*/\1 \2/')
        printf 'osv-scanner\t%s' "$key"; return 0 ;;
    esac
    printf 'scanner\t%s' "$desc"; return 0
  fi
  key=$(printf '%s' "$desc" | sed -nE 's/^\[([A-Za-z0-9_-]+)\].*/\1/p')
  printf 'agent\t%s' "${key:-$desc}"
}

# _audit_labels <severity> — the security label, plus the pickup labels when
# the severity reaches the auto-run threshold.
_audit_labels() {
  if finding_issues_auto_runs "$AUTO_RUN_MIN" "$1"; then
    printf '%s,%s' "$SECURITY_AUDIT_LABEL" "$PICK_LABELS"
  else
    printf '%s' "$SECURITY_AUDIT_LABEL"
  fi
}

# _audit_assignee <severity> — the routed assignee, on the same condition as
# the pickup labels: an issue that is not picked up needs no route.
_audit_assignee() {
  finding_issues_auto_runs "$AUTO_RUN_MIN" "$1" && printf '%s' "$ROUTE_ASSIGNEE"
  return 0
}

_audit_title() {
  local sev="$1" loc="$2" desc="$3" short file
  file=$(finding_location_file "$loc")
  short=$(printf '%s' "$desc" | cut -c1-90)
  [ "${#desc}" -gt 90 ] && short="$short…"
  printf 'Tietoturva (%s): %s%s' "$sev" "$short" "${file:+ — $file}"
}

_audit_body() {
  local sev="$1" conf="$2" loc="$3" desc="$4" source="$5" fp="$6" src_txt fix
  case "$source" in
    gitleaks)
      src_txt="gitleaks (salaisuusskanneri, koko historia)"
      fix="- [ ] Salaisuus on poistettu koodista ja konfiguraatiosta, ja sovellus lukee sen ympäristöstä tai salaisuusvarastosta.
- [ ] PR-kuvaus muistuttaa, että arvo on jo git-historiassa: avaimen kierrätys palvelussa on ihmisen tehtävä, eikä pelkkä poisto riitä." ;;
    osv-scanner)
      src_txt="osv-scanner (riippuvuuksien tunnetut haavoittuvuudet)"
      fix="- [ ] Riippuvuus on päivitetty versioon, jossa advisory on korjattu, ja lukkotiedosto on päivitetty.
- [ ] Jos korjattua versiota ei ole, PR-kuvaus kertoo sen ja perustelee valitun lievennyksen." ;;
    *)
      src_txt="agentin uhkamallikierros koko repolle"
      fix="- [ ] Kuvattu haavoittuvuus on korjattu sijainnissa \`$loc\`, eikä sama hyökkäyspolku toimi saman tiedoston muista kohdista.
- [ ] Korjaukselle on testi, jos projektissa on testejä." ;;
  esac
  cat <<EOF
## Tavoite

Korjaa koko repon tietoturva-auditoinnin (\`security-audit.sh\`) löytämä haavoittuvuus.

- **Vakavuus:** $sev
- **Varmuus:** $conf
- **Sijainti:** \`$loc\`
- **Lähde:** $src_txt
- **Kuvaus:** $desc

Auditoitu commit: \`$HEAD_SHA\` (\`$BASE_REF\`).

## Hyväksyntäkriteerit

$fix

## Rajaukset

- Vain tämä yksi löydös. Auditoinnin muut löydökset ovat omia issueitaan.
- Jos löydös osoittautuu vääräksi, älä muuta koodia: kirjaa perustelu ja pysähdy. Ihminen sulkee issuen tilaan *not planned*, jolloin auditointi ei avaa sitä uudelleen.

$(finding_marker "$AUDIT_KIND" "$fp")
EOF
}

# ---- apply --------------------------------------------------------------------
REOPEN_COMMENT="Löydös toistui koko repon tietoturva-auditoinnissa (\`security-audit.sh\`, commit \`$HEAD_SHA\`), joten issue avattiin uudelleen."
repo_audit_apply "$AUDIT_KIND" "$DRY_RUN" "$REOPEN_COMMENT" \
  _audit_source_key _audit_labels _audit_title _audit_body _audit_assignee <<EOF
$FINDINGS
EOF

SCANNERS_RAN=$(security_scan_ran_count "$SCAN_DIR")
printf 'security-audit: %s finding(s)%s%s%s%s\n' "$REPO_AUDIT_FINDINGS" \
  "$(case "$SKIP_AGENT" in unchanged) printf ' (code unchanged: scanners only)' ;; scanners_only) printf ' (scanners only)' ;; esac
     [ -n "$SKIP_AGENT" ] && [ "$SCANNERS_RAN" -eq 0 ] && echo ' — NOT CHECKED: no scanner installed')" \
  "$([ "$DRY_RUN" = 1 ] && echo ' (dry run: nothing written)')" \
  "$([ -n "$SCAN_FAILED" ] && echo "; scanner(s) failed: $SCAN_FAILED")" \
  "$([ "$REPO_AUDIT_WRITE_FAILED" -gt 0 ] && echo "; $REPO_AUDIT_WRITE_FAILED GitHub write(s) failed")"

[ "$REPO_AUDIT_WRITE_FAILED" -gt 0 ] && exit 4
[ -n "$SCAN_FAILED" ] && exit 5
if [ -n "$SKIP_AGENT" ] && [ "$SCANNERS_RAN" -eq 0 ]; then
  say "no scanner is installed and no agent ran — nothing was checked (not a clean result)"
  exit 7
fi
[ "$SKIP_AGENT" = unchanged ] && exit 6
exit 0
