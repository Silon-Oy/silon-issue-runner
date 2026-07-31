#!/usr/bin/env bash
# install.sh — link this package's Claude assets into $HOME/.claude.
#
# Claude Code reads agents from $HOME/.claude/agents and slash commands from
# $HOME/.claude/commands. Those directories are a shared namespace: dotfiles (or
# any other source) ships its own files there too. The installer therefore
# operates under one invariant, and everything else follows from it:
#
#   INV-OWN — the installer may create, replace or remove a path only if that
#   path is absent, or is a symlink whose target resolves inside this package
#   root. Anything else belongs to someone else and is left exactly as it is.
#
# Three consequences worth stating, because each rules out a tempting shortcut:
#
#   1. Ownership is read from disk (the symlink target), not from a manifest.
#      A manifest can fall out of sync and would then hand deletion rights over
#      a file the package no longer ships — possibly one it never shipped.
#
#   2. Planning and applying are separate passes. Every check runs first and
#      nothing is written; a single refusal aborts with zero changes. Checking
#      and writing in one loop would leave a half-installed tree when the
#      second directory turns out to be foreign, which is exactly the silent
#      partial failure this installer exists to avoid.
#
#   3. The installer never calls launchctl. launchd mutates a live user
#      session, is not idempotent under a redirected $HOME (so it could not be
#      tested), and the com.maintainer -> com.claude-issue-runner migration needs a
#      deliberate one-off bootout (CLAUDE.md, section 11). Plist files are
#      deployed; the launchctl commands are printed for the user to run.
#
# Symlinks created here are always absolute and one hop deep, which is why
# ownership can be decided with plain readlink; `readlink -f` is not portable
# to older macOS.
#
# Usage / options / exit codes: see usage() below.

set -euo pipefail

PKG_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/preflight.sh
. "$PKG_ROOT/lib/preflight.sh"

# Every filesystem location is derived from $HOME (or an explicit override) so
# that the test suite can run against a throwaway home on the very machine
# whose live $HOME/.claude the pollers use.
CLAUDE_HOME="${RUN_ISSUES_CLAUDE_HOME:-$HOME/.claude}"

# Directories whose contents this package owns file by file.
LINKED_DIRS="agents commands"

DRY_RUN=0
QUIET=0

TAB=$'\t'
PLAN=()
REFUSALS=()
CONFLICTS=()

usage() {
  cat <<'EOF'
Usage: install.sh [options]

Links this package's agents and slash commands into $HOME/.claude, file by
file, so that they coexist with assets from other sources.

Options:
  --dry-run    Print the plan and exit without writing anything
  --quiet      Suppress progress output; warnings, conflicts, refusals and the
               summary are always printed
  -h, --help   Show this help

Environment:
  RUN_ISSUES_CLAUDE_HOME         default: $HOME/.claude

Exit codes:
  0  success (or --dry-run completed)
  1  usage error
  2  refused — a target path is owned by something else; nothing was changed
  3  apply failed unexpectedly
  4  completed, but foreign files shadow shipped names (nothing overwritten)
EOF
}

log()    { [ "$QUIET" -eq 1 ] && return 0; printf '%s\n' "$*"; }
warn()   { printf 'WARN: %s\n' "$*" >&2; }
err()    { printf 'ERROR: %s\n' "$*" >&2; }
refuse() { REFUSALS+=("$1"); }

# conflict — a foreign file occupies a name this package ships. Not fatal: the
# rest of the install proceeds, but the exit code makes it machine-detectable
# so it cannot drown in a log.
conflict() { CONFLICTS+=("$1"); }

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

# resolve_dir <dir> — echo the physical path of an existing directory, or fail.
resolve_dir() {
  (cd -P "$1" 2>/dev/null && pwd)
}

