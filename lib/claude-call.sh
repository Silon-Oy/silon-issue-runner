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

# usage_limit_* (issue #294): call_claude records a detected usage limit in the
# machine-wide gate file. Function-only, so re-sourcing it is harmless.
# shellcheck source=usage-limit.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/usage-limit.sh"
# claude_profile_* (issue #295): the ordered subscription list call_claude falls
# over between on a usage limit. Function-only as well.
# shellcheck source=claude-profiles.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claude-profiles.sh"

# The return code call_claude uses for "the subscription's usage limit was hit".
# 75 is sysexits' EX_TEMPFAIL — "try again later" is exactly the contract — and
# it collides with neither timeout(1)'s 124/137 nor the CLI-missing 127.
CLAUDE_USAGE_LIMIT_RC=75

# Hard wall-clock budget per claude invocation. 60 minutes accommodates
# implementer cycles in slower repos (e.g. pnpm monorepos whose verification
# step builds + runs tests) that otherwise time out on the first attempt and
# only succeed after the restart ramp.
#
# A named constant rather than `RUN_ISSUES_CLAUDE_TIMEOUT="${VAR:-3600}"`, for
# the same reason RUN_ISSUES_PRINCIPLES_FILE is left untouched below: this module
# is sourced before the target repo's .claude/run-issues.json is read, and
# load_repo_timeout's "did anyone override this?" test cannot tell a repo-level
# value it should apply from a default we assigned ourselves a moment earlier.
# Materialising it here made claude_timeout_seconds dead configuration.
# Resolution therefore happens at call time, through claude_call_timeout:
#   1. RUN_ISSUES_CLAUDE_TIMEOUT from the environment / machine env file
#   2. claude_timeout_seconds in the target repo's .claude/run-issues.json
#      (applied by orchestrate.sh's load_repo_timeout, which yields to 1)
#   3. this default
RUN_ISSUES_CLAUDE_TIMEOUT_DEFAULT=3600

# claude_call_timeout — the effective per-call budget in seconds. The one place
# the default is applied, so the ramp in orchestrate.sh's restart path and the
# `timeout` prefix below cannot disagree about the base (they used to: 1800 vs
# 3600).
claude_call_timeout() {
  printf '%s\n' "${RUN_ISSUES_CLAUDE_TIMEOUT:-$RUN_ISSUES_CLAUDE_TIMEOUT_DEFAULT}"
}

# The CLI invocation used for every claude call. Defaults to the natively
# installed `claude` command (Claude Code's native installer puts it on PATH),
# which routes usage through the Claude plan (cost control) instead of API
# billing. A machine that installed Claude Code as the npm package instead —
# no `claude` on PATH — overrides this with the npx invocation, whose
# `--no-install` forces the already installed package and never downloads from
# the registry, and whose full scoped package name avoids resolving an
# unrelated `claude` bin (typosquat safety):
#   RUN_ISSUES_CLAUDE_CMD='npx --no-install @anthropic-ai/claude-code'
# Tests override this with a mock binary on PATH.
# NOTE: deliberately word-split at the call site (multi-token command), hence
# the SC2086 disables below.
#
# The default is a named constant because it is the seam the S0 preflight gate
# uses to tell "the user accepted our invocation" from "the user supplied their
# own driver". Only the former may be probed with --version: an override is an
# explicit claim about a private command whose flags we must not guess.
RUN_ISSUES_CLAUDE_CMD_DEFAULT='claude'
RUN_ISSUES_CLAUDE_CMD="${RUN_ISSUES_CLAUDE_CMD:-$RUN_ISSUES_CLAUDE_CMD_DEFAULT}"

