#!/usr/bin/env bash
# escape-trace.sh — where did the found defects come from? A read-only trace of
# finding issues' `path:line` locations to the PR that last changed each line
# (issue #389).
#
# Audits (security-audit.sh, coherence-audit.sh) and bug reports name locations,
# but nothing ties a finding to the run that produced it, so "how many of these
# did the runner write?" took a hand-made sample. This script does it: for every
# location of the given issues it runs `git blame` at a commit, asks GitHub which
# PR the commit came from and classifies the location (lib/escape-trace.sh):
# runner (a runner PR's, RUNNER_BRANCH_PREFIX), peritty (inherited, not a
# runner PR's) or tuntematon (no line to blame, or GitHub could not answer).
#
# READ-ONLY, by contract: it writes nothing to the repo nor to GitHub. Every gh
# call is a GET `gh api`; blame runs on the local clone with no fetch (a fetch
# writes refs). The only output is the report on stdout; warnings go to stderr.
#
# The blamed commit, per issue: --at > the issue body's "Auditoitu commit:" SHA
# when that commit exists locally (otherwise a warning and the default) >
# refs/remotes/<remote>/HEAD (the default branch's tip as last fetched).
#
# Cost (CLAUDE.md §5.2, §5.4): issues are read over REST (one call per --issues
# number, or one paginated label listing), never search. One
# `commits/<sha>/pulls` call per UNIQUE blamed commit, cached for the run. Only
# when GitHub knows no PR for a commit and its subject carries a bare `(#N)`
# (no `Auto:` prefix) is `pulls/<N>` read — once per unique N, cached too. A
# rate-limit refusal (§5.1, textual) stops all further calls; the rest of the
# locations are reported as tuntematon.
#
# Usage:
#   escape-trace.sh --repo <path> (--issues <N,N,...> | --label <label>)
#                   [--at <sha>] [--remote <name>]
#
#   --repo <path>      local clone of the repo the issues are in (required).
#   --issues <list>    comma-separated issue numbers.
#   --label <label>    every issue carrying <label> (state=all; PRs dropped).
#   --at <rev>         blame at <rev> for every issue (overrides the body SHA).
#   --remote <name>    the GitHub remote. Default origin.
#
# Output: a header row, then one tab-separated row per location:
#   location  commit  pr  class  method  issue  source  note
# location is `path:line`, commit the short SHA (or -), pr the PR number (or -),
# class runner|peritty|tuntematon, method pr-api|auto-prefix|msg-ref|-, issue
# the runner PR's issue (or -), source the finding issue `#N`, note the reason
# for tuntematon (empty otherwise). A summary of counts and shares follows,
# with one line on what blame cannot tell.
#
# Exit codes (own space):
#   0  report produced (also when the issues name no locations)
#   1  usage error (unknown flag, missing or bad value, --issues with --label,
#      --at that is not a commit)
#   2  --repo is not a git work tree, the remote is not a github.com remote,
#      <remote>/HEAD does not resolve without --at, or git/gh/jq is missing
#   3  reading the issues from GitHub failed
#
# Env: none of its own.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Windows/Git Bash: LF jq output (lib/jq-binary.sh).
# shellcheck source=lib/jq-binary.sh
. "$SCRIPT_DIR/lib/jq-binary.sh"
# shellcheck source=lib/git-remote.sh
. "$SCRIPT_DIR/lib/git-remote.sh"
# lib/git-remote.sh turns on errexit; this script reports per location and must
# not stop at the first failing lookup.
set +e
# shellcheck source=lib/rate-limit.sh
. "$SCRIPT_DIR/lib/rate-limit.sh"
# shellcheck source=lib/runner-pr.sh
. "$SCRIPT_DIR/lib/runner-pr.sh"
# shellcheck source=lib/escape-trace.sh
. "$SCRIPT_DIR/lib/escape-trace.sh"

usage() { sed -n '/^# Usage:/,/^# Output:/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }
die() { echo "escape-trace: $2" >&2; exit "$1"; }
warn() { echo "escape-trace: WARNING: $*" >&2; }

REPO="" ISSUES="" LABEL="" AT="" REMOTE="origin"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo|--issues|--label|--at|--remote)
      [ $# -ge 2 ] && [ -n "$2" ] || die 1 "$1 needs a value"
      case "$1" in
        --repo) REPO="$2" ;; --issues) ISSUES="$2" ;; --label) LABEL="$2" ;;
        --at) AT="$2" ;; --remote) REMOTE="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die 1 "unknown argument: $1" ;;
  esac
done
[ -n "$REPO" ] || die 1 "--repo is required"
if [ -n "$ISSUES" ] && [ -n "$LABEL" ]; then die 1 "--issues and --label are exclusive"; fi
[ -n "$ISSUES" ] || [ -n "$LABEL" ] || die 1 "one of --issues or --label is required"
if [ -n "$ISSUES" ]; then
  printf '%s' "$ISSUES" | grep -Eq '^[0-9]+(,[0-9]+)*$' || die 1 "--issues must be N,N,...: $ISSUES"
