#!/usr/bin/env bash
# lib/paths.sh — platform defaults for the lock root and the log directory.
#
# WHY THIS EXISTS. Both defaults were hard-coded to macOS conventions
# (~/Library/Application Support, ~/Library/Logs) in nine separate places. On
# Linux and on Windows/MSYS that shape is wrong twice over: it is not where
# anyone looks, and it plants a `Library` directory in a home directory that has
# no such concept. RUN_ISSUES_LOCK_ROOT and RUN_ISSUES_LOG_DIR always allowed a
# manual override — this removes the need to set them by hand (issue #216).
#
# THE BRANCH SHAPE IS LOAD-BEARING. The test is `uname -s = Darwin` -> macOS,
# EVERYTHING ELSE -> XDG. It is deliberately not an allow-list of the non-macOS
# platforms: `Linux` is easy to remember and `MINGW64_NT-10.0` is not, so a
# whitelist would silently leave Windows on the macOS default — exactly the bug
# this file removes. Same idiom as the sibling `uname -s` call sites that pick
# the portable `stat` flag (lib/locking.sh:_lock_mtime, orchestrate.sh,
# lib/github-app-auth.sh, lib/machine-env.sh).
#
# XDG_STATE_HOME, not XDG_DATA_HOME or XDG_CACHE_HOME: both the locks and the
# poller logs are state that should survive a reboot but that a user would not
# miss if it were lost, which is exactly what the base-directory spec reserves
# the state directory for. The status cache already uses XDG_CACHE_HOME and is
# untouched.
#
# macOS is unchanged, bit for bit: existing installations are not migrated, so
# no run in flight loses its lock and no poller loses its log tail.
#
# Defines functions only; no top-level work and no `set`. Sourcing is
# side-effect-free, which matters because both pollers source this ABOVE their
# host gate and above the `exec` redirect that opens their logs.

# _paths_xdg_state_home — $XDG_STATE_HOME when set and non-empty, else the
# spec's own fallback. An empty value is treated as unset, per the spec.
_paths_xdg_state_home() {
  printf '%s' "${XDG_STATE_HOME:-${HOME}/.local/state}"
}

# _paths_is_darwin — 0 on macOS. `uname` is invoked through PATH so the unit
# test can shim it; a failed invocation degrades to "not Darwin", which is the
# branch that needs no macOS-specific directory layout to exist.
_paths_is_darwin() {
  [ "$(uname -s 2>/dev/null || printf '')" = "Darwin" ]
}

# default_lock_root — default value for RUN_ISSUES_LOCK_ROOT.
default_lock_root() {
  if _paths_is_darwin; then
    printf '%s/Library/Application Support/run-issues/locks' "$HOME"
  else
    printf '%s/run-issues/locks' "$(_paths_xdg_state_home)"
  fi
}

# default_log_dir — default value for RUN_ISSUES_LOG_DIR.
#
# The two defaults are separate functions rather than one that returns both,
# because on macOS they are not siblings: the lock root is namespaced under
# `run-issues/` inside Application Support while the logs go straight into the
# shared ~/Library/Logs. Under XDG they are siblings. One function returning a
# pair would have to encode that asymmetry anyway, so two thin functions over a
# shared branch is the simplest shape that models the relation.
default_log_dir() {
  if _paths_is_darwin; then
    printf '%s/Library/Logs' "$HOME"
  else
    printf '%s/run-issues/logs' "$(_paths_xdg_state_home)"
  fi
}
