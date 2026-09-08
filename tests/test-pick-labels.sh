#!/usr/bin/env bash
# test-pick-labels.sh — the pickup-label resolution shared by poller.sh and
# /issue-runner:new-epic (lib/poller-config.sh: poller_pick_labels,
# poller_watchlist_pick_labels).
#
# Why this is worth its own test: the label set decides which issues are ever
# picked up, and BOTH failure directions are silent. Too wide a set (empty)
# would sweep every open issue in a repo into the runner; too narrow a set (a
# label nobody carries) yields zero matches forever, with no error and no log
# line. Neither shows up as a failure anywhere — only as behaviour nobody
# ordered.
#
# The chain used to live inline in two places in poller.sh (a jq default and a
# shell fallback). /issue-runner:new-epic needs the same answer to label a new
# epic with a set the poller will actually pick up, so the chain became one
# function and these cases pin it.
#
# Cases:
#   1. The lib parses and defines both functions
#   2. poller_pick_labels: the fallback chain, in order
#   3. poller_pick_labels: whitespace and empty elements in a hand-edited CSV
#   4. poller_pick_labels never returns an empty set
#   5. poller_watchlist_pick_labels: a covered repo (labels, and default_labels)
#   6. poller_watchlist_pick_labels: an uncovered repo prints the built-in
#      default AND reports rc 1, so the caller can say so out loud
#   7. poller_watchlist_pick_labels: missing / unparseable watchlist, no path
#   8. poller.sh resolves its pickup labels through the shared function
#   9. poller_watchlist_pick_assignees: the optional per-repo allow-list
#  10. poller.sh and drain-queue.sh resolve assignees through that one function
#
# Run: bash tests/test-pick-labels.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/lib/poller-config.sh"

if [ ! -f "$LIB" ]; then
  echo "FAIL: lib/poller-config.sh missing"
  exit 1
fi

WORK=$(mktemp -d -t pick-labels.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAIL=1; }

# shellcheck source=lib/poller-config.sh
. "$LIB"
# The lib sets -e for its production callers; a test must collect every failure.
set +e

# ---- Case 1: the lib parses and defines both functions ----
if bash -n "$LIB" 2>"$WORK/syntax.err"; then
  ok "case1 lib/poller-config.sh parses"
else
  bad "case1 lib/poller-config.sh does not parse:"
  sed 's/^/      /' "$WORK/syntax.err"
fi
for fn in poller_pick_labels poller_watchlist_pick_labels poller_watchlist_pick_assignees; do
  if declare -f "$fn" >/dev/null 2>&1; then
    ok "case1 $fn is defined"
  else
    bad "case1 $fn is not defined"
  fi
done

# ---- Case 2-4: poller_pick_labels ----
pick_case() {
  local desc="$1" want="$2" repo="$3" def="$4" got
  got=$(poller_pick_labels "$repo" "$def")
  if [ "$got" = "$want" ]; then
    ok "$desc"
  else
    bad "$desc (got '$got', expected '$want')"
  fi
}

pick_case "case2 the repo entry's labels win"          'x,y'      'x,y'      'auto-run'
pick_case "case2 default_labels are used when the entry has none" 'auto-run,backend' '' 'auto-run,backend'
pick_case "case2 the built-in default is the last resort" 'auto-run' ''       ''
# The chain REPLACES, it does not merge: an entry's labels are ANDed by the
# consumer, so merging in default_labels would narrow pickup behind the
# operator's back.
pick_case "case2 the entry's labels replace rather than extend the defaults" \
                                                        'x'        'x'        'auto-run,backend'

pick_case "case3 surrounding whitespace is trimmed"     'a,b'      ' a , b '  ''
pick_case "case3 empty elements are dropped"            'a,b'      'a,,b,'    ''
pick_case "case3 a whitespace-only entry falls through" 'auto-run' '   '      ''
pick_case "case3 a whitespace-only default falls through" 'auto-run' ''       ' , '

got=$(poller_pick_labels "" "")
if [ -n "$got" ]; then
  ok "case4 the resolved set is never empty"
else
  bad "case4 the resolved set was empty — the pick query would match every open issue"
fi
if [ "$POLLER_PICK_LABELS_DEFAULT" = "auto-run" ]; then
  ok "case4 the built-in default is still auto-run"
