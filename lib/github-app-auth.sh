#!/usr/bin/env bash
# lib/github-app-auth.sh — opt-in GitHub App identity for orchestrator + PR watcher.
#
# Why this exists
# ---------------
# /run-issues posts issue comments, opens PRs, applies labels and pushes commits
# through `gh` and `git`. By default those operations inherit `gh auth`'s
# identity, which is the maintainer's personal account — automation output
# becomes indistinguishable from human output in issues and PR history.
#
# A dedicated bot user would solve the readability problem but consume a paid
# seat in the Silon-Oy org. A GitHub App is seat-free: its installation acts as
# `<app-name>[bot]`, so this module mints short-lived installation access tokens
# and the orchestrator injects them into `gh`/`git` calls.
#
# Two-step auth (per https://docs.github.com/en/apps):
#   1. RS256-sign a JWT with the App's private .pem (max 10 min lifetime).
#   2. POST /app/installations/{id}/access_tokens with the JWT to receive a
#      1-hour `ghs_…` installation token scoped to the App's permissions.
#
# Only step 2's product (the installation token) is what `gh`/`git` use — and
# only in short bursts (issue comment, label, push, pr create). The longest
# operation in /run-issues (the claude implementer call) does NOT use a GitHub
# token at all, so refresh is purely a per-burst concern and runs as a lazy
# disk-cached helper instead of a daemon or timer.
#
# Tooling choice (CLAUDE.md External Dependencies §)
# --------------------------------------------------
# Implemented with `openssl` + `jq` + `curl` — three tools that are already
# present on both Mac dev hosts and audited as part of the OS / brew baseline.
# Rejected alternatives:
#   - `gh ext install <app-auth-extension>`: each candidate had a single
#     maintainer and ad-hoc release cadence; introducing it as a load-bearing
#     dep would violate the External Dependencies rule.
#   - A pinned `pyjwt`/`@octokit/auth-app` helper: adds a language runtime
#     (Python venv or Node tool) to the orchestrator's critical path purely for
#     a ~10-line RS256 sign + one HTTPS POST. Not justified for the surface area.
# openssl + jq + curl keeps the auth path inspectable in pure shell and avoids a
# new runtime in the critical path.
#
# Token cache
# -----------
# Tokens are cached at $RUN_ISSUES_GHA_CACHE_FILE (default
# $XDG_CACHE_HOME/run-issues/github-app-token.json or ~/.cache/...) with mode
# 0600. The cache file lives OUTSIDE any repo so the secret can never end up in
# git/PRs/prompts. A new token is minted only when the cached one has <5 min of
# validity left (RUN_ISSUES_GHA_REFRESH_BUFFER_SECONDS, default 300). Parallel
# runs share the file safely because writes go through tmp+mv (atomic rename).
#
# Surface
# -------
#   gha_enabled            — return 0 iff the three RUN_ISSUES_GITHUB_APP_*
#                            env vars are set AND the .pem file exists+readable.
#                            Used by callers as the opt-in switch ("am I in App
#                            mode?"). Fails closed (returns 1) if the .pem is
#                            unreadable, so misconfiguration cannot silently
#                            fall back to the personal identity.
#   gha_token              — print a valid installation token on stdout.
#                            Mints/refreshes lazily as needed. Exits non-zero
#                            with a diagnostic to stderr on failure (App mode is
#                            opt-in: a configured-but-broken App must NOT
#                            silently fall back, per issue spec edge case 2).
#   gha_with_token <cmd…>  — run a command with GH_TOKEN/GITHUB_TOKEN exported
#                            from gha_token. The token is scoped to the
#                            subprocess via env(1), so `set -x` in this shell
#                            cannot echo it. No-op (runs cmd unchanged) when
#                            gha_enabled is false — making it safe to wrap every
#                            gh call unconditionally.
#   gha_git_push_header    — print the value for `git -c http.extraheader=...`
#                            so callers can splice it into `git push` without
#                            putting the token into the remote URL (which would
#                            leak into `.git/config` and logs).

