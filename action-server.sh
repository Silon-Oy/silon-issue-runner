#!/usr/bin/env bash
# action-server.sh — lifecycle wrapper for the Ohjaamo action service (#77).
#
# The package's FIRST listening process. It owns everything around the socket so
# that lib/action-service.py can be a thin HTTP + auth core: the host gate, the
# config channel (poller.env), log rotation, dependency preflight, the Tailscale
# bind address, the allowed-user default, the shared token, and the environment
# the Python inherits. It ends with `exec python3 …`, so the Python's exit code
# becomes this process's exit code — which is why the codes below split cleanly
# between what THIS script decides (1/2) and what the service decides (0/3/4).
#
# Elinkaari periytyy pollerimallista, yhtä poikkeusta lukuun ottamatta:
#   - host gate (RUN_ISSUES_ACTION_HOSTS, poller_host_allowed) — foreign machine
#     no-ops (exit 0), exactly like the pollers;
#   - poller.env is the sourced config channel (launchd hands no environment);
#   - log rotation (lib/log-rotate.sh) BEFORE the exec redirect;
#   - the plist runs a long-lived KeepAlive daemon, NOT a StartInterval tick —
#     the one genuinely new element, justified by bind recovery: a boot where the
#     Tailscale address is not up yet exits non-zero and launchd retries.
#
# SECURITY MODEL (see README §7.9): the service binds ONLY to a Tailscale address
# (never 0.0.0.0), authenticates the caller by tailnet identity, and must NOT sit
# behind a reverse proxy. This wrapper enforces the bind: with no explicit
# RUN_ISSUES_ACTION_BIND it uses `tailscale ip -4`, and if that yields nothing it
# REFUSES to bind (exit 3) rather than fall back to a wildcard address.
#
# Usage:
#   action-server.sh            run the service (the LaunchAgent path)
#   action-server.sh --check    validate config + deps and exit (no bind)
#   action-server.sh -h|--help  show this help
#
# Exit codes (own space):
#   0  clean exit — host gate no-op, --check OK, or the service stopped on SIGTERM
#   1  usage error (unknown flag)
#   2  missing required dependency (python3 / jq / the Tailscale CLI)
#   3  bind failed — no Tailscale address to bind to, or the port is taken
#      (launchd's KeepAlive retries; this is the boot-before-tailnet case)
#   4  config refuses — the service has no allowed identity or no token
#
# Run: action-server.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_ISSUES_HOME="${RUN_ISSUES_HOME:-$HERE}"

CHECK_ONLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check)   CHECK_ONLY=1 ;;
    -h|--help) sed -n '27,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'action-server: unknown flag: %s\n' "$1" >&2; exit 1 ;;
  esac
  shift
done

# ---- config channel: poller.env (same LaunchAgent env-less reasoning) --------
POLLER_ENV_FILE="${RUN_ISSUES_POLLER_ENV_FILE:-${HOME}/.config/run-issues/poller.env}"
if [ -f "$POLLER_ENV_FILE" ]; then
  set +u
  # shellcheck disable=SC1090
  . "$POLLER_ENV_FILE"
  set -u
fi

# ---- shared libs (function-only, safe to source) ----
# shellcheck source=lib/poller-config.sh
. "${RUN_ISSUES_HOME}/lib/poller-config.sh"
# shellcheck source=lib/log-rotate.sh
. "${RUN_ISSUES_HOME}/lib/log-rotate.sh"
# shellcheck source=lib/host-gate-notice.sh
. "${RUN_ISSUES_HOME}/lib/host-gate-notice.sh"
# shellcheck source=lib/preflight.sh
. "${RUN_ISSUES_HOME}/lib/preflight.sh"
# shellcheck source=lib/action-token.sh
. "${RUN_ISSUES_HOME}/lib/action-token.sh"

# poller-config.sh / git-remote.sh enable errexit at source time; re-disable it.
# This script deliberately runs with `set -uo pipefail` and NO -e: it has many
# tolerated-non-zero probes (tr/head/jq resolving optional config) that must not
# abort the daemon before it can bind or exec.
set +e

# Resolved above the gate, created below it — see poller.sh.
LOG_DIR="${RUN_ISSUES_LOG_DIR:-${HOME}/Library/Logs}"

# ---- host gate (before any path is created) ----
# Inherits the pollers' rule (#152): no default list, an unset variable earns
# one explanatory line, a non-matching one stays silent. Both exit 0, which
# matters more here than in a poller — KeepAlive.SuccessfulExit=false restarts
# on any non-zero exit, so reporting a config error with one would crash-loop.
# The line goes through host_gate_notice for the same reason it does there: the
# exec redirect that connects stderr is below this gate, not above it.
HOST="$(hostname -s 2>/dev/null || echo unknown)"
if [ -z "${RUN_ISSUES_ACTION_HOSTS:-}" ]; then
  host_gate_notice \
    "$(poller_host_unset_message RUN_ISSUES_ACTION_HOSTS "$POLLER_ENV_FILE" "$HOST")" \
    "${LOG_DIR}/run-issues-action.stderr.log"
  exit 0
fi
poller_host_allowed "$HOST" "$RUN_ISSUES_ACTION_HOSTS" || exit 0

