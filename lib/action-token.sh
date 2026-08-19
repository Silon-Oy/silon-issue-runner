#!/usr/bin/env bash
# lib/action-token.sh — the shared secret for the Ohjaamo action channel (#77).
#
# The status page (status-render.sh, served on :8080 by Caddy) and the action
# service (action-server.sh, bound to a Tailscale address on :8081) are two
# different ORIGINS. `tailscale whois` authenticates the DEVICE that opened the
# TCP connection, not the PAGE the request came from: any site open in the same
# browser on a tailnet device could POST to the service and pass the whois
# check. The shared token closes that hole — status-render.sh embeds it in the
# page (<meta>) and the service requires it on every request, so a caller that
# cannot READ the page cannot forge a request. This is the third CSRF layer
# (origin allowlist + forced preflight header being the other two).
#
# The token lives in ONE file (default $HOME/.config/run-issues/action-token,
# mode 0600). Both processes call action_token_ensure to create it once,
# idempotently, and converge on the SAME value — a create-if-absent hardlink
# race means whoever loses reads the winner's token, never overwrites it. If the
# two processes ever held different tokens the page's token would not match the
# service's and every button would 403, so convergence is load-bearing.
#
# The token is a BEARER SECRET. It must NEVER reach status.json, the audit log,
# a situation comment, or any log line — it is confined to the page markup and
# the request header. That is why it lives outside the poller.env channel (which
# the pollers log around) and in its own 0600 file.
#
# This file only defines functions; sourcing is side-effect free.

# action_token_path — echo the token file path (env override, else default).
action_token_path() {
  printf '%s' "${RUN_ISSUES_ACTION_TOKEN_FILE:-$HOME/.config/run-issues/action-token}"
}

# _action_token_generate — echo a fresh high-entropy token, or fail (return 1)
# with no output when no entropy source is usable. 64 hex chars = 256 bits.
_action_token_generate() {
  local t=""
  if command -v openssl >/dev/null 2>&1; then
    t="$(openssl rand -hex 32 2>/dev/null)"
  fi
  if [ -z "$t" ] && [ -r /dev/urandom ]; then
    t="$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom 2>/dev/null | head -c 64)"
  fi
  [ -n "$t" ] || return 1
  printf '%s' "$t"
}

# action_token_ensure [<path>] — ensure a non-empty token file exists at <path>
# (default action_token_path) and echo the token. Idempotent: an existing
# non-empty file is READ, never rewritten. Returns non-zero only when the token
# can neither be read nor created (no entropy source, or an unwritable dir).
#
# Concurrency: a fresh token is written to a temp file (0600) and then HARDLINKED
# into place; `ln` fails atomically if the path already exists, so a process that
# loses the create race falls through to reading the winner's token. Both
# converge on one value.
action_token_ensure() {
  local path tok=""
  path="${1:-$(action_token_path)}"

  # Fast path: an existing non-empty token is authoritative.
  if [ -s "$path" ]; then
    tok="$(head -n1 "$path" 2>/dev/null | tr -d '\r\n[:space:]')"
    if [ -n "$tok" ]; then
      printf '%s' "$tok"
      return 0
    fi
  fi

  tok="$(_action_token_generate)" || return 1
  [ -n "$tok" ] || return 1

  local dir tmp
  dir="$(dirname "$path")"
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp="$(mktemp "$dir/.action-token.XXXXXX" 2>/dev/null)" || return 1
  chmod 0600 "$tmp" 2>/dev/null || true
  if ! printf '%s\n' "$tok" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  # Atomic create-if-absent: ln fails if $path already exists (race lost).
  if ln "$tmp" "$path" 2>/dev/null; then
    rm -f "$tmp"
    chmod 0600 "$path" 2>/dev/null || true
    printf '%s' "$tok"
    return 0
  fi
  rm -f "$tmp"

  # Race lost (or ln unsupported): read whatever is there now.
  if [ -s "$path" ]; then
    tok="$(head -n1 "$path" 2>/dev/null | tr -d '\r\n[:space:]')"
    if [ -n "$tok" ]; then
      printf '%s' "$tok"
      return 0
    fi
  fi
  return 1
}