# This file is a sourced library — every helper guards its side effects so
# stray `set -e` on the caller's side cannot trip them. We intentionally do NOT
# set our own pipefail/set-e to avoid surprising callers that source us.

# ---------- configuration ----------
# Cache file. XDG-style: honour $XDG_CACHE_HOME if set, otherwise ~/.cache.
_gha_default_cache_dir() {
  if [ -n "${XDG_CACHE_HOME:-}" ]; then
    printf '%s/run-issues' "$XDG_CACHE_HOME"
  else
    printf '%s/.cache/run-issues' "$HOME"
  fi
}

# How close to expiry we should pre-emptively refresh. GitHub installation
# tokens are valid 1h; 5 min leaves ample headroom for clock skew and the
# longest realistic burst (push + pr create + label).
RUN_ISSUES_GHA_REFRESH_BUFFER_SECONDS="${RUN_ISSUES_GHA_REFRESH_BUFFER_SECONDS:-300}"

# Allow override for tests (mock token endpoint URL).
RUN_ISSUES_GHA_TOKEN_ENDPOINT_BASE="${RUN_ISSUES_GHA_TOKEN_ENDPOINT_BASE:-https://api.github.com}"

# Logger — best-effort: if the caller hasn't defined a `log` function we fall
# back to a date-prefixed stderr line so diagnostics are not lost.
_gha_log() {
  if declare -F log >/dev/null 2>&1; then
    log "github-app-auth: $*"
  else
    printf '[github-app-auth %s] %s\n' "$(date -u +%FT%TZ)" "$*" >&2
  fi
}

# ---------- public: enabled? ----------
# gha_enabled — 0 iff App mode is configured AND usable. All three env vars
# must be present (set + non-empty) AND the .pem must exist and be readable by
# the current user. Anything else → 1 (caller stays on the personal identity).
gha_enabled() {
  [ -n "${RUN_ISSUES_GITHUB_APP_ID:-}" ] || return 1
  [ -n "${RUN_ISSUES_GITHUB_APP_INSTALLATION_ID:-}" ] || return 1
  [ -n "${RUN_ISSUES_GITHUB_APP_PRIVATE_KEY_PATH:-}" ] || return 1
  if [ ! -f "$RUN_ISSUES_GITHUB_APP_PRIVATE_KEY_PATH" ]; then
    _gha_log "ERROR: private key not found at $RUN_ISSUES_GITHUB_APP_PRIVATE_KEY_PATH (App mode requested but unusable — fail-closed; will NOT silently use the personal gh identity)"
    return 1
  fi
  if [ ! -r "$RUN_ISSUES_GITHUB_APP_PRIVATE_KEY_PATH" ]; then
    _gha_log "ERROR: private key not readable: $RUN_ISSUES_GITHUB_APP_PRIVATE_KEY_PATH (check permissions; chmod 600)"
    return 1
  fi
  # Warn (not fail) if the .pem is world/group-readable. Permission models
  # differ across hosts — we won't refuse to run if the key is e.g. 0644 — but
  # the warning is intentionally loud since this is a secret.
  local perm=""
  if [ "$(uname -s)" = "Darwin" ]; then
    perm=$(stat -f '%Lp' "$RUN_ISSUES_GITHUB_APP_PRIVATE_KEY_PATH" 2>/dev/null || echo "")
  else
    perm=$(stat -c '%a' "$RUN_ISSUES_GITHUB_APP_PRIVATE_KEY_PATH" 2>/dev/null || echo "")
  fi
  case "$perm" in
    600|400|"") : ;;
    *) _gha_log "WARNING: private key $RUN_ISSUES_GITHUB_APP_PRIVATE_KEY_PATH has permissions $perm — recommend 'chmod 600 <key>'" ;;
  esac
  return 0
}

