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
#      labels (poller_pick_labels), so the runner fixes them like any issue.
#
# The audit never changes code. It runs in a temporary detached worktree of
# <remote>/<default-branch> (removed on exit); the operator's working tree is
# never touched. The agent's read-only promise is checked afterwards.
#
# Not a result, and nothing is written (CLAUDE.md §9): the agent could not
# start, the result is empty or unparseable, or the worktree changed (exit 3).
# A scanner that FAILED does not become an issue (one missing network must not
# file an issue per audit); it is reported and turns the exit code into 5.
#
# Usage:
#   security-audit.sh <repo> [--remote <name>] [--dry-run] [--watchlist <path>]
#
#   <repo>             a local clone of the audited repository
#   --remote <name>    the remote to audit and to file issues in (default origin)
#   --dry-run          print the findings and the planned action per finding
#                      (create / exists / reopen / dismissed); no GitHub write
#   --watchlist <path> where the pickup labels come from (poller semantics: the
#                      ONLY candidate). A repo the watchlist does not list gets
#                      the built-in default pickup label.
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
#
# Env:
#   RUN_ISSUES_SECURITY_AUDIT_AUTO_RUN_MIN_SEVERITY  mildest severity whose issue
#        gets the pickup labels: critical|high|medium|low|none (default high).
#        The repo's `.security.audit_auto_run_min_severity` in
#        .claude/run-issues.json (default branch) wins. Unknown => none.
#   RUN_ISSUES_SECURITY_AUDIT_TIMEOUT   agent call time cap in seconds (default 3600)
#   RUN_ISSUES_SECURITY_AUDIT_FETCH_TIMEOUT  git fetch time cap (default 300)
#   RUN_ISSUES_WATCHLIST                watchlist override (poller semantics)
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

die_usage() { printf 'security-audit.sh: %s\n' "$1" >&2; exit 1; }
say() { printf 'security-audit: %s\n' "$*" >&2; }

REPO=""
REMOTE="origin"
DRY_RUN=0
WATCHLIST_OVERRIDE="${RUN_ISSUES_WATCHLIST:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --remote)    shift; [ "$#" -gt 0 ] || die_usage "--remote needs a value"; REMOTE="$1" ;;
    --dry-run)   DRY_RUN=1 ;;
    --watchlist) shift; [ "$#" -gt 0 ] || die_usage "--watchlist needs a value"; WATCHLIST_OVERRIDE="$1" ;;
    -h|--help)   sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)          die_usage "unknown argument: $1" ;;
    *)           [ -z "$REPO" ] || die_usage "only one <repo> may be given"; REPO="$1" ;;
  esac
  shift
done
[ -n "$REPO" ] || die_usage "usage: security-audit.sh <repo> [--remote <name>] [--dry-run] [--watchlist <path>]"

for tool in git jq gh; do
  command -v "$tool" >/dev/null 2>&1 || { say "$tool is required but not installed"; exit 2; }
done

if ! TOPLEVEL=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null) || [ -z "$TOPLEVEL" ]; then
  say "'$REPO' is not a git repository"
  exit 2
fi
# The path as the operator spelled it (logical, symlinks kept) when it is the
# repo root: the watchlist lookup compares paths as strings, and git's own
# answer is the physical path.
if [ "$(cd "$REPO" && pwd -P)" = "$(cd "$TOPLEVEL" && pwd -P)" ]; then
  REPO=$(cd "$REPO" && pwd)
else
  REPO="$TOPLEVEL"
fi

# Libraries. claude-call.sh and preflight.sh carry `set -e`; this script does
# not (every failure below is an explicit exit code), so it is switched off
# again after sourcing.
source_machine_env
# shellcheck source=lib/git-remote.sh
. "$SCRIPT_DIR/lib/git-remote.sh"
# shellcheck source=lib/poller-config.sh
. "$SCRIPT_DIR/lib/poller-config.sh"
# shellcheck source=lib/labels.sh
. "$SCRIPT_DIR/lib/labels.sh"
# shellcheck source=lib/merge-gate.sh
. "$SCRIPT_DIR/lib/merge-gate.sh"
# shellcheck source=lib/security-scan.sh
. "$SCRIPT_DIR/lib/security-scan.sh"
# shellcheck source=lib/finding-issues.sh
. "$SCRIPT_DIR/lib/finding-issues.sh"
# shellcheck source=lib/claude-call.sh
. "$SCRIPT_DIR/lib/claude-call.sh"
set +e

