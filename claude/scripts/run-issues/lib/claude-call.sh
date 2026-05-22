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

# Hard wall-clock budget per claude invocation. 60 minutes accommodates
# implementer cycles in slower repos (e.g. pnpm monorepos whose verification
# step builds + runs tests) that otherwise time out on the first attempt and
# only succeed after the restart ramp. A repo can still override this via
# .claude/run-issues.json (claude_timeout_seconds) or the env var.
RUN_ISSUES_CLAUDE_TIMEOUT="${RUN_ISSUES_CLAUDE_TIMEOUT:-3600}"

# The CLI invocation used for every claude call. Defaults to the globally
# installed npm package via npx, which routes usage through the Claude plan
# (cost control) instead of API billing. `--no-install` forces the already
# installed package and never downloads from the registry, and the full
# scoped package name avoids resolving an unrelated `claude` bin (typosquat
# safety). Tests override this with a mock binary on PATH.
# NOTE: deliberately word-split at the call site (multi-token command), hence
# the SC2086 disables below.
RUN_ISSUES_CLAUDE_CMD="${RUN_ISSUES_CLAUDE_CMD:-npx --no-install @anthropic-ai/claude-code}"

# Path to a `timeout` binary. macOS ships `gtimeout` via coreutils;
# fall back to a no-op wrapper that just exec's the command if no
# timeout is available.
# --kill-after=60 escalates to SIGKILL 60s after the initial SIGTERM if the
# child ignores TERM, so a wedged claude process is reaped deterministically
# and `timeout` still reports rc=124.
_resolve_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    printf 'timeout --kill-after=60 %s' "$RUN_ISSUES_CLAUDE_TIMEOUT"
  elif command -v gtimeout >/dev/null 2>&1; then
    printf 'gtimeout --kill-after=60 %s' "$RUN_ISSUES_CLAUDE_TIMEOUT"
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
    $timeout_prefix $RUN_ISSUES_CLAUDE_CMD --dangerously-skip-permissions -p "$(cat "$prompt_file")" > "$out_file" 2>&1 || rc=$?
  else
    printf '[claude-call %s] WARNING: no timeout binary available (timeout/gtimeout), claude calls may hang indefinitely — install coreutils (brew install coreutils)\n' \
      "$(date -u +%FT%TZ)" >&2
    # shellcheck disable=SC2086
    $RUN_ISSUES_CLAUDE_CMD --dangerously-skip-permissions -p "$(cat "$prompt_file")" > "$out_file" 2>&1 || rc=$?
  fi

  printf '%s\n' "$rc" > "$exit_file"
  return "$rc"
}

# render_prompt <template-file> <output-file> <key1=val1> [<key2=val2> ...]
# Substitutes {{KEY}} placeholders in the template in a SINGLE pass.
# Values are walked over but never re-scanned, so a literal "{{OTHER}}"
# string inside a substituted value is preserved as-is — this prevents
# placeholder injection from untrusted issue content. Values may contain
# arbitrary text including newlines; glob metacharacters and backslashes
# pass through byte-for-byte. Placeholder names are uppercase by
# convention. The order of key=value arguments is irrelevant.
render_prompt() {
  local template="$1"
  local out="$2"
  shift 2

  local kv k
  local -a keys=()
  local -a env_args=()
  for kv in "$@"; do
    k="${kv%%=*}"
    keys+=("$k")
    env_args+=("_RP_$k=${kv#*=}")
  done

  env "${env_args[@]}" _RP_KEYS="${keys[*]}" \
    awk -v template_file="$template" '
      BEGIN {
        n = split(ENVIRON["_RP_KEYS"], ks, " ")
        for (i = 1; i <= n; i++) {
          vals[ks[i]] = ENVIRON["_RP_" ks[i]]
          valid[ks[i]] = 1
        }

        template = ""
        first = 1
        while ((getline line < template_file) > 0) {
          if (first) { template = line; first = 0 }
          else { template = template "\n" line }
        }
        close(template_file)
        sub(/\n+$/, "", template)

        out = ""
        i = 1
        len = length(template)
        while (i <= len) {
          if (substr(template, i, 2) == "{{") {
            rest = substr(template, i + 2)
            end = index(rest, "}}")
            if (end > 0) {
              key = substr(rest, 1, end - 1)
              if (key in valid) {
                out = out vals[key]
                i = i + 2 + end + 1
                continue
              }
            }
          }
          out = out substr(template, i, 1)
          i++
        }
        printf "%s\n", out
      }
    ' > "$out"
}
