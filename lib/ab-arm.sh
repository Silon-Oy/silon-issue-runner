#!/usr/bin/env bash
# lib/ab-arm.sh — A/B arm of one run (issue #308).
#
# An opt-in experiment compares two per-phase settings in production runs
# without running anything twice: each run is assigned ONCE to arm A (current
# settings) or arm B (the experimental value), the arm is recorded in run.json
# as .ab_arm, and every Claude call of that run reads it back from there.
#
# The arm is a property of the run, not of the process: --restart, --resume,
# --continue and the PR watcher's agents are separate processes that never
# re-assign, they only read run.json. That is what keeps the arm stable for the
# whole run without any bookkeeping of its own.
#
# The mechanism knows nothing about models or efforts — it only answers "is an
# experiment defined" and "which arm is this run in". The settings themselves
# live in lib/claude-call.sh (RUN_ISSUES_AB_CLAUDE_{MODEL,EFFORT}[_<PHASE>]); a
# future experiment on something else (a prompt variant, say) would define its
# own RUN_ISSUES_AB_* variables and read ab_arm_of the same way.
#
# Function-only: safe to source more than once.

# The variable-name prefix of every experiment definition. Read INDIRECTLY at
# call time (never a source-time default), so a machine env file sourced after
# this module still reaches it (CLAUDE.md §5.5).
AB_VAR_PREFIX="RUN_ISSUES_AB_CLAUDE_"

# ab_experiment_defined — 0 when at least one experiment variable is non-empty.
# Empty = not set, like every other RUN_ISSUES_CLAUDE_* setting.
ab_experiment_defined() {
  local v
  for v in $(compgen -A variable "$AB_VAR_PREFIX"); do
    [ -n "${!v:-}" ] && return 0
  done
  return 1
}

# ab_arm_pick — print A or B. Random, not alternating: alternation needs a
# shared counter that concurrent runs on two machines would have to lock, and a
# coin flip gives the same expected split with no state at all.
# RUN_ISSUES_AB_ARM=A|B forces the arm (tests; an operator pinning a run).
ab_arm_pick() {
  case "${RUN_ISSUES_AB_ARM:-}" in
    A|B) printf '%s' "$RUN_ISSUES_AB_ARM"; return 0 ;;
  esac
  if [ $((RANDOM % 2)) -eq 0 ]; then printf 'A'; else printf 'B'; fi
}

# ab_arm_of <run-dir> — the run's recorded arm, or nothing (no experiment when
# the run started, no run.json, unreadable file). Never fails.
ab_arm_of() {
  local f="$1/run.json"
  [ -f "$f" ] || return 0
  jq -r '.ab_arm // empty' "$f" 2>/dev/null || true
}

# ab_arm_assign <run-dir> — record an arm for the run when an experiment is
# defined and none is recorded yet; print the arm in effect (or nothing).
# Without an experiment, run.json is not touched: no ab_arm field at all.
# Needs state_set (lib/state.sh).
ab_arm_assign() {
  local run_dir="$1" arm
  arm=$(ab_arm_of "$run_dir")
  if [ -z "$arm" ] && ab_experiment_defined; then
    arm=$(ab_arm_pick)
    state_set "$run_dir" ab_arm "$arm"
  fi
  printf '%s' "$arm"
}
