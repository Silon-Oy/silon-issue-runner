#!/usr/bin/env bash
# evolution-digest.sh — a read-only report of what the evolution step kept
# finding across runs, grouped into recurring topics (issue #315).
#
# Every run's evolution step (S9) writes its verdict into <run-dir>/03-evolution.out:
# a FIXED line (evolution fixed what the implementer left undone), a
# NEEDS_FOLLOWUP line (it left something unfixed) and zero or more Δψ lines
# (structural problems it saw outside the PR's scope). Each one lands in ONE PR
# description and is never seen again next to its siblings. A finding that
# recurs twice is a signal that the implementer's instructions or the target
# repo's CLAUDE.md are missing a rule — or that a structural problem deserves an
# issue of its own. This script closes that loop by putting them side by side.
#
# A fourth kind comes from outside the run-dirs: with --escapes, the runner-class
# locations of an `escape-trace.sh --json` document become ESCAPE findings — a
# defect found in main later whose line a runner PR last changed (issue #390).
# The file is the user's own material: it is read as is, with no window, and
# never produced here (escape-trace.sh calls gh; this script does not).
#
# READ-ONLY, by contract: it writes nothing to any repo nor to GitHub and makes no
# gh call. The only output is the report (stdout, or --out <file>). Run it by
# hand; there is deliberately no LaunchAgent for it.
#
# Cost (CLAUDE.md §5.3 / §5.4): state.jsonl is never opened. Runs are found from
# the watchlist repos' live and archived run-dirs; run.json files outside the
# window are dropped by mtime (a stat, not a read — run.json is rewritten at
# finalize and later, so its mtime is never older than the run's end), then by
# the run's own finished_at/started_at. Only runs in the window are read.
#
# Grouping. Without --claude the grouping is DETERMINISTIC: findings are keyed by
# the files and backticked identifiers they mention, and a key shared by at least
# --min-count distinct runs is a recurring topic. The suggested target follows
# from the group's shape:
#   * any ESCAPE finding                 → a stage's prompt or a merge gate (a
#                                           runner run let the defect into main)
#   * more than one repo                 → the implementer prompt
#   * one repo, evolution FIXED it        → that repo's CLAUDE.md (a convention
#                                           the implementer does not know)
#   * one repo, only unfixed / Δψ         → a new issue (a structural defect,
#                                           not a missing instruction)
# Tooling-class Δψ findings (issue #392: test environment, provisioning, the
# runner itself) form their own lane: they are grouped apart from the rest even
# when they mention the same file, and their target is always the target repo's
# test environment / provisioning hook or the runner package.
# Findings are ordered by timestamp, ties broken by repo, issue and run id.
# With --claude (opt-in) the findings and the mechanical groups are handed to one
# call_claude call that groups by MEANING; on failure the deterministic report is
# printed instead (exit 3).
#
# Usage:
#   evolution-digest.sh [--since <days>] [--min-count <n>] [--repo <path>]
#                       [--watchlist <path>] [--escapes <file>] [--json]
#                       [--claude] [--out <file>]
#
#   --since <days>     window in days, measured from the run's finished_at
#                      (fallback started_at). Default 30.
#   --min-count <n>    distinct runs a topic needs to count as recurring (>= 2).
#                      Default 2.
#   --repo <path>      restrict to one watchlist repo path.
#   --watchlist <path> watchlist override (poller semantics: the ONLY candidate).
#   --escapes <file>   an `escape-trace.sh --json` document; its runner-class
#                      locations join the findings as kind ESCAPE (one runner
#                      PR = one run). With --repo, a document of another repo
#                      is skipped.
#   --json             machine output: { window_days, min_count, findings[],
#                      groups[] }. Not combinable with --claude.
#   --claude           group with one Claude call (opt-in; costs a call).
#   --out <file>       write the report to <file> instead of stdout.
#
# Exit codes (own space):
#   0  report produced (also when there are no findings)
#   1  usage error (unknown flag / bad value), --escapes is not a readable
#      escape-trace JSON document, or --out is not writable
#   2  no watchlist, no readable repo on disk, or jq missing
#   3  --claude grouping failed — the deterministic report was produced instead
#
# Env:
#   RUN_ISSUES_WATCHLIST                watchlist override (poller semantics)
#   RUN_ISSUES_EVOLUTION_DIGEST_DAYS    default --since (30)
#   RUN_ISSUES_EVOLUTION_DIGEST_MIN     default --min-count (2)
#   RUN_ISSUES_CLAUDE_CMD and the rest of lib/claude-call.sh's settings apply to
#   --claude; the machine env file is sourced for it like orchestrate.sh does
#   (lib/machine-env.sh, caller wins in RUN_ISSUES_*).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Snapshot the caller's environment before any library assigns defaults
# (lib/machine-env.sh, issue #200) — only consulted under --claude.
# shellcheck source=lib/machine-env.sh
. "$SCRIPT_DIR/lib/machine-env.sh"
machine_env_capture
# Windows/Git Bash: LF jq output (lib/jq-binary.sh).
# shellcheck source=lib/jq-binary.sh
. "$SCRIPT_DIR/lib/jq-binary.sh"

