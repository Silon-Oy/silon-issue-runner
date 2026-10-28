#!/usr/bin/env bash
# lib/accretion.sh — deterministic file-accretion meter (issue #411).
#
# Each run stays within its scope, yet the sum of runs can grow one file
# without bound (a 5 500-line admin.ts with no observation on the way). The
# agent-based evolution step judges only its own diff, so it cannot see the
# cumulative size. This meter compares line counts between two git refs and
# reports the files a change grows while they already exceed a threshold.
#
# Generic over a <base> <head> ref pair: it knows nothing about the
# orchestrator, so an audit or the PR watcher can call the same function.
# Advisory, never a gate: a git failure is rc != 0 with empty output, and the
# caller decides to ignore it.
#
# Function-only: safe to source more than once.

ACCRETION_DEFAULT_MAX_LINES=1000

# accretion_max_lines <repo-dir> — the threshold: .accretion.max_lines from
# <repo-dir>/.claude/run-issues.json when it is a positive integer, else the
# default.
accretion_max_lines() {
  local cfg="$1/.claude/run-issues.json" v=""
  if [ -f "$cfg" ]; then
    v=$(jq -r '.accretion.max_lines // empty' "$cfg" 2>/dev/null || true)
  fi
  case "$v" in
    ''|*[!0-9]*|0*) printf '%s\n' "$ACCRETION_DEFAULT_MAX_LINES" ;;
    *) printf '%s\n' "$v" ;;
  esac
}

# accretion_skip_path <repo-dir> <head> <path> — rc 0 when <path> is not worth
# measuring: a lock file, a snapshot, or marked linguist-generated in
# .gitattributes. Lock files are listed by name, not reused from
# security-scan.sh: that list also holds manifests, whose growth is a signal.
accretion_skip_path() {
  local repo="$1" head="$2" path="$3" base attr
  base="${path##*/}"
  case "$base" in
    package-lock.json|npm-shrinkwrap.json|yarn.lock|pnpm-lock.yaml|bun.lock|bun.lockb|\
    composer.lock|Gemfile.lock|gems.locked|Cargo.lock|poetry.lock|Pipfile.lock|\
    pdm.lock|uv.lock|mix.lock|pubspec.lock|go.sum|flake.lock|packages.lock.json|\
    *.lockfile|*.lock|*.snap)
      return 0 ;;
  esac
  case "/$path" in
    */__snapshots__/*) return 0 ;;
  esac
  # The attribute is read from <head>'s .gitattributes (git >= 2.40); an older
  # git rejects --source, so fall back to the checkout's own attributes.
  attr=$(git -C "$repo" check-attr --source "$head" linguist-generated -- "$path" 2>/dev/null) \
    || attr=$(git -C "$repo" check-attr linguist-generated -- "$path" 2>/dev/null) \
    || attr=""
  case "${attr##*: }" in
    set|true) return 0 ;;
  esac
  return 1
}

# _accretion_lines <repo-dir> <ref> <path> — line count of <path> at <ref>, 0
# when the path does not exist there.
_accretion_lines() {
  local n
  n=$(git -C "$1" show "$2:$3" 2>/dev/null | wc -l) || n=0
  printf '%s\n' $(( ${n:-0} + 0 ))
}

# accretion_findings <base> <head> [<repo-dir>] — TSV rows
# "<path>\t<head_lines>\t<growth>\t<threshold>" for every added or modified
# text file whose line count at <head> exceeds the threshold and grew since
# <base>. A new file grows from zero. No findings: empty output, rc 0.
accretion_findings() {
  local base="$1" head="$2" repo="${3:-.}" max numstat added removed path
  local before after
  numstat=$(git -C "$repo" diff --numstat --no-renames --diff-filter=AM "$base" "$head" 2>/dev/null) || return 1
  max=$(accretion_max_lines "$repo")
  while IFS=$'\t' read -r added removed path; do
    [ -n "$path" ] || continue
    # Binary files show "-" in numstat; their line count means nothing.
    [ "$added" = "-" ] && continue
    accretion_skip_path "$repo" "$head" "$path" && continue
    after=$(_accretion_lines "$repo" "$head" "$path")
    [ "$after" -gt "$max" ] || continue
    before=$(_accretion_lines "$repo" "$base" "$path")
    [ "$after" -gt "$before" ] || continue
    printf '%s\t%s\t%s\t%s\n' "$path" "$after" "$(( after - before ))" "$max"
  done <<< "$numstat"
  return 0
}

# accretion_format_markdown — TSV rows on stdin → one markdown bullet each.
accretion_format_markdown() {
  awk -F '\t' 'NF >= 4 { printf "- `%s`: %s riviä (+%s), kynnys %s\n", $1, $2, $3, $4 }'
}

# accretion_to_json — TSV rows on stdin → [{path, lines, growth, threshold}].
accretion_to_json() {
  jq -R -s -c '
    split("\n") | map(select(length > 0) | split("\t")
      | {path: .[0], lines: (.[1] | tonumber), growth: (.[2] | tonumber), threshold: (.[3] | tonumber)})'
}
