#!/usr/bin/env bash
# test-drain-queue.sh — drain-queue.sh is the window-model sibling of poller.sh.
# Both must pick up the SAME issues on a given host, so the thing worth guarding
# is that the drain resolves repos and pickup labels from the watchlist through
# the same resolver the poller uses — not a second list that can drift.
#
# pick_oldest_candidate is stubbed (it queries GitHub); lib/poller-config.sh is
# the real one, so label resolution is genuinely exercised.
#
# Cases:
#   1. No arguments: every watchlist repo is drained, each under ITS OWN labels
#   2. RUN_ISSUES_LABELS_CSV overrides every repo in the run
#   3. A repo not in the watchlist falls back to the built-in default label
#   4. No arguments and no watchlist: refuses rather than draining nothing
#   5. Shipped files name no project, person or host — this package is generic
#
# Run: bash tests/test-drain-queue.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
DRAIN="$PKG/drain-queue.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not in PATH"; exit 0; }
[ -x "$DRAIN" ] || { echo "FAIL: drain-queue.sh missing or not executable"; exit 1; }

fails=0
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A fake package root: real poller-config.sh, stubbed issue.sh and orchestrator.
FAKE="$TMP/runner"
mkdir -p "$FAKE/lib"
cp "$PKG/lib/poller-config.sh" "$FAKE/lib/poller-config.sh"
cp "$PKG/lib/jq-binary.sh"     "$FAKE/lib/jq-binary.sh"
cat > "$FAKE/lib/issue.sh" <<'STUB'
pick_oldest_candidate() { printf ''; }   # queue always empty: no orchestrator call
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/orchestrate.sh"
chmod +x "$FAKE/orchestrate.sh"

mkdir -p "$TMP/repo-a" "$TMP/repo-b" "$TMP/repo-outside"
WL="$TMP/watchlist.json"
jq -n --arg a "$TMP/repo-a" --arg b "$TMP/repo-b" '{
  default_labels: ["fallback-label"],
  global_max_concurrent: 1,
  repos: [
    { path: $a, labels: ["label-a"], remotes: ["origin"] },
    { path: $b, labels: ["label-b"], remotes: ["origin"] }
  ]
}' > "$WL"

run_drain() {
  RUNNER_DIR="$FAKE" RUN_ISSUES_WATCHLIST="$WL" "$DRAIN" "$@" 2>&1
}

# --- 1. no args: both watchlist repos, each under its own labels -------------
out=$(run_drain)
if grep -q "draining $TMP/repo-a (labels: label-a)" <<<"$out" \
   && grep -q "draining $TMP/repo-b (labels: label-b)" <<<"$out"; then
  ok "no args drains every watchlist repo under its own labels"
else
  bad "no args did not drain both repos with per-repo labels"
  printf '%s\n' "$out" | sed 's/^/       /'
fi

# --- 2. env override wins for every repo ------------------------------------
out=$(RUN_ISSUES_LABELS_CSV=override-label run_drain)
if grep -q "draining $TMP/repo-a (labels: override-label)" <<<"$out" \
   && grep -q "draining $TMP/repo-b (labels: override-label)" <<<"$out"; then
  ok "RUN_ISSUES_LABELS_CSV overrides every repo"
else
  bad "env override did not apply to every repo"
fi

# --- 3. repo outside the watchlist falls back to the built-in default --------
out=$(run_drain "$TMP/repo-outside")
if grep -q "draining $TMP/repo-outside (labels: auto-run)" <<<"$out"; then
  ok "uncovered repo falls back to the built-in pickup label"
else
  bad "uncovered repo did not fall back to auto-run"
  printf '%s\n' "$out" | sed 's/^/       /'
fi

# --- 4. no args and no watchlist: refuse ------------------------------------
out=$(RUNNER_DIR="$FAKE" RUN_ISSUES_WATCHLIST="$TMP/does-not-exist.json" "$DRAIN" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && grep -qi "no repos" <<<"$out"; then
  ok "refuses when there is nothing to drain"
else
  bad "expected a refusal with no repos and no watchlist (rc=$rc)"
fi

# --- 5. the shipped files are generic ---------------------------------------
# A package that names one operator's projects cannot be handed to the next
# person setting up a runner — which is exactly how this script reached the
# package in the first place.
leaks=0
for f in "$PKG/drain-queue.sh" "$PKG/examples/wake-run.example.sh"; do
  [ -f "$f" ] || { bad "missing shipped file: $f"; continue; }
  if hit=$(grep -nEi 'customer-a|putkiwelho|customer-d|/Users/[a-z]|/home/[a-z]' "$f"); then
    bad "project/host name in $(basename "$f"):"
    printf '%s\n' "$hit" | sed 's/^/       /'
    leaks=1
  fi
done
[ "$leaks" -eq 0 ] && ok "shipped files name no project or host"

if [ "$fails" -eq 0 ]; then
  echo "PASS: test-drain-queue.sh"
  exit 0
fi
echo "FAIL: test-drain-queue.sh ($fails)"
exit 1
