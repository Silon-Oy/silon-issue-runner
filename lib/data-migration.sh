#!/usr/bin/env bash
# lib/data-migration.sh — deterministic detection of a data-destroying change in
# a diff (issue #409).
#
# A runner PR once merged a backfill migration that emptied a column of customer
# data; recovery depended on a backup. Neither agent merge gate looks for that
# (security looks for vulnerabilities, semantic for duplicates), so this scanner
# reads the ADDED lines of the migration files a diff touches and reports every
# statement that can destroy data: DROP COLUMN, DROP TABLE, TRUNCATE, DELETE,
# UPDATE and ALTER … TYPE.
#
# The detection is deliberately coarse — no SQL parsing, no ORM knowledge. A
# false alarm costs one human review; a miss costs data. `ON DELETE CASCADE` in a
# new table therefore hits, and that is accepted.
#
# The scanner knows nothing about PRs: <base> <head> in, hits out. pr-watch.sh
# (pr_run_data_migration_gate) holds a PR on a hit; any other caller (e.g. the
# orchestrator warning in a PR description) can call it the same way.
#
# Sourced; defines functions only and does no top-level work.

# The default migration-file patterns. `**/` also matches at the repo root and
# `*` crosses directories (data_migration_path_matches). Kept short on purpose:
# a repo whose destructive scripts live elsewhere (backfills) names them in
# .claude/run-issues.json `.data_migration.paths`, which ADDS to these.
DATA_MIGRATION_DEFAULT_PATHS='**/migrations/**/*.sql
**/migrations/**/*.php
**/migrations/**/*.py
**/migrations/**/*.js
**/migrations/**/*.ts
**/db/migrate/**/*.rb'

