#!/usr/bin/env bash
# lib/jq-binary.sh — make `jq` emit LF on every platform the package runs on.
#
# WHY THIS EXISTS. `jq` is a native Windows executable under Git Bash, and it
# opens stdout in the C runtime's TEXT mode: every `\n` it writes leaves the
# process as `\r\n`. Measured on windows-latest (Git Bash, jq-1.8.1):
#
#   $ printf '{"p":"/tmp/x"}' | jq -r .p | od -c
#   0000000   /   t   m   p   /   x  \r  \n
#
# `$(...)` strips the trailing newline but NOT the carriage return, so every
# value read out of jq carries an invisible `\r`. The failures that produces are
# silent and look like unrelated logic bugs: `[ -d "$path" ]` is false for a
# path that exists, a watchlist entry stops matching its own repo so the repo
# falls back to the default labels, `case "$n" in *[!0-9]*)` classifies a
# perfectly good count as a non-numeric body and the fail-closed branch fires.
# Twelve of the twenty test files that were red on Windows failed only for this.
#
# WHY A FUNCTION AND NOT A CALL-SITE EDIT. There are ~700 `jq` invocations in
# the package across 33 files. Editing them is not a fix but a migration that
# the next added call site silently leaves behind — the same shape as the
# namespace rule in lib/machine-env.sh, where an exception list would have left
# the next variable uncovered. One shim covers every call site, present and
# future, and `command jq` inside it is what keeps it from recursing.
#
# WHY `-b` AND NOT A `tr -d '\r'` PIPE. `jq --binary` (jq >= 1.7) is jq's own
# switch for exactly this: it opens the streams in binary mode, so nothing is
# translated in the first place. A pipe would work on the bytes but destroy the
# exit status, and `jq -e` is a gate in this package (an empty or false result
# is a decision, not a formatting detail). lib/preflight.sh requires a jq that
# understands the flag on this platform, so a jq too old to take it is a named
# refusal at the S0 gate rather than silent corruption later.
#
# THE BRANCH IS AN ALLOW-LIST, THE OPPOSITE OF lib/paths.sh. There the risk was
# leaving an unnamed platform on the macOS default, so everything but Darwin
# takes the portable branch. Here the risk runs the other way: `-b` is a no-op
# on any platform whose streams are already binary, but it is a hard error on
# a jq older than 1.7, so it is added only where it is needed and nowhere else.
#
# IT IS EXPORTED, on that platform only. A bash function reaches subshells and
# `$(...)` for free but NOT a child process, and this package's jq calls are
# spread across processes by design: a poller spawns the orchestrator, the
# orchestrator runs the target repo's provisioning hook, the action service
# `execve`s a dispatcher, and a test spawns the gh shim it just wrote. Sourcing
# alone would leave every one of those children back on CRLF. Exporting also
# happens to be the correct answer for the target repo's own hooks: `-b` is
# what any script parsing jq output on Windows wants. The cost is one
# `BASH_FUNC_jq%%` in the environment of Windows children, `claude` among them;
# on macOS and Linux the function is never defined, so nothing is exported and
# the environment is untouched.
#
# ONE CONSEQUENCE THE EXPORT CARRIES. `command -v jq` answers yes for a shell
# function, so in a child that inherits the shim the installed-check is true
# even if that child's PATH holds no jq at all. Nothing in the package strips
# its own PATH, so the only place this shows is a test that stages "no tools":
# tests/test-preflight.sh drops the function alongside the PATH it empties, and
# tests/test-cleanup-run-report.sh reads link targets with `type -P`, which
# ignores functions by definition.
#
# Defines a function only; no top-level work and no `set`. Sourcing is
# side-effect-free, which matters because the pollers source it above their host
# gate. tests/test-jq-binary.sh derives the entry point set from disk and fails
# closed when one of them stops sourcing this.

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    # The shim is defined only over a jq that EXISTS and takes the flag. A bare
    # `command -v jq` is this package's "is jq installed?" gate in five places
    # and it answers yes for a function, so an unconditional definition would
    # report a healthy jq on a machine that has none. A jq too old for `-b`
    # (< 1.7) is left unshimmed on purpose as well: preflight names that as a
    # missing dependency, which is a diagnosis, where a `tr -d` fallback would
    # be a silent half-fix that also swallowed `jq -e`'s exit status.
    if command -v jq >/dev/null 2>&1 && command jq -b -n 1 >/dev/null 2>&1; then
      jq() { command jq -b "$@"; }
      export -f jq
    fi
    ;;
esac
