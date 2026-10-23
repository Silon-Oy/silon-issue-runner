#!/usr/bin/env bash
# lib/security-scan.sh — optional deterministic security scanners (issue #336).
#
# A scanner finds a leaked secret or a known-vulnerable dependency version more
# reliably than a language model. Scanners are OPTIONAL: the package neither
# installs nor requires them (README §2). An installed scanner runs; a missing
# one is a recorded no-op ("not installed"); an installed scanner that FAILED is
# never a clean result — the failure is part of the output.
#
# Supported scanners (licences checked in #336 — no GPL/AGPL scanner is added
# without the maintainer's explicit permission; trufflehog is AGPL-3.0):
#
#   gitleaks     (MIT)         secrets. Needs a gitleaks with the `git`
#                              subcommand (8.19+); an older one shows as FAILED.
#   osv-scanner  (Apache-2.0)  known vulnerabilities in lockfiles (network).
#
# Public interface (stable — the merge gate in pr-watch.sh and the whole-repo
# audit of #339 both call it):
#
#   security_scan <diff|audit> <repo-dir> <out-dir> [<base-ref>]
#     diff   scan what <base-ref>..HEAD adds: gitleaks over those commits,
#            osv-scanner over the lockfiles the diff changes, reporting only
#            vulnerabilities the base's version of the lockfile did not have.
#            The scanners' config/ignore files are taken from the merge base,
#            not from the head under review: a change must not be able to
#            silence the scanner that reviews it. Changes to those files, and
#            added `gitleaks:allow` markers, are findings of their own.
#     audit  scan the whole repository: gitleaks over the full history,
#            osv-scanner recursively, with the repo's own scanner config.
#     Writes ONLY into <out-dir> (created; never into <repo-dir>):
#       scan.findings  severity|confidence|location|description per line — the
#                      normalised form of lib/merge-gate.sh (merge_gate_findings)
#       scan.summary   one human-readable line per scanner (OK / not installed /
#                      FAILED with rc and a stderr excerpt)
#       scan.failed    scanner|rc|reason per scanner that failed
#     rc 0 whenever the function itself worked — a scanner failing is data, not
#     an error. rc 1 on a usage error (unknown mode, diff without a resolvable
#     base-ref, unwritable out-dir); then nothing is a result.
#
#   security_scan_gate_findings <out-dir>
#     scan.findings plus one `low|high|<scanner>|…` row per failed scanner, so a
#     failure shows in the result instead of reading as clean. A missing out-dir
#     (the scan never ran) yields a single failure row of its own.
#
#   security_scan_prompt_text <out-dir>
#     The summary and the findings as text for a reviewer's prompt.
#
# Severity: a gitleaks finding is always `high` (never less — a secret the
# scanner found is not the reviewer's to downgrade). osv-scanner by CVSS score:
# >= 9 critical, >= 7 high, >= 4 medium, else low; no score => the advisory's
# own rating, else `medium`. A secret's value is never written anywhere: only
# the rule id, the rule description and the location.
#
# Env:
#   RUN_ISSUES_GITLEAKS_BIN            gitleaks binary (default: command -v gitleaks)
#   RUN_ISSUES_OSV_SCANNER_BIN         osv-scanner binary (default: command -v osv-scanner)
#   RUN_ISSUES_SECURITY_SCAN_TIMEOUT   per-scanner-call time cap in seconds (default 600)
#
# Sourced; defines functions only and does no top-level work.

SECURITY_SCANNERS="gitleaks osv-scanner"

# Lockfile basenames osv-scanner parses (diff mode scans the changed ones).
SECURITY_SCAN_LOCKFILES="package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml bun.lock composer.lock Gemfile.lock gems.locked go.mod Cargo.lock poetry.lock Pipfile.lock pdm.lock uv.lock requirements.txt mix.lock pubspec.lock gradle.lockfile buildscript-gradle.lockfile pom.xml packages.lock.json renv.lock conan.lock"

# gitleaks exits with this code when it found leaks, so that a leak (with a
# report) is told apart from a fatal error (gitleaks exits 1 on those).
_SECURITY_SCAN_GITLEAKS_LEAK_RC=99

