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
LAUNCH_AGENTS_DIR="${RUN_ISSUES_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"

# Directories whose contents this package owns file by file.
LINKED_DIRS="agents commands"

DRY_RUN=0
QUIET=0
WITH_LAUNCHAGENTS=0

# The directory $CLAUDE_HOME/scripts/run-issues resolves to once this run's
# plan has been applied. Set by plan_scripts_binding; empty until then.
SCRIPTS_BINDING_TARGET=""

TAB=$'\t'
PLAN=()
REFUSALS=()
CONFLICTS=()
LAUNCH_LABELS=()

usage() {
  cat <<'EOF'
Usage: install.sh [options]

Links this package's agents and slash commands into $HOME/.claude, file by
file, so that they coexist with assets from other sources.

Options:
  --dry-run             Print the plan and exit without writing anything
  --with-launchagents   Also deploy the poller LaunchAgent plists. Opt-in: the
                        plists are only useful on a machine that runs the
                        pollers. install.sh deploys the files only — the
                        launchctl commands are printed for you to run.
  --quiet               Suppress progress output; warnings, conflicts,
                        refusals and the summary are always printed
  -h, --help            Show this help

Environment:
  RUN_ISSUES_CLAUDE_HOME         default: $HOME/.claude
  RUN_ISSUES_LAUNCH_AGENTS_DIR   default: $HOME/Library/LaunchAgents

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

# plan_scripts_binding — make $CLAUDE_HOME/scripts/run-issues resolve to this
# package.
#
# The slash commands and prompts/02-implementer.md invoke
# "$HOME/.claude/scripts/run-issues/<script>" by absolute path. In the dotfiles
# install model that path already exists (dotfiles symlinks the whole scripts
# tree and the package is mounted inside it as a submodule); on any other
# machine nothing creates it, and a clean clone would install slash commands
# pointing at a script that is not there.
#
# The binding is therefore conditional, never unconditional: if the path
# already works it is left alone whoever provides it, and it is only created
# where the package can own it outright.
plan_scripts_binding() {
  local scripts_dir="$CLAUDE_HOME/scripts"
  local bind="$scripts_dir/run-issues"
  local real

  # Already usable — including the dotfiles + submodule shape, where the path
  # is provided through a directory symlink this package must not touch.
  if [ -x "$bind/orchestrate.sh" ]; then
    real="$(resolve_dir "$bind" 2>/dev/null || true)"
    if [ "$real" = "$PKG_ROOT" ]; then
      plan_add skip "$bind already resolves to this package"
      SCRIPTS_BINDING_TARGET="$PKG_ROOT"
    else
      plan_add skip "$bind is provided by another package instance"
      SCRIPTS_BINDING_TARGET="$real"
      warn "$bind resolves to ${real:-an unreadable path}, not $PKG_ROOT; left untouched"
    fi
    return 0
  fi

  if [ ! -e "$scripts_dir" ] && [ ! -L "$scripts_dir" ]; then
    plan_add mkdir "$scripts_dir"
    plan_add link "$PKG_ROOT" "$bind"
    SCRIPTS_BINDING_TARGET="$PKG_ROOT"
    return 0
  fi

  # A directory symlink here belongs to whoever created it, and the run-issues
  # path behind it does not work — writing into it would place this package's
  # binding inside a foreign tree.
  if [ -L "$scripts_dir" ]; then
    refuse "$scripts_dir is a directory symlink -> $(readlink "$scripts_dir") but does not provide run-issues/orchestrate.sh. Fix that tree, or replace the symlink with a real directory and re-run install.sh."
    return 0
  fi
  if [ ! -d "$scripts_dir" ]; then
    refuse "$scripts_dir exists but is not a directory. Move it aside, then re-run install.sh."
    return 0
  fi

  if is_pkg_owned_link "$bind"; then
    plan_add relink "$PKG_ROOT" "$bind"
    SCRIPTS_BINDING_TARGET="$PKG_ROOT"
  elif [ -e "$bind" ] || [ -L "$bind" ]; then
    refuse "$bind exists and is not owned by this package. Move it aside, then re-run install.sh."
  else
    plan_add link "$PKG_ROOT" "$bind"
    SCRIPTS_BINDING_TARGET="$PKG_ROOT"
  fi
}

# plist_program <plist> — echo the program the agent would execute, with a
# literal $HOME expanded the way launchd's `/bin/bash -l -c` wrapper does.
# ProgramArguments is ["/bin/bash", "-l", "-c", "<command>"], so the command is
# the last element and the program is its first word.
plist_program() {
  local plist="$1" count raw
  count="$(plutil -extract ProgramArguments raw -o - "$plist" 2>/dev/null)" || return 1
  case "$count" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$count" -gt 0 ] || return 1
  raw="$(plutil -extract "ProgramArguments.$((count - 1))" raw -o - "$plist" 2>/dev/null)" || return 1
  raw="${raw//\$HOME/$HOME}"
  printf '%s' "${raw%% *}"
}

# program_resolves <program> — true when <program> is executable now, or when
# the scripts binding this run has already planned would make it executable.
#
# Planning and applying are separate passes (INV-OWN, consequence 2), so on a
# clean machine the binding that provides the plists' program exists only as a
# plan entry at this point. A plain [ -x ] test would therefore refuse every
# time, including the run that is about to create the very path it demands.
#
# Only the plists' own program prefix is forgiven; anything outside
# $CLAUDE_HOME/scripts/run-issues/ is not this run's to promise, so it falls
# through to a refusal — the safe direction.
program_resolves() {
  local program="$1" prefix="$CLAUDE_HOME/scripts/run-issues/" rel
  [ -x "$program" ] && return 0
  [ -n "$SCRIPTS_BINDING_TARGET" ] || return 1
  case "$program" in
    "$prefix"*) rel="${program#"$prefix"}" ;;
    *)          return 1 ;;
  esac
  [ -n "$rel" ] || return 1
  [ -x "$SCRIPTS_BINDING_TARGET/$rel" ]
}

