#!/usr/bin/env bash
# lib/observed-defects.sh — the cycle review's inherited-defect lines to GitHub
# issues (issue #391).
#
# The cycle review reads the code around the change and sometimes sees an
# existing defect that is outside the issue's scope. The prompt
# (prompts/01-cycle-review.md, "Perityt viat") lets it record each one on a
# machine line before the decision line:
#
#   CYCLE_REVIEW_OBSERVED_DEFECT: <critical|high|medium|low> | <file:line> | <description>
#
# The orchestrator turns each line into ONE issue through lib/finding-issues.sh
# (kind and label `observed`), so the same defect seen by two runs is one issue.
# The issues never carry pickup labels: whether an inherited defect is worth a
# run is a human's call, the same rule as the coherence audit's issues.
#
# A defect line is never a gate: an unparseable line, a failed index or a failed
# write is logged and the run's outcome is unchanged. Every function returns 0.
#
# Fingerprint: source `observed`, the location without its line, and the
# description normalised (case, whitespace). Another wording of the same defect
# costs a duplicate issue; keying on the file alone would merge two defects of
# one file into one issue and lose the second — the loss this issue exists to
# end.
#
# Sourced; defines functions only and does no top-level work beyond constants.

if ! declare -F finding_issue_apply >/dev/null 2>&1; then
  # shellcheck source=finding-issues.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/finding-issues.sh"
fi

OBSERVED_DEFECT_LABEL="observed"
OBSERVED_DEFECT_KIND="observed"
OBSERVED_DEFECT_PREFIX="CYCLE_REVIEW_OBSERVED_DEFECT:"
OBSERVED_DEFECT_MAX_DEFAULT=3

_observed_trim() {
  printf '%s' "$1" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'
}

# _observed_placeholder <field> — rc 0 when the field is the prompt's own
# placeholder (`<tiedosto:rivi>`, `<kuvaus>`) copied verbatim.
_observed_placeholder() {
  case "$1" in
    "<"*">") return 0 ;;
  esac
  return 1
}

# observed_defects_parse <cr-out> — every well-formed defect line as TSV
# "<severity>\t<location>\t<description>" on stdout, in order. The description
# is everything after the second `|`, so it may contain `|` itself. A malformed
# line goes to stderr as "observed-defect: unparseable line: …". A missing file
# is no lines. rc is always 0.
observed_defects_parse() {
  local out="$1" line rest sev loc desc
  [ -f "$out" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in "$OBSERVED_DEFECT_PREFIX"*) ;; *) continue ;; esac
    rest="${line#"$OBSERVED_DEFECT_PREFIX"}"
    if [[ "$rest" != *"|"*"|"* ]]; then
      printf 'observed-defect: unparseable line: %s\n' "$line" >&2
      continue
    fi
    sev=$(_observed_trim "${rest%%|*}" | tr '[:upper:]' '[:lower:]')
    rest="${rest#*|}"
    loc=$(_observed_trim "${rest%%|*}")
    desc=$(_observed_trim "${rest#*|}" | tr '\t' ' ')
    if ! merge_gate_severity_rank "$sev" >/dev/null 2>&1 \
       || [ -z "$loc" ] || [ -z "$desc" ] \
       || _observed_placeholder "$loc" || _observed_placeholder "$desc"; then
      printf 'observed-defect: unparseable line: %s\n' "$line" >&2
      continue
    fi
    printf '%s\t%s\t%s\n' "$sev" "$loc" "$desc"
  done < "$out"
  return 0
}

# observed_defects_key <description> — the fingerprint key: lower case, inner
# whitespace runs collapsed, edges trimmed.
observed_defects_key() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' \
    | sed -E 's/^ +| +$//g'
}

# observed_defects_title <severity> <location> <description>
observed_defects_title() {
  local sev="$1" loc="$2" desc="$3" short file
  file=$(finding_location_file "$loc")
  short=$(printf '%s' "$desc" | cut -c1-90)
  [ "${#desc}" -gt 90 ] && short="$short…"
  printf 'Havaittu vika (%s): %s%s' "$sev" "$short" "${file:+ — $file}"
}

