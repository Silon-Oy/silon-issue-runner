#!/usr/bin/env bash
# lib/claude-call.sh — invoke the claude CLI for a single orchestrated step.
#
# Each step has:
#   - a prompt file (already rendered with placeholders substituted)
#   - an output file:  <run-dir>/<step-id>.out
#   - an exit-code file: <run-dir>/<step-id>.exit
#   - the appended system prompt: <run-dir>/<step-id>.system-prompt.md
# This separation keeps the orchestrator state-machine simple (it just
# checks the exit file) and lets prompts be re-read for debugging.

set -euo pipefail

# preflight_timeout_bin (the single source of truth for timeout/gtimeout
# selection) lives in preflight.sh. Source it if it is not already loaded so
# this module stays self-contained when sourced on its own (unit tests, tools);
# orchestrate.sh sources both and the guard makes the second load a no-op.
if ! declare -F preflight_timeout_bin >/dev/null 2>&1; then
  _claude_call_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=preflight.sh
  . "$_claude_call_lib_dir/preflight.sh"
  unset _claude_call_lib_dir
fi

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
#
# The default is a named constant because it is the seam the S0 preflight gate
# uses to tell "the user accepted our invocation" from "the user supplied their
# own driver". Only the former may be probed with --version: an override is an
# explicit claim about a private command whose flags we must not guess.
RUN_ISSUES_CLAUDE_CMD_DEFAULT='npx --no-install @anthropic-ai/claude-code'
RUN_ISSUES_CLAUDE_CMD="${RUN_ISSUES_CLAUDE_CMD:-$RUN_ISSUES_CLAUDE_CMD_DEFAULT}"

# Optional model override. When set, passes --model <value> to the claude CLI.
# Without this the CLI uses its configured default (currently claude-fable-5).
# Set in ~/.config/run-issues/env to pin to a stable model and prevent a
# single model's availability window from stalling the factory for 3600 s.
# Example: RUN_ISSUES_CLAUDE_MODEL=claude-opus-4-8
RUN_ISSUES_CLAUDE_MODEL="${RUN_ISSUES_CLAUDE_MODEL:-}"

# ---------- always-on system prompt: contract + coding standard ----------
# Every orchestrated step gets the package's coding standard as an APPENDED
# system prompt. Before this, only 01-cycle-review.md injected anything
# (the TARGET repo's CLAUDE.md, a different document); S8/S9 and the PR
# watcher's agents relied on Claude Code loading the operator's own user-level
# memory, so the rules applied only on the machine that happened to have them.
# Delivery must be structural, not incidental — hence the CLI flag rather than a
# skill, whose description-gated loading is a silent-failure mechanism for
# always-on rules.
#
# The packaged standard. A named constant (like RUN_ISSUES_CLAUDE_CMD_DEFAULT)
# because _resolve_principles_file needs it as the fallback target, not just as
# an initial value. Derived from BASH_SOURCE so it resolves in both install
# models (symlink to the package root, or dotfiles submodule).
RUN_ISSUES_PRINCIPLES_FILE_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/principles/coding.md"

# The packaged operating contract (issue #176): what an orchestrated agent is
# allowed to do without asking, and the four boundaries on that permission. It
# used to live in prompts/02-implementer.md AND in the operator's own user-level
# CLAUDE.md, so it reached the implementer twice and the PR watcher's agents not
# at all — and a co-developer whose own instructions say "never change anything
# without asking" got an agent arguing with the automation.
#
# Deliberately NOT the same file as the coding standard, and deliberately WITHOUT
# an env var of its own. The standard is overridable per repo (principles_file)
# and opt-out-able (RUN_ISSUES_PRINCIPLES_FILE=""); the contract must survive
# both, because a target repo shipping its own coding standard must not be able
# to silently drop the runner's own operating boundaries. Two files, one flag —
# hence the concatenation in _resolve_system_prompt_file.
RUN_ISSUES_CONTRACT_FILE_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/principles/auto-run-contract.md"

# NOTE the absence of a `RUN_ISSUES_PRINCIPLES_FILE="${RUN_ISSUES_PRINCIPLES_FILE:-...}"`
# line here. Two independent reasons, both load-bearing:
#
#  1. `:-` collapses "unset" into "set to empty", and those must stay distinct:
#     unset = use the packaged standard, empty = send no coding standard at all
#     (the contract above is unaffected either way).
#     Presence (${VAR+x}), not emptiness, is therefore the test everywhere below.
#  2. lib/machine-env.sh snapshots every ALREADY-SET RUN_ISSUES_* name and
#     restores it over the machine env file. Anything this module materialises at
#     source time (claude-call.sh is sourced before source_machine_env runs) can
#     consequently never be set from ~/.config/run-issues/env again. Leaving the
#     variable untouched keeps that delivery channel open and keeps "nobody
#     configured this" decidable for the whole run.
#
# Resolution therefore happens lazily, at call time:
#   1. RUN_ISSUES_PRINCIPLES_FILE from the environment / machine env file
#   2. principles_file in the target repo's .claude/run-issues.json
#      (applied by load_repo_principles_file, which yields to 1)
#   3. this package's own principles/coding.md

