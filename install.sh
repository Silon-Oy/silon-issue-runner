#!/usr/bin/env bash
# install.sh — link this package's Claude assets into $HOME/.claude.
#
# Claude Code reads slash commands from $HOME/.claude/commands and skills from
# $HOME/.claude/skills. Those directories are a shared namespace: dotfiles (or
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
#      tested), and the com.legacy -> com.claude-issue-runner migration needs a
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

# poller_host_unset_message — the host gate's own wording, so the line printed
# here at install time and the line a poller prints at run time are literally
# the same function and not two drifting paraphrases. Safe to source: this file
# is pure (no writes, no exits), which is why the host-gate wording lives there
# and not in lib/host-gate-notice.sh, which appends to a log. An installer
# prints; it does not log.
# shellcheck source=lib/poller-config.sh
. "$PKG_ROOT/lib/poller-config.sh"

# Every filesystem location is derived from $HOME (or an explicit override) so
# that the test suite can run against a throwaway home on the very machine
# whose live $HOME/.claude the pollers use.
CLAUDE_HOME="${RUN_ISSUES_CLAUDE_HOME:-$HOME/.claude}"
LAUNCH_AGENTS_DIR="${RUN_ISSUES_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"

# The machine's poller configuration. Read only — the installer reports on this
# file, it never creates or edits it (guessing a hostname is precisely the
# package-to-one-machine coupling issue #152 removed).
POLLER_ENV_FILE="${RUN_ISSUES_POLLER_ENV_FILE:-$HOME/.config/run-issues/poller.env}"

# Directories whose contents this package owns file by file.
#
# The two commands entries are one mechanism, not a special case. Claude Code
# derives a command's namespace from its subdirectory, so the shipped files live
# in commands/issue-runner/ and resolve as /issue-runner:<name>. The bare
# commands entry is kept because its *.md glob now matches nothing: wanted stays
# empty and plan_prune_owned removes every package-owned link left flat in
# $HOME/.claude/commands by an earlier install. Without it a machine would
# carry both /new-epic and /issue-runner:new-epic. Foreign entries are untouched
# either way, and the real issue-runner subdirectory is not a symlink so the
# prune skips it.
LINKED_DIRS="commands commands/issue-runner"

# Directories this package no longer ships into, but whose links it once owned.
# A removed directory cannot be pruned by LINKED_DIRS: plan_link_dir would also
# mkdir the target, recreating on a clean machine the very directory that was
# removed. So the migration gets its own named list — one line to read, one line
# to delete once no machine can still carry the stale links.
#
#   agents/ — the agent factory's four subagent definitions. Removed with the
#             factory commands; nothing in the runner ever invoked them.
PRUNED_DIRS="agents"

# Directories whose contents this package owns entry by entry, where each entry
# is itself a directory (a skill is <name>/SKILL.md plus attachments).
SKILL_DIRS="skills"

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

Links this package's slash commands and skills into $HOME/.claude, entry by
entry, so that they coexist with assets from other sources.

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
  RUN_ISSUES_POLLER_ENV_FILE     default: $HOME/.config/run-issues/poller.env
                                 (read only, for the advisory host-gate report)

Exit codes:
  0  success (or --dry-run completed)
  1  usage error
  2  refused — a target path is owned by something else, or `ln -s` does not
     produce a real symlink here; nothing was changed
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

# probe_symlink_support — does `ln -s` on this machine produce a real symlink?
#
# Not every environment answers yes. Git Bash on Windows accepts `ln -s` and
# silently copies unless Developer Mode is on and MSYS=winsymlinks:nativestrict
# is set. That is the one failure mode INV-OWN cannot survive: ownership is
# decided by reading the symlink target, so a copy reads back as a foreign
# file. The install would look like it succeeded and the *next* run would
# refuse — at a different path, with a reason that names the wrong problem.
#
# The probe is a capability question, so it is answered by doing the thing, the
# same way preflight_probe_claude runs the CLI rather than looking for it: a
# uname test would name a platform, not the behaviour, and would still be wrong
# on the Windows machine that is configured correctly.
#
# It writes to a throwaway directory of its own, never into $HOME. Nothing here
# may enter PLAN either — the plan is the record of what is written under the
# home, and a probe that cleans up after itself writes nothing at all.
probe_symlink_support() {
  local dir target link rc=1
  dir="$(mktemp -d 2>/dev/null)" || return 1
  target="$dir/target"
  link="$dir/link"
  if : >"$target" 2>/dev/null \
    && ln -s "$target" "$link" 2>/dev/null \
    && [ -L "$link" ] \
    && [ "$(readlink "$link" 2>/dev/null)" = "$target" ]; then
    rc=0
  fi
  rm -rf "$dir"
  return "$rc"
}

# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------

# plan_symlink_capability — the planning phase's first gate.
#
# Placed ahead of every other plan_* function on purpose: the refusal it raises
# is about the mechanism the whole plan is made of, so learning it after the
# other gates have run would only delay the same exit 2. A refusal here costs
# zero writes for the ordinary structural reason (INV-OWN consequence 2), not
# because this function is careful.
plan_symlink_capability() {
  if probe_symlink_support; then
    log "symlink capability: ok — ln -s produced a real symlink (probed in a temporary directory, outside \$HOME)"
    return 0
  fi
  refuse "ln -s does not produce a real symlink on this machine (probed in a temporary directory). This package decides ownership by reading a symlink's target, so a copy would read back as a foreign file and the next install would refuse for the wrong reason. On Windows/Git Bash: enable Developer Mode, then re-run with MSYS=winsymlinks:nativestrict in the environment (MSYS=winsymlinks:nativestrict bash install.sh)."
}

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

# plan_link_dir <name> [mode] — plan the per-entry links for $PKG_ROOT/<name>
# into $CLAUDE_HOME/<name>, and plan the removal of package-owned links that no
# longer correspond to a shipped entry.
#
# mode selects both what an entry is and how a foreign directory at the target
# is treated:
#
#   files  (default) — each entry is a *.md file (commands). A foreign
#                      directory at the target is a REFUSAL that aborts the
#                      whole run: the slash commands are the only thing this
#                      package installs into $HOME/.claude that a human reaches
#                      for directly, so a run that skipped them has installed
#                      nothing usable and must stop rather than report success.
#                      Note what the justification is NOT: the runner keeps
#                      working without a single link here, because the pollers
#                      invoke the scripts directly. What a foreign directory
#                      costs is the entry surface, not the automation.
#
#   skills           — each entry is a <name>/SKILL.md subdirectory, linked at
#                      directory level. A foreign directory at the target is a
#                      CONFLICT, not a refusal: the skill is extra guidance whose
#                      absence breaks nothing, while $HOME/.claude/skills may
#                      legitimately be a whole-directory symlink owned by another
#                      source (a dotfiles tree that has not been split into
#                      per-entry links). Refusing there would abort the whole
#                      install — including the commands — over an optional
#                      extra. So skills degrades to a conflict line and lets the
#                      core install proceed.
#
# The ownership predicate (is_pkg_owned_link) and the name-based prune are
# identical for both modes: a directory symlink into the package is owned just
# as a file symlink is.
plan_link_dir() {
  local name="$1" mode="${2:-files}"
  local src_dir="$PKG_ROOT/$name" dst_dir="$CLAUDE_HOME/$name"
  local src base dst current
  local wanted=() srcs=()

  # A whole-directory symlink (or a non-directory) means another source owns the
  # directory itself (the pre-split dotfiles layout). Writing into it would place
  # this package's entries in a tree it does not own. Under files mode this is
  # fatal to the whole run; under skills mode it degrades to a conflict so the
  # core install still completes — see the header for why.
  if [ -L "$dst_dir" ]; then
    if [ "$mode" = skills ]; then
      conflict "$dst_dir is a directory symlink -> $(readlink "$dst_dir"); skill not installed. Replace it with a real directory holding per-entry symlinks, then re-run install.sh."
    else
      refuse "$dst_dir is a directory symlink -> $(readlink "$dst_dir"). Replace it with a real directory holding per-file symlinks, then re-run install.sh."
    fi
    return 0
  fi
  if [ -e "$dst_dir" ] && [ ! -d "$dst_dir" ]; then
    if [ "$mode" = skills ]; then
      conflict "$dst_dir exists but is not a directory; skill not installed. Move it aside, then re-run install.sh."
    else
      refuse "$dst_dir exists but is not a directory. Move it aside, then re-run install.sh."
    fi
    return 0
  fi
  [ -d "$dst_dir" ] || plan_add mkdir "$dst_dir"

  # Enumerate shipped entries. Skills are directories carrying a SKILL.md; the
  # trailing slash from the */ glob is stripped so the link target has none.
  if [ "$mode" = skills ]; then
    for src in "$src_dir"/*/; do
      [ -f "${src}SKILL.md" ] || continue
      srcs+=("${src%/}")
    done
  else
    for src in "$src_dir"/*.md; do
      [ -e "$src" ] || continue
      srcs+=("$src")
    done
  fi

  for src in ${srcs[@]+"${srcs[@]}"}; do
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

  plan_prune_owned "$dst_dir" ${wanted[@]+"${wanted[@]}"}
}

# plan_prune_owned <dst_dir> [kept-name...] — plan the removal of every
# package-owned link in <dst_dir> whose basename is not in the kept set.
#
# The decision rests on the name alone, never on whether the link resolves — a
# shipped name that currently dangles (a file moved inside the package) is
# already covered by the relink in plan_link_dir, and pruning it here would undo
# that relink, since apply runs the plan in order.
#
# Read-only with respect to the directory itself: it never plans a mkdir. That
# is what lets plan_prune_dir reuse it for a directory the package has stopped
# shipping into, where creating the target would be exactly wrong.
plan_prune_owned() {
  local dst_dir="$1"; shift
  local entry ebase keep name

  [ -d "$dst_dir" ] || return 0
  for entry in "$dst_dir"/*; do
    is_pkg_owned_link "$entry" || continue
    ebase="$(basename "$entry")"
    keep=0
    for name in "$@"; do
      if [ "$name" = "$ebase" ]; then keep=1; break; fi
    done
    if [ "$keep" -eq 0 ]; then
      plan_add unlink "$entry"
    fi
  done
}

# plan_prune_dir <name> — migration path for a directory this package used to
# link into and no longer does (PRUNED_DIRS).
#
# It is plan_link_dir with the shipped set empty, minus the mkdir: a machine
# that still carries the old links gets them removed, and a machine that never
# had them gets nothing — no empty directory conjured for a directory the
# package has removed. INV-OWN limits the prune to links resolving inside this
# package root, so foreign files inside the directory are passed over.
#
# A whole-directory symlink at the target is skipped outright, matching what
# plan_link_dir refuses for: the directory belongs to another source, and a link
# living inside it is that source's to remove even when its target resolves here.
# Nothing is aborted, because with no shipped entries there is no install to
# leave half-done — the stale links simply stay until that tree is fixed.
plan_prune_dir() {
  local dst_dir="$CLAUDE_HOME/$1"
  if [ -L "$dst_dir" ]; then
    return 0
  fi
  plan_prune_owned "$dst_dir"
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
  log "agent with the same label must be booted out first (CLAUDE.md, §10)."
  for entry in "${LAUNCH_LABELS[@]}"; do
    IFS="$TAB" read -r label path <<<"$entry"
    log "  launchctl bootout   gui/$uid/$label   # only if that label is loaded"
    log "  launchctl bootstrap gui/$uid $path"
  done
  log ""
  log "The pollers are host-gated and the gate has no default: set"
  log "RUN_ISSUES_POLLER_HOSTS in $HOME/.config/run-issues/poller.env"
  log "to a glob matching \`hostname -s\`, or they will no-op on every tick."
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

# The reason a tool is needed is written here (it is installer-specific), while
# the command that installs it comes from preflight_install_hint — the same
# source the orchestrator's S0 gate quotes, so a user who reads one message and
# then hits the other is told to type the same thing.
report_preflight() {
  local tb
  log "dependencies (advisory — a missing tool never blocks the install):"
  log "  $(preflight_report_tool git required "needed to update the package (submodule pin); install: $(preflight_install_hint git)" || true)"
  log "  $(preflight_report_tool gh required "GitHub CLI — orchestrate.sh and pr-watch.sh depend on it; install: $(preflight_install_hint gh)" || true)"
  log "  $(preflight_report_tool jq required "JSON handling in orchestrate.sh, poller.sh and pr-watch.sh; install: $(preflight_install_hint jq)" || true)"
  log "  $(preflight_report_tool npx required "the default RUN_ISSUES_CLAUDE_CMD invokes the Claude CLI via npx; install: $(preflight_install_hint npx)" || true)"
  log "  $(preflight_report_tool tmux optional "only the pollers need it; install: $(preflight_install_hint tmux)" || true)"
  log "  $(preflight_report_tool python3 optional "only the Ohjaamo action service needs it (action-server.sh); install: $(preflight_install_hint python3)" || true)"
  tb="$(preflight_timeout_bin)"
  if [ -n "$tb" ]; then
    log "  ok: $tb"
  else
    log "  MISSING (optional): timeout/gtimeout — claude calls would run unbounded; install: $(preflight_install_hint timeout)"
  fi
}

# poller_env_values <file> — echo the three host-gate-relevant settings the
# machine's poller.env produces, one KEY=VALUE line each.
#
# The file is SOURCED, not grepped, because that is how every run-time reader
# consumes it: a poller.env may set a variable conditionally or derive it from
# another, and a grep would answer a question about the text rather than about
# the configuration.
#
# The three names are unset first, because a LaunchAgent — the only production
# mode — is handed no environment at all. A value that exists only in the shell
# running the installer would otherwise report an all-clear for a machine that
# will still fail the gate at the next tick.
#
# The subshell's own stdout is discarded and the answer is written to fd 3, so
# a poller.env that echoes cannot inject a KEY=VALUE line into the reply.
poller_env_values() {
  local file="$1"
  (
    exec 3>&1 >/dev/null 2>/dev/null
    set +eu
    unset RUN_ISSUES_POLLER_HOSTS RUN_ISSUES_ACTION_HOSTS RUN_ISSUES_ACTION_BASE
    if [ -f "$file" ]; then
      # shellcheck disable=SC1090
      . "$file"
    fi
    printf 'POLLER_HOSTS=%s\n' "${RUN_ISSUES_POLLER_HOSTS:-}" >&3
    printf 'ACTION_HOSTS=%s\n' "${RUN_ISSUES_ACTION_HOSTS:-}" >&3
    printf 'ACTION_BASE=%s\n' "${RUN_ISSUES_ACTION_BASE:-}" >&3
  )
}

# report_host_gate — advisory, read-only report on the host gate (issue #170).
#
# The gate is fail-closed and has no default (#152), so a machine whose
# poller.env does not set RUN_ISSUES_POLLER_HOSTS runs nothing. Issue #160 put
# that line where it can be read, but it is still only produced AT RUN TIME —
# at a moment when nobody is watching, and the discovery path stays "the
# automation has done nothing" -> suspicion -> opening a log. Installing is the
# one moment a human is present and reading output, so the same line is offered
# here too. This ADDS an earlier observation point; it replaces nothing.
#
# Advisory on purpose, never a refusal: poller.env is machine configuration and
# may legitimately be written after the install, so this must not touch the
# exit code. (Contrast the plist gate, which does refuse — a program path that
# does not resolve cannot fix itself without a new install.)
#
# It also stays out of ownership and planning entirely: it only reads, and its
# result feeds neither PLAN, REFUSALS nor CONFLICTS. Called from main() beside
# report_preflight for that reason.
report_host_gate() {
  local host poller_hosts="" action_hosts="" action_base="" key value
  host="$(hostname -s 2>/dev/null || echo unknown)"

  while IFS='=' read -r key value; do
    case "$key" in
      POLLER_HOSTS) poller_hosts="$value" ;;
      ACTION_HOSTS) action_hosts="$value" ;;
      ACTION_BASE)  action_base="$value" ;;
    esac
  done < <(poller_env_values "$POLLER_ENV_FILE")

  log "host gate (advisory — poller.env is machine configuration and may be written after this install):"
  if [ ! -f "$POLLER_ENV_FILE" ]; then
    log "  note: $POLLER_ENV_FILE does not exist yet"
  fi

  if [ -n "$poller_hosts" ]; then
    log "  ok: RUN_ISSUES_POLLER_HOSTS=$poller_hosts (this host: $host)"
  else
    log "  $(poller_host_unset_message RUN_ISSUES_POLLER_HOSTS "$POLLER_ENV_FILE" "$host")"
  fi

  # The action service is opt-in: without RUN_ISSUES_ACTION_BASE an unset
  # RUN_ISSUES_ACTION_HOSTS is the correct state, not an error. Warning
  # unconditionally would put a line about Ohjaamo in front of every machine
  # that does not use it.
  if [ -z "$action_base" ]; then
    log "  ok: RUN_ISSUES_ACTION_HOSTS not needed — RUN_ISSUES_ACTION_BASE is unset, so the Ohjaamo action service is off"
  elif [ -n "$action_hosts" ]; then
    log "  ok: RUN_ISSUES_ACTION_HOSTS=$action_hosts (this host: $host)"
  else
    log "  $(poller_host_unset_message RUN_ISSUES_ACTION_HOSTS "$POLLER_ENV_FILE" "$host")"
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
  report_host_gate

  plan_symlink_capability
  for d in $LINKED_DIRS; do
    plan_link_dir "$d" files
  done
  for d in $PRUNED_DIRS; do
    plan_prune_dir "$d"
  done
  # Skills come after the core directories: on the maintainer's machine skills
  # produces a conflict (its target is a directory symlink) but the commands
  # must still install, and the summary reads more naturally with the core
  # links reported before the conflict line.
  for d in $SKILL_DIRS; do
    plan_link_dir "$d" skills
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
    # Deliberately reasonless: the REFUSED lines above each name their own
    # cause, and not every refusal is about ownership — the symlink-capability
    # probe refuses about the machine. Naming one cause here would restate the
    # very mistake this gate exists to avoid.
    err "refusing — nothing was changed"
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
