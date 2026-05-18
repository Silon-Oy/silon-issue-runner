#!/usr/bin/env bash
# db-clone/postgres.sh — clone a Postgres database via pg_dump + psql.
#
# Args: <repo-root> <slug> <config-json>
#
# Config schema:
#   {
#     "type": "postgres",
#     "source_conn": "postgres://user:pass@host:5432/proddb",  # required
#     "target_conn_template":                                  # required
#        "postgres://user:pass@host:5432/{db}",
#     "clone": {
#       "name_prefix": "pg_clone_"
#     }
#   }
#
# The {db} placeholder in target_conn_template is replaced with the
# generated database name. The source_conn is only used by pg_dump; the
# template's connection (minus the {db}) must point at a server where
# the running user has CREATEDB privileges.
#
# Prints RUN_ISSUES_DB_CLONE=<cloned-db-name> on success.

set -euo pipefail

REPO_ROOT="$1"  # unused but kept for signature symmetry
SLUG="$2"
CONFIG="$3"

: "$REPO_ROOT"  # silence unused warning under set -u when used by linters

j() { jq -r "$1" <<<"$CONFIG"; }

SOURCE_CONN=$(j '.source_conn // empty')
TARGET_TPL=$(j '.target_conn_template // empty')
NAME_PREFIX=$(j '.clone.name_prefix // "pg_clone_"')

[ -n "$SOURCE_CONN" ]  || { echo "postgres: .source_conn required" >&2; exit 2; }
[ -n "$TARGET_TPL" ]   || { echo "postgres: .target_conn_template required" >&2; exit 2; }

case "$TARGET_TPL" in
  *"{db}"*) : ;;
  *) echo "postgres: .target_conn_template must contain {db}" >&2; exit 2 ;;
esac

SAFE_SLUG=$(printf '%s' "$SLUG" | tr -c '[:alnum:]_' '_' | cut -c1-32)
CLONE_DB="${NAME_PREFIX}${SAFE_SLUG}"

# Build a maintenance connection by replacing {db} with the postgres
# default DB so we can create the clone DB.
ADMIN_CONN=$(printf '%s' "$TARGET_TPL" | sed "s|{db}|postgres|g")
TARGET_CONN=$(printf '%s' "$TARGET_TPL" | sed "s|{db}|${CLONE_DB}|g")

TMP_DUMP=$(mktemp -t pgclone.XXXXXX.sql)
trap 'rm -f "$TMP_DUMP"' EXIT

echo "postgres: pg_dump → $TMP_DUMP" >&2
pg_dump --no-owner --no-acl --format=plain --dbname="$SOURCE_CONN" > "$TMP_DUMP"

echo "postgres: creating database $CLONE_DB" >&2
psql --dbname="$ADMIN_CONN" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"$CLONE_DB\";"
psql --dbname="$ADMIN_CONN" -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$CLONE_DB\";"

echo "postgres: importing dump into $CLONE_DB" >&2
psql --dbname="$TARGET_CONN" -v ON_ERROR_STOP=1 -f "$TMP_DUMP" >/dev/null

printf 'RUN_ISSUES_DB_CLONE=%s\n' "$CLONE_DB"