# shellcheck source=lib/poller-config.sh
. "$SCRIPT_DIR/lib/poller-config.sh"
# shellcheck source=lib/status-read.sh
. "$SCRIPT_DIR/lib/status-read.sh"
# shellcheck source=lib/evolution-findings.sh
. "$SCRIPT_DIR/lib/evolution-findings.sh"

die_usage() { printf 'evolution-digest.sh: %s\n' "$1" >&2; exit 1; }

SINCE_DAYS="${RUN_ISSUES_EVOLUTION_DIGEST_DAYS:-30}"
MIN_COUNT="${RUN_ISSUES_EVOLUTION_DIGEST_MIN:-2}"
REPO_FILTER=""
WATCHLIST_OVERRIDE="${RUN_ISSUES_WATCHLIST:-}"
JSON_MODE=0
CLAUDE_MODE=0
OUT_FILE=""
ESCAPES_FILE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --since)     shift; [ "$#" -gt 0 ] || die_usage "--since needs a value"; SINCE_DAYS="$1" ;;
    --min-count) shift; [ "$#" -gt 0 ] || die_usage "--min-count needs a value"; MIN_COUNT="$1" ;;
    --repo)      shift; [ "$#" -gt 0 ] || die_usage "--repo needs a value"; REPO_FILTER="$1" ;;
    --watchlist) shift; [ "$#" -gt 0 ] || die_usage "--watchlist needs a value"; WATCHLIST_OVERRIDE="$1" ;;
    --escapes)   shift; [ "$#" -gt 0 ] || die_usage "--escapes needs a value"; ESCAPES_FILE="$1" ;;
    --json)      JSON_MODE=1 ;;
    --claude)    CLAUDE_MODE=1 ;;
    --out)       shift; [ "$#" -gt 0 ] || die_usage "--out needs a value"; OUT_FILE="$1" ;;
    -h|--help)   sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die_usage "unknown argument: $1" ;;
  esac
  shift
done

case "$SINCE_DAYS" in ''|*[!0-9]*) die_usage "--since must be a positive integer (days)" ;; esac
[ "$SINCE_DAYS" -ge 1 ] || die_usage "--since must be a positive integer (days)"
case "$MIN_COUNT" in ''|*[!0-9]*) die_usage "--min-count must be an integer >= 2" ;; esac
[ "$MIN_COUNT" -ge 2 ] || die_usage "--min-count must be an integer >= 2"
if [ "$JSON_MODE" = 1 ] && [ "$CLAUDE_MODE" = 1 ]; then
  die_usage "--json and --claude are mutually exclusive"
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'evolution-digest.sh: jq is required but not installed\n' >&2
  exit 2
fi

if [ -n "$ESCAPES_FILE" ]; then
  [ -f "$ESCAPES_FILE" ] && [ -r "$ESCAPES_FILE" ] || die_usage "--escapes file not readable: $ESCAPES_FILE"
  jq -e '(.locations | type == "array") and (.repo | type == "string")' "$ESCAPES_FILE" >/dev/null 2>&1 \
    || die_usage "--escapes is not an escape-trace.sh --json document: $ESCAPES_FILE"
fi

