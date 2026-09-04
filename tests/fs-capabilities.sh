#!/usr/bin/env bash
# tests/fs-capabilities.sh — runtime probes for the filesystem behaviour a few
# assertions depend on. Not a test: the suite runner globs `test-*.sh`, so this
# name keeps it out of the run and available to `.`-source.
#
# WHY PROBE INSTEAD OF NAMING A PLATFORM. Three assertions in the suite are
# really assertions about POSIX file permissions: a cache file must be 0600, an
# unreadable key must fail closed, a hook without the execute bit must be
# skipped. Under Git Bash on a plain NTFS mount `chmod` is accepted and then
# ignored — 0600 reads back as 644, `chmod 000` leaves the file readable and
# `chmod -x` leaves it executable — so those three assert the OS rather than the
# package. `uname -s = MINGW*` would skip them, but it would also skip them on a
# Windows checkout mounted WITH ACL-backed permissions, where they do hold, and
# it would keep asserting on some future filesystem that behaves the same way
# NTFS does. The property is the filesystem's, so the probe asks the filesystem.
#
# Each probe creates and removes its own temporary file under the directory it
# is given. Functions only; no top-level work.

# fs_file_mode <path> — the file's mode as octal digits (e.g. 600), or empty.
# The `stat` format flag is not portable: BSD/macOS reads `-f`, GNU coreutils
# reads `-c` (and takes `-f` as --file-system). Same branch as lib/locking.sh.
fs_file_mode() {
  if [ "$(uname -s)" = "Darwin" ]; then
    stat -f '%Lp' "$1" 2>/dev/null || printf ''
  else
    stat -c '%a' "$1" 2>/dev/null || printf ''
  fi
}

# fs_enforces_modes <dir> — 0 when `chmod 600` is actually reflected back.
fs_enforces_modes() {
  local probe="$1/.fs-cap-mode.$$"
  : > "$probe" 2>/dev/null || return 1
  chmod 600 "$probe" 2>/dev/null
  local mode; mode="$(fs_file_mode "$probe")"
  rm -f "$probe"
  [ "$mode" = "600" ]
}

# fs_enforces_unreadable <dir> — 0 when `chmod 000` really removes read access.
# Skipped as meaningless for root, who reads regardless of the mode.
fs_enforces_unreadable() {
  local probe="$1/.fs-cap-read.$$"
  printf 'x\n' > "$probe" 2>/dev/null || return 1
  chmod 000 "$probe" 2>/dev/null
  local readable=1
  [ -r "$probe" ] && readable=0
  chmod 600 "$probe" 2>/dev/null
  rm -f "$probe"
  [ "$readable" -ne 0 ]
}

# fs_can_stage_non_executable <dir> — 0 when a freshly written script that was
# never chmod +x'd reads back as NOT executable. Git Bash answers no: MSYS calls
# a file executable when its first bytes are `#!`, so a hook the test means to
# leave inert is executable the moment it is written, and there is no chmod that
# takes the bit away again.
fs_can_stage_non_executable() {
  local probe="$1/.fs-cap-exec.$$"
  printf '#!/bin/sh\nexit 0\n' > "$probe" 2>/dev/null || return 1
  local is_x=1; [ -x "$probe" ] && is_x=0
  rm -f "$probe"
  [ "$is_x" -ne 0 ]
}
