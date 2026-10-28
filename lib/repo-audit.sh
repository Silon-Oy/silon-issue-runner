#!/usr/bin/env bash
# lib/repo-audit.sh — the skeleton every whole-repo audit shares: the security
# audit (security-audit.sh, #339), the coherence audit (coherence-audit.sh,
# #342) and the quality audit (quality-audit.sh, #395).
#
# An audit differs from another in WHAT it asks (its prompt, its material, its
# issue text, which findings may start a run). It does not differ in how the
# answer is made trustworthy, so that lives here once (CLAUDE.md §7):
#
#   - the audited state: <remote>/<default-branch> after a bounded fetch
#   - the work area: a temporary DETACHED worktree of that commit, removed on
#     exit; the operator's working tree is never touched
#   - the read-only gate: an agent that moved HEAD or dirtied the worktree
#     rejects the whole audit (exit 3) — two copies of this gate would be two
#     chances for one of them to go missing silently
#   - "not a result" (CLAUDE.md §9): a launch failure, an empty or unparseable
#     answer is exit 3, never "no findings"
#   - the refutation pass (opt-in): each agent finding is checked by an agent
#     that tries to disprove it, under the same read-only gate
#   - the finding loop: fingerprint → plan → write, via lib/finding-issues.sh
#   - the grouping mode (--group, #396): new findings grouped into fix-sized
#     issues under epics instead of one issue per finding
#
# The functions share state through globals the calling script also reads:
# REPO REMOTE OWNER_REPO BASE_REF BASE_BRANCH HEAD_SHA WORK WT KEEP_WORK INDEX
# KNOWN RESULT. Diagnostics go to stderr prefixed with REPO_AUDIT_NAME. Each
# function returns the caller's exit code for its failure (2 resolution,
# 3 no result, 4 GitHub), so the script's exit-code space stays its own.
#
# Sourced AFTER source_machine_env (lib/machine-env.sh): claude-call.sh reads
# its defaults at source time (CLAUDE.md §5.5). claude-call.sh carries `set -e`;
# the caller switches it off again after sourcing this file.

_REPO_AUDIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-remote.sh
. "$_REPO_AUDIT_DIR/git-remote.sh"
# shellcheck source=lib/labels.sh
. "$_REPO_AUDIT_DIR/labels.sh"
# shellcheck source=lib/merge-gate.sh
. "$_REPO_AUDIT_DIR/merge-gate.sh"
# shellcheck source=lib/finding-issues.sh
. "$_REPO_AUDIT_DIR/finding-issues.sh"
# shellcheck source=lib/epic-write.sh
. "$_REPO_AUDIT_DIR/epic-write.sh"
# shellcheck source=lib/claude-call.sh
. "$_REPO_AUDIT_DIR/claude-call.sh"

repo_audit_say() { printf '%s: %s\n' "${REPO_AUDIT_NAME:-audit}" "$*" >&2; }

# repo_audit_require_tools — rc 2 when git, jq or gh is missing.
repo_audit_require_tools() {
  local tool
  for tool in git jq gh; do
    command -v "$tool" >/dev/null 2>&1 || { repo_audit_say "$tool is required but not installed"; return 2; }
  done
}

# repo_audit_set_repo <path> — sets REPO to the repository root. The path as
# the operator spelled it (logical, symlinks kept) when it is the root: the
# watchlist lookup compares paths as strings, and git's own answer is the
# physical path. rc 2 when <path> is not inside a git repository.
repo_audit_set_repo() {
  local top
  if ! top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || [ -z "$top" ]; then
    repo_audit_say "'$1' is not a git repository"
    return 2
  fi
  if [ "$(cd "$1" && pwd -P)" = "$(cd "$top" && pwd -P)" ]; then
    REPO=$(cd "$1" && pwd)
  else
    REPO="$top"
  fi
}

# repo_audit_resolve <fetch-timeout> — resolve REMOTE of REPO and fetch it; sets
# OWNER_REPO, BASE_REF (<remote>/<branch>), BASE_BRANCH and HEAD_SHA. rc 2 when
# the remote is not a github.com remote, the fetch fails or <remote>/HEAD does
# not resolve.
repo_audit_resolve() {
  if ! OWNER_REPO=$(resolve_remote_to_owner_repo "$REPO" "$REMOTE"); then
    repo_audit_say "remote '$REMOTE' does not exist in $REPO or is not a github.com remote"
    return 2
  fi
  if ! runner_git_fetch_bounded "$(preflight_timeout_bin)" "$1" "$REPO" "$REMOTE" --quiet; then
    repo_audit_say "git fetch $REMOTE failed in $REPO"
    return 2
  fi
  if ! BASE_REF=$(git -C "$REPO" symbolic-ref --short "refs/remotes/$REMOTE/HEAD" 2>/dev/null) || [ -z "$BASE_REF" ]; then
    repo_audit_say "'$REMOTE/HEAD' does not resolve — run 'git remote set-head $REMOTE -a' in $REPO, then retry"
    return 2
  fi
  BASE_BRANCH="${BASE_REF#"$REMOTE"/}"
  HEAD_SHA=$(git -C "$REPO" rev-parse "$BASE_REF" 2>/dev/null)
}

