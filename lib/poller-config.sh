#!/usr/bin/env bash
# lib/poller-config.sh — configuration resolution for poller.sh,
# pr-watch-poller.sh and /issue-runner:new-epic: the host gate, the watchlist
# lookup and the pickup labels a repo's issues must carry.
#
# Both pollers make the same two decisions before they do anything else, and
# both must be able to make them on a machine that has no ~/dotfiles. Keeping
# the decisions here as pure, side-effect-free functions means they can be
# tested by sourcing this file, instead of extracting function bodies out of a
# poller with awk — which is what the poller's own tests have to do, because a
# poller exits at source time on a host that is not in the gate.
#
# Writes nothing, mutates nothing, never exits — that is the guarantee a poller
# sourcing this at startup depends on. Everything here is also free of external
# commands except poller_watchlist_pick_labels, which reads the watchlist with
# jq; it is documented at its own definition.

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

# The label set an issue must carry when nothing configures one. It is a single
# constant rather than a literal repeated in a jq filter and a shell fallback,
# because those two used to be the two places the chain below lived.
# shellcheck disable=SC2034  # read by the sourcing pollers, not by this file
POLLER_PICK_LABELS_DEFAULT='auto-run'

# _poller_trim_csv <csv> — echo <csv> with surrounding whitespace removed from
# the whole string and from each element, and with empty elements dropped.
# A watchlist is hand-edited JSON, so `auto-run, backend` must mean the same
# two labels as `auto-run,backend`.
_poller_trim_csv() {
  local csv="${1-}" out="" part
  # read -a rather than an unquoted `for part in $csv`: the latter also runs
  # pathname expansion, so a label containing a glob character would be
  # silently rewritten into whatever happens to sit in the caller's cwd.
  local IFS=','
  local -a parts=()
  read -r -a parts <<<"$csv"
  for part in ${parts+"${parts[@]}"}; do
    # Trim with parameter expansion rather than sed: this file promises to be
    # free of external commands (see the header), and a per-element subshell
    # would run once per label on every poller tick.
    part="${part#"${part%%[![:space:]]*}"}"
    part="${part%"${part##*[![:space:]]}"}"
    [ -n "$part" ] || continue
    if [ -z "$out" ]; then out="$part"; else out="$out,$part"; fi
  done
  printf '%s' "$out"
}

# poller_pick_labels <repo-labels-csv> <default-labels-csv> — echo the pickup
# label set for one repo, as the comma-separated list pick_oldest_candidate and
# epic_list_open expect. Always prints something; never fails.
#
# The list is ANDed by the consumer (REST `labels=`): an issue must carry EVERY
# label in it. Widening the list therefore narrows pickup, which is why the
# fallback chain takes the FIRST non-empty candidate rather than merging them:
# a repo entry's `labels` REPLACES `default_labels`, it does not add to it.
#
#   repo entry `labels` -> watchlist `default_labels` -> POLLER_PICK_LABELS_DEFAULT
#
# The last step is why this never returns empty: an empty label set would make
# the pick query match every open issue in the repo.
poller_pick_labels() {
  local repo_csv default_csv
  repo_csv="$(_poller_trim_csv "${1-}")"
  default_csv="$(_poller_trim_csv "${2-}")"
  if [ -n "$repo_csv" ]; then
    printf '%s' "$repo_csv"
  elif [ -n "$default_csv" ]; then
    printf '%s' "$default_csv"
  else
    printf '%s' "$POLLER_PICK_LABELS_DEFAULT"
  fi
}

# poller_watchlist_pick_labels <watchlist-path> <repo-path> — echo the pickup
# labels a watchlist records for one repo checkout, and return 0 when the
# watchlist actually covers that repo, 1 when it does not.
#
# The labels are printed in BOTH cases: rc 1 means "what you got is the built-in
# default, say so out loud", never "no answer". A caller that swallows the rc
# still gets a working label set; a caller that reports it
# (/issue-runner:new-epic) can tell the human that nothing configured this,
# which is the difference between a considered default and a label that will
# never be picked up.
#
# Not covered means any of: no path given, no watchlist, an unreadable or
# unparseable watchlist, or no `.repos[]` entry whose `path` is this checkout.
# They collapse into one rc AND one label set on purpose. In particular an
# uncovered repo does NOT inherit the watchlist's `default_labels`: that key is
# the default for the repos the watchlist lists, and applying it to a repo the
# watchlist does not list would quietly impose one machine's convention on a
# checkout no poller here will ever look at.
#
# Unlike the rest of this file this reads a file and shells out to jq. It still
# writes nothing, mutates nothing and never exits: the guarantee that matters
# for a poller sourcing this at startup is intact.
poller_watchlist_pick_labels() {
  local watchlist="${1-}" repo_path="${2-}"
  local default_csv="" repo_csv="" found=""

  if [ -n "$watchlist" ] && [ -f "$watchlist" ] && [ -n "$repo_path" ]; then
    # THE PATH NEVER CROSSES INTO jq. Under Git Bash, jq is a native Windows
    # program, and MSYS rewrites anything that looks like an absolute POSIX path
    # on its way into one — measured on windows-latest, BOTH channels:
    #
    #   jq -rn --arg p /tmp/repo-a '$p'          -> C:/Users/.../Temp/repo-a
    #   ( export P=/tmp/repo-a; jq -rn '$ENV.P' ) -> C:/Users/.../Temp/repo-a
    #
    # while the watchlist FILE still reads /tmp/repo-a, so the comparison never
    # matched and every repo silently fell back to the default labels. `$ENV` is
    # not an escape hatch: the environment is converted too. Nor is switching the
    # conversion off, because the watchlist path is an operand on the same
    # command line and jq.exe genuinely needs THAT one converted.
    #
    # So jq is asked only for what it can answer without seeing our path — the
    # entries — and bash does the comparison, where both sides are bash strings.
    # jq's OUTPUT is not rewritten (only argv and the environment are), so the
    # paths come back exactly as the file spells them.
    #
    # Still one jq pass, for the original reason: a watchlist must not be able to
    # read as "covered" by one filter and "not covered" by another. Line 1 is the
    # default CSV; every further line is "<path>\t<that entry's CSV>". Trailing
    # slashes are normalised on both sides — `/repo` and `/repo/` are one checkout.
    local rows=""
    rows=$(jq -r '
      def norm: (. // "" | tostring) | sub("/+$"; "");
      def csv:  (. // []) | map(select(type == "string" and length > 0)) | join(",");
      (.default_labels | csv),
      (.repos[]? | ((.path | norm) + "\t" + (.labels | csv)))
    ' "$watchlist" 2>/dev/null) || rows=""

    if [ -n "$rows" ]; then
      local want="$repo_path"
      while [ "${want%/}" != "$want" ]; do want="${want%/}"; done

      local line first=1 entry_path
      while IFS= read -r line; do
        if [ "$first" -eq 1 ]; then
          default_csv="$line"
          first=0
          continue
        fi
        entry_path="${line%%$'\t'*}"
        if [ "$entry_path" = "$want" ]; then
          repo_csv="${line#*$'\t'}"
          found="1"
          break
        fi
      done <<< "$rows"
    fi
  fi

  if [ "$found" = "1" ]; then
    poller_pick_labels "$repo_csv" "$default_csv"
    return 0
  fi
  poller_pick_labels "" ""
  return 1
}
