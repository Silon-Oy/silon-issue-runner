#!/usr/bin/env bash
# lib/preflight.sh — shared external-dependency probe.
#
# Two callers with opposite policies need the same facts: install.sh only
# reports what is missing (an installer must not refuse to place symlinks just
# because `gh` is absent — the user can install it afterwards), while a doctor
# command needs a missing required tool to be fatal. Keeping the probe pure and
# encoding severity in the return code lets both share one source of truth
# instead of drifting apart in two copies.
#
# Every function is side-effect free: no writes, no exits, no globals.

set -euo pipefail

# preflight_have <cmd> — 0 if <cmd> is callable, 1 otherwise. Prints nothing;
# the caller owns all output.
preflight_have() {
  command -v "$1" >/dev/null 2>&1
}

# preflight_timeout_bin — echo the name of the available timeout binary:
#   timeout   — GNU coreutils, the Linux default
#   gtimeout  — Homebrew coreutils on macOS
#   ""        — neither; the caller must decide what an unbounded call means
# An empty result is a legitimate answer, not an error, so the return code
# stays 0. Callers assigning this under `set -u` therefore never see an unbound
# variable.
preflight_timeout_bin() {
  local bin=""
  if preflight_have timeout; then
    bin="timeout"
  elif preflight_have gtimeout; then
    bin="gtimeout"
  fi
  printf '%s' "$bin"
}

# preflight_report_tool <cmd> <level> <hint>
#   level = required | optional
# Prints one line and returns the severity of the finding:
#   0 — present            "ok: <cmd>"
#   1 — missing, optional  "MISSING (optional): <cmd> — <hint>"
#   2 — missing, required  "MISSING (required): <cmd> — <hint>"
# The 1/2 split is the whole point of the function: it lets an advisory caller
# and a fatal caller share the same probe and the same wording.
preflight_report_tool() {
  local cmd="$1" level="$2" hint="${3:-}"

  if preflight_have "$cmd"; then
    printf 'ok: %s\n' "$cmd"
    return 0
  fi

  printf 'MISSING (%s): %s — %s\n' "$level" "$cmd" "$hint"
  if [ "$level" = "required" ]; then
    return 2
  fi
  return 1
}
