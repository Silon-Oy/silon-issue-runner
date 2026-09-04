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
# Every function is free of persistent side effects: no writes, no exits, no
# globals. Two functions — preflight_probe_claude and preflight_timeout_bin —
# EXECUTE the command they are asked about, because for those two a name on
# PATH does not imply the contract we need. Each names that exception in its
# own header.

set -euo pipefail

# preflight_have <cmd> — 0 if <cmd> is callable, 1 otherwise. Prints nothing;
# the caller owns all output.
preflight_have() {
  command -v "$1" >/dev/null 2>&1
}

# preflight_timeout_bin — echo the name of the available GNU timeout binary:
#   timeout   — GNU coreutils, the Linux default
#   gtimeout  — Homebrew coreutils on macOS
#   ""        — neither; the caller must decide what an unbounded call means
# An empty result is a legitimate answer, not an error, so the return code
# stays 0. Callers assigning this under `set -u` therefore never see an unbound
# variable.
#
# EXECUTES each candidate as `<bin> --version`, and that is the point: on
# Windows the name `timeout` is taken by C:\Windows\System32\timeout.exe, a
# delay tool that shares nothing but the name, and Git Bash puts System32 on
# PATH. `command -v` cannot tell the two apart, so a mere existence check would
# let the wrapper wrap a claude call in the wrong program. GNU timeout answers
# `--version`; the Windows one rejects the flag. stdin is closed for the same
# reason as in preflight_probe_claude: a candidate that decides to read must
# not hang the caller.
#
# Limitation: `command -v` resolves only the FIRST PATH match per name. A
# Windows machine with coreutils installed as `timeout` but System32 earlier on
# PATH therefore yields "" even though a usable binary exists. The outcome is
# safe (an unbounded call, not a wrong one); iterating `type -a` is a separate
# change.
preflight_timeout_bin() {
  local bin="" c
  for c in timeout gtimeout; do
    if preflight_have "$c" && "$c" --version >/dev/null 2>&1 </dev/null; then
      bin="$c"
      break
    fi
  done
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

# preflight_install_hint <key> — echo the fix command for a dependency.
#   key = git | gh | jq | jq-binary | npx | claude | gh-auth | timeout | tmux |
#         python3
# Returns 1 without output for an unknown key.
# Single source of truth for fix commands: install.sh reports them advisorily
# and the orchestrator's S0 gate prints them fatally, so a wording change must
# not have to be repeated in two files. A `case` (not an associative array)
# keeps this working on the bash 3.2 that ships with macOS.
preflight_install_hint() {
  case "$1" in
    git)     printf 'brew install git\n' ;;
    gh)      printf 'brew install gh\n' ;;
    jq)      printf 'brew install jq\n' ;;
    npx)     printf 'brew install node (or nvm install --lts)\n' ;;
    claude)  printf 'npm i -g @anthropic-ai/claude-code\n' ;;
    gh-auth) printf 'gh auth login\n' ;;
    jq-binary) printf 'upgrade jq to 1.7 or newer (Windows: winget upgrade jqlang.jq)\n' ;;
    timeout) printf 'brew install coreutils (Git Bash on Windows: scoop install coreutils)\n' ;;
    tmux)    printf 'brew install tmux\n' ;;
    python3) printf 'xcode-select --install\n' ;;
    git-filter-repo) printf 'brew install git-filter-repo\n' ;;
    *)       return 1 ;;
  esac
}

# preflight_probe_claude <cmd-token...> — run `<cmd-token...> --version` and
# return its exit code (0 usable, 127 missing, 124 wedged). Prints nothing.
#
# One of the two functions in this module that EXECUTE the probed command
# (preflight_timeout_bin is the other), and it earns that exception: the
# default invocation `npx --no-install
# @anthropic-ai/claude-code` exits 127 when the package is not installed even
# though `npx` itself is on PATH, so `command -v` cannot see the failure that
# actually breaks a run. stdin is closed so a CLI that decides to prompt cannot
# hang the caller, and the timeout binary (when present) bounds the call.
preflight_probe_claude() {
  local tb
  tb=$(preflight_timeout_bin)
  if [ -n "$tb" ]; then
    "$tb" 20 "$@" --version >/dev/null 2>&1 </dev/null
  else
    "$@" --version >/dev/null 2>&1 </dev/null
  fi
}

