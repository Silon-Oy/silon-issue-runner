#!/usr/bin/env bash
# test-watchlist-example.sh — examples/run-issues-watchlist.example.json is the
# only documentation of the watchlist schema that poller.sh and
# pr-watch-poller.sh actually consume. Two invariants are guarded:
#
#   a) the example matches the keys the pollers read (poller.sh reads
#      .global_max_concurrent, .default_labels, .repos[].path/.labels/.remotes)
#   b) the example leaks nothing: every repo path is a <placeholder> and no
#      path resolves to a real directory on this machine
#
# Cases:
#   1. Valid JSON
#   2. Top-level keys are exactly the documented set
#   3. Types match what the pollers' jq filters expect
#   4. At least one repo documents the multi-remote form (>= 2 remotes)
#   5. No leaked paths: every .repos[].path contains '<' and does not exist
#
# Run: bash tests/test-watchlist-example.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not in PATH"; exit 0; }

ROOT="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$ROOT" ]; then
  echo "SKIP: not inside a git work tree"
  exit 0
fi

EX="$ROOT/examples/run-issues-watchlist.example.json"
FAIL=0

if [ ! -f "$EX" ]; then
  echo "FAIL: example watchlist missing at $EX"
  echo "----------------------------------------"
  echo "watchlist-example: FAILURES"
  exit 1
fi

# ---- Case 1: valid JSON ----
if jq -e . "$EX" >/dev/null 2>&1; then
  echo "PASS: example is valid JSON"
else
  echo "FAIL: example is not valid JSON"
  echo "----------------------------------------"
  echo "watchlist-example: FAILURES"
  exit 1
fi

# ---- Case 2: top-level keys are exactly the documented set ----
KEYS=$(jq -r 'keys_unsorted | sort | join(",")' "$EX")
EXPECTED="_comment,default_labels,global_max_concurrent,repos"
if [ "$KEYS" = "$EXPECTED" ]; then
  echo "PASS: top-level keys are '$EXPECTED'"
else
  echo "FAIL: top-level keys are '$KEYS' (expected '$EXPECTED')"
  FAIL=1
fi

# ---- Case 3: types match the pollers' jq filters ----
if jq -e '
  (._comment | type == "string" and length > 0)
  and (.global_max_concurrent | type == "number")
  and (.default_labels | type == "array" and length > 0
        and all(.[]; type == "string" and length > 0))
  and (.repos | type == "array" and length > 0)
  and (.repos | all(
        (.path | type == "string" and length > 0)
        and (.labels  | type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
        and (.remotes | type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
      ))
' "$EX" >/dev/null; then
  echo "PASS: schema types match the pollers' readers"
else
  echo "FAIL: schema types do not match the pollers' readers"
  FAIL=1
fi

# ---- Case 4: multi-remote form documented ----
if jq -e '[.repos[] | select((.remotes | length) >= 2)] | length >= 1' "$EX" >/dev/null; then
  echo "PASS: at least one repo documents the multi-remote form"
else
  echo "FAIL: no repo entry documents >= 2 remotes"
  FAIL=1
fi

# ---- Case 5: no leaked paths ----
while IFS= read -r p; do
  [ -n "$p" ] || continue
  case "$p" in
    *'<'*) echo "PASS: path is a placeholder: $p" ;;
    *)     echo "FAIL: path is not a placeholder (possible leak): $p"; FAIL=1 ;;
  esac
  if [ -e "$p" ]; then
    echo "FAIL: path exists on this machine (real path leaked): $p"
    FAIL=1
  fi
done < <(jq -r '.repos[].path' "$EX")

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "watchlist-example: all passed" || echo "watchlist-example: FAILURES"
[ "$FAIL" -eq 0 ]
