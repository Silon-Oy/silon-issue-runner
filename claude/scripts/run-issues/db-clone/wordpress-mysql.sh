#!/usr/bin/env bash
# db-clone/wordpress-mysql.sh — clone a WP database via wp db export + mysql.
#
# Args: <repo-root> <slug> <config-json>
#
# Config schema (subset of .claude/db-clone.json relevant here):
#   {
#     "type": "wordpress-mysql",
#     "source_db": "wp_silon",                  # required
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

# Build exclude flags for wp db export.
EXCLUDE_ARGS=()
while IFS= read -r t; do
  [ -n "$t" ] || continue
  EXCLUDE_ARGS+=("--exclude_tables=$t")
done < <(jq -r '.clone.exclude_tables[]? // empty' <<<"$CONFIG")

TMP_SQL=$(mktemp -t wpclone.XXXXXX.sql)
trap 'rm -f "$TMP_SQL"' EXIT

echo "wordpress-mysql: exporting $SOURCE_DB → $TMP_SQL" >&2
(
  cd "$WP_DIR"
  if [ "${#EXCLUDE_ARGS[@]}" -gt 0 ]; then
    wp db export "$TMP_SQL" "${EXCLUDE_ARGS[@]}"
  else
    wp db export "$TMP_SQL"
  fi
)

echo "wordpress-mysql: creating $CLONE_DB on $MYSQL_HOST" >&2
mysql -u "$MYSQL_USER" -h "$MYSQL_HOST" -e "DROP DATABASE IF EXISTS \`$CLONE_DB\`; CREATE DATABASE \`$CLONE_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

echo "wordpress-mysql: importing dump into $CLONE_DB" >&2
mysql -u "$MYSQL_USER" -h "$MYSQL_HOST" "$CLONE_DB" < "$TMP_SQL"

if [ "$UPDATE_URLS" = "true" ]; then
  [ -n "$URL_FROM" ] && [ -n "$URL_TO" ] || {
    echo "wordpress-mysql: clone.url_pair.from/to required when update_urls=true" >&2
    exit 2
  }
  echo "wordpress-mysql: rewriting URLs $URL_FROM → $URL_TO in $CLONE_DB" >&2
  (
    cd "$WP_DIR"
    # Run search-replace against the cloned DB by overriding DB_NAME.
    wp search-replace "$URL_FROM" "$URL_TO" \
      --all-tables \
      --skip-columns=guid \
      --report-changed-only \
      --db_name="$CLONE_DB" 2>/dev/null \
      || wp --url="$URL_FROM" db query "USE \`$CLONE_DB\`;" >/dev/null 2>&1 || true
  )
fi

printf 'RUN_ISSUES_DB_CLONE=%s\n' "$CLONE_DB"