# claude_cmd_is_native — is RUN_ISSUES_CLAUDE_CMD the Claude Code CLI itself,
# whose flag vocabulary we know, rather than the operator's own driver? Asked by
# the plugin-context declaration in call_claude.
#
# Deliberately NOT the question the S0 preflight probe and the CI-repair
# preflight (pr-watch.sh) ask. They compare against RUN_ISSUES_CLAUDE_CMD_DEFAULT
# exactly, because theirs is "did the user accept our invocation?" — only then
# may we fire `--version` at it; any explicit value gets the `have` check. The
# isolation flags ask "does this command speak Claude Code's flags?", and an
# absolute path to the same binary does.
#
# True for the packaged default and for a single-token path whose basename is
# exactly `claude`. The second case is the same binary pinned by absolute path —
# launchd's PATH lacks ~/.local/bin, so a production machine typically sets
# RUN_ISSUES_CLAUDE_CMD=/Users/<user>/.local/bin/claude. Comparing strings alone
# classified that as an override, which silently skipped the #282 plugin-context
# isolation on exactly the machine that runs the factory. A wrapper under any
# other name (docs/local-llm-runner.md's claude-toshllm) and any multi-token
# invocation stay overrides.
claude_cmd_is_native() {
  local cmd="$RUN_ISSUES_CLAUDE_CMD"
  [ "$cmd" = "$RUN_ISSUES_CLAUDE_CMD_DEFAULT" ] && return 0
  case "$cmd" in
    *[[:space:]]*) return 1 ;;
  esac
  [ "${cmd##*/}" = "claude" ]
}

# Optional model override. When set, passes --model <value> to the claude CLI;
# empty means the CLI's own configured default.
# Recommended: a FAMILY alias (opus, sonnet, haiku — optionally with a context
# window suffix such as opus[1m]), so a new model version is picked up without a
# configuration change. A versioned id (claude-<family>-<version>) still works
# but pins the version; call_claude logs one warning line per call saying so. It
# is kept as an emergency brake for when a new model turns out to be a problem.
RUN_ISSUES_CLAUDE_MODEL="${RUN_ISSUES_CLAUDE_MODEL:-}"

# Optional fallback model, passed as --fallback-model <value> — the CLI switches
# to it when the primary model is unavailable. This, not a pinned version, is what
# keeps one model's availability window from stalling the factory for 3600 s.
# Native CLI only (claude_cmd_is_native): an operator's own driver's flag
# vocabulary is not assumed. Empty = no flag.
RUN_ISSUES_CLAUDE_FALLBACK_MODEL="${RUN_ISSUES_CLAUDE_FALLBACK_MODEL:-}"

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
#  2. "nobody configured this" has to stay decidable for the whole run, because
#     the repo-level lookup (load_repo_principles_file) runs long after this file
#     is sourced and must be able to tell an unconfigured run from an overridden
#     one. A default assigned here would answer "configured" to every later
#     question. This is the same trap that made claude_timeout_seconds dead
#     configuration (see RUN_ISSUES_CLAUDE_TIMEOUT_DEFAULT above) — and, until
#     issue #200 moved lib/machine-env.sh's snapshot to machine_env_capture, it
#     also locked ~/.config/run-issues/env out of RUN_ISSUES_CLAUDE_CMD/_MODEL.
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
    printf '%s --kill-after=60 %s' "$tb" "$(claude_call_timeout)"
  else
    printf '' # no-op
  fi
}

# ---------- usage-limit detection (issue #294) ----------
# Textual and after the fact, like lib/rate-limit.sh's GitHub detection: the CLI
# offers no way to ask in advance, and the message is the only signal.
#
# MATCHING IS NARROW, AND SCOPED TO THE END OF THE OUTPUT. The .out file is the
# agent's final answer, which can legitimately TALK about usage limits — this
# very feature's implementer output does. Three guards keep that from tripping a
# machine-wide pause:
#   1. only the last few lines are read: in -p mode a limit hit replaces the
#      final answer with the CLI's own one-line message;
#   2. an output carrying a step result line (CYCLE_REVIEW_DECISION:,
#      IMPLEMENTER_RESULT:, …) is a finished answer, never a limit;
#   3. only the CLI's own phrasings match, not the bare words "usage limit".
# A false positive costs one backoff window on one machine; a false negative is
# the old behaviour. RUN_ISSUES_USAGE_LIMIT_DETECTION=0 turns detection off.
CLAUDE_USAGE_LIMIT_TAIL_LINES=5

# claude_usage_limit_matches <text> — 0 when the text is a usage-limit message.
# Pure; no I/O.
claude_usage_limit_matches() {
  local lower
  lower=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *"usage limit reached"*) return 0 ;;
    *"usage limit has been reached"*) return 0 ;;
  esac
  # "You've hit your limit", "You've hit your session limit", "…weekly limit"
  [[ "$lower" =~ hit\ your\ ([a-z0-9-]+\ )?limit ]] && return 0
  # "5-hour limit reached · resets 3pm"
  [[ "$lower" =~ limit\ reached.*resets ]] && return 0
  return 1
}

