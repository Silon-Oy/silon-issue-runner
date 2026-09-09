#!/usr/bin/env bash
# test-pr-watch-gh-gate.sh — the P0 gh dependency gate in pr-watch.sh (issue #279).
#
# A missing or unauthenticated gh used to be indistinguishable from a transient
# PR-level error: the first `gh pr view` failed, watch_one logged "gh pr view
# failed for PR #N" and returned 4 ("safe to retry next poll"), yet nothing had
# been checked and nothing changed on the next tick — a silent stuck run. The
# gate must instead observe the durable condition once per invocation, before the
# first PR call, and exit with its own code (9, not 4). It reuses lib/preflight.sh
# — the same probe the orchestrator's S0 gate uses — rather than a copy.
#
# Cases:
#   A1  gh absent from PATH (named PR) -> exit 9, one explanatory line naming gh,
#       and NEITHER the transient "gh pr view failed" line NOR exit 4
#   A2  gh absent from PATH (scan) -> exit 9 with the gate line printed exactly
#       ONCE, before any per-PR work (§5.7: not once per candidate)
#   B1  gh present but `gh auth token` fails, App mode OFF -> exit 9 + fix hint
#   B2  gh present, auth fails, App mode ON -> NOT fatal (warning, gate passes)
#   C   gh present + authenticated, but `gh pr view` fails with a reason on
#       stderr -> the reason reaches the log (the P3 call no longer swallows
#       gh_route's re-emitted stderr with 2>/dev/null) and rc is 4, unchanged
#   D   gh present + authenticated + a mergeable PR -> the gate is transparent:
#       normal behaviour is unchanged (foreign-host merge, rc 0, no gate line)
#
# Offline and machine-independent: gh is a PATH stub (or deliberately absent),
# HOME is a throwaway dir and the lock root is redirected into the work dir.
#
# Run: bash tests/test-pr-watch-gh-gate.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRWATCH="$HERE/../pr-watch.sh"
STATE_LIB="$HERE/../lib/state.sh"

WORK=$(mktemp -d -t prwatch-ghgate.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; FAIL=1; }

REPO="$WORK/repo"
git init -q "$REPO"

export HOME="$WORK/home"; mkdir -p "$HOME"
export RUN_ISSUES_LOCK_ROOT="$WORK/locks"

# A bin dir mirroring the whole current PATH except gh, so `command -v gh` fails
# genuinely while every other tool the script needs stays reachable. This is the
# only robust way to hide exactly one binary that may live in several PATH dirs.
NOGH="$WORK/nogh-bin"
mkdir -p "$NOGH"
IFS=':' read -r -a _pdirs <<< "$PATH"
for d in "${_pdirs[@]}"; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    [ "$b" = "gh" ] && continue
    [ -e "$NOGH/$b" ] && continue
    ln -s "$f" "$NOGH/$b" 2>/dev/null || true
  done
done
command -v gh >/dev/null 2>&1 && [ ! -e "$NOGH/gh" ] || true

# A working gh stub: `auth token` obeys $GH_AUTH_RC, `pr view` obeys
# $GH_PRVIEW_RC (printing $GH_PRVIEW_ERR to stderr on failure and a mergeable PR
# on success), `pr merge` succeeds, everything else is a no-op.
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "auth token")
    [ "${GH_AUTH_RC:-0}" = "0" ] && printf 'gho_stubtoken\n'
    exit "${GH_AUTH_RC:-0}" ;;
  "pr view")
    if [ "${GH_PRVIEW_RC:-0}" != "0" ]; then
      printf '%s\n' "${GH_PRVIEW_ERR:-gh: something went wrong}" >&2
      exit "${GH_PRVIEW_RC}"
    fi
    cat <<'JSON'
{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN",
 "labels":[{"name":"auto-merge"}],"statusCheckRollup":[],"headRefName":"feature/x"}
JSON
    ;;
  "pr merge") echo "merged (mock)" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN/gh"

# ---- A1: gh absent from PATH, named PR ----
OUT=$(PATH="$NOGH" "$PRWATCH" "$REPO" 42 2>&1); RC=$?
[ "$RC" -eq 9 ] && ok "A1 missing gh exits 9" || bad "A1 expected exit 9, got $RC — out: $OUT"
printf '%s\n' "$OUT" | grep -qi 'gh is not available' \
  && ok "A1 names the missing gh dependency" || bad "A1 no explanatory gh line — out: $OUT"
if printf '%s\n' "$OUT" | grep -q 'gh pr view failed'; then
  bad "A1 still reported the transient PR-level error line"