CONFIG_WL="$HOME/.config/run-issues/watchlist.json"
LEGACY_WL="$HOME/dotfiles/machine-studio/run-issues-watchlist.json"
if ! WATCHLIST="$(poller_resolve_watchlist "$WATCHLIST_OVERRIDE" "$CONFIG_WL" "$LEGACY_WL")"; then
  if [ -n "$WATCHLIST_OVERRIDE" ]; then
    printf 'evolution-digest.sh: watchlist override not found: %s\n' "$WATCHLIST_OVERRIDE" >&2
  else
    printf 'evolution-digest.sh: no watchlist found (looked at %s and %s)\n' "$CONFIG_WL" "$LEGACY_WL" >&2
  fi
  exit 2
fi

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/evolution-digest.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

NOW=$(date -u +%s)
CUTOFF=$((NOW - SINCE_DAYS * 86400))
FINDINGS_JSONL="$TMPD/findings.jsonl"
: > "$FINDINGS_JSONL"

# ---- collect findings from live and archived run-dirs ----
REPOS_SCANNED=0
RUNS_READ=0
while IFS= read -r rp; do
  [ -n "$rp" ] || continue
  if [ -n "$REPO_FILTER" ] && [ "$rp" != "$REPO_FILTER" ]; then continue; fi
  [ -d "$rp" ] || continue
  REPOS_SCANNED=$((REPOS_SCANNED + 1))
  repo_label="$(basename "$rp")"
  for base in "$rp/.claude/run-issues" "$rp/.claude/run-issues-archive"; do
    [ -d "$base" ] || continue
    # mtime prefilter: one day of slack so the exact timestamp test decides.
    while IFS= read -r rj; do
      [ -n "$rj" ] || continue
      rd="$(dirname "$rj")"
      evo_out="$rd/03-evolution.out"
      [ -f "$evo_out" ] || continue
      meta=$(jq -r '[(.run_id // ""), ((.issue_number // "") | tostring),
                     (.finished_at // .started_at // "")] | @tsv' "$rj" 2>/dev/null) || continue
      IFS=$'\t' read -r run_id issue at <<EOF
$meta
EOF
      at_epoch=$(_iso_to_epoch "$at")
      [ -n "$at_epoch" ] || continue
      [ "$at_epoch" -ge "$CUTOFF" ] || continue
      RUNS_READ=$((RUNS_READ + 1))
      while IFS=$'\t' read -r kind class text; do
        [ -n "$kind" ] || continue
        jq -nc --arg repo "$repo_label" --arg issue "$issue" --arg run_id "${run_id:-$(basename "$rd")}" \
          --arg at "$at" --arg kind "$kind" --arg class "$class" --arg text "$text" \
          '{repo: $repo, issue: $issue, run_id: $run_id, at: $at, kind: $kind,
            class: (if $class == "-" then null else $class end), text: $text}' \
          >> "$FINDINGS_JSONL"
      done <<EOF
$(evolution_findings "$evo_out")
EOF
    done <<EOF
$(find "$base" -mindepth 2 -maxdepth 2 -name run.json -mtime "-$((SINCE_DAYS + 1))" 2>/dev/null)
EOF
  done
done <<EOF
$(jq -r '.repos[]?.path // empty' "$WATCHLIST" 2>/dev/null)
EOF

if [ "$REPOS_SCANNED" -eq 0 ]; then
  printf 'evolution-digest.sh: no readable repo on disk (watchlist=%s)\n' "$WATCHLIST" >&2
  exit 2
fi

# ---- ESCAPE findings from an escape-trace.sh --json document ----
# Same schema as the run-dir findings, so grouping and rendering need no second
# path. The path sits in backticks so keys_of groups by file, not by line; at is
# empty (escape-trace has no run timestamp), so these sort first. The repo filter
# compares in bash, not in jq (CLAUDE.md §5.8: a path crossing into jq changes).
if [ -n "$ESCAPES_FILE" ]; then
  esc_repo="$(jq -r '.repo' "$ESCAPES_FILE")"
  if [ -z "$REPO_FILTER" ] || [ "$esc_repo" = "$REPO_FILTER" ]; then
    jq -c '
      (.repo | sub("/+$"; "") | sub(".*/"; "")) as $repo
      | .locations[] | select(.class == "runner")
      | (.location | capture("^(?<path>.*):(?<line>[^:]*)$")) as $l
      | (if .pr == "-" then "runner-ajo" else "runner-PR #\(.pr)" end) as $by
      | {repo: $repo, issue: (.issue | ltrimstr("#")),
         run_id: (if .pr == "-" then "issue-\(.issue)" else "pr-\(.pr)" end),
         at: "", kind: "ESCAPE",
         text: "`\($l.path)` rivi \($l.line) — löydös \(.source), \($by) (\(.method))"}
    ' "$ESCAPES_FILE" >> "$FINDINGS_JSONL"
  fi
fi

# ---- deterministic grouping ----
# Keys: backticked spans, plus file-like words (a slash, or a known extension).
# Groups with the same member run set are merged so one recurrence that touches
# three files is one topic, not three. Both steps are per lane, so a tooling
# finding never joins a product topic.
# Order: by at, ties broken by repo, issue and run_id, so the output does not
# depend on find's order or on live-before-archive. sort_by is stable, so one
# run's findings keep the parser's order.
DOC="$TMPD/doc.json"
jq -s --argjson days "$SINCE_DAYS" --argjson min "$MIN_COUNT" '
  def keys_of:
    ([scan("`[^`]+`") | ltrimstr("`") | rtrimstr("`")]
     + [scan("[A-Za-z0-9_.-]*/[A-Za-z0-9_./-]+|[A-Za-z0-9_.-]+\\.(?:sh|md|json|ya?ml|php|js|mjs|ts|tsx|py|css|scss|plist|toml)\\b")])
    | map(sub("[.,:;]+$"; "")) | map(select(length > 1)) | unique;
  def lane: if .class == "tooling" then "tooling" else "product" end;
  def target:
    if any(.findings[]; .kind == "ESCAPE") then "stage_or_gate"
    elif .lane == "tooling" then "test_env_or_runner"
    elif (.repos | length) > 1 then "implementer_prompt"
    elif any(.findings[]; .kind == "FIXED") then "repo_claude_md"
    else "new_issue" end;
  (sort_by([.at, .repo, (.issue | tonumber? // -1), .issue, .run_id]) | to_entries | map(.value + {id: .key, class: (.value.class // null)})) as $f
  | ([ $f[] | . as $x | (.text | keys_of)[] | {lane: ($x | lane), key: ., id: $x.id} ]
     | group_by([.lane, .key])
     | map({lane: .[0].lane, key: .[0].key, ids: (map(.id) | unique)})
     | map(. + {runs: ([.ids[] as $i | $f[$i].run_id] | unique)})
     | map(select((.runs | length) >= $min))
     | group_by([.lane, .ids])
     | map({lane: .[0].lane, keys: (map(.key) | unique), ids: .[0].ids, runs: .[0].runs})
     | map({
         lane,
         keys,
         run_count: (.runs | length),
         repos: ([.ids[] as $i | $f[$i].repo] | unique),
         findings: [.ids[] as $i | $f[$i] | del(.id)]
       } | . + {target: target})
     | sort_by(-.run_count, .keys[0])) as $groups
  | ([$groups[].findings[] | [.run_id, .kind, .class, .text]] ) as $grouped
  | { window_days: $days, min_count: $min,
      findings: [$f[] | del(.id)],
      groups: $groups,
      ungrouped: [$f[] | del(.id) | select([.run_id, .kind, .class, .text] as $k | any($grouped[]; . == $k) | not)] }
' "$FINDINGS_JSONL" > "$DOC" || { printf 'evolution-digest.sh: grouping failed\n' >&2; exit 2; }

# ---- report rendering ----
render_human() {
  jq -r --argjson repos "$REPOS_SCANNED" --argjson runs "$RUNS_READ" '
    def kind_fi: ({FIXED: "korjattu", NEEDS_FOLLOWUP: "jatkotoimi", DELTA_PSI: "Δψ", ESCAPE: "läpi päässyt"}[.kind] // .kind)
      + (if .kind == "DELTA_PSI" and .class != null then "/\(.class)" else "" end);
    def target_fi:
      if .target == "stage_or_gate" then "vaiheen prompti tai merge-portti (cycle review, toteutus, Evolution, tietoturva- tai semanttinen portti) — runnerin ajo päästi vian mainiin"
      elif .target == "test_env_or_runner" then "kohderepon testiympäristö tai provisiointi (`.claude/provision-test-env.sh`, \(.repos | join(", "))) tai runnerin paketti — toistuva ympäristökitka"
      elif .target == "implementer_prompt" then "Implementerin prompti (prompts/02-implementer.md) — toistuu \(.repos | length) repossa"
      elif .target == "repo_claude_md" then "kohderepon CLAUDE.md (\(.repos[0])) — Evolution korjasi saman asian toistuvasti"
      else "uusi issue (\(.repos[0])) — korjaamaton rakenteellinen havainto" end;
    def row: "  - \(.repo)#\(.issue) (\(kind_fi)): \(.text)";
    def topics($lane; $title):
      ([.groups[] | select(.lane == $lane)]) as $g
      | "## Toistuvat aiheet — \($title)",
        "",
        (if ($g | length) == 0 then "Ei toistuvia aiheita.", ""
         else ($g[] |
           "### \(.keys | map("`\(.)`") | join(", ")) — \(.run_count) ajoa",
           "Ehdotettu kohde: \(target_fi)",
           (.findings[] | row),
           "")
         end);
    "# Evolutionin havaintojen kooste",
    "",
    "Jakso: \(.window_days) vrk · repoja: \($repos) · ajoja jaksossa: \($runs) · havaintoja: \(.findings | length)",
    "Toistuvaksi lasketaan aihe, joka esiintyy vähintään \(.min_count) eri ajossa. Ryhmittely on mekaaninen (mainitut tiedostot ja tunnisteet); --claude ryhmittelee merkityksen perusteella.",
    "",
    topics("product"; "tuote"),
    topics("tooling"; "testiympäristö ja runner"),
    "## Muut havainnot",
    "",
    (if (.ungrouped | length) == 0 then "Ei muita havaintoja."
     else (.ungrouped | group_by(.repo)[] | "### \(.[0].repo)", (.[] | row), "") end)
  ' "$DOC"
}

# emit can fail (unwritable --out); with pipefail the pipeline reports it.
emit() {
  if [ -n "$OUT_FILE" ]; then
    cat > "$OUT_FILE" || { printf 'evolution-digest.sh: cannot write %s\n' "$OUT_FILE" >&2; return 1; }
  else
    cat
  fi
}

if [ "$JSON_MODE" = 1 ]; then
  jq '. + {repos_scanned: $repos, runs_read: $runs}' \
    --argjson repos "$REPOS_SCANNED" --argjson runs "$RUNS_READ" "$DOC" | emit || exit 1
  exit 0
fi

if [ "$CLAUDE_MODE" = 0 ]; then
  render_human | emit || exit 1
  exit 0
fi

# ---- --claude: one call, in an empty scratch directory ----
# No findings means there is nothing to group — do not spend a call on it.
if [ "$(jq '.findings | length' "$DOC")" -eq 0 ]; then
  render_human | emit || exit 1
  exit 0
fi

# Like orchestrate.sh: the machine env file may name the CLI (caller wins in
# RUN_ISSUES_*). claude-call.sh carries `set -e`; this script does not.
source_machine_env
# shellcheck source=lib/claude-call.sh
. "$SCRIPT_DIR/lib/claude-call.sh"
set +e

CALL_DIR="$TMPD/call"
mkdir -p "$CALL_DIR"
PROMPT="$CALL_DIR/evolution-digest.prompt"
render_prompt "$SCRIPT_DIR/prompts/evolution-digest.md" "$PROMPT" \
  "WINDOW_DAYS=$SINCE_DAYS" \
  "MIN_COUNT=$MIN_COUNT" \
  "DETERMINISTIC_GROUPS=$(render_human)" \
  "FINDINGS_JSON=$(jq '.findings' "$DOC")"

rc=0
( cd "$CALL_DIR" && call_claude "$CALL_DIR" "evolution-digest" "$PROMPT" ) >/dev/null 2>"$CALL_DIR/call.log" || rc=$?
if [ "$rc" = 0 ] && [ -s "$CALL_DIR/evolution-digest.out" ]; then
  {
    printf '# Evolutionin havaintojen kooste (Claude-ryhmittely)\n\n'
    printf 'Jakso: %s vrk · ajoja jaksossa: %s · havaintoja: %s\n\n' \
      "$SINCE_DAYS" "$RUNS_READ" "$(jq '.findings | length' "$DOC")"
    cat "$CALL_DIR/evolution-digest.out"
  } | emit || exit 1
  exit 0
fi

printf 'evolution-digest.sh: Claude grouping failed (rc=%s) — printing the deterministic report\n' "$rc" >&2
render_human | emit || exit 1
exit 3