# _claude_usage_clock_to_epoch <hour-0-23> <minute> <tz> <now-epoch> — the next
# occurrence (strictly after now) of the wall-clock time in <tz> (empty = the
# machine's local zone). Prints nothing when date(1) cannot compute it. Handles
# both date dialects: GNU (Linux, Git Bash) and BSD (macOS).
_claude_usage_clock_to_epoch() {
  local h="$1" m="$2" tz="$3" now="$4" day e
  local -a tzenv=()
  [ -n "$tz" ] && tzenv=(TZ="$tz")
  if date -d @0 +%s >/dev/null 2>&1; then
    day=$(env ${tzenv[@]+"${tzenv[@]}"} date -d "@$now" +%F 2>/dev/null) || return 0
    e=$(env ${tzenv[@]+"${tzenv[@]}"} date -d "$day $h:$m:00" +%s 2>/dev/null) || return 0
  else
    day=$(env ${tzenv[@]+"${tzenv[@]}"} date -r "$now" +%F 2>/dev/null) || return 0
    e=$(env ${tzenv[@]+"${tzenv[@]}"} date -j -f '%Y-%m-%d %H:%M:%S' "$day $h:$m:00" +%s 2>/dev/null) || return 0
  fi
  case "$e" in ''|*[!0-9]*) return 0 ;; esac
  # The reset already passed today -> it is tomorrow's.
  [ "$e" -gt "$now" ] || e=$((e + 86400))
  printf '%s' "$e"
}

# claude_usage_limit_reset_epoch <text> [<now-epoch>] — the reset time carried
# by a usage-limit message, as epoch seconds, or nothing when none parses. Two
# shapes are understood:
#   "Claude AI usage limit reached|1759420800"   (epoch after a pipe)
#   "… resets 3pm (Europe/Helsinki)", "resets 11:30pm", "resets 15:00"
# A result that is not in the future, or more than a week out, is discarded as a
# misparse: the caller then falls back to RUN_ISSUES_USAGE_LIMIT_BACKOFF.
claude_usage_limit_reset_epoch() {
  local text="${1:-}" now="${2:-$(date +%s)}" lower e=""
  lower=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')
  if [[ "$lower" =~ limit\ reached\|([0-9]{9,11}) ]]; then
    e="${BASH_REMATCH[1]}"
  elif [[ "$lower" =~ resets?\ (at\ )?([0-9]{1,2})(:([0-9]{2}))?\ ?(am|pm)?(\ \(([^\)]+)\))? ]]; then
    local h="${BASH_REMATCH[2]}" m="${BASH_REMATCH[4]:-00}" ap="${BASH_REMATCH[5]}" tz=""
    # The zone name is matched on the lowercased copy but must be passed in its
    # original case (Europe/Helsinki, not europe/helsinki) — re-read it.
    if [ -n "${BASH_REMATCH[7]}" ] && [[ "$text" =~ \(([A-Za-z_]+(/[A-Za-z0-9_+-]+)*)\) ]]; then
      tz="${BASH_REMATCH[1]}"
    fi
    h=$((10#$h)); m=$((10#$m))
    case "$ap" in
      am) [ "$h" -eq 12 ] && h=0 ;;
      pm) [ "$h" -lt 12 ] && h=$((h + 12)) ;;
    esac
    if [ "$h" -le 23 ] && [ "$m" -le 59 ]; then
      e=$(_claude_usage_clock_to_epoch "$(printf '%02d' "$h")" "$(printf '%02d' "$m")" "$tz" "$now")
    fi
  fi
  case "$e" in ''|*[!0-9]*) return 0 ;; esac
  [ "$e" -gt "$now" ] && [ "$e" -le $((now + 7 * 86400)) ] || return 0
  printf '%s' "$e"
}