# observed_defects_body <severity> <location> <description> <owner/repo>
#                       <issue-num> <fingerprint>
observed_defects_body() {
  local sev="$1" loc="$2" desc="$3" owner_repo="$4" num="$5" fp="$6"
  cat <<EOF
## Tavoite

Korjaa vika, jonka runnerin cycle review havaitsi koodissa toteuttaessaan issueta #$num (https://github.com/$owner_repo/issues/$num). Vika on olemassa olevassa koodissa: issue #$num ei tuottanut sitä eikä korjannut sitä, koska se oli ajon rajauksen ulkopuolella.

- **Vakavuus:** $sev
- **Sijainti:** \`$loc\`
- **Havainto:** $desc

## Hyväksyntäkriteerit

- [ ] Havainto on todennettu nykyisestä koodista, ja kuvattu vika on korjattu.
- [ ] Korjaukselle on testi, jos projektissa on testejä.

## Rajaukset

- Vain tämä yksi havainto.
- Kirjattu cycle reviewn havaintona: issue ei saa poimintalabeleita, vaan ihminen päättää jatkosta. Lisää poimintalabel itse, jos haluat runnerin korjaavan vian.
- Jos havainto osoittautuu vääräksi, sulje issue tilaan *not planned*, jolloin seuraava ajo ei avaa sitä uudelleen.

$(finding_marker "$OBSERVED_DEFECT_KIND" "$fp")
EOF
}

# observed_defects_max <value> — the per-run cap: a non-negative integer, else
# the default (3).
observed_defects_max() {
  case "$1" in
    ''|*[!0-9]*) printf '%s' "$OBSERVED_DEFECT_MAX_DEFAULT" ;;
    *) printf '%s' "$((10#$1))" ;;
  esac
}

# observed_defects_record <cr-out> <owner/repo> <issue-num> <max> <index-file>
# Parse the cycle review's defect lines and file the first <max> distinct ones as
# issues. Prints one line per defect, "observed-defect: <result> <sev> <loc> —
# <desc>", where <result> is finding_issue_apply's ("created #N", "exists #N",
# "reopened #N", "dismissed #N") or FAILED; defects over the cap print
# "observed-defect: over cap (<max>), not recorded: …". Diagnostics go to
# stderr. rc is always 0: a defect line is never a gate.
observed_defects_record() {
  local out="$1" owner_repo="$2" num="$3" max index="$5"
  local rows row sev loc desc fp seen=" " kept=0 title body res comment
  max=$(observed_defects_max "$4")
  rows=$(observed_defects_parse "$out")
  [ -n "$rows" ] || return 0

  local -a keep=()
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS=$'\t' read -r sev loc desc <<<"$row"
    fp=$(finding_fingerprint "$OBSERVED_DEFECT_KIND" "$loc" "$(observed_defects_key "$desc")")
    if [[ "$seen" == *" $fp "* ]]; then
      continue
    fi
    seen="$seen$fp "
    if [ "$kept" -ge "$max" ]; then
      printf 'observed-defect: over cap (%s), not recorded: %s %s — %s\n' "$max" "$sev" "$loc" "$desc"
      continue
    fi
    kept=$((kept + 1))
    keep+=("$fp"$'\t'"$row")
  done <<EOF
$rows
EOF
  [ "${#keep[@]}" -gt 0 ] || return 0

  if ! finding_issues_index "$owner_repo" "$OBSERVED_DEFECT_LABEL" "$index"; then
    echo "observed-defect: listing the $OBSERVED_DEFECT_LABEL issues of $owner_repo failed — nothing recorded" >&2
    return 0
  fi

  comment="Cycle review havaitsi tämän vian uudelleen ajossa #$num (https://github.com/$owner_repo/issues/$num)."
  for row in "${keep[@]}"; do
    IFS=$'\t' read -r fp sev loc desc <<<"$row"
    title=$(observed_defects_title "$sev" "$loc" "$desc")
    body=$(observed_defects_body "$sev" "$loc" "$desc" "$owner_repo" "$num" "$fp")
    if res=$(finding_issue_apply "$owner_repo" "$index" "$OBSERVED_DEFECT_KIND" "$fp" \
               "$title" "$body" "$OBSERVED_DEFECT_LABEL" "$comment"); then
      printf 'observed-defect: %s %s %s — %s\n' "$res" "$sev" "$loc" "$desc"
    else
      printf 'observed-defect: FAILED %s %s — %s\n' "$sev" "$loc" "$desc"
    fi
  done
  return 0
}
