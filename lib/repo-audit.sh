#!/usr/bin/env bash
# lib/repo-audit.sh — the skeleton every whole-repo audit shares: the security
# audit (security-audit.sh, #339) and the coherence audit (coherence-audit.sh,
# #342).
#
# An audit differs from another in WHAT it asks (its prompt, its material, its
# issue text, which findings may start a run). It does not differ in how the
# answer is made trustworthy, so that lives here once (CLAUDE.md §7):
#
#   - the audited state: <remote>/<default-branch> after a bounded fetch
#   - the work area: a temporary DETACHED worktree of that commit, removed on
#     exit; the operator's working tree is never touched
#   - the read-only gate: an agent that moved HEAD or dirtied the worktree
#     rejects the whole audit (exit 3) — two copies of this gate would be two
#     chances for one of them to go missing silently
#   - "not a result" (CLAUDE.md §9): a launch failure, an empty or unparseable
#     answer is exit 3, never "no findings"
#   - the finding loop: fingerprint → plan → write, via lib/finding-issues.sh
#
# The functions share state through globals the calling script also reads:
# REPO REMOTE OWNER_REPO BASE_REF BASE_BRANCH HEAD_SHA WORK WT KEEP_WORK INDEX
# KNOWN RESULT. Diagnostics go to stderr prefixed with REPO_AUDIT_NAME. Each
# function returns the caller's exit code for its failure (2 resolution,
# 3 no result, 4 GitHub), so the script's exit-code space stays its own.
#
# Sourced AFTER source_machine_env (lib/machine-env.sh): claude-call.sh reads
# its defaults at source time (CLAUDE.md §5.5). claude-call.sh carries `set -e`;
# the caller switches it off again after sourcing this file.

_REPO_AUDIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-remote.sh
. "$_REPO_AUDIT_DIR/git-remote.sh"
# shellcheck source=lib/labels.sh
. "$_REPO_AUDIT_DIR/labels.sh"
# shellcheck source=lib/merge-gate.sh
. "$_REPO_AUDIT_DIR/merge-gate.sh"
# shellcheck source=lib/finding-issues.sh
. "$_REPO_AUDIT_DIR/finding-issues.sh"
# shellcheck source=lib/claude-call.sh
. "$_REPO_AUDIT_DIR/claude-call.sh"

repo_audit_say() { printf '%s: %s\n' "${REPO_AUDIT_NAME:-audit}" "$*" >&2; }

# repo_audit_require_tools — rc 2 when git, jq or gh is missing.
repo_audit_require_tools() {
  local tool
  for tool in git jq gh; do
    command -v "$tool" >/dev/null 2>&1 || { repo_audit_say "$tool is required but not installed"; return 2; }
  done
}

# repo_audit_set_repo <path> — sets REPO to the repository root. The path as
# the operator spelled it (logical, symlinks kept) when it is the root: the
# watchlist lookup compares paths as strings, and git's own answer is the
# physical path. rc 2 when <path> is not inside a git repository.
repo_audit_set_repo() {
  local top
  if ! top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || [ -z "$top" ]; then
    repo_audit_say "'$1' is not a git repository"
    return 2
  fi
  if [ "$(cd "$1" && pwd -P)" = "$(cd "$top" && pwd -P)" ]; then
    REPO=$(cd "$1" && pwd)
  else
    REPO="$top"
  fi
}

# repo_audit_resolve <fetch-timeout> — resolve REMOTE of REPO and fetch it; sets
# OWNER_REPO, BASE_REF (<remote>/<branch>), BASE_BRANCH and HEAD_SHA. rc 2 when
# the remote is not a github.com remote, the fetch fails or <remote>/HEAD does
# not resolve.
repo_audit_resolve() {
  if ! OWNER_REPO=$(resolve_remote_to_owner_repo "$REPO" "$REMOTE"); then
    repo_audit_say "remote '$REMOTE' does not exist in $REPO or is not a github.com remote"
    return 2
  fi
  if ! runner_git_fetch_bounded "$(preflight_timeout_bin)" "$1" "$REPO" "$REMOTE" --quiet; then
    repo_audit_say "git fetch $REMOTE failed in $REPO"
    return 2
  fi
  if ! BASE_REF=$(git -C "$REPO" symbolic-ref --short "refs/remotes/$REMOTE/HEAD" 2>/dev/null) || [ -z "$BASE_REF" ]; then
    repo_audit_say "'$REMOTE/HEAD' does not resolve — run 'git remote set-head $REMOTE -a' in $REPO, then retry"
    return 2
  fi
  BASE_BRANCH="${BASE_REF#"$REMOTE"/}"
  HEAD_SHA=$(git -C "$REPO" rev-parse "$BASE_REF" 2>/dev/null)
}