# claude_usage_limit_check <out-file> [<now-epoch>] — 0 when the step output
# ends in a usage-limit message; prints "<deadline-epoch> <source>" where source
# is `reset` (parsed from the message, plus a minute of margin because the
# message has minute granularity) or `backoff` (the fallback wait). 1 otherwise,
# including a missing file and the kill switch.
claude_usage_limit_check() {
  local f="${1:-}" now="${2:-$(date +%s)}" tail_text reset
  usage_limit_enabled || return 1
  [ -n "$f" ] && [ -s "$f" ] || return 1
  if grep -qE '^[A-Z][A-Z_]*_(RESULT|DECISION):' "$f" 2>/dev/null; then
    return 1
  fi
  tail_text=$(tail -n "$CLAUDE_USAGE_LIMIT_TAIL_LINES" "$f" 2>/dev/null || printf '')
  claude_usage_limit_matches "$tail_text" || return 1
  reset=$(claude_usage_limit_reset_epoch "$tail_text" "$now")
  if [ -n "$reset" ]; then
    printf '%s reset' "$((reset + 60))"
  else
    printf '%s backoff' "$((now + $(usage_limit_backoff_seconds)))"
  fi
  return 0
}

# _claude_usage_limit_record <run-dir> <step-id> <deadline> <source> — trip the
# machine-wide gate and, when <run-dir> is an orchestrated run, record the
# deadline in its run.json so the restart path knows when it may resume. The
# PR watcher's agents pass a scratch dir with no run.json: the gate still trips.
_claude_usage_limit_record() {
  local run_dir="$1" step_id="$2" deadline="$3" source="$4"
  usage_limit_trip "$(usage_limit_state_file)" "$deadline" "$source" || true
  _claude_call_log "usage limit hit in step $step_id — no claude work on this machine until $(date -u -r "$deadline" +%FT%TZ 2>/dev/null || date -u -d "@$deadline" +%FT%TZ 2>/dev/null || echo "$deadline") (source=$source)"
  if [ -f "$run_dir/run.json" ] && declare -F state_set >/dev/null 2>&1; then
    state_set "$run_dir" usage_limit_reset_at "$deadline" || true
    state_set "$run_dir" usage_limit_source "$source" || true
    state_event "$run_dir" "usage_limit_hit" "step=$step_id" "reset_at=$deadline" "source=$source" || true
  fi
}

# _claude_profile_event <run-dir> <step-id> <event> <key=value>... — the state
# event for the profile half of a call. Names only, never a token.
_claude_profile_event() {
  local run_dir="$1" step_id="$2" event="$3"
  shift 3
  if [ -f "$run_dir/run.json" ] && declare -F state_event >/dev/null 2>&1; then
    state_event "$run_dir" "$event" "step=$step_id" "$@" || true
  fi
}

# _claude_all_profiles_full <run-dir> <step-id> <fallback-deadline> <fallback-source>
# — every configured profile is at its limit (or unusable): trip the machine-wide
# gate at the EARLIEST profile reset, which is when the next call can succeed.
# The fallback is this call's own last detected deadline, for when no profile
# file could be written (unwritable log dir) — the gate must still trip.
_claude_all_profiles_full() {
  local run_dir="$1" step_id="$2" fb_deadline="$3" fb_source="$4" earliest
  earliest=$(claude_profiles_earliest_reset)
  if [ -z "$earliest" ]; then
    earliest="$fb_deadline $fb_source"
  fi
  _claude_call_log "every Claude profile is at its usage limit"
  _claude_usage_limit_record "$run_dir" "$step_id" "${earliest%% *}" "${earliest#* }"
}

