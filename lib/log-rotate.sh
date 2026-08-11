#!/usr/bin/env bash
# lib/log-rotate.sh — size-based log rotation for the pollers.
#
# Both pollers own four log files each (.log, .runs.log, .stdout.log,
# .stderr.log) and nothing ever trimmed them: pr-watch-poller.runs.log was
# measured at 190 MB (issue #65). This keeps a single previous generation per
# file — mv <file> <file>.1, replacing any existing .1 — so a file can grow to
# at most ~2× the cap between ticks.
#
# The rotation MUST run at the very start of a tick, BEFORE the poller's `exec`
# redirect opens .stdout.log/.stderr.log: once a file descriptor points at the
# file, moving the file leaves the fd writing to the moved inode, defeating the
# rotation. The .log/.runs.log files are reopened on every `>>` append, so their
# timing is less delicate, but rotating all four together at tick start keeps
# the rule simple.
#
# Defines one function only; no top-level work. Sourcing is side-effect-free.

# rotate_log_if_big <path> <max-bytes>
# Rotate <path> to <path>.1 when its size exceeds <max-bytes>. One generation is
# kept (the old .1 is overwritten). A <max-bytes> of 0 (or non-numeric) disables
# rotation. A missing file, or a size that cannot be read, is a silent no-op.
#
# `mv` on the same filesystem is atomic, so a concurrent reader (status.sh
# tailing state.jsonl is unrelated, but a human `tail -f` on the log is not)
# always sees either the intact old file or the intact new one — never a
# half-moved file. The rotated-away generation stays on disk as <path>.1.
rotate_log_if_big() {
  local path="$1" max="${2:-0}" size
  # Disabled when max is 0 or not a positive integer.
  [ "$max" -gt 0 ] 2>/dev/null || return 0
  [ -f "$path" ] || return 0
  size=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]') || return 0
  [ -n "$size" ] || return 0
  if [ "$size" -gt "$max" ] 2>/dev/null; then
    mv -f "$path" "$path.1" 2>/dev/null || true
  fi
}
