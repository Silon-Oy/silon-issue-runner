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
# Dependency findings are one issue per package VERSION, not per advisory
# (#397, lib/dependency-findings.sh): one upgrade fixes them all, so one issue
# lists every advisory id of `<ecosystem>/<package>@<version>`, the most severe
# one's severity and the lowest version that fixes all. A new advisory of the
# same version updates the open issue; an upgraded version is a new finding,
# and the old version's issue is never reopened. An open per-advisory issue
# filed before #397 (found by its old fingerprint) is closed with a comment
# naming the package issue that replaces it.
#
# A dependency finding that gets the pickup labels also gets the merge label
# (poller_merge_label), so its PR merges through pr-watch's gates without a
# human; a finding of the agent pass never does. The repo, the watchlist entry
# or the machine can switch that off (finding_issues_dependency_auto_merge).
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
#                      (create / exists / update / reopen / dismissed, and
#                      supersede per replaced per-advisory issue); no GitHub write
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
#   RUN_ISSUES_SECURITY_AUDIT_DEPENDENCY_AUTO_MERGE  whether a dependency finding
#        with the pickup labels also gets the merge label: true|false (default
#        true). Environment, else poller.env; the repo's watchlist entry
#        `security_dependency_auto_merge` wins over both, and the repo's
#        `.security.dependency_auto_merge` wins over all. Unknown => false.
#   PR_WATCH_MERGE_LABEL                the merge label (poller_merge_label;
#        environment, else poller.env, default auto-merge)
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
# shellcheck source=lib/dependency-findings.sh
. "$SCRIPT_DIR/lib/dependency-findings.sh"
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
DEP_AUTO_MERGE_ENV="${RUN_ISSUES_SECURITY_AUDIT_DEPENDENCY_AUTO_MERGE:-$(repo_audit_poller_env_value RUN_ISSUES_SECURITY_AUDIT_DEPENDENCY_AUTO_MERGE)}"
# The label pr-watch merges on: the poller runs this under poller.env, so a hand
# run reads the same file to name the same label.
PR_WATCH_MERGE_LABEL="${PR_WATCH_MERGE_LABEL:-$(repo_audit_poller_env_value PR_WATCH_MERGE_LABEL)}"
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
# The watchlist entry is this machine's per-repo value and stands in for the
# environment's when set (audit_machine_interval: the same machine-value rule
# as the audit schedule); the repo's own config still wins.
DEP_AUTO_MERGE=$(finding_issues_dependency_auto_merge "$CFG" "$AUDIT_KIND" \
  "$(audit_machine_interval "$(poller_watchlist_repo_value "$WATCHLIST" "$REPO" security_dependency_auto_merge)" "$DEP_AUTO_MERGE_ENV")")
MERGE_LABEL=$(poller_merge_label)
say "auditing $OWNER_REPO at $BASE_REF ($HEAD_SHA); auto-run threshold '$AUTO_RUN_MIN', pickup labels '$PICK_LABELS'${PICK_ASSIGNEES:+, assignees '$PICK_ASSIGNEES' → '${ROUTE_ASSIGNEE:-(none)}'}, dependency merge label '$([ "$DEP_AUTO_MERGE" = 1 ] && printf '%s' "$MERGE_LABEL" || printf off)'"

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
# Dependency findings: one per package version (#397). The per-advisory
# osv-scanner rows are replaced by the grouped ones whenever the scanner's
# per-group detail is there; without it (an older out-dir) they stay as they are.
DEPS="$WORK/deps.tsv"
: > "$DEPS"
if [ -s "$SCAN_DIR/scan.findings" ]; then
  if [ -f "$SCAN_DIR/scan.osv.tsv" ]; then
    SCANNER_ROWS=$(grep -v '^[^|]*|[^|]*|[^|]*|osv-scanner: ' "$SCAN_DIR/scan.findings" | sed 's/^/scanner|/'
                   dependency_findings_group "$SCAN_DIR/scan.osv.tsv" "$DEPS")
  else
    SCANNER_ROWS=$(sed 's/^/scanner|/' "$SCAN_DIR/scan.findings")
  fi
  FINDINGS=$(printf '%s\n%s\n' "$FINDINGS" "$SCANNER_ROWS")
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
# A package version (#397) keys on `<eco>/<pkg>@<ver>` and adds its advisory
# ids as the third field. The per-advisory `osv-scanner` key stays: it is the
# old fingerprint by which _audit_supersede finds the issues it replaces.
_audit_source_key() {
  local origin="$1" desc="$2" key
  if [ "$origin" = scanner ]; then
    if key=$(dependency_finding_parse "$desc"); then
      printf 'osv-scanner-pkg\t%s' "$key"; return 0
    fi
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

# _audit_is_dependency <source> — rc 0 for a dependency finding (a package
# version, or a per-advisory row when the scanner's detail was missing).
_audit_is_dependency() {
  case "$1" in osv-scanner|osv-scanner-pkg) return 0 ;; esac
  return 1
}

