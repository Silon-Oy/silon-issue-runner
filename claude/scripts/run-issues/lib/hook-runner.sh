#!/usr/bin/env bash
# lib/hook-runner.sh — synchronous git commit that drives post-commit hooks
# to completion before returning. Used by /run-issues so doc-update and
# codex-security commits land on the same feature branch.
#
# The mechanism is a single env flag: POST_COMMIT_SYNC=1 makes the
# global post-commit hook run its phases in the foreground.

set -euo pipefail

# sync_commit <message>
# Stages NOTHING — caller must `git add` first. Runs the commit with the
# sync flag and returns the commit's exit code (0 even if the post-commit
# hook reports a non-fatal phase failure — the hook propagates only the
# worst sub-exit, see shared/git-templates/hooks/post-commit).
sync_commit() {
  local message="$1"
  POST_COMMIT_SYNC=1 git commit -m "$message"
}

# sync_commit_all <message>
# Convenience: equivalent to `git commit -am <msg>` but synchronous.
sync_commit_all() {
  local message="$1"
  POST_COMMIT_SYNC=1 git commit -am "$message"
}
