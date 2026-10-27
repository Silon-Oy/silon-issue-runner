#!/usr/bin/env bash
# lib/deps.sh — reader for lib/deps.tsv, the package's one dependency list.
#
# Before this file the list was written by hand four times (the S0 gate, the
# installer's report, README §2 and every runner guide), and a dependency added
# to one copy silently never reached the others: #336's scanners reached the
# README and nothing else, so a Sprite ran the merge gate without them. Every
# consumer now asks this module instead of keeping its own list.
#
# Pure functions: no writes, no exits, no globals beyond the directory captured
# at source time. Reading is plain bash (`read`, parameter expansion) and never
# forks a helper, for two reasons:
#   - callers run these with a deliberately empty PATH (tests stage "no tools at
#     all"), and an awk/sed reader would itself be a missing dependency there;
#   - a list whose reader needs jq would be a list that needs one of its own
#     rows (and jq's Windows text-mode output, CLAUDE.md §5.8). A stray CR from a
#     CRLF checkout is stripped all the same.
#
# Bash 3.2 compatible (macOS): no associative arrays, no mapfile.
#
# Env:
#   RUN_ISSUES_DEPS_FILE      (test injection point) — the list to read
#   RUN_ISSUES_DEPS_PLATFORM  (test injection point) — brew | apt; default
#                             detected: apt on a Linux with apt-get, else brew

_DEPS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# deps_file — the path of the list in use.
deps_file() {
  printf '%s' "${RUN_ISSUES_DEPS_FILE:-$_DEPS_LIB_DIR/deps.tsv}"
}

# _deps_rows — every data row of the list, one per line, CR stripped. Comment
# and blank lines are dropped. Returns 1 when the list cannot be read.
_deps_rows() {
  local file line
  file="$(deps_file)"
  [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      ''|'#'*) continue ;;
    esac
    printf '%s\n' "$line"
  done < "$file"
}

# deps_names [level] [scope] — the dependency names, in list order, one per line.
# An empty or omitted filter matches everything.
deps_names() {
  local want_level="${1:-}" want_scope="${2:-}" rows name level scope rest
  rows="$(_deps_rows)" || return 1
  while IFS=$'\t' read -r name level scope rest; do
    [ -n "$name" ] || continue
    [ -z "$want_level" ] || [ "$level" = "$want_level" ] || continue
    [ -z "$want_scope" ] || [ "$scope" = "$want_scope" ] || continue
    printf '%s\n' "$name"
  done <<< "$rows"
}

# deps_field <name> <column> — one field of one row.
#   column = level | scope | brew | apt | license | purpose
# Returns 1 without output for an unknown name or column.
deps_field() {
  local want="$1" column="$2" rows name level scope brew apt license purpose
  rows="$(_deps_rows)" || return 1
  while IFS=$'\t' read -r name level scope brew apt license purpose; do
    [ "$name" = "$want" ] || continue
    case "$column" in
      level)   printf '%s\n' "$level" ;;
      scope)   printf '%s\n' "$scope" ;;
      brew)    printf '%s\n' "$brew" ;;
      apt)     printf '%s\n' "$apt" ;;
      license) printf '%s\n' "$license" ;;
      purpose) printf '%s\n' "$purpose" ;;
      *)       return 1 ;;
    esac
    return 0
  done <<< "$rows"
  return 1
}

# deps_platform — brew | apt: which install column applies to this machine.
# Detection uses $OSTYPE and the `command -v` builtin only, so it works under
# an empty PATH (where it answers brew, the historical wording).
deps_platform() {
  if [ -n "${RUN_ISSUES_DEPS_PLATFORM:-}" ]; then
    printf '%s' "$RUN_ISSUES_DEPS_PLATFORM"
    return 0
  fi
  case "${OSTYPE:-}" in
    linux*)
      if command -v apt-get >/dev/null 2>&1; then
        printf 'apt'
        return 0
      fi
      ;;
  esac
  printf 'brew'
}

# deps_hint <name> — the install hint for this platform. Returns 1 without
# output for a name that is not in the list.
deps_hint() {
  deps_field "$1" "$(deps_platform)"
}

# _deps_md_cell <text> — escape a value for a markdown table cell.
_deps_md_cell() {
  local s="$1"
  s="${s//|/\\|}"
  printf '%s' "$s"
}

# deps_markdown_table — the shared table docs/dependencies.md embeds between
# its deps-table markers. tests/test-dependencies.sh compares the committed
# copy against this output, so a list change without a regenerated table fails.
deps_markdown_table() {
  local rows name level scope brew apt license purpose
  rows="$(_deps_rows)" || return 1
  printf '| Riippuvuus | Taso | Kuka tarvitsee | macOS (Homebrew) | Ubuntu / Sprite (apt tai julkaisubinääri) | Lisenssi | Käyttötarkoitus |\n'
  printf '|---|---|---|---|---|---|---|\n'
  while IFS=$'\t' read -r name level scope brew apt license purpose; do
    [ -n "$name" ] || continue
    printf '| `%s` | %s | %s | %s | %s | %s | %s |\n' \
      "$name" "$level" "$scope" \
      "$(_deps_md_cell "$brew")" "$(_deps_md_cell "$apt")" \
      "$(_deps_md_cell "$license")" "$(_deps_md_cell "$purpose")"
  done <<< "$rows"
}
