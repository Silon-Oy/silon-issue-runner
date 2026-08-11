#!/usr/bin/env bash
# test-status-classify.sh — unit tests for lib/status-read.sh:status_classify.
#
# Pure classification logic, no disk / no network. Feeds a fully-enriched run
# object and asserts the "<class> <class_reason> <class_confidence>" triple.
# Mirrors tests/test-pr-watch-decision.sh's shape. Covers both invariants
# (INV-STATUS, INV-UNKNOWN), every verdict->class mapping, the initialized
# priority order, and wedged_session.
#
# Run: bash tests/test-status-classify.sh   (exit 0 = all pass)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/status-read.sh
. "$HERE/../lib/status-read.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed"
  exit 0
fi

PASS=0
FAIL=0

# mk <key=value>... — build a run object. Values are interpreted as JSON when
# they parse as JSON, else as strings. Unspecified fields default to null/false.
mk() {
  local filter='{status:null, current_state:null, session_alive:false, idle_seconds:null, pr_local_verdict:null}'
  local args=() kv k v i=0
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    args+=(--arg "k$i" "$k" --argjson "v$i" "$v")
    filter="$filter | .[\$k$i] = \$v$i"
    i=$((i + 1))
  done
  jq -nc "${args[@]}" "$filter"
}

# assert <name> <expected-triple> <stale> <run-json>
assert() {
  local name="$1" expected="$2" stale="$3" obj="$4" got
  got="$(status_classify "$obj" "$stale")"
  if [ "$got" = "$expected" ]; then
    PASS=$((PASS + 1)); printf 'PASS  %-48s -> %s\n' "$name" "$got"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL  %-48s -> got=[%s] expected=[%s]\n' "$name" "$got" "$expected"
  fi
}

S=3600

# ---- initialized branch: priority order, all reasons reachable ----
assert "init+alive+recent=running/active" "running active_session high" $S \
  "$(mk status='"initialized"' current_state='"S8_Implementer"' session_alive=true idle_seconds=10)"
assert "init+dead+recent=running/recent"  "running recent_progress high" $S \
  "$(mk status='"initialized"' current_state='"S8_Implementer"' session_alive=false idle_seconds=10)"
# wedged_session: session ALIVE but idle > stale => stalled (agrees with poller
# scan_stalled, which kills exactly these).
assert "init+alive+stale=stalled/wedged"  "stalled wedged_session high" $S \
  "$(mk status='"initialized"' current_state='"S8_Implementer"' session_alive=true idle_seconds=99999)"
assert "init+dead+stale=stalled/orphaned" "stalled orphaned high" $S \
  "$(mk status='"initialized"' current_state='"S8_Implementer"' session_alive=false idle_seconds=99999)"
# idle unknown, session dead, not at review gate => orphaned.
assert "init+dead+idlenull=stalled/orphan" "stalled orphaned high" $S \
  "$(mk status='"initialized"' current_state='"S8_Implementer"' session_alive=false idle_seconds=null)"
# review gate + session dead => awaiting_review, even with a stale idle clock.
assert "init+reviewgate+dead=awaiting_rev" "attention awaiting_review high" $S \
  "$(mk status='"initialized"' current_state='"S7_ReviewGate"' session_alive=false idle_seconds=99999)"

# ---- attention (status-based) ----
assert "blocked=attention/blocked" "attention blocked high" $S \
  "$(mk status='"blocked"')"
assert "timed_out=attention/timed_out" "attention timed_out high" $S \
  "$(mk status='"timed_out"')"
assert "pr_conflicted=attention/pr_conf" "attention pr_conflicted high" $S \
  "$(mk status='"pr_conflicted"')"
assert "awaiting_clar=attention/awaiting" "attention awaiting_clarification high" $S \
  "$(mk status='"awaiting_clarification"')"

# ---- INV-STATUS: completed + blocked_reason set must NOT be attention ----
assert "INV-STATUS completed+timeout!=att" "cleanup pr_not_open high" $S \
  "$(mk status='"completed"' blocked_reason='"implementer_timeout"' pr_local_verdict='"SKIP_CLOSED"')"

# ---- completed: every pr verdict -> class ----
assert "SKIP_CLOSED=cleanup/pr_not_open" "cleanup pr_not_open high" $S \
  "$(mk status='"completed"' pr_local_verdict='"SKIP_CLOSED"')"
assert "SKIP_NO_LABEL=attention/unlabelled" "attention pr_unlabelled high" $S \
  "$(mk status='"completed"' pr_local_verdict='"SKIP_NO_LABEL"')"
for v in WAIT_CI WAIT_DIRTY REBASE MERGE FIX_CI SKIP_BLOCKED; do
  assert "$v=pr_in_flight/pr_open_waiting" "pr_in_flight pr_open_waiting high" $S \
    "$(mk status='"completed"' pr_local_verdict="\"$v\"")"
done
# ---- INV-UNKNOWN: completed with no verdict -> pr_in_flight + low, never cleanup ----
assert "INV-UNKNOWN completed+noverdict" "pr_in_flight pr_state_unknown low" $S \
  "$(mk status='"completed"' pr_local_verdict=null)"

# ---- cleanup (terminal race/cancel/merge) ----
assert "lost_race=cleanup/lost_race" "cleanup lost_race high" $S \
  "$(mk status='"lost_race"')"
assert "cancelled=cleanup/cancelled" "cleanup cancelled high" $S \
  "$(mk status='"cancelled"')"
assert "merged=cleanup/pr_not_open" "cleanup pr_not_open high" $S \
  "$(mk status='"merged"')"

# ---- unknown status -> attention/blocked/low (fail-closed catch-all) ----
assert "unknown-status=attention/low" "attention blocked low" $S \
  "$(mk status='"weird_new_status"')"

echo "----------------------------------------"
echo "status-classify: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