# ---------- internals: base64url + JWT ----------
# RFC 7515 base64url (no padding, +/ → -_).
_gha_b64url() {
  # `openssl base64 -A` keeps the output on a single line; we strip padding and
  # remap the alphabet. Reading stdin lets us pipe binary signatures through
  # without intermediate files.
  openssl base64 -A | tr -d '=' | tr '/+' '_-'
}

# _gha_make_jwt — RS256 JWT signed with the App's private key. iat is set 60s
# in the past to absorb host clock skew (recommended by GitHub docs). exp is
# 540s in the future (max allowed is 600s; staying under the ceiling avoids
# "expiration is too far in the future" errors when the request reaches GitHub).
_gha_make_jwt() {
  local pem="$RUN_ISSUES_GITHUB_APP_PRIVATE_KEY_PATH"
  local app_id="$RUN_ISSUES_GITHUB_APP_ID"
  local now iat exp header header_b64 payload payload_b64 signing_input sig_b64
  now=$(date +%s)
  iat=$((now - 60))
  exp=$((now + 540))
  header='{"alg":"RS256","typ":"JWT"}'
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$app_id")
  header_b64=$(printf '%s' "$header" | _gha_b64url)
  payload_b64=$(printf '%s' "$payload" | _gha_b64url)
  signing_input="${header_b64}.${payload_b64}"
  # openssl reads the message from stdin, writes the raw signature to stdout;
  # we pipe it through _gha_b64url to produce the JWS signature segment.
  if ! sig_b64=$(printf '%s' "$signing_input" \
    | openssl dgst -sha256 -sign "$pem" -binary 2>/dev/null \
    | _gha_b64url); then
    _gha_log "ERROR: openssl failed to sign JWT (check that $pem is a valid RSA private key)"
    return 1
  fi
  if [ -z "$sig_b64" ]; then
    _gha_log "ERROR: empty JWT signature (openssl produced no output)"
    return 1
  fi
  printf '%s.%s' "$signing_input" "$sig_b64"
}

# _gha_cache_file — resolve the cache file path lazily so a test can override
# RUN_ISSUES_GHA_CACHE_FILE before sourcing this library.
_gha_cache_file() {
  if [ -n "${RUN_ISSUES_GHA_CACHE_FILE:-}" ]; then
    printf '%s' "$RUN_ISSUES_GHA_CACHE_FILE"
  else
    printf '%s/github-app-token.json' "$(_gha_default_cache_dir)"
  fi
}

