#!/usr/bin/env bash
# lib/gitignore.sh — keep the TARGET repo's .gitignore ignoring the /run-issues
# runtime artefacts the orchestrator creates in the working tree.
#
# The orchestrator writes per-run dirs under <repo>/.claude/ (run-issues/,
# run-issues-archive/, worktrees/). Without a .gitignore entry these leak into
# the target project's version control — the implementer's `git add` and any
# auto-sync would pull them in. CLAUDE.md already *assumes* they are ignored
# ("gitignoressa, ei versionhallintaa"); this makes that true automatically.
#
# The entries live inside a marker-delimited managed block so re-runs are
# idempotent (no duplicate lines) and the path set can evolve in one place.
# The function is pure file I/O (no git) so it is unit-testable on its own.

set -euo pipefail

# Marker lines delimiting the block this helper owns. Anything between them is
# replaced wholesale on update; everything else in the file is left untouched.
RUN_ISSUES_GITIGNORE_BEGIN="# >>> /run-issues orchestrator runtime state (managed — do not edit) >>>"
RUN_ISSUES_GITIGNORE_END="# <<< /run-issues orchestrator runtime state <<<"

# _run_issues_gitignore_block — emit the desired managed block (markers +
# body). Single source of truth for the ignored paths.
_run_issues_gitignore_block() {
  printf '%s\n' "$RUN_ISSUES_GITIGNORE_BEGIN"
  printf '%s\n' "# Per-run artefacts (logs, prompts, JSON state) and git worktrees created"
  printf '%s\n' "# by the /run-issues orchestrator. Auto-maintained — never version-controlled."
  printf '%s\n' ".claude/run-issues/"
  printf '%s\n' ".claude/run-issues-archive/"
  printf '%s\n' ".claude/worktrees/"
  printf '%s\n' "$RUN_ISSUES_GITIGNORE_END"
}

# ensure_run_issues_gitignore <gitignore-path>
# Ensures the file contains the managed run-issues block. Idempotent:
#   - file/block absent      -> create or append the block, return 0 (changed)
#   - block present, current -> no write, return 1 (unchanged)
#   - block present, stale   -> replace the block in place, return 0 (changed)
# Return code lets the caller decide whether a commit is warranted.
ensure_run_issues_gitignore() {
  local target="$1"
  local desired existing="" preamble="" rebuilt
  desired="$(_run_issues_gitignore_block)"

  [ -f "$target" ] && existing="$(cat "$target")"

  # Strip any existing managed block (BEGIN..END inclusive). awk only needs the
  # single-line markers — passing the multi-line block via -v is unportable
  # (BSD awk rejects embedded newlines), so the desired block is reattached in
  # shell below rather than inside awk.
  if [ -n "$existing" ]; then
    preamble="$(printf '%s\n' "$existing" | awk \
      -v b="$RUN_ISSUES_GITIGNORE_BEGIN" -v e="$RUN_ISSUES_GITIGNORE_END" '
      $0 == b { skip = 1; next }
      skip && $0 == e { skip = 0; next }
      skip { next }
      { print }
    ')"
    # Drop trailing blank lines so the separator below is deterministic.
    preamble="$(printf '%s' "$preamble" | sed -e 's/[[:space:]]*$//' | awk '
      { lines[NR] = $0 }
      END { last = NR; while (last > 0 && lines[last] == "") last--;
            for (i = 1; i <= last; i++) print lines[i] }
    ')"
  fi

  # Reattach the desired block: preamble (if any) + blank separator + block.
  if [ -n "$preamble" ]; then
    rebuilt="$preamble"$'\n\n'"$desired"
  else
    rebuilt="$desired"
  fi

  # Write (and report change) only when the result differs from the current
  # file — including the trailing newline printf adds.
  if [ -f "$target" ] && [ "$existing" = "$rebuilt" ]; then
    return 1
  fi
  printf '%s\n' "$rebuilt" > "$target"
  return 0
}
