#!/usr/bin/env bash
# lib/merge-gate.sh — the generic merge gate's pure parts (issue #334).
#
# A merge gate is an agent review that runs on a PR's FINAL head, right before
# pr-watch.sh merges it — after every rebase, conflict resolution and CI repair
# the watcher's own agents may have made. The mechanism is gate-agnostic: the
# result format, the head-SHA bookkeeping, the attempt cap and the severity
# threshold are the same for every gate; a gate contributes only its prompts, its
# switch and its config key. Security is the first gate, semantic
# (lib/semantic-gate.sh) the second; the caller in
# pr-watch.sh (pr_run_merge_gate) drives the review/fix loop and the hold.
#
# Result format every gate prompt must produce (scoped to the END of the output,
# the same narrow-matching rule lib/claude-call.sh applies to its markers):
#
#   FINDING: <severity> | <confidence> | <location> | <description>
#   ...
#   MERGE_GATE_RESULT: CLEAN | FINDINGS
#
#   severity   ∈ critical, high, medium, low
#   confidence ∈ high, medium, low
#
# Everything that is not a well-formed result is launch_failed — never clean.
# A missing/empty output, a non-zero exit, a missing marker, a FINDINGS marker
# without a single FINDING line, a CLEAN marker WITH finding lines, or one
# malformed FINDING line all mean "the review did not happen in a form we can
# trust" (CLAUDE.md §9: a launch failure is never reported as a result).
#
# Sourced; defines functions only and does no top-level work.

# How many lines of state.jsonl's TAIL the gate reads (CLAUDE.md §5.3: the file
# is never read whole). A lost record fails SAFE: the head is reviewed again and
# the fix cap restarts — extra cost, never a skipped review.
PR_WATCH_GATE_TAIL_LINES="${PR_WATCH_GATE_TAIL_LINES:-1000}"

MERGE_GATE_SEVERITIES="critical high medium low"

# merge_gate_severity_rank <severity> — 4 critical … 1 low; rc 1 on anything else.
merge_gate_severity_rank() {
  case "$1" in
    critical) printf '4' ;;
    high)     printf '3' ;;
    medium)   printf '2' ;;
    low)      printf '1' ;;
    *) return 1 ;;
  esac
}