else
  ok "A1 did not fall through to the transient 'gh pr view failed' line"
fi

# ---- A2: gh absent from PATH, scan mode — one gate line, once per run ----
OUT=$(PATH="$NOGH" "$PRWATCH" "$REPO" scan 2>&1); RC=$?
[ "$RC" -eq 9 ] && ok "A2 missing gh exits 9 in scan mode" || bad "A2 expected exit 9, got $RC — out: $OUT"
N=$(printf '%s\n' "$OUT" | grep -c 'gh is not available')
[ "$N" -eq 1 ] && ok "A2 gate line printed exactly once (not per candidate)" \
  || bad "A2 gate line printed $N times (expected 1) — out: $OUT"

# ---- B1: gh present, auth fails, App mode OFF -> fatal ----
OUT=$(PATH="$BIN:$NOGH" GH_AUTH_RC=1 "$PRWATCH" "$REPO" 42 2>&1); RC=$?
[ "$RC" -eq 9 ] && ok "B1 unauthenticated gh exits 9" || bad "B1 expected exit 9, got $RC — out: $OUT"
printf '%s\n' "$OUT" | grep -q 'gh auth login' \
  && ok "B1 names the auth fix command" || bad "B1 missing 'gh auth login' hint — out: $OUT"

# ---- B2: gh present, auth fails, App mode ON -> not fatal ----
PEM="$WORK/app.pem"; printf 'not-a-real-key\n' > "$PEM"; chmod 600 "$PEM"
OUT=$(PATH="$BIN:$NOGH" GH_AUTH_RC=1 \
  RUN_ISSUES_GITHUB_APP_ID=1 \
  RUN_ISSUES_GITHUB_APP_INSTALLATION_ID=2 \
  RUN_ISSUES_GITHUB_APP_PRIVATE_KEY_PATH="$PEM" \
  "$PRWATCH" "$REPO" 42 2>&1); RC=$?
[ "$RC" -ne 9 ] && ok "B2 App mode does not make a missing personal login fatal" \
  || bad "B2 App mode still exited 9 — out: $OUT"
printf '%s\n' "$OUT" | grep -qi 'WARNING' \
  && ok "B2 the missing login is reported as a warning" || bad "B2 no warning line — out: $OUT"

# ---- C: gh present + authenticated, but `gh pr view` fails with a reason ----
# The reason must reach the log (P3 no longer swallows gh_route's stderr), and
# the classification stays a transient exit 4 — the gate did not change it.
MARK="stub-gh-pr-view-boom-$$"
OUT=$(PATH="$BIN:$NOGH" GH_PRVIEW_RC=1 GH_PRVIEW_ERR="$MARK" "$PRWATCH" "$REPO" 42 2>&1); RC=$?
[ "$RC" -eq 4 ] && ok "C a failing gh pr view stays a transient exit 4" \
  || bad "C expected exit 4, got $RC — out: $OUT"
printf '%s\n' "$OUT" | grep -qF "$MARK" \
  && ok "C the gh pr view failure reason reached the log" \
  || bad "C the failure reason was swallowed — out: $OUT"

# ---- D: gh present + authenticated + mergeable PR -> gate transparent ----
# A completed run on a FOREIGN host: the merge proceeds but local cleanup is
# skipped (rc 0). This proves the gate passed and did not alter normal behaviour.
RID="20260521-1200-issue-77"
RD="$REPO/.claude/run-issues/$RID"
# shellcheck source=../lib/state.sh
. "$STATE_LIB"
state_init "$RD" "$RID" "$REPO" "77"
state_set "$RD" "pr_url" "https://github.com/Silon-Oy/dotfiles/pull/777"
tmp=$(mktemp); jq '.host = "some-other-host"' "$RD/run.json" > "$tmp"; mv "$tmp" "$RD/run.json"
state_finalize "$RD" "completed"

OUT=$(PATH="$BIN:$NOGH" "$PRWATCH" "$REPO" 777 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "D a healthy gh merges normally (rc 0)" || bad "D expected exit 0, got $RC — out: $OUT"
if printf '%s\n' "$OUT" | grep -qE 'gh is not available|gh is not authenticated|exit 9'; then
  bad "D the gate fired on a healthy environment — out: $OUT"
else
  ok "D the gate was transparent on a healthy environment"
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "pr-watch-gh-gate: all passed" || echo "pr-watch-gh-gate: FAILURES"
[ "$FAIL" -eq 0 ]