# repo_audit_cleanup — the EXIT trap: remove the worktree, and the work dir
# unless KEEP_WORK=1 (a rejected audit keeps its artifacts for inspection).
repo_audit_cleanup() {
  [ -n "${WT:-}" ] && git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
  git -C "$REPO" worktree prune >/dev/null 2>&1 || true
  [ -n "${WORK:-}" ] || return 0
  if [ "${KEEP_WORK:-0}" = 1 ]; then
    repo_audit_say "artifacts kept for inspection: $WORK"
  else
    rm -rf "$WORK"
  fi
}

# repo_audit_worktree — sets WORK (temp dir) and WT (a detached worktree of
# HEAD_SHA inside it) and installs repo_audit_cleanup as the EXIT trap. rc 2
# when either cannot be created.
repo_audit_worktree() {
  KEEP_WORK=0
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/${REPO_AUDIT_NAME:-audit}.XXXXXX") || { repo_audit_say "cannot create a temp dir"; return 2; }
  WT="$WORK/wt"
  trap repo_audit_cleanup EXIT
  if ! git -C "$REPO" worktree add --detach -q "$WT" "$HEAD_SHA" >/dev/null 2>&1; then
    repo_audit_say "cannot create a worktree of $BASE_REF"
    return 2
  fi
}

# repo_audit_preflight — rc 3 when the agent CLI cannot launch: checked before
# anything costs, and reported as "no audit", never as "no findings".
repo_audit_preflight() {
  local reason
  if reason=$(preflight_claude_cmd_unusable); then
    repo_audit_say "audit agent unavailable: $reason — nothing written"
    return 3
  fi
}

# repo_audit_index <label> — the known findings of <label>: sets INDEX (the
# dedup index, lib/finding-issues.sh) and KNOWN (one line per known issue, for
# the prompt). rc 4 when the listing failed: an empty index would turn every
# known finding into a duplicate, so nothing may be written.
repo_audit_index() {
  INDEX="$WORK/index.tsv"
  if ! finding_issues_index "$OWNER_REPO" "$1" "$INDEX"; then
    repo_audit_say "listing the '$1' issues of $OWNER_REPO failed — nothing written"
    return 4
  fi
  if [ -s "$INDEX" ]; then
    KNOWN=$(awk -F'\t' '{ printf "#%s (%s) %s\n", $3, $4, $5 }' "$INDEX")
  else
    KNOWN="Ei tunnettuja löydöksiä."
  fi
}

