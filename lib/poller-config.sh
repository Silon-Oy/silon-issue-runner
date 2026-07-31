#!/usr/bin/env bash
# lib/poller-config.sh — configuration resolution for poller.sh and
# pr-watch-poller.sh: the host gate and the watchlist lookup.
#
# Both pollers make the same two decisions before they do anything else, and
# both must be able to make them on a machine that has no ~/dotfiles. Keeping
# the decisions here as pure, side-effect-free functions means they can be
# tested by sourcing this file, instead of extracting function bodies out of a
# poller with awk — which is what the poller's own tests have to do, because a
# poller exits at source time on a host that is not in the gate.
#
# Pure: no writes, no external commands, no exits.

set -euo pipefail

# Hosts the pollers ran on before the gate became configurable. This is a
# back-compat shim, not machine configuration: it exists so that the machine
# currently running the auto-run setup keeps working without setting a single
# new environment variable. It disappears once that machine sets
# RUN_ISSUES_POLLER_HOSTS in its poller.env (CLAUDE.md, section 12).
# shellcheck disable=SC2034  # read by the sourcing pollers, not by this file
POLLER_HOSTS_LEGACY_DEFAULT='*host-a*,*host-a*'

# poller_host_allowed <host> <patterns> — return 0 when <host> matches any
# pattern in <patterns>, else 1. Prints nothing.
#
# <patterns> is a list of shell glob patterns separated by commas and/or
# whitespace; empty elements are ignored, so `a,,b` and `a, b` both mean two
# patterns. A single `*` allows every host. An empty list allows nothing, which
# is the fail-safe direction: an unknown machine must be a no-op, never a
# machine that starts orchestrating someone else's repos.
poller_host_allowed() {
  local host="${1-}" patterns="${2-}" pat
  local -a pats=()
  local IFS=$', \t\n'
  # read (not word splitting) so the glob metacharacters in the patterns are
  # not expanded against the current directory on their way into the loop.
  read -r -a pats <<<"$patterns"
  for pat in ${pats[@]+"${pats[@]}"}; do
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2254
    case "$host" in
      $pat) return 0 ;;
    esac
  done
  return 1
}

# poller_resolve_watchlist <explicit> <config> <legacy> — echo the watchlist
# path to use and return 0, or return 1 with no output when none is usable.
#
# When <explicit> (the RUN_ISSUES_WATCHLIST override) is non-empty it is the
# ONLY candidate: an override that points at a missing file is an error, not a
# reason to fall back. Falling back there would silently run the poller against
# a different repo set than the operator asked for.
#
# Otherwise <config> wins over <legacy>, so a machine can migrate its watchlist
# out of the dotfiles tree just by copying the file.
poller_resolve_watchlist() {
  local explicit="${1-}" config="${2-}" legacy="${3-}" candidate
  if [ -n "$explicit" ]; then
    [ -f "$explicit" ] || return 1
    printf '%s' "$explicit"
    return 0
  fi
  for candidate in "$config" "$legacy"; do
    [ -n "$candidate" ] || continue
    if [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}
