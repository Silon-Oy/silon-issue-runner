#!/usr/bin/env bash
# test-cleanup-run-report.sh — cleanup-run.sh must not report "Done." when a
# GitHub operation failed (issue #31).
#
# The bug: cleanup-run.sh tore down local artefacts, watched every `gh` call
# fail (gh not on PATH over ssh), and still printed "Done." with exit 0 — so 25
# issues stayed assigned and dropped out of auto-run pickup silently. The fix
# has three observable parts, one case each:
#
#   A) gh present but every call fails → local state still cleaned, but the run
#      reports a partial-failure summary and exits non-zero (4), NOT "Done.".
#   B) gh present and every call succeeds → the unchanged happy path: "Done.",
#      exit 0.
#   C) gh missing → refuse BEFORE any side effect with exit 3, so a partial
#      teardown never starts.
#
# Run: bash tests/test-cleanup-run-report.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP="$HERE/../cleanup-run.sh"
STATE_LIB="$HERE/../lib/state.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

WORK=$(mktemp -d -t cleanup-report.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0

# make_run <issue-num> <lock-root> — create a non-completed run for the issue in
# a fresh repo and echo "REPO RID" so callers can assert on the artefacts.
make_run() {
  local issue="$1" repo="$2"
  mkdir -p "$repo/.git"
  # shellcheck source=lib/state.sh
  ( . "$STATE_LIB"
    RID="20260806-00${issue}-issue-${issue}"
    RD="$repo/.claude/run-issues/$RID"
    state_init "$RD" "$RID" "$repo" "$issue"
    state_finalize "$RD" "blocked" ) >/dev/null 2>&1
  printf '20260806-00%s-issue-%s' "$issue" "$issue"
}

# ---- Case A: gh present but failing → partial-failure report, exit 4 ----
REPO_A="$WORK/repoA"
RID_A=$(make_run 41 "$REPO_A")
BIN_A="$WORK/binA"; mkdir -p "$BIN_A"
cat > "$BIN_A/gh" <<'SH'
#!/usr/bin/env bash
echo "gh: simulated failure" >&2
exit 1
SH
chmod +x "$BIN_A/gh"

OUT_A=$(PATH="$BIN_A:$PATH" RUN_ISSUES_LOCK_ROOT="$WORK/locksA" \
  bash "$CLEANUP" --repo "$REPO_A" --issue 41 --yes 2>&1)
RC_A=$?

if [ "$RC_A" -eq 4 ]; then
  echo "PASS: failing GitHub ops exit 4 (not 0)"
else
  echo "FAIL: expected exit 4 on GitHub failure, got $RC_A"; FAIL=1
fi
if printf '%s\n' "$OUT_A" | grep -q 'GitHub op(s) failed'; then
  echo "PASS: partial-failure summary names the GitHub failures"
else
  echo "FAIL: no partial-failure summary in output:"; printf '%s\n' "$OUT_A"; FAIL=1
fi
if printf '%s\n' "$OUT_A" | grep -qx 'Done.'; then
  echo "FAIL: bare 'Done.' printed despite GitHub failures"; FAIL=1
else
  echo "PASS: no bare 'Done.' on partial failure"
fi
# Local teardown still happened — the run-dir is gone.
if [ -d "$REPO_A/.claude/run-issues/$RID_A" ]; then
  echo "FAIL: run-dir survived — local teardown did not run"; FAIL=1
else
  echo "PASS: local state torn down even though GitHub ops failed"
fi

# ---- Case B: gh present and succeeding → "Done.", exit 0 ----
REPO_B="$WORK/repoB"
RID_B=$(make_run 42 "$REPO_B")
BIN_B="$WORK/binB"; mkdir -p "$BIN_B"
cat > "$BIN_B/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$BIN_B/gh"

OUT_B=$(PATH="$BIN_B:$PATH" RUN_ISSUES_LOCK_ROOT="$WORK/locksB" \
  bash "$CLEANUP" --repo "$REPO_B" --issue 42 --yes 2>&1)
RC_B=$?

if [ "$RC_B" -eq 0 ]; then
  echo "PASS: all-success path exits 0"
else
  echo "FAIL: expected exit 0 on full success, got $RC_B"; printf '%s\n' "$OUT_B"; FAIL=1
fi
if printf '%s\n' "$OUT_B" | grep -qx 'Done.'; then
  echo "PASS: full success prints 'Done.'"
else
  echo "FAIL: 'Done.' missing on full success:"; printf '%s\n' "$OUT_B"; FAIL=1
fi

# ---- Case C: gh missing → refuse before any side effect, exit 3 ----
# Build a curated PATH that has the tools the script touches before the gate but
# NOT gh. Symlink individual binaries so gh cannot leak in via a shared dir.
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
missing_tool=0
for t in bash dirname basename git jq sed cat tr cut grep mktemp rm mkdir cp uname stat env; do
  # `type -P` and not `command -v`: the latter answers with the NAME of a shell
  # function when one shadows the tool, and lib/jq-binary.sh shadows jq on
  # Windows. A name is not a link target.
  p=$(type -P "$t" 2>/dev/null) || { missing_tool=1; continue; }
  [ -n "$p" ] || { missing_tool=1; continue; }
  ln -s "$p" "$FAKEBIN/$t"
done

# The curated PATH has to actually work, and on Git Bash it does not: the tools
# are `<name>.exe`, so a link named `<name>` is a file Windows will not launch,
# and every command in the child resolves to nothing (exit 127) — which the case
# below would read as "the gh gate did not fire". Prove the PATH first.
if [ "$missing_tool" -eq 0 ] && ! PATH="$FAKEBIN" bash -c 'git --version' >/dev/null 2>&1; then
  missing_tool=2
fi

if [ "$missing_tool" -eq 2 ]; then
  echo "SKIP: the assembled gh-free PATH is not executable here (Git Bash: a PATH entry needs its .exe name)"
elif [ "$missing_tool" -eq 1 ]; then
  echo "SKIP: could not assemble a gh-free PATH (a base tool is missing)"
else
  REPO_C="$WORK/repoC"
  RID_C=$(make_run 43 "$REPO_C")
  OUT_C=$(PATH="$FAKEBIN" RUN_ISSUES_LOCK_ROOT="$WORK/locksC" \
    bash "$CLEANUP" --repo "$REPO_C" --issue 43 --yes 2>&1)
  RC_C=$?

  if [ "$RC_C" -eq 3 ]; then
    echo "PASS: missing gh refuses with exit 3"
  else
    echo "FAIL: expected exit 3 when gh is absent, got $RC_C"; printf '%s\n' "$OUT_C"; FAIL=1
  fi
  # The refusal must precede any teardown: the run-dir is still there.
  if [ -d "$REPO_C/.claude/run-issues/$RID_C" ]; then
    echo "PASS: gate refused before any local teardown (run-dir intact)"
  else
    echo "FAIL: local state was torn down despite missing gh"; FAIL=1
  fi
fi

# ---- Case D: --dry-run performs no side effect, so it needs no gh and never
#      reports a failure. With gh absent it must still exit 0 and keep the
#      run-dir. (The gate and the failure counter must not fire on a dry run.) --
if [ "$missing_tool" -eq 0 ]; then
  REPO_D="$WORK/repoD"
  RID_D=$(make_run 44 "$REPO_D")
  OUT_D=$(PATH="$FAKEBIN" RUN_ISSUES_LOCK_ROOT="$WORK/locksD" \
    bash "$CLEANUP" --repo "$REPO_D" --issue 44 --yes --dry-run 2>&1)
  RC_D=$?

  if [ "$RC_D" -eq 0 ]; then
    echo "PASS: --dry-run without gh still exits 0"
  else
    echo "FAIL: --dry-run should exit 0 even without gh, got $RC_D"; printf '%s\n' "$OUT_D"; FAIL=1
  fi
  if [ -d "$REPO_D/.claude/run-issues/$RID_D" ]; then
    echo "PASS: --dry-run left the run-dir untouched"
  else
    echo "FAIL: --dry-run removed the run-dir"; FAIL=1
  fi
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "cleanup-run-report: all passed" || echo "cleanup-run-report: FAILURES"
[ "$FAIL" -eq 0 ]
