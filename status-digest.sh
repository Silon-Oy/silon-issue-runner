#!/usr/bin/env bash
# status-digest.sh — turn status.sh --json into a pushed Finnish email digest of
# the runs that need a human.
#
# status.sh makes the situation FINDABLE (one JSON document over every watchlist
# repo), but nothing makes it NOTICED: customer-a-report issue #92 waited 71 days in
# awaiting_clarification while the bot's question sat on GitHub — a dashboard you
# have to remember to open fails the same way. This script is the push: it reads
# the JSON status.sh emits (stdin or --from-file <path>) and mails a Finnish
# text/plain digest of the attention/stalled runs via `gws`. Repeat-death is
# defused by a fingerprint: an unchanged situation sends nothing.
#
# It depends ONLY on status.sh's local JSON, never on gh enrichment — a #92-style
# case is purely local state, and `github: null` is a legal schema value. The
# digest writes only about what the data holds.
#
# Usage:
#   status.sh --json | status-digest.sh [flags]
#   status-digest.sh --from-file <path> [flags]
#
#   --from-file <path>   read the status JSON from a file instead of stdin (so
#                        tests need no full scan).
#   --to <address>       recipient(s), comma-separated. Overrides the env value.
#   --force              send even if the fingerprint is unchanged.
#   --dry-run            print the body that WOULD be sent to stdout; write no
#                        fingerprint and send nothing.
#   --max-silence <days> if nothing has been sent for this many days, send anyway
#                        (default 7). Silence must never read as "broken".
#   --min-class <c>      lowest class to include: attention (only attention) or
#                        stalled (attention + stalled). Default: stalled.
#
# gws is NOT a package dependency. Without it (or without a recipient) the body
# is printed to stdout and the exit is 0 — the same SKIP spirit as the tests, so
# the package stays installable without Google Workspace tooling and the digest
# can be piped to any other channel.
#
# Exit codes (own space; not the orchestrator's or status.sh's):
#   0  sent, or no send was needed (unchanged situation)
#   1  usage error (bad flag/value, or unreadable/unparseable input)
#   2  unknown schema_version — the schema contract is honoured; nothing is sent
#   3  send failed (the body is still printed to stdout for recovery)
#
# Environment (all optional; the example file documents them):
#   RUN_ISSUES_DIGEST_ENV_FILE    config file to source first (default
#                                 $HOME/.config/run-issues/digest.env)
#   RUN_ISSUES_DIGEST_TO          default recipient(s)
#   RUN_ISSUES_DIGEST_MAX_SILENCE default --max-silence days
#   RUN_ISSUES_DIGEST_MIN_CLASS   default --min-class
#   RUN_ISSUES_DIGEST_MAX_ROWS    per-group row cap before "…ja M muuta" (10)
#   RUN_ISSUES_DIGEST_SUBJECT_PREFIX  subject prefix (default "run-issues -kooste")
#   RUN_ISSUES_DIGEST_GWS         gws command (default "gws"); test injection point
#   RUN_ISSUES_DIGEST_STATE_FILE  fingerprint file (default
#                                 ${XDG_STATE_HOME:-$HOME/.local/state}/run-issues/last-digest.sha)

set -uo pipefail

# ---- config file (delivery channel under launchd, mirrors orchestrate.sh) ----
# Sourced first so RUN_ISSUES_DIGEST_* below can come from it; a shell flag still
# wins because flags are applied after. Absent file => built-in defaults.
DIGEST_ENV_FILE="${RUN_ISSUES_DIGEST_ENV_FILE:-$HOME/.config/run-issues/digest.env}"
if [ -f "$DIGEST_ENV_FILE" ]; then
  set +u
  # shellcheck disable=SC1090
  . "$DIGEST_ENV_FILE"
  set -u
fi

usage() {
  sed -n '2,44p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}
die_usage() {
  printf 'status-digest.sh: %s\n' "$1" >&2
  exit 1
}

# ---- argument parsing ----
OPT_FROM_FILE=""
OPT_TO=""
OPT_FORCE=0
OPT_DRY_RUN=0
OPT_MAX_SILENCE=""
OPT_MIN_CLASS=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --from-file) shift; [ "$#" -gt 0 ] || die_usage "--from-file needs a value"; OPT_FROM_FILE="$1" ;;
    --to)        shift; [ "$#" -gt 0 ] || die_usage "--to needs a value"; OPT_TO="$1" ;;
    --force)     OPT_FORCE=1 ;;
    --dry-run)   OPT_DRY_RUN=1 ;;
    --max-silence)
      shift; [ "$#" -gt 0 ] || die_usage "--max-silence needs a value"
      case "$1" in ''|*[!0-9]*) die_usage "--max-silence must be a non-negative integer" ;; esac
      OPT_MAX_SILENCE="$1" ;;
    --min-class)
      shift; [ "$#" -gt 0 ] || die_usage "--min-class needs a value"
      case "$1" in attention|stalled) OPT_MIN_CLASS="$1" ;; *) die_usage "--min-class must be attention or stalled" ;; esac ;;
    -h|--help)   usage; exit 0 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
  shift
