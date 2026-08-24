#!/usr/bin/env bash
# status-render.sh — render status.sh's --json document into a self-contained
# web app (HTML + inline CSS + inline JS) that reads status.json in the browser.
#
# status.sh (#59) aggregates every watchlist repo's run-dirs into one versioned
# JSON document. This script is the first CONSUMER of that JSON. It writes two
# files into RUN_ISSUES_STATUS_OUT_DIR so a plain web server (Caddy, nginx, …)
# can serve the picture without running any server-side code:
#
#   status.json  the same JSON verbatim (the machine-readable interface)
#   index.html   a self-contained page: inline CSS + inline JS, NO external
#                resources. The JS fetches status.json (same directory) every
#                60 s and renders a grouped, filterable, Finnish-explained view.
#
# WHY A CLIENT-SIDE APP (#76). #62 rendered a static jq-built dark table with no
# grouping or filtering. This increment moves the view into the browser: the JS
# groups runs by repo (busiest first), offers filter chips + row sorting, gives a
# plain-Finnish explanation for every class_reason, a light default theme (dark
# via prefers-color-scheme), and auto-refresh — all reading the SAME status.json
# schema, which is NOT touched here (collection stays server-side in status.sh).
#
# This script writes files ONLY. It never decides how the page is exposed:
# there is no vhost, no domain, no tunnel here. Exposure (a Caddy vhost bound to
# a Tailscale address, an authenticating proxy) is the machine owner's
# configuration, not this package's content — see examples/status-caddy.example
# and README §7.8. The reason is a leak boundary: status.json carries repo slugs,
# issue numbers, PR URLs and branch names. Behind a public tunnel with no access
# control those would be world-readable, so the package refuses to make that
# decision for you.
#
# FIELD ALLOWLIST, NOT A BLOCKLIST. The allowlist is now enforced in two places,
# not by this script's markup (which is static and data-free):
#   1. status.sh assembles each runs[] object from explicitly named fields
#      (repo slug, issue number + URL, PR URL, class, class_reason, ages,
#      current_state, branch, blocked_reason, …). It never copies issue BODY,
#      agent output, logs, prompts or absolute paths into runs[]. The one gh-only
#      datum shown is the issue TITLE, and it lives ONLY inside the run's `github`
#      sub-object as github.issue_title (#78) — never at the run's top level, so
#      the provenance stays obvious (gh data is confined to `github`). Titles are
#      shown deliberately for a tailnet-only page; see README §7.8.
#   2. The inline JS reads ONLY those named fields — including github.issue_title,
#      github.ci, github.pr_decide_verdict, github.cache_age_seconds and
#      github.pr_state as an explicit allowlist — and inserts every data string
#      with textContent (never innerHTML), so a title or branch literally named
#      "<script>" is shown as text and never executes. The JS never iterates the
#      run or github object, so a field the schema grows later cannot leak. The
#      epics[] lane (#79) reads only its named fields too — repo_slug, epic_number,
#      epic_title, epic_url, sub_issues[].{number,state}, source — the same way.
#
# EPIC ROLLUP (#79). status.sh --github also emits a top-level epics[] list (open
# epic-labelled issues + their sub-issues). The JS renders one lane per epic
# inside its repo group: a progress bar (closed/total), the running sub-issue
# highlighted, queued sub-issues in list (dependency) order with their blocker
# ("jonossa · estäjä #N"), and closed sub-issues as strikethrough ack rows while
# the epic is open. A sub-issue's run is shown ONCE — inside the lane, deduped out
# of the loose repo rows. Without --github, epics[] is empty and the view is the
# V3 page unchanged.
#
# Usage:
#   status-render.sh [--input <file>|-] [--out-dir <dir>]
#
#   --input <file>   read the status JSON from <file> instead of invoking
#                    status.sh. "-" reads stdin. (Test/pipeline injection point.)
#   --out-dir <dir>  where to write status.json + index.html. Overrides
#                    RUN_ISSUES_STATUS_OUT_DIR.
#   -h, --help       show this help.
#
# Exit codes (own space — not the orchestrator's or status.sh's):
#   0  rendered OK (both files written atomically)
#   1  usage error (unknown flag / missing value)
#   2  input unusable — status.sh produced no valid JSON, or the document's
#      schema_version is not the one this renderer understands. Any existing
#      page is LEFT IN PLACE (never overwritten with a broken render).
#   3  write failed (disk full / permissions). The temp files are removed and
#      the previous status.json / index.html stay intact — the web server never
#      serves a half-written file.
#
# GITHUB ENRICHMENT (#78). With RUN_ISSUES_RENDER_GITHUB=1 the LaunchAgent path
# (no --input) runs `status.sh --github` instead of a plain read, so the page
# shows issue titles (github.issue_title) as each row's main text and CI /
# merge-readiness chips on open-PR rows. It is FAIL-SOFT: if the enrichment run
# fails outright the script falls back to a plain local read and renders exactly
# the V1 page. status.sh --github is itself fail-soft (an unreachable repo lands
# in repos_failed and its runs stay github:null), so the fallback is belt-and-
# suspenders. Default 0 = local-only, byte-for-byte the pre-#78 behaviour.
#
# Environment:
#   RUN_ISSUES_STATUS_OUT_DIR  output directory (default:
#                              ${XDG_STATE_HOME:-$HOME/.local/state}/run-issues/www)
#   RUN_ISSUES_RENDER_GITHUB   1 = drive status.sh with --github on the
#                              LaunchAgent path (issue titles + CI chips);
#                              0 (default) = plain local read. Only affects the
#                              no --input path; ignored when --input is given.
#   RUN_ISSUES_LOG_DIR         stdout/stderr under launchd go here (default:
#                              $HOME/Library/Logs). The LaunchAgent plist carries
#                              no StandardOutPath/StandardErrorPath keys (launchd
#                              expands no $HOME in them), so — like the pollers —
#                              this script owns its own log paths.
#   RUN_ISSUES_HOME            install root (test injection point; defaults to
#                              this script's directory)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_ISSUES_HOME="${RUN_ISSUES_HOME:-$HERE}"

# ---- machine config: source poller.env, the LaunchAgent config channel ----
# launchd hands this agent no environment of its own, so — exactly like the
# pollers — the one place a machine can set RUN_ISSUES_RENDER_GITHUB (and the
# output/log dirs) for the LaunchAgent path is poller.env. Sourced => THE FILE
# WINS over an inherited variable. Missing file = plain defaults; a flag still
# overrides (--out-dir is parsed after this). No secrets here (README §7.8).
POLLER_ENV_FILE="${RUN_ISSUES_POLLER_ENV_FILE:-${HOME}/.config/run-issues/poller.env}"
if [ -f "$POLLER_ENV_FILE" ]; then
  set +u
  # shellcheck disable=SC1090
  . "$POLLER_ENV_FILE"
  set -u
