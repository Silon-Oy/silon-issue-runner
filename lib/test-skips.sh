#!/usr/bin/env bash
# lib/test-skips.sh — test skip and focus markers ADDED by a branch's diff.
#
# A green suite is the evidence S9 (evolution's Ω run) and CI rely on, but a
# suite is also green when its tests were skipped. This module reads the local
# diff and reports every added skip (`it.skip`, `xit`, `markTestSkipped`, …)
# and every added focus marker (`.only`, `fit`, `fdescribe`), which silently
# drops every other test in the file. orchestrate.sh turns an unjustified skip
# or any focus marker into a draft PR (issue #410).
#
# The scan is mechanical on purpose: the agent whose work is being guarded is
# never asked which skips it added.
#
# Recognised frameworks, each only in its own file type and only in test paths
# (a draft PR blocks an auto-merge chain, so a false positive costs more than a
# miss — `array.skip(` in application code must not count):
#   Playwright, Vitest, Jest (js/jsx/ts/tsx/mjs/cjs/mts/cts):
#     <it|test|describe|suite|context>.<skip|fixme>  → skip
#     <it|test|describe|suite|context>.only          → only
#     xit( xdescribe( xtest(                         → skip
#     fit( fdescribe( ftest(                         → only
#   PHPUnit (php): markTestSkipped(, @group skip     → skip
#   pytest (py):   @pytest.mark.skip, @pytest.mark.skipif → skip
#   bats (bats):   a line starting with `skip`       → skip
#
# A marker is "justified" when the same line carries a comment after it, when
# the preceding line of the new file is a comment with text, or when the
# marker carries its own reason: markTestSkipped('why'), skip "why" (bats),
# @pytest.mark.skip(reason="why") / skip("why"). A JS argument is never a
# reason — `test.skip('title', fn)` takes the test's title there.
#
# Never fails: a git error is one stderr line and no output, not a dead caller
# under `set -e` (the same contract as lib/evolution-findings.sh).
#
# Function-only: safe to source more than once.

