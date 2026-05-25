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
