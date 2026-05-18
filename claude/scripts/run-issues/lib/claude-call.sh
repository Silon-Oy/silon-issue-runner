#!/usr/bin/env bash
# lib/claude-call.sh — invoke the claude CLI for a single orchestrated step.
#
# Each step has:
#   - a prompt file (already rendered with placeholders substituted)
#   - an output file:  <run-dir>/<step-id>.out
#   - an exit-code file: <run-dir>/<step-id>.exit
# This separation keeps the orchestrator state-machine simple (it just
# checks the exit file) and lets prompts be re-read for debugging.

set -euo pipefail

# Hard wall-clock budget per claude invocation. 30 minutes is enough for
# implementer cycles that include commits + post-commit hooks; if you
# need longer, the prompt is probably too big.
RUN_ISSUES_CLAUDE_TIMEOUT="${RUN_ISSUES_CLAUDE_TIMEOUT:-1800}"

# Path to a `timeout` binary. macOS ships `gtimeout` via coreutils;
# fall back to a no-op wrapper that just exec's the command if no
# timeout is available.
_resolve_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    printf 'timeout %s' "$RUN_ISSUES_CLAUDE_TIMEOUT"
  elif command -v gtimeout >/dev/null 2>&1; then
    printf 'gtimeout %s' "$RUN_ISSUES_CLAUDE_TIMEOUT"
  else
    printf '' # no-op
  fi
}

# call_claude <run-dir> <step-id> <prompt-file>
# Returns the claude process exit code (0 on success). Always writes the
# .out and .exit files even on timeout or interruption.
call_claude() {
  local run_dir="$1"
  local step_id="$2"
  local prompt_file="$3"

  local out_file="$run_dir/${step_id}.out"
  local exit_file="$run_dir/${step_id}.exit"

  local timeout_prefix
  timeout_prefix=$(_resolve_timeout)

  local rc=0
  if [ -n "$timeout_prefix" ]; then
    # shellcheck disable=SC2086
    $timeout_prefix claude --dangerously-skip-permissions -p "$(cat "$prompt_file")" > "$out_file" 2>&1 || rc=$?
  else
    claude --dangerously-skip-permissions -p "$(cat "$prompt_file")" > "$out_file" 2>&1 || rc=$?
  fi

  printf '%s\n' "$rc" > "$exit_file"
  return "$rc"
}

# render_prompt <template-file> <output-file> <key1=val1> [<key2=val2> ...]
# Substitutes {{KEY}} placeholders in the template. Values may contain
# arbitrary text; substitution is done line-safe via awk to avoid shell
# expansion of metacharacters in `sed`.
render_prompt() {
  local template="$1"
  local out="$2"
  shift 2

  local tmp
  tmp=$(mktemp)
  cp "$template" "$tmp"

  for kv in "$@"; do
    local k="${kv%%=*}"
    local v="${kv#*=}"
    # Use awk for safe literal substitution (no regex on the value).
    local tmp2
    tmp2=$(mktemp)
    awk -v key="{{$k}}" -v val="$v" '
      {
        n = index($0, key)
        while (n > 0) {
          $0 = substr($0, 1, n - 1) val substr($0, n + length(key))
          n = index($0, key)
        }
        print
      }
    ' "$tmp" > "$tmp2"
    mv -f "$tmp2" "$tmp"
  done

  mv -f "$tmp" "$out"
}
