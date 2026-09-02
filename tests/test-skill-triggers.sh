#!/usr/bin/env bash
# test-skill-triggers.sh — a skill is a CONDITIONAL loader: the model reads only
# the `description` and decides from it whether to pull the body in. That makes
# the description the whole contract, and it makes two mistakes invisible.
#
#   1. A description with no real trigger ("always when you write code") either
#      never fires or fires on everything. An always-on rule belongs in
#      principles/coding.md, which is loaded unconditionally; putting it behind a
#      description is how it stops being applied without anyone noticing.
#   2. A body that names ANOTHER skill this package does not ship is confident
#      wrong instruction with no error anywhere — the reader is told to reach for
#      something that is not there. The same silent failure the skill surface
#      test (test-skill-surface.sh) pins for commands and scripts.
#
# This test is the mechanical half of both rules, for EVERY shipped skill:
#
#   Case 1  every skills/<name>/ has a non-empty SKILL.md (fail-closed floor)
#   Case 2  frontmatter parses and carries name / description / when_to_use / version
#   Case 3  frontmatter `name` equals the directory name (the directory is what
#           install.sh links, the field is what the model addresses)
#   Case 4  no description states an unconditional trigger
#   Case 5  the reference extractor still works (FAIL-CLOSED self-test)
#   Case 6  every skill a skill names is a skill this package ships
#   Case 7  the trigger-conditional skills are present by name
#
# This test WRITES NOTHING and needs no $HOME. It only reads repository files.
#
# Run: bash tests/test-skill-triggers.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FAIL=0

# ---- Case 1: enumerate the shipped skills ----
# Fail-closed: an empty set would let every later case pass vacuously, which is
# the failure this file exists to prevent.
SKILLS=""
for d in "$ROOT/skills"/*/; do
  [ -d "$d" ] || continue
  SKILLS="$SKILLS $(basename "$d")"
done
SKILLS="$(printf '%s\n' $SKILLS | sort -u)"
SKILL_COUNT="$(printf '%s\n' "$SKILLS" | grep -c '[^[:space:]]')"

if [ "$SKILL_COUNT" -lt 1 ]; then
  echo "FAIL: no skills found under $ROOT/skills — enumeration broke?"
  echo "----------------------------------------"
  echo "skill-triggers: FAILURES"
  exit 1
fi
echo "PASS: found $SKILL_COUNT shipped skill(s)"

for name in $SKILLS; do
  f="$ROOT/skills/$name/SKILL.md"
  if [ -s "$f" ]; then
    echo "PASS: skills/$name/SKILL.md exists and is non-empty"
  else
    echo "FAIL: skills/$name/ has no non-empty SKILL.md"; FAIL=1
  fi
done

# Frontmatter is the leading block between the first two `---` lines. Read with
# awk rather than a YAML parser: the package has no YAML dependency, and every
# field this test cares about is a single `key: value` line.
frontmatter() {
  awk 'NR==1 && $0=="---" { inb=1; next }
       inb && $0=="---" { exit }
       inb { print }' "$1"
}

field() {
  frontmatter "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -1
}

# ---- Cases 2-4: per-skill frontmatter contract ----
# The always-words are matched whole-word and case-insensitively. "aina" is a
# Finnish word that appears inside ordinary words ("ainoa", "ainakin"), so a
# substring match here would refuse forever — and a gate that refuses forever
# teaches people to ignore it.
ALWAYS_WORDS="aina always"
ALWAYS_PHRASES="every time|any time|each time|at all times"

for name in $SKILLS; do
  f="$ROOT/skills/$name/SKILL.md"
  [ -s "$f" ] || continue

  fm="$(frontmatter "$f")"
  if [ -z "$fm" ]; then
    echo "FAIL: skills/$name — no frontmatter block (first line must be '---')"; FAIL=1
    continue
  fi

  missing=""
  for key in name description when_to_use version; do
    [ -n "$(field "$f" "$key")" ] || missing="$missing $key"
  done
  if [ -z "$missing" ]; then
    echo "PASS: skills/$name frontmatter carries name, description, when_to_use, version"
  else
    echo "FAIL: skills/$name frontmatter incomplete — missing:$missing"; FAIL=1
  fi

  fm_name="$(field "$f" name)"
  if [ "$fm_name" = "$name" ]; then
    echo "PASS: skills/$name frontmatter name matches its directory"
  else
    echo "FAIL: skills/$name declares name '$fm_name' — must equal the directory name"; FAIL=1
  fi

  desc="$(field "$f" description)"
  bad=""
  for w in $ALWAYS_WORDS; do
    printf '%s\n' "$desc" | grep -qwiF -- "$w" && bad="$bad $w"
  done
  if printf '%s\n' "$desc" | grep -qiE -- "$ALWAYS_PHRASES"; then
    bad="$bad <unconditional-phrase>"
  fi
  if [ -z "$bad" ]; then
    echo "PASS: skills/$name description states a conditional trigger"
  else
    echo "FAIL: skills/$name description reads as unconditional —$bad"
    echo "      An always-on rule belongs in principles/coding.md, not behind a description."
    FAIL=1
  fi
done

# ---- Case 5: the reference extractor, self-tested ----
# Skill names are identifiers and this repo backticks identifiers, so a cross
# reference is written `name`-skill / `name` skill / skill `name`. Matching the
# backticked form only is deliberate: an unquoted `-skill` suffix collides with
# ordinary Finnish compounds and would turn this gate into noise.
skill_refs() {
  {
    grep -ohE '`[a-z0-9][a-z0-9-]*`[ -]?[Ss]kill' "$@" \
      | sed -E 's/^`([a-z0-9][a-z0-9-]*)`.*/\1/'
    grep -ohE '[Ss]kill[a-zäö]*[ -]`[a-z0-9][a-z0-9-]*`' "$@" \
      | sed -E 's/.*`([a-z0-9][a-z0-9-]*)`$/\1/'
  } 2>/dev/null | sort -u
}