# call_claude <run-dir> <step-id> <prompt-file>
# Returns the claude process exit code (0 on success), or CLAUDE_USAGE_LIMIT_RC
# when the output is a usage-limit message (the .exit file still records the
# process's own code). Always writes the .out and .exit files even on timeout or
# interruption.
#
# With RUN_ISSUES_CLAUDE_PROFILES set (issue #295, lib/claude-profiles.sh) the
# step runs on the first free profile; a usage limit marks that profile full and
# the SAME step is re-run at once on the next free one. CLAUDE_USAGE_LIMIT_RC is
# returned only when no profile is left. The limited attempt's output is kept as
# <step-id>.out.limited-<profile> so .out always holds the final attempt.
call_claude() {
  local run_dir="$1"
  local step_id="$2"
  local prompt_file="$3"

  local out_file="$run_dir/${step_id}.out"
  local exit_file="$run_dir/${step_id}.exit"

  local timeout_prefix
  timeout_prefix=$(_resolve_timeout)

  # An ARRAY, not a word-split string: a context-window alias such as opus[1m]
  # is a glob bracket expression, and unquoted it would expand to any matching
  # file name in the working directory.
  local -a model_args=()
  if [ -n "$RUN_ISSUES_CLAUDE_MODEL" ]; then
    model_args=(--model "$RUN_ISSUES_CLAUDE_MODEL")
    case "$RUN_ISSUES_CLAUDE_MODEL" in
      claude-*)
        _claude_call_log "WARNING: RUN_ISSUES_CLAUDE_MODEL=$RUN_ISSUES_CLAUDE_MODEL is a versioned model id — it pins that version and will not move to a newer model; use a family alias (opus, sonnet, haiku) unless the pin is deliberate"
        ;;
    esac
  fi

  # An ARRAY for the same reason: this one carries a
  # filesystem path, and a repo or operator may legitimately keep the package
  # somewhere with a space in it. The ${arr[@]+"${arr[@]}"} form expands to zero
  # words when empty without tripping `set -u` on bash 3.2 (macOS system bash).
  local principles_file
  principles_file=$(_resolve_system_prompt_file "$run_dir" "$step_id")
  local -a principles_args=()
  [ -n "$principles_file" ] && principles_args=(--append-system-prompt-file "$principles_file")

  # ---------- declared plugin/extension context (issue #282) ----------
  # An orchestrated run is meant to be reproducible, so it DECLARES its plugin
  # and MCP context instead of inheriting whatever the machine's
  # ~/.claude/settings.json happens to enable. Without these flags the native
  # `claude` command syncs that file's `enabledPlugins` / `extraKnownMarketplaces`
  # into every unattended 3600 s call: undeclared machine state whose token cost
  # and behaviour vary per machine and never show up in the run's own bookkeeping
  # — the same failure shape as the machine env file overwriting a caller's
  # explicit choice (CLAUDE.md §5.5).
  #
  #   --setting-sources project,local  loads only the target repo's own settings
  #       (project = its checked-in, reproducible .claude/settings.json; local =
  #       .claude/settings.local.json), never the machine's USER-level profile,
  #       which is exactly where the measured plugin list and marketplaces live.
  #   --strict-mcp-config              uses only MCP servers from --mcp-config
  #       (we pass none), so no ambient MCP server the machine happens to have
  #       configured leaks into the run either.
  #
  # NOT --bare, though it is the one flag that skips plugin sync outright: it would
  # ALSO skip CLAUDE.md auto-discovery (the cycle-review and implementer steps rely
  # on the target repo's CLAUDE.md reaching the agent) and, decisively, force
  # ANTHROPIC_API_KEY auth — "OAuth and keychain are never read" — which breaks the
  # whole reason this module defaults to the native `claude` command: routing usage
  # through the Claude plan instead of API billing (see RUN_ISSUES_CLAUDE_CMD_DEFAULT).
  #
  # Gated on claude_cmd_is_native (see there for why the preflight probes ask a
  # narrower question): any other RUN_ISSUES_CLAUDE_CMD
  # is the operator's own driver (e.g. a local-LLM wrapper, docs/local-llm-runner.md)
  # whose flag vocabulary we must not assume — the same rule that keeps --version off
  # an override. Logged (not just applied) so the chosen context is readable from the
  # run trace, not only from this source: undeclaredness is the whole point of #282.
  local -a plugin_context_args=()
  if claude_cmd_is_native; then
    # `project,local` is a SINGLE element: --setting-sources takes one
    # comma-separated value, so the comma is deliberate, not an array separator.
    # shellcheck disable=SC2054
    plugin_context_args=(--strict-mcp-config --setting-sources project,local)
    _claude_call_log "plugin context declared: --strict-mcp-config --setting-sources project,local (not inheriting the machine's ~/.claude/settings.json plugins/marketplaces)"
  else
    _claude_call_log "plugin context left to the overridden driver: RUN_ISSUES_CLAUDE_CMD=$RUN_ISSUES_CLAUDE_CMD"
  fi

  # Same gate, same reason: --fallback-model is native CLI vocabulary.
  local -a fallback_args=()
  if [ -n "$RUN_ISSUES_CLAUDE_FALLBACK_MODEL" ] && claude_cmd_is_native; then
    fallback_args=(--fallback-model "$RUN_ISSUES_CLAUDE_FALLBACK_MODEL")
  fi

  local -a cmd=()
  if [ -z "$timeout_prefix" ]; then
    printf '[claude-call %s] WARNING: no timeout binary available (timeout/gtimeout), claude calls may hang indefinitely — install coreutils (brew install coreutils)\n' \
      "$(date -u +%FT%TZ)" >&2
  fi
  # shellcheck disable=SC2206  # deliberate word-split of multi-token settings
  cmd=($timeout_prefix $RUN_ISSUES_CLAUDE_CMD ${model_args[@]+"${model_args[@]}"} ${fallback_args[@]+"${fallback_args[@]}"})

  local use_profiles=0 profile="" profile_path="" tried="" token
  local last_deadline="" last_source=""
  claude_profiles_configured && use_profiles=1

  local rc ul
  while :; do
    token=""
    if [ "$use_profiles" = 1 ]; then
      local picked
      if ! picked=$(claude_profile_pick "$tried"); then
        if [ -n "$tried" ] || [ -n "$(claude_profiles_earliest_reset)" ]; then
          # Nothing free, and at least one profile is full: the usage-limit
          # outcome. No process ran on this pass, so .out says why.
          [ -n "$last_deadline" ] || { printf 'claude-call: no Claude profile available — all at their usage limit\n' > "$out_file"; printf '%s\n' "$CLAUDE_USAGE_LIMIT_RC" > "$exit_file"; }
          _claude_all_profiles_full "$run_dir" "$step_id" "${last_deadline:-$(( $(date +%s) + $(usage_limit_backoff_seconds) ))}" "${last_source:-backoff}"
          return "$CLAUDE_USAGE_LIMIT_RC"
        fi
        # Nothing is full and nothing is usable: a configuration error. Fail
        # closed — never fall back to the CLI's own login.
        _claude_call_log "ERROR: RUN_ISSUES_CLAUDE_PROFILES is set but no profile is usable — step $step_id not run"
        printf 'claude-call: RUN_ISSUES_CLAUDE_PROFILES is set but no profile has a usable token file\n' > "$out_file"
        printf '1\n' > "$exit_file"
        return 1
      fi
      profile="${picked%% *}"
      profile_path="${picked#* }"
      tried="$tried $profile"
      token=$(claude_profile_token "$profile_path")
      _claude_call_log "step $step_id runs on Claude profile '$profile'"
      _claude_profile_event "$run_dir" "$step_id" "claude_profile" "profile=$profile"
    fi

    rc=0
    # A subshell so the token reaches the claude process's environment only: it
    # is never exported into this shell, never on a command line (ps), and never
    # set at all without profiles — an empty CLAUDE_CODE_OAUTH_TOKEN is not the
    # same thing as an absent one.
    (
      if [ -n "$token" ]; then
        CLAUDE_CODE_OAUTH_TOKEN="$token"
        export CLAUDE_CODE_OAUTH_TOKEN
      fi
      exec "${cmd[@]}" ${principles_args[@]+"${principles_args[@]}"} ${plugin_context_args[@]+"${plugin_context_args[@]}"} --dangerously-skip-permissions -p "$(cat "$prompt_file")"
    ) > "$out_file" 2>&1 || rc=$?

    printf '%s\n' "$rc" > "$exit_file"

    # A timeout is its own outcome (finalize_timeout); everything else is checked,
    # including rc=0 — the CLI's exit code on a limit hit is not something to bet on.
    if [ "$rc" != "124" ] && ul=$(claude_usage_limit_check "$out_file"); then
      if [ "$use_profiles" = 1 ]; then
        last_deadline="${ul%% *}"
        last_source="${ul#* }"
        claude_profile_trip "$profile" "$last_deadline" "$last_source" || true
        cp -f "$out_file" "$out_file.limited-$profile" 2>/dev/null || true
        _claude_call_log "usage limit hit in step $step_id on Claude profile '$profile' — profile full until $(date -u -r "$last_deadline" +%FT%TZ 2>/dev/null || date -u -d "@$last_deadline" +%FT%TZ 2>/dev/null || echo "$last_deadline") (source=$last_source); trying the next profile"
        _claude_profile_event "$run_dir" "$step_id" "claude_profile_limited" "profile=$profile" "reset_at=$last_deadline" "source=$last_source"
        continue
      fi
      _claude_usage_limit_record "$run_dir" "$step_id" "${ul%% *}" "${ul#* }"
      return "$CLAUDE_USAGE_LIMIT_RC"
    fi
    return "$rc"
  done
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
