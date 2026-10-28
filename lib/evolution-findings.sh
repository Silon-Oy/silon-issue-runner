#!/usr/bin/env bash
# lib/evolution-findings.sh — the ONE parser of an evolution step's output
# (<run-dir>/03-evolution.out), shared by orchestrate.sh (S9 → PR body) and
# evolution-digest.sh (the cross-run report, issue #315).
#
# The evolution prompt (prompts/03-evolution.md) ends its answer with machine
# lines:
#   EVOLUTION_RESULT: CLEAN | FIXED — <why> | NEEDS_FOLLOWUP — <why>
#   EVOLUTION_DELTA_PSI: <tooling|product> | <one sentence>   (zero or more)
#   EVOLUTION_TEST_RUN: <command> | passed=<n> | skipped=<n> | failed=<n>
#                                                            (zero or more, #410)
# A Δψ line carries a class (issue #392): `tooling` is friction in the test
# environment, provisioning or the runner itself; `product` is a structural
# defect in the target application's code. A line without a recognised class —
# including the pre-#392 format — reads as `unclassified`, never dropped.
# Two readers with their own grep would drift the first time the line format
# changes, and the digest would silently stop seeing what the PR body shows.
#
# Never fails: a missing file or line is "no result", not a dead caller under
# `set -e` (the same contract as orchestrate.sh's _implementer_result).
#
# Function-only: safe to source more than once.

# evolution_result_payload <evolution-out> — the LAST EVOLUTION_RESULT payload
# ("FIXED — why"), or empty.
evolution_result_payload() {
  grep -E '^EVOLUTION_RESULT:' "$1" 2>/dev/null | tail -1 | sed 's/^EVOLUTION_RESULT: *//' || true
}

# evolution_delta_psi_payloads <evolution-out> — every EVOLUTION_DELTA_PSI
# payload, one per line, or nothing.
evolution_delta_psi_payloads() {
  grep -E '^EVOLUTION_DELTA_PSI:' "$1" 2>/dev/null | sed 's/^EVOLUTION_DELTA_PSI: *//' || true
}

# evolution_delta_psi_classified <evolution-out> — every Δψ line as TSV
# "<class>\t<text>", class one of tooling, product, unclassified. The class
# prefix and its "|" are stripped from the text only when the class is known;
# otherwise the whole payload is kept as the text.
evolution_delta_psi_classified() {
  local line class text rest cand
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    line=$(printf '%s' "$line" | tr '\t' ' ')
    class=unclassified
    text="$line"
    case "$line" in
      tooling*) rest="${line#tooling}"; cand=tooling ;;
      product*) rest="${line#product}"; cand=product ;;
      *)        rest=""; cand="" ;;
    esac
    if [ -n "$cand" ]; then
      rest=$(printf '%s' "$rest" | sed 's/^[[:space:]]*//')
      case "$rest" in
        '|'*) class="$cand"; text=$(printf '%s' "${rest#|}" | sed 's/^[[:space:]]*//') ;;
      esac
    fi
    printf '%s\t%s\n' "$class" "$text"
  done <<EOF
$(evolution_delta_psi_payloads "$1")
EOF
  return 0
}

# evolution_findings <evolution-out> — the run's findings as TSV lines
# "<kind>\t<class>\t<text>", kind one of FIXED, NEEDS_FOLLOWUP, DELTA_PSI; class
# is the Δψ class (see evolution_delta_psi_classified) and "-" for the other
# kinds — never empty, because `IFS=$'\t' read` collapses an empty field. CLEAN and an
# unknown or missing result produce no FIXED/NEEDS_FOLLOWUP line; Δψ lines are
# emitted regardless of the result class, because a CLEAN run may still have
# seen a structural problem outside its scope. The result text is stripped of
# its class keyword and the separator the prompt asks for ("—", or "--").
evolution_findings() {
  local out="$1" payload class text line
  payload=$(evolution_result_payload "$out")
  class="${payload%%[!A-Z_]*}"
  case "$class" in
    FIXED|NEEDS_FOLLOWUP)
      text="${payload#"$class"}"
      text=$(printf '%s' "$text" | sed -e 's/^[[:space:]]*//' -e 's/^—[[:space:]]*//' -e 's/^--*[[:space:]]*//' | tr '\t' ' ')
      printf '%s\t-\t%s\n' "$class" "$text"
      ;;
  esac
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf 'DELTA_PSI\t%s\n' "$line"
  done <<EOF
$(evolution_delta_psi_classified "$out")
EOF
  return 0
}

# evolution_test_runs_json <evolution-out> — every EVOLUTION_TEST_RUN line as a
# compact JSON array [{"command","passed","skipped","failed"}], or [] when there
# is none (an older evolution output). The counts are the three RIGHTMOST
# "|"-fields, so a command with a pipe in it stays whole. A count that is not a
# number ("?", missing) is null — the line is kept, never dropped, because a
# run the agent could not count is still a run it made.
evolution_test_runs_json() {
  local lines
  lines=$(grep -E '^EVOLUTION_TEST_RUN:' "$1" 2>/dev/null || true)
  printf '%s' "$lines" | jq -Rsc '
    def num: if test("^[0-9]+$") then tonumber else null end;
    [ split("\n")[]
      | sub("\r$"; "")
      | select(length > 0)
      | sub("^EVOLUTION_TEST_RUN:\\s*"; "")
      | split("|") as $p
      | ($p | length) as $n
      | (if $n >= 4 then $p[$n-3:] else [] end) as $kv
      | (reduce $kv[] as $f ({};
           ($f | capture("^\\s*(?<k>[a-z]+)\\s*=\\s*(?<v>.*?)\\s*$")?) as $m
           | if $m then .[$m.k] = ($m.v | num) else . end)) as $c
      | { command: ((if $n >= 4 then $p[:$n-3] else $p end) | join("|") | sub("^\\s+"; "") | sub("\\s+$"; "")),
          passed: $c.passed, skipped: $c.skipped, failed: $c.failed }
    ]' 2>/dev/null || echo '[]'
  return 0
}