fi

SCHEMA_VERSION=1

# ---- Ohjaamo action channel (#77): opt-in mutation buttons -------------------
# The page grows four action buttons (Pysäytä / Siivoa / Salli auto-merge /
# Jatka) ONLY when RUN_ISSUES_ACTION_BASE names the reachable action service
# (action-server.sh, on a Tailscale address). When it does, we embed the service
# base URL and the shared CSRF token (lib/action-token.sh) as <meta> tags; the
# inline JS reads them and POSTs to the service. Without the base the page stays
# a pure V1 read surface — the buttons never render. The token is a bearer
# secret confined to index.html (served tailnet-only, README §7.8/§7.9); it is
# NEVER written into status.json.
# Sourced from HERE (the script's own dir), NOT RUN_ISSUES_HOME: the token lib
# ships alongside this script, whereas RUN_ISSUES_HOME is the test injection point
# for where status.sh lives and may point at a fixture with no lib/.
# shellcheck source=lib/action-token.sh
. "$HERE/lib/action-token.sh"

ACTION_BASE="${RUN_ISSUES_ACTION_BASE:-}"
ACTION_TOKEN=""
if [ -n "$ACTION_BASE" ]; then
  # Strip attribute-breaking characters (operator-configured, but be safe): the
  # value lands in a content="..." attribute.
  ACTION_BASE="$(printf '%s' "$ACTION_BASE" | tr -d '"'"'"'<>[:space:]')"
  ACTION_TOKEN="$(action_token_ensure 2>/dev/null || printf '')"
fi

OUT_DIR="${RUN_ISSUES_STATUS_OUT_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/run-issues/www}"
INPUT_FILE=""

usage() {
  sed -n '43,49p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die_usage() {
  printf 'status-render.sh: %s\n' "$1" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input)   shift; [ "$#" -gt 0 ] || die_usage "--input needs a value"; INPUT_FILE="$1" ;;
    --out-dir) shift; [ "$#" -gt 0 ] || die_usage "--out-dir needs a value"; OUT_DIR="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
  shift
done

# ---- hard dependency: jq (used only to validate the input document) ----
if ! command -v jq >/dev/null 2>&1; then
  printf 'status-render.sh: jq is required but not installed (brew install jq)\n' >&2
  exit 2
fi

# ---- own the log paths, like the pollers ----
# The plist has no StandardOutPath/StandardErrorPath (launchd expands no $HOME
# there), so redirect our own streams when not on a TTY. A manual run still
# prints. Usage errors above happen before this point, so they always reach the
# real terminal.
LOG_DIR="${RUN_ISSUES_LOG_DIR:-$HOME/Library/Logs}"
if [ ! -t 1 ]; then
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  exec >>"$LOG_DIR/status-render.stdout.log" 2>>"$LOG_DIR/status-render.stderr.log"
fi

log() { printf '%s\n' "$*"; }
err() { printf 'status-render.sh: %s\n' "$1" >&2; }

# ---- obtain the status JSON ----
# --input reads a file (or stdin for "-"); otherwise invoke status.sh ourselves,
# which is what the LaunchAgent does. status.sh exit 3 is a DEGRADED-but-valid
# document (one unreadable run.json) — still rendered, with a warning banner.
# Any other non-zero from status.sh means no usable document: leave the old page.
RAW=""
if [ -n "$INPUT_FILE" ]; then
  if [ "$INPUT_FILE" = "-" ]; then
    RAW="$(cat)"
  elif [ -r "$INPUT_FILE" ]; then
    RAW="$(cat "$INPUT_FILE")"
  else
    err "input file not readable: $INPUT_FILE"
    exit 2
  fi
else
  # --github enrichment is opt-in (#78). status.sh exit 3 is a DEGRADED-but-valid
  # document (rendered with a warning), so only a genuinely non-zero, non-3 exit
  # is a failure. When enrichment fails outright, fall back to a plain local read
  # so the page still renders with V1 data (fail-soft).
  if [ "${RUN_ISSUES_RENDER_GITHUB:-0}" = "1" ]; then
    RAW="$("$RUN_ISSUES_HOME/status.sh" --json --github)"
    rc=$?
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
      err "status.sh --github failed (exit $rc); falling back to local data"
      RAW="$("$RUN_ISSUES_HOME/status.sh" --json)"
      rc=$?
    fi
  else
    RAW="$("$RUN_ISSUES_HOME/status.sh" --json)"
    rc=$?
  fi
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
    err "status.sh produced no usable document (exit $rc); leaving existing page in place"
    exit 2
  fi
fi

# ---- validate: parseable JSON with the schema_version we render ----
# The page markup is static and data-free, so it CANNOT fail on the data. But we
# still gate on schema_version here: the JS is written against schema-v1's field
# names, so serving it alongside a document of a different shape would produce a
# silently wrong page. An unknown version leaves the previous page intact.
if ! printf '%s' "$RAW" | jq -e . >/dev/null 2>&1; then
  err "input is not valid JSON; leaving existing page in place"
  exit 2
fi
SV="$(printf '%s' "$RAW" | jq -r '.schema_version // empty')"
if [ "$SV" != "$SCHEMA_VERSION" ]; then
  err "unknown schema_version: ${SV:-<none>} (expected $SCHEMA_VERSION); leaving existing page in place"
  exit 2
fi

# ---- the page: static HTML + inline CSS + inline JS, data-free ----
# read -d '' (not $(cat <<'HTML')): bash 3.2 mis-parses a multi-line heredoc
# nested inside command substitution. read returns 1 at EOF, hence "|| true".
# The heredoc is single-quoted ('HTML') so the shell expands NOTHING inside —
# the JS keeps its literal $ and backticks. The page never embeds run data; the
# JS fetches status.json at runtime and inserts every value with textContent.
IFS= read -r -d '' HTML <<'HTML' || true
<!DOCTYPE html>
<html lang="fi">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="run-issues-action-base" content="__ACTION_BASE__">
<meta name="run-issues-action-token" content="__ACTION_TOKEN__">
<title>run-issues status</title>
<style>
:root{
  --bg:#ffffff; --fg:#1a1a1a; --muted:#5f6368; --border:#e3e3e3; --card:#f6f7f9;
  --link:#0a66c2;
  --c-attention:#e0a300; --c-stalled:#d13438; --c-running:#0a66c2;
  --c-pr:#107c10; --c-cleanup:#8a8a8a;
}
@media (prefers-color-scheme: dark){
  :root{
    --bg:#0f1115; --fg:#e6e6e6; --muted:#9aa0a6; --border:#2a2f3a; --card:#1b1f27;
    --link:#6c9fff;
    --c-attention:#d9a441; --c-stalled:#e06c75; --c-running:#61afef;
    --c-pr:#4caf50; --c-cleanup:#6b7280;
  }
}
*{box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;
  margin:0;background:var(--bg);color:var(--fg);font-size:15px;line-height:1.4}
