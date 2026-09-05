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
#   6. The optional per-repo `assignees` list reaches the pickup call, and an
#      entry without the key passes nothing — the drain must not narrow pickup
#      in a repo that never opted in
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
# Queue always empty, so no orchestrator is ever launched. The arguments are
# recorded so case 6 can assert what the drain actually asked for rather than
# inferring it from a log line.
pick_oldest_candidate() {
  # One bracketed field per argument: an empty argument has to be visible, and
  # `$*` would collapse three empty trailing ones into whitespace.
  [ -n "${DRAIN_TEST_PICK_ARGS:-}" ] && { printf '[%s]' "$@"; printf '\n'; } >> "$DRAIN_TEST_PICK_ARGS"
  printf ''
}
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/orchestrate.sh"
chmod +x "$FAKE/orchestrate.sh"

mkdir -p "$TMP/repo-a" "$TMP/repo-b" "$TMP/repo-c" "$TMP/repo-outside"
WL="$TMP/watchlist.json"
# Written by bash, NOT by `jq --arg`. Under Git Bash jq is a native Windows
# program and MSYS rewrites a POSIX path on its way into argv, so `--arg a
# /tmp/x` stores C:/Users/.../Temp/x in the watchlist while this test still
# greps for /tmp/x — the drain looked broken on windows-latest when it was
# doing exactly the right thing. jq's OUTPUT is not rewritten, so a path bash
# puts in the file comes back out of the drain unchanged. Same trap that
# lib/poller-config.sh documents at length.
cat > "$WL" <<JSON
{
  "default_labels": ["fallback-label"],
  "global_max_concurrent": 1,
  "repos": [
    { "path": "$TMP/repo-a", "labels": ["label-a"], "remotes": ["origin"] },
    { "path": "$TMP/repo-b", "labels": ["label-b"], "remotes": ["origin"] },
    { "path": "$TMP/repo-c", "labels": ["label-c"], "assignees": ["runner-a"], "remotes": ["origin"] }
  ]
}
JSON

run_drain() {
  RUNNER_DIR="$FAKE" RUN_ISSUES_WATCHLIST="$WL" "$DRAIN" "$@" 2>&1
}

# --- 1. no args: both watchlist repos, each under its own labels -------------
out=$(run_drain)
if grep -q "draining $TMP/repo-a (labels: label-a)" <<<"$out" \
   && grep -q "draining $TMP/repo-b (labels: label-b)" <<<"$out" \
   && grep -q "draining $TMP/repo-c (labels: label-c, assignees: runner-a)" <<<"$out"; then
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

# --- 6. the assignee allow-list reaches the pickup call ---------------------
# Argument 5 of pick_oldest_candidate. Asserting the argument rather than the
# log line is the point: the log is cosmetic, the argument is what decides
# which issues this host takes.
PICKARGS="$TMP/pick-args.txt"
: > "$PICKARGS"
DRAIN_TEST_PICK_ARGS="$PICKARGS" run_drain >/dev/null
if grep -qxF "[$TMP/repo-c][label-c][][][runner-a]" "$PICKARGS"; then
  ok "a repo with an assignees list passes it to the pickup call"
else
  bad "the assignees list did not reach pick_oldest_candidate"
  sed 's/^/       /' "$PICKARGS"
fi
# The repos that did not opt in must pass an EMPTY list. An allow-list invented
# for them would narrow pickup in a repo nobody configured, and the narrowing
# would be invisible: no error, no log line, just issues that stop running.
if grep -qxF "[$TMP/repo-a][label-a][][][]" "$PICKARGS"; then
  ok "a repo without the key passes an empty assignee list"
else
  bad "a repo without an assignees key did not pass an empty list"
  sed 's/^/       /' "$PICKARGS"
fi
# An uncovered repo is the same case, reached by a different route.
: > "$PICKARGS"
DRAIN_TEST_PICK_ARGS="$PICKARGS" run_drain "$TMP/repo-outside" >/dev/null
if grep -qxF "[$TMP/repo-outside][auto-run][][][]" "$PICKARGS"; then
  ok "an uncovered repo passes an empty assignee list"
else
  bad "an uncovered repo did not pass an empty assignee list"
  sed 's/^/       /' "$PICKARGS"
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
