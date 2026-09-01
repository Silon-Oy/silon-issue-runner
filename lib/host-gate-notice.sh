#!/usr/bin/env bash
# lib/host-gate-notice.sh — deliver the host gate's "variable is not set" line
# to somewhere a human will actually find it.
#
# The gate has no default host list (#152), so an unset RUN_ISSUES_POLLER_HOSTS
# / RUN_ISSUES_ACTION_HOSTS stops the machine dead. Reporting that on stderr
# alone put the line exactly where nobody reads it: the plists carry no
# StandardErrorPath key (launchd expands no variables there, so a literal $HOME
# would land in a directory called '$HOME' — CLAUDE.md section 10), and each
# script opens its own logs only AFTER the gate, deliberately, so that a foreign
# machine creates nothing. Under a LaunchAgent — the only production mode — the
# line therefore went to a closed fd. It was visible when run by hand, which is
# the one case where the operator already knows what they are doing.
#
# So the line goes to BOTH: stderr (unchanged — a manual run still prints, and
# under launchd this is a harmless no-op) and the script's own log file, which
# is where someone asking "why has nothing run?" looks.
#
# Separate from poller-config.sh on purpose: that module's contract is that it
# is pure — no writes, no external commands, no exits — and this writes to disk.
# lib/log-rotate.sh was split out from it for the same reason.
#
# Defines one function only; no top-level work. Sourcing is side-effect-free.

# host_gate_notice <line> [log-path]
# Print <line> to stderr, then append it to <log-path> unless that file's last
# line is already the same text.
#
# The de-duplication is not cosmetic. The two pollers tick every 300s, so an
# unconditional append writes 288 identical lines a day into the file someone
# is trying to read — the noise failure CLAUDE.md section 5.7 exists to prevent
# (the original incident wrote 1754 identical lines, none of them signal). When
# the gate is what stopped the tick the poller writes nothing else, so from the
# second tick on the log's last line IS this message: comparing against
# `tail -n 1` needs no state file of its own, and reads only the tail, per the
# rule in section 5.3. That is also why the line carries no timestamp — stamped
# lines would all differ and nothing would ever be suppressed.
#
# Every disk step is best-effort: a log that cannot be written must not turn a
# configuration error into a crash. action-server.sh in particular exits 0 here
# (KeepAlive.SuccessfulExit=false would crash-loop on anything else).
host_gate_notice() {
  local line="${1-}" log="${2-}" dir
  printf '%s\n' "$line" >&2
  [ -n "$log" ] || return 0
  dir=$(dirname "$log")
  mkdir -p "$dir" 2>/dev/null || return 0
  # Written as an `if` rather than `[ ... ] && return 0` so the callers running
  # `set -e` cannot be surprised by the and-list's exit status.
  if [ "$(tail -n 1 "$log" 2>/dev/null)" = "$line" ]; then
    return 0
  fi
  printf '%s\n' "$line" >>"$log" 2>/dev/null || true
  return 0
}