fi

for t in git gh jq; do command -v "$t" >/dev/null 2>&1 || die 2 "$t is not installed"; done
[ -d "$REPO" ] && git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die 2 "not a git work tree: $REPO"
OWNER_REPO=$(resolve_remote_to_owner_repo "$REPO" "$REMOTE") \
  || die 2 "remote '$REMOTE' does not exist in $REPO or is not a github.com remote"

DEFAULT_SHA=""
if [ -n "$AT" ]; then
  AT=$(git -C "$REPO" rev-parse --verify --quiet "$AT^{commit}") || die 1 "--at is not a commit in $REPO"
else
  DEFAULT_SHA=$(git -C "$REPO" rev-parse --verify --quiet "refs/remotes/$REMOTE/HEAD^{commit}") \
    || die 2 "'$REMOTE/HEAD' does not resolve — run 'git remote set-head $REMOTE -a' in $REPO, then retry"
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/escape-trace.XXXXXX") || die 2 "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/commit" "$WORK/pr"

# ---- issues -------------------------------------------------------------------
# One {number, body} JSON object per line in $WORK/issues.jsonl.
ISSUES_FILE="$WORK/issues.jsonl"
if [ -n "$ISSUES" ]; then
  for n in $(printf '%s' "$ISSUES" | tr ',' ' '); do
    gh api "repos/$OWNER_REPO/issues/$n" --jq '{number, body: (.body // "")}' \
      >>"$ISSUES_FILE" 2>"$WORK/err" || die 3 "reading issue #$n failed: $(head -c 300 "$WORK/err")"
  done
else
  label_q=$(jq -rn --arg l "$LABEL" '$l | @uri')
  gh api --paginate "repos/$OWNER_REPO/issues?labels=$label_q&state=all&per_page=100" \
    --jq '.[] | select(.pull_request | not) | {number, body: (.body // "")}' \
    >"$ISSUES_FILE" 2>"$WORK/err" || die 3 "listing issues labelled '$LABEL' failed: $(head -c 300 "$WORK/err")"
fi

# ---- GitHub lookups, cached for the run ----------------------------------------
# The rate-limit stop is a file, not a variable: the lookups run in command
# substitutions, whose assignments would not reach the next lookup.
RATE_LIMITED="$WORK/rate-limited"

# gh_get <cache-file> <path> — GET <path> into <cache-file> once. rc 1 on failure,
# rc 2 when GitHub answered 404 (the failure is cached as well, so nothing is
# asked twice); the reason is in <cache-file>.why.
gh_get() {
  local cache="$1" path="$2"
  [ -f "$cache.notfound" ] && return 2
  [ -f "$cache" ] && { [ -f "$cache.fail" ] && return 1; return 0; }
  if [ -f "$RATE_LIMITED" ]; then : >"$cache"; : >"$cache.fail"; echo "kutsuraja" >"$cache.why"; return 1; fi
  if gh api "$path" >"$cache" 2>"$cache.err"; then return 0; fi
  : >"$cache.fail"
  if grep -q 'HTTP 404' "$cache.err"; then
    : >"$cache.notfound"; echo "ei-löydy" >"$cache.why"; return 2
  fi
  if rate_limit_matches "$(cat "$cache.err")"; then
    : >"$RATE_LIMITED"; echo "kutsuraja" >"$cache.why"
    warn "GitHub rate limit — no further calls this run"
  else
    echo "api-virhe" >"$cache.why"
  fi
  return 1
}