done

# ---- resolve config: flag > env > default ----
TO="${OPT_TO:-${RUN_ISSUES_DIGEST_TO:-}}"
MAX_SILENCE="${OPT_MAX_SILENCE:-${RUN_ISSUES_DIGEST_MAX_SILENCE:-7}}"
case "$MAX_SILENCE" in ''|*[!0-9]*) die_usage "RUN_ISSUES_DIGEST_MAX_SILENCE must be a non-negative integer" ;; esac
MIN_CLASS="${OPT_MIN_CLASS:-${RUN_ISSUES_DIGEST_MIN_CLASS:-stalled}}"
case "$MIN_CLASS" in attention|stalled) : ;; *) die_usage "RUN_ISSUES_DIGEST_MIN_CLASS must be attention or stalled" ;; esac
MAX_ROWS="${RUN_ISSUES_DIGEST_MAX_ROWS:-10}"
case "$MAX_ROWS" in ''|*[!0-9]*) MAX_ROWS=10 ;; esac
SUBJECT_PREFIX="${RUN_ISSUES_DIGEST_SUBJECT_PREFIX:-run-issues -kooste}"
GWS_CMD="${RUN_ISSUES_DIGEST_GWS:-gws}"
STATE_FILE="${RUN_ISSUES_DIGEST_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/run-issues/last-digest.sha}"

# ---- hard dependency: jq ----
if ! command -v jq >/dev/null 2>&1; then
  printf 'status-digest.sh: jq is required but not installed (brew install jq)\n' >&2
  exit 1
fi

# ---- classes to include from min-class ----
if [ "$MIN_CLASS" = "attention" ]; then
  CLASSES='["attention"]'
else
  CLASSES='["attention","stalled"]'
fi

# ---- read input ----
if [ -n "$OPT_FROM_FILE" ]; then
  if [ ! -r "$OPT_FROM_FILE" ]; then
    printf 'status-digest.sh: cannot read --from-file %s\n' "$OPT_FROM_FILE" >&2
    exit 1
  fi
  INPUT="$(cat "$OPT_FROM_FILE")"
else
  INPUT="$(cat)"
fi

# Whitespace-only detection via glob match, NOT ${INPUT//…/}: bash 3.2 pattern
# substitution is effectively quadratic and spins for minutes on a real
# ~400 KB pretty-printed status document.
case "$INPUT" in
  *[![:space:]]*) : ;;
  *)
    printf 'status-digest.sh: empty input (expected status.sh --json)\n' >&2
    exit 1
    ;;
esac

# ---- validate JSON + schema_version ----
if ! printf '%s' "$INPUT" | jq -e . >/dev/null 2>&1; then
  printf 'status-digest.sh: input is not valid JSON\n' >&2
  exit 1
fi
SCHEMA_VERSION="$(printf '%s' "$INPUT" | jq -r '.schema_version // empty')"
if [ "$SCHEMA_VERSION" != "1" ]; then
  printf 'status-digest.sh: unknown schema_version %s (expected 1) — not sending\n' \
    "${SCHEMA_VERSION:-<missing>}" >&2
  exit 2
fi

# ---- select attention/stalled runs; count; fingerprint ----
N_SELECTED="$(printf '%s' "$INPUT" | jq --argjson classes "$CLASSES" \
  '[.runs[] | select(.class as $c | $classes | index($c))] | length')"