# _gha_cache_valid <file> — 0 iff <file> exists, parses as JSON, has a token,
# and has at least RUN_ISSUES_GHA_REFRESH_BUFFER_SECONDS of validity left AND
# was minted against the currently-configured installation ID.
_gha_cache_valid() {
  local f="$1"
  [ -f "$f" ] || return 1
  if ! jq -e . "$f" >/dev/null 2>&1; then
    return 1
  fi
  local token expires_at installation_id
  token=$(jq -r '.token // empty' "$f")
  expires_at=$(jq -r '.expires_at // empty' "$f")
  installation_id=$(jq -r '.installation_id // empty' "$f")
  [ -n "$token" ] || return 1
  [ -n "$expires_at" ] || return 1
  # If the installation ID changed (re-installed App, switched repo set), the
  # cached token is no longer authoritative — force a refresh.
  if [ -n "$installation_id" ] && [ "$installation_id" != "$RUN_ISSUES_GITHUB_APP_INSTALLATION_ID" ]; then
    return 1
  fi
  # GitHub returns expires_at as ISO-8601 UTC ("2026-05-30T22:45:00Z"). We
  # convert it to epoch for comparison. GNU date and BSD date take different
  # flags; try both. A parse failure is treated as "expired" (safer than
  # treating a corrupt cache as fresh).
  local exp_epoch=""
  exp_epoch=$(date -u -d "$expires_at" +%s 2>/dev/null || \
              date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$expires_at" +%s 2>/dev/null || \
              echo "")
  [ -n "$exp_epoch" ] || return 1
  local now
  now=$(date +%s)
  if [ "$((exp_epoch - now))" -lt "$RUN_ISSUES_GHA_REFRESH_BUFFER_SECONDS" ]; then
    return 1
  fi
  return 0
}

# _gha_cache_write <token> <expires_at_iso> — atomic write of the cache file
# with chmod 600. The write goes through a tmp file in the same directory so
# the rename is atomic on every filesystem (mv across mount points is not).
_gha_cache_write() {
  local token="$1"
  local expires_at="$2"
  local cache_file
  cache_file=$(_gha_cache_file)
  local cache_dir
  cache_dir=$(dirname "$cache_file")
  mkdir -p "$cache_dir"
  # mktemp pattern -> sibling of the cache file. The file is created mode 0600
  # (umask of mktemp + explicit chmod for safety on hosts with a permissive
  # umask).
  local tmp
  tmp=$(mktemp "${cache_file}.XXXXXX") || {
    _gha_log "ERROR: cannot create tmp file next to $cache_file"
    return 1
  }
  chmod 600 "$tmp" 2>/dev/null || true
  # Build the JSON via jq to escape values correctly (the token shouldn't
  # contain anything weird, but we control the JSON shape regardless).
  if ! jq -n \
        --arg token "$token" \
        --arg expires_at "$expires_at" \
        --arg installation_id "$RUN_ISSUES_GITHUB_APP_INSTALLATION_ID" \
        --arg app_id "$RUN_ISSUES_GITHUB_APP_ID" \
        '{token:$token, expires_at:$expires_at, installation_id:$installation_id, app_id:$app_id, minted_at: (now | todateiso8601)}' \
        > "$tmp"; then
    rm -f "$tmp"
    _gha_log "ERROR: jq failed to render cache JSON"
    return 1
  fi
  mv "$tmp" "$cache_file" || {
    rm -f "$tmp"
    _gha_log "ERROR: cannot rename $tmp -> $cache_file"
    return 1
  }
  return 0
}

# _gha_mint_token — JWT → installation token (POST /app/installations/{id}/access_tokens).
# Prints "<token>\t<expires_at>" on stdout, non-zero on failure.
_gha_mint_token() {
  local jwt
  jwt=$(_gha_make_jwt) || return 1
  local url="${RUN_ISSUES_GHA_TOKEN_ENDPOINT_BASE%/}/app/installations/${RUN_ISSUES_GITHUB_APP_INSTALLATION_ID}/access_tokens"
  # The JWT is passed via -H so it never lands in the URL (no query/log leak).
  # --fail-with-body returns non-zero on HTTP errors but still emits the body
  # to stdout so we can quote it back to the caller in a diagnostic.
  local resp http_code body
  resp=$(curl -sS \
    -X POST \
    -H "Authorization: Bearer $jwt" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -w '\n%{http_code}' \
    "$url" 2>&1) || {
    _gha_log "ERROR: curl POST $url failed (network/DNS)"
    return 1
  }
  http_code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  case "$http_code" in
    201|200) ;;
    401)
      _gha_log "ERROR: 401 minting installation token — JWT rejected. Check RUN_ISSUES_GITHUB_APP_ID + private key pairing."
      return 1 ;;
    404)
      _gha_log "ERROR: 404 minting installation token — installation ID $RUN_ISSUES_GITHUB_APP_INSTALLATION_ID not found (App may not be installed in that org / target repo)."
      return 1 ;;
    *)
      _gha_log "ERROR: HTTP $http_code minting installation token (response body: $(printf '%s' "$body" | tr '\n' ' ' | head -c 300))"
      return 1 ;;
  esac
  local token expires_at
  token=$(printf '%s' "$body" | jq -r '.token // empty')
  expires_at=$(printf '%s' "$body" | jq -r '.expires_at // empty')
  if [ -z "$token" ] || [ -z "$expires_at" ]; then
    _gha_log "ERROR: installation token response missing token/expires_at"
    return 1
  fi
  printf '%s\t%s' "$token" "$expires_at"
}

