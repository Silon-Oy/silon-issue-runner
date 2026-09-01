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

# poller_host_unset_message <var-name> <env-file> <host> — echo the single line
# a caller prints before it exits when <var-name> is unset. Pure: it builds the
# text, the caller decides where the text goes.
#
# The host gate has no default. It used to carry a built-in list of the machine
# names the pollers happened to run on (issue #152 removed it), which made the
# package know one particular machine and, worse, made a MISCONFIGURED machine
# indistinguishable from a foreign one: both exited 0 in silence. The two are
# now separate. An unset variable is an operator error and says so; a set
# variable that matches nothing is a foreign machine and stays silent, because
# that no-op is the whole point of the gate.
#
# The line names the variable AND the file it belongs in, because those two
# facts are what the reader is missing — the gate runs before the poller has
# opened any log of its own, so this is all they get.
poller_host_unset_message() {
  local var="${1-}" env_file="${2-}" host="${3-}"
  printf '%s is not set: the host gate is fail-closed, so nothing runs here. Set it in %s to a comma-separated list of hostname globs, e.g. %s="%s" (this host).\n' \
    "$var" "$env_file" "$var" "$host"
}

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
