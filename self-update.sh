#!/usr/bin/env bash
# self-update.sh — keep the installed package current on a machine, unattended.
#
# The gap this closes (issue #112): a machine's dotfiles sync APPLIES the
# submodule pin but never runs the installer, so a change to the FILE SET (a new
# or removed skill, command or agent) needed a manual `install.sh` run to link
# and prune. This LaunchAgent (StartInterval 3600) runs the installer every tick,
# and — only on a dev clone — also pulls origin/main first.
#
# Two environments differ ONLY in the pull step:
#   * dev clone (a symlinked clone anywhere) — pull + install.
#   * maintainer clone (a pinned dotfiles submodule) — pull is ALWAYS skipped;
#     the pin is owned by dotfiles' bump-run-issues CI and self-update never
#     moves it. Only the install step runs.
#
# The pull is guarded and non-destructive: it runs only when the clone is not a
# submodule, HEAD is `main`, and the tree is clean, and the fetch itself is
# `git pull --ff-only` — never a rebase or reset, so local work is never
# discarded. Any guard failing skips the pull with a logged reason; that is not
# an error. An idle port precedes the pull: if a live run exists on THIS host
# (run.json, status=initialized, host==hostname -s) the WHOLE tick is skipped,
# so code is never moved under a running orchestrator (same idea as the
# dotfiles sync's own idle port).
#
# TRUST BOUNDARY: an unattended pull runs whatever was merged into main on the
# NEXT tick. The review gate is therefore the PR review, not this install
# moment. See README section 7.10.
#
# Config channel is poller.env (LaunchAgent environmentlessness, CLAUDE.md §7).
# Kill switch: RUN_ISSUES_SELF_UPDATE=0 skips the tick. There is NO host gate —
# opt-in is the operator bootstrapping the agent. self-update NEVER calls
# launchctl (same reasons as the installer, CLAUDE.md §11): if the install links
# a new plist it logs a NOTE naming the manual `launchctl bootstrap`.
#
# Exit codes (own space — not the orchestrator's, not the installer's):
#   0  tick complete, or cleanly skipped (idle / kill-switch / pull guard). The
#      pull is always fail-soft: a network error or a non-ff main is a NOTE, not
#      a failure — the next tick retries.
#   1  usage error (unknown flag).
#   2  install phase failed unexpectedly (installer exit not in {0,2,4}); logged,
#      the next tick retries. The installer's own refuse (2) / conflict (4) are a
#      NOTE and DO NOT reach here — they are expected on a maintainer machine.
#
# Run: self-update.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The package root. Read from the environment ONLY (test injection point, the
# way RUN_ISSUES_HOME does for the pollers): the git operations, the version
# summary and the installer all target this directory. In normal use SCRIPT_DIR
# is already correct and nobody needs to set this.
RUN_ISSUES_HOME="${RUN_ISSUES_HOME:-$SCRIPT_DIR}"

# --- Argument parsing (usage error is exit 1, before any side effect) --------
usage() {
  cat <<'EOF'
Usage: self-update.sh

Keeps the installed package current on this machine, unattended: pulls
origin/main into a dev clone when it is safe to do so, then runs install.sh so
new and removed agents, commands and skills are linked and pruned. Intended to
run from a LaunchAgent (StartInterval 3600), not by hand.

Environment:
  RUN_ISSUES_SELF_UPDATE   0 disables the tick (kill switch). Default 1.
  RUN_ISSUES_LOG_DIR       log directory. Default $HOME/Library/Logs.
  RUN_ISSUES_LOG_MAX_BYTES rotation threshold. Default 10485760 (0 disables).

Exit codes:
  0  tick complete, or cleanly skipped (idle / kill-switch / pull guard)
  1  usage error (unknown flag)
  2  install phase failed unexpectedly (installer exit not in {0,2,4})
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) printf 'self-update: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
  shift
done