# repo_audit_cleanup — the EXIT trap: remove the worktree, and the work dir
# unless KEEP_WORK=1 (a rejected audit keeps its artifacts for inspection).
repo_audit_cleanup() {
  [ -n "${WT:-}" ] && git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
  git -C "$REPO" worktree prune >/dev/null 2>&1 || true
  [ -n "${WORK:-}" ] || return 0
  if [ "${KEEP_WORK:-0}" = 1 ]; then
    repo_audit_say "artifacts kept for inspection: $WORK"
  else
    rm -rf "$WORK"
  fi
}

# repo_audit_worktree — sets WORK (temp dir) and WT (a detached worktree of
# HEAD_SHA inside it) and installs repo_audit_cleanup as the EXIT trap. rc 2
# when either cannot be created.
repo_audit_worktree() {
  KEEP_WORK=0
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/${REPO_AUDIT_NAME:-audit}.XXXXXX") || { repo_audit_say "cannot create a temp dir"; return 2; }
  WT="$WORK/wt"
  trap repo_audit_cleanup EXIT
  if ! git -C "$REPO" worktree add --detach -q "$WT" "$HEAD_SHA" >/dev/null 2>&1; then
    repo_audit_say "cannot create a worktree of $BASE_REF"
    return 2
  fi
}

# repo_audit_preflight — rc 3 when the agent CLI cannot launch: checked before
# anything costs, and reported as "no audit", never as "no findings".
repo_audit_preflight() {
  local reason
  if reason=$(preflight_claude_cmd_unusable); then
    repo_audit_say "audit agent unavailable: $reason — nothing written"
    return 3
  fi
}

# repo_audit_index <label> — the known findings of <label>: sets INDEX (the
# dedup index, lib/finding-issues.sh) and KNOWN (one line per known issue, for
# the prompt). rc 4 when the listing failed: an empty index would turn every
# known finding into a duplicate, so nothing may be written.
repo_audit_index() {
  INDEX="$WORK/index.tsv"
  if ! finding_issues_index "$OWNER_REPO" "$1" "$INDEX"; then
    repo_audit_say "listing the '$1' issues of $OWNER_REPO failed — nothing written"
    return 4
  fi
  if [ -s "$INDEX" ]; then
    KNOWN=$(awk -F'\t' '{ printf "#%s (%s) %s\n", $3, $4, $5 }' "$INDEX")
  else
    KNOWN="Ei tunnettuja löydöksiä."
  fi
}

