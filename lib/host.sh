#!/usr/bin/env bash
# lib/host.sh — the machine's short hostname, resolved once and the same way
# everywhere.
#
# `run.json.host` is the base of every ownership decision in the package: the
# per-run host gate in stop-run.sh (exit 4), cleanup-run.sh, teardown.sh, both
# pollers' scans and self-update.sh's idle check all compare a recorded host
# against the host they are running on (CLAUDE.md section 5.6). The comparison
# is fail-closed, so an EMPTY host field does not read as "unknown" — it reads
# as "belongs to another machine", and every gate then silently leaves the run's
# artefacts on disk.
#
# `hostname -s` is what produced that field, and the flag is not portable:
# Windows' hostname.exe has no -s and answers with a usage error. On such a
# machine the field would be empty, which is the one value the gates cannot
# survive. Hence the fallback chain, and hence the guarantee that matters more
# than any single branch of it: this NEVER returns an empty string.
#
# The chain is ordered by how specific the answer is:
#   1. `hostname -s`      — the short name, unchanged from what every existing
#                           run.json on disk already records.
#   2. `hostname`         — truncated at the first dot, i.e. the short name
#                           derived from an FQDN.
#   3. $COMPUTERNAME      — Windows' own environment variable.
#   4. "unknown"          — last resort. Note that all such machines then SHARE
#                           one host value and the gate cannot tell them apart;
#                           that is strictly better than the empty field, which
#                           makes every machine foreign to itself.
#
# Both the host gate's comparison (poller_host_allowed's argument) and the
# run.json writes go through this function, so the gate and the record can never
# disagree about what this machine is called.
#
# Defines two functions only; no top-level work. Sourcing is side-effect-free
# and repeatable, which matters because the callers form a chain (orchestrate.sh
# -> lib/state.sh, poller.sh -> lib/teardown.sh).

# _runner_host_usable <candidate>
# A candidate is usable when it is a single non-empty token. The whitespace test
# is what rejects a usage error printed on stdout ("hostname: illegal option --
# s"), which is the failure mode of a `hostname` that does not know the flag but
# still exits 0.
_runner_host_usable() {
  case "${1-}" in
    '' | *[[:space:]]*) return 1 ;;
    *) return 0 ;;
  esac
}

# runner_host
# Print this machine's short hostname. Always prints exactly one non-empty
# token, and always succeeds (rc 0), so callers need neither `2>/dev/null` nor
# an `|| echo unknown` of their own.
runner_host() {
  local h

  # Carriage returns are stripped from every branch: a Windows-built tool can
  # end its line with CRLF, and command substitution removes only the LF.
  h="$(hostname -s 2>/dev/null || true)"
  h="${h//$'\r'/}"
  if _runner_host_usable "$h"; then
    printf '%s\n' "$h"
    return 0
  fi

  h="$(hostname 2>/dev/null || true)"
  h="${h//$'\r'/}"
  h="${h%%.*}"
  if _runner_host_usable "$h"; then
    printf '%s\n' "$h"
    return 0
  fi

  h="${COMPUTERNAME:-}"
  h="${h//$'\r'/}"
  h="${h%%.*}"
  if _runner_host_usable "$h"; then
    printf '%s\n' "$h"
    return 0
  fi

  printf 'unknown\n'
}
