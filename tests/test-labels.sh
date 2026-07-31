#!/usr/bin/env bash
# test-labels.sh — regression coverage for lib/labels.sh.
#
# What this protects
# ------------------
# 1. The REST call shape: labels are attached via
#    `api --method POST repos/<o>/<r>/issues/<n>/labels -f labels[]=<name>`,
#    never via `gh issue edit` / `gh pr edit`. That is the whole point of the
#    lib — those subcommands demand the `read:project` OAuth scope and failed
#    silently on the fleet for five weeks. A test that asserts the shape is
#    what keeps someone from "simplifying" it back to gh pr edit.
# 2. One call carries every label (CSV -> repeated -f), with whitespace
#    trimmed and empty entries dropped.
# 3. Failures are NOT swallowed: rc propagates and a diagnostic reaches
#    stderr. The original bug was invisible precisely because stderr went to
#    /dev/null.
# 4. labels_ensure treats an existing label (422 already_exists) as success.
# 5. The pure URL parsers extract owner/repo and number from PR and issue URLs.
#
# Network-free: gh is a PATH shim that records argv and replays a scripted
# exit code / stderr from files in the work dir.
#
# Run: bash tests/test-labels.sh   (exit 0 = all pass)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib/labels.sh"

WORK=$(mktemp -d -t labels-test.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

BIN="$WORK/bin"; mkdir -p "$BIN"
GH_LOG="$WORK/gh-calls.log"
GH_RC="$WORK/gh-rc"; echo 0 > "$GH_RC"
GH_ERR="$WORK/gh-err"; : > "$GH_ERR"

cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"
cat "$GH_ERR" >&2
exit "\$(cat "$GH_RC")"
SH
chmod +x "$BIN/gh"
PATH="$BIN:$PATH"

# shellcheck source=lib/labels.sh
. "$LIB"

FAIL=0
fail() { echo "FAIL: $*"; FAIL=1; }
ok()   { echo "ok:   $*"; }

reset() { : > "$GH_LOG"; echo 0 > "$GH_RC"; : > "$GH_ERR"; }

# === 1 + 2. call shape, multi-label, trimming ==============================
reset
labels_add "acme/widgets" 42 "auto-merge, priority ,, release" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] || fail "labels_add returned $RC on a healthy gh"

CALL=$(cat "$GH_LOG")
case "$CALL" in
  *"api --method POST repos/acme/widgets/issues/42/labels"*) ok "REST endpoint shape" ;;
  *) fail "wrong endpoint: $CALL" ;;
esac
case "$CALL" in
  *"pr edit"*|*"issue edit"*) fail "used the scope-fragile gh edit path: $CALL" ;;
  *) ok "does not use gh pr/issue edit" ;;
esac
for want in "labels[]=auto-merge" "labels[]=priority" "labels[]=release"; do
  case "$CALL" in
    *"$want"*) ok "carries $want" ;;
    *) fail "missing $want in: $CALL" ;;
  esac
done
[ "$(wc -l < "$GH_LOG")" -eq 1 ] || fail "expected a single combined call, got $(wc -l < "$GH_LOG")"
case "$CALL" in
  *"labels[]= "*|*"labels[]=,"*) fail "whitespace/empty entry leaked: $CALL" ;;
  *) ok "trims whitespace and drops empty entries" ;;
esac

# === 3. failures propagate rc AND a diagnostic =============================
reset
echo 1 > "$GH_RC"
printf 'HTTP 403: Resource not accessible by integration\n' > "$GH_ERR"
ERR_OUT=$(labels_add "acme/widgets" 42 "auto-merge" 2>&1 >/dev/null)
RC=$?
[ "$RC" -ne 0 ] || fail "labels_add masked a gh failure as success"
case "$ERR_OUT" in
  *"labels_add"*"403"*) ok "failure diagnostic reaches stderr" ;;
  *) fail "diagnostic lost the cause: '$ERR_OUT'" ;;
esac
[ "$(printf '%s' "$ERR_OUT" | wc -l)" -le 1 ] || fail "diagnostic spans multiple lines"

# missing arguments are rejected without calling gh at all
reset
labels_add "acme/widgets" 42 "" >/dev/null 2>&1
[ $? -eq 2 ] || fail "empty label CSV should return 2"
[ ! -s "$GH_LOG" ] || fail "empty CSV still called gh: $(cat "$GH_LOG")"
ok "rejects empty label list without calling gh"

# === labels_remove: DELETE + URL encoding ==================================
reset
labels_remove "acme/widgets" 7 "needs human" >/dev/null 2>&1
CALL=$(cat "$GH_LOG")
case "$CALL" in
  *"api --method DELETE repos/acme/widgets/issues/7/labels/needs%20human"*)
    ok "remove uses DELETE with a URL-encoded label" ;;
  *) fail "wrong remove call: $CALL" ;;
esac

# === empty owner/repo falls back to gh's cwd placeholders ==================
# orchestrate.sh leaves OWNER_REPO empty on origin remotes on purpose; gh api
# fills {owner}/{repo} from the working directory's remote, preserving that.
reset
labels_add "" 42 "auto-merge" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] || fail "empty owner/repo should be valid (cwd inference), rc=$RC"
CALL=$(cat "$GH_LOG")
case "$CALL" in
  *"repos/{owner}/{repo}/issues/42/labels"*) ok "empty owner/repo -> {owner}/{repo} placeholders" ;;
  *) fail "expected placeholder path, got: $CALL" ;;
esac

# === 4. labels_ensure tolerates an existing label ==========================
reset
echo 1 > "$GH_RC"
printf 'HTTP 422: Validation Failed (already_exists)\n' > "$GH_ERR"
ERR_OUT=$(labels_ensure "acme/widgets" "waiting" FBCA04 "odottaa" 2>&1 >/dev/null)
RC=$?
[ "$RC" -eq 0 ] || fail "labels_ensure should treat already_exists as success (rc=$RC)"
[ -z "$ERR_OUT" ] || fail "already_exists should stay silent, got: '$ERR_OUT'"
ok "labels_ensure: existing label is success, silently"

reset
echo 1 > "$GH_RC"
printf 'HTTP 404: Not Found\n' > "$GH_ERR"
labels_ensure "acme/widgets" "waiting" >/dev/null 2>&1
[ $? -ne 0 ] || fail "labels_ensure masked a real failure"
ok "labels_ensure: real failure still propagates"

# === 5. pure URL parsers ===================================================
[ "$(labels_owner_repo_from_url 'https://github.com/Silon-Oy/customer-c-erp/pull/42')" = "Silon-Oy/customer-c-erp" ] \
  || fail "owner/repo from PR URL"
[ "$(labels_number_from_url 'https://github.com/Silon-Oy/customer-c-erp/pull/42')" = "42" ] \
  || fail "number from PR URL"
[ "$(labels_owner_repo_from_url 'https://github.com/o/r/issues/7')" = "o/r" ] \
  || fail "owner/repo from issue URL"
[ "$(labels_number_from_url 'https://github.com/o/r/issues/7#issuecomment-1')" = "7" ] \
  || fail "number from issue URL with fragment"
[ -z "$(labels_owner_repo_from_url 'not-a-url')" ] || fail "garbage URL should yield empty"
[ -z "$(labels_number_from_url '')" ] || fail "empty URL should yield empty"
ok "URL parsers handle pull/issues/fragment/garbage"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "labels: all passed" || echo "labels: FAILURES"
[ "$FAIL" -eq 0 ]