# security_scan_bin <scanner> — the scanner's binary path; rc 1 if not
# installed. An override pointing at a non-executable path is "not installed"
# too (tests use that to hide a real scanner on the machine).
security_scan_bin() {
  local var bin
  case "$1" in
    gitleaks)    var="RUN_ISSUES_GITLEAKS_BIN" ;;
    osv-scanner) var="RUN_ISSUES_OSV_SCANNER_BIN" ;;
    *) return 1 ;;
  esac
  bin="${!var:-}"
  if [ -n "$bin" ]; then
    [ -x "$bin" ] && [ ! -d "$bin" ] || return 1
    printf '%s' "$bin"
    return 0
  fi
  bin=$(command -v "$1" 2>/dev/null) || return 1
  [ -n "$bin" ] || return 1
  printf '%s' "$bin"
}

# _security_scan_run <stdout-file> <stderr-file> <cmd...> — run one scanner call
# under the time cap (when a timeout binary exists: preflight_timeout_bin is the
# single source of that detection, so without lib/preflight.sh the call is
# uncapped). Prints the exit code; the call's own rc is never fatal.
_security_scan_run() {
  local out="$1" err="$2" tbin="" rc=0
  shift 2
  if declare -F preflight_timeout_bin >/dev/null 2>&1; then
    tbin=$(preflight_timeout_bin)
  fi
  if [ -n "$tbin" ]; then
    "$tbin" "${RUN_ISSUES_SECURITY_SCAN_TIMEOUT:-600}" "$@" >"$out" 2>"$err" </dev/null || rc=$?
  else
    "$@" >"$out" 2>"$err" </dev/null || rc=$?
  fi
  printf '%s' "$rc"
}

# _security_scan_excerpt <file> — the tail of a stderr file as one short line.
_security_scan_excerpt() {
  tail -n 3 "$1" 2>/dev/null | tr '\n\r\t' '   ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//' | cut -c1-300
}

# _security_scan_fail <out-dir> <scanner> <rc> <reason>
_security_scan_fail() {
  local reason
  reason=$(printf '%s' "$4" | tr '|\n' '/ ')
  printf '%s|%s|%s\n' "$2" "$3" "$reason" >> "$1/scan.failed"
  printf '%s: EPÄONNISTUI (rc=%s): %s\n' "$2" "$3" "${reason:-ei virhetulostetta}" >> "$1/scan.summary"
}

# _security_scan_ok <out-dir> <scanner> <count> [<note>]
_security_scan_ok() {
  printf '%s: OK, %s löydöstä%s\n' "$2" "$3" "${4:+ ($4)}" >> "$1/scan.summary"
}

