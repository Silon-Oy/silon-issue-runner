#!/usr/bin/env bash
# lib/escape-trace.sh — the pure parsers and the class decision behind
# escape-trace.sh (issue #389): where did a found defect come from?
#
# A finding issue (an audit's, or a bug report) names `path:line` locations. Each
# one is blamed at a commit, and the commit is tied to a PR. The class answers
# "did the runner write this line?":
#
#   runner      the commit belongs to a runner PR (head branch RUNNER_BRANCH_PREFIX)
#   peritty     the commit is not a runner PR's (inherited code, or a human's PR)
#   tuntematon  the line could not be blamed or the PR could not be read
#
# How the commit was tied to a runner PR is the method:
#
#   pr-api       GitHub's commit → PR association named a runner head branch
#   auto-prefix  no association; the subject starts `Auto:` — the runner's PR
#                title (orchestrate.sh) survives a squash merge as the subject
#   msg-ref      no association; the subject's last `(#N)` names a PR whose head
#                branch is the runner's
#
# The subject's `(#N)` reading: orchestrate.sh titles a PR "Auto: <title> (#ISSUE)"
# and a squash merge appends " (#PR)", so the FIRST reference of an `Auto:`
# subject is the issue and the LAST one (when there are two or more) is the PR.
# Without `Auto:` the last reference is taken as the PR.
#
# Sourced; defines functions only and does no top-level work. Needs
# lib/runner-pr.sh (sourced here if not yet loaded). The Evolution digest's
# trace input is meant to reuse these functions as they are.

if [ -z "${RUNNER_BRANCH_PREFIX:-}" ]; then
  # shellcheck source=runner-pr.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/runner-pr.sh"
fi

# escape_trace_refs <body> — the `path:line` locations of <body>, one
# "<path>\t<line>" row each, in order of first appearance and deduplicated.
# Accepts `path:12`, `path:12-14` and `path:L12` (the start line is used), in
# backticks or bare. A path must hold a `/` or a `.` (so `12:30` is not one), a
# leading `./` is dropped, and URLs are skipped whole (a `host/x:12` inside a
# URL is a link, not a location).
escape_trace_refs() {
  printf '%s\n' "${1:-}" \
    | sed -E 's#[A-Za-z][A-Za-z0-9+.-]*://[^[:space:])>`"]*##g' \
    | grep -oE '[A-Za-z0-9_./@+-]+:L?[0-9]+(-L?[0-9]+)?' \
    | sed -E -e 's#^(\./)+##' -e 's/:L?([0-9]+)(-L?[0-9]+)?$/	\1/' \
    | awk -F'\t' '$1 ~ /[\/.]/ && $1 !~ /^[.]+$/ && $2 > 0 && !seen[$0]++'
  return 0
}

# escape_trace_audited_sha <body> — the commit an audit audited, from the
# finding issue's "Auditoitu commit: `<sha>`" line (security-audit.sh,
# coherence-audit.sh). Prints nothing when the line is absent.
escape_trace_audited_sha() {
  printf '%s\n' "${1:-}" | grep -m1 'Auditoitu commit:' \
    | grep -oE '[0-9a-f]{7,40}' | head -n1
  return 0
}

# escape_trace_msg_link <subject> — what a commit subject says about its PR:
#   "auto-prefix <issue|-> <pr|->"  an `Auto:` subject
#   "msg-ref <pr>"                  any other subject with a `(#N)` reference
# and nothing when the subject says nothing.
escape_trace_msg_link() {
  local subject="${1:-}" nums first last count
  nums=$(printf '%s\n' "$subject" | grep -oE '\(#[0-9]+\)' | tr -d '(#)') || nums=""
  count=$(printf '%s\n' "$nums" | grep -c '[0-9]') || count=0
  first=$(printf '%s\n' "$nums" | head -n1)
  last=$(printf '%s\n' "$nums" | tail -n1)
  case "$subject" in
    Auto:*)
      if [ "$count" -ge 2 ]; then printf 'auto-prefix %s %s\n' "$first" "$last"
      elif [ "$count" -eq 1 ]; then printf 'auto-prefix %s -\n' "$first"
      else printf 'auto-prefix - -\n'; fi ;;
    *)
      if [ "$count" -ge 1 ]; then printf 'msg-ref %s\n' "$last"; fi ;;
  esac
  return 0
}

# escape_trace_issue_from_branch <head-ref> — the issue number of a runner head
# branch (RUNNER_BRANCH_PREFIX<ts>-<org>-<repo>-issue-<N>-<slug>, orchestrate.sh).
# The first `-issue-<digits>` segment wins, so a repo name holding `-issue-`
# (`claude-issue-runner`) is passed over. Prints nothing for any other branch.
escape_trace_issue_from_branch() {
  local ref="${1:-}" rest n
  case "$ref" in "$RUNNER_BRANCH_PREFIX"*) ;; *) return 0 ;; esac
  rest="${ref#"$RUNNER_BRANCH_PREFIX"}"
  while :; do
    case "$rest" in *-issue-*) ;; *) return 0 ;; esac
    rest="${rest#*-issue-}"
    n="${rest%%[!0-9]*}"
    if [ -n "$n" ]; then
      case "${rest#"$n"}" in ''|-*) printf '%s\n' "$n"; return 0 ;; esac
    fi
  done
}

# escape_trace_is_runner_ref <head-ref> — rc 0 when <head-ref> is a runner branch.
escape_trace_is_runner_ref() {
  case "${1:-}" in "$RUNNER_BRANCH_PREFIX"?*) return 0 ;; esac
  return 1
}

# escape_trace_classify <blame> <api> <api-head-ref> <msg-kind> <msg-head-ref>
# — the class and method of one location, as "<class> <method>". Pure: the
# caller gathers the facts, this decides. "-" is an empty value.
#   <blame>         ok | fail
#   <api>           ok | fail          (the commit → PR association call)
#   <api-head-ref>  head ref of the associated PR, or -
#   <msg-kind>      auto-prefix | msg-ref | -   (escape_trace_msg_link)
#   <msg-head-ref>  head ref of the msg-ref PR, `?` when it could not be read, or -
# An association that names a non-runner PR is final (a human's PR): the
# subject is only read when GitHub knows no PR for the commit.
escape_trace_classify() {
  local blame="$1" api="$2" head="$3" kind="$4" mhead="$5"
  if [ "$blame" != ok ] || [ "$api" != ok ]; then
    echo "tuntematon -"; return 0
  fi
  if [ "$head" != - ]; then
    if escape_trace_is_runner_ref "$head"; then echo "runner pr-api"; else echo "peritty -"; fi
    return 0
  fi
  case "$kind" in
    auto-prefix) echo "runner auto-prefix" ;;
    msg-ref)
      if [ "$mhead" = '?' ]; then echo "tuntematon -"
      elif escape_trace_is_runner_ref "$mhead"; then echo "runner msg-ref"
      else echo "peritty -"; fi ;;
    *) echo "peritty -" ;;
  esac
}