# ---------- public: get a token ----------
# gha_token — print a valid installation token on stdout (no trailing newline so
# `tok=$(gha_token)` works without trimming). Non-zero exit + stderr diagnostic
# on failure: App mode is opt-in, and the spec edge case 2 explicitly requires
# fail-fast over silent fallback.
#
# Concurrency: two parallel orchestrator runs may both notice an expired cache
# and race to mint. Both will write through `mktemp + mv` to the same final
# path, so the rename is atomic — the second writer just clobbers the first
# writer's identical-shape file. No corruption, no torn reads.
gha_token() {
  if ! gha_enabled; then
    _gha_log "ERROR: gha_token called but App mode is not enabled"
    return 1
  fi
  local cache_file
  cache_file=$(_gha_cache_file)
  if _gha_cache_valid "$cache_file"; then
    jq -r '.token' "$cache_file"
    return 0
  fi
  local minted token expires_at
  minted=$(_gha_mint_token) || return 1
  token="${minted%%$'\t'*}"
  expires_at="${minted##*$'\t'}"
  _gha_cache_write "$token" "$expires_at" || return 1
  printf '%s' "$token"
}

# ---------- public: run a command with token in the env ----------
# gha_with_token <cmd...> — execute <cmd...> with GH_TOKEN/GITHUB_TOKEN set
# from gha_token, *only* in that subprocess. When App mode is OFF this is a
# no-op pass-through (cmd runs with the caller's environment) — making it safe
# to wrap every gh invocation in the orchestrator unconditionally without
# regressing the gh-CLI default.
#
# The token is exported via env(1) rather than `GH_TOKEN=… cmd` to keep it out
# of any `set -x` trace on this shell. (env(1) prints argv on a trace, but only
# the program name + the static "GH_TOKEN=" prefix is in argv; the value is
# under env's argv which is not echoed by `set -x` on the surrounding shell.)
#
# We set BOTH GH_TOKEN (preferred by `gh`) and GITHUB_TOKEN (used by some other
# tools and by `gh` as a fallback). `gh` only reads GH_TOKEN from the env when
# present, so this overrides `gh auth login`'s stored credential.
gha_with_token() {
  if ! gha_enabled; then
    "$@"
    return $?
  fi
  local tok
  if ! tok=$(gha_token); then
    return 1
  fi
  GH_TOKEN="$tok" GITHUB_TOKEN="$tok" "$@"
}

# ---------- public: git push header ----------
# gha_git_push_header — print the value for `git -c http.extraheader="<this>"`
# so callers can authenticate `git push` as the App without putting the token
# into the remote URL (which would land in .git/config and any `git remote -v`
# / fetch log). Prints an empty line and returns non-zero when App mode is OFF
# so the caller can branch without parsing exit codes.
#
# Usage:
#   header=$(gha_git_push_header) || header=""
#   if [ -n "$header" ]; then
#     git -c http.extraheader="$header" push ...
#   else
#     git push ...
#   fi
gha_git_push_header() {
  if ! gha_enabled; then
    return 1
  fi
  local tok
  if ! tok=$(gha_token); then
    return 1
  fi
  # GitHub accepts "Authorization: Bearer ghs_..." for installation tokens.
  # We deliberately do NOT print this line to any log (the caller assigns it
  # to a local and passes it to `git -c`).
  printf 'Authorization: Bearer %s' "$tok"
}

# ---------- public: clear cache (testing / forced refresh) ----------
gha_clear_cache() {
  local f
  f=$(_gha_cache_file)
  [ -f "$f" ] && rm -f "$f"
  return 0
}