# _claude_call_log <message> — log through the caller's `log` when it has one
# (orchestrate.sh writes to its run log), else to stderr. Same discovery pattern
# as lib/machine-env.sh's _machine_env_log.
_claude_call_log() {
  if declare -F log >/dev/null 2>&1; then
    log "claude-call: $1"
  else
    printf '[claude-call %s] %s\n' "$(date -u +%FT%TZ)" "$1" >&2
  fi
}

# _resolve_principles_file — print the path to append as a system prompt, or
# nothing when no system prompt should be sent. Never fails the run.
#
# MEASURED, and the reason this function exists at all: the flag is fail-CLOSED
# on a bad path. Against claude CLI 2.1.257,
# `--append-system-prompt-file /does/not/exist -p ...` aborts with
# "Error: Append system prompt file not found: ..." before the agent starts —
# it does not warn and continue. An unreadable override reaching the command
# line would therefore kill every step of every run over one typo'd config key.
# So readability is checked HERE and a bad path degrades to the packaged
# standard; if even that is gone the flag is dropped entirely rather than
# passed as a path we know the CLI will reject.
#
# (The same probe established that the option exists despite being absent from
# `--help`: an unknown option errors at parse time — `--bogus -p ...` prints
# "unknown option" — whereas this one parsed and reached authentication.
# `--version`/`--help` short-circuit option parsing and can verify neither.)
_resolve_principles_file() {
  # Unset: nobody configured anything -> the packaged standard.
  if [ -z "${RUN_ISSUES_PRINCIPLES_FILE+x}" ]; then
    if [ -r "$RUN_ISSUES_PRINCIPLES_FILE_DEFAULT" ]; then
      printf '%s' "$RUN_ISSUES_PRINCIPLES_FILE_DEFAULT"
    else
      _claude_call_log "WARNING: packaged coding standard missing at $RUN_ISSUES_PRINCIPLES_FILE_DEFAULT — sending no system prompt"
    fi
    return 0
  fi

  # Set to empty: a deliberate opt-out, so it is silent, not a warning.
  [ -n "$RUN_ISSUES_PRINCIPLES_FILE" ] || return 0

  if [ -r "$RUN_ISSUES_PRINCIPLES_FILE" ]; then
    printf '%s' "$RUN_ISSUES_PRINCIPLES_FILE"
    return 0
  fi

  _claude_call_log "WARNING: principles file not readable: $RUN_ISSUES_PRINCIPLES_FILE — falling back to the packaged standard"
  if [ -r "$RUN_ISSUES_PRINCIPLES_FILE_DEFAULT" ]; then
    printf '%s' "$RUN_ISSUES_PRINCIPLES_FILE_DEFAULT"
  else
    _claude_call_log "WARNING: packaged coding standard missing at $RUN_ISSUES_PRINCIPLES_FILE_DEFAULT — sending no system prompt"
  fi
  return 0
}

# _resolve_system_prompt_file <run-dir> <step-id> — print the single path to
# append as a system prompt, or nothing when there is none. Never fails the run.
#
# The CLI flag takes ONE file but the package has two always-on documents with
# different override rules (see RUN_ISSUES_CONTRACT_FILE_DEFAULT). They are
# therefore concatenated into a per-step file next to the step's .out/.exit,
# which keeps them re-readable for debugging exactly like the rendered prompt is.
#
# The contract comes FIRST: it is the one document that cannot be overridden, and
# a reader (human or model) hitting the permission rule before the style rules
# matches the order in which they matter.
#
# Fail-soft in three directions, because none of these may kill a run: a missing
# packaged contract degrades to the standard alone, a missing standard degrades
# to the contract alone, and an unwritable run-dir degrades to the contract file
# itself (the non-overridable half) rather than to nothing.
_resolve_system_prompt_file() {
  local run_dir="$1" step_id="$2"

  local contract=""
  if [ -r "$RUN_ISSUES_CONTRACT_FILE_DEFAULT" ]; then
    contract="$RUN_ISSUES_CONTRACT_FILE_DEFAULT"
  else
    _claude_call_log "WARNING: packaged operating contract missing at $RUN_ISSUES_CONTRACT_FILE_DEFAULT — the agent will not be told it may act without asking"
  fi

  local principles
  principles=$(_resolve_principles_file)

  # Only one of the two present (or neither): no concatenation needed, and no
  # temp file to fail to write.
  if [ -z "$contract" ]; then
    printf '%s' "$principles"
    return 0
  fi
  if [ -z "$principles" ]; then
    printf '%s' "$contract"
    return 0
  fi

  local combined="$run_dir/${step_id}.system-prompt.md"
  if { cat "$contract"; printf '\n'; cat "$principles"; } 2>/dev/null > "$combined"; then
    printf '%s' "$combined"
  else
    _claude_call_log "WARNING: could not write $combined — sending the operating contract alone"
    printf '%s' "$contract"
  fi
  return 0
}