PROBE="$(mktemp)"
trap 'rm -f "$PROBE"' EXIT
cat > "$PROBE" <<'PROBEEOF'
verify the page with the `webapp-testing` skill before continuing
katso `some-other`-skillistä tarkemmat ohjeet
ks. skilliä `third-one` samasta paketista
PROBEEOF
probe_out="$(skill_refs "$PROBE")"
probe_want="$(printf 'some-other\nthird-one\nwebapp-testing\n')"
if [ "$probe_out" = "$probe_want" ]; then
  echo "PASS: skill reference extractor works (self-test)"
else
  echo "FAIL: skill reference extractor broke — Case 6 would pass vacuously"
  echo "      want: $(printf '%s' "$probe_want" | tr '\n' ' ')"
  echo "      got:  $(printf '%s' "$probe_out" | tr '\n' ' ')"
  FAIL=1
fi

# ---- Case 6: no dangling skill references ----
# Zero references is the expected steady state and passes: the rule is that a
# named skill must exist, not that skills must cross-reference each other.
found_ref=0
for name in $SKILLS; do
  f="$ROOT/skills/$name/SKILL.md"
  [ -s "$f" ] || continue
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    found_ref=1
    if [ -f "$ROOT/skills/$ref/SKILL.md" ]; then
      echo "PASS: skills/$name references skill '$ref', which this package ships"
    else
      echo "FAIL: skills/$name references skill '$ref', which this package does NOT ship"; FAIL=1
    fi
  done <<< "$(skill_refs "$f")"
done
[ "$found_ref" -eq 0 ] && echo "PASS: no skill names another skill (nothing can dangle)"

# ---- Case 7: the trigger-conditional skills are present ----
# These two carry rules that have a genuine firing condition and therefore have
# no other home: they are wrong in principles/coding.md (which is unconditional)
# and lost entirely if the directory is renamed without updating this line.
#   e2e-testing      writing or repairing a browser end-to-end test
#   container-build  the first container build in a project
for name in e2e-testing container-build; do
  if [ -s "$ROOT/skills/$name/SKILL.md" ]; then
    echo "PASS: trigger-conditional skill '$name' is shipped"
  else
    echo "FAIL: trigger-conditional skill '$name' is missing"; FAIL=1
  fi
done

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "skill-triggers: all passed" || echo "skill-triggers: FAILURES"
[ "$FAIL" -eq 0 ]