.wrap{max-width:1100px;margin:0 auto;padding:1.4rem 1.2rem 3rem}
h1{font-size:1.35rem;margin:0 0 .2rem}
.meta{color:var(--muted);font-size:.85rem;margin:.1rem 0 1rem}
.banner{padding:.55rem .8rem;border-radius:6px;margin:.5rem 0;font-size:.9rem}
.banner.warn{background:#fff4d6;color:#5a4500;border:1px solid #e6c860}
.banner.err{background:#fde0e0;color:#7a1a1a;border:1px solid #e0a0a0}
@media (prefers-color-scheme: dark){
  .banner.warn{background:#3a2f10;color:#f0d890;border-color:#5c4a1a}
  .banner.err{background:#3a1616;color:#f0b0b0;border-color:#5c1a1a}
}
.chips{list-style:none;padding:0;display:flex;flex-wrap:wrap;gap:.5rem;margin:.4rem 0 .8rem}
.chip{border:1px solid var(--border);background:var(--card);color:var(--fg);
  padding:.35rem .7rem;border-radius:999px;font-size:.85rem;cursor:pointer;
  display:inline-flex;align-items:center;gap:.4rem;user-select:none}
.chip .dot{width:.6rem;height:.6rem;border-radius:50%}
.chip.off{opacity:.45}
.chip[data-class="attention"] .dot{background:var(--c-attention)}
.chip[data-class="running"] .dot{background:var(--c-running)}
.chip[data-class="stalled"] .dot{background:var(--c-stalled)}
.chip[data-class="pr_in_flight"] .dot{background:var(--c-pr)}
.chip[data-class="cleanup"] .dot{background:var(--c-cleanup)}
.controls{display:flex;align-items:center;gap:.5rem;margin:.2rem 0 1rem;font-size:.85rem;color:var(--muted)}
.controls select{font-size:.85rem;padding:.2rem .3rem}
.group{border:1px solid var(--border);border-radius:8px;margin:.7rem 0;overflow:hidden}
.group-head{display:flex;align-items:center;gap:.6rem;padding:.55rem .8rem;
  background:var(--card);cursor:pointer;user-select:none}
.group-head .slug{font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:40%}
.group-head .gcounts{color:var(--muted);font-size:.82rem;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.group-head .caret{margin-left:auto;color:var(--muted);font-size:.8rem}
.row{border-left:5px solid var(--border);padding:.5rem .8rem;border-top:1px solid var(--border)}
.row.cls-attention{border-left-color:var(--c-attention)}
.row.cls-stalled{border-left-color:var(--c-stalled)}
.row.cls-running{border-left-color:var(--c-running)}
.row.cls-pr_in_flight{border-left-color:var(--c-pr)}
.row.cls-cleanup{border-left-color:var(--c-cleanup)}
.row-main{display:flex;align-items:baseline;flex-wrap:wrap;gap:.55rem}
.badge{font-size:.72rem;padding:.08rem .45rem;border-radius:4px;color:#fff;white-space:nowrap}
.badge.attention{background:var(--c-attention)}
.badge.stalled{background:var(--c-stalled)}
.badge.running{background:var(--c-running)}
.badge.pr_in_flight{background:var(--c-pr)}
.badge.cleanup{background:var(--c-cleanup)}
.reason{font-weight:500}
.title{font-weight:600;flex:1 1 100%;order:9;margin-top:.1rem}
.age{color:var(--muted);font-size:.85rem}
.gh-chips{display:flex;flex-wrap:wrap;gap:.4rem;margin-top:.25rem;align-items:center}
.gh-chip{font-size:.72rem;padding:.08rem .45rem;border-radius:4px;white-space:nowrap;
  border:1px solid var(--border);color:var(--fg);background:var(--card)}
.gh-chip.ci-green{color:#fff;background:var(--c-pr);border-color:var(--c-pr)}
.gh-chip.ci-red{color:#fff;background:var(--c-stalled);border-color:var(--c-stalled)}
.gh-chip.ci-pending{color:#fff;background:var(--c-attention);border-color:var(--c-attention)}
.gh-age{color:var(--muted);font-size:.72rem}
.row-next{color:var(--muted);font-size:.85rem;margin-top:.2rem}
.row-sub{color:var(--muted);font-size:.78rem;margin-top:.15rem;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.cleanup-summary{padding:.45rem .8rem;border-top:1px solid var(--border);
  color:var(--muted);font-size:.85rem;border-left:5px solid var(--c-cleanup)}
.actions{display:flex;flex-wrap:wrap;gap:.4rem;margin-top:.35rem;align-items:center}
.act{font-size:.8rem;padding:.2rem .6rem;border-radius:6px;cursor:pointer;
  border:1px solid var(--border);background:var(--card);color:var(--fg);
  font-family:inherit;line-height:1.3}
.act:hover:not(:disabled){border-color:var(--link)}
.act:disabled{opacity:.45;cursor:not-allowed}
.act.danger{border-color:var(--c-stalled)}
.act.danger:hover:not(:disabled){background:var(--c-stalled);color:#fff}
.act.go{border-color:var(--c-pr)}
.act.go:hover:not(:disabled){background:var(--c-pr);color:#fff}
.act-msg{font-size:.78rem;margin-top:.25rem}
.act-msg.ok{color:var(--c-pr)}
.act-msg.err{color:var(--c-stalled);white-space:pre-wrap;
  font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.act-note{color:var(--muted);font-size:.78rem;margin-top:.3rem}
.group-actions{padding:.4rem .8rem;border-top:1px solid var(--border)}
/* Epic rollup lane (#79) */
.epic{border-top:1px solid var(--border);border-left:5px solid var(--c-running);
  padding:.5rem .8rem;background:var(--card)}
.epic-head{display:flex;align-items:baseline;flex-wrap:wrap;gap:.5rem}
.epic-badge{font-size:.68rem;padding:.06rem .4rem;border-radius:4px;color:#fff;
  background:var(--c-running);white-space:nowrap;letter-spacing:.03em}
.epic-title{font-weight:600}
.epic-progress-count{color:var(--muted);font-size:.82rem;margin-left:auto;white-space:nowrap}
.epic-bar{height:.5rem;border-radius:999px;background:var(--border);margin:.4rem 0;overflow:hidden}
.epic-bar-fill{height:100%;background:var(--c-pr);border-radius:999px}
.epic-sub{display:flex;align-items:baseline;gap:.5rem;padding:.2rem 0 .2rem .4rem;font-size:.88rem}
.epic-sub .epic-mark{width:1rem;text-align:center;color:var(--muted)}
.epic-sub.active{font-weight:600}
.epic-sub.active .epic-mark{color:var(--c-running)}
.epic-sub.done .epic-mark{color:var(--c-pr)}
.epic-sub.done .done-title{text-decoration:line-through;color:var(--muted)}
.epic-sub.queued{color:var(--muted)}
.epic-sub-state{color:var(--muted);font-size:.82rem}
a{color:var(--link);text-decoration:none}
a:hover{text-decoration:underline}
.empty{color:var(--muted);padding:1rem 0}
</style>
</head>
<body>
<div class="wrap">
  <h1>run-issues status</h1>
  <p class="meta" id="meta"></p>
  <div id="banners"></div>
  <ul class="chips" id="chips"></ul>
  <div class="controls">
    <label>Järjestys:
      <select id="sort">
        <option value="age">ikä (vanhin ensin)</option>
        <option value="repo">repo</option>
        <option value="class">luokka</option>
      </select>
    </label>
  </div>
  <div id="view"></div>
  <noscript>
    <p class="banner warn">Tämä näkymä vaatii JavaScriptin. Raakadata:
      <a href="status.json">status.json</a>.</p>
  </noscript>
</div>
<script>
(function(){
  "use strict";

  // Class priority: worst first. Used for group ordering and the "class" sort.
  var PRIORITY = {stalled:0, attention:1, running:2, pr_in_flight:3, cleanup:4};

  // Top-bar chips, in the spec's order: Huomiota / Käynnissä / Jumissa /
  // PR matkalla / Siivousjono. Each toggles its class in/out of the view.
  var CHIPS = [
    {cls:"attention",    label:"Huomiota"},
    {cls:"running",      label:"Käynnissä"},
    {cls:"stalled",      label:"Jumissa"},
    {cls:"pr_in_flight", label:"PR matkalla"},
    {cls:"cleanup",      label:"Siivousjono"}
  ];

  // Plain-Finnish explanation + recommended next step for every class_reason
  // documented in lib/status-read.sh. An unknown reason falls back to its raw
  // code (see reasonInfo) instead of crashing.
  var REASONS = {
    awaiting_review:       {label:"Odottaa katselmointiasi", next:"Hyväksy tai peru ajo: orchestrate.sh --resume."},
    wedged_session:        {label:"Istunto jumissa",         next:"Elävä istunto ei edisty — tarkista tai pysäytä (stop-run.sh)."},
    orphaned:              {label:"Orpo ajo",                next:"Ei elävää istuntoa — siivottavissa (cleanup-run.sh)."},
    active_session:        {label:"Käynnissä",               next:"Istunto elää — ei toimia."},
    recent_progress:       {label:"Käynnissä",               next:"Edennyt äskettäin — ei toimia."},
    blocked:               {label:"Estetty",                 next:"Vaatii huomiotasi — lue tilannekommentti issuesta."},
    timed_out:             {label:"Aikakatkaistu",           next:"Voidaan käynnistää uudelleen: orchestrate.sh --restart."},
    pr_conflicted:         {label:"PR-konflikti",            next:"Ratkaise rebase-konflikti tai anna vahdin hoitaa."},
    awaiting_clarification:{label:"Odottaa vastaustasi",     next:"Botin kysymys odottaa vastaustasi issuessa."},
    pr_not_open:           {label:"PR suljettu",             next:"PR mergetty tai suljettu — ajo siivottavissa."},
    issue_closed:          {label:"Issue suljettu",          next:"Issue suljettu ilman PR:ää — ajo siivottavissa (auto-clean-label tai cleanup-run.sh)."},
    pr_unlabelled:         {label:"PR ilman labelia",        next:"PR ilman auto-merge-labelia — vahti ei koske siihen."},
    pr_open_waiting:       {label:"PR matkalla",             next:"PR avoinna — vahti hoitaa mergen."},
    pr_state_unknown:      {label:"PR-tila epävarma",        next:"PR:n tilaa ei voitu päätellä paikallisesti."},
    lost_race:             {label:"Hävisi kisan",            next:"Hävisi lukkokisan — siivottavissa."},
    cancelled:             {label:"Peruttu",                 next:"Ajo peruttu — siivottavissa."},
    pr_ci_red:             {label:"CI punainen",             next:"PR:n CI on punainen — korjaa tai anna vahdin korjata."},
    pr_changes_requested:  {label:"Muutoksia pyydetty",      next:"PR:ään on pyydetty muutoksia — käsittele katselmointi."},
    pr_draft_stale:        {label:"Draft jäänyt",            next:"PR on jäänyt draftiksi — merkitse valmiiksi tai sulje."}
  };

  // github.ci -> {label, css}. An unknown/absent ci renders no chip.
  var CI = {
    GREEN:   {label:"CI vihreä",  css:"ci-green"},
    RED:     {label:"CI punainen", css:"ci-red"},
    PENDING: {label:"CI kesken",  css:"ci-pending"}
  };

  // github.pr_decide_verdict -> plain-Finnish "what the watcher would do next".
  // Mirrors lib/pr-watch-lib.sh's pr_decide verdicts; an unknown code falls back
  // to the raw code so a new verdict never crashes or hides.
  var VERDICTS = {
    MERGE:        "vahti mergeää seuraavalla tikillä",
    WAIT_CI:      "odottaa CI:tä",
    WAIT_DIRTY:   "odottaa (työpuu likainen)",
    REBASE:       "vahti rebasettaa",
    FIX_CI:       "vahti korjaa CI:n",
    SKIP_NO_LABEL:"ei auto-merge-labelia",
    SKIP_CLOSED:  "PR suljettu",
    SKIP_BLOCKED: "estetty riippuvuudesta"
  };

  // ---- Ohjaamo action channel (#77) --------------------------------------
  // The four buttons are opt-in: they exist only when a base URL is embedded
  // (RUN_ISSUES_ACTION_BASE) AND the service answers a /healthz probe. Without
  // the base the page is a pure V1 read surface. The token is read once here and
  // sent in a header on every POST — a page that cannot be read (cross-origin)
  // cannot read it, which is the CSRF defence.
  function metaContent(name){
    var m = document.querySelector('meta[name="' + name + '"]');
    return (m && m.getAttribute("content")) || "";
  }
  var ACTION_BASE  = metaContent("run-issues-action-base");
  var ACTION_TOKEN = metaContent("run-issues-action-token");
  var actionsConfigured = !!(ACTION_BASE && ACTION_TOKEN);
  var serviceUp = false;    // set by probeService()

  // postAction — POST one action to the service. The custom header forces a CORS
  // preflight that only the allowlisted origin passes; the token proves the
  // request came from this page. Returns a promise of {ok, code, output}.
  function postAction(payload){
    return fetch(ACTION_BASE + "/action", {
      method: "POST",
      mode: "cors",
      headers: {
        "Content-Type": "application/json",
        "X-Run-Issues-Action": "1",
        "X-Run-Issues-Token": ACTION_TOKEN
      },
      body: JSON.stringify(payload)
    }).then(function(resp){
      return resp.json().then(function(j){ return j; }, function(){
        return {ok: resp.ok, code: resp.status, output: "HTTP " + resp.status};
      });
    });
  }

  // probeService — a GET /healthz to decide whether the buttons are live. On any
  // failure the buttons render disabled with an explanation (edge case: service
  // down -> page still works read-only).
  function probeService(){
    if (!actionsConfigured){ serviceUp = false; return; }
    fetch(ACTION_BASE + "/healthz", {mode:"cors", cache:"no-store"})
      .then(function(r){ return r.ok ? r.json() : null; })
      .then(function(j){ serviceUp = !!(j && j.ok); render(); })
      .catch(function(){ serviceUp = false; render(); });
  }

  // The payload the service needs to address a run. Only named fields — never the
  // whole object — so a field the schema grows later is not forwarded blindly.
  function actionPayload(action, r){
    return {
      action: action,
      run_dir: r.run_dir || null,
      repo_path: r.repo_path || null,
      owner_repo: r.owner_repo || null,
      issue_number: (r.issue_number != null ? r.issue_number : null),
      pr_number: (r.pr_number != null ? r.pr_number : null),
      remote: r.remote || null,
      repo_slug: r.repo_slug || null
    };
  }

  // Run one action after a confirmation that NAMES the consequences (security
  // model rule 4). msgNode receives the ok/error result inline.
  function doAction(action, r, confirmText, msgNode){
    if (!window.confirm(confirmText)) return;
    msgNode.className = "act-msg";
    msgNode.textContent = "…";
    postAction(actionPayload(action, r)).then(function(res){
      if (res && res.ok){
        msgNode.className = "act-msg ok";
        msgNode.textContent = "✓ " + (res.output || "valmis");
      } else {
        msgNode.className = "act-msg err";
        // Rule 5: show the delegate's error verbatim, do not paper over it.
        msgNode.textContent = "✗ " + ((res && res.output) || "toiminto epäonnistui");
      }
    }).catch(function(){
      msgNode.className = "act-msg err";
      msgNode.textContent = "✗ toimintopalvelu ei tavoitettavissa";
    });
  }

  // Which actions a row offers, by the identifiers it carries.
  function canStop(r){ return !!r.run_dir && r.status === "initialized"; }
  function canClean(r){ return r.issue_number != null && r.class !== "running"; }
  function canMerge(r){
    if (r.pr_number == null) return false;
    return !r.github || r.github.pr_state === "OPEN" || r.github.pr_state == null;
  }
  function canResume(r){
    if (r.issue_number == null) return false;
    return r.class === "attention" || r.class_reason === "timed_out" || r.class_reason === "blocked";
  }

  function mkBtn(label, cls){
    var b = el("button", "act" + (cls ? " " + cls : ""), label);
    b.type = "button";
    return b;
  }

  // renderActions — the per-row action bar. Returns null when no action applies
  // or the channel is not configured (keeps the V1 look on rows without actions).
  function renderActions(r){
    if (!actionsConfigured) return null;
    var stop = canStop(r), clean = canClean(r), merge = canMerge(r), resume = canResume(r);
    if (!(stop || clean || merge || resume)) return null;

    var wrap = el("div", null);
    var bar = el("div", "actions");
    var msg = el("div", "act-msg");
    var disabled = !serviceUp;

    function add(cond, label, cls, action, confirmText){
      if (!cond) return;
      var b = mkBtn(label, cls);
      b.disabled = disabled;
      if (disabled) b.title = "Toimintopalvelu ei tavoitettavissa";
      else b.addEventListener("click", function(){ doAction(action, r, confirmText, msg); });
      bar.appendChild(b);
    }
    var idn = (r.issue_number != null ? " #" + r.issue_number : "");
    add(stop, "Pysäytä", "danger", "stop",
        "Pysäytä ajo" + idn + "?\n\ntmux-istunto tapetaan; worktree, haara ja run-dir SÄILYVÄT.");
    add(clean, "Siivoa", "danger", "clean",
        "Siivoa ajo" + idn + "?\n\nLisää auto-clean-label — poller poistaa worktreen, haaran, run-dirin ja assignaation turvaportteineen.");
    add(merge, "Salli auto-merge", "go", "allow-merge",
        "Salli auto-merge PR #" + (r.pr_number != null ? r.pr_number : "?") + "?\n\nLisää auto-merge-label — vahti mergeää (ja ratkaisee konfliktin) kun CI on vihreä.");
    add(resume, "Jatka", null, "resume",
        "Jatka ajoa" + idn + "?\n\nTimed_out-ajo käynnistetään uudelleen; muuten needs-human-label poistetaan ja ajo vapautetaan uudelleenkäsittelyyn.");

    if (!bar.firstChild) return null;
    wrap.appendChild(bar);
    if (disabled) wrap.appendChild(el("div", "act-note", "Toimintopalvelu ei tavoitettavissa — napit poissa käytöstä."));
    wrap.appendChild(msg);
    return wrap;
  }

  // View state. Default filter shows attention + stalled + running only.
  var active = {attention:true, running:true, stalled:true, pr_in_flight:false, cleanup:false};
  var sortMode = "age";
  var collapsed = {};           // repo_slug -> true when collapsed
  var lastData = null;          // last successfully fetched document
  var lastOk = false;           // did the most recent fetch succeed?

  function el(tag, cls, text){
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;   // textContent only — never innerHTML
    return e;
  }
  function link(url, text){
    var a = el("a", null, text);
    if (typeof url === "string" && /^https?:\/\//.test(url)) {
      a.href = url; a.target = "_blank"; a.rel = "noopener noreferrer";
    }
    return a;
  }
  function dur(s){
    if (s == null) return "—";
    s = Math.floor(s);
    if (s < 60) return s + " s";
    if (s < 3600) return Math.floor(s/60) + " min";
    if (s < 86400) return Math.floor(s/3600) + " h";
    return Math.floor(s/86400) + " d";
  }
  function reasonInfo(r){
    if (r && Object.prototype.hasOwnProperty.call(REASONS, r)) return REASONS[r];
    return {label: (r || "(tuntematon)"), next: ""};   // unknown reason => raw code
  }
  function freshness(iso){
    var t = Date.parse(iso);
    if (isNaN(t)) return "";
    var d = Math.max(0, (Date.now() - t) / 1000);
    return "päivitetty " + dur(d) + " sitten";
  }
  function clear(node){ while (node.firstChild) node.removeChild(node.firstChild); }

  function renderMeta(data){
    var meta = document.getElementById("meta");
    clear(meta);
    var parts = [];
    if (data.host) parts.push("Kone: " + data.host);
    var f = freshness(data.generated_at);
    if (f) parts.push(f);
    if (data.enrichment && data.enrichment.cache_age_seconds != null)
      parts.push("Cachen ikä: " + dur(data.enrichment.cache_age_seconds));
    meta.textContent = parts.join(" · ");
  }

  function renderBanners(data){
    var box = document.getElementById("banners");
    clear(box);
    if (!lastOk) {
      // Failed fetch: keep the previous data visible, warn on top. If nothing
      // ever loaded, show the recovery instructions instead.
      var b = el("div", "banner err");
      if (lastData) {
        b.textContent = "⚠ Yhteys katkennut — näytetään viimeisin haettu tila.";
      } else {
        b.textContent = "status.json ei latautunut. Tarkista yhteys tai aja hallintakoneella: status.sh --human";
      }
      box.appendChild(b);
    }
    if (data && data.totals && data.totals.degraded) {
      var n = (data.read_errors && data.read_errors.length) || 0;
      box.appendChild(el("div", "banner warn",
        "⚠ Vajaa luenta: " + n + " run.json-tiedostoa oli lukukelvottomia. Muut tiedot ovat täydelliset."));
    }
  }

  function renderChips(data){
    var box = document.getElementById("chips");
    clear(box);
    var byClass = (data.totals && data.totals.by_class) || {};
    CHIPS.forEach(function(c){
      var li = el("li", "chip" + (active[c.cls] ? "" : " off"));
      li.setAttribute("data-class", c.cls);
      li.setAttribute("role", "button");
      li.appendChild(el("span", "dot"));
      li.appendChild(el("span", null, c.label + " " + (byClass[c.cls] != null ? byClass[c.cls] : 0)));
      li.addEventListener("click", function(){
        active[c.cls] = !active[c.cls];
        render();
      });
      box.appendChild(li);
    });
  }

  function classLabel(cls){
    for (var i = 0; i < CHIPS.length; i++) if (CHIPS[i].cls === cls) return CHIPS[i].label;
    return cls;
  }

  function rowCompare(a, b){
    if (sortMode === "class") {
      var pa = PRIORITY[a.class] != null ? PRIORITY[a.class] : 99;
      var pb = PRIORITY[b.class] != null ? PRIORITY[b.class] : 99;
      if (pa !== pb) return pa - pb;
    } else if (sortMode === "repo") {
      var ia = a.issue_number != null ? a.issue_number : 1e12;
      var ib = b.issue_number != null ? b.issue_number : 1e12;
      if (ia !== ib) return ia - ib;
    }
    // default + tie-break: oldest first (null ages last)
    var aa = a.age_seconds != null ? a.age_seconds : -1;
    var ab = b.age_seconds != null ? b.age_seconds : -1;
    return ab - aa;
  }

  // gh(r) — the run's github sub-object or null. Read ONLY named fields off it;
  // never iterate it, so a field the schema grows later cannot leak (allowlist).
  function ghTitle(g){ return (g && typeof g.issue_title === "string") ? g.issue_title : null; }

  function renderRow(r){
    var row = el("div", "row cls-" + r.class);
    row.setAttribute("data-class", r.class);
    row.setAttribute("data-repo", r.repo_slug || "");
    var info = reasonInfo(r.class_reason);
    var g = r.github;                       // null in local mode / failed repo
    var title = ghTitle(g);

    var main = el("div", "row-main");
    main.appendChild(el("span", "badge " + r.class, classLabel(r.class)));
    if (r.issue_number != null) {
      main.appendChild(link(r.issue_url, "#" + r.issue_number + " ↗"));
    }
    main.appendChild(el("span", "reason", info.label));
    main.appendChild(el("span", "age", dur(r.age_seconds)));
    if (r.pr_url) {
      main.appendChild(link(r.pr_url, "PR" + (r.pr_number != null ? " #" + r.pr_number : "") + " ↗"));
    }
    // Issue title as the row's main text (#78). textContent-inserted, so a title
    // literally named "<script>" is shown as text. Without enrichment (title
    // null) the row keeps the V1 shape and the branch shows in the sub-line.
    if (title) main.appendChild(el("span", "title", title));
    row.appendChild(main);

    // CI + merge-readiness chips, only for a row whose PR is OPEN (#78: chips are
    // for PR-in-flight rows). Each datum read by name and textContent-inserted.
    if (g && g.pr_state === "OPEN") {
      var chips = el("div", "gh-chips");
      var ci = CI[g.ci];
      if (ci) chips.appendChild(el("span", "gh-chip " + ci.css, ci.label));
      var v = g.pr_decide_verdict;
      if (typeof v === "string" && v) {
        chips.appendChild(el("span", "gh-chip",
          Object.prototype.hasOwnProperty.call(VERDICTS, v) ? VERDICTS[v] : v));
      }
      if (g.cache_age_seconds != null) {
        chips.appendChild(el("span", "gh-age", "gh " + dur(g.cache_age_seconds) + " sitten"));
      }
      if (chips.firstChild) row.appendChild(chips);
    }

    if (info.next) row.appendChild(el("div", "row-next", info.next));

    // Secondary, technical line: current_state / blocked_reason / branch.
    var tech = [];
    if (r.current_state) tech.push(r.current_state);
    if (r.blocked_reason) tech.push(r.blocked_reason);
    if (r.branch) tech.push(r.branch);
    if (tech.length) row.appendChild(el("div", "row-sub", tech.join(" · ")));

    var acts = renderActions(r);
    if (acts) row.appendChild(acts);
    return row;
  }

  // Mass clean: one confirmation NAMING the count, then N sequential clean
  // POSTs. Partial failure is reported per run in the shared message node.
  function renderMassClean(slug, cleanupRuns){
    if (!actionsConfigured) return null;
    var targets = cleanupRuns.filter(function(r){ return r.issue_number != null; });
    if (targets.length === 0) return null;
    var wrap = el("div", "group-actions");
    var b = mkBtn("Siivoa kaikki " + targets.length, "danger");
    b.disabled = !serviceUp;
    if (!serviceUp) b.title = "Toimintopalvelu ei tavoitettavissa";
    var msg = el("div", "act-msg");
    b.addEventListener("click", function(){
      if (!window.confirm("Siivoa kaikki " + targets.length + " valmista ajoa repossa " + slug +
        "?\n\nJokaiseen lisätään auto-clean-label; poller purkaa ne turvaportteineen.")) return;
      msg.className = "act-msg";
      msg.textContent = "Siivotaan 0/" + targets.length + "…";
      var done = 0, failed = 0;
      targets.forEach(function(r){
        postAction(actionPayload("clean", r)).then(function(res){
          done++;
          if (!(res && res.ok)) failed++;
          msg.className = "act-msg" + (failed ? " err" : (done === targets.length ? " ok" : ""));
          msg.textContent = (failed ? "✗ " : (done === targets.length ? "✓ " : "")) +
            "Siivottu " + (done - failed) + "/" + targets.length +
            (failed ? " (" + failed + " epäonnistui)" : "");
        }).catch(function(){
          done++; failed++;
          msg.className = "act-msg err";
          msg.textContent = "✗ Siivottu " + (done - failed) + "/" + targets.length + " (" + failed + " epäonnistui)";
        });
      });
    });
    wrap.appendChild(b);
    wrap.appendChild(msg);
    return wrap;
  }

  // --- epic rollup (#79) ------------------------------------------------
  // subKey(repo_slug, number) — the join key between a sub-issue and its run.
  function subKey(slug, n){ return (slug || "(tuntematon repo)") + "#" + n; }

  // A run is "live" when it is not in the cleanup class (a finished run lingering
  // on disk). A closed sub-issue keeps its lane row (ack) while the epic is open.
  function isLiveRun(r){ return r && r.class !== "cleanup"; }

  // epicLaneVisible — an epic produces a lane while it has any OPEN sub-issue OR
  // any sub-issue still backed by a live run (spec goal 3: an epic with no live
  // run and no open sub-issue produces no lane).
  function epicLaneVisible(e, runByKey){
    var subs = e.sub_issues || [];
    if (subs.some(function(s){ return s.state === "open"; })) return true;
    return subs.some(function(s){ return isLiveRun(runByKey[subKey(e.repo_slug, s.number)]); });
  }

  function renderEpicLane(e, runByKey){
    var subs = e.sub_issues || [];
    var total = subs.length;
    var closed = subs.filter(function(s){ return s.state === "closed"; }).length;
    var lane = el("div", "epic");
    lane.setAttribute("data-epic", e.epic_number != null ? e.epic_number : "");

    var head = el("div", "epic-head");
    head.appendChild(el("span", "epic-badge", "EPIC"));
    if (e.epic_number != null) head.appendChild(link(e.epic_url, "#" + e.epic_number + " ↗"));
    if (typeof e.epic_title === "string" && e.epic_title)
      head.appendChild(el("span", "epic-title", e.epic_title));
    head.appendChild(el("span", "epic-progress-count", closed + "/" + total + " valmis"));
    lane.appendChild(head);

    // Progress bar: closed / total. Width set via style property (never innerHTML).
    var bar = el("div", "epic-bar");
    var fill = el("div", "epic-bar-fill");
    fill.style.width = (total > 0 ? Math.round((closed / total) * 100) : 0) + "%";
    bar.appendChild(fill);
    lane.appendChild(bar);

    // Sub-issue rows in list (dependency) order. The blocker of a queued open
    // sub-issue is the nearest PRECEDING still-open sub-issue.
    var blocker = null;
    subs.forEach(function(s){
      var r = runByKey[subKey(e.repo_slug, s.number)];
      var title = r ? ghTitle(r.github) : null;
      var row;
      if (s.state === "closed") {
        // Acknowledgement row: strikethrough, green check. Stays while epic open.
        row = el("div", "epic-sub done");
        row.appendChild(el("span", "epic-mark", "✓"));
        row.appendChild(r ? link(r.issue_url, "#" + s.number) : el("span", "epic-sub-num", "#" + s.number));
        if (title) row.appendChild(el("span", "epic-sub-title done-title", title));
        lane.appendChild(row);
        return;   // closed subs do not shift the blocker
      }
      if (isLiveRun(r)) {
        // Active: the sub-issue currently has a live run (highlighted).
        row = el("div", "epic-sub active");
        row.appendChild(el("span", "epic-mark", "▶"));
        row.appendChild(link(r.issue_url, "#" + s.number + " ↗"));
        row.appendChild(el("span", "epic-sub-state", reasonInfo(r.class_reason).label));
        if (title) row.appendChild(el("span", "epic-sub-title", title));
      } else {
        // Queued: no live run. Blocked by the nearest preceding open sub-issue,
        // else waiting to be picked up.
        row = el("div", "epic-sub queued");
        row.appendChild(el("span", "epic-mark", "•"));
        row.appendChild(r ? link(r.issue_url, "#" + s.number) : el("span", "epic-sub-num", "#" + s.number));
        row.appendChild(el("span", "epic-sub-state",
          blocker != null ? ("jonossa · estäjä #" + blocker) : "odottaa poimintaa"));
        if (title) row.appendChild(el("span", "epic-sub-title", title));
      }
      lane.appendChild(row);
      blocker = s.number;   // this open sub-issue blocks the ones after it
    });
    return lane;
  }

  function groupCounts(runs){
    var c = {};
    runs.forEach(function(r){ c[r.class] = (c[r.class] || 0) + 1; });
    var parts = [];
    ["stalled","attention","running","pr_in_flight","cleanup"].forEach(function(cls){
      if (c[cls]) parts.push(classLabel(cls) + " " + c[cls]);
    });
    return parts.join(" · ");
  }

  function render(){
    var view = document.getElementById("view");
    if (!lastData) {
      // Nothing has loaded yet: banners carry the recovery hint.
      renderBanners(null);
      clear(view);
      return;
    }
    var data = lastData;
    renderMeta(data);
    renderBanners(data);
    renderChips(data);
    document.getElementById("sort").value = sortMode;

    clear(view);
    var runs = data.runs || [];
    if (runs.length === 0) {
      view.appendChild(el("p", "empty", "Ei ajoja."));
      return;
    }

    // Epic membership (#79): group epics by repo_slug, index runs by sub-key so
    // a lane can pull its sub-issue runs — and so those runs render ONCE, inside
    // the lane, never also as a loose repo row (dedup, spec criterion 3). Only a
    // VISIBLE epic dedups its subs: an epic with no lane would otherwise hide a
    // sub-issue's lingering cleanup run from the group entirely (no lane + not a
    // loose row), so it must stay a loose row when there is no lane to hold it.
    var epicsList = data.epics || [];
    var epicsByRepo = {}, epicMember = {}, runByKey = {};
    runs.forEach(function(r){ runByKey[subKey(r.repo_slug, r.issue_number)] = r; });
    epicsList.forEach(function(e){
      var k = e.repo_slug || "(tuntematon repo)";
      (epicsByRepo[k] = epicsByRepo[k] || []).push(e);
      if (!epicLaneVisible(e, runByKey)) return;
      (e.sub_issues || []).forEach(function(s){ epicMember[subKey(k, s.number)] = true; });
    });

    // Group by repo_slug. allRuns drives counts + ordering; rows excludes runs
    // that belong to an epic lane; epics holds the visible lanes.
    var groups = {};
    function grp(k){ return groups[k] || (groups[k] = {slug:k, rows:[], allRuns:[], epics:[]}); }
    runs.forEach(function(r){
      var k = r.repo_slug || "(tuntematon repo)";
      var g = grp(k);
      g.allRuns.push(r);
      if (!epicMember[subKey(k, r.issue_number)]) g.rows.push(r);
    });
    Object.keys(epicsByRepo).forEach(function(k){
      grp(k).epics = epicsByRepo[k].filter(function(e){ return epicLaneVisible(e, runByKey); });
    });

    // Order groups busiest first: worst class (lowest priority number), then
    // oldest age. Uses ALL of a group's runs so ordering is stable under filters.
    var order = Object.keys(groups).map(function(k){
      var g = groups[k];
      var worst = 99, oldest = -1;
      g.allRuns.forEach(function(r){
        var p = PRIORITY[r.class] != null ? PRIORITY[r.class] : 99;
        if (p < worst) worst = p;
        var a = r.age_seconds != null ? r.age_seconds : -1;
        if (a > oldest) oldest = a;
      });
      // A repo with only epic lanes (no runs of its own) still needs an order
      // slot; treat it as running-priority so it sits among active work.
      if (g.epics.length && worst === 99) worst = PRIORITY.running;
      return {slug:k, rows:g.rows, allRuns:g.allRuns, epics:g.epics, worst:worst, oldest:oldest};
    });
    order.sort(function(a, b){
      return (a.worst - b.worst) || (b.oldest - a.oldest) || a.slug.localeCompare(b.slug);
    });

    var shown = 0;
    order.forEach(function(g){
      var visible = g.rows.filter(function(r){ return active[r.class]; });
      var cleanupRuns = g.rows.filter(function(r){ return r.class === "cleanup"; });
      // Show the group if it has visible rows OR any epic lane. A group of only
      // cleanup runs with the Siivousjono chip off (and no epic) collapses away.
      if (visible.length === 0 && g.epics.length === 0) return;
      shown++;

      var group = el("div", "group");
      var head = el("div", "group-head");
      head.setAttribute("data-repo", g.slug);
      head.appendChild(el("span", "slug", g.slug));
      head.appendChild(el("span", "gcounts", groupCounts(g.allRuns)));
      var isCollapsed = !!collapsed[g.slug];
      head.appendChild(el("span", "caret", isCollapsed ? "▸" : "▾"));
      head.addEventListener("click", function(){
        collapsed[g.slug] = !collapsed[g.slug];
        render();
      });
      group.appendChild(head);

      if (!isCollapsed) {
        // Epic lanes first, then the loose (non-epic) rows.
        g.epics.forEach(function(e){ group.appendChild(renderEpicLane(e, runByKey)); });
        visible.slice().sort(rowCompare).forEach(function(r){ group.appendChild(renderRow(r)); });
        // Cleanup tail: when cleanup rows are not individually shown, summarise.
        if (!active.cleanup && cleanupRuns.length > 0) {
          group.appendChild(el("div", "cleanup-summary",
            "Siivousjono: " + cleanupRuns.length + " valmista ajoa"));
        }
        // Mass "Siivoa kaikki N" for the group's cleanup runs (opt-in channel).
        var mass = renderMassClean(g.slug, cleanupRuns);
        if (mass) group.appendChild(mass);
      }
      view.appendChild(group);
    });

    if (shown === 0) view.appendChild(el("p", "empty", "Ei näytettäviä ajoja valituilla suodattimilla."));
  }

  function fetchData(){
    fetch("status.json", {cache:"no-store"})
      .then(function(resp){
        if (!resp.ok) throw new Error("HTTP " + resp.status);
        return resp.json();
      })
      .then(function(json){
        lastData = json; lastOk = true; render();
      })
      .catch(function(){
        lastOk = false; render();   // keep lastData visible; banner warns
      });
  }

  document.getElementById("sort").addEventListener("change", function(e){
    sortMode = e.target.value; render();
  });

  fetchData();
  probeService();                  // enable the action buttons if the service is up
  setInterval(fetchData, 60000);   // auto-refresh every 60 s
  setInterval(probeService, 60000);
})();
</script>
</body>
</html>
HTML

# ---- inject the action channel config (base + token) ----
# The heredoc is single-quoted so it carries literal __ACTION_BASE__ /
# __ACTION_TOKEN__ placeholders; fill them via bash parameter expansion (no sed:
# the base URL contains slashes and the replacement is taken literally here, so
# there is nothing to escape). Empty values => the JS sees no base and renders
# the pure V1 read surface. The token reaches ONLY index.html, never status.json.
HTML="${HTML//__ACTION_BASE__/$ACTION_BASE}"
HTML="${HTML//__ACTION_TOKEN__/$ACTION_TOKEN}"

# ---- atomic write: temp in OUT_DIR (same filesystem) + mv -f ----
# Writing both files then renaming them means a concurrent web request never
# sees a half-written file, and a failed write (disk full) leaves the previous
# page untouched.
if ! mkdir -p "$OUT_DIR" 2>/dev/null; then
  err "cannot create output directory: $OUT_DIR"
  exit 3
fi

tmp_json="$(mktemp "$OUT_DIR/.status.json.XXXXXX" 2>/dev/null)" || { err "mktemp failed in $OUT_DIR"; exit 3; }
tmp_html="$(mktemp "$OUT_DIR/.index.html.XXXXXX" 2>/dev/null)" || { rm -f "$tmp_json"; err "mktemp failed in $OUT_DIR"; exit 3; }
cleanup_tmp() { rm -f "$tmp_json" "$tmp_html"; }

if ! printf '%s' "$RAW" > "$tmp_json"; then
  cleanup_tmp; err "write failed (status.json); previous page left intact"; exit 3
fi
if ! printf '%s\n' "$HTML" > "$tmp_html"; then
  cleanup_tmp; err "write failed (index.html); previous page left intact"; exit 3
fi
chmod 644 "$tmp_json" "$tmp_html" 2>/dev/null || true

if ! mv -f "$tmp_json" "$OUT_DIR/status.json"; then
  cleanup_tmp; err "rename failed (status.json); previous page left intact"; exit 3
fi
if ! mv -f "$tmp_html" "$OUT_DIR/index.html"; then
  rm -f "$tmp_html"; err "rename failed (index.html); previous page left intact"; exit 3
fi

log "status-render.sh: wrote $OUT_DIR/index.html and $OUT_DIR/status.json"
exit 0
