#!/usr/bin/env bash
# lib/env-bootstrap.sh — package-manager detection for the fail-fast env
# bootstrap gate (orchestrate.sh S7b).
#
# Kept as a pure, side-effect-free function so it can be unit-tested directly
# (tests/test-env-bootstrap.sh) without driving the whole orchestrator. The
# orchestrator sources this file and wraps detect_package_manager in
# run_env_bootstrap, which performs the actual install + finalization.

set -euo pipefail

# detect_package_manager <dir> — echo the package manager to use for <dir>,
# resolved from the lockfile at the directory root. Echoes one of:
#   pnpm   — pnpm-lock.yaml present
#   yarn   — yarn.lock present
#   npm    — package-lock.json present, OR a package.json with no recognized
#            lockfile (npm install tolerates a missing lockfile)
#   ""     — no package.json: nothing to bootstrap (the no-op case, e.g. the
#            dotfiles repo itself). The caller treats empty as "skip".
#
# Lockfile precedence (pnpm > yarn > npm) is deliberate: in a monorepo the root
# lockfile decides the manager. Pure: reads the filesystem, mutates nothing.
detect_package_manager() {
  local dir="$1"
  [ -f "$dir/package.json" ] || { printf '%s' ""; return 0; }
  if [ -f "$dir/pnpm-lock.yaml" ]; then
    printf '%s' "pnpm"
  elif [ -f "$dir/yarn.lock" ]; then
    printf '%s' "yarn"
  elif [ -f "$dir/package-lock.json" ]; then
    printf '%s' "npm"
  else
    # package.json but no recognized lockfile: npm install works without one.
    printf '%s' "npm"
  fi
}

# detect_composer <dir> — echo "composer" when a composer.lock is present at the
# directory root (meaning `composer install` must run to materialize vendor/),
# else "". This is the PHP/Composer counterpart of detect_package_manager and is
# deliberately INDEPENDENT of it: a Bedrock-style WordPress repo carries BOTH a
# composer.lock (PHP deps + the WP core under web/wp/) and a JS lockfile
# (package-lock.json for the front-end build), so the orchestrator runs both.
# composer.lock is the canonical signal — `composer install` needs a lockfile to
# produce a deterministic vendor/ tree. Pure: reads the filesystem, mutates
# nothing.
detect_composer() {
  local dir="$1"
  if [ -f "$dir/composer.lock" ]; then
    printf '%s' "composer"
  else
    printf '%s' ""
  fi
}

# detect_node_version <dir> — echo the Node version the target repo pins in
# <dir>/.nvmrc (trimmed of surrounding whitespace), or "" when the directory has
# no .nvmrc (or the file is blank).
#
# The empty return is the no-op case (issue #287): the repo does not pin a Node
# version, so the run keeps whatever Node is already on PATH — behaviour
# unchanged from before this file learned to read .nvmrc. The orchestrator
# (select_node_runtime) treats empty as "keep PATH node, source=default".
#
# The content is returned VERBATIM minus whitespace: nvm accepts every form an
# .nvmrc may hold — "22", "v22", "22.1.0", "lts/hydrogen", "lts/*", "node" — so
# normalizing further would mean second-guessing nvm's own resolver. The caller
# hands the string straight to `nvm use`. Pure: reads the filesystem, mutates
# nothing (the sibling of detect_package_manager / detect_composer).
detect_node_version() {
  local dir="$1"
  local f="$dir/.nvmrc"
  [ -f "$f" ] || { printf '%s' ""; return 0; }
  # First non-blank line, leading/trailing whitespace stripped. .nvmrc is
  # conventionally a single line; tolerating a trailing newline or a hand-edited
  # blank line keeps the file from resolving to an empty version.
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"   # strip leading whitespace
    line="${line%"${line##*[![:space:]]}"}"   # strip trailing whitespace
    if [ -n "$line" ]; then
      printf '%s' "$line"
      return 0
    fi
  done < "$f"
  printf '%s' ""
}