# _audit_labels <severity> <source> — the security label, plus the pickup
# labels when the severity reaches the auto-run threshold, plus the merge label
# when it is also a dependency finding and the policy allows it (#397).
_audit_labels() {
  if finding_issues_auto_runs "$AUTO_RUN_MIN" "$1"; then
    printf '%s,%s' "$SECURITY_AUDIT_LABEL" "$PICK_LABELS"
    [ "$DEP_AUTO_MERGE" = 1 ] && _audit_is_dependency "${2:-}" && printf ',%s' "$MERGE_LABEL"
  else
    printf '%s' "$SECURITY_AUDIT_LABEL"
  fi
  return 0
}

# _audit_assignee <severity> [<source>] — the routed assignee, on the same
# condition as the pickup labels: an issue that is not picked up needs no route.
_audit_assignee() {
  finding_issues_auto_runs "$AUTO_RUN_MIN" "$1" && printf '%s' "$ROUTE_ASSIGNEE"
  return 0
}

_audit_title() {
  local sev="$1" loc="$2" desc="$3" short file pk n
  if pk=$(dependency_finding_parse "$desc"); then
    n=$(printf '%s' "${pk#*$'\t'}" | tr ',' '\n' | grep -c .)
    printf 'Tietoturva (%s): päivitä riippuvuus %s (%s tunnistetta)' "$sev" "${pk%%$'\t'*}" "$n"
    return 0
  fi
  file=$(finding_location_file "$loc")
  short=$(printf '%s' "$desc" | cut -c1-90)
  [ "${#desc}" -gt 90 ] && short="$short…"
  printf 'Tietoturva (%s): %s%s' "$sev" "$short" "${file:+ — $file}"
}