# ---- log rotation + own log paths (like the pollers) ----
RUN_ISSUES_LOG_MAX_BYTES="${RUN_ISSUES_LOG_MAX_BYTES:-10485760}"
mkdir -p "$LOG_DIR" 2>/dev/null || true
rotate_log_if_big "$LOG_DIR/run-issues-action.stdout.log"  "$RUN_ISSUES_LOG_MAX_BYTES"
rotate_log_if_big "$LOG_DIR/run-issues-action.stderr.log"  "$RUN_ISSUES_LOG_MAX_BYTES"
# The audit log itself is rotated by the Python (open-append-close per line), so
# it is intentionally NOT rotated here — an already-open fd is not the issue.
if [ "$CHECK_ONLY" -ne 1 ] && [ ! -t 1 ]; then
  exec >>"$LOG_DIR/run-issues-action.stdout.log" 2>>"$LOG_DIR/run-issues-action.stderr.log"
fi

err() { printf 'action-server: %s\n' "$1" >&2; }

# ---- preflight: python3, jq, and the Tailscale CLI ----
PYTHON_BIN="${RUN_ISSUES_ACTION_PYTHON:-}"
if [ -z "$PYTHON_BIN" ]; then
  if preflight_have python3; then PYTHON_BIN="python3"; fi
fi
if [ -z "$PYTHON_BIN" ] || ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  err "python3 is required (xcode-select --install), or set RUN_ISSUES_ACTION_PYTHON"
  exit 2
fi
preflight_have jq || { err "jq is required (brew install jq)"; exit 2; }

# Resolve the Tailscale CLI: env override, PATH, then the known app / brew paths.
# The standalone variant has no LocalAPI socket, so the CLI is the variant-
# independent surface (design decision 2).
resolve_tailscale() {
  local c
  if [ -n "${RUN_ISSUES_TAILSCALE_BIN:-}" ] && [ -x "${RUN_ISSUES_TAILSCALE_BIN}" ]; then
    printf '%s' "$RUN_ISSUES_TAILSCALE_BIN"; return 0
  fi
  if command -v tailscale >/dev/null 2>&1; then command -v tailscale; return 0; fi
  for c in /Applications/Tailscale.app/Contents/MacOS/Tailscale \
           /opt/homebrew/bin/tailscale /usr/local/bin/tailscale; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}
TS_BIN="$(resolve_tailscale)" || { err "the Tailscale CLI was not found (set RUN_ISSUES_TAILSCALE_BIN)"; exit 2; }

# ---- resolve the bind address: NEVER a wildcard ----
# Explicit override wins (tests use 127.0.0.1). Otherwise the first Tailscale
# IPv4. If neither yields an address, refuse to bind (exit 3) — launchd retries,
# which is exactly the boot-before-tailnet recovery path.
BIND="${RUN_ISSUES_ACTION_BIND:-}"
if [ -z "$BIND" ]; then
  BIND="$("$TS_BIN" ip -4 2>/dev/null | head -n1 | tr -d '[:space:]')"
fi
case "$BIND" in
  ""|0.0.0.0|"::"|"[::]")
    err "no Tailscale address to bind to (got '${BIND:-<none>}'); refusing a wildcard bind. Is Tailscale up?"
    exit 3 ;;
esac
PORT="${RUN_ISSUES_ACTION_PORT:-8081}"

# ---- resolve allowed users: default = this node's own tailnet owner ----
ALLOWED_USERS="${RUN_ISSUES_ACTION_ALLOWED_USERS:-}"
if [ -z "$ALLOWED_USERS" ]; then
  ALLOWED_USERS="$("$TS_BIN" status --json 2>/dev/null | jq -r '
    (.Self.UserID | tostring) as $u | (.User[$u].LoginName // empty)' 2>/dev/null | tr -d '[:space:]')"
fi
if [ -z "$ALLOWED_USERS" ]; then
  err "could not resolve an allowed tailnet user (set RUN_ISSUES_ACTION_ALLOWED_USERS); refusing (fail-closed)"
  exit 4
fi

# ---- resolve the allowed page origin(s): default http://<bind>:8080 ----
ORIGIN="${RUN_ISSUES_ACTION_ORIGIN:-http://$BIND:8080}"

# ---- ensure the shared token (idempotent, mode 0600) ----
TOKEN_FILE="$(action_token_path)"
if ! action_token_ensure "$TOKEN_FILE" >/dev/null; then
  err "could not create or read the shared token at $TOKEN_FILE; refusing"
  exit 4
fi

DISPATCH="$RUN_ISSUES_HOME/action-dispatch.sh"
[ -x "$DISPATCH" ] || { err "action-dispatch.sh is not executable at $DISPATCH"; exit 2; }

# ---- export the environment the service inherits, then exec ----
export RUN_ISSUES_ACTION_BIND="$BIND"
export RUN_ISSUES_ACTION_PORT="$PORT"
export RUN_ISSUES_ACTION_ALLOWED_USERS="$ALLOWED_USERS"
export RUN_ISSUES_ACTION_ORIGIN="$ORIGIN"
export RUN_ISSUES_ACTION_TOKEN_FILE="$TOKEN_FILE"
export RUN_ISSUES_ACTION_DISPATCH="$DISPATCH"
export RUN_ISSUES_TAILSCALE_BIN="$TS_BIN"
export RUN_ISSUES_LOG_DIR="$LOG_DIR"
export RUN_ISSUES_LOG_MAX_BYTES

if [ "$CHECK_ONLY" -eq 1 ]; then
  printf 'action-server: OK — bind=%s:%s users=%s origin=%s python=%s tailscale=%s\n' \
    "$BIND" "$PORT" "$ALLOWED_USERS" "$ORIGIN" "$PYTHON_BIN" "$TS_BIN"
  exit 0
fi

exec "$PYTHON_BIN" "$RUN_ISSUES_HOME/lib/action-service.py"
