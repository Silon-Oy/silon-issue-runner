#!/usr/bin/env bash
# test-issue-pick.sh — pick_oldest_candidate multi-label search syntax.
#
# Verifies that pick_oldest_candidate (lib/issue.sh) encodes a labels-CSV as
# separate `label:"x"` terms — which gh ANDs — keeps the standing
# -is:blocked/-label:waiting/-label:wip + is:open/-label:auto-claimed/sort filters,
# and treats an empty gh result as "no candidate" (empty stdout, rc 0).
#
# Issue #99 removed `no:assignee` from the pickup search and replaced the
# reservation with `-label:auto-claimed`: a hand-assigned issue is now a valid
# candidate, and only the automation-owned auto-claimed label removes an in-flight
# or un-cleaned run from pickup. The `-label:auto-claimed` term is pinned exactly,
# for the same fail-open reason as `-is:blocked`: a typo'd negative qualifier does
# NOT error on GitHub — it silently matches everything.
#
# WHY THE -is:blocked TERM IS PINNED EXACTLY, AND WHY THE TWO PICKUP SEARCHES
# ARE ASSERTED CONGRUENT:
#   Blocked issues are excluded with GitHub's native `-is:blocked` qualifier
#   (reads the blocked_by graph), replacing the old blocked-label filter and its
#   label-sync script. An UNKNOWN negative qualifier does NOT error on GitHub —
#   it silently matches everything (measured: `-is:totallynotreal` returned all
#   open issues). So a typo like `-is:blockd` would not fail; it would quietly
#   leak blocked issues into pickup. The old label-based bug failed safe (picked
#   too few, noticed at once); this one fails open, so the lost safety margin is
#   bought back here: we pin the literal `-is:blocked` string AND assert
#   lib/issue.sh's and poller.sh's pickup searches carry the same standing
#   filters, so the two sources can't drift apart unnoticed.
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
ARGV="$WORK/argv.txt"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
# Record argv for assertions: the joined form (for --search matching) and the
# per-element form (so a word-split bug that collapses "--repo owner/repo" into
# a single argv entry is detectable — \$* would hide it behind a space).
printf '%s\n' "\$*" >> "$CAPTURE"
: > "$ARGV"
for a in "\$@"; do printf '%s\n' "\$a" >> "$ARGV"; done
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
out=$(pick_oldest_candidate "$REPO" "auto-run,enhancement")
[ "$out" = "12" ] || fail "multi-label: expected 12, got [$out]"

last_search() { tail -n1 "$CAPTURE"; }
s=$(last_search)
case "$s" in
  *'label:"auto-run"'*'label:"enhancement"'*) : ;;
  *) fail "search missing separate label terms: $s" ;;
esac

# --- 2. standing filters always present ----------------------------------
for term in 'is:open' '-label:auto-claimed' '-is:blocked' '-label:waiting' '-label:wip' '-label:epic' '-label:auto-clean' 'sort:created-asc'; do
  case "$s" in
    *"$term"*) : ;;
    *) fail "search missing standing filter '$term': $s" ;;
  esac
done

# --- 2a. blocked exclusion uses the exact native -is:blocked qualifier ----
# A typo in the negative qualifier (e.g. -is:blockd) does not error on GitHub;
# it silently matches everything, leaking blocked issues into pickup. The
# standing-filter loop above already fails if `-is:blocked` is absent (a
# regression to the old label form would drop it); this pins the exact spelling
# so a near-miss typo is caught too.
case "$s" in
  *'-is:blocked'*) : ;;
  *) fail "search missing exact '-is:blocked': $s" ;;
esac

# --- 2b. epic issues are excluded from pickup (issue #81) ------------------
# An epic collects runnable sub-issues but is never itself runnable; running it
# would launch the implementer against an aggregating body. -label:epic keeps it
# out of pickup (orchestrate.sh re-checks authoritatively via is_epic after the
# lock, mirroring the -is:blocked / S2b pattern). Pinned exactly here for the
# same fail-open reason as -is:blocked: a typo would silently leak epics.
case "$s" in
  *'-label:epic'*) : ;;
  *) fail "search missing exact '-label:epic': $s" ;;