# plan_launchagents — opt-in deploy of the poller plists.
#
# Deploying an agent whose program does not exist is worse than not deploying
# it: launchd loads it, fails on every StartInterval tick and reports nothing
# back. So an unresolvable path is a refusal, not a warning.
plan_launchagents() {
  local plist name program dst

  if ! preflight_have plutil; then
    refuse "plutil is not available — LaunchAgents are macOS-only. Drop --with-launchagents on this machine."
    return 0
  fi
  if [ ! -d "$(dirname "$LAUNCH_AGENTS_DIR")" ]; then
    refuse "$(dirname "$LAUNCH_AGENTS_DIR") does not exist — LaunchAgents are macOS-only. Drop --with-launchagents on this machine."
    return 0
  fi
  if [ -e "$LAUNCH_AGENTS_DIR" ] && [ ! -d "$LAUNCH_AGENTS_DIR" ]; then
    refuse "$LAUNCH_AGENTS_DIR exists but is not a directory."
    return 0
  fi
  [ -d "$LAUNCH_AGENTS_DIR" ] || plan_add mkdir "$LAUNCH_AGENTS_DIR"

  for plist in "$PKG_ROOT"/com.claude-issue-runner.*.plist; do
    [ -e "$plist" ] || continue
    name="$(basename "$plist")"
    dst="$LAUNCH_AGENTS_DIR/$name"

    program="$(plist_program "$plist" || true)"
    if [ -z "$program" ]; then
      refuse "$name: could not read ProgramArguments; refusing to deploy an agent whose program is unknown."
      continue
    fi
    if ! program_resolves "$program"; then
      refuse "$name: its program $program is not executable and this install does not provide it. Run install.sh so that $CLAUDE_HOME/scripts/run-issues resolves to this package, or point RUN_ISSUES_CLAUDE_HOME at the home the plists reference. Refusing to deploy an agent that could only fail silently."
      continue
    fi

    if is_pkg_owned_link "$dst"; then
      if [ "$(resolve_link_target "$dst")" = "$plist" ]; then
        plan_add skip "$dst already links to this package"
      else
        plan_add relink "$plist" "$dst"
      fi
    elif [ -e "$dst" ] || [ -L "$dst" ]; then
      # Someone else's plist under our filename: leave it, and do not print
      # launchctl instructions that would load it.
      conflict "$dst is owned by another source; left untouched"
      continue
    else
      plan_add link "$plist" "$dst"
    fi

    # launchd identifies an agent by Label, and tests/test-package-layout.sh
    # holds Label == filename stem, so the stem is a safe source here.
    LAUNCH_LABELS+=("${name%.plist}$TAB$dst")
  done
}

print_launchagent_instructions() {
  local entry label path uid
  [ "${#LAUNCH_LABELS[@]}" -gt 0 ] || return 0
  uid="$(id -u)"
  log ""
  log "LaunchAgent plists are in place. Loading them is left to you on purpose:"
  log "launchd identifies an agent by its Label, not its filename, so a running"
  log "agent with the same label must be booted out first (CLAUDE.md, §11)."
  for entry in "${LAUNCH_LABELS[@]}"; do
    IFS="$TAB" read -r label path <<<"$entry"
    log "  launchctl bootout   gui/$uid/$label   # only if that label is loaded"
    log "  launchctl bootstrap gui/$uid $path"
  done
  log ""
  log "The pollers are host-gated: unless this machine matches the built-in"
  log "default host list, set RUN_ISSUES_POLLER_HOSTS in"
  log "$HOME/.config/run-issues/poller.env or they will no-op on every tick."
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
      --dry-run)           DRY_RUN=1 ;;
      --with-launchagents) WITH_LAUNCHAGENTS=1 ;;
      --quiet)             QUIET=1 ;;
      -h|--help)           usage; exit 0 ;;
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
  # Order matters: plan_scripts_binding publishes SCRIPTS_BINDING_TARGET, which
  # plan_launchagents needs to decide whether the plists' program will resolve
  # once this plan is applied. Reversing the two would refuse every deploy on a
  # machine that does not already have the binding.
  plan_scripts_binding
  if [ "$WITH_LAUNCHAGENTS" -eq 1 ]; then
    plan_launchagents
  fi

  # The refusal gate sits between planning and applying: no refusal can ever
  # coexist with a partial write.
  if [ "${#REFUSALS[@]}" -gt 0 ]; then
    print_refusals
    err "refusing to modify a layout this package does not own — nothing was changed"
    exit 2
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    print_plan
    print_launchagent_instructions
    print_conflicts
    print_summary
    exit 0
  fi

  if ! apply_plan; then
    err "install failed part-way through; re-run to converge"
    exit 3
  fi

  print_launchagent_instructions
  print_conflicts
  print_summary

  if [ "${#CONFLICTS[@]}" -gt 0 ]; then
    exit 4
  fi
  exit 0
}

main "$@"
