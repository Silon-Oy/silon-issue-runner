#!/usr/bin/env bash
# test-data-migration.sh — the data-destroying-migration scan (lib/data-migration.sh)
# and its hold in pr-watch.sh (issue #409).
#
# Scanner (fixture git repos, base + head commit):
#   S1) DROP COLUMN in migrations/ hits with the right file:line
#   S2) CREATE TABLE / ADD COLUMN do not hit (rc 1)
#   S3) UPDATE in a backfill script hits only when .data_migration.paths names it
#   S4) a REMOVED destructive line does not hit
#   S5) invalid config / unresolvable ref -> rc 2, never rc 1
#   S6) path matching: **/ also matches at the root
#
# PR watcher (gh is a PATH shim, no agent; FOREIGN host so the run-dir survives):
#   W1) hit -> manual-merge label, one marker comment, no merge, exit 10
#   W2) next tick (payload carries manual-merge) -> rescanned and held: no new
#       comment, no new label, no merge
#   W3) same head, label write lost -> label again, comment NOT repeated
#   W4) scan cannot run (invalid base config) -> held, no merge
#   W5) no hit -> merge bound to the scanned head
#   W6) switch off -> no scan, merge
#   W7) heavy-run override: manual-merge + auto-merge, no hit -> merged
#
# Run: bash tests/test-data-migration.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Hermetic: never source this machine's real env file (CLAUDE.md §5.5).
export RUN_ISSUES_ENV_FILE="$HERE/.no-such-machine-env"
PRWATCH="$HERE/../pr-watch.sh"
STATE_LIB="$HERE/../lib/state.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available"
  exit 0
fi

# shellcheck source=../lib/data-migration.sh
. "$HERE/../lib/data-migration.sh"

FAIL=0
bad() { echo "FAIL $1: $2"; FAIL=1; }
ok()  { echo "PASS $1: $2"; }

TMP=$(mktemp -d -t datamig.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# fixture <dir> — a repo with one base commit on main; the caller adds the head.
fixture() {
  local d="$1"
  git init -q "$d"
  git -C "$d" symbolic-ref HEAD refs/heads/main
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
  mkdir -p "$d/db/migrations" "$d/scripts"
  printf 'CREATE TABLE users (id int);\nDROP TABLE legacy;\n' > "$d/db/migrations/001.sql"
  printf '<?php\n' > "$d/scripts/backfill-phone.php"
  git -C "$d" add -A; git -C "$d" commit -qm base
  git -C "$d" checkout -q -b feature
}
commit_head() { git -C "$1" add -A; git -C "$1" commit -qm head; }
scan() { ( cd "$1" && data_migration_scan main feature "${2-}" ); }

# ---- S1 ---------------------------------------------------------------------
R="$TMP/s1"; fixture "$R"
mkdir -p "$R/migrations"
printf -- '-- drop the phone\nALTER TABLE users DROP COLUMN phone;\n' > "$R/migrations/002.sql"
commit_head "$R"
OUT=$(scan "$R"); RC=$?
[ "$RC" = 0 ] || bad S1 "rc $RC, want 0"
[ "$OUT" = "migrations/002.sql:2"$'\t'"ALTER TABLE users DROP COLUMN phone;" ] || bad S1 "output '$OUT'"
[ "$FAIL" = 0 ] && ok S1 "DROP COLUMN hits with file:line"

# ---- S2 ---------------------------------------------------------------------
FB=$FAIL
R="$TMP/s2"; fixture "$R"
printf 'CREATE TABLE phones (id int, updated_at timestamp);\nALTER TABLE users ADD COLUMN phone text;\n' > "$R/db/migrations/002.sql"
commit_head "$R"
OUT=$(scan "$R"); RC=$?
[ "$RC" = 1 ] || bad S2 "rc $RC, want 1 (out '$OUT')"
[ -z "$OUT" ] || bad S2 "output '$OUT'"
[ "$FAIL" = "$FB" ] && ok S2 "CREATE TABLE / ADD COLUMN do not hit"

# ---- S3 ---------------------------------------------------------------------
FB=$FAIL
R="$TMP/s3"; fixture "$R"
printf '<?php\n$db->query("UPDATE users SET phone = NULL");\n' > "$R/scripts/backfill-phone.php"
commit_head "$R"
OUT=$(scan "$R"); RC=$?
[ "$RC" = 1 ] || bad S3 "without config: rc $RC, want 1 (out '$OUT')"
OUT=$(scan "$R" '{"data_migration":{"paths":["scripts/backfill*"]}}'); RC=$?
[ "$RC" = 0 ] || bad S3 "with config: rc $RC, want 0"
case "$OUT" in "scripts/backfill-phone.php:2"$'\t'*'UPDATE users SET phone = NULL'*) ;; *) bad S3 "output '$OUT'" ;; esac
[ "$FAIL" = "$FB" ] && ok S3 "UPDATE in a configured backfill path hits"

