#!/usr/bin/env bash
# test-skill-labels.sh — the claude-issue-runner skill is a THIRD copy of the
# label conventions (README §6.3 and CLAUDE.md are the other two). It is the
# most dangerous copy to let drift: it loads into a session in a FOREIGN repo,
# where the reader has no README beside them to cross-check. This test pins the
# skill's label claims to the SOURCE OF TRUTH — the scripts — the same way
# test-readme.sh derives its exit-code expectations from the scripts.
#
# What it guards:
#   a) the hardcoded labels the skill names (waiting, wip, needs-human,
#      auto-clean-skipped) each appear in the code
#   b) the labels the skill marks configurable (auto-clean / RUN_ISSUES_CLEAN_LABEL,
#      auto-merge / PR_WATCH_MERGE_LABEL) are configurable in the code, and the
#      skill names their env var rather than presenting the name as fixed
#   c) the pickup query's negative label terms (-label:waiting -label:wip
#      -label:<clean>) in lib/issue.sh match the labels the skill claims block
#      pickup
#   d) BIDIRECTIONAL coverage: the FULL label vocabulary derived from the code
#      is named in the skill. (a)-(c) only walk skill→code, so a label added to
#      the code would silently never reach the skill; case 5 walks code→skill
#      and turns that into a red test.
#
# This test WRITES NOTHING and needs no $HOME. It only reads repository files.
#
# Run: bash tests/test-skill-labels.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FAIL=0

SKILL="$ROOT/skills/claude-issue-runner/SKILL.md"
ISSUE_LIB="$ROOT/lib/issue.sh"

# ---- Case 1: skill exists ----
# Exit immediately if it is missing: every later case would report the same
# single cause otherwise, drowning the real signal.
if [ ! -s "$SKILL" ]; then
  echo "FAIL: skill missing or empty at $SKILL"
  echo "----------------------------------------"
  echo "skill-labels: FAILURES"
  exit 1
fi
echo "PASS: claude-issue-runner/SKILL.md exists and is non-empty"

