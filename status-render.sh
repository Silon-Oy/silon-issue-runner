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
#      current_state, branch, blocked_reason, …). It never copies issue
#      title/body, agent output, logs, prompts or absolute paths into runs[].
#   2. The inline JS reads ONLY those named fields and inserts every data string
#      with textContent (never innerHTML), so a branch literally named
#      "<script>" is shown as text and never executes. The JS never iterates the
#      run object, so a field the schema grows later cannot leak onto the page.
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
# Environment:
#   RUN_ISSUES_STATUS_OUT_DIR  output directory (default:
#                              ${XDG_STATE_HOME:-$HOME/.local/state}/run-issues/www)
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

SCHEMA_VERSION=1

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
  RAW="$("$RUN_ISSUES_HOME/status.sh" --json)"
  rc=$?
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
.age{color:var(--muted);font-size:.85rem}
.row-next{color:var(--muted);font-size:.85rem;margin-top:.2rem}
.row-sub{color:var(--muted);font-size:.78rem;margin-top:.15rem;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.cleanup-summary{padding:.45rem .8rem;border-top:1px solid var(--border);
  color:var(--muted);font-size:.85rem;border-left:5px solid var(--c-cleanup)}
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
    pr_unlabelled:         {label:"PR ilman labelia",        next:"PR ilman auto-merge-labelia — vahti ei koske siihen."},
    pr_open_waiting:       {label:"PR matkalla",             next:"PR avoinna — vahti hoitaa mergen."},
    pr_state_unknown:      {label:"PR-tila epävarma",        next:"PR:n tilaa ei voitu päätellä paikallisesti."},
    lost_race:             {label:"Hävisi kisan",            next:"Hävisi lukkokisan — siivottavissa."},
    cancelled:             {label:"Peruttu",                 next:"Ajo peruttu — siivottavissa."},
    pr_ci_red:             {label:"CI punainen",             next:"PR:n CI on punainen — korjaa tai anna vahdin korjata."},
    pr_changes_requested:  {label:"Muutoksia pyydetty",      next:"PR:ään on pyydetty muutoksia — käsittele katselmointi."},
    pr_draft_stale:        {label:"Draft jäänyt",            next:"PR on jäänyt draftiksi — merkitse valmiiksi tai sulje."}
  };

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

  function renderRow(r){
    var row = el("div", "row cls-" + r.class);
    row.setAttribute("data-class", r.class);
    row.setAttribute("data-repo", r.repo_slug || "");
    var info = reasonInfo(r.class_reason);

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
    row.appendChild(main);

    if (info.next) row.appendChild(el("div", "row-next", info.next));

    // Secondary, technical line: current_state / blocked_reason / branch.
    var tech = [];
    if (r.current_state) tech.push(r.current_state);
    if (r.blocked_reason) tech.push(r.blocked_reason);
    if (r.branch) tech.push(r.branch);
    if (tech.length) row.appendChild(el("div", "row-sub", tech.join(" · ")));
    return row;
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

    // Group by repo_slug.
    var groups = {};
    runs.forEach(function(r){
      var k = r.repo_slug || "(tuntematon repo)";
      (groups[k] = groups[k] || []).push(r);
    });

    // Order groups busiest first: worst class (lowest priority number), then
    // oldest age. Uses ALL of a group's runs so ordering is stable under filters.
    var order = Object.keys(groups).map(function(k){
      var rs = groups[k];
      var worst = 99, oldest = -1;
      rs.forEach(function(r){
        var p = PRIORITY[r.class] != null ? PRIORITY[r.class] : 99;
        if (p < worst) worst = p;
        var a = r.age_seconds != null ? r.age_seconds : -1;
        if (a > oldest) oldest = a;
      });
      return {slug:k, runs:rs, worst:worst, oldest:oldest};
    });
    order.sort(function(a, b){
      return (a.worst - b.worst) || (b.oldest - a.oldest) || a.slug.localeCompare(b.slug);
    });

    var shown = 0;
    order.forEach(function(g){
      var visible = g.runs.filter(function(r){ return active[r.class]; });
      var cleanupRuns = g.runs.filter(function(r){ return r.class === "cleanup"; });
      // A group with only-cleanup runs and the Siivousjono chip off has no
      // visible rows -> hidden entirely (spec edge case).
      if (visible.length === 0) return;
      shown++;

      var group = el("div", "group");
      var head = el("div", "group-head");
      head.setAttribute("data-repo", g.slug);
      head.appendChild(el("span", "slug", g.slug));
      head.appendChild(el("span", "gcounts", groupCounts(g.runs)));
      var isCollapsed = !!collapsed[g.slug];
      head.appendChild(el("span", "caret", isCollapsed ? "▸" : "▾"));
      head.addEventListener("click", function(){
        collapsed[g.slug] = !collapsed[g.slug];
        render();
      });
      group.appendChild(head);

      if (!isCollapsed) {
        visible.slice().sort(rowCompare).forEach(function(r){ group.appendChild(renderRow(r)); });
        // Cleanup tail: when cleanup rows are not individually shown, summarise.
        if (!active.cleanup && cleanupRuns.length > 0) {
          group.appendChild(el("div", "cleanup-summary",
            "Siivousjono: " + cleanupRuns.length + " valmista ajoa"));
        }
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
  setInterval(fetchData, 60000);   // auto-refresh every 60 s
})();
</script>
</body>
</html>
HTML

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