# ---- S4 ---------------------------------------------------------------------
FB=$FAIL
R="$TMP/s4"; fixture "$R"
printf 'CREATE TABLE users (id int);\n' > "$R/db/migrations/001.sql"
commit_head "$R"
OUT=$(scan "$R"); RC=$?
[ "$RC" = 1 ] || bad S4 "rc $RC, want 1 (out '$OUT')"
[ "$FAIL" = "$FB" ] && ok S4 "a removed DROP TABLE does not hit"

# ---- S5 ---------------------------------------------------------------------
FB=$FAIL
R="$TMP/s1"
scan "$R" '{not json' >/dev/null; RC=$?
[ "$RC" = 2 ] || bad S5 "invalid JSON: rc $RC, want 2"
scan "$R" '{"data_migration":{"paths":"scripts/*"}}' >/dev/null; RC=$?
[ "$RC" = 2 ] || bad S5 "paths not an array: rc $RC, want 2"
scan "$R" '{"data_migration":{"paths":[1]}}' >/dev/null; RC=$?
[ "$RC" = 2 ] || bad S5 "non-string path: rc $RC, want 2"
( cd "$R" && data_migration_scan main no-such-ref ) >/dev/null; RC=$?
[ "$RC" = 2 ] || bad S5 "unresolvable ref: rc $RC, want 2"
( cd "$TMP" && data_migration_scan main feature ) >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] || bad S5 "outside a repo: rc $RC, want 2"
scan "$R" '{"other":1}' >/dev/null; RC=$?
[ "$RC" = 0 ] || bad S5 "config without data_migration: rc $RC, want 0 (defaults)"
[ "$FAIL" = "$FB" ] && ok S5 "scan errors are rc 2, never rc 1"

# ---- S6 ---------------------------------------------------------------------
FB=$FAIL
P='**/migrations/**/*.sql'
for p in migrations/1.sql db/migrations/1.sql a/b/migrations/2026/1.sql; do
  data_migration_path_matches "$p" "$P" || bad S6 "'$p' should match '$P'"
done
for p in migrations.sql db/migrations/1.php src/remigrations/1.sql; do
  data_migration_path_matches "$p" "$P" && bad S6 "'$p' should not match '$P'"
done
[ "$FAIL" = "$FB" ] && ok S6 "path patterns"

# ============================================================================
# PR watcher
# ============================================================================