# _merge_gate_result_lines <out-file> — the output with trailing blank lines and
# bare code fences dropped, so a result wrapped in ``` still ends on its marker.
_merge_gate_result_lines() {
  sed -e 's/[[:space:]]*$//' "$1" 2>/dev/null \
    | awk '{ lines[NR] = $0 } END {
        n = NR
        while (n > 0 && (lines[n] == "" || lines[n] ~ /^`+[a-z]*$/)) n--
        for (i = 1; i <= n; i++) print lines[i]
      }'
}

# merge_gate_findings <out-file> — prints every FINDING line normalised to
# "severity|confidence|location|description" (lower-cased enums, trimmed
# fields). rc 1 if any FINDING line is malformed: a finding we cannot rank is not
# a finding we may ignore.
merge_gate_findings() {
  local f="$1"
  [ -s "$f" ] || return 0
  # `|| true`: no FINDING line is a valid answer, and under the caller's
  # pipefail grep's rc 1 would otherwise read as a malformed finding.
  { grep -E '^[[:space:]]*FINDING:' "$f" 2>/dev/null || true; } | awk -v sevs="$MERGE_GATE_SEVERITIES" '
    function trim(s) { gsub(/^[ \t`*]+|[ \t`*]+$/, "", s); return s }
    BEGIN { split(sevs, a, " "); for (i in a) okSev[a[i]] = 1
            okConf["high"] = 1; okConf["medium"] = 1; okConf["low"] = 1; bad = 0 }
    {
      line = $0
      sub(/^[ \t]*FINDING:[ \t]*/, "", line)
      n = split(line, p, "|")
      if (n < 4) { bad = 1; next }
      sev = tolower(trim(p[1])); conf = tolower(trim(p[2])); loc = trim(p[3])
      desc = p[4]; for (i = 5; i <= n; i++) desc = desc "|" p[i]
      desc = trim(desc)
      if (!(sev in okSev) || !(conf in okConf) || desc == "") { bad = 1; next }
      print sev "|" conf "|" loc "|" desc
    }
    END { exit bad }'
}

# merge_gate_parse <out-file> [<exit-file>] — prints exactly one of
# clean | findings | launch_failed (see the header for the rules).
merge_gate_parse() {
  local out="$1" exit_file="${2:-}"
  if [ -n "$exit_file" ]; then
    local rc
    rc=$(tr -dc '0-9' < "$exit_file" 2>/dev/null || true)
    if [ "${rc:-1}" != "0" ]; then printf 'launch_failed'; return 0; fi
  fi
  [ -s "$out" ] || { printf 'launch_failed'; return 0; }

  local last marker
  last=$(_merge_gate_result_lines "$out" | tail -n 1)
  marker=$(printf '%s' "$last" | sed -nE 's/^[[:space:]`*]*MERGE_GATE_RESULT:[[:space:]]*([A-Za-z]+)[[:space:]`*]*$/\1/p')

  local findings count frc=0
  findings=$(merge_gate_findings "$out") || frc=$?
  [ "$frc" -eq 0 ] || { printf 'launch_failed'; return 0; }
  count=$(printf '%s' "$findings" | grep -c . || true)

  case "$marker" in
    CLEAN)    [ "${count:-0}" -eq 0 ] && printf 'clean' || printf 'launch_failed' ;;
    FINDINGS) [ "${count:-0}" -gt 0 ] && printf 'findings' || printf 'launch_failed' ;;
    *)        printf 'launch_failed' ;;
  esac
}

# merge_gate_holding <min-severity> <normalised-findings> — the findings
# (merge_gate_findings output) that reach the hold threshold, one per line.
merge_gate_holding() {
  local min="$1" findings="$2" min_rank sev r line
  min_rank=$(merge_gate_severity_rank "$min") || min_rank=1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    sev="${line%%|*}"
    r=$(merge_gate_severity_rank "$sev") || r=4
    if [ "$r" -ge "$min_rank" ]; then printf '%s\n' "$line"; fi
  done <<<"$findings"
}

# merge_gate_hold_min <repo-config-json> <gate> <machine-value> — the hold
# threshold. The REPO's `.<gate>.hold_min_severity` wins over the machine value,
# which wins over the default `high`: the threshold is a property of the
# application, not of whichever machine happens to watch it (the deliberate
# exception to CLAUDE.md §8 "caller wins"; docs/env-reference.md).
#
# The caller passes the config as read from the PR's BASE branch, never from its
# head: a PR must not be able to lower the gate that reviews it.
#
# Fail-closed: an unparseable config or an unknown value resolves to `low`, the
# strictest threshold, with a warning on stderr.
merge_gate_hold_min() {
  local cfg="$1" gate="$2" machine="$3" repo_val=""
  if [ -n "$cfg" ]; then
    if ! repo_val=$(jq -r --arg g "$gate" '.[$g].hold_min_severity // empty' <<<"$cfg" 2>/dev/null); then
      echo "merge-gate: .claude/run-issues.json on the base branch is not valid JSON — $gate hold threshold falls back to the strictest (low)" >&2
      printf 'low'
      return 0
    fi
  fi
  local val="${repo_val:-${machine:-high}}"
  val=$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')
  if merge_gate_severity_rank "$val" >/dev/null; then
    printf '%s' "$val"
  else
    echo "merge-gate: unknown $gate hold_min_severity '$val' (want one of: $MERGE_GATE_SEVERITIES) — using the strictest (low)" >&2
    printf 'low'
  fi
}

# merge_gate_last_result <state-jsonl> <gate> <sha> [<base-sha>] — "<result>
# <holding>" of the most recent merge_gate_reviewed event for this gate and head,
# or nothing. With <base-sha>, only a review recorded against that base counts
# (a gate whose verdict depends on the base, issue #341).
merge_gate_last_result() {
  local jsonl="$1" gate="$2" sha="$3" base="${4:-}"
  [ -f "$jsonl" ] || return 0
  tail -n "$PR_WATCH_GATE_TAIL_LINES" "$jsonl" 2>/dev/null \
    | jq -Rrn --arg g "$gate" --arg s "$sha" --arg b "$base" '
        [inputs | fromjson? | select(.event == "merge_gate_reviewed" and .data.gate == $g and .data.sha == $s)
                            | select($b == "" or .data.base_sha == $b)]
        | last | if . == null then empty else "\(.data.result) \(.data.holding // "0")" end' \
        2>/dev/null || true
}

# merge_gate_attempts <state-jsonl> <gate> — fix attempts recorded for this gate.
# Lines are parsed one by one (fromjson?): one torn line must not zero the count.
merge_gate_attempts() {
  local jsonl="$1" gate="$2" n
  [ -f "$jsonl" ] || { printf '0'; return 0; }
  n=$(tail -n "$PR_WATCH_GATE_TAIL_LINES" "$jsonl" 2>/dev/null \
    | jq -Rrn --arg g "$gate" '[inputs | fromjson? | select(.event == "merge_gate_fix_attempted" and .data.gate == $g)] | length' \
        2>/dev/null) || n=0
  printf '%s' "${n:-0}"
}

# merge_gate_trigger_failures <state-jsonl> <gate> — how many PERMANENT trigger
# failures (pr_watch_skipped reason=gate_trigger_failed kind=permanent) this gate
# has recorded in a row. Any later merge_gate_* event of the gate (a review, a
# pass without one, a hold) resets the count; transient failures neither count
# nor reset it, so a flaky network between two 404s does not hide the repeat.
merge_gate_trigger_failures() {
  local jsonl="$1" gate="$2" n
  [ -f "$jsonl" ] || { printf '0'; return 0; }
  n=$(tail -n "$PR_WATCH_GATE_TAIL_LINES" "$jsonl" 2>/dev/null \
    | jq -Rrn --arg g "$gate" '
        reduce (inputs | fromjson? | select(.data.gate == $g)) as $e (0;
          if ($e.event | startswith("merge_gate_")) then 0
          elif $e.event == "pr_watch_skipped" and $e.data.reason == "gate_trigger_failed"
               and $e.data.kind == "permanent" then . + 1
          else . end)' 2>/dev/null) || n=0
  printf '%s' "${n:-0}"
}

# merge_gate_format_findings <normalised-findings> — a Markdown list for a PR
# comment, most severe first.
merge_gate_format_findings() {
  local findings="$1"
  printf '%s\n' "$findings" | awk -F'|' '
    NF >= 4 {
      r = ($1 == "critical") ? 4 : ($1 == "high") ? 3 : ($1 == "medium") ? 2 : 1
      desc = $4; for (i = 5; i <= NF; i++) desc = desc "|" $i
      loc = ($3 == "") ? "" : " `" $3 "`"
      printf "%d\t- **%s** (varmuus: %s)%s — %s\n", r, $1, $2, loc, desc
    }' | sort -t "$(printf '\t')" -k1,1nr -s | cut -f2-
}
