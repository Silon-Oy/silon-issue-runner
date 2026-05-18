#!/usr/bin/env bash
# lib/state.sh — durable run state for /run-issues.
#
# Layout, all under <run-dir>:
#   run.json     — canonical snapshot (atomic via tmp+mv)
#   state.jsonl  — append-only event log (one JSON object per line)
#
# Functions take the run directory as the first argument so callers can
# manage multiple concurrent runs without globals.

set -euo pipefail

# _state_now: ISO-8601 UTC timestamp on stdout.
_state_now() {
  date -u +%FT%TZ
}

# state_init <run-dir> <run-id> <repo-root> <issue-number>
# Creates run.json with status=initialized and an empty state.jsonl.
state_init() {
  local run_dir="$1"
  local run_id="$2"
  local repo="$3"
  local issue_num="$4"

  mkdir -p "$run_dir"
  : > "$run_dir/state.jsonl"

  local tmp
  tmp=$(mktemp "$run_dir/.run.json.XXXXXX")
  jq -n \
    --arg run_id "$run_id" \
    --arg repo "$repo" \
    --arg issue_num "$issue_num" \
    --arg ts "$(_state_now)" \
    '{
      run_id: $run_id,
      repo: $repo,
      issue_number: ($issue_num | tonumber),
      status: "initialized",
      started_at: $ts,
      finished_at: null,
      current_state: "S0_Idle",
      branch: null,
      worktree_path: null,
      pr_url: null,
      cycle_review_decision: null,
      blocked_reason: null
    }' > "$tmp"
  mv -f "$tmp" "$run_dir/run.json"
}

# state_event <run-dir> <event-name> [<key=value> ...]
# Appends one event to state.jsonl. Extra key=value pairs are stored
# inside a "data" object. Values are passed verbatim as strings.
state_event() {
  local run_dir="$1"
  shift
  local event="$1"
  shift

  local jq_args=(--arg event "$event" --arg ts "$(_state_now)")
  local data_filter='{}'
  local i=0
  for kv in "$@"; do
    local k="${kv%%=*}"
    local v="${kv#*=}"
    jq_args+=(--arg "k${i}" "$k" --arg "v${i}" "$v")
    if [ "$data_filter" = '{}' ]; then
      data_filter="{(\$k${i}): \$v${i}}"
    else
      data_filter="${data_filter} + {(\$k${i}): \$v${i}}"
    fi
    i=$((i + 1))
  done

  jq -nc "${jq_args[@]}" \
    "{event: \$event, ts: \$ts, data: ($data_filter)}" \
    >> "$run_dir/state.jsonl"
}

# state_set <run-dir> <key> <value>
# Updates a single field in run.json atomically. Value is stored as a
# JSON string. For nested fields, use a dot.path (e.g. nested.field).
state_set() {
  local run_dir="$1"
  local key="$2"
  local value="$3"

  local tmp
  tmp=$(mktemp "$run_dir/.run.json.XXXXXX")
  jq --arg v "$value" --arg path ".$key" \
    'setpath(($path | ltrimstr(".") | split(".")); $v)' \
    "$run_dir/run.json" > "$tmp"
  mv -f "$tmp" "$run_dir/run.json"
}

# state_finalize <run-dir> <status> [<blocked-reason>]
# Sets status, finished_at, optional blocked_reason.
# NOTE: we deliberately avoid naming a local variable `status` — that
# clashes with a read-only special parameter in zsh and would break if
# this file is ever sourced from a zsh shell (e.g. probe scripts).
state_finalize() {
  local run_dir="$1"
  local new_status="$2"
  local reason="${3:-}"

  local tmp
  tmp=$(mktemp "$run_dir/.run.json.XXXXXX")
  if [ -n "$reason" ]; then
    jq --arg s "$new_status" --arg ts "$(_state_now)" --arg r "$reason" \
      '.status = $s | .finished_at = $ts | .blocked_reason = $r' \
      "$run_dir/run.json" > "$tmp"
  else
    jq --arg s "$new_status" --arg ts "$(_state_now)" \
      '.status = $s | .finished_at = $ts' \
      "$run_dir/run.json" > "$tmp"
  fi
  mv -f "$tmp" "$run_dir/run.json"
}
