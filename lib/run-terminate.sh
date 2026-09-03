#!/usr/bin/env bash
# lib/run-terminate.sh — terminate a live /run-issues run safely.
#
# `run_terminate <run-dir> <reason-slug> [<comment-context>]` is the one place
# that knows how to stop a still-running orchestration without corrupting its
# neighbours. It grew out of poller.sh:finalize_stalled (issue #49) and every
# one of its five responsibilities was paid for by a production incident:
#
#   1. Per-run host gate — a run.json whose .host is not THIS_HOST belongs to
#      another machine; its live tmux session and lock are never touched.
#   2. Exact tmux match (`-t "=$sess"`) — without the leading `=`, killing
#      `run-issues-3` would prefix-match and kill `run-issues-34` as well.
#   3. state_finalize → blocked/<reason> + a state_event, so the dead run's
#      run.json carries a terminal status and the transition is auditable.
#   4. Best-effort needs-human label + a Finnish situation comment on the issue
#      (all gh calls `|| true` — a GitHub hiccup must never wedge the caller).
#   5. Lock teardown from the run's OWN recorded identity (repo_slug + remote),
#      NOT from the issue number alone — deriving the lock name from the number
#      once deleted a DIFFERENT repo's live lock for the same issue (issue #67).
#
# The logic lived inside poller.sh, which `exit 0`s at source time on a foreign
# host (the host gate runs at the top of the file), so it was not callable from
# anywhere else. A future stop-run.sh needs exactly this path, and duplicating a
# safety-critical routine would be a second implementation to keep in sync — so
# it is extracted here as a pure, sourceable function (issue #63).
#
# Parameterisation is deliberately minimal (a pure refactor): the caller passes
# the `reason` slug (finalize_stalled passes `stalled_in_<current_state>`) and an
# optional `context` keyword that flavours the log headline, the state_event
# name AND the situation-comment body. Two comment flavours exist (issue #64):
#   - "stalled" (the poller liveness sweep) — carries an awaiting-answer marker,
#     so a human reply re-triggers a fresh run via scan_blocked_answered (#57).
#   - "stopped" (stop-run.sh, an operator-requested stop) — NO marker: a stop is
#     a deliberate human action and stop-run's scope-out forbids an automatic
#     restart, so the reply-driven retry must NOT fire. The body points to
#     cleanup (cleanup-run.sh / the auto-clean label) instead. This is the
#     "jumittuminen vs. pyydetty pysäytys" branch the extraction (#63) foresaw.
#
# This file only defines functions — no side effects at source time — so it is
# safe to source from any caller. It pulls in its own dependencies (git-remote /
# state / labels / issue), all of which are likewise function-only, so a caller
# such as stop-run.sh needs to source this one file alone.

set -euo pipefail

_RUN_TERMINATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# session_suffix / repo_slug / remote_label — tmux session names + lock label.
# shellcheck source=git-remote.sh
. "$_RUN_TERMINATE_DIR/git-remote.sh"
# state_finalize / state_event — durable run.json transition.
# shellcheck source=state.sh
. "$_RUN_TERMINATE_DIR/state.sh"
# labels_ensure / labels_add — REST-based needs-human label write.
# shellcheck source=labels.sh
. "$_RUN_TERMINATE_DIR/labels.sh"
# build_marker — the awaiting-answer marker embedded in the situation comment.
# shellcheck source=issue.sh
. "$_RUN_TERMINATE_DIR/issue.sh"

# _run_terminate_log <message> — best-effort logger, same spirit as
# lib/locking.sh:_locking_log. A caller that defines a log() function
# (orchestrate.sh) gets it; the pollers set $LOG and the line lands in that
# file; every other caller (e.g. stop-run.sh run from a terminal) falls back to
# a date-prefixed stderr line so nothing is ever silently dropped.
_run_terminate_log() {
  if declare -F log >/dev/null 2>&1; then
    log "run_terminate: $*"
  elif [ -n "${LOG:-}" ]; then
    printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"
  else
    printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&2
  fi
}

