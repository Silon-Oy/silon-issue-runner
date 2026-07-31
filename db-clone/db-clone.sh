#!/usr/bin/env bash
# db-clone.sh — opt-in database clone dispatcher for /run-issues.
#
# Usage:
#   db-clone.sh <repo-root> <slug>            # clone (legacy form, still works)
#   db-clone.sh clone <repo-root> <slug>      # clone (explicit)
#   db-clone.sh cleanup <repo-root> <slug>    # drop the previously cloned DB
#
#   <slug> is typically the run-id, used as a suffix for the cloned DB.
#
# Reads <repo-root>/.claude/db-clone.json and delegates to a backend
# script based on `.type`. Backends are siblings of this file.
#
# Exit codes:
#   0  clone/cleanup succeeded
#   1  no .claude/db-clone.json present (clone is opt-in; not an error)
#   2  config invalid (bad JSON, missing required fields, or a string value
#      containing a shell metacharacter)
#   3  unknown backend type
#   4  backend reported failure
#
# On a successful clone, writes a single line `RUN_ISSUES_DB_CLONE=<value>`
# to stdout. The orchestrator captures this for downstream tools that need
# the cloned DB identifier (e.g. WP_DB_NAME, compose project name). cleanup
# mode is idempotent: dropping an already-absent clone returns 0.

set -euo pipefail

usage() {
  echo "usage: db-clone.sh [clone|cleanup] <repo-root> <slug>" >&2
  exit 2
}

# Resolve mode without breaking the legacy two-argument form. The orchestrator
# (orchestrate.sh S5) still calls `db-clone.sh <repo-root> <slug>`, so when the
# first argument is not an explicit mode keyword we default to clone.
MODE="clone"
case "${1:-}" in
  clone|cleanup)
    MODE="$1"
    shift
    ;;
esac

[ "$#" -eq 2 ] || usage
REPO_ROOT="$1"
SLUG="$2"

CONFIG_PATH="$REPO_ROOT/.claude/db-clone.json"
if [ ! -f "$CONFIG_PATH" ]; then
  echo "db-clone: no .claude/db-clone.json — skipping $MODE" >&2
  exit 1
fi

if ! jq -e . "$CONFIG_PATH" >/dev/null 2>&1; then
  echo "db-clone: invalid JSON in $CONFIG_PATH" >&2
  exit 2
fi

# Reject config string values containing shell metacharacters. Some backends
# (notably docker-compose.sh) interpolate these values into shell command
# strings built on the host, so a value like `$(...)`, a backtick, `;` or `|`
# would be a shell-injection vector. See README "Turvallisuus". Legitimate
# values — including postgres connection strings such as
# postgres://user:pass@host:5432/db — contain none of these characters.
if jq -r '.. | strings' "$CONFIG_PATH" | grep -qE '[$`;|]'; then
  echo "db-clone: config value contains a shell metacharacter (\$ \` ; |); refusing for safety" >&2
  exit 2
fi

TYPE=$(jq -r '.type // empty' "$CONFIG_PATH")
if [ -z "$TYPE" ]; then
  echo "db-clone: .type missing in $CONFIG_PATH" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$TYPE" in
  wordpress-mysql)
    BACKEND="$SCRIPT_DIR/wordpress-mysql.sh"
    ;;
  postgres)
    BACKEND="$SCRIPT_DIR/postgres.sh"
    ;;
  docker-compose)
    BACKEND="$SCRIPT_DIR/docker-compose.sh"
    ;;
  *)
    echo "db-clone: unknown type '$TYPE'" >&2
    exit 3
    ;;
esac

if [ ! -x "$BACKEND" ]; then
  echo "db-clone: backend not executable: $BACKEND" >&2
  exit 3
fi

CONFIG_JSON=$(cat "$CONFIG_PATH")

if ! "$BACKEND" "$REPO_ROOT" "$SLUG" "$CONFIG_JSON" "$MODE"; then
  echo "db-clone: backend $TYPE $MODE failed" >&2
  exit 4
fi
