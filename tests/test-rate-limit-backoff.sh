#!/usr/bin/env bash
# test-rate-limit-backoff.sh — GitHub rate-limit detection and backoff (#126).
#
# Two halves:
#   A  lib/rate-limit.sh in isolation — matching, the ladder, the state file.
#   B  poller.sh end to end against a stubbed gh that rejects, proving the tick
#      ABORTS instead of asking the remaining repos, and that the next tick makes
#      no call at all.
#
# Part B matters more than it looks. The failure this issue fixes was not "a call
# failed" but "the call kept being repeated": 1754 identical stderr lines over ten
# hours, each rejection feeding the limit that produced it. So the assertions are
# about CALL COUNTS, not about log wording.
#
# Isolation follows tests/test-poller-portability.sh: fake HOME under $WORK (with
# a hard refusal otherwise), env -i, gh and tmux stubbed at the front of PATH.
#
# Run: bash tests/test-rate-limit-backoff.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

for req in jq git; do
  command -v "$req" >/dev/null 2>&1 || { echo "SKIP: $req not installed"; exit 0; }
done

WORK=$(mktemp -d -t rate-limit.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAIL=1; }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1 — got '$2', want '$3'"; }

# ============================ A: lib/rate-limit.sh ==========================
# shellcheck source=lib/rate-limit.sh
. "$ROOT/lib/rate-limit.sh"

# A1 — recognised rejections. These are the exact phrases GitHub returns; the
# first is the one measured during the 2026-08-28 outage.
for msg in \
  "GraphQL: API rate limit already exceeded for user ID 71727355." \
  "You have exceeded a secondary rate limit. Please wait a few minutes." \
  "You have triggered an abuse detection mechanism." \
  "HTTP 403: API rate limit exceeded for 1.2.3.4"
do
  rate_limit_matches "$msg" && ok "matches: ${msg:0:42}…" || bad "did NOT match: $msg"
done

# A2 — ordinary failures must NOT match. A false positive idles the whole factory,
# so this half of the predicate is the load-bearing one.
for msg in \
  "GraphQL: Could not resolve to an Issue with the number 999." \
  "gh: Validation Failed (HTTP 422)" \
  "fatal: repository not found" \
  "" \
  "limit 200 reached"
do
  rate_limit_matches "$msg" && bad "false positive on: '$msg'" || ok "no match: '${msg:0:36}'"
done

# A3 — file form
ERRF="$WORK/err.txt"
rate_limit_file_matches "$WORK/does-not-exist" && bad "missing file matched" || ok "missing file does not match"
: > "$ERRF"
rate_limit_file_matches "$ERRF" && bad "empty file matched" || ok "empty file does not match"
echo "GraphQL: API rate limit already exceeded" > "$ERRF"
rate_limit_file_matches "$ERRF" && ok "file with rejection matches" || bad "file with rejection did not match"

# A4 — state file: corrupt and missing degrade to "no backoff", never to a block.
SF="$WORK/state"
rm -f "$SF"
rate_limit_active "$SF" 1000 && bad "missing state file blocked" || ok "missing state file does not block"
printf 'garbage\n' > "$SF"
rate_limit_active "$SF" 1000 && bad "corrupt state file blocked" || ok "corrupt state file does not block"

# A5 — the ladder: 300 → 600 → 1200 → 2400 → 3600, then capped.
rm -f "$SF"
for want in 300 600 1200 2400 3600 3600; do
  got="$(rate_limit_trip "$SF" 1000)"
  check "ladder rung -> ${want}s" "${got##* }" "$want"
done

# A6 — an active deadline blocks; an expired one does not.
rm -f "$SF"; rate_limit_trip "$SF" 1000 >/dev/null      # deadline = 1300
rate_limit_active "$SF" 1200 && ok "future deadline blocks" || bad "future deadline did not block"
rate_limit_active "$SF" 1400 && bad "expired deadline blocked" || ok "expired deadline does not block"
check "deadline exported for the caller to log" "$RATE_LIMIT_DEADLINE" "1300"

# A7 — kill switch. Same reason RUN_ISSUES_SKIP_PREFLIGHT exists: a new gate must
# never be the reason a healthy machine will not run.
RUN_ISSUES_RATE_LIMIT_BACKOFF=0 rate_limit_active "$SF" 1200 \
  && bad "kill switch did not disable the gate" || ok "kill switch disables the gate"
RUN_ISSUES_RATE_LIMIT_BACKOFF=0 rate_limit_trip "$SF" 1200 >/dev/null \
  && bad "kill switch did not disable trip" || ok "kill switch disables trip"

# A8 — clear, and the JSON the runner object folds in.
rate_limit_clear "$SF"
[ -f "$SF" ] && bad "clear left the state file behind" || ok "clear removes the state file"
check "status json when healthy" \
  "$(rate_limit_status_json "$SF" 1000)" \
  '{"rate_limited_until":null,"rate_limit_backoff_seconds":null}'
rate_limit_trip "$SF" 1000 >/dev/null
check "status json while backing off" \
  "$(rate_limit_status_json "$SF" 1100)" \
  '{"rate_limited_until":1300,"rate_limit_backoff_seconds":200}'
# A stale file from a past outage must not make a healthy runner look throttled.
check "status json after the deadline passed" \
  "$(rate_limit_status_json "$SF" 9999)" \
  '{"rate_limited_until":null,"rate_limit_backoff_seconds":null}'