# _audit_dependency_body <severity> <key> <ids> <fingerprint> — the issue text
# of one package version (#397), from the grouped detail (DEPS).
_audit_dependency_body() {
  local sev="$1" key="$2" ids="$3" fp="$4" rows pkg eco ver fix_all files table fix
  rows=$(dependency_details_of "$DEPS" "$key")
  eco=$(printf '%s\n' "$rows" | head -n 1 | cut -f3)
  pkg=$(printf '%s\n' "$rows" | head -n 1 | cut -f4)
  ver=$(printf '%s\n' "$rows" | head -n 1 | cut -f5)
  fix_all=$(dependency_fix_all "$DEPS" "$key")
  files=$(printf '%s\n' "$rows" | cut -f2 | awk 'NF && !seen[$0]++ { printf "%s`%s`", (n++ ? ", " : ""), $0 }')
  table=$(printf '%s\n' "$rows" | awk -F'\t' '!seen[$7]++ {
    ids = $7; gsub(",", ", ", ids); s = $9; gsub("\\|", "/", s)
    printf "| %s | %s | %s | %s |\n", ids, $6, ($8 == "" ? "ei tiedossa" : "`" $8 "`"), s }')
  if [ -n "$fix_all" ]; then
    fix="- [ ] \`$pkg\` on päivitetty vähintään versioon \`$fix_all\`, ja lukkotiedostot on päivitetty."
  else
    fix="- [ ] \`$pkg\` on päivitetty versioon, joka korjaa jokaisen yllä luetellun tunnisteen, ja lukkotiedostot on päivitetty."
  fi
  cat <<EOF
## Tavoite

Päivitä riippuvuus \`$pkg\` ($eco) versiosta \`$ver\` versioon, joka korjaa kaikki koko repon tietoturva-auditoinnin (\`security-audit.sh\`) löytämät tunnetut haavoittuvuudet. Yksi versiopäivitys korjaa ne, joten tämä issue kattaa paketin tämän version kaikki tunnisteet.

- **Vakavuus:** $sev (vakavimman tunnisteen mukaan)
- **Pienin kaikki korjaava versio:** $([ -n "$fix_all" ] && printf '`%s`' "$fix_all" || printf 'ei tiedossa — skanneri ei kerro korjattua versiota kaikille tunnisteille')
- **Lukkotiedostot:** $files
- **Lähde:** osv-scanner (riippuvuuksien tunnetut haavoittuvuudet)

| Tunniste | Vakavuus | Korjattu versiossa | Kuvaus |
|---|---|---|---|
$table

Auditoitu commit: \`$HEAD_SHA\` (\`$BASE_REF\`).

## Hyväksyntäkriteerit

$fix
- [ ] Jos jollekin tunnisteelle ei ole korjattua versiota, PR-kuvaus kertoo sen ja perustelee valitun lievennyksen.

## Rajaukset

- Vain tämän paketin tämä versio. Muiden pakettien löydökset ovat omia issueitaan.
- Jos löydös osoittautuu vääräksi, älä muuta koodia: kirjaa perustelu ja pysähdy. Ihminen sulkee issuen tilaan *not planned*, jolloin auditointi ei avaa sitä uudelleen.

$(finding_marker "$AUDIT_KIND" "$fp")
$(finding_ids_marker "$fp" "$ids")
EOF
}

_audit_body() {
  local sev="$1" conf="$2" loc="$3" desc="$4" source="$5" fp="$6" src_txt fix extra="" pk
  if [ "$source" = osv-scanner-pkg ] && pk=$(dependency_finding_parse "$desc"); then
    _audit_dependency_body "$sev" "${pk%%$'\t'*}" "${pk#*$'\t'}" "$fp"
    return 0
  fi
  case "$source" in
    gitleaks)
      # A scanner hit is a question, not a verdict (#398): the body says what to
      # find out and what each answer means, and never claims rotation is due.
      src_txt="gitleaks (salaisuusskanneri, koko historia)"
      fix="Selvitä ensin, onko osuma oikea salaisuus. Skannerin kuvauksessa näkyy arvosta enintään neljä ensimmäistä ja kaksi viimeistä merkkiä sekä pituus: älä lainaa koko arvoa issueen, kommenttiin, PR-kuvaukseen tai lokiin.

1. **Onko arvo oikea salaisuus?** Vaihtoehdot: oikea avain tai salasana, testidata, täytearvo (esim. CI:n placeholder tai \`.env.example\`n paikallinen arvo) tai julkiseksi tarkoitettu avain (esim. JWT, jonka \`role\`-kenttä on julkinen rooli kuten \`anon\`).
2. **Onko arvo HEADissa vai vain historiassa?** Tarkista, löytyykö se yhä sijainnista \`$loc\` vai vain löydöksen commitista.

Mitä vastaus tarkoittaa:

- **Oikea salaisuus HEADissa:** arvo poistetaan koodista ja konfiguraatiosta, ja sovellus lukee sen ympäristöstä tai salaisuusvarastosta. Arvo on jo git-historiassa, joten pelkkä poisto ei riitä: myös avaimen kierrätys palvelussa tarvitaan. Se on ihmisen tehtävä, ja PR-kuvaus muistuttaa siitä.
- **Oikea salaisuus vain historiassa:** koodimuutosta ei tarvita. Avaimen kierrätys palvelussa riittää, ja se on ihmisen tehtävä.
- **Väärä hälytys** (testidata, täytearvo, julkinen avain): koodia ei muuteta, ja issue suljetaan tilaan *not planned* (ks. alla).

- [ ] Osuman luokka (oikea salaisuus / väärä hälytys) ja sijainti (HEAD / vain historia) on selvitetty.
- [ ] Oikean salaisuuden HEADissa oleva arvo on poistettu, ja kierrätyksen tarve on kirjattu ihmiselle."
      extra="
## Väärä hälytys

Jos osuma on väärä hälytys, sulje issue tilaan *not planned*. Auditointi ei avaa sitä uudelleen, vaikka sama osuma löytyisi seuraavalla kierroksella. Kommentointi ennen sulkemista ei ole tarpeen: kommentti avoimeen issueen käynnistäisi ajon uudelleen.
" ;;
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
$extra
$(finding_marker "$AUDIT_KIND" "$fp")
EOF
}

# _audit_supersede <source> <key> <number> <action> — the move from per-advisory
# issues (#397): every OPEN issue that carries the old per-advisory fingerprint
# of one of the package version's advisories is closed with a comment naming
# the package issue <number>. The old fingerprint is computed with the old key
# (_audit_source_key on the advisory's scan.findings description), so it is the
# one the issue was filed under. Runs on every audit while the scanner reports
# the advisory, so a failed close converges on the next run. A package issue a
# human dismissed (not planned) takes its old issues with it the same way.
_audit_supersede() {
  local source="$1" key="$2" n="$3" action="$4" path desc sk old plan old_n reason msg res rc=0
  [ "$source" = osv-scanner-pkg ] || return 0
  [ "$action" = dismissed ] && reason=not_planned || reason=completed
  while IFS=$'\t' read -r path desc; do
    [ -n "$desc" ] || continue
    sk=$(_audit_source_key scanner "$desc")
    old=$(finding_fingerprint "${sk%%$'\t'*}" "$path" "${sk#*$'\t'}")
    plan=$(finding_issue_plan "$INDEX" "$AUDIT_KIND" "$old")
    case "$plan" in exists\ *) old_n="${plan#exists }" ;; *) continue ;; esac
    [ "$old_n" = "$n" ] && continue
    if [ "$DRY_RUN" = 1 ]; then
      printf 'supersede #%s → %s\t\t%s\t%s\n' "$old_n" "${n:+#$n}${n:-(uusi)}" "$key" "$desc"
      continue
    fi
    msg="Auditointi kokoaa nyt riippuvuuslöydökset paketin version mukaan, koska yksi versiopäivitys korjaa saman version kaikki tunnisteet. Tämä tunniste kuuluu issueen #$n (\`$key\`), joten tämä issue suljettiin, jottei samaa korjausta tehdä kahteen kertaan."
    if res=$(finding_issue_supersede "$OWNER_REPO" "$INDEX" "$old_n" "$msg" "$reason"); then
      printf '%s → #%s\t\t%s\t%s\n' "$res" "$n" "$key" "$desc"
    else
      printf 'FAILED supersede #%s\t\t%s\t%s\n' "$old_n" "$key" "$desc"
      rc=1
    fi
  done <<EOF
$(dependency_details_of "$DEPS" "$key" | awk -F'\t' '{ print $2 "\t" $10 }')
EOF
  return "$rc"
}

# ---- apply --------------------------------------------------------------------
REOPEN_COMMENT="Löydös toistui koko repon tietoturva-auditoinnissa (\`security-audit.sh\`, commit \`$HEAD_SHA\`), joten issue avattiin uudelleen."
repo_audit_apply "$AUDIT_KIND" "$DRY_RUN" "$REOPEN_COMMENT" \
  _audit_source_key _audit_labels _audit_title _audit_body _audit_assignee _audit_supersede <<EOF
$FINDINGS
EOF

SCANNERS_RAN=$(security_scan_ran_count "$SCAN_DIR")
# Not a `case` inside $(...): bash 3.2 cannot parse its unbalanced `)`.
MODE_NOTE=""
case "$SKIP_AGENT" in
  unchanged)     MODE_NOTE=" (code unchanged: scanners only)" ;;
  scanners_only) MODE_NOTE=" (scanners only)" ;;
esac
[ -n "$SKIP_AGENT" ] && [ "$SCANNERS_RAN" -eq 0 ] && MODE_NOTE="$MODE_NOTE — NOT CHECKED: no scanner installed"
printf 'security-audit: %s finding(s)%s%s%s%s\n' "$REPO_AUDIT_FINDINGS" \
  "$MODE_NOTE" \
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