# preflight_jq_binary_ok — 0 when jq's output on THIS platform is safe to read.
# Everywhere but the Windows shells that is unconditionally true and the probe
# is skipped. Under Git Bash it is not: jq is a native Windows executable whose
# stdout is opened in the C runtime's text mode, so every `\n` it writes leaves
# as `\r\n` and every value the package reads out of jq ends in an invisible
# carriage return (lib/jq-binary.sh has the measurement). `jq --binary`, added
# in jq 1.7, is the fix, so a jq that does not take the flag is a dependency
# that cannot do this job — named here rather than left to surface later as a
# path that does not exist or a count that is not a number.
#
# EXECUTES jq, the third exception to this file's no-side-effects rule and for
# the same reason as the other two: a name on PATH does not tell us whether the
# binary honours the contract. `-n` supplies its own input so nothing is read
# from stdin, and the output is discarded.
preflight_jq_binary_ok() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) command jq -b -n 1 >/dev/null 2>&1 ;;
    *) return 0 ;;
  esac
}

# preflight_gate_report <mode> <claude-cmd-token...>
#   mode = probe | have
# Prints ONLY findings (one per line, preflight_report_tool's format) so that a
# silent result means "nothing to report". Returns:
#   0 — no required dependency is missing (optional findings may still print)
#   2 — at least one required dependency is missing
#
# The mode argument encodes who owns the claude command. `probe` is for the
# default npx invocation, whose silent 127 is the failure this gate exists to
# catch. `have` is for a user-supplied RUN_ISSUES_CLAUDE_CMD: an override is an
# explicit claim about a private driver whose `--version` semantics we must not
# guess (and must not execute — a mock would see an uninstrumented call).
#
# Severity is a fact of the dependency, not of the caller: git/gh/jq/claude are
# required because no run can complete without them, while a missing timeout
# binary only degrades claude calls to unbounded — behaviour that predates this
# gate and must not become fatal.
preflight_gate_report() {
  local mode="$1"
  shift

  local fatal=0 cmd line rc

  for cmd in git gh jq; do
    rc=0
    line=$(preflight_report_tool "$cmd" required "$(preflight_install_hint "$cmd")") || rc=$?
    if [ "$rc" -ne 0 ]; then
      printf '%s\n' "$line"
      fatal=1
    fi
  done

  # A jq that is present but too old to read from is still a missing dependency:
  # on Git Bash without `--binary` every value it hands back carries a trailing
  # carriage return, and the resulting failures name innocent code.
  if preflight_have jq && ! preflight_jq_binary_ok; then
    printf 'MISSING (required): jq --binary — %s\n' "$(preflight_install_hint jq-binary)"
    fatal=1
  fi

  if [ "$mode" = "probe" ]; then
    if ! preflight_have npx; then
      printf 'MISSING (required): npx — %s\n' "$(preflight_install_hint npx)"
      fatal=1
    elif ! preflight_probe_claude "$@"; then
      printf 'MISSING (required): @anthropic-ai/claude-code — %s\n' "$(preflight_install_hint claude)"
      fatal=1
    fi
  else
    rc=0
    line=$(preflight_report_tool "${1:-}" required "$(preflight_install_hint claude)") || rc=$?
    if [ "$rc" -ne 0 ]; then
      printf '%s\n' "$line"
      fatal=1
    fi
  fi

  if [ -z "$(preflight_timeout_bin)" ]; then
    printf 'MISSING (optional): timeout/gtimeout — %s\n' "$(preflight_install_hint timeout)"
  fi

  [ "$fatal" -eq 0 ] || return 2
  return 0
}