# _security_scan_added_lines <repo-dir> <merge-base> — "file:line<TAB>text" for
# every line the diff merge-base..HEAD adds.
_security_scan_added_lines() {
  ( cd "$1" && git diff --no-color --no-ext-diff -U0 "$2" HEAD 2>/dev/null ) | awk '
    /^\+\+\+ / { f = substr($0, 5); sub(/^b\//, "", f); next }
    /^@@ / {
      h = $0; sub(/^@@ -[0-9,]+ \+/, "", h); sub(/[ ,].*$/, "", h); n = h + 0; next
    }
    /^\+/ { print f ":" n "\t" substr($0, 2); n++ }'
}

# ----- gitleaks --------------------------------------------------------------

# _security_scan_gitleaks <mode> <repo-dir> <out-dir> <bin> [<range> <merge-base>]
_security_scan_gitleaks() {
  local mode="$1" repo="$2" out="$3" bin="$4" range="${5:-}" mb="${6:-}"
  local report="$out/gitleaks.json" rc
  local -a args=(git "$repo" --no-banner --redact --report-format json
    --report-path "$report" --exit-code "$_SECURITY_SCAN_GITLEAKS_LEAK_RC")
  rm -f "$report"

  if [ "$mode" = "diff" ]; then
    # Pin the config and the ignore list to the merge base (see the header).
    local cfg="$out/gitleaks-base.toml" ign="$out/gitleaks-base-ignore"
    mkdir -p "$ign"
    if ! ( cd "$repo" && git show "$mb:.gitleaks.toml" ) > "$cfg" 2>/dev/null; then
      printf '[extend]\nuseDefault = true\n' > "$cfg"
    fi
    ( cd "$repo" && git show "$mb:.gitleaksignore" ) > "$ign/.gitleaksignore" 2>/dev/null \
      || rm -f "$ign/.gitleaksignore"
    args+=(--config "$cfg" --gitleaks-ignore-path "$ign" --log-opts "$range")
  fi

  rc=$(cd "$out" && _security_scan_run "$out/gitleaks.stdout" "$out/gitleaks.stderr" "$bin" "${args[@]}")
  if [ "$rc" != 0 ] && [ "$rc" != "$_SECURITY_SCAN_GITLEAKS_LEAK_RC" ]; then
    _security_scan_fail "$out" gitleaks "$rc" "$(_security_scan_excerpt "$out/gitleaks.stderr")"
    return 0
  fi
  local rows
  if ! rows=$(jq -r '
        def clean: tostring | gsub("[|\r\n\t]"; " ");
        if type != "array" then error("not an array") else .[] end
        | "high|high|\((.File // "?") | clean):\(.StartLine // 0)|gitleaks: \((.RuleID // "?") | clean) — \((.Description // "salaisuus") | clean)"
          + (if (.Commit // "") != "" then " (commit \(.Commit[0:12]))" else "" end)
          + ". Arvo on jo historiassa: avain on kierrätettävä, pelkkä poisto ei riitä"
      ' "$report" 2>/dev/null); then
    _security_scan_fail "$out" gitleaks "$rc" "raportti puuttui tai ei ollut jäsennettävää JSONia"
    return 0
  fi
  if [ "$rc" = "$_SECURITY_SCAN_GITLEAKS_LEAK_RC" ] && [ -z "$rows" ]; then
    _security_scan_fail "$out" gitleaks "$rc" "gitleaks ilmoitti vuodosta, mutta raportti oli tyhjä"
    return 0
  fi

  if [ "$mode" = "diff" ]; then
    # Tamper signal: the head cannot change what reviews it unnoticed.
    local f
    while IFS= read -r f; do
      case "${f##*/}" in
        .gitleaks.toml|.gitleaksignore)
          rows+=$'\n'"high|medium|$f|PR muuttaa gitleaksin konfiguraatiota tai poikkeuslistaa; skannaus käytti merge-basen versiota, mutta muutos voi vaientaa skannerin mergen jälkeen" ;;
      esac
    done < <(cd "$repo" && git diff --name-only "$mb" HEAD 2>/dev/null)
    while IFS=$'\t' read -r f _; do
      [ -n "$f" ] && rows+=$'\n'"high|medium|${f//|//}|PR lisää gitleaks:allow-merkinnän, joka ohittaa salaisuusskannauksen tällä rivillä"
    done < <(_security_scan_added_lines "$repo" "$mb" | grep -F 'gitleaks:allow' || true)
  fi

  rows=$(printf '%s\n' "$rows" | grep . || true)
  [ -n "$rows" ] && printf '%s\n' "$rows" >> "$out/scan.findings"
  _security_scan_ok "$out" gitleaks "$(printf '%s' "$rows" | grep -c . || true)"
}

# ----- osv-scanner -------------------------------------------------------------

# _security_scan_osv_rows <json-file> — "key<TAB>finding-row" per vulnerability
# group; the key (path, package, version, ids) lets diff mode drop what the base
# already had. Location is source.path as reported. rc 1 on unparseable JSON.
_security_scan_osv_rows() {
  jq -r '
    def clean: tostring | gsub("[|\r\n\t]"; " ");
    def sevof($score; $db):
      if $score != null then
        (if $score >= 9 then "critical" elif $score >= 7 then "high"
         elif $score >= 4 then "medium" else "low" end)
      else
        ({"CRITICAL":"critical","HIGH":"high","MODERATE":"medium","MEDIUM":"medium","LOW":"low"}[($db // "") | ascii_upcase] // "medium")
      end;
    if type != "object" then error("not an object") else . end
    | (.results // [])[] | (.source.path // "?") as $path
    | (.packages // [])[] | .package as $pkg | (.vulnerabilities // []) as $vulns
    | ((.groups // []) | if length > 0 then . else [$vulns[] | {ids: [.id]}] end)[]
    | .ids as $ids
    | ([$vulns[] | select(.id as $i | $ids | index($i))] | first) as $v
    | (try ((.max_severity // "") | tostring | tonumber) catch null) as $score
    | sevof($score; $v.database_specific.severity // null) as $sev
    | ($ids | join(",")) as $idtxt
    | "\($path)\t\($pkg.name)\t\($pkg.version)\t\($idtxt)\t"
      + "\($sev)|high|\($path | clean)|osv-scanner: \($pkg.name | clean)@\(($pkg.version // "?") | clean) (\(($pkg.ecosystem // "?") | clean)): \($idtxt | clean)"
      + (if ($v.summary // "") != "" then " — \($v.summary | clean)" else "" end)
  ' "$1" 2>/dev/null
}

# _security_scan_osv_call <out-dir> <bin> <tag> <config|-> <args...> — one
# osv-scanner call; prints "key<TAB>row" lines. rc 1 (after recording the
# failure) if the call failed. osv-scanner rc: 0 none, 1 vulnerabilities,
# 128 no package sources found (= nothing to scan, not a failure).
_security_scan_osv_call() {
  local out="$1" bin="$2" tag="$3" cfg="$4" rc
  shift 4
  local -a args=(--format json)
  [ "$cfg" != "-" ] && args+=(--config "$cfg")
  rc=$(cd "$out" && _security_scan_run "$out/osv-$tag.json" "$out/osv-$tag.stderr" "$bin" "${args[@]}" "$@")
  case "$rc" in
    128) return 0 ;;
    0|1) ;;
    *) _security_scan_fail "$out" osv-scanner "$rc" "$(_security_scan_excerpt "$out/osv-$tag.stderr")"; return 1 ;;
  esac
  if ! _security_scan_osv_rows "$out/osv-$tag.json"; then
    _security_scan_fail "$out" osv-scanner "$rc" "tuloste ei ollut jäsennettävää JSONia"
    return 1
  fi
}

# _security_scan_osv <mode> <repo-dir> <out-dir> <bin> [<merge-base>]
_security_scan_osv() {
  local mode="$1" repo="$2" out="$3" bin="$4" mb="${5:-}"
  local rows=""

  if [ "$mode" = "audit" ]; then
    local raw
    raw=$(_security_scan_osv_call "$out" "$bin" audit - -r "$repo") || return 0
    # Repo-relative locations; the prefix is stripped in awk, not passed through
    # jq, so a path never crosses a native-binary boundary (CLAUDE.md §5.8).
    rows=$(printf '%s\n' "$raw" | grep . | cut -f5- | awk -F'|' -v p="$repo/" -v OFS='|' '
      index($3, p) == 1 { $3 = substr($3, length(p) + 1) } { print }' || true)
  else
    local -a changed=()
    local f base
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      for base in $SECURITY_SCAN_LOCKFILES; do
        [ "${f##*/}" = "$base" ] && [ -f "$repo/$f" ] && changed+=("$f")
      done
    done < <(cd "$repo" && git diff --name-only --diff-filter=AMR "$mb" HEAD 2>/dev/null)

    # The config is pinned to the merge base (an empty one when it has none),
    # so a head-added osv-scanner.toml cannot ignore its own vulnerabilities.
    local cfg="$out/osv-scanner-base.toml" tamper=""
    ( cd "$repo" && git show "$mb:osv-scanner.toml" ) > "$cfg" 2>/dev/null || : > "$cfg"
    while IFS= read -r f; do
      [ "${f##*/}" = "osv-scanner.toml" ] && \
        tamper+="high|medium|$f|PR muuttaa osv-scannerin konfiguraatiota; skannaus käytti merge-basen juuren versiota, mutta muutos voi ohittaa haavoittuvuuksia mergen jälkeen"$'\n'
    done < <(cd "$repo" && git diff --name-only "$mb" HEAD 2>/dev/null)

    if [ "${#changed[@]}" -eq 0 ]; then
      [ -n "$tamper" ] && printf '%s' "$tamper" >> "$out/scan.findings"
      _security_scan_ok "$out" osv-scanner "$(printf '%s' "$tamper" | grep -c . || true)" "diff ei muuta lukkotiedostoja"
      return 0
    fi

    local i=0 head_raw base_raw known line key
    for f in "${changed[@]}"; do
      i=$((i + 1))
      head_raw=$(_security_scan_osv_call "$out" "$bin" "head-$i" "$cfg" -L "$repo/$f") || return 0
      known=""
      if ( cd "$repo" && git cat-file -e "$mb:$f" ) 2>/dev/null; then
        # Same basename in its own directory: osv-scanner picks the parser by name.
        mkdir -p "$out/osv-base-$i"
        ( cd "$repo" && git show "$mb:$f" ) > "$out/osv-base-$i/${f##*/}" 2>/dev/null
        base_raw=$(_security_scan_osv_call "$out" "$bin" "base-$i" "$cfg" -L "$out/osv-base-$i/${f##*/}") || return 0
        known=$(printf '%s\n' "$base_raw" | grep . | cut -f2-4 || true)
      fi
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        key=$(printf '%s' "$line" | cut -f2-4)
        if [ -n "$known" ] && printf '%s\n' "$known" | grep -qxF -- "$key"; then continue; fi
        # Location: the repo-relative lockfile, not the scanner's absolute path.
        rows+=$(printf '%s' "$line" | cut -f5- | awk -F'|' -v OFS='|' -v l="$f" '{ $3 = l; print }')$'\n'
      done <<<"$head_raw"
    done
    rows+="$tamper"
  fi

  rows=$(printf '%s\n' "$rows" | grep . | awk '!seen[$0]++' || true)
  [ -n "$rows" ] && printf '%s\n' "$rows" >> "$out/scan.findings"
  _security_scan_ok "$out" osv-scanner "$(printf '%s' "$rows" | grep -c . || true)" \
    "$([ "$mode" = diff ] && echo "vain merge-basesta puuttuvat haavoittuvuudet")"
}

# ----- public ------------------------------------------------------------------

security_scan() {
  local mode="$1" repo="$2" out="$3" base_ref="${4:-}"
  case "$mode" in
    diff|audit) ;;
    *) echo "security_scan: unknown mode '$mode' (want diff|audit)" >&2; return 1 ;;
  esac
  if [ -z "$repo" ] || ! ( cd "$repo" && git rev-parse --git-dir ) >/dev/null 2>&1; then
    echo "security_scan: '$repo' is not a git repository" >&2
    return 1
  fi
  mkdir -p "$out" 2>/dev/null && : > "$out/scan.findings" 2>/dev/null || {
    echo "security_scan: cannot write to '$out'" >&2
    return 1
  }
  out=$(cd "$out" && pwd)
  repo=$(cd "$repo" && pwd)
  : > "$out/scan.summary"
  : > "$out/scan.failed"

  local mb="" range=""
  if [ "$mode" = "diff" ]; then
    if [ -z "$base_ref" ] || ! mb=$(cd "$repo" && git merge-base "$base_ref" HEAD 2>/dev/null) || [ -z "$mb" ]; then
      echo "security_scan: diff mode needs a base-ref with a merge base against HEAD (got '$base_ref')" >&2
      return 1
    fi
    range="$base_ref..HEAD"
  fi

  local s bin
  for s in $SECURITY_SCANNERS; do
    if ! bin=$(security_scan_bin "$s"); then
      printf '%s: ei asennettu — skanneria %s ei ole asennettu, joten sen kattamaa luokkaa ei tarkistettu deterministisesti\n' "$s" "$s" >> "$out/scan.summary"
      continue
    fi
    case "$s" in
      gitleaks)    _security_scan_gitleaks "$mode" "$repo" "$out" "$bin" "$range" "$mb" ;;
      osv-scanner) _security_scan_osv "$mode" "$repo" "$out" "$bin" "$mb" ;;
    esac
  done
  return 0
}

security_scan_gate_findings() {
  local out="$1"
  if [ ! -f "$out/scan.summary" ]; then
    printf 'low|high|security-scan|deterministinen skannaus ei käynnistynyt, joten salaisuuksia ja riippuvuuksia ei tarkistettu skannerilla\n'
    return 0
  fi
  grep . "$out/scan.findings" 2>/dev/null || true
  local s rc reason
  while IFS='|' read -r s rc reason; do
    [ -n "$s" ] || continue
    printf 'low|high|%s|skanneri %s epäonnistui (rc=%s), joten sen kattamaa luokkaa ei tarkistettu: %s\n' \
      "$s" "$s" "$rc" "${reason:-ei virhetulostetta}"
  done < "$out/scan.failed"
}

security_scan_prompt_text() {
  local out="$1"
  if [ ! -f "$out/scan.summary" ]; then
    printf 'Deterministinen skannaus ei käynnistynyt. Arvioi salaisuudet ja riippuvuudet itse.\n'
    return 0
  fi
  printf 'Skannerit:\n'
  sed 's/^/- /' "$out/scan.summary"
  if grep -q . "$out/scan.findings" 2>/dev/null; then
    printf '\nSkannerien löydökset (vakavuus | varmuus | sijainti | kuvaus):\n'
    sed -e 's/|/ | /g' -e 's/^/- /' "$out/scan.findings"
  else
    printf '\nSkannerit eivät löytäneet mitään.\n'
  fi
}
