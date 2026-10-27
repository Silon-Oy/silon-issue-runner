#!/usr/bin/env bash
# dependency-scan.sh — the whole-repo security audit's deterministic scanners,
# with no agent call (issue #382).
#
# A new vulnerability in an unchanged dependency appears without any commit:
# osv-scanner compares the lockfile with the advisory database as it is today.
# The full audit (security-audit.sh) is too costly to repeat often, so the
# poller schedules this kind separately (`dependency-scan` in
# lib/audit-schedule.sh) on its own, denser interval at no Claude cost.
#
# It is security-audit.sh's --scanners-only mode, not a copy (CLAUDE.md §7):
# the fingerprint, the `security` label, the auto-run threshold and the
# assignee route (#374) live in one place, and a finding this files is the same
# issue the full audit would file.
#
# Usage:
#   dependency-scan.sh <repo> [--remote <name>] [--dry-run] [--watchlist <path>]
#
# Exit codes (own space):
#   0  scan done, issues written (also: no findings); or --dry-run done
#   1  usage error
#   2  repo, remote or its default branch does not resolve, or git/jq/gh is missing
#   4  GitHub read or write failed — issues may be partially written
#   5  scan done, but at least one scanner failed (its class was not checked)
#   7  no scanner is installed — nothing was checked, never a clean result
#
# Env: as security-audit.sh (the scanners' RUN_ISSUES_GITLEAKS_BIN /
# RUN_ISSUES_OSV_SCANNER_BIN / RUN_ISSUES_SECURITY_SCAN_TIMEOUT, the auto-run
# threshold RUN_ISSUES_SECURITY_AUDIT_AUTO_RUN_MIN_SEVERITY, RUN_ISSUES_WATCHLIST).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Windows/Git Bash: LF jq output (lib/jq-binary.sh). The function is exported,
# so it reaches the exec'd security-audit.sh as well.
# shellcheck source=lib/jq-binary.sh
. "$SCRIPT_DIR/lib/jq-binary.sh"
for a in "$@"; do
  case "$a" in
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done
exec "$SCRIPT_DIR/security-audit.sh" --scanners-only "$@"