# Fingerprint = sha256 over the sorted (run_id, class, class_reason) list of the
# selected runs, plus whether a GitHub backoff is active (issue #126). Empty set
# => sha of a stable constant.
#
# The backoff belongs in the fingerprint because entering or leaving it IS the
# news: a rate-limited factory produces no new attention runs, so without this
# term it fingerprints identically to a quiet, healthy one and stays silent until
# the heartbeat fires days later — the exact failure this digest exists to
# prevent.
sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  else sha256sum | awk '{print $1}'; fi
}
FINGERPRINT="$(printf '%s' "$INPUT" | jq -r --argjson classes "$CLASSES" '
  (((.runner // {}) | .rate_limited_until) | if . == null then "no" else "yes" end) as $rl
  | ([.runs[] | select(.class as $c | $classes | index($c))
      | "\(.run_id)\t\(.class)\t\(.class_reason)"] | sort)
    + ["rate_limited=\($rl)"]
  | .[]' | sha256)"

# ---- read prior state (fingerprint + last-send epoch) ----
PRIOR_FP=""
PRIOR_SENT_EPOCH=0
if [ -f "$STATE_FILE" ]; then
  PRIOR_FP="$(sed -n '1p' "$STATE_FILE" 2>/dev/null)"
  _e="$(sed -n '2p' "$STATE_FILE" 2>/dev/null)"
  case "$_e" in ''|*[!0-9]*) PRIOR_SENT_EPOCH=0 ;; *) PRIOR_SENT_EPOCH="$_e" ;; esac
fi

NOW_EPOCH="$(date -u +%s)"
SILENCE_SECS=$((MAX_SILENCE * 86400))
# Silence is only "exceeded" relative to a real prior send/baseline (epoch > 0).
# A first-ever run (epoch 0) is NOT a silence overrun — it establishes the
# baseline below rather than firing an all-clear immediately. max-silence 0
# disables the heartbeat entirely.
if [ "$MAX_SILENCE" -gt 0 ] && [ "$PRIOR_SENT_EPOCH" -gt 0 ] \
   && [ "$((NOW_EPOCH - PRIOR_SENT_EPOCH))" -ge "$SILENCE_SECS" ]; then
  SILENCE_EXCEEDED=1
else
  SILENCE_EXCEEDED=0
fi

FP_CHANGED=0
[ "$FINGERPRINT" != "$PRIOR_FP" ] && FP_CHANGED=1

# ---- decide whether to send ----
# force               => always
# content present     => on change, or on silence heartbeat
# nothing to report   => only on silence heartbeat (the "kaikki kunnossa" note)
SHOULD_SEND=0
if [ "$OPT_FORCE" -eq 1 ]; then
  SHOULD_SEND=1
elif [ "$N_SELECTED" -gt 0 ]; then
  { [ "$FP_CHANGED" -eq 1 ] || [ "$SILENCE_EXCEEDED" -eq 1 ]; } && SHOULD_SEND=1
else
  [ "$SILENCE_EXCEEDED" -eq 1 ] && SHOULD_SEND=1
fi

# ---- build the Finnish text/plain body ----
GENERATED_AT="$(printf '%s' "$INPUT" | jq -r '.generated_at // "?"')"
HOST="$(printf '%s' "$INPUT" | jq -r '.host // "?"')"

# Finnish label per class_reason. Unknown reasons fall back to the raw reason.
REASON_LABELS='{
  "awaiting_review":"odottaa katselmointia",
  "blocked":"estynyt",
  "timed_out":"aikakatkaistu",
  "pr_conflicted":"PR-konflikti",
  "awaiting_clarification":"odottaa vastaustasi",
  "pr_unlabelled":"PR ilman auto-merge-labelia",
  "wedged_session":"jumittunut sessio",
  "orphaned":"orpo ajo (sessio kuollut)"
}'

