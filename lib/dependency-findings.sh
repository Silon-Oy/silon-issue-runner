#!/usr/bin/env bash
# lib/dependency-findings.sh — dependency findings grouped by package version
# (issue #397).
#
# osv-scanner reports one vulnerability group per advisory. Filed as they come,
# one package version became up to nine issues and as many parallel runs of
# the same upgrade — while one version bump fixes them all. The unit of work is
# the installed package version, so that is the unit of a finding:
#
#   one finding per <ecosystem>/<package>@<version>, carrying every advisory id
#   of that version, the most severe advisory's severity, every lockfile it was
#   found in and the lowest version that fixes all of them (when the advisories
#   name a fixed version for each).
#
# Input is the scanner's per-group detail (scan.osv.tsv, lib/security-scan.sh).
# The version is part of the key on purpose: after an upgrade the old version's
# issue does not recur (so it is never reopened), and the new version's own
# advisories are a new finding.
#
# Sourced; defines functions only and does no top-level work. Needs
# lib/merge-gate.sh (merge_gate_severity_rank), sourced here if not yet loaded.

if ! declare -F merge_gate_severity_rank >/dev/null 2>&1; then
  # shellcheck source=merge-gate.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/merge-gate.sh"
fi

# The description prefix of a grouped finding — what the audit keys on.
DEPENDENCY_FINDING_PREFIX="osv-scanner-pkg: "

# _dependency_version_gt <a> <b> — rc 0 when version <a> sorts after <b> (sort -V).
_dependency_version_gt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

# dependency_fix_version <installed> <fixed-csv> — the lowest of the advisory's
# fixed versions above <installed>, or nothing when none is (or none is known).
# An advisory with several ranges (2.4.1 for 2.x, 3.2.0 for 3.x) fixes an
# installed 3.1.5 in 3.2.0, not in 2.4.1.
dependency_fix_version() {
  local installed="$1" v
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    if _dependency_version_gt "$v" "$installed"; then printf '%s' "$v"; return 0; fi
  done <<EOF
$(printf '%s' "${2:-}" | tr ',' '\n' | sort -V)
EOF
  return 0
}

# dependency_findings_group <osv-tsv> <details-out> — read scan.osv.tsv and
# print one finding row per package version in the audit's input form:
#
#   scanner|<severity>|high|<eco>/<pkg>@<ver>|osv-scanner-pkg: <eco>/<pkg>@<ver>: <ids>
#
# <ids> is every advisory id of the version, comma-separated, first-seen order.
# <details-out> gets one TSV row per advisory group, the material of the issue
# text and of the move from per-advisory issues:
#
#   key  path  eco  pkg  ver  severity  ids  fix  summary  description
#
# fix is the group's own fixed version (dependency_fix_version); description is
# the group's scan.findings description. Groups of the same version in several
# lockfiles are one finding.
dependency_findings_group() {
  local tsv="$1" details="$2" line lockfile eco pkg ver sev ids fixed summary desc key
  : > "$details"
  # A tab is IFS whitespace, so `read` would merge an empty column into the
  # next one; the unit separator is not.
  while IFS= read -r line; do
    IFS=$'\x1f' read -r lockfile eco pkg ver sev ids fixed summary desc <<<"${line//$'\t'/$'\x1f'}"
    [ -n "$pkg" ] || continue
    key="$eco/$pkg@$ver"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$key" "$lockfile" "$eco" "$pkg" "$ver" \
      "$sev" "$ids" "$(dependency_fix_version "$ver" "$fixed")" "$summary" "$desc" >> "$details"
  done < "$tsv"

  local rank best best_rank all_ids
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    best="low"; best_rank=0
    while IFS= read -r sev; do
      rank=$(merge_gate_severity_rank "$sev") || rank=0
      [ "$rank" -gt "$best_rank" ] && { best="$sev"; best_rank="$rank"; }
    done <<EOF
$(dependency_details_of "$details" "$key" | cut -f6)
EOF
    all_ids=$(dependency_details_of "$details" "$key" | cut -f7 | tr ',' '\n' \
      | awk 'NF && !seen[$0]++' | paste -sd, -)
    printf 'scanner|%s|high|%s|%s%s: %s\n' "$best" "$key" "$DEPENDENCY_FINDING_PREFIX" "$key" "$all_ids"
  done <<EOF
$(cut -f1 "$details" | awk 'NF && !seen[$0]++')
EOF
}

# dependency_details_of <details> <key> — the detail rows of one package version.
dependency_details_of() {
  awk -F'\t' -v k="$2" '$1 == k' "$1" 2>/dev/null
}

# dependency_fix_all <details> <key> — the lowest version that fixes every
# advisory of <key>: the highest of the per-advisory fixes. Nothing when any
# advisory has no known fix — then no single version can be named.
dependency_fix_all() {
  local rows
  rows=$(dependency_details_of "$1" "$2")
  [ -n "$rows" ] || return 0
  printf '%s\n' "$rows" | awk -F'\t' '$8 == "" { missing = 1 } END { exit missing ? 0 : 1 }' && return 0
  printf '%s\n' "$rows" | cut -f8 | sort -V | tail -n 1 | tr -d '\n'
}

# dependency_finding_parse <description> — "<key>\t<ids>" of a grouped
# finding's description; rc 1 when it is not one. The key may itself contain
# ": " (a Maven `group:artifact`), the ids never do, so the split is at the last.
dependency_finding_parse() {
  local rest
  case "$1" in "$DEPENDENCY_FINDING_PREFIX"*) ;; *) return 1 ;; esac
  rest="${1#"$DEPENDENCY_FINDING_PREFIX"}"
  printf '%s\t%s' "${rest%: *}" "${rest##*: }"
}