else
  bad "case4 the built-in default is '$POLLER_PICK_LABELS_DEFAULT', not auto-run"
fi

# ---- Cases 5-7 need jq: the watchlist reader parses JSON with it ----
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not in PATH — watchlist cases (5-7) skipped"
else
  WL="$WORK/watchlist.json"
  cat > "$WL" <<'JSON'
{
  "default_labels": ["auto-run", "backend"],
  "repos": [
    { "path": "/tmp/repo-a", "labels": ["auto-run", "frontend"] },
    { "path": "/tmp/repo-b/" },
    { "path": "/tmp/repo-c", "labels": [] }
  ]
}
JSON

  wl_case() {
    local desc="$1" want_rc="$2" want="$3" wl="$4" path="$5" got rc
    got=$(poller_watchlist_pick_labels "$wl" "$path"); rc=$?
    if [ "$rc" -eq "$want_rc" ] && [ "$got" = "$want" ]; then
      ok "$desc"
    else
      bad "$desc (rc=$rc/$want_rc, got '$got', expected '$want')"
    fi
  }

  wl_case "case5 a covered repo uses its own labels"        0 'auto-run,frontend' "$WL" '/tmp/repo-a'
  wl_case "case5 a trailing slash still matches the entry"  0 'auto-run,frontend' "$WL" '/tmp/repo-a/'
  wl_case "case5 an entry without labels uses default_labels" 0 'auto-run,backend' "$WL" '/tmp/repo-b'
  wl_case "case5 an entry with an empty labels array uses default_labels" \
                                                            0 'auto-run,backend' "$WL" '/tmp/repo-c'
  # A watchlist entry written with a trailing slash must match the plain path.
  wl_case "case5 an entry's own trailing slash is normalised too" \
                                                            0 'auto-run,backend' "$WL" '/tmp/repo-b/'

  # The whole point of the rc: an uncovered repo must NOT silently inherit the
  # watchlist's default_labels, and the caller must be able to say so.
  wl_case "case6 an uncovered repo gets the built-in default, not default_labels" \
                                                            1 'auto-run' "$WL" '/tmp/repo-unknown'

  BAD="$WORK/broken.json"
  printf '{ not json' > "$BAD"
  wl_case "case7 an unparseable watchlist still yields a working set" 1 'auto-run' "$BAD" '/tmp/repo-a'
  wl_case "case7 a missing watchlist still yields a working set"      1 'auto-run' "$WORK/nope.json" '/tmp/repo-a'
  wl_case "case7 an empty watchlist path still yields a working set"  1 'auto-run' '' '/tmp/repo-a'
  wl_case "case7 an empty repo path still yields a working set"       1 'auto-run' "$WL" ''
fi

