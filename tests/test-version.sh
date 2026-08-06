#!/usr/bin/env bash
# test-version.sh — lib/version.sh (runner version visibility, issue #32).
#
# Pure functions, so this sources the lib directly and drives it against
# synthetic git repos:
#   * runner_version         — short sha inside a repo, "?" outside one.
#   * runner_behind_origin   — "0" when even with origin/main, N when behind,
#                              "?" when no upstream ref exists.
#   * runner_version_summary — the three human-string shapes.
#   * runner_fetch_throttled — fetches when the stamp is missing/stale, and
#                              SKIPS the fetch when the stamp is fresh (a git
#                              shim records every `fetch` so the throttle is
#                              observable without a network).
#
# Run: bash tests/test-version.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_LIB="$HERE/../lib/version.sh"

if ! command -v git >/dev/null 2>&1; then
  echo "SKIP: git not in PATH"
  exit 0
fi
REAL_GIT="$(command -v git)"

WORK=$(mktemp -d -t version.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=lib/version.sh
. "$VERSION_LIB"

FAIL=0

# --- Build a repo whose HEAD is 2 commits behind origin/main ---------------
REPO="$WORK/repo"
git init -q "$REPO"
(
  cd "$REPO"
  git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m c1
  C1=$(git rev-parse HEAD)
  git commit -q --allow-empty -m c2
  git commit -q --allow-empty -m c3
  # No real remote: synthesize origin/main at c3, then move HEAD back to c1.
  git update-ref refs/remotes/origin/main HEAD
  git reset -q --hard "$C1"
)

# === runner_version ========================================================
VER=$(runner_version "$REPO")
echo "--- runner_version: $VER ---"
printf '%s' "$VER" | grep -Eq '^[0-9a-f]{7,}$' || { echo "FAIL: runner_version not a short sha ('$VER')"; FAIL=1; }

VER_NONGIT=$(runner_version "$WORK")   # $WORK itself is not a git repo
[ "$VER_NONGIT" = "?" ] || { echo "FAIL: runner_version outside a repo != '?' (got '$VER_NONGIT')"; FAIL=1; }

# === runner_behind_origin ==================================================
BEHIND=$(runner_behind_origin "$REPO")
[ "$BEHIND" = "2" ] || { echo "FAIL: runner_behind_origin != 2 (got '$BEHIND')"; FAIL=1; }

# Even with origin/main -> 0.
( cd "$REPO" && git reset -q --hard origin/main )
BEHIND0=$(runner_behind_origin "$REPO")
[ "$BEHIND0" = "0" ] || { echo "FAIL: runner_behind_origin (even) != 0 (got '$BEHIND0')"; FAIL=1; }

# No upstream ref at all -> "?".
NOUP="$WORK/noup"
git init -q "$NOUP"
( cd "$NOUP" && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m only )
BEHIND_Q=$(runner_behind_origin "$NOUP")
[ "$BEHIND_Q" = "?" ] || { echo "FAIL: runner_behind_origin (no upstream) != '?' (got '$BEHIND_Q')"; FAIL=1; }

# Outside a repo -> "?".
BEHIND_NG=$(runner_behind_origin "$WORK")
[ "$BEHIND_NG" = "?" ] || { echo "FAIL: runner_behind_origin (non-git) != '?' (got '$BEHIND_NG')"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS: runner_version + runner_behind_origin (behind/even/none/non-git)"

# === runner_version_summary ================================================
# Rebuild the behind-2 state for the summary.
( cd "$REPO"
  git reset -q --hard 'origin/main~2' )   # HEAD 2 behind again
SUM_BEHIND=$(runner_version_summary "$REPO")
echo "--- summary (behind): $SUM_BEHIND ---"
printf '%s' "$SUM_BEHIND" | grep -q '2 commits behind origin/main' \
  || { echo "FAIL: summary (behind) missing behind clause ('$SUM_BEHIND')"; FAIL=1; }

( cd "$REPO" && git reset -q --hard origin/main )
SUM_EVEN=$(runner_version_summary "$REPO")
printf '%s' "$SUM_EVEN" | grep -q 'up to date' \
  || { echo "FAIL: summary (even) missing 'up to date' ('$SUM_EVEN')"; FAIL=1; }

SUM_Q=$(runner_version_summary "$NOUP")
printf '%s' "$SUM_Q" | grep -q 'behind' && { echo "FAIL: summary (unknown) claims drift ('$SUM_Q')"; FAIL=1; }
printf '%s' "$SUM_Q" | grep -q 'up to date' && { echo "FAIL: summary (unknown) claims up to date ('$SUM_Q')"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS: runner_version_summary (behind / up to date / bare sha)"

# === runner_fetch_throttled ================================================
# A git shim that records every `fetch` and execs real git otherwise, so the
# throttle decision is observable without a network. version.sh's other git
# calls (rev-parse/rev-list) pass straight through.
BIN="$WORK/bin"
mkdir -p "$BIN"
FETCHLOG="$WORK/fetch.log"
cat > "$BIN/git" <<SH
#!/usr/bin/env bash
sub=""
if [ "\$1" = "-C" ]; then sub="\$3"; else sub="\$1"; fi
if [ "\$sub" = "fetch" ]; then echo fetch >> "$FETCHLOG"; exit 0; fi
exec "$REAL_GIT" "\$@"
SH
chmod +x "$BIN/git"

STAMP="$WORK/fetch-stamp"

# (1) Missing stamp -> fetch happens, stamp created.
: > "$FETCHLOG"
PATH="$BIN:$PATH" runner_fetch_throttled "$REPO" "$STAMP" 3600 ""
[ -s "$FETCHLOG" ] || { echo "FAIL: fetch not attempted with missing stamp"; FAIL=1; }
[ -f "$STAMP" ]    || { echo "FAIL: stamp not created after fetch"; FAIL=1; }

# (2) Fresh stamp -> throttled, no fetch.
: > "$FETCHLOG"
: > "$STAMP"   # mtime = now
PATH="$BIN:$PATH" runner_fetch_throttled "$REPO" "$STAMP" 3600 ""
[ -s "$FETCHLOG" ] && { echo "FAIL: fetch attempted despite fresh stamp"; FAIL=1; }

# (3) Stale stamp -> fetch happens again.
: > "$FETCHLOG"
touch -t 202001010000.00 "$STAMP"   # mtime = 2020, far older than interval
PATH="$BIN:$PATH" runner_fetch_throttled "$REPO" "$STAMP" 3600 ""
[ -s "$FETCHLOG" ] || { echo "FAIL: fetch not attempted with stale stamp"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS: runner_fetch_throttled (missing/stale fetch, fresh throttled)"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "version: all passed" || echo "version: FAILURES"
[ "$FAIL" -eq 0 ]
