#!/usr/bin/env bash
# lib/deadline-file.sh — the one-line "<deadline-epoch> <tag>" state file shared
# by the machine-wide backoff gates.
#
# Two gates use this shape: the GitHub rate-limit backoff (lib/rate-limit.sh,
# tag = ladder step) and the Claude usage-limit gate (lib/usage-limit.sh, tag =
# where the deadline came from). They differ in WHAT they gate and how a
# deadline is chosen; they share how it is stored, and storing it is the part
# whose failure modes matter:
#
#   - FAIL-SOFT READ. A missing, empty or unparseable file reads as deadline 0,
#     i.e. "no backoff". A corrupt file must never be able to wedge a machine
#     shut — the worst a bad write can do is lose one backoff.
#   - ATOMIC WRITE. tmp + mv in the same directory, so a reader racing a writer
#     sees either the old line or the new one, never half of each.
#
# Defines functions only; no top-level work and no `set`. Sourcing is
# side-effect-free, which matters because both pollers source the gates above
# their host gate.

# deadline_file_read <path> — print "<deadline-epoch> <tag>". The deadline is
# 0 when the file is missing or its first field is not a non-negative integer;
# the tag is the second whitespace-separated field verbatim, or empty. Never
# fails.
deadline_file_read() {
  local line d t
  line=$(head -n 1 "${1:-}" 2>/dev/null || printf '')
  d="${line%% *}"
  case "$line" in
    *" "*) t="${line#* }"; t="${t%% *}" ;;
    *) t="" ;;
  esac
  case "$d" in ''|*[!0-9]*) d=0 ;; esac
  printf '%s %s' "$d" "$t"
}

# deadline_file_write <path> <deadline-epoch> <tag> — atomically replace the
# file with one line. Returns 1 (and leaves the old file in place) when the
# directory is not writable; callers treat that as "backoff not recorded", which
# degrades to no backoff rather than to an error.
deadline_file_write() {
  local f="${1:-}" d="${2:-0}" t="${3:-}"
  [ -n "$f" ] || return 1
  local tmp
  tmp=$(mktemp "${f}.XXXXXX" 2>/dev/null) || return 1
  if printf '%s %s\n' "$d" "$t" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}
