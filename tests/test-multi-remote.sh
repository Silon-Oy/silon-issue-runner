#!/usr/bin/env bash
# test-multi-remote.sh — multi-remote (multi-org) plumbing (issue #53).
#
# Verifies the load-bearing invariants of one clone polling multiple GitHub
# orgs at once:
#   (a) parse_owner_repo_from_remote_url handles SSH/HTTPS/ssh:// shapes with
#       and without `.git`; rejects non-github hosts and malformed URLs.
#   (b) resolve_remote_to_owner_repo reads `git remote get-url <name>` from a
#       real local clone and returns owner/repo; missing remote -> rc=1.
#   (c) remote_label / session_suffix backward compatibility:
#         - origin: lock label = "issue-N", tmux suffix = "N" (legacy)
#         - other:  lock label = "<remote>-issue-N", tmux suffix = "<remote>-issue-N"
#   (d) lock_issue / unlock_issue namespace by remote — origin and a non-origin
#       remote can hold concurrent locks for the same issue number without
#       colliding.
#   (e) cleanup-run.sh removes a non-origin-namespaced lock.
#
# Verkoton, deterministinen — käyttää aitoja paikallisia git-repoja ja
# stubattua gh-binääriä. Run: bash tests/test-multi-remote.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GR_LIB="$HERE/../lib/git-remote.sh"
LOCKING_LIB="$HERE/../lib/locking.sh"
STATE_LIB="$HERE/../lib/state.sh"
CLEANUP="$HERE/../cleanup-run.sh"

