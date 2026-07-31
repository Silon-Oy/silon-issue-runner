#!/usr/bin/env bash
# test-db-clone-cleanup.sh — round-trip for db-clone.sh cleanup (postgres).
#
# clone -> cleanup -> DB gone -> cleanup again returns 0 (idempotent).
# Skips with exit 0 if no local postgres server is reachable (CI/laptop
# without a DB), printing SKIP so the run still passes.
#
# Run: bash tests/test-db-clone-cleanup.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DBCLONE="$HERE/../db-clone/db-clone.sh"

PG_ADMIN="postgres://localhost:5432/postgres"
if ! command -v psql >/dev/null 2>&1 || ! psql --dbname="$PG_ADMIN" -c '\conninfo' >/dev/null 2>&1; then
  echo "SKIP db-clone-cleanup: no local postgres server reachable"
  exit 0
fi

WORK=$(mktemp -d -t dbclone-test.XXXXXX)
REPO="$WORK/repo"
mkdir -p "$REPO/.claude"
trap 'rm -rf "$WORK"; psql --dbname="$PG_ADMIN" -c "DROP DATABASE IF EXISTS dbclone_test_src;" >/dev/null 2>&1 || true' EXIT

psql --dbname="$PG_ADMIN" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS dbclone_test_src;" >/dev/null
psql --dbname="$PG_ADMIN" -v ON_ERROR_STOP=1 -c "CREATE DATABASE dbclone_test_src;" >/dev/null
psql --dbname="postgres://localhost:5432/dbclone_test_src" -v ON_ERROR_STOP=1 \
  -c "CREATE TABLE t(id int); INSERT INTO t VALUES (1);" >/dev/null

cat > "$REPO/.claude/db-clone.json" <<'JSON'
{
  "type": "postgres",
  "source_conn": "postgres://localhost:5432/dbclone_test_src",
  "target_conn_template": "postgres://localhost:5432/{db}",
  "clone": { "name_prefix": "pg_clone_test_" }
}
JSON

SLUG="rt"
CLONE_DB="pg_clone_test_rt"
db_exists() {
  psql --dbname="$PG_ADMIN" -tAc \
    "SELECT 1 FROM pg_database WHERE datname='$CLONE_DB';" 2>/dev/null | grep -q 1
}

FAIL=0
"$DBCLONE" "$REPO" "$SLUG" >/dev/null
db_exists && echo "PASS clone created $CLONE_DB" || { echo "FAIL clone"; FAIL=1; }

"$DBCLONE" cleanup "$REPO" "$SLUG"
db_exists && { echo "FAIL cleanup left DB"; FAIL=1; } || echo "PASS cleanup dropped $CLONE_DB"

if "$DBCLONE" cleanup "$REPO" "$SLUG"; then
  echo "PASS cleanup idempotent (rc=0 on missing DB)"
else
  echo "FAIL cleanup not idempotent"; FAIL=1
fi

"$DBCLONE" cleanup "$REPO" "$SLUG" >/dev/null 2>&1 || true
echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "db-clone-cleanup: all passed" || echo "db-clone-cleanup: FAILURES"
[ "$FAIL" -eq 0 ]