# load_repo_principles_file <repo-root> — apply the target repo's
# principles_file override unless the environment already decided.
#
# Same opt-in convention as claude_timeout_seconds / base_branch: the key lives
# in the target repo's .claude/run-issues.json and an absent file, absent key or
# broken JSON is a benign no-op. A relative value is resolved against the repo
# root so a repo can ship its own standard without knowing the runner's CWD.
#
# The environment test is PRESENCE, not emptiness: RUN_ISSUES_PRINCIPLES_FILE=""
# is a deliberate opt-out that a repo config must not silently undo.
#
# Callers must invoke this AFTER source_machine_env — see the note above; running
# it earlier would let the machine env file lose to the repo config, inverting
# the documented precedence.
load_repo_principles_file() {
  local repo="$1"
  [ -n "${RUN_ISSUES_PRINCIPLES_FILE+x}" ] && return 0

  local cfg="$repo/.claude/run-issues.json"
  [ -f "$cfg" ] || return 0
  jq -e . "$cfg" >/dev/null 2>&1 || return 0

  local p
  p=$(jq -r '.principles_file // empty' "$cfg" 2>/dev/null || true)
  [ -n "$p" ] || return 0
  case "$p" in
    /*) : ;;
    *) p="$repo/$p" ;;
  esac

  RUN_ISSUES_PRINCIPLES_FILE="$p"
  export RUN_ISSUES_PRINCIPLES_FILE
  _claude_call_log "using repo principles_file=$p from $cfg"
}

# Path to a `timeout` binary. macOS ships `gtimeout` via coreutils;
# fall back to a no-op wrapper that just exec's the command if no
# timeout is available. Binary selection is delegated to preflight_timeout_bin
# (preflight.sh) so timeout/gtimeout detection lives in exactly one place.
# --kill-after=60 escalates to SIGKILL 60s after the initial SIGTERM if the
# child ignores TERM, so a wedged claude process is reaped deterministically
# and `timeout` still reports rc=124.
_resolve_timeout() {
  local tb
  tb=$(preflight_timeout_bin)
  if [ -n "$tb" ]; then
    printf '%s --kill-after=60 %s' "$tb" "$RUN_ISSUES_CLAUDE_TIMEOUT"
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

  local model_flag=""
  [ -n "$RUN_ISSUES_CLAUDE_MODEL" ] && model_flag="--model $RUN_ISSUES_CLAUDE_MODEL"

  # An ARRAY, not a word-split string like model_flag: this one carries a
  # filesystem path, and a repo or operator may legitimately keep the package
  # somewhere with a space in it. The ${arr[@]+"${arr[@]}"} form expands to zero
  # words when empty without tripping `set -u` on bash 3.2 (macOS system bash).
  local principles_file
  principles_file=$(_resolve_system_prompt_file "$run_dir" "$step_id")
  local -a principles_args=()
  [ -n "$principles_file" ] && principles_args=(--append-system-prompt-file "$principles_file")

  local rc=0
  if [ -n "$timeout_prefix" ]; then
    # shellcheck disable=SC2086
    $timeout_prefix $RUN_ISSUES_CLAUDE_CMD $model_flag ${principles_args[@]+"${principles_args[@]}"} --dangerously-skip-permissions -p "$(cat "$prompt_file")" > "$out_file" 2>&1 || rc=$?
  else
    printf '[claude-call %s] WARNING: no timeout binary available (timeout/gtimeout), claude calls may hang indefinitely — install coreutils (brew install coreutils)\n' \
      "$(date -u +%FT%TZ)" >&2
    # shellcheck disable=SC2086
    $RUN_ISSUES_CLAUDE_CMD $model_flag ${principles_args[@]+"${principles_args[@]}"} --dangerously-skip-permissions -p "$(cat "$prompt_file")" > "$out_file" 2>&1 || rc=$?
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