esac

# --- 2c. reservation is -label:auto-claimed, and no:assignee is GONE (#99) -
# The reservation moved from assignment to the automation-owned auto-claimed
# label. Pin the exact negative qualifier (a typo fails open, like -is:blocked)
# and assert `no:assignee` is no longer part of the search — a hand-assigned issue
# must now be a valid candidate.
case "$s" in
  *'-label:auto-claimed'*) : ;;
  *) fail "search missing exact '-label:auto-claimed': $s" ;;
esac
case "$s" in
  *'no:assignee'*) fail "search still carries 'no:assignee' — issue #99 removed it: $s" ;;
  *) : ;;
esac

# --- 3. empty labels CSV → no label: term added --------------------------
out=$(pick_oldest_candidate "$REPO" "")
s=$(last_search)
case "$s" in
  *'label:"'*) fail "empty CSV should add no label: term, got: $s" ;;
  *) : ;;
esac
[ "$out" = "11" ] || fail "empty CSV: expected 11 from mock, got [$out]"

# --- 4. zero-match → empty stdout, rc 0 ----------------------------------
set +e
out=$(pick_oldest_candidate "$REPO" "auto-run,documentation"); rc=$?
set -e
[ "$rc" = "0" ] || fail "zero-match: expected rc 0, got $rc"
[ -z "$out" ]   || fail "zero-match: expected empty stdout, got [$out]"

# --- 5. owner/repo arg is NOT collapsed by the label loop's IFS=',' -------
# Regression for the IFS leak: pick_oldest_candidate sets IFS=',' to split the
# labels CSV. If that IFS leaks into the `$(_repo_args "$owner_repo")` word-split
# below, "--repo owner/repo" stays a single argv entry → gh sees an unknown flag
# and pickup silently returns nothing for every non-empty owner/repo (every
# non-origin remote, and origin clones whose URL resolves). We pass BOTH a
# multi-label CSV (forces IFS=',') AND an owner/repo, then assert gh received
# "--repo" and "customer-d-oy/rahti" as two distinct argv entries.
out=$(pick_oldest_candidate "$REPO" "auto-run,enhancement" "customer-d-oy/rahti")
[ "$out" = "12" ] || fail "owner/repo split: expected 12, got [$out]"
grep -qxF -- '--repo' "$ARGV"        || fail "owner/repo split: '--repo' not a standalone argv entry"
grep -qxF -- 'customer-d-oy/rahti' "$ARGV" || fail "owner/repo split: 'customer-d-oy/rahti' not a standalone argv entry"
if grep -qxF -- '--repo customer-d-oy/rahti' "$ARGV"; then
  fail "owner/repo split: IFS=',' leaked — '--repo customer-d-oy/rahti' collapsed into one argv entry"
fi

# --- 5a. poller.sh no longer has its OWN pickup search (issue #99) ---------
# There used to be two parallel pickup searches — pick_oldest_candidate
# (lib/issue.sh) and the poller's inline `gh issue list --search` — that had to be
# asserted congruent. Issue #99 converged them: the poller now DELEGATES to
# pick_oldest_candidate, so there is exactly one query and no drift is possible
# (the #91 pattern, applied to pickup). This case guards that convergence: if a
# future edit reintroduces an inline `gh issue list --search` pickup in poller.sh,
# the two-search hazard is back and this fails.
POLLER_SH="$HERE/../poller.sh"
if grep -qE 'gh issue list.*--search' "$POLLER_SH"; then
  fail "poller.sh reintroduced an inline 'gh issue list --search' pickup — it must delegate to pick_oldest_candidate (issue #99)"
fi
if ! grep -q 'pick_oldest_candidate' "$POLLER_SH"; then
  fail "poller.sh no longer calls pick_oldest_candidate — the single pickup search was lost"
fi

# --- 6. optional live AND/OR probe (skipped by default) ------------------
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