AUTO_RUN_MACHINE="${RUN_ISSUES_SECURITY_AUDIT_AUTO_RUN_MIN_SEVERITY:-}"
AUDIT_TIMEOUT="${RUN_ISSUES_SECURITY_AUDIT_TIMEOUT:-3600}"
FETCH_TIMEOUT="${RUN_ISSUES_SECURITY_AUDIT_FETCH_TIMEOUT:-300}"

if ! OWNER_REPO=$(resolve_remote_to_owner_repo "$REPO" "$REMOTE"); then
  say "remote '$REMOTE' does not exist in $REPO or is not a github.com remote"
  exit 2
fi

if ! runner_git_fetch_bounded "$(preflight_timeout_bin)" "$FETCH_TIMEOUT" "$REPO" "$REMOTE" --quiet; then
  say "git fetch $REMOTE failed in $REPO"
  exit 2
fi
if ! BASE_REF=$(git -C "$REPO" symbolic-ref --short "refs/remotes/$REMOTE/HEAD" 2>/dev/null) || [ -z "$BASE_REF" ]; then
  say "'$REMOTE/HEAD' does not resolve — run 'git remote set-head $REMOTE -a' in $REPO, then retry"
  exit 2
fi
BASE_BRANCH="${BASE_REF#"$REMOTE"/}"
HEAD_SHA=$(git -C "$REPO" rev-parse "$BASE_REF" 2>/dev/null)

