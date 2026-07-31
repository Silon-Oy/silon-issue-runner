#!/usr/bin/env bash
# db-clone/docker-compose.sh — clone (or drop) a DB inside a compose service.
#
# Args: <repo-root> <slug> <config-json> [clone|cleanup]   (default: clone)
#
# In cleanup mode the clone DB name is recomputed with the same logic as
# clone (name_prefix + sanitized slug) and only the DROP DATABASE branch runs.
# No dump/import happens. DROP DATABASE IF EXISTS is idempotent, but if the
# compose stack is down the `exec` fails and we return non-zero — the
# dispatcher maps that to RC=4 (drop failed) without crashing the caller.
#
# Config schema:
#   {
#     "type": "docker-compose",
#     "compose_file": "docker-compose.yml",       # default "docker-compose.yml"
#     "original_project": "silon",                # required (compose -p value)
#     "db_service": "db",                         # required
#     "db_engine": "mysql",                       # required, "mysql" or "postgres"
#     "db_user_env": "MYSQL_ROOT_PASSWORD_USER",  # env var containing the user
#     "db_pass_env": "MYSQL_ROOT_PASSWORD",       # env var containing the password
#     "source_db_env": "MYSQL_DATABASE",          # env var with the source DB name
#     "clone": {
#       "name_prefix": "clone_"
#     }
#   }
#
# Creates a clone DB inside the SAME db service (not a separate compose
# project). Full project cloning (a separate <original>-clone-<slug>
# compose project with its own containers, volumes, networks and ports)
# is a DELIBERATE non-goal, not an unfinished feature: it has zero current
# consumers and the in-service clone never opens new ports, so parallel
# worktrees can't collide. The evaluation, trigger condition and future
# design path live in docs/design/docker-compose-full-project-clone.md
# (issue #11). Here we report the new in-service DB name.
#
# Prints RUN_ISSUES_DB_CLONE=<cloned-db-name> on success.

set -euo pipefail

REPO_ROOT="$1"
SLUG="$2"
CONFIG="$3"
MODE="${4:-clone}"

j() { jq -r "$1" <<<"$CONFIG"; }

COMPOSE_FILE=$(j '.compose_file // "docker-compose.yml"')
ORIGINAL_PROJECT=$(j '.original_project // empty')
DB_SERVICE=$(j '.db_service // empty')
DB_ENGINE=$(j '.db_engine // empty')
SOURCE_DB_ENV=$(j '.source_db_env // empty')
USER_ENV=$(j '.db_user_env // empty')
PASS_ENV=$(j '.db_pass_env // empty')
NAME_PREFIX=$(j '.clone.name_prefix // "clone_"')

[ -n "$ORIGINAL_PROJECT" ] || { echo "docker-compose: .original_project required" >&2; exit 2; }
[ -n "$DB_SERVICE" ]       || { echo "docker-compose: .db_service required"       >&2; exit 2; }
[ -n "$DB_ENGINE" ]        || { echo "docker-compose: .db_engine required"        >&2; exit 2; }
[ -n "$SOURCE_DB_ENV" ]    || { echo "docker-compose: .source_db_env required"    >&2; exit 2; }

SAFE_SLUG=$(printf '%s' "$SLUG" | tr -c '[:alnum:]_' '_' | cut -c1-32)
CLONE_DB="${NAME_PREFIX}${SAFE_SLUG}"

# Compose invocation prefix. We keep --project-name explicit so we don't
# rely on the user's current shell having the right working directory.
COMPOSE_PREFIX=(
  docker compose
  --project-name "$ORIGINAL_PROJECT"
  --file "$REPO_ROOT/$COMPOSE_FILE"
)

# A full project clone would derive its own compose project name here, e.g.
#   CLONE_PROJECT="${ORIGINAL_PROJECT}-clone-${SAFE_SLUG}"
# That path is deferred by design — see the header comment and
# docs/design/docker-compose-full-project-clone.md.

# Run a command inside the db service container. Credentials are pulled
# from the container's own environment (env var indirection), so they
# never appear on the host shell command line.
db_run_in_container() {
  "${COMPOSE_PREFIX[@]}" exec -T "$DB_SERVICE" "$@"
}

case "$DB_ENGINE" in
  mysql)
    USER_EXPR="\${$USER_ENV:-root}"
    PASS_EXPR="\${$PASS_ENV:-}"
    SOURCE_EXPR="\${$SOURCE_DB_ENV:-}"
    if [ "$MODE" = "cleanup" ]; then
      echo "docker-compose/mysql: dropping $CLONE_DB" >&2
      db_run_in_container sh -c "
        set -e
        : \"$USER_EXPR\"
        : \"$PASS_EXPR\"
        mysql -u\"$USER_EXPR\" -p\"$PASS_EXPR\" -e \"DROP DATABASE IF EXISTS \\\`$CLONE_DB\\\`;\"
      "
      exit 0
    fi
    echo "docker-compose/mysql: cloning \$$SOURCE_DB_ENV → $CLONE_DB" >&2
    db_run_in_container sh -c "
      set -e
      : \"$USER_EXPR\"
      : \"$PASS_EXPR\"
      : \"$SOURCE_EXPR\"
      mysql -u\"$USER_EXPR\" -p\"$PASS_EXPR\" -e \"DROP DATABASE IF EXISTS \\\`$CLONE_DB\\\`; CREATE DATABASE \\\`$CLONE_DB\\\`;\"
      mysqldump -u\"$USER_EXPR\" -p\"$PASS_EXPR\" \"$SOURCE_EXPR\" | mysql -u\"$USER_EXPR\" -p\"$PASS_EXPR\" \"$CLONE_DB\"
    "
    ;;
  postgres)
    USER_EXPR="\${$USER_ENV:-postgres}"
    SOURCE_EXPR="\${$SOURCE_DB_ENV:-}"
    if [ "$MODE" = "cleanup" ]; then
      echo "docker-compose/postgres: dropping $CLONE_DB" >&2
      db_run_in_container sh -c "
        set -e
        : \"$USER_EXPR\"
        psql -U \"$USER_EXPR\" -d postgres -c \"DROP DATABASE IF EXISTS \\\"$CLONE_DB\\\";\"
      "
      exit 0
    fi
    echo "docker-compose/postgres: cloning \$$SOURCE_DB_ENV → $CLONE_DB" >&2
    db_run_in_container sh -c "
      set -e
      : \"$USER_EXPR\"
      : \"$SOURCE_EXPR\"
      psql -U \"$USER_EXPR\" -d postgres -c \"DROP DATABASE IF EXISTS \\\"$CLONE_DB\\\";\"
      psql -U \"$USER_EXPR\" -d postgres -c \"CREATE DATABASE \\\"$CLONE_DB\\\" TEMPLATE \\\"$SOURCE_EXPR\\\";\"
    "
    ;;
  *)
    echo "docker-compose: unsupported db_engine '$DB_ENGINE'" >&2
    exit 2
    ;;
esac

printf 'RUN_ISSUES_DB_CLONE=%s\n' "$CLONE_DB"