# data_migration_paths [<cfg-json-text>] — print the effective patterns, one per
# line: the defaults followed by `.data_migration.paths[]` of the config text.
# An empty config means the defaults only. rc 2 (and no output) on a config that
# is not JSON, or whose `.data_migration.paths` is present but not an array of
# strings — fail-closed: a typo must not silently narrow the scan to defaults.
data_migration_paths() {
  local cfg="${1-}" extra
  if [ -n "$cfg" ]; then
    extra=$(jq -r '
      if type != "object" then error("config is not an object")
      elif (.data_migration // null) == null then empty
      elif (.data_migration | type) != "object" then error("data_migration is not an object")
      elif (.data_migration.paths // null) == null then empty
      elif (.data_migration.paths | type) != "array" then error("paths is not an array")
      elif ([.data_migration.paths[] | select(type != "string" or length == 0)] | length) > 0
        then error("paths has a non-string or empty entry")
      else .data_migration.paths[] end' <<<"$cfg" 2>/dev/null) || return 2
    extra=$(printf '%s' "$extra" | tr -d '\r')
  else
    extra=""
  fi
  printf '%s\n' "$DATA_MIGRATION_DEFAULT_PATHS"
  [ -n "$extra" ] && printf '%s\n' "$extra"
  return 0
}

# data_migration_path_matches <path> <pattern> — rc 0 when <path> matches the
# glob <pattern>. Matching is bash's [[ == ]], where `*` also matches `/`, so
# `**` needs no globstar (bash 3.2). Every `/**/` is collapsed to `/` and a
# leading `**/` is optional, so `**/migrations/**/*.sql` matches
# `migrations/001.sql` as well as `db/migrations/2026/001.sql`.
data_migration_path_matches() {
  local path="$1" pat="$2"
  while [[ "$pat" == *"/**/"* ]]; do
    pat="${pat%%/\*\*/*}/${pat#*/\*\*/}"
  done
  # shellcheck disable=SC2053  # the right-hand side is a glob on purpose
  [[ "$path" == $pat ]] && return 0
  if [[ "$pat" == '**/'* ]]; then
    # shellcheck disable=SC2053
    [[ "$path" == ${pat#\*\*/} ]] && return 0
  fi
  return 1
}

# data_migration_scan <base> <head> [<cfg-json-text>] — run inside a git repo.
# Scans the lines ADDED by <base>...<head> (the merge-base diff, i.e. what the PR
# brings) in every file that matches data_migration_paths, and prints one line
# per hit:
#
#   <file>:<line>\t<statement, trimmed, at most 200 chars>
#
# rc 0 = hits printed, 1 = no hits, 2 = the scan could not run (a ref does not
# resolve, git diff failed, an invalid config). A caller must never read 2 as 1.
data_migration_scan() {
  local base="${1-}" head="${2-}" cfg="${3-}"
  [ -n "$base" ] && [ -n "$head" ] || return 2
  git rev-parse --verify -q "$base^{commit}" >/dev/null 2>&1 || return 2
  git rev-parse --verify -q "$head^{commit}" >/dev/null 2>&1 || return 2

  local patterns
  patterns=$(data_migration_paths "$cfg") || return 2

  local names
  names=$(git -c core.quotePath=false diff --no-ext-diff --no-renames --name-only \
            --diff-filter=ACM "$base...$head" 2>/dev/null) || return 2
  names=$(printf '%s' "$names" | tr -d '\r')

  local -a files=()
  local f p
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if data_migration_path_matches "$f" "$p"; then
        files+=(":(literal)$f")
        break
      fi
    done <<<"$patterns"
  done <<<"$names"
  [ "${#files[@]}" -gt 0 ] || return 1

  local diff
  diff=$(git -c core.quotePath=false diff --no-ext-diff --no-renames --no-color -U0 \
           "$base...$head" -- "${files[@]}" 2>/dev/null) || return 2

  local hits
  hits=$(printf '%s\n' "$diff" | tr -d '\r' | awk '
    function word(s) { return "(^|[^[:alnum:]_])" s "([^[:alnum:]_]|$)" }
    BEGIN {
      plain = word("(drop[[:space:]]+(column|table)|truncate|delete|update)")
      alter = word("alter")
      type_ = word("type")
    }
    /^\+\+\+ / { file = substr($0, 5); sub(/^b\//, "", file); next }
    /^@@ / {
      # @@ -a[,b] +c[,d] @@ — the new side starts at c.
      split($3, nw, ","); line = substr(nw[1], 2) + 0; next
    }
    /^\+/ {
      text = substr($0, 2); low = tolower(text)
      if (low ~ plain || (low ~ alter && low ~ type_)) {
        sub(/^[[:space:]]+/, "", text); sub(/[[:space:]]+$/, "", text)
        printf "%s:%d\t%s\n", file, line, substr(text, 1, 200)
      }
      line++
    }')
  [ -n "$hits" ] || return 1
  printf '%s\n' "$hits"
  return 0
}

# data_migration_held_before <state-jsonl> <pr-number> <sha> — rc 0 when a
# pr_data_migration_held event for this PR and head is already in the tail, i.e.
# the hold comment for this head has been posted. A new head is a new comment.
# Reads PR_WATCH_GATE_TAIL_LINES lines of the tail, the merge gates' window
# (CLAUDE.md §5.3: never the whole file). A lost record fails toward noise, not
# toward a merge: the comment is posted once more.
data_migration_held_before() {
  local jsonl="$1" pr="$2" sha="$3" n
  [ -f "$jsonl" ] || return 1
  n=$(tail -n "${PR_WATCH_GATE_TAIL_LINES:-1000}" "$jsonl" 2>/dev/null \
    | jq -Rrn --arg p "$pr" --arg s "$sha" '
        [inputs | fromjson? | select(.event == "pr_data_migration_held"
                                     and (.data.pr | tostring) == $p and .data.sha == $s)] | length' \
        2>/dev/null | tr -d '\r') || n=0
  [ "${n:-0}" -gt 0 ] 2>/dev/null
}