# commit_pr <sha> — "<pr|-> <head-ref|->" of the commit's associated PR (a runner
# head first, else the first PR). rc 1 when the call failed.
commit_pr() {
  local cache="$WORK/commit/$1"
  gh_get "$cache" "repos/$OWNER_REPO/commits/$1/pulls" || return 1
  jq -r --arg p "$RUNNER_BRANCH_PREFIX" '
    if type == "array" and length > 0 then
      ((map(select((.head.ref // "") | startswith($p))) + .) | first
       | "\(.number) \(.head.ref // "-")")
    else "- -" end' "$cache" 2>/dev/null || echo "- -"
}

# pr_head <n> — the head ref of PR <n>, `-` when the repo has no such PR (404:
# the number is an issue's, or another repo's — history carried over from
# elsewhere), or `?` when it could not be read.
pr_head() {
  local cache="$WORK/pr/$1" rc=0
  gh_get "$cache" "repos/$OWNER_REPO/pulls/$1" || rc=$?
  case "$rc" in 0) ;; 2) echo '-'; return 0 ;; *) echo '?'; return 0 ;; esac
  jq -r '.head.ref // "-"' "$cache" 2>/dev/null || echo '?'
}

# ---- trace ----------------------------------------------------------------------
printf 'location\tcommit\tpr\tclass\tmethod\tissue\tsource\tnote\n'
N_RUNNER=0 N_PERITTY=0 N_TUNTEMATON=0

while IFS= read -r issue_json; do
  [ -n "$issue_json" ] || continue
  src=$(jq -r '.number' <<<"$issue_json")
  body=$(jq -r '.body' <<<"$issue_json")
  sha="$AT"
  if [ -z "$sha" ]; then
    sha="$DEFAULT_SHA"
    body_sha=$(escape_trace_audited_sha "$body")
    if [ -n "$body_sha" ]; then
      if full=$(git -C "$REPO" rev-parse --verify --quiet "$body_sha^{commit}"); then
        sha="$full"
      else
        warn "#$src: audited commit $body_sha is not in $REPO — blaming $REMOTE/HEAD instead"
      fi
    fi
  fi

  while IFS="$(printf '\t')" read -r path line; do
    [ -n "$path" ] || continue
    commit="-" pr="-" issue="-" note="" api=fail head="-" kind="-" mhead="-" blame=fail
    if c=$(git -C "$REPO" blame --porcelain -L "$line,$line" "$sha" -- "$path" 2>/dev/null | head -n1 | cut -d' ' -f1) \
        && [ -n "$c" ]; then
      blame=ok; commit="$c"
      if prinfo=$(commit_pr "$commit"); then
        api=ok
        pr="${prinfo%% *}"; head="${prinfo#* }"
        if [ "$head" = - ]; then
          subject=$(git -C "$REPO" log -1 --format=%s "$commit" 2>/dev/null)
          link=$(escape_trace_msg_link "$subject")
          kind="${link%% *}"; [ -n "$link" ] || kind="-"
          case "$kind" in
            auto-prefix)
              read -r _ issue pr <<<"$link" ;;
            msg-ref)
              read -r _ pr <<<"$link"; mhead=$(pr_head "$pr")
              [ "$mhead" = - ] && pr="-"   # not a PR of this repo
              [ "$mhead" = '?' ] && note="pr-#$pr:$(cat "$WORK/pr/$pr.why" 2>/dev/null || echo api-virhe)" ;;
          esac
        fi
      else
        note=$(cat "$WORK/commit/$commit.why" 2>/dev/null || echo api-virhe)
      fi
    else
      if git -C "$REPO" cat-file -e "$sha:$path" 2>/dev/null; then note="ei-riviä"; else note="ei-tiedostoa"; fi
    fi
    read -r class method <<<"$(escape_trace_classify "$blame" "$api" "$head" "$kind" "$mhead")"
    # The runner PR's issue: from its head branch, or from the `Auto:` subject.
    # Any other class has no runner issue; tuntematon names no PR either.
    case "$method" in
      pr-api)  issue=$(escape_trace_issue_from_branch "$head") ;;
      msg-ref) issue=$(escape_trace_issue_from_branch "$mhead") ;;
      auto-prefix) ;;
      *) issue="-"; [ "$class" = tuntematon ] && pr="-" ;;
    esac
    [ -n "$issue" ] || issue="-"
    case "$class" in
      runner) N_RUNNER=$((N_RUNNER + 1)) ;;
      peritty) N_PERITTY=$((N_PERITTY + 1)) ;;
      *) N_TUNTEMATON=$((N_TUNTEMATON + 1)) ;;
    esac
    short="-"; [ "$commit" = - ] || short="${commit:0:12}"
    printf '%s:%s\t%s\t%s\t%s\t%s\t%s\t#%s\t%s\n' \
      "$path" "$line" "$short" "$pr" "$class" "$method" "$issue" "$src" "$note"
  done < <(escape_trace_refs "$body")
done <"$ISSUES_FILE"

# ---- summary --------------------------------------------------------------------
TOTAL=$((N_RUNNER + N_PERITTY + N_TUNTEMATON))
share() { if [ "$TOTAL" -gt 0 ]; then awk -v n="$1" -v t="$TOTAL" 'BEGIN { printf "%.1f", 100 * n / t }'; else echo "0.0"; fi; }
echo
echo "Yhteenveto ($TOTAL viittausta):"
printf '  runner      %4d  %5s %%\n' "$N_RUNNER" "$(share "$N_RUNNER")"
printf '  peritty     %4d  %5s %%\n' "$N_PERITTY" "$(share "$N_PERITTY")"
printf '  tuntematon  %4d  %5s %%\n' "$N_TUNTEMATON" "$(share "$N_TUNTEMATON")"
echo "Rajoitus: blame kertoo viimeisimmän muuttajan, ei aina vian aiheuttajaa; puuttuvalla tarkistuksella ei ole riviä."
exit 0