# ============================ B: poller.sh end to end =======================
BIN="$WORK/bin"; mkdir -p "$BIN" "$WORK/tmp" "$WORK/git-home"
GH_LOG="$WORK/gh.log"
GH_MODE="$WORK/gh-mode"      # "reject" or "ok"
printf 'ok' > "$GH_MODE"

cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
echo "gh \$*" >> "$GH_LOG"
if [ "\$(cat "$GH_MODE")" = "reject" ]; then
  echo "GraphQL: API rate limit already exceeded for user ID 71727355." >&2
  exit 1
fi
exit 0
SH
cat > "$BIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in ls|list-sessions|has-session) exit 1 ;; *) exit 0 ;; esac
SH
chmod +x "$BIN/gh" "$BIN/tmux"

mk_repo() {
  mkdir -p "$1"
  HOME="$WORK/git-home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    git -C "$1" init -q >/dev/null 2>&1
  HOME="$WORK/git-home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    git -C "$1" remote add origin "git@github.com:example-org/repo$2.git" >/dev/null 2>&1
}
mk_repo "$WORK/repo1" 1
mk_repo "$WORK/repo2" 2
mk_repo "$WORK/repo3" 3

WL="$WORK/wl.json"
cat > "$WL" <<JSON
{ "default_labels": ["auto-run"], "global_max_concurrent": 2,
  "repos": [ { "path": "$WORK/repo1", "labels": ["auto-run"], "remotes": ["origin"] },
             { "path": "$WORK/repo2", "labels": ["auto-run"], "remotes": ["origin"] },
             { "path": "$WORK/repo3", "labels": ["auto-run"], "remotes": ["origin"] } ] }
JSON

PHOME="$WORK/home"; mkdir -p "$PHOME"
PLOGS="$WORK/logs"
STATE="$PLOGS/.rate-limit-backoff"

run_poller() {  # [VAR=value ...]
  case "$PHOME" in "$WORK"/*) ;; *) bad "SAFETY: HOME outside \$WORK"; return 99 ;; esac
  : > "$GH_LOG"
  env -i PATH="$BIN:$PATH" HOME="$PHOME" TMPDIR="$WORK/tmp" \
    RUN_ISSUES_LOCK_ROOT="$WORK/locks" \
    RUN_ISSUES_POLLER_HOSTS='*' \
    RUN_ISSUES_LOG_DIR="$PLOGS" \
    RUN_ISSUES_WATCHLIST="$WL" \
    "$@" \
    bash "$ROOT/poller.sh"
}
# grep -c prints a count AND exits 1 when that count is 0, so the fallback must
# live OUTSIDE the substitution — inside, it would append a second "0" to grep's
# own and yield "0\n0". Same trap poller.sh documents for its ACTIVE counter.
gh_calls() {
  local n
  n=$(grep -c . "$GH_LOG" 2>/dev/null) || n=0
  printf '%s' "${n:-0}"
}

# B1 — a rejection aborts the sweep. Three repos in the watchlist; the first one's
# listing is rejected, so the other two must not be asked at all. This is THE
# regression guard: without it the tick fires 3x and each rejection extends the
# block.
rm -rf "$PLOGS"; printf 'reject' > "$GH_MODE"
run_poller >/dev/null 2>&1
CALLS_AFTER_REJECT=$(gh_calls)
[ "$CALLS_AFTER_REJECT" -le 2 ] \
  && ok "rejection aborts the sweep ($CALLS_AFTER_REJECT gh call(s), not one per repo)" \
  || bad "sweep continued after rejection ($CALLS_AFTER_REJECT gh calls for 3 repos)"
[ -f "$STATE" ] && ok "backoff state written on rejection" || bad "no backoff state written"

# B2 — the NEXT tick makes no call at all while the deadline stands.
run_poller >/dev/null 2>&1
check "tick during backoff makes zero gh calls" "$(gh_calls)" "0"
grep -q "skipping tick until" "$PLOGS/run-issues-poller.log" \
  && ok "skipped tick is logged once" || bad "skipped tick not logged"
SKIP_LINES=$(grep -c "skipping tick until" "$PLOGS/run-issues-poller.log" 2>/dev/null) || SKIP_LINES=0
check "one log line per skipped tick, not per call" "$SKIP_LINES" "1"

# B3 — kill switch overrides an active deadline.
run_poller RUN_ISSUES_RATE_LIMIT_BACKOFF=0 >/dev/null 2>&1
[ "$(gh_calls)" -gt 0 ] && ok "kill switch bypasses the gate" || bad "kill switch did not bypass the gate"

# B4 — an expired deadline lets the tick through, and a clean tick forgets the
# ladder so the next outage starts from the first rung.
printf 'ok' > "$GH_MODE"
printf '1 0\n' > "$STATE"          # deadline far in the past
run_poller >/dev/null 2>&1
[ "$(gh_calls)" -gt 0 ] && ok "expired deadline lets the tick run" || bad "expired deadline still blocked"
[ -f "$STATE" ] && bad "clean tick left the backoff state behind" || ok "clean tick clears the backoff"

# B5 — a corrupt state file must not wedge the poller shut.
printf 'not-a-deadline\n' > "$STATE"
run_poller >/dev/null 2>&1
[ "$(gh_calls)" -gt 0 ] && ok "corrupt state file does not block the tick" || bad "corrupt state file blocked the tick"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "rate-limit-backoff: all passed" || echo "rate-limit-backoff: FAILURES"
[ "$FAIL" -eq 0 ]