# repo_audit_readonly_check <who> — the read-only gate, ONE copy for every agent
# that runs in WT (the audit agent and each finding verifier): HEAD must still
# be HEAD_SHA and the worktree clean. rc 3 (KEEP_WORK=1) otherwise.
repo_audit_readonly_check() {
  local head_after
  head_after=$(git -C "$WT" rev-parse HEAD 2>/dev/null)
  if [ "$head_after" != "$HEAD_SHA" ] || [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then
    KEEP_WORK=1
    repo_audit_say "the $1 changed the worktree (head ${head_after:-?}) although it may only read — audit rejected, nothing written"
    return 3
  fi
}

# repo_audit_agent <step> <prompt-file> <timeout-secs> — run the audit agent in
# WT and accept its answer only if it left the worktree untouched. Sets RESULT
# to clean | findings; the answer is in $WORK/<step>.out. rc 3 (KEEP_WORK=1)
# when the worktree changed, the agent failed or its answer is empty or
# unparseable — nothing may be written then.
repo_audit_agent() {
  local step="$1" prompt="$2" timeout="$3" arc=0
  ( cd "$WT" && RUN_ISSUES_CLAUDE_TIMEOUT="$timeout" call_claude "$WORK" "$step" "$prompt" ) >&2 || arc=$?
  repo_audit_say "audit agent returned rc=$arc"

  repo_audit_readonly_check "audit agent" || return 3
  RESULT=$(merge_gate_parse "$WORK/$step.out" "$WORK/$step.exit")
  [ "$arc" -ne 0 ] && RESULT="launch_failed"
  if [ "$RESULT" = "launch_failed" ]; then
    KEEP_WORK=1
    if [ "$arc" -ne 0 ]; then
      repo_audit_say "the audit agent failed (rc=$arc; 127 = did not start, 124 = timeout) — nothing written"
    else
      repo_audit_say "the audit result was empty or unparseable (no consistent MERGE_GATE_RESULT line) — nothing written"
    fi
    return 3
  fi
}

# repo_audit_verify <kind> — the refutation pass (issue #394), run between
# parsing and repo_audit_apply. Opt-in: RUN_ISSUES_AUDIT_VERIFY=1 (the poller
# sets it, CLAUDE.md §9); otherwise a no-op. Operates on the global FINDINGS
# (the rows repo_audit_apply reads) rather than a pipe: a subshell would lose
# KEEP_WORK, and a verifier reading the rows' stdin would swallow the rest.
#
# Each `agent|` row is handed, alone and in a fresh context, to an agent told
# to disprove it from the code (prompts/13-finding-verify.md):
#   CONFIRMED → kept as is
#   REFUTED   → dropped from FINDINGS and logged
#   UNSURE    → kept, and listed in $WORK/verify.unsure: repo_audit_apply files
#               it with the kind's label only, no assignee, and a note
# A launch failure, a timeout or an unparseable answer reads as UNSURE, never
# REFUTED: a finding must not vanish because its verifier did. Scanner rows are
# deterministic tool output and pass unverified. Every verifier runs under the
# same read-only gate as the audit agent: rc 3 rejects the whole audit.
repo_audit_verify() {
  local kind="$1" row rest sev conf loc desc i=0 rc verdict prompt step kept=""
  local n_conf=0 n_ref=0 n_uns=0
  local timeout="${RUN_ISSUES_AUDIT_VERIFY_TIMEOUT:-600}"
  local template="$_REPO_AUDIT_DIR/../prompts/13-finding-verify.md"
  : > "$WORK/verify.unsure"
  [ "${RUN_ISSUES_AUDIT_VERIFY:-0}" = 1 ] || return 0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    if [ "${row%%|*}" != agent ]; then
      kept="$kept$row"$'\n'
      continue
    fi
    i=$((i + 1))
    rest="${row#*|}"
    IFS='|' read -r sev conf loc desc <<<"$rest"
    desc="${rest#*|*|*|}"
    step="13-finding-verify-$i"
    prompt="$WORK/$step.prompt"
    verdict=""
    if render_prompt "$template" "$prompt" \
         REPO="$OWNER_REPO" HEAD_SHA="$HEAD_SHA" AUDIT_KIND="$kind" \
         FINDING_SEVERITY="$sev" FINDING_CONFIDENCE="$conf" \
         FINDING_LOCATION="$loc" FINDING_DESCRIPTION="$desc" 2>/dev/null && [ -s "$prompt" ]; then
      rc=0
      ( cd "$WT" && RUN_ISSUES_CLAUDE_TIMEOUT="$timeout" call_claude "$WORK" "$step" "$prompt" ) </dev/null >&2 || rc=$?
      repo_audit_readonly_check "finding verifier" || return 3
      if [ "$rc" -eq 0 ]; then
        verdict=$(awk 'NF { l = $0 } END { sub(/\r$/, "", l); print l }' "$WORK/$step.out" 2>/dev/null \
                  | sed -nE 's/^VERIFY_RESULT: (CONFIRMED|REFUTED|UNSURE)$/\1/p')
      fi
      [ -n "$verdict" ] || repo_audit_say "finding verifier gave no result (rc=$rc; 127 = did not start, 124 = timeout) — read as UNSURE: $loc"
    else
      repo_audit_say "cannot render the verifier prompt — read as UNSURE: $loc"
    fi
    case "${verdict:-UNSURE}" in
      CONFIRMED)
        n_conf=$((n_conf + 1)); kept="$kept$row"$'\n' ;;
      REFUTED)
        n_ref=$((n_ref + 1))
        repo_audit_say "finding refuted by verifier: $loc — $desc" ;;
      *)
        n_uns=$((n_uns + 1)); kept="$kept$row"$'\n'
        printf '%s\n' "$row" >> "$WORK/verify.unsure" ;;
    esac
  done <<<"$FINDINGS"
  FINDINGS="${kept%$'\n'}"
  [ "$i" -gt 0 ] && repo_audit_say "verified: $n_conf confirmed, $n_ref refuted, $n_uns unsure"
  return 0
}