WORK=$(mktemp -d -t multi-remote.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0

# ===========================================================================
# (a) parse_owner_repo_from_remote_url
# ===========================================================================
# shellcheck source=../lib/git-remote.sh
. "$GR_LIB"

assert_parse() {
  local url="$1" want="$2" tag="$3"
  local got
  got=$(parse_owner_repo_from_remote_url "$url")
  if [ "$got" = "$want" ]; then
    echo "PASS (a) $tag: '$url' -> '$got'"
  else
    echo "FAIL (a) $tag: '$url' -> '$got' (want '$want')"
    FAIL=1
  fi
}

assert_parse "git@github.com:Silon-Oy/map-api.git"   "Silon-Oy/map-api"   "ssh scp+.git"
assert_parse "git@github.com:Silon-Oy/map-api"       "Silon-Oy/map-api"   "ssh scp no .git"
assert_parse "https://github.com/Silon-Oy/map-api.git" "Silon-Oy/map-api" "https+.git"
assert_parse "https://github.com/Silon-Oy/map-api"     "Silon-Oy/map-api" "https no .git"
assert_parse "ssh://git@github.com/partner-org/map-api.git" "partner-org/map-api" "ssh://"
assert_parse "https://github.com/partner-org/map-api/"   "partner-org/map-api"   "trailing slash"

# non-github + malformed
assert_parse "https://gitlab.com/Silon-Oy/map-api.git" ""                       "non-github (gitlab)"
assert_parse ""                                            ""                          "empty input"
assert_parse "https://github.com/Silon-Oy/map-api/extra/path" "" "extra path segments rejected"
assert_parse "git@github.com:owner-only" ""                                            "missing repo half"

# ===========================================================================
# (b) resolve_remote_to_owner_repo against a real local clone
# ===========================================================================
ORIGIN_BARE="$WORK/origin.git"
PARTNER_BARE="$WORK/partner.git"
git init -q --bare "$ORIGIN_BARE"
# Force `main` regardless of the machine's init.defaultBranch.
git -C "$ORIGIN_BARE" symbolic-ref HEAD refs/heads/main
git init -q --bare "$PARTNER_BARE"
git -C "$PARTNER_BARE" symbolic-ref HEAD refs/heads/main

CLONE="$WORK/clone"
git init -q "$CLONE"
git -C "$CLONE" symbolic-ref HEAD refs/heads/main
(
  cd "$CLONE"
  git config user.email t@t.t
  git config user.name t
  echo "v0" > f.txt
  git add f.txt
  git commit -qm init
  # Use scp-like SSH URL for origin (most common GitHub clone shape) and an
  # https URL for the secondary remote so both code paths get exercised.
  git remote add origin "git@github.com:Silon-Oy/map-api.git"
  # The clone never actually pushes to these URLs in this test; the parse
  # function reads URL strings, not network.
  git remote add partner "https://github.com/partner-org/map-api.git"
)

GOT_ORIGIN=$(resolve_remote_to_owner_repo "$CLONE" "origin")
[ "$GOT_ORIGIN" = "Silon-Oy/map-api" ] \
  || { echo "FAIL (b) origin -> '$GOT_ORIGIN' (want Silon-Oy/map-api)"; FAIL=1; }
GOT_PARTNER=$(resolve_remote_to_owner_repo "$CLONE" "partner")
[ "$GOT_PARTNER" = "partner-org/map-api" ] \
  || { echo "FAIL (b) partner -> '$GOT_PARTNER' (want partner-org/map-api)"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (b) resolve_remote_to_owner_repo reads URL from clone"

# Missing remote -> rc=1, empty stdout.
set +e
GOT_MISSING=$(resolve_remote_to_owner_repo "$CLONE" "does-not-exist")
RC_MISSING=$?
set -e
[ "$RC_MISSING" = "1" ] && [ -z "$GOT_MISSING" ] \
  || { echo "FAIL (b) missing remote: rc=$RC_MISSING got='$GOT_MISSING' (want rc=1, empty)"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (b) missing remote -> rc=1 + empty"

# ===========================================================================
# (c) remote_label / session_suffix backward compatibility
# ===========================================================================
# origin -> legacy shapes
[ "$(remote_label origin 5)" = "issue-5" ] \
  || { echo "FAIL (c) remote_label origin 5"; FAIL=1; }
[ "$(remote_label '' 5)" = "issue-5" ] \
  || { echo "FAIL (c) remote_label '' 5 (treat empty as origin)"; FAIL=1; }
[ "$(session_suffix origin 5)" = "5" ] \
  || { echo "FAIL (c) session_suffix origin 5"; FAIL=1; }
[ "$(session_suffix '' 5)" = "5" ] \
  || { echo "FAIL (c) session_suffix '' 5"; FAIL=1; }
# non-origin -> namespaced
[ "$(remote_label partner 5)" = "partner-issue-5" ] \
  || { echo "FAIL (c) remote_label partner 5"; FAIL=1; }
[ "$(session_suffix partner 5)" = "partner-issue-5" ] \
  || { echo "FAIL (c) session_suffix partner 5"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (c) remote_label + session_suffix legacy/namespaced split"

# ===========================================================================
# (d) lock_issue / unlock_issue namespace
# ===========================================================================
export RUN_ISSUES_LOCK_ROOT="$WORK/locks"
# shellcheck source=../lib/locking.sh
. "$LOCKING_LIB"

# origin lock for issue 5
lock_issue 5 origin || { echo "FAIL (d) lock_issue 5 origin"; FAIL=1; }
ORIGIN_LOCK="$RUN_ISSUES_LOCK_ROOT/issue-5.lock"
[ -d "$ORIGIN_LOCK" ] \
  || { echo "FAIL (d) origin lock dir not created at $ORIGIN_LOCK"; FAIL=1; }

# partner lock for the same issue 5 — should succeed, distinct path
lock_issue 5 partner || { echo "FAIL (d) lock_issue 5 partner — collided with origin"; FAIL=1; }
PARTNER_LOCK="$RUN_ISSUES_LOCK_ROOT/partner-issue-5.lock"
[ -d "$PARTNER_LOCK" ] \
  || { echo "FAIL (d) partner lock dir not created at $PARTNER_LOCK"; FAIL=1; }

# Trying to re-lock origin (no remote arg = default origin) must fail
set +e
lock_issue 5
RC_RELOCK=$?
set -e
[ "$RC_RELOCK" = "1" ] \
  || { echo "FAIL (d) re-locking origin issue 5 should have failed, got rc=$RC_RELOCK"; FAIL=1; }

# unlock each namespace independently
unlock_issue 5 origin
[ ! -d "$ORIGIN_LOCK" ] \
  || { echo "FAIL (d) origin lock not removed by unlock"; FAIL=1; }
[ -d "$PARTNER_LOCK" ] \
  || { echo "FAIL (d) partner lock removed by origin unlock — namespaces leak"; FAIL=1; }
unlock_issue 5 partner
[ ! -d "$PARTNER_LOCK" ] \
  || { echo "FAIL (d) partner lock not removed by unlock"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "PASS (d) namespaced locks coexist + independent unlock"

# ===========================================================================
# (e) cleanup-run.sh removes a non-origin lock
# ===========================================================================
# shellcheck source=../lib/state.sh
. "$STATE_LIB"
set +e  # state.sh re-enables -e

# Re-acquire a partner lock for issue 77 + create a matching non-completed run.
lock_issue 77 partner || { echo "FAIL (e) could not acquire partner lock 77"; FAIL=1; }
WL="$RUN_ISSUES_LOCK_ROOT/partner-issue-77.lock"
[ -d "$WL" ] || { echo "FAIL (e) partner lock dir 77 not created"; FAIL=1; }

REPO_E="$WORK/repo-e"
mkdir -p "$REPO_E/.git"
RID_E="20260601-1200-partner-issue-77"
RD_E="$REPO_E/.claude/run-issues/$RID_E"
state_init "$RD_E" "$RID_E" "$REPO_E" 77
state_set "$RD_E" "remote" "partner"
state_finalize "$RD_E" "blocked"

# Stub gh so cleanup's `gh issue edit` is a no-op.
BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$BIN/gh"
PATH="$BIN:$PATH" \
  RUN_ISSUES_LOCK_ROOT="$RUN_ISSUES_LOCK_ROOT" \
  bash "$CLEANUP" --repo "$REPO_E" --issue 77 --remote partner --yes >/dev/null 2>&1
RC_CLEAN=$?
[ "$RC_CLEAN" = "0" ] || { echo "FAIL (e) cleanup-run.sh exited rc=$RC_CLEAN"; FAIL=1; }
if [ -d "$WL" ]; then
  echo "FAIL (e) partner-issue-77.lock still present after cleanup-run.sh"
  FAIL=1
else
  echo "PASS (e) cleanup-run.sh removes non-origin lock partner-issue-77.lock"
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "multi-remote: all passed" || echo "multi-remote: FAILURES"
[ "$FAIL" -eq 0 ]
