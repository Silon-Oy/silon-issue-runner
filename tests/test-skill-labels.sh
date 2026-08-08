#!/usr/bin/env bash
# test-skill-labels.sh — the run-issues-workflow skill is a THIRD copy of the
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
#
# This test WRITES NOTHING and needs no $HOME. It only reads repository files.
#
# Run: bash tests/test-skill-labels.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FAIL=0

SKILL="$ROOT/skills/run-issues-workflow/SKILL.md"
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
echo "PASS: run-issues-workflow/SKILL.md exists and is non-empty"

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

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "skill-labels: all passed" || echo "skill-labels: FAILURES"
[ "$FAIL" -eq 0 ]