# _test_skips_added_lines <base> <head> — the diff's added lines, one TSV line
# "<file>\t<line>\t<prev>\t<text>" each, where <line> is the line number in the
# new file and <prev> is the preceding line of the new file when the diff shows
# it (an added or a context line), empty otherwise. Tabs inside text become
# spaces. The generic hunk iterator: a sibling diff guard reuses it unchanged.
_test_skips_added_lines() {
  local base="$1" head="$2" diff rc=0
  diff=$(git -c core.quotePath=false diff --no-color --no-ext-diff --unified=1 \
    "${base}...${head}" -- 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "test_skips_added: git diff ${base}...${head} failed (rc=$rc); no skips reported" >&2
    return 0
  fi
  printf '%s\n' "$diff" | awk '
    function clean(s) { sub(/\r$/, "", s); gsub(/\t/, " ", s); return s }
    /^diff --git / { header = 1; file = ""; next }
    header && /^\+\+\+ / {
      file = substr($0, 5)
      if (file == "/dev/null") file = ""
      else sub(/^b\//, "", file)
      next
    }
    /^@@ / {
      header = 0
      h = $0
      sub(/^@@ -[0-9,]+ \+/, "", h)
      sub(/[^0-9].*$/, "", h)
      ln = h + 0
      prev = ""
      next
    }
    header { next }
    file == "" { next }
    /^\+/ {
      t = clean(substr($0, 2))
      printf "%s\t%d\t%s\t%s\n", file, ln, prev, t
      prev = t; ln++; next
    }
    /^ / { prev = clean(substr($0, 2)); ln++; next }
  '
  return 0
}

# test_skips_added <base> <head> — every skip or focus marker the diff
# base...head adds, one TSV line "<file>\t<line>\t<kind>\t<justified>\t<text>",
# kind one of skip, only; justified 1 or 0; text is the trimmed added line.
# Runs in the current directory's repository. Always returns 0.
test_skips_added() {
  _test_skips_added_lines "$1" "$2" | awk -F '\t' '
    function has_text(s) { return s ~ /[A-Za-z0-9]/ }
    function test_path(p,   b) {
      b = p; sub(/^.*\//, "", b)
      if (b ~ /\.bats$/ || b ~ /\.(test|spec)\./ || b ~ /_test\./ || b ~ /^test_.*\.py$/ || b ~ /Test\.php$/) return 1
      return ("/" p) ~ /\/(test|tests|e2e|__tests__|spec)\//
    }
    function lang_of(p) {
      if (p ~ /\.(js|jsx|ts|tsx|mjs|cjs|mts|cts)$/) return "js"
      if (p ~ /\.php$/) return "php"
      if (p ~ /\.py$/) return "py"
      if (p ~ /\.bats$/) return "bats"
      return ""
    }
    # A line that is only a comment, with words in it.
    function comment_line(s,   t) {
      t = s
      sub(/^[[:space:]]+/, "", t)
      if (t ~ /^#\[/) return 0
      if (t !~ /^(\/\/|#|\/\*|\*|--)/) return 0
      sub(/^(\/\/+|#+|\/\*+|\*+|--+)/, "", t)
      return has_text(t)
    }
    # A comment line that explains: a commented-out marker explains nothing.
    function reason_line(s) {
      if (!comment_line(s)) return 0
      return s !~ /\.(skip|only|fixme)([^A-Za-z0-9_$]|$)|(^|[^A-Za-z0-9_$.])(xit|xdescribe|xtest|fit|fdescribe|ftest)[[:space:]]*\(|markTestSkipped|@group[[:space:]]+skip|pytest\.mark\.skip/
    }
    # A comment with words after position <from> of the line.
    function trailing_comment(s, from,   rest) {
      rest = substr(s, from)
      if (match(rest, /(^|[[:space:]])(\/\/|#|\/\*)/) == 0) return 0
      return has_text(substr(rest, RSTART + RLENGTH))
    }
    function emit(kind, end,   just, t) {
      just = (reason || trailing_comment(text, end) || reason_line(prev)) ? 1 : 0
      t = text
      sub(/^[[:space:]]+/, "", t); sub(/[[:space:]]+$/, "", t)
      printf "%s\t%s\t%s\t%d\t%s\n", file, line, kind, just, t
    }
    {
      file = $1; line = $2; prev = $3; text = $4; reason = 0
      if (!test_path(file)) next
      lang = lang_of(file)
      if (lang == "") next
      # A marker that is commented out does not run, so it skips nothing
      # (a PHPUnit docblock tag is the one marker that lives in a comment).
      if (comment_line(text) && !(lang == "php" && text ~ /@group/)) next
      if (lang == "js") {
        if (match(text, /(^|[^A-Za-z0-9_$])(it|test|describe|suite|context)\.only([^A-Za-z0-9_$]|$)/) ||
            match(text, /(^|[^A-Za-z0-9_$.])(fit|fdescribe|ftest)[[:space:]]*\(/)) {
          emit("only", RSTART + RLENGTH); next
        }
        if (match(text, /(^|[^A-Za-z0-9_$])(it|test|describe|suite|context)\.(skip|fixme)([^A-Za-z0-9_$]|$)/) ||
            match(text, /(^|[^A-Za-z0-9_$.])(xit|xdescribe|xtest)[[:space:]]*\(/)) {
          emit("skip", RSTART + RLENGTH); next
        }
      } else if (lang == "php") {
        if (match(text, /markTestSkipped[[:space:]]*\(/)) {
          end = RSTART + RLENGTH
          if (substr(text, end) ~ /^[[:space:]]*["\047][^"\047]*[A-Za-z0-9]/) reason = 1
          emit("skip", end); next
        }
        if (match(text, /@group[[:space:]]+skip([^A-Za-z0-9_-]|$)/)) {
          end = RSTART + RLENGTH
          # In a docblock the words after the tag are its reason.
          rest = text; sub(/^.*@group[[:space:]]+skip/, "", rest)
          if (has_text(rest)) reason = 1
          emit("skip", end); next
        }
      } else if (lang == "py") {
        if (match(text, /@pytest\.mark\.skip(if)?([^A-Za-z0-9_]|$)/)) {
          end = RSTART + RLENGTH
          rest = text; sub(/^.*@pytest\.mark\.skip(if)?/, "", rest)
          if (rest ~ /reason[[:space:]]*=[[:space:]]*[rRbBuUfF]*["\047][^"\047]*[A-Za-z0-9]/ ||
              rest ~ /^\([[:space:]]*[rRbBuUfF]*["\047][^"\047]*[A-Za-z0-9]/) reason = 1
          emit("skip", end); next
        }
      } else if (lang == "bats") {
        if (match(text, /^[[:space:]]*skip([[:space:]]|$)/)) {
          end = RSTART + RLENGTH
          rest = text; sub(/^[[:space:]]*skip/, "", rest)
          if (rest ~ /^[[:space:]]+["\047]?[A-Za-z0-9]/) reason = 1
          emit("skip", end); next
        }
      }
    }
  '
  return 0
}