# --- Library sourcing --------------------------------------------------------
# poller_resolve_watchlist (idle port), rotate_log_if_big (log rotation) and
# runner_version_summary (the tick's version line). Sourced UNGUARDED so a lib
# that failed to resolve fails loudly rather than limping on. poller-config.sh
# carries its own `set -euo pipefail`, which the source turns ON for this shell;
# we clear -e again afterward because the git operations below are best-effort
# and must not abort the script.
# shellcheck source=lib/poller-config.sh
. "${RUN_ISSUES_HOME}/lib/poller-config.sh"
# shellcheck source=lib/log-rotate.sh
. "${RUN_ISSUES_HOME}/lib/log-rotate.sh"
# shellcheck source=lib/version.sh
. "${RUN_ISSUES_HOME}/lib/version.sh"
set +e

# --- Machine configuration (poller.env) --------------------------------------
# launchd hands an agent no environment of its own, so this file is the only
# channel through which a machine configures its LaunchAgents. Sourced, so the
# FILE WINS over an inherited variable — the same idiom the pollers use.
# RUN_ISSUES_HOME is resolved above, from the environment only, before this.
POLLER_ENV_FILE="${RUN_ISSUES_POLLER_ENV_FILE:-${HOME}/.config/run-issues/poller.env}"
if [ -f "$POLLER_ENV_FILE" ]; then
  set +u
  # shellcheck disable=SC1090
  . "$POLLER_ENV_FILE"
  set -u
fi

# --- Logging -----------------------------------------------------------------
LOG_DIR="${RUN_ISSUES_LOG_DIR:-${HOME}/Library/Logs}"
mkdir -p "$LOG_DIR"
LOG="${LOG_DIR}/run-issues-self-update.log"