# REPO_AUDIT_UNSURE_NOTE — prepended to the body of an UNSURE finding's issue.
REPO_AUDIT_UNSURE_NOTE="> **Tarkistus:** riippumaton tarkistus ei pystynyt vahvistamaan eikä kumoamaan tätä löydöstä, joten issue ei saanut poimintalabelia automaattisesti. Arvioi löydös ennen toteutusta."

# repo_audit_apply <kind> <dry-run 0|1> <reopen-comment> <key-fn> <labels-fn>
#                  <title-fn> <body-fn> [<assignee-fn>] [<after-fn>]
# Read findings `<origin>|<severity>|<confidence>|<location>|<description>` on
# stdin (origin: agent | scanner) and carry each out. The audit's own parts are
# the functions:
#
#   <key-fn> <origin> <description>         → "<source>\t<key>[\t<ids>]" (the
#                                             fingerprint class; <ids>, comma-
#                                             separated, makes an open issue
#                                             that lacks one of them an update)
#   <labels-fn> <severity> <source>         → the labels CSV, <kind>'s label first
#   <title-fn> <severity> <location> <description>
#   <body-fn> <severity> <confidence> <location> <description> <source> <fingerprint>
#   <assignee-fn> <severity> <source>       → the login to route the issue to, or
#                                             nothing (optional; finding_issue_apply)
#   <after-fn> <source> <key> <number> <action>
#                                           → runs once the finding has an issue
#                                             (<number>, empty in a dry run that
#                                             would create one; <action> is the
#                                             plan or result word). Prints its
#                                             own output lines; rc 1 counts as a
#                                             failed write (optional)
#
# Prints one line per finding: <action>\t<severity>\t<location>\t<description>.
# Sets REPO_AUDIT_FINDINGS and REPO_AUDIT_WRITE_FAILED (counts). Uses OWNER_REPO
# and INDEX.
repo_audit_apply() {
  local kind="$1" dry="$2" comment="$3" key_fn="$4" labels_fn="$5" title_fn="$6" body_fn="$7"
  local assignee_fn="${8:-}" after_fn="${9:-}"
  local row origin rest sev conf loc desc sk source key ids fp labels assignee plan title body res num unsure seen=" "
  REPO_AUDIT_FINDINGS=0
  REPO_AUDIT_WRITE_FAILED=0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    origin="${row%%|*}"; rest="${row#*|}"
    IFS='|' read -r sev conf loc desc <<<"$rest"
    desc="${rest#*|*|*|}"
    sk=$("$key_fn" "$origin" "$desc")
    source="${sk%%$'\t'*}"; key="${sk#*$'\t'}"; ids=""
    case "$key" in *$'\t'*) ids="${key#*$'\t'}"; key="${key%%$'\t'*}" ;; esac
    fp=$(finding_fingerprint "$source" "$loc" "$key")
    REPO_AUDIT_FINDINGS=$((REPO_AUDIT_FINDINGS + 1))

    if [[ "$seen" == *" $fp "* ]]; then
      printf 'duplicate\t%s\t%s\t%s\n' "$sev" "$loc" "$desc"
      continue
    fi
    seen="$seen$fp "

    labels=$("$labels_fn" "$sev" "$source")
    assignee=""
    [ -n "$assignee_fn" ] && assignee=$("$assignee_fn" "$sev" "$source")
    unsure=0
    # An UNSURE finding (repo_audit_verify): the kind's own label only — the
    # labels-fn contract puts it first — and no route, at any severity.
    if [ -s "${WORK:-}/verify.unsure" ] && grep -qxF -- "$row" "$WORK/verify.unsure"; then
      unsure=1; labels="${labels%%,*}"; assignee=""
    fi

    if [ "$dry" = 1 ]; then
      plan=$(finding_issue_plan "$INDEX" "$kind" "$fp" "$ids")
      res="$plan"
      case "$plan" in create|reopen*|update*) plan="$plan [$labels]${assignee:+ @$assignee}" ;; esac
      [ "$unsure" = 1 ] && plan="$plan [unsure]"
      printf '%s\t%s\t%s\t%s\n' "$plan" "$sev" "$loc" "$desc"
    else
      title=$("$title_fn" "$sev" "$loc" "$desc")
      body=$("$body_fn" "$sev" "$conf" "$loc" "$desc" "$source" "$fp")
      [ "$unsure" = 1 ] && body="$REPO_AUDIT_UNSURE_NOTE