# ---- Case 9: poller_watchlist_pick_assignees ----
# The sibling of the lookup above, with the opposite empty-set semantics.
# Empty is a LEGAL answer here and means "do not filter by assignee": an empty
# label set would match every open issue, but an empty allow-list must simply
# leave pickup as it was. So there is no default step, no built-in fallback,
# and the rc carries no information — an uncovered repo and a covered repo
# without the key mean exactly the same thing, and callers under `set -e` must
# be able to assign the result directly.
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not in PATH — assignee cases (9) skipped"
else
  AWL="$WORK/assignees.json"
  cat > "$AWL" <<'JSON'
{
  "default_labels": ["auto-run"],
  "repos": [
    { "path": "/tmp/repo-a", "labels": ["auto-run"], "assignees": ["runner-a", "runner-b"] },
    { "path": "/tmp/repo-b/", "labels": ["auto-run"] },
    { "path": "/tmp/repo-c", "labels": ["auto-run"], "assignees": [] },
    { "path": "/tmp/repo-d", "labels": ["auto-run"], "assignees": [" spaced ", "", "  "] },
    { "path": "/tmp/repo-e", "labels": ["auto-run"], "assignees": ["not:runner-a", " not:runner-b "] }
  ]
}
JSON

  as_case() {
    local desc="$1" want="$2" wl="$3" path="$4" got rc
    got=$(poller_watchlist_pick_assignees "$wl" "$path"); rc=$?
    if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then
      ok "$desc"
    else
      bad "$desc (rc=$rc/0, got '$got', expected '$want')"
    fi
  }

  as_case "case9 a repo with the key gets its own list"        'runner-a,runner-b' "$AWL" '/tmp/repo-a'
  as_case "case9 a trailing slash still matches the entry"     'runner-a,runner-b' "$AWL" '/tmp/repo-a/'
  as_case "case9 no key means no assignee filtering"           ''                   "$AWL" '/tmp/repo-b'
  as_case "case9 an entry's own trailing slash is normalised"  ''                   "$AWL" '/tmp/repo-b/'
  as_case "case9 an empty array means no assignee filtering"   ''                   "$AWL" '/tmp/repo-c'
  as_case "case9 whitespace is trimmed and blanks are dropped" 'spaced'             "$AWL" '/tmp/repo-d'
  # The `not:` negation prefix (issue #246) must survive the resolver verbatim:
  # ALLOW/DENY splitting lives in _pick_filter_jq, so this function stays the one
  # place that never has to know the syntax. Whitespace is still trimmed around
  # the whole entry, but the colon and prefix are carried through.
  as_case "case9 the not: prefix is returned verbatim"         'not:runner-a,not:runner-b' "$AWL" '/tmp/repo-e'
  # An uncovered repo must NOT inherit anything: unlike labels there is no
  # default to inherit, and inventing one would filter a checkout nobody
  # configured.
  as_case "case9 an uncovered repo gets no list"               ''                   "$AWL" '/tmp/repo-unknown'
  as_case "case9 an unparseable watchlist yields no list"      ''                   "$BAD" '/tmp/repo-a'
  as_case "case9 a missing watchlist yields no list"           ''                   "$WORK/nope.json" '/tmp/repo-a'
  as_case "case9 an empty watchlist path yields no list"       ''                   '' '/tmp/repo-a'
  as_case "case9 an empty repo path yields no list"            ''                   "$AWL" ''

  # The labels lookup must be untouched by a watchlist that also carries
  # assignees — the two keys are independent, and the assignee list must never
  # leak into the label set that goes into the REST `labels=` term.
  got=$(poller_watchlist_pick_labels "$AWL" '/tmp/repo-a')
  if [ "$got" = "auto-run" ]; then
    ok "case9 the assignee key does not disturb the label lookup"
  else
    bad "case9 the assignee key leaked into the labels (got '$got')"
  fi
fi

# ---- Case 8: poller.sh goes through the shared function ----
# The chain must not grow a second implementation: a poller that resolved its
# own labels could pick up a different set than /issue-runner:new-epic writes,
# and the mismatch would look exactly like an issue that "just never runs".
POLLER="$ROOT/poller.sh"
if grep -q 'poller_pick_labels' "$POLLER"; then
  ok "case8 poller.sh calls poller_pick_labels"
else
  bad "case8 poller.sh does not call poller_pick_labels"
fi
if hits=$(grep -n 'LABELS_CSV="\$REPO_LABELS"\|default_labels // \["auto-run"\]' "$POLLER"); then
  bad "case8 poller.sh still resolves pickup labels inline:"
  printf '%s\n' "$hits" | sed 's/^/      /'
else
  ok "case8 poller.sh has no inline pickup-label fallback left"
fi

# ---- Case 10: both pickup entry points share the assignee resolver ----
# The poller and the window model must not be able to disagree about what this
# host picks up. drain-queue.sh already reads the labels through the shared
# lookup; the assignee list has to travel the same way, or a drain could take
# an issue the poller would never touch.
DRAIN="$ROOT/drain-queue.sh"
for f in "$POLLER" "$DRAIN"; do
  if grep -q 'poller_watchlist_pick_assignees' "$f"; then
    ok "case10 $(basename "$f") resolves assignees through the shared function"
  else
    bad "case10 $(basename "$f") does not call poller_watchlist_pick_assignees"
  fi
  if grep -vE '^\s*#' "$f" | grep -qE '\.assignees|jq[^|]*assignees'; then
    bad "case10 $(basename "$f") reads the assignees key inline"
  else
    ok "case10 $(basename "$f") has no inline assignees read"
  fi
done

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "pick-labels: all passed" || echo "pick-labels: FAILURES"
[ "$FAIL" -eq 0 ]