# run_terminate <run-dir> <reason-slug> [<comment-context>]
#   1. Kill any matching tmux session (run-issues-<N> / run-issues-restart-<N>
#      / run-issues-continue-<N> / run-issues-clean-<N> / run-issues-reset-<N>)
#      so the run stops consuming a GLOBAL_MAX slot. The list is a literal
#      enumeration of the poller's session prefixes: a verb missing here is a
#      session nothing can stop, which is why the two teardown verbs are both
#      named rather than one standing in for the other.
#   2. Finalize run.json as blocked/<reason-slug> via state_finalize (state.sh),
#      plus a <context>_finalized state_event.
#   3. Best-effort: post a Finnish situation comment to the issue, add the
#      needs-human label, release the per-issue advisory lock.
#
# The issue number, repo, remote and repo slug are all read from run.json — the
# run-dir is the single source of truth, so no caller has to pass them and none
# can pass one that disagrees with the recorded run.
#
# All gh calls are `|| true` — a GitHub hiccup must never wedge the caller's
# loop. The lock teardown matches lib/locking.sh's path convention
# (RUN_ISSUES_LOCK_ROOT/<label>.lock) and is idempotent.
run_terminate() {
  local run_dir="$1" reason="$2" context="${3:-stalled}"
  local rj="$run_dir/run.json"
  [ -f "$rj" ] || return 0

  local current_state repo host_in_run remote_in_run slug_in_run run_id_in_run issue
  current_state=$(jq -r '.current_state // "unknown"' "$rj" 2>/dev/null || echo "unknown")
  repo=$(jq -r '.repo // empty' "$rj" 2>/dev/null || echo "")
  # run_id for the awaiting-answer marker (issue #57). Empty -> run-dir basename,
  # which IS the run-id by construction. Only the marker's ts matters downstream
  # (scan_blocked_answered reads ts=), but build_marker wants the run field too.
  run_id_in_run=$(jq -r '.run_id // empty' "$rj" 2>/dev/null || echo "")
  [ -n "$run_id_in_run" ] || run_id_in_run=$(basename "$run_dir")
  host_in_run=$(jq -r '.host // empty' "$rj" 2>/dev/null || echo "")
  # Multi-remote (issue #53): empty -> "origin" (legacy run.json predating the
  # field). The remote drives tmux session naming and lock teardown below.
  remote_in_run=$(jq -r '.remote // "origin"' "$rj" 2>/dev/null || echo "origin")
  # Repo namespacing (issue #67): the slug RECORDED BY THIS RUN, not one derived
  # here. That distinction is the whole fix for cross-repo lock theft — we
  # release exactly the lock this run holds. Empty = pre-#67 run holding the
  # legacy repo-agnostic lock.
  slug_in_run=$(jq -r '.repo_slug // ""' "$rj" 2>/dev/null || echo "")
  # The issue number is the run's own — read it here rather than trusting a
  # caller-supplied value that could drift from run.json.
  issue=$(jq -r '.issue_number // empty' "$rj" 2>/dev/null || echo "")

  # 1. Host gate. Defense in depth: scan_stalled host-gates before it ever hands
  # a run-dir here, but a misalignment between caller and helper would otherwise
  # let us tap a foreign session.
  if [ -n "$host_in_run" ] && [ "$host_in_run" != "$THIS_HOST" ]; then
    _run_terminate_log "run_terminate refusing foreign host run (host=$host_in_run, this=$THIS_HOST)"
    return 0
  fi

  # Log headline. The verb is the uppercased context (STALLED / …) so the same
  # line serves every flavour; `tr` keeps it portable to bash 3.2 (macOS).
  local verb
  verb=$(printf '%s' "$context" | tr '[:lower:]' '[:upper:]')
  _run_terminate_log "${verb} issue=#${issue} remote=${remote_in_run} state=${current_state} run_dir=${run_dir} — killing tmux sessions and finalizing blocked/${reason}"

  # 2. Kill any tmux session for this run. There is exactly one orchestrator per
  # (repo, remote, issue) triple (the per-issue lock guarantees it), but it could
  # carry any of four prefixes depending on how it was launched. The suffix shape
  # depends on the remote and the repo slug, so derive it from session_suffix.
  #
  # A pre-#67 run gets a second suffix probed: its ORIGINAL session carries the
  # legacy repo-agnostic name, but if this poller version restarted/continued it,
  # the newer session carries the repo-namespaced one. Both must die or the run
  # keeps holding a GLOBAL_MAX slot. For a post-#67 run only its own name is
  # touched — that is what keeps another repo's identically-numbered session safe.
  local suffix suffix_alt sess
  suffix=$(session_suffix "$remote_in_run" "$issue" "$slug_in_run")
  suffix_alt=""
  if [ -z "$slug_in_run" ] && [ -n "$repo" ]; then
    suffix_alt=$(session_suffix "$remote_in_run" "$issue" "$(repo_slug "$repo" "$remote_in_run")")
    [ "$suffix_alt" = "$suffix" ] && suffix_alt=""
  fi
  for sess in "run-issues-${suffix}" "run-issues-restart-${suffix}" \
              "run-issues-continue-${suffix}" "run-issues-clean-${suffix}" \
              "run-issues-reset-${suffix}" \
              ${suffix_alt:+"run-issues-${suffix_alt}"} \
              ${suffix_alt:+"run-issues-restart-${suffix_alt}"} \
              ${suffix_alt:+"run-issues-continue-${suffix_alt}"} \
              ${suffix_alt:+"run-issues-clean-${suffix_alt}"} \
              ${suffix_alt:+"run-issues-reset-${suffix_alt}"}; do
    # `=` forces an exact tmux target match; without it `run-issues-3` prefix-
    # matches `run-issues-34` and we would kill an unrelated running session.
    if tmux has-session -t "=$sess" 2>/dev/null; then
      _run_terminate_log "killing stalled tmux session $sess"
      tmux kill-session -t "=$sess" 2>/dev/null || true
    fi
  done

  # 3. Finalize state. The orchestrator process is dead (or never had a chance to
  # write a terminal status), so we own the run.json transition here.
  state_finalize "$run_dir" "blocked" "$reason"
  state_event "$run_dir" "${context}_finalized" \
    "current_state=$current_state" \
    "host=$THIS_HOST" \
    "stale_after=${RUN_ISSUES_STALE_AFTER:-3600}"

  # 4. Best-effort label + comment via gh. We change into the repo (from run.json)
  # so gh resolves the right repo even from the caller's cwd.
  if [ -n "$repo" ]; then
    # Diagnostics from the label helpers are logged, not sent to /dev/null: a
    # silent best-effort label write is how the read:project scope breakage
    # stayed invisible for five weeks. They flow through _run_terminate_log so
    # they land wherever this caller's log does.
    ( cd "$repo" && labels_ensure "" needs-human B60205 \
        "Vaatii ihmisen — automaattinen ajo ei onnistunut" ) 2>&1 \
        | while IFS= read -r _line; do _run_terminate_log "$_line"; done || true
    ( cd "$repo" && labels_add "" "$issue" needs-human ) 2>&1 \
        | while IFS= read -r _line; do _run_terminate_log "$_line"; done || true

    # Write the comment body to a temp file (heredoc inside $(...) has fragile
    # parser interactions with bash's case-statement-aware tokenizer; the temp
    # file is simpler and verifiable). Both flavours mirror
    # _post_situation_to_issue's headline + meta-list shape so a human scanning
    # issues sees the same skeleton across all hand-off paths — the branch below
    # differs only in the marker, the headline verb and the follow-up sentence.
    local body_file
    body_file=$(mktemp -t run-terminate-body.XXXXXX)
    if [ "$context" = "stopped" ]; then
      # Operator-requested stop (stop-run.sh, issue #64). NO awaiting-answer
      # marker: scope-out forbids an automatic restart, so scan_blocked_answered
      # must not re-trigger this run on a reply. The body points to cleanup
      # instead — the worktree/branch/run-dir are intentionally left intact, so a
      # human decides when to tear them down.
      {
        echo "## /run-issues — Ajo pysäytetty vaiheessa \`${current_state}\`"
        echo
        echo "- Issue: #${issue}"
        echo "- Status/syy: \`${reason}\`"
        echo "- Host: \`${THIS_HOST}\`"
        echo "- Run-dir: \`${run_dir}\`"
        echo
        echo "Ajo pysäytettiin operaattorin pyynnöstä (\`stop-run.sh\`). Tmux-sessio tapettiin ja ajo viimeisteltiin \`blocked\`-tilaan, jotta se ei enää varaa \`GLOBAL_MAX\`-kapasiteettia. **Worktree, haara ja run-dir jätettiin ennalleen** — pysäytys ei ole siivous."
        echo
        echo "**Jatkotoimet:** siivoa artefaktit käsin koneella \`${THIS_HOST}\`: \`~/.claude/scripts/run-issues/cleanup-run.sh --issue ${issue} --force --yes\`, tai lisää issueen \`auto-clean\`-label niin poller siivoaa sen automaattisesti. Siivouksen jälkeen issue palaa normaaliin poimintaan uutena ajona."
      } > "$body_file"
    else
      # Stalled flavour (poller liveness sweep, issue #49). Answerable marker
      # (issue #57): a human reply after this ts re-triggers a fresh run via
      # scan_blocked_answered. build_marker + parse_marker/detect_answer are the
      # SAME machinery the orchestrator uses, so the poller's stalled comment
      # participates identically. Marker first (top of body) — parse_marker takes
      # the newest by ts, and detect_answer skips this comment itself (it carries
      # the "run-issues:" token).
      local stale_after_log stalled_marker
      stale_after_log="${RUN_ISSUES_STALE_AFTER:-3600}"
      stalled_marker=$(build_marker "$run_id_in_run" "$issue" "$(date -u +%FT%TZ)")
      {
        echo "$stalled_marker"
        echo "## /run-issues — Ajo jumitettu vaiheessa \`${current_state}\`"
        echo
        echo "- Issue: #${issue}"
        echo "- Status/syy: \`${reason}\`"
        echo "- Host: \`${THIS_HOST}\`"
        echo "- Run-dir: \`${run_dir}\`"
        echo
        echo "Pollerin liveness-tarkistus havaitsi että rakenteinen etenemistila (\`state.jsonl\`-aikaleima) ei ole liikahtanut yli ${stale_after_log}s. Tmux-sessio tapettiin ja ajo viimeisteltiin \`blocked\`-tilaan, jotta yksittäinen jumi-ajo ei tukkisi \`GLOBAL_MAX\`-kapasiteettia loputtomiin (issue #49)."
        echo
        echo "**Kun este on selvitetty, kommentoi tähän issueen — ajo siivotaan ja yritetään uudelleen automaattisesti (≤5 min).** Vaihtoehtoisesti siivoa käsin koneella \`${THIS_HOST}\`: \`~/.claude/scripts/run-issues/cleanup-run.sh --issue ${issue} --force --yes\`."
      } > "$body_file"
    fi
    ( cd "$repo" && gh issue comment "$issue" --body-file "$body_file" >/dev/null 2>&1 ) || true
    rm -f "$body_file"
  fi

  # 5. Release the per-issue advisory lock (its owner is dead). Same path shape
  # as lib/locking.sh; idempotent — a missing lock is fine.
  #
  # The label is built from the run's OWN recorded identity (repo slug + remote),
  # so this removes exactly the lock this run holds. Deriving the label from the
  # issue number alone was cross-repo lock theft (issue #67): finalizing a
  # stalled run in repo A deleted repo B's LIVE lock for the same issue number,
  # after which the next poller cycle could start a second run for B.
  local lock_root="${RUN_ISSUES_LOCK_ROOT:-${HOME}/Library/Application Support/run-issues/locks}"
  local lock_label
  lock_label=$(remote_label "$remote_in_run" "$issue" "$slug_in_run")
  rm -rf "${lock_root}/${lock_label}.lock" 2>/dev/null || true

  return 0
}