build_body() {
  printf '%s' "$INPUT" | jq -r \
    --argjson classes "$CLASSES" \
    --argjson labels "$REASON_LABELS" \
    --argjson maxrows "$MAX_ROWS" \
    --arg host "$HOST" \
    --arg generated "$GENERATED_AT" \
    --arg maxsilence "$MAX_SILENCE" '
    def daysof($s): (($s // 0) / 86400) | floor;
    def rlabel($r): ($labels[$r] // $r);
    def linkof: (.issue_url // .pr_url // "(ei linkkiä)");
    def refof:
      if .issue_number != null then "#\(.issue_number)"
      elif .pr_number != null then "PR #\(.pr_number)"
      else "?" end;

    [.runs[] | select(.class as $c | $classes | index($c))] as $sel
    | ($sel | length) as $n
    | ($sel | map(.repo_path) | unique | length) as $nrepos
    | (.read_errors // [] | length) as $nerr
    | ((.runner // {}) | .rate_limited_until) as $rl
    | ((.runner // {}) | .rate_limit_backoff_seconds) as $rlsecs
    | ($sel | group_by(.class_reason)
        | map({ reason: .[0].class_reason,
                count: length,
                oldest: (map(.age_seconds // 0) | max),
                runs: (sort_by(.age_seconds // 0) | reverse) })
        | sort_by(.oldest) | reverse) as $groups
    | (
        ["\($host) — \($generated) — paikallinen data", ""]
        + (if $nerr > 0 then
             ["⚠ Vajaa luenta: \($nerr) run.json-tiedostoa lukukelvottomia — kooste voi olla epätäydellinen.", ""]
           else [] end)
        + (if $rl != null then
             ["⚠ GitHubin kutsuraja: ajo on tauolla ja jatkuu automaattisesti noin \(($rlsecs // 0) / 60 | floor) min kuluttua.",
              "  Pollerit perääntyvät eivätkä kuormita rajaa lisää. Alla oleva tilanne voi siis olla vanhentunut.", ""]
           else [] end)
        + (if $n == 0 then
             ["Kaikki kunnossa: ei huomiota vaativia ajoja.",
              "(Hiljaisuusviesti \($maxsilence) vrk:n jälkeen — kooste on elossa.)"]
           else
             ["Huomiota vaativia ajoja: \($n) (\($nrepos) repossa).",
              ("Yhteenveto: " + ([$groups[] | "\(.count) \(rlabel(.reason)) (vanhin \(daysof(.oldest)) vrk)"] | join("; "))),
              ""]
             + ([$groups[]
                 | (["▸ \(rlabel(.reason)) — \(.count) ajoa, vanhin \(daysof(.oldest)) vrk"]
                    + ([.runs[:$maxrows][]
                        | "    \(.repo_slug // "?")  \(refof)  \(daysof(.age_seconds)) vrk  \(.current_state // "-")  \(linkof)"])
                    + (if .count > $maxrows then ["    …ja \(.count - $maxrows) muuta"] else [] end)
                    + [""])]
                | add)
           end)
      )
    | join("\n")'
}

# ---- write the fingerprint state atomically (fp on line 1, send epoch on 2) ----
write_state() {
  local sent_epoch="$1" dir tmp
  dir="$(dirname "$STATE_FILE")"
  mkdir -p "$dir" 2>/dev/null || true
  tmp="$(mktemp "$dir/.last-digest.XXXXXX" 2>/dev/null)" || return 1
  printf '%s\n%s\n' "$FINGERPRINT" "$sent_epoch" > "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

# ---- act ----
if [ "$SHOULD_SEND" -eq 0 ]; then
  # Nothing to send. Start the silence clock on the very first run so the
  # heartbeat has a baseline; otherwise leave the file untouched so silence can
  # accrue toward --max-silence. --dry-run stays side-effect free (writes no
  # fingerprint), so it never seeds the baseline here.
  if [ "$OPT_DRY_RUN" -eq 0 ] && [ ! -f "$STATE_FILE" ]; then
    write_state "$NOW_EPOCH" || true
  fi
  printf 'status-digest.sh: no change (fingerprint unchanged, silence within %s d) — not sending\n' \
    "$MAX_SILENCE" >&2
  exit 0
fi

BODY="$(build_body)"

# An active GitHub backoff OWNS the subject line (issue #126). A rate-limited
# factory produces no new attention runs, so N_SELECTED is typically 0 and the
# subject would read "kaikki kunnossa" while nothing is running at all — the
# precise illusion that let the 2026-08-28 outage go unnoticed for ten hours.
RL_ACTIVE="$(printf '%s' "$INPUT" | jq -r '((.runner // {}) | .rate_limited_until) // empty' 2>/dev/null || printf '')"
if [ -n "$RL_ACTIVE" ]; then
  SUBJECT="$SUBJECT_PREFIX: GitHubin kutsuraja — ajo tauolla ($HOST)"
elif [ "$N_SELECTED" -gt 0 ]; then
  SUBJECT="$SUBJECT_PREFIX: $N_SELECTED huomiota vaativaa ajoa ($HOST)"
else
  SUBJECT="$SUBJECT_PREFIX: kaikki kunnossa ($HOST)"
fi

# --dry-run: preview only, no writes, no send.
if [ "$OPT_DRY_RUN" -eq 1 ]; then
  printf '[dry-run] Aihe: %s\n\n%s\n' "$SUBJECT" "$BODY"
  exit 0
fi

# Deliver. gws is opt-in: without it, or without a recipient, fall back to
# stdout and treat that as a successful delivery to the pipe channel.
if [ -n "$TO" ] && command -v "$GWS_CMD" >/dev/null 2>&1; then
  if "$GWS_CMD" gmail +send --to "$TO" --subject "$SUBJECT" --body "$BODY" >/dev/null 2>&1; then
    write_state "$NOW_EPOCH" || true
    printf 'status-digest.sh: sent to %s\n' "$TO" >&2
    exit 0
  else
    printf 'status-digest.sh: gws send failed — body follows on stdout\n' >&2
    printf '%s\n' "$BODY"
    exit 3
  fi
else
  # No gws / no recipient: stdout is the channel. Record the fingerprint so an
  # unchanged situation stays quiet on repeat runs.
  if [ -z "$TO" ]; then
    printf 'status-digest.sh: no recipient (set --to or RUN_ISSUES_DIGEST_TO) — body follows on stdout\n' >&2
  else
    printf 'status-digest.sh: %s not found — body follows on stdout\n' "$GWS_CMD" >&2
  fi
  printf '%s\n' "$BODY"
  write_state "$NOW_EPOCH" || true
  exit 0
fi