# ---- work area: a temporary detached worktree of the default branch ----------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/security-audit.XXXXXX") || { say "cannot create a temp dir"; exit 2; }
WT="$WORK/wt"
KEEP_WORK=0
cleanup() {
  git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true
  git -C "$REPO" worktree prune >/dev/null 2>&1 || true
  if [ "$KEEP_WORK" = 1 ]; then
    say "artifacts kept for inspection: $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT
if ! git -C "$REPO" worktree add --detach -q "$WT" "$HEAD_SHA" >/dev/null 2>&1; then
  say "cannot create a worktree of $BASE_REF"
  exit 2
fi

# ---- policy: repo (default branch) > machine > default ----------------------
CFG=$(git -C "$REPO" show "$HEAD_SHA:.claude/run-issues.json" 2>/dev/null || true)
AUTO_RUN_MIN=$(finding_issues_auto_run_min "$CFG" "$AUDIT_KIND" "$AUTO_RUN_MACHINE")
WATCHLIST=$(poller_resolve_watchlist "$WATCHLIST_OVERRIDE" \
  "$HOME/.config/run-issues/watchlist.json" \
  "$HOME/dotfiles/machine-studio/run-issues-watchlist.json") || WATCHLIST=""
PICK_LABELS=$(poller_watchlist_pick_labels "$WATCHLIST" "$REPO") \
  || say "$REPO is not in a watchlist — using the default pickup labels ($PICK_LABELS)"
say "auditing $OWNER_REPO at $BASE_REF ($HEAD_SHA); auto-run threshold '$AUTO_RUN_MIN', pickup labels '$PICK_LABELS'"

# ---- launch check before anything costs ---------------------------------------
if reason=$(preflight_claude_cmd_unusable); then
  say "audit agent unavailable: $reason — nothing written"
  exit 3
fi

# ---- known findings (also the dedup index) ------------------------------------
INDEX="$WORK/index.tsv"
if ! finding_issues_index "$OWNER_REPO" "$SECURITY_AUDIT_LABEL" "$INDEX"; then
  say "listing the '$SECURITY_AUDIT_LABEL' issues of $OWNER_REPO failed — nothing written"
  exit 4
fi
if [ -s "$INDEX" ]; then
  KNOWN=$(awk -F'\t' '{ printf "#%s (%s) %s\n", $3, $4, $5 }' "$INDEX")
else
  KNOWN="Ei tunnettuja löydöksiä."
fi

# ---- scanners -----------------------------------------------------------------
SCAN_DIR="$WORK/scan"
security_scan audit "$WT" "$SCAN_DIR" >&2 \
  || { say "security scan did not start — recorded as a failed scan"; rm -rf "$SCAN_DIR"; }
[ -f "$SCAN_DIR/scan.summary" ] && say "scan: $(tr '\n' ';' < "$SCAN_DIR/scan.summary")"
SCANNER_RESULTS=$(security_scan_prompt_text "$SCAN_DIR")

# ---- the agent ----------------------------------------------------------------
PROMPT="$WORK/$AUDIT_STEP.prompt"
render_prompt "$SCRIPT_DIR/prompts/$AUDIT_STEP.md" "$PROMPT" \
  REPO="$OWNER_REPO" HEAD_SHA="$HEAD_SHA" REMOTE="$REMOTE" BASE_REF="$BASE_BRANCH" \
  SCANNER_RESULTS="$SCANNER_RESULTS" KNOWN_FINDINGS="$KNOWN"
arc=0
( cd "$WT" && RUN_ISSUES_CLAUDE_TIMEOUT="$AUDIT_TIMEOUT" call_claude "$WORK" "$AUDIT_STEP" "$PROMPT" ) >&2 || arc=$?
say "audit agent returned rc=$arc"

OUT="$WORK/$AUDIT_STEP.out"
head_after=$(git -C "$WT" rev-parse HEAD 2>/dev/null)
if [ "$head_after" != "$HEAD_SHA" ] || [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then
  KEEP_WORK=1
  say "the audit agent changed the worktree (head ${head_after:-?}) although it may only read — audit rejected, nothing written"
  exit 3
fi
RESULT=$(merge_gate_parse "$OUT" "$WORK/$AUDIT_STEP.exit")
[ "$arc" -ne 0 ] && RESULT="launch_failed"
if [ "$RESULT" = "launch_failed" ]; then
  KEEP_WORK=1
  if [ "$arc" -ne 0 ]; then
    say "the audit agent failed (rc=$arc; 127 = did not start, 124 = timeout) — nothing written"
  else
    say "the audit result was empty or unparseable (no consistent MERGE_GATE_RESULT line) — nothing written"
  fi
  exit 3
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
N_FINDINGS=0
N_WRITE_FAILED=0
SEEN=" "
REOPEN_COMMENT="Löydös toistui koko repon tietoturva-auditoinnissa (\`security-audit.sh\`, commit \`$HEAD_SHA\`), joten issue avattiin uudelleen."
while IFS= read -r row; do
  [ -n "$row" ] || continue
  origin="${row%%|*}"; rest="${row#*|}"
  IFS='|' read -r sev conf loc desc <<<"$rest"
  desc="${rest#*|*|*|}"
  sk=$(_audit_source_key "$origin" "$desc")
  source="${sk%%$'\t'*}"; key="${sk#*$'\t'}"
  fp=$(finding_fingerprint "$source" "$loc" "$key")
  N_FINDINGS=$((N_FINDINGS + 1))

  if [[ "$SEEN" == *" $fp "* ]]; then
    printf 'duplicate\t%s\t%s\t%s\n' "$sev" "$loc" "$desc"
    continue
  fi
  SEEN="$SEEN$fp "

  labels="$SECURITY_AUDIT_LABEL"
  finding_issues_auto_runs "$AUTO_RUN_MIN" "$sev" && labels="$labels,$PICK_LABELS"

  if [ "$DRY_RUN" = 1 ]; then
    plan=$(finding_issue_plan "$INDEX" "$AUDIT_KIND" "$fp")
    case "$plan" in create|reopen*) plan="$plan [$labels]" ;; esac
    printf '%s\t%s\t%s\t%s\n' "$plan" "$sev" "$loc" "$desc"
    continue
  fi

  title=$(_audit_title "$sev" "$loc" "$desc")
  body=$(_audit_body "$sev" "$conf" "$loc" "$desc" "$source" "$fp")
  if res=$(finding_issue_apply "$OWNER_REPO" "$INDEX" "$AUDIT_KIND" "$fp" "$title" "$body" "$labels" "$REOPEN_COMMENT"); then
    printf '%s\t%s\t%s\t%s\n' "$res" "$sev" "$loc" "$desc"
  else
    N_WRITE_FAILED=$((N_WRITE_FAILED + 1))
    printf 'FAILED\t%s\t%s\t%s\n' "$sev" "$loc" "$desc"
  fi
done <<EOF
$FINDINGS
EOF

printf 'security-audit: %s finding(s)%s%s%s\n' "$N_FINDINGS" \
  "$([ "$DRY_RUN" = 1 ] && echo ' (dry run: nothing written)')" \
  "$([ -n "$SCAN_FAILED" ] && echo "; scanner(s) failed: $SCAN_FAILED")" \
  "$([ "$N_WRITE_FAILED" -gt 0 ] && echo "; $N_WRITE_FAILED GitHub write(s) failed")"

[ "$N_WRITE_FAILED" -gt 0 ] && exit 4
[ -n "$SCAN_FAILED" ] && exit 5
exit 0
