#!/usr/bin/env bash
# db-clone/wordpress-mysql.sh — clone (or drop) a WP database via wp db export + mysql.
#
# Args: <repo-root> <slug> <config-json> [clone|cleanup]   (default: clone)
#
# In cleanup mode the clone DB name is recomputed with the same logic as
# clone (name_prefix + sanitized slug) and only the DROP DATABASE branch runs.
# No export/import happens. DROP DATABASE IF EXISTS makes cleanup idempotent.
#
# Config schema (subset of .claude/db-clone.json relevant here):
#   {
#     "type": "wordpress-mysql",
#     "source_db": "wp_example",                  # required
#     "wp_path": ".",                           # path of wp-cli root inside repo, default "."
#     "mysql_user": "root",                     # default "root"
#     "mysql_host": "127.0.0.1",                # default "127.0.0.1"
#     "clone": {
#       "name_prefix": "wp_clone_",             # default "wp_clone_"
#       "exclude_tables": ["wp_options"],       # optional
#       "update_urls": true,                    # optional
#       "url_pair": {                           # required if update_urls
#         "from": "https://prod.example.com",
#         "to":   "https://clone.example.test"
#       }
#     }
#   }
#
# Prints RUN_ISSUES_DB_CLONE=<cloned-db-name> on success.

set -euo pipefail

REPO_ROOT="$1"
SLUG="$2"
CONFIG="$3"
MODE="${4:-clone}"

j() { jq -r "$1" <<<"$CONFIG"; }

SOURCE_DB=$(j '.source_db // empty')
[ -n "$SOURCE_DB" ] || { echo "wordpress-mysql: .source_db required" >&2; exit 2; }

WP_PATH=$(j '.wp_path // "."')
MYSQL_USER=$(j '.mysql_user // "root"')
MYSQL_HOST=$(j '.mysql_host // "127.0.0.1"')
NAME_PREFIX=$(j '.clone.name_prefix // "wp_clone_"')
UPDATE_URLS=$(j '.clone.update_urls // false')
URL_FROM=$(j '.clone.url_pair.from // empty')
URL_TO=$(j '.clone.url_pair.to // empty')

# Sanitize the slug for use as a MySQL identifier.
SAFE_SLUG=$(printf '%s' "$SLUG" | tr -c '[:alnum:]_' '_' | cut -c1-32)
CLONE_DB="${NAME_PREFIX}${SAFE_SLUG}"

WP_DIR="$REPO_ROOT/$WP_PATH"

if [ "$MODE" = "cleanup" ]; then
  echo "wordpress-mysql: dropping $CLONE_DB on $MYSQL_HOST" >&2
  mysql -u "$MYSQL_USER" -h "$MYSQL_HOST" -e "DROP DATABASE IF EXISTS \`$CLONE_DB\`;"
  exit 0
fi

# Collect tables to exclude. wp db export and wp search-replace name the same
# intent differently (--exclude_tables vs --skip-tables), so keep the raw list
# and build the right comma-separated flag per command below.
EXCLUDE_TABLES=()
while IFS= read -r t; do
  [ -n "$t" ] || continue
  EXCLUDE_TABLES+=("$t")
done < <(jq -r '.clone.exclude_tables[]? // empty' <<<"$CONFIG")

# Validate the URL pair before doing any work so we fail fast.
if [ "$UPDATE_URLS" = "true" ]; then
  [ -n "$URL_FROM" ] && [ -n "$URL_TO" ] || {
    echo "wordpress-mysql: clone.url_pair.from/to required when update_urls=true" >&2
    exit 2
  }
fi

TMP_SQL=$(mktemp -t wpclone.XXXXXX.sql)
trap 'rm -f "$TMP_SQL"' EXIT

# Produce the dump that gets imported into the clone. When update_urls is set we
# rewrite the URLs *during export*: `wp search-replace --export` reads the source
# DB read-only and writes an already-rewritten SQL dump to a file (serialized
# values handled correctly by wp-cli). wp-cli has no per-command flag to point at
# a different database, so rewriting on export is what guarantees the change lands
# only in the clone and never mutates the source DB.
if [ "$UPDATE_URLS" = "true" ]; then
  echo "wordpress-mysql: exporting $SOURCE_DB with URL rewrite $URL_FROM → $URL_TO → $TMP_SQL" >&2
  (
    cd "$WP_DIR"
    if [ "${#EXCLUDE_TABLES[@]}" -gt 0 ]; then
      wp search-replace "$URL_FROM" "$URL_TO" \
        --all-tables --skip-columns=guid --report-changed-only \
        --skip-tables="$(IFS=,; echo "${EXCLUDE_TABLES[*]}")" \
        --export="$TMP_SQL"
    else
      wp search-replace "$URL_FROM" "$URL_TO" \
        --all-tables --skip-columns=guid --report-changed-only \
        --export="$TMP_SQL"
    fi
  )
else
  echo "wordpress-mysql: exporting $SOURCE_DB → $TMP_SQL" >&2
  (
    cd "$WP_DIR"
    if [ "${#EXCLUDE_TABLES[@]}" -gt 0 ]; then
      wp db export "$TMP_SQL" "--exclude_tables=$(IFS=,; echo "${EXCLUDE_TABLES[*]}")"
    else
      wp db export "$TMP_SQL"
    fi
  )
fi

echo "wordpress-mysql: creating $CLONE_DB on $MYSQL_HOST" >&2
mysql -u "$MYSQL_USER" -h "$MYSQL_HOST" -e "DROP DATABASE IF EXISTS \`$CLONE_DB\`; CREATE DATABASE \`$CLONE_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

echo "wordpress-mysql: importing dump into $CLONE_DB" >&2
mysql -u "$MYSQL_USER" -h "$MYSQL_HOST" "$CLONE_DB" < "$TMP_SQL"

printf 'RUN_ISSUES_DB_CLONE=%s\n' "$CLONE_DB"