$body"
      if res=$(finding_issue_apply "$OWNER_REPO" "$INDEX" "$kind" "$fp" "$title" "$body" "$labels" "$comment" "$assignee" "$ids"); then
        printf '%s\t%s\t%s\t%s\n' "$res" "$sev" "$loc" "$desc"
      else
        REPO_AUDIT_WRITE_FAILED=$((REPO_AUDIT_WRITE_FAILED + 1))
        printf 'FAILED\t%s\t%s\t%s\n' "$sev" "$loc" "$desc"
        continue
      fi
    fi
    # "created #12" / "exists 12" / "create" → action word and number.
    if [ -n "$after_fn" ]; then
      num="${res##*[ #]}"
      [ "$num" = "$res" ] && num=""
      "$after_fn" "$source" "$key" "$num" "${res%% *}" \
        || REPO_AUDIT_WRITE_FAILED=$((REPO_AUDIT_WRITE_FAILED + 1))
    fi
  done
}

# _repo_audit_group_labels <severity> — the audit's labels-fn cut to the kind's
# own label (its first, by the labels-fn contract): in grouping mode nothing
# gets a pickup label, not even a reopened single-finding issue.
_repo_audit_group_labels() {
  local l
  l=$("$_REPO_AUDIT_GROUP_LABELS_FN" "$1")
  printf '%s' "${l%%,*}"
}

