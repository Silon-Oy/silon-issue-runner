#!/usr/bin/env bash
# lib/evolution-findings.sh — the ONE parser of an evolution step's output
# (<run-dir>/03-evolution.out), shared by orchestrate.sh (S9 → PR body) and
# evolution-digest.sh (the cross-run report, issue #315).
#
# The evolution prompt (prompts/03-evolution.md) ends its answer with machine
# lines:
#   EVOLUTION_RESULT: CLEAN | FIXED — <why> | NEEDS_FOLLOWUP — <why>
#   EVOLUTION_DELTA_PSI: <one sentence>        (zero or more)
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

# evolution_findings <evolution-out> — the run's findings as TSV lines
# "<kind>\t<text>", kind one of FIXED, NEEDS_FOLLOWUP, DELTA_PSI. CLEAN and an
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
      printf '%s\t%s\n' "$class" "$text"
      ;;
  esac
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf 'DELTA_PSI\t%s\n' "$(printf '%s' "$line" | tr '\t' ' ')"
  done <<EOF
$(evolution_delta_psi_payloads "$out")
EOF
  return 0
}
