#!/usr/bin/env bash
# test-issue-pick.sh — pick_oldest_unassigned multi-label search syntax.
#
# Verifies that pick_oldest_unassigned (lib/issue.sh) encodes a labels-CSV as
# separate `label:"x"` terms — which gh ANDs — keeps the standing
# -label:blocked/-label:waiting/-label:wip + is:open/no:assignee/sort filters,
# and treats an empty gh result as "no candidate" (empty stdout, rc 0).
#
# Two layers:
#   1. Default (offline, deterministic): `gh` is mocked via a PATH shim that
#      captures the --search argument and emits a controlled issue number, so
#      run-all.sh never touches the network or GitHub auth.
#   2. Optional live probe: set RUN_ISSUES_LIVE_PROBE=1 (and a repo with two
#      auto-run issues differing by a second label) to confirm gh's real
#      AND/OR behaviour. Skipped — never failed — when unset or gh unavailable.
#
# Run: bash tests/test-issue-pick.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISSUE_LIB="$HERE/../lib/issue.sh"

WORK=$(mktemp -d -t issuepick.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
fail() { echo "FAIL $1"; FAIL=1; }

# --- gh mock -------------------------------------------------------------
# Captures the full argv (so we can assert on the --search string) and prints
# an issue number chosen by the requested label combination, mimicking gh's
# AND semantics for `label:"x" label:"y"`. A search that asks for a label no
# fixture issue carries prints nothing → simulates a zero-match (rc 0).
BIN="$WORK/bin"
mkdir -p "$BIN"
CAPTURE="$WORK/capture.txt"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
# Record argv for assertions.
printf '%s\n' "\$*" >> "$CAPTURE"
# Extract the value passed to --search.
search=""
while [ \$# -gt 0 ]; do
  if [ "\$1" = "--search" ]; then search="\$2"; shift 2; continue; fi
  shift
done
# Fixture world: issue 11 has auto-run only; issue 12 has auto-run+enhancement.
# Emulate AND: every requested positive label:"x" must be satisfiable.
emit=""
case "\$search" in
  *'label:"auto-run"'*'label:"enhancement"'*) emit="12" ;;   # both → 12
  *'label:"documentation"'*)                   emit=""   ;;   # nobody has it → none
  *'label:"auto-run"'*)                        emit="11" ;;   # auto-run alone → oldest (11)
  *)                                           emit="11" ;;
esac
[ -n "\$emit" ] && printf '%s\n' "\$emit"
exit 0
SH
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# shellcheck source=../lib/issue.sh
. "$ISSUE_LIB"

REPO="$WORK"  # any dir; gh is mocked so cwd is irrelevant

# --- 1. multi-label CSV → ANDed label:"x" label:"y" terms ----------------
out=$(pick_oldest_unassigned "$REPO" "auto-run,enhancement")
[ "$out" = "12" ] || fail "multi-label: expected 12, got [$out]"

last_search() { tail -n1 "$CAPTURE"; }
s=$(last_search)
case "$s" in
  *'label:"auto-run"'*'label:"enhancement"'*) : ;;
  *) fail "search missing separate label terms: $s" ;;
esac

# --- 2. standing filters always present ----------------------------------
for term in 'is:open' 'no:assignee' '-label:blocked' '-label:waiting' '-label:wip' 'sort:created-asc'; do
  case "$s" in
    *"$term"*) : ;;
    *) fail "search missing standing filter '$term': $s" ;;
  esac
done

# --- 3. empty labels CSV → no label: term added --------------------------
out=$(pick_oldest_unassigned "$REPO" "")
s=$(last_search)
case "$s" in
  *'label:"'*) fail "empty CSV should add no label: term, got: $s" ;;
  *) : ;;
esac
[ "$out" = "11" ] || fail "empty CSV: expected 11 from mock, got [$out]"

# --- 4. zero-match → empty stdout, rc 0 ----------------------------------
set +e
out=$(pick_oldest_unassigned "$REPO" "auto-run,documentation"); rc=$?
set -e
[ "$rc" = "0" ] || fail "zero-match: expected rc 0, got $rc"
[ -z "$out" ]   || fail "zero-match: expected empty stdout, got [$out]"

# --- 5. optional live AND/OR probe (skipped by default) ------------------
if [ "${RUN_ISSUES_LIVE_PROBE:-0}" = "1" ]; then
  echo "--- live probe: RUN_ISSUES_LIVE_PROBE=1 ---"
  # Remove the mock from PATH for the live segment.
  REAL_PATH="${PATH#"$BIN":}"
  if PATH="$REAL_PATH" command -v gh >/dev/null 2>&1 \
     && PATH="$REAL_PATH" gh auth status >/dev/null 2>&1; then
    repo="${RUN_ISSUES_LIVE_REPO:-$PWD}"
    la="${RUN_ISSUES_LIVE_LABEL_A:-auto-run}"
    lb="${RUN_ISSUES_LIVE_LABEL_B:-}"
    if [ -n "$lb" ]; then
      both=$(PATH="$REAL_PATH" gh issue list -R "$repo" --state open \
               --search "label:\"$la\" label:\"$lb\"" --json number --jq 'length')
      only_a=$(PATH="$REAL_PATH" gh issue list -R "$repo" --state open \
               --search "label:\"$la\"" --json number --jq 'length')
      echo "live: both($la,$lb)=$both  only($la)=$only_a"
      # AND ⇒ both ≤ only_a (the conjunction can only narrow the set).
      [ "$both" -le "$only_a" ] || fail "live: AND violated (both=$both > only_a=$only_a)"
    else
      echo "live: SKIP — set RUN_ISSUES_LIVE_LABEL_B to probe AND semantics"
    fi
  else
    echo "live: SKIP — gh unavailable or not authenticated"
  fi
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "issue-pick: all passed" || echo "issue-pick: FAILURES"
[ "$FAIL" -eq 0 ]