# resolve_link_target <link> — echo the absolute target of a symlink. A
# relative target is resolved against the link's physical parent. Anything that
# cannot be resolved fails, and every caller treats a failure as "not ours",
# which is the safe direction.
resolve_link_target() {
  local link="$1" target parent
  target="$(readlink "$link" 2>/dev/null)" || return 1
  [ -n "$target" ] || return 1
  case "$target" in
    /*) printf '%s' "$target" ;;
    *)
      parent="$(resolve_dir "$(dirname "$link")")" || return 1
      printf '%s/%s' "$parent" "$target"
      ;;
  esac
}

# is_pkg_owned_link <path> — INV-OWN's predicate.
is_pkg_owned_link() {
  local path="$1" target
  [ -L "$path" ] || return 1
  target="$(resolve_link_target "$path")" || return 1
  case "$target" in
    "$PKG_ROOT"/*) return 0 ;;
    *)             return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------

# plan_add <action> [args...] — actions: mkdir | link | relink | unlink | skip.
# Fields are tab-separated; no path this package deals with contains a tab.
plan_add() {
  local IFS="$TAB"
  PLAN+=("$*")
}

count_action() {
  local want="$1" entry action rest n=0
  if [ "${#PLAN[@]}" -gt 0 ]; then
    for entry in "${PLAN[@]}"; do
      IFS="$TAB" read -r action rest <<<"$entry"
      [ "$action" = "$want" ] && n=$((n + 1))
    done
  fi
  printf '%s' "$n"
}

# plan_link_dir <name> — plan the per-file links for $PKG_ROOT/<name> into
# $CLAUDE_HOME/<name>, and plan the removal of package-owned links that no
# longer correspond to a shipped file.
plan_link_dir() {
  local name="$1"
  local src_dir="$PKG_ROOT/$name" dst_dir="$CLAUDE_HOME/$name"
  local src base dst entry ebase keep current
  local wanted=()

  # A whole-directory symlink means another source owns the directory itself
  # (the pre-split dotfiles layout). Writing into it would place this package's
  # files in a repository it does not own.
  if [ -L "$dst_dir" ]; then
    refuse "$dst_dir is a directory symlink -> $(readlink "$dst_dir"). Replace it with a real directory holding per-file symlinks, then re-run install.sh."
    return 0
  fi
  if [ -e "$dst_dir" ] && [ ! -d "$dst_dir" ]; then
    refuse "$dst_dir exists but is not a directory. Move it aside, then re-run install.sh."
    return 0
  fi
  [ -d "$dst_dir" ] || plan_add mkdir "$dst_dir"

  for src in "$src_dir"/*.md; do
    [ -e "$src" ] || continue
    base="$(basename "$src")"
    wanted+=("$base")
    dst="$dst_dir/$base"

    if is_pkg_owned_link "$dst"; then
      current="$(resolve_link_target "$dst")"
      if [ "$current" = "$src" ]; then
        plan_add skip "$dst already links to this package"
      else
        plan_add relink "$src" "$dst"
      fi
    elif [ -L "$dst" ]; then
      conflict "$dst is a symlink owned by another source -> $(readlink "$dst"); left untouched"
    elif [ -e "$dst" ]; then
      conflict "$dst is a file owned by another source; left untouched"
    else
      plan_add link "$src" "$dst"
    fi
  done

  # Prune: package-owned links whose name the package no longer ships. The
  # decision rests on the name alone, never on whether the link resolves — a
  # shipped name that currently dangles (a file moved inside the package) is
  # already covered by the relink above, and pruning it here would undo that
  # relink, since apply runs the plan in order.
  if [ -d "$dst_dir" ]; then
    for entry in "$dst_dir"/*; do
      is_pkg_owned_link "$entry" || continue
      ebase="$(basename "$entry")"
      keep=0
      if [ "${#wanted[@]}" -gt 0 ]; then
        for base in "${wanted[@]}"; do
          if [ "$base" = "$ebase" ]; then keep=1; break; fi
        done
      fi
      if [ "$keep" -eq 0 ]; then
        plan_add unlink "$entry"
      fi
    done
  fi
}

print_plan() {
  local entry action a b
  [ "${#PLAN[@]}" -gt 0 ] || return 0
  for entry in "${PLAN[@]}"; do
    IFS="$TAB" read -r action a b <<<"$entry"
    case "$action" in
      mkdir)  log "plan: mkdir  $a" ;;
      link)   log "plan: link   $b -> $a" ;;
      relink) log "plan: relink $b -> $a" ;;
      unlink) log "plan: unlink $a" ;;
      skip)   log "plan: skip   $a" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

apply_plan() {
  local entry action a b
  [ "${#PLAN[@]}" -gt 0 ] || return 0
  for entry in "${PLAN[@]}"; do
    IFS="$TAB" read -r action a b <<<"$entry"
    case "$action" in
      mkdir)
        mkdir -p "$a" || return 1
        log "ok: created $a"
        ;;
      link)
        ln -s "$a" "$b" || return 1
        log "ok: linked $b"
        ;;
      relink)
        rm -f "$b" || return 1
        ln -s "$a" "$b" || return 1
        log "ok: relinked $b"
        ;;
      unlink)
        rm -f "$a" || return 1
        log "ok: pruned $a"
        ;;
      skip) : ;;
      *)
        err "internal: unknown plan action '$action'"
        return 1
        ;;
    esac
  done
  return 0
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

report_preflight() {
  local tb
  log "dependencies (advisory — a missing tool never blocks the install):"
  log "  $(preflight_report_tool git required 'needed to update the package (submodule pin)' || true)"
  log "  $(preflight_report_tool gh required 'GitHub CLI — orchestrate.sh and pr-watch.sh depend on it' || true)"
  log "  $(preflight_report_tool jq required 'JSON handling in orchestrate.sh, poller.sh and pr-watch.sh' || true)"
  log "  $(preflight_report_tool npx required 'the default RUN_ISSUES_CLAUDE_CMD invokes the Claude CLI via npx' || true)"
  log "  $(preflight_report_tool tmux optional 'only the pollers need it' || true)"
  tb="$(preflight_timeout_bin)"
  if [ -n "$tb" ]; then
    log "  ok: $tb"
  else
    log "  MISSING (optional): timeout/gtimeout — claude calls would run unbounded"
  fi
}

print_refusals() {
  local r
  [ "${#REFUSALS[@]}" -gt 0 ] || return 0
  for r in "${REFUSALS[@]}"; do
    printf 'REFUSED: %s\n' "$r" >&2
  done
}

print_conflicts() {
  local c
  [ "${#CONFLICTS[@]}" -gt 0 ] || return 0
  for c in "${CONFLICTS[@]}"; do
    printf 'CONFLICT: %s\n' "$c" >&2
  done
}

print_summary() {
  printf 'summary: linked=%s relinked=%s pruned=%s skipped=%s conflicts=%s\n' \
    "$(count_action link)" "$(count_action relink)" "$(count_action unlink)" \
    "$(count_action skip)" "${#CONFLICTS[@]}"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --quiet)   QUIET=1 ;;
      -h|--help) usage; exit 0 ;;
      *)
        err "unknown option: $1"
        usage >&2
        exit 1
        ;;
    esac
    shift
  done
}

main() {
  local d

  parse_args "$@"
  report_preflight

  for d in $LINKED_DIRS; do
    plan_link_dir "$d"
  done

  # The refusal gate sits between planning and applying: no refusal can ever
  # coexist with a partial write.
  if [ "${#REFUSALS[@]}" -gt 0 ]; then
    print_refusals
    err "refusing to modify a layout this package does not own — nothing was changed"
    exit 2
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    print_plan
    print_conflicts
    print_summary
    exit 0
  fi

  if ! apply_plan; then
    err "install failed part-way through; re-run to converge"
    exit 3
  fi

  print_conflicts
  print_summary

  if [ "${#CONFLICTS[@]}" -gt 0 ]; then
    exit 4
  fi
  exit 0
}

main "$@"