# setup <name> <file> <content> — origin + repo + feature worktree with one
# commit writing <content> to <file>, a completed run (FOREIGN host), gh shim.
setup() {
  WORK="$TMP/w-$1"; mkdir -p "$WORK"
  ORIGIN="$WORK/origin.git"; REPO="$WORK/repo"; WT="$WORK/wt-feature"
  git init -q --bare "$ORIGIN"
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  git init -q "$REPO"
  git -C "$REPO" symbolic-ref HEAD refs/heads/main
  (
    cd "$REPO"
    git config user.email t@t.t; git config user.name t
    git remote add origin "$ORIGIN"
    echo v0 > README; git add -A; git commit -qm init
    if [ -n "${BASE_CFG:-}" ]; then
      mkdir -p .claude; printf '%s\n' "$BASE_CFG" > .claude/run-issues.json
      git add .claude/run-issues.json; git commit -qm cfg
    fi
    git push -q origin main
    git checkout -q -b auto-run/x-5
    mkdir -p "$(dirname "$2")"; printf '%s\n' "$3" > "$2"
    git add "$2"; git commit -qm feature
    git push -q origin auto-run/x-5
    git checkout -q main
  )
  ( cd "$REPO" && git worktree add -q "$WT" auto-run/x-5 )

  RD="$REPO/.claude/run-issues/20261028-1200-issue-5"
  # shellcheck source=../lib/state.sh
  . "$STATE_LIB"
  state_init "$RD" "20261028-1200-issue-5" "$REPO" "5"
  state_set "$RD" "pr_url" "https://github.com/Silon-Oy/x/pull/55"
  state_set "$RD" "worktree_path" "$WT"
  state_set "$RD" "branch" "auto-run/x-5"
  state_set "$RD" "owner_repo" "Silon-Oy/x"
  local tmp; tmp=$(mktemp)
  jq '.host = "some-other-host"' "$RD/run.json" > "$tmp"; mv "$tmp" "$RD/run.json"
  state_finalize "$RD" "completed"

  BIN="$WORK/bin"; mkdir -p "$BIN"
  : > "$WORK/labels.log"; : > "$WORK/comments.log"; : > "$WORK/merge.log"
  echo '[{"name":"auto-merge"}]' > "$WORK/pr_labels"
  cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
case "\$1" in
  api)  printf '%s\n' "\$*" >> "$WORK/labels.log"; exit 0 ;;
  auth) exit 0 ;;
esac
case "\$1 \$2" in
  "pr view")
    jq -n --argjson l "\$(cat "$WORK/pr_labels")" '{state:"OPEN",mergeable:"MERGEABLE",mergeStateStatus:"CLEAN",labels:\$l,
      statusCheckRollup:[{__typename:"CheckRun",name:"ci",status:"COMPLETED",conclusion:"SUCCESS"}],
      headRefName:"auto-run/x-5",baseRefName:"main"}' ;;
  "pr merge")   printf '%s\n' "\$*" >> "$WORK/merge.log"; echo "merged (mock)" ;;
  "pr comment") { cat; echo; echo "-----"; } >> "$WORK/comments.log" ;;
  "issue view") echo '{"state":"CLOSED"}' ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$BIN/gh"
  # Any agent call is a test failure: the hold is deterministic.
  printf '#!/usr/bin/env bash\necho AGENT >> "%s/agent.log"\nexit 1\n' "$WORK" > "$BIN/claude-mock"
  chmod +x "$BIN/claude-mock"
}

run_watch() {
  set +e
  OUT=$( env PATH="$BIN:$PATH" \
    RUN_ISSUES_LOCK_ROOT="$WORK/locks" \
    RUN_ISSUES_CLAUDE_CMD="$BIN/claude-mock" \
    PR_WATCH_ENABLE_DATA_MIGRATION_GATE=1 \
    PR_WATCH_ENABLE_SECURITY_GATE=0 PR_WATCH_ENABLE_SEMANTIC_CHECK=0 \
    "$@" "$PRWATCH" "$REPO" 55 2>&1 )
  RC=$?
}

merged() { [ -s "$WORK/merge.log" ]; }
comments() { grep -c 'run-issues:data-migration-gate' "$WORK/comments.log" 2>/dev/null || true; }
label_adds() { grep -c "issues/55/labels.*labels\[\]=manual-merge" "$WORK/labels.log" 2>/dev/null || true; }
show() { echo "$OUT" | sed "s/^/$1| /"; echo "$1| (rc=$RC)"; }

# ---- W1..W3 -------------------------------------------------------------------
FB=$FAIL
setup W migrations/002.sql 'ALTER TABLE users DROP COLUMN phone;'
run_watch
[ "$RC" = 10 ] || { show W1; bad W1 "rc $RC, want 10"; }
merged && bad W1 "merged"
[ "$(comments)" = 1 ] || bad W1 "marker comments $(comments), want 1"
grep -q 'migrations/002.sql:1' "$WORK/comments.log" || bad W1 "comment does not name the hit"
grep -q 'DROP COLUMN phone' "$WORK/comments.log" || bad W1 "comment does not quote the statement"
[ "$(label_adds)" = 1 ] || bad W1 "manual-merge label adds $(label_adds), want 1"
grep -q '"event":"pr_data_migration_held"' "$RD/state.jsonl" || bad W1 "no pr_data_migration_held event"
[ -e "$WORK/agent.log" ] && bad W1 "an agent was called"
[ "$FAIL" = "$FB" ] && ok W1 "hit -> manual-merge, one comment, no merge, exit 10"

