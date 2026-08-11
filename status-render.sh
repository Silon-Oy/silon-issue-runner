#!/usr/bin/env bash
# status-render.sh — render status.sh's --json document into a static web page.
#
# status.sh (#59) aggregates every watchlist repo's run-dirs into one versioned
# JSON document. This script is the first CONSUMER of that JSON: it writes two
# files into RUN_ISSUES_STATUS_OUT_DIR so a plain web server (Caddy, nginx, …)
# can serve the picture without running any code:
#
#   status.json  the same JSON verbatim (the machine-readable interface)
#   index.html   a self-contained page: inline CSS, NO external resources, NO
#                JavaScript. Safe to serve from a read-only directory.
#
# This script writes files ONLY. It never decides how the page is exposed:
# there is no vhost, no domain, no tunnel here. Exposure (a Caddy vhost bound to
# a Tailscale address, an authenticating proxy) is the machine owner's
# configuration, not this package's content — see examples/status-caddy.example
# and README §7.8. The reason is a leak boundary: the page carries repo slugs,
# issue numbers, PR URLs and branch names. Behind a public tunnel with no access
# control those would be world-readable, so the package refuses to make that
# decision for you.
#
# FIELD ALLOWLIST, NOT A BLOCKLIST. The renderer names the fields that reach the
# page (repo slug, issue number + URL, PR URL, class, class_reason, ages,
# current_state, branch, blocked_reason, cache age, generated_at) and pulls each
# one out by name with jq. It never iterates the run object. A blocklist would
# leak whatever field the schema grows next; an allowlist cannot. Forbidden and
# therefore never selected: issue title/body, agent output, logs, prompts,
# absolute filesystem paths. Every data string is HTML-escaped (jq @html) so a
# branch literally named "<script>" renders as text.
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
  sed -n '31,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

# ---- hard dependency: jq ----
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
if ! printf '%s' "$RAW" | jq -e . >/dev/null 2>&1; then
  err "input is not valid JSON; leaving existing page in place"
  exit 2
fi
SV="$(printf '%s' "$RAW" | jq -r '.schema_version // empty')"
if [ "$SV" != "$SCHEMA_VERSION" ]; then
  err "unknown schema_version: ${SV:-<none>} (expected $SCHEMA_VERSION); leaving existing page in place"
  exit 2
fi

# ---- render HTML (allowlisted fields only; every string HTML-escaped) ----
# read -d '' (not $(cat <<'JQ')): bash 3.2 mis-parses a multi-line heredoc
# nested inside command substitution. read returns 1 at EOF, hence "|| true".
IFS= read -r -d '' HTML_JQ <<'JQ' || true
def esc: if . == null then "" else (tostring | @html) end;
def dur:
  if . == null then "—"
  elif . < 60 then "\(.|floor) s"
  elif . < 3600 then "\((./60)|floor) min"
  elif . < 86400 then "\((./3600)|floor) h"
  else "\((./86400)|floor) d" end;

"<!DOCTYPE html>",
"<html lang=\"fi\">",
"<head>",
"<meta charset=\"utf-8\">",
"<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
"<meta http-equiv=\"refresh\" content=\"300\">",
"<title>run-issues status</title>",
"<style>body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;margin:2rem;background:#0f1115;color:#e6e6e6}h1{font-size:1.4rem;margin:0 0 .3rem}.meta{color:#9aa0a6;font-size:.85rem;margin:.2rem 0 1rem}.warn{background:#5c1a1a;color:#fff;padding:.6rem .8rem;border-radius:6px;margin:.6rem 0}.counts{list-style:none;padding:0;display:flex;flex-wrap:wrap;gap:.8rem;margin:0 0 1.2rem}.counts li{background:#1b1f27;padding:.4rem .8rem;border-radius:6px;font-size:.9rem}table{border-collapse:collapse;width:100%;font-size:.85rem}th,td{text-align:left;padding:.4rem .6rem;border-bottom:1px solid #2a2f3a;vertical-align:top}th{color:#9aa0a6;font-weight:600}a{color:#6c9fff}.badge{display:inline-block;padding:.1rem .45rem;border-radius:4px;font-size:.75rem;background:#2a2f3a}tr.cls-attention .badge{background:#7a4a00}tr.cls-stalled .badge{background:#5c1a1a}tr.cls-running .badge{background:#1a5c2a}tr.cls-pr_in_flight .badge{background:#1a3a5c}tr.cls-cleanup .badge{background:#3a3a3a}.empty{color:#9aa0a6}</style>",
"</head>",
"<body>",
"<h1>run-issues status</h1>",
"<p class=\"meta\">Kone: \(.host|esc) · Luotu: \(.generated_at|esc) · Data: \(.enrichment.mode|esc) · Cachen ikä: \(.enrichment.cache_age_seconds|dur)</p>",
(if .totals.degraded then
  "<p class=\"warn\">⚠ Vajaa luenta: \(.read_errors|length|esc) run.json-tiedostoa oli lukukelvottomia. Näytetyt tiedot ovat muilta osin täydelliset.</p>"
 else empty end),
"<ul class=\"counts\">",
"<li>Käynnissä: \(.totals.by_class.running|esc)</li>",
"<li>Jumissa: \(.totals.by_class.stalled|esc)</li>",
"<li>Huomiota: \(.totals.by_class.attention|esc)</li>",
"<li>PR matkalla: \(.totals.by_class.pr_in_flight|esc)</li>",
"<li>Siivousjono: \(.totals.by_class.cleanup|esc)</li>",
"</ul>",
(if (.runs|length) == 0 then
  "<p class=\"empty\">Ei ajoja.</p>"
 else
  ( "<table>",
    "<thead><tr><th>Repo</th><th>Issue</th><th>Luokka</th><th>Tila</th><th>Haara</th><th>Ikä</th><th>Idle</th><th>Blocked</th><th>PR</th></tr></thead>",
    "<tbody>",
    ( .runs[] |
      "<tr class=\"cls-\(.class|esc)\">"
      + "<td>\(.repo_slug|esc)</td>"
      + "<td>" + (if (.issue_url // "") != "" and .issue_number != null then "<a href=\"\(.issue_url|esc)\">#\(.issue_number|esc)</a>"
                  elif .issue_number != null then "#\(.issue_number|esc)"
                  else "—" end) + "</td>"
      + "<td><span class=\"badge\">\(.class|esc)</span> \(.class_reason|esc)</td>"
      + "<td>\((.current_state // "—")|esc)</td>"
      + "<td>\((.branch // "—")|esc)</td>"
      + "<td>\(.age_seconds|dur)</td>"
      + "<td>\(.idle_seconds|dur)</td>"
      + "<td>\((.blocked_reason // "—")|esc)</td>"
      + "<td>" + (if (.pr_url // "") != "" then "<a href=\"\(.pr_url|esc)\">PR\(if .pr_number != null then " #\(.pr_number|esc)" else "" end)</a>" else "—" end) + "</td>"
      + "</tr>"
    ),
    "</tbody>",
    "</table>" )
 end),
"</body>",
"</html>"
JQ

if ! HTML="$(printf '%s' "$RAW" | jq -r "$HTML_JQ")"; then
  err "HTML render failed; leaving existing page in place"
  exit 2
fi

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