# repo_audit_agent <step> <prompt-file> <timeout-secs> — run the audit agent in
# WT and accept its answer only if it left the worktree untouched. Sets RESULT
# to clean | findings; the answer is in $WORK/<step>.out. rc 3 (KEEP_WORK=1)
# when the worktree changed, the agent failed or its answer is empty or
# unparseable — nothing may be written then.
repo_audit_agent() {
  local step="$1" prompt="$2" timeout="$3" arc=0 head_after
  ( cd "$WT" && RUN_ISSUES_CLAUDE_TIMEOUT="$timeout" call_claude "$WORK" "$step" "$prompt" ) >&2 || arc=$?
  repo_audit_say "audit agent returned rc=$arc"

  head_after=$(git -C "$WT" rev-parse HEAD 2>/dev/null)
  if [ "$head_after" != "$HEAD_SHA" ] || [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then
    KEEP_WORK=1
    repo_audit_say "the audit agent changed the worktree (head ${head_after:-?}) although it may only read — audit rejected, nothing written"
    return 3
  fi
  RESULT=$(merge_gate_parse "$WORK/$step.out" "$WORK/$step.exit")
  [ "$arc" -ne 0 ] && RESULT="launch_failed"
  if [ "$RESULT" = "launch_failed" ]; then
    KEEP_WORK=1
    if [ "$arc" -ne 0 ]; then
      repo_audit_say "the audit agent failed (rc=$arc; 127 = did not start, 124 = timeout) — nothing written"
    else
      repo_audit_say "the audit result was empty or unparseable (no consistent MERGE_GATE_RESULT line) — nothing written"
    fi
    return 3
  fi
}

# repo_audit_apply <kind> <dry-run 0|1> <reopen-comment> <key-fn> <labels-fn>
#                  <title-fn> <body-fn>
# Read findings `<origin>|<severity>|<confidence>|<location>|<description>` on
# stdin (origin: agent | scanner) and carry each out. The audit's own parts are
# the four functions:
#
#   <key-fn> <origin> <description>         → "<source>\t<key>" (the fingerprint class)
#   <labels-fn> <severity>                  → the labels CSV, <kind>'s label first
#   <title-fn> <severity> <location> <description>
#   <body-fn> <severity> <confidence> <location> <description> <source> <fingerprint>
#
# Prints one line per finding: <action>\t<severity>\t<location>\t<description>.
# Sets REPO_AUDIT_FINDINGS and REPO_AUDIT_WRITE_FAILED (counts). Uses OWNER_REPO
# and INDEX.
repo_audit_apply() {
  local kind="$1" dry="$2" comment="$3" key_fn="$4" labels_fn="$5" title_fn="$6" body_fn="$7"
  local row origin rest sev conf loc desc sk source key fp labels plan title body res seen=" "
  REPO_AUDIT_FINDINGS=0
  REPO_AUDIT_WRITE_FAILED=0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    origin="${row%%|*}"; rest="${row#*|}"
    IFS='|' read -r sev conf loc desc <<<"$rest"
    desc="${rest#*|*|*|}"
    sk=$("$key_fn" "$origin" "$desc")
    source="${sk%%$'\t'*}"; key="${sk#*$'\t'}"
    fp=$(finding_fingerprint "$source" "$loc" "$key")
    REPO_AUDIT_FINDINGS=$((REPO_AUDIT_FINDINGS + 1))

    if [[ "$seen" == *" $fp "* ]]; then
      printf 'duplicate\t%s\t%s\t%s\n' "$sev" "$loc" "$desc"
      continue
    fi
    seen="$seen$fp "

    labels=$("$labels_fn" "$sev")

    if [ "$dry" = 1 ]; then
      plan=$(finding_issue_plan "$INDEX" "$kind" "$fp")
      case "$plan" in create|reopen*) plan="$plan [$labels]" ;; esac
      printf '%s\t%s\t%s\t%s\n' "$plan" "$sev" "$loc" "$desc"
      continue
    fi

    title=$("$title_fn" "$sev" "$loc" "$desc")
    body=$("$body_fn" "$sev" "$conf" "$loc" "$desc" "$source" "$fp")
    if res=$(finding_issue_apply "$OWNER_REPO" "$INDEX" "$kind" "$fp" "$title" "$body" "$labels" "$comment"); then
      printf '%s\t%s\t%s\t%s\n' "$res" "$sev" "$loc" "$desc"
    else
      REPO_AUDIT_WRITE_FAILED=$((REPO_AUDIT_WRITE_FAILED + 1))
      printf 'FAILED\t%s\t%s\t%s\n' "$sev" "$loc" "$desc"
    fi
  done
}

# repo_audit_poller_env_value <var> — one variable out of poller.env
# (RUN_ISSUES_POLLER_ENV_FILE, default $HOME/.config/run-issues/poller.env),
# read in a subshell so nothing else in the file reaches this process (the
# same pattern as install.sh's poller_env_values). The poller runs an audit
# under that file, so a hand run and a scheduled run of one machine agree.
repo_audit_poller_env_value() {
  local f="${RUN_ISSUES_POLLER_ENV_FILE:-$HOME/.config/run-issues/poller.env}"
  ( exec 3>&1 >/dev/null 2>&1; set +eu; unset "$1"; [ -f "$f" ] && . "$f"; printf '%s' "${!1:-}" >&3 )
}