# Sources in which a label literal is considered "present in the code". Kept
# broad on purpose: the point is that the label is real, not where it lives.
CODE_FILES=("$ROOT"/lib/*.sh "$ROOT"/*.sh)

# Word-boundary matching so a label is not "found" as a substring of a longer
# token (needs-human must not match inside needs-humann). Hyphens are word
# separators for grep -w, so multi-part labels are matched at their real edges.
label_in_code() {
  local label="$1"
  grep -qwF -- "$label" "${CODE_FILES[@]}" 2>/dev/null
}
label_in_skill() {
  local label="$1"
  grep -qwF -- "$label" "$SKILL"
}

# ---- Case 2: hardcoded labels the skill names exist in the code ----
# These are the labels the skill presents as fixed. If the code renamed one, the
# skill would be teaching a foreign repo a label that no longer does anything.
for label in waiting wip needs-human auto-clean-skipped; do
  in_skill=0; in_code=0
  label_in_skill "$label" && in_skill=1
  label_in_code "$label" && in_code=1
  if [ "$in_skill" -eq 1 ] && [ "$in_code" -eq 1 ]; then
    echo "PASS: hardcoded label '$label' present in both skill and code"
  else
    echo "FAIL: hardcoded label '$label' skill=$in_skill code=$in_code (expected both 1)"; FAIL=1
  fi
done

# ---- Case 3: configurable labels are marked configurable, not fixed ----
# The skill must name the env var, so a reader does not assume the default name
# is the only possibility. And the code must actually honour that env var.
assert_configurable() {
  local label="$1" var="$2" default="$3"
  # The code defines the var with the documented default.
  if grep -qE "$var=\"?\\\$\{$var:-$default\}" "${CODE_FILES[@]}" 2>/dev/null; then
    echo "PASS: code makes '$label' configurable via $var (default $default)"
  else
    echo "FAIL: code does not define $var with default '$default'"; FAIL=1
  fi
  # The skill mentions the env var (marks the label configurable).
  if grep -qF -- "$var" "$SKILL"; then
    echo "PASS: skill marks '$label' configurable via $var"
  else
    echo "FAIL: skill presents '$label' without naming $var — reads as fixed"; FAIL=1
  fi
}
assert_configurable auto-clean RUN_ISSUES_CLEAN_LABEL auto-clean
assert_configurable auto-merge PR_WATCH_MERGE_LABEL auto-merge

# ---- Case 4: pickup-query negative labels match the skill's blocker claim ----
# The authoritative pickup query lives in lib/issue.sh. Extract its hardcoded
# -label: terms (the configurable clean label expands from a variable and is
# handled separately in case 3) and assert the skill names each as a blocker.
QUERY_LINE="$(grep -nE 'is:open no:assignee .*-is:blocked' "$ISSUE_LIB" | grep -v '^\s*#' | head -1)"
if [ -z "$QUERY_LINE" ]; then
  echo "FAIL: could not locate the pickup query in $ISSUE_LIB — its shape changed"; FAIL=1
else
  echo "PASS: pickup query located in lib/issue.sh"
  # Pull out -label:<word> terms whose target is a literal (not a ${var}).
  NEG_LABELS="$(printf '%s\n' "$QUERY_LINE" | grep -oE -- '-label:[a-z-]+' | sed 's/^-label://' | sort -u)"
  if [ -z "$NEG_LABELS" ]; then
    echo "FAIL: no literal -label: terms parsed from the pickup query"; FAIL=1
  fi
  while IFS= read -r lbl; do
    [ -n "$lbl" ] || continue
    if label_in_skill "$lbl"; then
      echo "PASS: pickup-blocker '$lbl' from the query is named in the skill"
    else
      echo "FAIL: pickup-blocker '$lbl' from the query is not named in the skill"; FAIL=1
    fi
  done <<< "$NEG_LABELS"
fi

# ---- Case 5: the code's full label vocabulary is named in the skill ----
# Cases 2-4 walk skill→code. This one walks code→skill: derive every label the
# package actually writes or filters on, and require the skill to name each. A
# new label introduced in the code without a skill row is a red test.
#
# Four derivation sources, because no single one is complete:
#   1. the pickup query's literal -label: terms          (lib/issue.sh)
#   2. the label ARGUMENT of every labels_add/remove/ensure call site
#      (lib/*.sh + root *.sh, minus lib/labels.sh which defines them). Read
#      POSITIONALLY (add/remove: 3rd arg, ensure: 2nd arg) so a Finnish label
#      DESCRIPTION string is never mistaken for a label name.
#   3. *_LABEL="<literal>" assignments (the fixed names held in variables)
#   4. the documented defaults of the configurable ones, incl. the poller's
#      default pickup label

derived_labels() {
  {
    # 1. pickup query literals (the ${clean_label} term is a variable → source 4)
    grep -hE 'is:open no:assignee .*-is:blocked' "$ISSUE_LIB" \
      | grep -v '^[[:space:]]*#' \
      | grep -oE -- '-label:[a-z][a-z0-9-]*' | sed 's/^-label://'

    # 2. label argument of each call site, by position. awk locates the call
    # token itself and steps to its label argument — a `sed` cut on the line
    # would mis-fire on wrappers like `do_or_dry remote "unlabel" labels_remove …`
    # and on any line where the call is not the first token.
    for f in "${CODE_FILES[@]}"; do
      case "$f" in */lib/labels.sh) continue ;; esac
      [ -f "$f" ] || continue
      grep -v '^[[:space:]]*#' "$f" | awk '
        {
          for (i = 1; i <= NF; i++) {
            if ($i == "labels_add" || $i == "labels_remove") off = 3
            else if ($i == "labels_ensure") off = 2
            else continue
            if (i + off <= NF) print $(i + off)
          }
        }' | tr -d '"'"'"'\\'
    done

    # 3. fixed names held in *_LABEL variables
    grep -hoE '[A-Z_]*LABEL="[a-z][a-z0-9-]*"' "${CODE_FILES[@]}" 2>/dev/null \
      | sed 's/.*="//; s/"$//'

    # 4. documented defaults of the configurable labels + the poller's default
    grep -hoE '\$\{RUN_ISSUES_CLEAN_LABEL:-[a-z][a-z0-9-]*\}' "${CODE_FILES[@]}" 2>/dev/null \
      | sed 's/.*:-//; s/}$//'
    grep -hoE '\$\{PR_WATCH_MERGE_LABEL:-[a-z][a-z0-9-]*\}' "${CODE_FILES[@]}" 2>/dev/null \
      | sed 's/.*:-//; s/}$//'
    grep -hoE 'default_labels // \["[a-z][a-z0-9-]*"\]' "$ROOT/poller.sh" 2>/dev/null \
      | sed 's/.*\["//; s/"\]//'
  } | grep -E '^[a-z][a-z0-9-]*$' | sort -u
}

DERIVED="$(derived_labels)"
DERIVED_COUNT="$(printf '%s\n' "$DERIVED" | grep -c '[a-z]')"

# FAIL-CLOSED: a derivation that silently stopped matching would let the skill
# pass with an EMPTY expectation set — the exact failure this case exists to
# prevent. Require a plausible floor and a known anchor before comparing.
if [ "$DERIVED_COUNT" -lt 8 ] || ! printf '%s\n' "$DERIVED" | grep -qx 'needs-human'; then
  echo "FAIL: label derivation broke — got $DERIVED_COUNT label(s), anchor 'needs-human' missing?"
  printf '%s\n' "$DERIVED" | sed 's/^/      derived: /'
  FAIL=1
else
  echo "PASS: derived $DERIVED_COUNT labels from the code ($(printf '%s' "$DERIVED" | tr '\n' ' '))"
  while IFS= read -r lbl; do
    [ -n "$lbl" ] || continue
    if label_in_skill "$lbl"; then
      echo "PASS: code label '$lbl' is named in the skill"
    else
      echo "FAIL: code label '$lbl' is NOT named in the skill"; FAIL=1
    fi
  done <<< "$DERIVED"
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "skill-labels: all passed" || echo "skill-labels: FAILURES"
[ "$FAIL" -eq 0 ]