FB=$FAIL
echo '[{"name":"auto-merge"},{"name":"manual-merge"}]' > "$WORK/pr_labels"
run_watch
[ "$RC" = 10 ] || { show W2; bad W2 "rc $RC, want 10"; }
merged && bad W2 "merged a manual-merge PR"
[ "$(comments)" = 1 ] || bad W2 "marker comments $(comments), want still 1"
[ "$(label_adds)" = 1 ] || bad W2 "label written again"
[ "$FAIL" = "$FB" ] && ok W2 "held PR: no repeat comment, no merge"

FB=$FAIL
echo '[{"name":"auto-merge"}]' > "$WORK/pr_labels"
run_watch
[ "$RC" = 10 ] || { show W3; bad W3 "rc $RC, want 10"; }
merged && bad W3 "merged"
[ "$(comments)" = 1 ] || bad W3 "marker comments $(comments), want still 1 for the same head"
[ "$(label_adds)" = 2 ] || bad W3 "label adds $(label_adds), want 2"
[ "$FAIL" = "$FB" ] && ok W3 "same head without the label: label again, comment not repeated"

# ---- W4 ---------------------------------------------------------------------
FB=$FAIL
BASE_CFG='{"data_migration":{"paths":"oops"}}' setup W4 docs/readme.md 'nothing'
run_watch
[ "$RC" = 10 ] || { show W4; bad W4 "rc $RC, want 10"; }
merged && bad W4 "merged although the scan could not run"
grep -q 'ei toteutunut' "$WORK/comments.log" || bad W4 "comment does not say the scan failed"
[ "$(label_adds)" = 1 ] || bad W4 "label adds $(label_adds), want 1"
[ "$FAIL" = "$FB" ] && ok W4 "scan failure holds (fail-closed)"

# ---- W5 ---------------------------------------------------------------------
FB=$FAIL
setup W5 migrations/002.sql 'ALTER TABLE users ADD COLUMN phone2 text;'
SHA=$(git -C "$WT" rev-parse HEAD)
run_watch
[ "$RC" = 0 ] || { show W5; bad W5 "rc $RC, want 0"; }
merged || bad W5 "not merged"
grep -q -- "--match-head-commit $SHA" "$WORK/merge.log" || bad W5 "merge not bound to the scanned head"
[ "$(comments)" = 0 ] || bad W5 "commented"
[ "$FAIL" = "$FB" ] && ok W5 "no hit -> merge bound to the scanned head"

# ---- W6 ---------------------------------------------------------------------
FB=$FAIL
setup W6 migrations/002.sql 'DROP TABLE users;'
run_watch PR_WATCH_ENABLE_DATA_MIGRATION_GATE=0
[ "$RC" = 0 ] || { show W6; bad W6 "rc $RC, want 0"; }
merged || bad W6 "not merged with the switch off"
[ "$(comments)" = 0 ] || bad W6 "commented with the switch off"
[ "$FAIL" = "$FB" ] && ok W6 "switch off -> no scan"

# ---- W7 ---------------------------------------------------------------------
# A heavy-run PR carries manual-merge from birth; a human releases it by adding
# auto-merge. Without a data-destroying statement the hold must not stop it.
FB=$FAIL
setup W7 migrations/002.sql 'ALTER TABLE users ADD COLUMN phone2 text;'
echo '[{"name":"auto-merge"},{"name":"manual-merge"}]' > "$WORK/pr_labels"
run_watch
[ "$RC" = 0 ] || { show W7; bad W7 "rc $RC, want 0"; }
merged || bad W7 "heavy-run override not merged"
[ "$(comments)" = 0 ] || bad W7 "commented"
[ "$(label_adds)" = 0 ] || bad W7 "label written"
[ "$FAIL" = "$FB" ] && ok W7 "manual-merge alone does not hold a PR without a hit"

echo "----------------------------------------"
if [ "$FAIL" = 0 ]; then echo "data-migration: ALL PASS"; else echo "data-migration: FAILURES"; fi
exit "$FAIL"
