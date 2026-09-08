#!/usr/bin/env bash
# machine-env.sh — sourcing the machine-local env file with CALLER PRECEDENCE.
#
# WHY THE FILE EXISTS. Both pollers run as LaunchAgents, which do NOT inherit an
# interactive shell's environment. Secrets the implementer needs to install
# private dependencies — GITHUB_TOKEN (read:packages) above all — are therefore
# absent, and a silent dependency-install failure used to burn the whole
# implementer timeout budget. A machine-local, gitignored shell file (default
# ~/.config/run-issues/env, override with RUN_ISSUES_ENV_FILE) delivers them.
#
# WHY PRECEDENCE (issue #144). The file is plain shell full of `export FOO=bar`,
# and `export` beats a command-prefix assignment. Sourcing it therefore
# OVERWROTE whatever the caller had deliberately set. The tests set
# `RUN_ISSUES_CLAUDE_CMD="$BIN/claude"` to stub the agent; on a machine whose env
# file exports the real one, `orchestrate.sh` silently ran the REAL claude CLI
# with a 3600 s timeout — measured 2026-08-31, `tests/run-all.sh` launched live,
# billed agent runs against a temp repo and nothing in the output said so. Two
# tests with the same name did two different things on two machines.
#
# THE RULE (not a list). Inside the package's OWN configuration namespaces —
# RUN_ISSUES_* and PR_WATCH_* — a value that was already set when the script
# started WINS over the file. Everything else keeps the old file-wins behaviour,
# which is correct for its actual purpose: nobody hand-sets GITHUB_TOKEN before
# invoking the orchestrator, and the delivery channel must keep working.
#
# A namespace rule rather than a per-variable exception list is the point: an
# exception list would silently fail to cover the next variable someone adds,
# which is exactly how this bug survived (poller.env's deliberate file-wins
# semantics names RUN_ISSUES_HOME and RUN_ISSUES_POLLER_ENV_FILE as structural
# exceptions — CLAUDE.md §7 — and the same reasoning was never extended here).
#
# "Set to empty" counts as SET: the caller chose it, so the file does not
# overwrite it.
#
# WHEN "ALREADY SET" IS MEASURED (issue #200). The rule above is only as good as
# the moment it reads the environment. Taking the snapshot inside
# source_machine_env made every `${VAR:-default}` that any module had already
# materialised look like a deliberate caller choice: lib/claude-call.sh is
# sourced first and assigns RUN_ISSUES_CLAUDE_CMD/_MODEL/_TIMEOUT at source
# time, so the package's own default was restored OVER the env file's value
# and ~/.config/run-issues/env could no longer name the CLI at all. Measured on
# two machines (when that default was still the npx invocation): S0 preflight
# failed with "MISSING (required): @anthropic-ai/claude-code" while the env file
# named an installed driver.
#
# The snapshot is therefore taken by machine_env_capture, which entry points
# call BEFORE loading any library. "The caller" then means what it says: the
# process environment as the script was invoked, not whatever the package had
# assigned to itself in between.
#
# `compgen -e` (exported variables only) was considered and rejected: orchestrate.sh
# exports RUN_ISSUES_AUTO — and, on the repo-config path, RUN_ISSUES_CLAUDE_TIMEOUT —
# before source_machine_env runs, so export-ness does not separate the caller
# from the package either.
#
# Pure function definitions — sourcing this file has no side effects.

# _machine_env_log <message> — logs through the caller's `log` when it has one
# (orchestrate.sh writes to its run log), else to stderr. Same discovery pattern
# as lib/run-terminate.sh, and the reason pr-watch.sh's copy of this logic was
# never factored out before.
_machine_env_log() {
  if declare -F log >/dev/null 2>&1; then
    log "$1"
  else
    printf '%s machine-env: %s\n' "$(date -u +%FT%TZ)" "$1" >&2
  fi
}

# _machine_env_snapshot — prints re-executable `NAME=<quoted>` assignments for
# every currently-set variable in the package's own namespaces. printf %q keeps
# values with spaces, quotes or newlines intact through the eval.
_machine_env_snapshot() {
  local n
  for n in $(compgen -v 2>/dev/null | grep -E '^(RUN_ISSUES_|PR_WATCH_)' || true); do
    printf '%s=%q\n' "$n" "${!n}"
  done
}

# The captured caller environment, and whether it was captured at all. Both are
# read through `${VAR:-}` on load so that sourcing this file twice (orchestrate.sh
# has guards of this shape elsewhere) cannot discard a capture already taken.
_MACHINE_ENV_CAPTURED="${_MACHINE_ENV_CAPTURED:-}"
_MACHINE_ENV_CAPTURED_VALUES="${_MACHINE_ENV_CAPTURED_VALUES:-}"

# machine_env_capture — record the caller's RUN_ISSUES_*/PR_WATCH_* values NOW.
#
# Call it as early as an entry point can: after resolving SCRIPT_DIR and before
# sourcing any other library, so that no module's own `${VAR:-default}` has run
# yet (see the header). Idempotent — a second call keeps the first capture, so
# the earliest caller wins and a re-source cannot widen the snapshot.
machine_env_capture() {
  [ -z "$_MACHINE_ENV_CAPTURED" ] || return 0
  _MACHINE_ENV_CAPTURED_VALUES=$(_machine_env_snapshot)
  _MACHINE_ENV_CAPTURED=1
}

# source_machine_env — source $RUN_ISSUES_ENV_FILE, then restore the caller's
# own RUN_ISSUES_*/PR_WATCH_* values over anything the file changed.
#
# Absent file => one log line and no injection, exactly as before (no regression).
# The file holds secrets, so a laxer mode than 0600/0400 is a WARNING, never a
# failure — refusing to run would turn a permissions nit into an outage.
source_machine_env() {
  local f="${RUN_ISSUES_ENV_FILE:-$HOME/.config/run-issues/env}"
  if [ ! -f "$f" ]; then
    _machine_env_log "no machine-local env file at $f — proceeding without it (no secrets injected)"
    return 0
  fi

  local perm=""
  if [ "$(uname -s)" = "Darwin" ]; then
    perm=$(stat -f '%Lp' "$f" 2>/dev/null || echo "")
  else
    perm=$(stat -c '%a' "$f" 2>/dev/null || echo "")
  fi
  case "$perm" in
    600|400|"") : ;;
    *) _machine_env_log "WARNING: env file $f has permissions $perm — recommend 'chmod 600 $f' (it holds secrets)" ;;
  esac

  # Prefer the early capture. Falling back to a snapshot taken here keeps the
  # function usable on its own (unit tests, a future caller that never calls
  # machine_env_capture): the precedence rule still holds, only the definition of
  # "the caller" degrades to "whatever is set right now". Fail-soft on purpose —
  # a public function that silently depends on call order would be its own trap.
  local caller_values
  if [ -n "$_MACHINE_ENV_CAPTURED" ]; then
    caller_values="$_MACHINE_ENV_CAPTURED_VALUES"
  else
    caller_values=$(_machine_env_snapshot)
  fi

  _machine_env_log "sourcing machine-local env file: $f"
  # The file is hand-written shell, not authored for `set -euo pipefail`, so
  # relax while sourcing and restore afterwards.
  set +eu
  # shellcheck disable=SC1090
  . "$f"
  # Caller precedence. Re-applying the snapshot only touches names the caller had
  # already set; variables the file introduces are untouched, so secret delivery
  # is unchanged. Assignments run at the caller's scope (no `local` here), so the
  # values are global exactly as the file's own exports are.
  eval "$caller_values"
  set -eu
}