# _repo_audit_group_jq — validates the grouping agent's plan against the
# candidates ($c) and builds the plan epic_write_plan writes. A rejected plan is
# a jq error() whose message is the reason. The bodies are built here, not by
# the agent, so the locations and the finding markers ($marker, with __FP__ for
# the fingerprint — the format stays finding_marker's) are exact.
# shellcheck disable=SC2016
_REPO_AUDIT_GROUP_JQ='
def rank: ({"critical": 4, "high": 3, "medium": 2, "low": 1}[ascii_downcase] // 0);
def sevname: (["unknown", "low", "medium", "high", "critical"][.]);
def strs: ((. // []) | if type == "array" then map(select(type == "string" and length > 0)) else [] end);
def acyclic:
  { left: map({id, deps: ((.depends_on // []) | unique)}), stuck: false }
  | until((.left | length) == 0 or .stuck;
      ([.left[] | select((.deps | length) == 0) | .id]) as $ready
      | if ($ready | length) == 0 then .stuck = true
        else .left |= (map(select(.id as $i | ($ready | index($i)) | not)) | map(.deps -= $ready)) end)
  | .stuck | not;

$c[0] as $cand
| ($cand | map({key: (.n | tostring), value: .}) | from_entries) as $byn
| if type != "object" or (.epics | type) != "array" or (.epics | length) == 0 then error("the plan has no epics") else . end
| if any(.epics[]; (.title | type) != "string" or .title == "" or (.groups | type) != "array" or (.groups | length) == 0)
  then error("an epic lacks a title or groups") else . end
| [.epics[].groups[]] as $groups
| if any($groups[]; (.id | type) != "string" or .id == "" or (.title | type) != "string" or .title == ""
                    or (.members | type) != "array" or (.members | length) == 0)
  then error("a group lacks an id, a title or members") else . end
| ($groups | map(.id)) as $ids
| if ($ids | unique | length) != ($ids | length) then error("group ids are not unique") else . end
| [$groups[].members[]] as $m
| if any($m[]; type != "number" or $byn[tostring] == null) then error("a member is not a finding number of this audit") else . end
| if ($m | length) != ($cand | length) or ($m | unique | length) != ($cand | length)
  then error("every finding must be in exactly one group") else . end
| if any($groups[]; (.depends_on // []) | type != "array") then error("depends_on is not a list") else . end
| if any($groups[]; .id as $g | (.depends_on // [])[] | . as $d | $d == $g or (($ids | index($d)) == null))
  then error("a dependency names no group of this plan, or the group itself") else . end
| if ($groups | acyclic) then . else error("the dependencies form a cycle") end

| ($groups | map({key: .id, value: .title}) | from_entries) as $gtitle
| .epics
| map(
    . as $e
    | (.groups | map(
        . as $g
        | ($g.members | map($byn[tostring])) as $mem
        | ($mem | map(.sev | rank) | max) as $r
        | ($prefix + " (" + ($r | sevname) + "): " + $g.title) as $title
        | {key: $g.id, title: $title, severity: ($r | sevname), rank: $r,
           labels: [$kind], blocked_by: (($g.depends_on // []) | unique),
           members: $mem,
           body: ("## Tavoite\n\n" + ($g.goal // $g.title)
                  + "\n\nOsa epiciä «" + $e.title + "». Löydökset tuotti koko repon auditointi (`" + $script
                  + "`), commit `" + $sha + "` (`" + $base + "`).\n\n## Löydökset\n\n"
                  + ($mem | map("- `" + .loc + "` — " + .sev + " (varmuus " + .conf + ") — " + .desc) | join("\n"))
                  + "\n\n## Toteutus\n\n" + ($g.implementation // "Korjaa yllä listatut löydökset yhtenä muutoksena.")
                  + "\n\n## Hyväksyntäkriteerit\n\n"
                  + ((($g.acceptance | strs) + ["Jokainen Löydökset-osion löydös on korjattu, tai PR-kuvaus perustelee, miksi löydös on väärä."])
                     | map("- [ ] " + .) | join("\n"))
                  + "\n\n## Rajaukset\n\n"
                  + ((($g.out_of_scope | strs)
                      + ["Vain tämän issuen löydökset. Saman auditoinnin muut korjausyksiköt ovat omia issueitaan.",
                         "Jos löydös osoittautuu vääräksi, älä muuta sitä koskevaa koodia: kirjaa perustelu PR-kuvaukseen. Jos koko issue on väärä, ihminen sulkee sen tilaan *not planned*, jolloin auditointi ei avaa sitä uudelleen."])
                     | map("- " + .) | join("\n"))
                  + "\n\n" + ($mem | map(.fp as $fp | $marker | sub("__FP__"; $fp)) | join("\n")) + "\n")
          })
        | sort_by(-.rank)) as $children
    | ($children | map(.rank) | max) as $r
    | {title: ($prefix + " (" + ($r | sevname) + "): " + $e.title), severity: ($r | sevname), rank: $r,
       labels: ["epic", $kind],
       overlaps: (($e.overlaps // []) | if type == "array" then map(select(type == "object" and (.issue | type) == "number")) else [] end),
       human_tasks: ($e.human_tasks | strs),
       children: $children}
    | . as $ep
    | .body = ("## Tavoite\n\n" + ($e.goal // $e.title)
               + "\n\nKoko repon auditoinnin (`" + $script + "`, commit `" + $sha + "`, `" + $base
               + "`) löydökset koottuna korjauksen kokoisiksi issueiksi. Epic ei käynnisty itsestään: ajoon vienti on ihmisen päätös (`/issue-runner:run-epic`).\n\n## Alaissuet\n\n"
               + ($ep.children | map("- " + .title + " — " + (.members | length | tostring) + " löydös(tä)"
                   + (if (.blocked_by | length) > 0 then "; odottaa: " + (.blocked_by | map($gtitle[.]) | join(", ")) else "" end))
                  | join("\n"))
               + "\n\n## Päällekkäisyydet avoimien issueiden kanssa\n\n"
               + (if ($ep.overlaps | length) == 0 then "Ei havaittuja."
                  else ($ep.overlaps | map("- #" + (.issue | tostring) + " — " + (.note // "")) | join("\n")) end)
               + "\n\n## Ihmisen tehtävät\n\n"
               + (if ($ep.human_tasks | length) == 0 then "Ei."
                  else ($ep.human_tasks | map("- [ ] " + .) | join("\n")) end)
               + "\n"))
| sort_by(-.rank)
| to_entries | map(.value + {key: ("epic-" + ((.key + 1) | tostring))})
| {kind: $kind, head_sha: $sha, epics: .}
'

# _repo_audit_group_md <plan-file> — the plan as markdown, for the operator.
_repo_audit_group_md() {
  jq -r '
    "# Ryhmittelysuunnitelma (\(.kind)): \([.epics[].children[].members[]] | length) löydöstä → \([.epics[].children[]] | length) issueta, \(.epics | length) epiciä",
    (.epics[] |
      "",
      "## \(.title)",
      (.children[] |
        "- \(.title) [\(.key)]\(if (.blocked_by | length) > 0 then " — odottaa: " + (.blocked_by | join(", ")) else "" end)",
        (.members[] | "  - `\(.loc)` — \(.sev) — \(.desc)")),
      (if (.overlaps | length) > 0 then "Päällekkäisyydet: " + (.overlaps | map("#\(.issue) (\(.note // ""))") | join("; ")) else empty end),
      (if (.human_tasks | length) > 0 then "Ihmisen tehtävät: " + (.human_tasks | join("; ")) else empty end))' "$1"
}

# repo_audit_group <kind> <write 0|1> <title-prefix> <reopen-comment> <key-fn>
#                  <labels-fn> <title-fn> <body-fn>
# The grouping mode (issue #396), run instead of repo_audit_apply: the
# findings are grouped into fix-sized issues and those into epics by severity,
# rather than one issue per finding. Reads the global FINDINGS (the rows
# repo_audit_apply reads) and the same functions, so a finding means the same in
# both modes.
#
# Which findings are grouped: only the ones finding_issue_plan says `create`
# and the verifier did not leave UNSURE — confirmed, new findings. A finding
# that already has an issue stays with it (exists / dismissed / reopen), and an
# UNSURE one is filed alone with its note; both go through repo_audit_apply as
# before, with the kind's label only. A group issue carries every member's
# finding marker and the kind's label, so the index of the next audit sees each
# member through it: open → exists, completed → reopen, not planned → dismissed.
#
# An agent (prompts/15-finding-group.md) proposes the grouping as JSON under the
# read-only gate; bash validates it fail-closed — every finding in exactly one
# group, dependencies only to groups of the plan, no cycle — and builds the
# bodies. <title-prefix> starts every title ("Tietoturva", …).
#
# <write> 0: prints the plan (markdown on stdout, the JSON path after it) and
# writes nothing. <write> 1: also writes it with epic_write_plan — epic, its
# children, the sub-issue links, then the dependencies; the epic gets `epic`
# and the kind's label, a group issue the kind's label, nothing gets a pickup
# label or an assignee. Running an epic stays a human's decision.
#
# Sets REPO_AUDIT_FINDINGS and REPO_AUDIT_WRITE_FAILED like repo_audit_apply.
# rc 3 (KEEP_WORK=1) when the agent cannot start, fails, changes the worktree
# or its plan is rejected — nothing is written then; rc 4 when listing the open
# issues failed.
repo_audit_group() {
  local kind="$1" write="$2" prefix="$3" comment="$4" key_fn="$5" labels_fn="$6" title_fn="$7" body_fn="$8"
  local row origin rest sev conf loc desc sk source key fp plan seen=" " n=0 pass="" dups=""
  local cand="$WORK/group.candidates.tsv" out_plan="$WORK/group-plan.json"
  local timeout="${RUN_ISSUES_AUDIT_GROUP_TIMEOUT:-1800}"
  local step="15-finding-group" total failed=0
  REPO_AUDIT_FINDINGS=0
  REPO_AUDIT_WRITE_FAILED=0
  _REPO_AUDIT_GROUP_LABELS_FN="$labels_fn"
  : > "$cand"

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    origin="${row%%|*}"; rest="${row#*|}"
    IFS='|' read -r sev conf loc desc <<<"$rest"
    desc="${rest#*|*|*|}"
    sk=$("$key_fn" "$origin" "$desc")
    source="${sk%%$'\t'*}"; key="${sk#*$'\t'}"
    fp=$(finding_fingerprint "$source" "$loc" "$key")
    REPO_AUDIT_FINDINGS=$((REPO_AUDIT_FINDINGS + 1))
    if [[ "$seen" == *" $fp "* ]]; then
      dups="${dups}duplicate"$'\t'"$sev"$'\t'"$loc"$'\t'"$desc"$'\n'
      continue
    fi
    seen="$seen$fp "
    plan=$(finding_issue_plan "$INDEX" "$kind" "$fp")
    if [ "$plan" = create ] && ! { [ -s "$WORK/verify.unsure" ] && grep -qxF -- "$row" "$WORK/verify.unsure"; }; then
      n=$((n + 1))
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$sev" "$conf" "$loc" "$(printf '%s' "$desc" | tr '\t' ' ')" "$fp" >> "$cand"
    else
      pass="$pass$row"$'\n'
    fi
  done <<<"$FINDINGS"
  total=$REPO_AUDIT_FINDINGS

  if [ "$n" -gt 0 ]; then
    local raw open_issues listing prompt arc=0 answer
    if ! raw=$(labels_gh api --paginate "repos/$OWNER_REPO/issues?state=open&per_page=100" 2>/dev/null); then
      repo_audit_say "listing the open issues of $OWNER_REPO failed — nothing written"
      return 4
    fi
    open_issues=$(printf '%s' "$raw" | jq -r '.[]? | select(.pull_request | not)
                    | "#\(.number) \(.title // "" | gsub("[\t\r\n]"; " "))"' 2>/dev/null | head -n 300)
    [ -n "$open_issues" ] || open_issues="Ei avoimia issueita."
    listing=$(awk -F'\t' '{ printf "%s | %s | %s | %s | %s\n", $1, $2, $3, $4, $5 }' "$cand")

    repo_audit_preflight || return 3
    prompt="$WORK/$step.prompt"
    if ! render_prompt "$_REPO_AUDIT_DIR/../prompts/$step.md" "$prompt" \
         REPO="$OWNER_REPO" HEAD_SHA="$HEAD_SHA" AUDIT_KIND="$kind" \
         FINDINGS="$listing" OPEN_ISSUES="$open_issues" || [ ! -s "$prompt" ]; then
      KEEP_WORK=1
      repo_audit_say "cannot render the grouping prompt — nothing written"
      return 3
    fi
    ( cd "$WT" && RUN_ISSUES_CLAUDE_TIMEOUT="$timeout" call_claude "$WORK" "$step" "$prompt" ) </dev/null >&2 || arc=$?
    repo_audit_say "grouping agent returned rc=$arc"
    repo_audit_readonly_check "grouping agent" || return 3
    if [ "$arc" -ne 0 ] || [ "$(awk 'NF { l = $0 } END { sub(/\r$/, "", l); print l }' "$WORK/$step.out" 2>/dev/null)" != "GROUP_RESULT: OK" ]; then
      KEEP_WORK=1
      repo_audit_say "the grouping agent gave no result (rc=$arc; 127 = did not start, 124 = timeout; or no final GROUP_RESULT: OK line) — nothing written"
      return 3
    fi
    # The last ```json block of the answer.
    answer=$(tr -d '\r' < "$WORK/$step.out" | awk '
      /^[[:space:]]*```json[[:space:]]*$/ { buf = ""; inb = 1; next }
      inb && /^[[:space:]]*```[[:space:]]*$/ { inb = 0; last = buf; got = 1; next }
      inb { buf = buf $0 "\n" }
      END { if (got) printf "%s", last }')
    jq -R -s 'split("\n") | map(select(length > 0) | split("\t")
               | {n: (.[0] | tonumber), sev: .[1], conf: .[2], loc: .[3], desc: .[4], fp: .[5]})' \
      "$cand" > "$WORK/group.candidates.json"
    local err
    if ! err=$(printf '%s' "$answer" | jq --slurpfile c "$WORK/group.candidates.json" \
                 --arg kind "$kind" --arg prefix "$prefix" --arg sha "$HEAD_SHA" --arg base "$BASE_REF" \
                 --arg script "${REPO_AUDIT_NAME:-audit}.sh" --arg marker "$(finding_marker "$kind" __FP__)" \
                 "$_REPO_AUDIT_GROUP_JQ" 2>&1 > "$out_plan") || [ ! -s "$out_plan" ]; then
      KEEP_WORK=1
      repo_audit_say "grouping plan rejected: $(printf '%s' "${err:-no JSON block}" | sed -E 's/^jq: error \(at [^)]*\): //' | head -n 1) — nothing written"
      return 3
    fi
  fi

  # What is not grouped keeps its single-finding path.
  if [ -n "$pass" ] || [ -n "$dups" ]; then
    printf '# Ennallaan (ei ryhmitelty)\n'
    printf '%s' "$dups"
    if [ -n "$pass" ]; then
      repo_audit_apply "$kind" "$((1 - write))" "$comment" "$key_fn" _repo_audit_group_labels "$title_fn" "$body_fn" <<<"$pass"
      failed=$REPO_AUDIT_WRITE_FAILED
    fi
    printf '\n'
  fi
  REPO_AUDIT_FINDINGS=$total
  REPO_AUDIT_WRITE_FAILED=$failed

  if [ "$n" -eq 0 ]; then
    printf 'grouping: no new confirmed findings to group\n'
    return 0
  fi

  _repo_audit_group_md "$out_plan"
  local keep
  if keep=$(mktemp "${TMPDIR:-/tmp}/${REPO_AUDIT_NAME:-audit}-group-plan.XXXXXX") && cp "$out_plan" "$keep"; then
    printf '\nplan JSON: %s\n' "$keep"
  else
    repo_audit_say "cannot keep a copy of the plan JSON"
  fi

  [ "$write" = 1 ] || return 0
  printf '\n# Kirjoitus\n'
  : > "$WORK/group.ledger"
  if ! epic_write_plan "$OWNER_REPO" "$out_plan" "$WORK/group.ledger"; then
    REPO_AUDIT_WRITE_FAILED=$((REPO_AUDIT_WRITE_FAILED + 1))
  fi
  return 0
}

# repo_audit_poller_env_value <var> — one variable out of poller.env
# (RUN_ISSUES_POLLER_ENV_FILE, default $HOME/.config/run-issues/poller.env),
# read in a subshell so nothing else in the file reaches this process (the
# same pattern as install.sh's poller_env_values). The poller runs an audit
# under that file, so a hand run and a scheduled run of one machine agree.
repo_audit_poller_env_value() {
  local f="${RUN_ISSUES_POLLER_ENV_FILE:-$HOME/.config/run-issues/poller.env}"
  ( exec 3>&1 >/dev/null 2>&1; set +eu; unset "$1"; [ -f "$f" ] && . "$f"; printf '%s' "${!1:-}" >&3 )
}