log() { printf '%s self-update: %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }

# Size-based log rotation (issue #65). At the start of the tick, before the first
# write and before the exec redirect below, rotate any of the three log files
# that has grown past RUN_ISSUES_LOG_MAX_BYTES (default 10 MB; 0 disables). One
# .1 generation is kept. The .stdout/.stderr rotation MUST precede the exec.
RUN_ISSUES_LOG_MAX_BYTES="${RUN_ISSUES_LOG_MAX_BYTES:-10485760}"
rotate_log_if_big "$LOG"                                       "$RUN_ISSUES_LOG_MAX_BYTES"
rotate_log_if_big "${LOG_DIR}/run-issues-self-update.stdout.log" "$RUN_ISSUES_LOG_MAX_BYTES"
rotate_log_if_big "${LOG_DIR}/run-issues-self-update.stderr.log" "$RUN_ISSUES_LOG_MAX_BYTES"

# The plist carries no StandardOutPath/StandardErrorPath keys (launchd expands no
# variables in them), so this script owns its stdout/stderr paths. Not on a TTY:
# a manual run must still print.
if [ ! -t 1 ]; then
  exec >>"${LOG_DIR}/run-issues-self-update.stdout.log" 2>>"${LOG_DIR}/run-issues-self-update.stderr.log"
fi

log "tick start version=$(runner_version_summary "$RUN_ISSUES_HOME")"

# --- Kill switch -------------------------------------------------------------
if [ "${RUN_ISSUES_SELF_UPDATE:-1}" = "0" ]; then
  log "NOTE: disabled via RUN_ISSUES_SELF_UPDATE=0 — skipping tick"
  exit 0
fi

# --- Idle port ---------------------------------------------------------------
# has_live_run — return 0 if any watchlist repo has a run.json with
# status=initialized and host==this host. Filesystem-only, like the poller's
# scan_stalled: an empty/unreadable/absent watchlist means "no known live run"
# (return 1), so a machine that is not configured for auto-run still self-updates.
has_live_run() {
  local watchlist this_host repo_path rj status host
  watchlist=$(poller_resolve_watchlist "${RUN_ISSUES_WATCHLIST:-}" \
    "${HOME}/.config/run-issues/watchlist.json" \
    "${HOME}/dotfiles/machine-studio/run-issues-watchlist.json") || return 1
  [ -f "$watchlist" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e . "$watchlist" >/dev/null 2>&1 || return 1
  this_host=$(hostname -s 2>/dev/null || echo "")
  shopt -s nullglob
  while IFS= read -r repo_path; do
    [ -n "$repo_path" ] || continue
    for rj in "$repo_path"/.claude/run-issues/*/run.json; do
      status=$(jq -r '.status // "initialized"' "$rj" 2>/dev/null || echo "")
      [ "$status" = "initialized" ] || continue
      host=$(jq -r '.host // ""' "$rj" 2>/dev/null || echo "")
      # Empty host = pre-host-field run.json; treat as local (best effort), same
      # as scan_stalled. A live run here means the whole tick is skipped.
      if [ -z "$host" ] || [ "$host" = "$this_host" ]; then
        return 0
      fi
    done
  done < <(jq -r '.repos[]?.path // empty' "$watchlist")
  return 1
}

if has_live_run; then
  log "NOTE: live run present on this host — skipping tick (not moving code under a running orchestrator)"
  exit 0
fi

# --- Pull phase (guarded, non-destructive) -----------------------------------
# pull_guard_reason — echo nothing and return 0 when the pull may proceed, else
# echo the reason and return 1. All three guards read from RUN_ISSUES_HOME.
pull_guard_reason() {
  local super branch dirty
  super=$(git -C "$RUN_ISSUES_HOME" rev-parse --show-superproject-working-tree 2>/dev/null) || super=""
  if [ -n "$super" ]; then
    echo "clone is a dotfiles submodule (pin owned by dotfiles CI)"; return 1
  fi
  branch=$(git -C "$RUN_ISSUES_HOME" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=""
  if [ "$branch" != "main" ]; then
    echo "branch is '${branch:-unknown}', not main"; return 1
  fi
  dirty=$(git -C "$RUN_ISSUES_HOME" status --porcelain 2>/dev/null) || dirty=""
  if [ -n "$dirty" ]; then
    echo "working tree not clean"; return 1
  fi
  return 0
}

if reason=$(pull_guard_reason); then
  log "pull: guards pass — git pull --ff-only"
  if pull_out=$(git -C "$RUN_ISSUES_HOME" pull --ff-only --quiet 2>&1); then
    log "pull: fast-forwarded (or already up to date)"
  else
    # Fail-soft: a non-ff main, no upstream, or a network error is a NOTE, never
    # a failure. --ff-only guarantees nothing local was discarded.
    log "NOTE: pull --ff-only did not apply (nothing destroyed): ${pull_out:-<no output>}"
  fi
else
  log "pull: skipped — $reason"
fi

# --- Install phase -----------------------------------------------------------
# _plist_snapshot <dir> — sorted list of this package's plists under <dir>, so a
# newly-linked plist can be detected across the install call.
_plist_snapshot() {
  ls -1 "$1"/com.claude-issue-runner.*.plist 2>/dev/null | sort
  return 0
}

# _note_new_plists <before> <after> <dir> — for each plist in <after> not in
# <before>, log a NOTE naming the manual `launchctl bootstrap` command.
_note_new_plists() {
  local before="$1" after="$2" uid line
  uid=$(id -u)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if ! printf '%s\n' "$before" | grep -qxF "$line"; then
      log "NOTE: install linked a new LaunchAgent ($(basename "$line")). self-update does NOT call launchctl — bootstrap it manually:"
      log "NOTE:   launchctl bootstrap gui/$uid $line"
    fi
  done <<< "$after"
}

INSTALL_FAILED=0
run_install() {
  local install la_dir before after out rc=0
  install="${RUN_ISSUES_SELF_UPDATE_INSTALL:-$RUN_ISSUES_HOME/install.sh}"
  if [ ! -x "$install" ]; then
    log "NOTE: installer not executable at $install — skipping install phase"
    return 0
  fi
  la_dir="${RUN_ISSUES_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
  before=$(_plist_snapshot "$la_dir")
  out=$("$install" --with-launchagents --quiet 2>&1) || rc=$?
  [ -n "$out" ] && log "install output: $out"
  case "$rc" in
    0) log "install: ok (exit 0)" ;;
    2) log "NOTE: install refused (exit 2) — a target path is foreign-owned; nothing changed" ;;
    4) log "NOTE: install conflict (exit 4) — a foreign file shadows a shipped name; nothing overwritten" ;;
    *) log "NOTE: install FAILED (exit $rc) — will retry next tick"; INSTALL_FAILED=1 ;;
  esac
  after=$(_plist_snapshot "$la_dir")
  _note_new_plists "$before" "$after" "$la_dir"
  return 0
}

run_install

log "tick done"
[ "$INSTALL_FAILED" -eq 1 ] && exit 2
exit 0
