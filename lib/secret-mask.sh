#!/usr/bin/env bash
# lib/secret-mask.sh — the one masked form of a found secret (issue #398).
#
# A secret a scanner found must never travel whole into text the runner writes
# (issue bodies, comments, PR descriptions) or into an agent's prompt: for a real
# secret the runner would publish it itself. A fully hidden value is no good
# either — a human cannot tell a false positive (a JWT starting `eyJh`, a test
# token) from a real key without seeing anything. The masked form is the
# compromise, and every caller uses this one function so the form cannot drift.
#
#   secret_mask <value>
#     >= 8 chars: first 4 + "…" + last 2 + " (N merkkiä)"   e.g. "AKIA…23 (25 merkkiä)"
#     <  8 chars: " (N merkkiä)" only, without the leading space: "(7 merkkiä)"
#     empty:      prints nothing (no value is no mask)
#   The output is safe inside a `severity|confidence|location|description` row:
#   `|`, CR, LF and tab become spaces (a private key spans lines).
#
# Why 8: four plus two characters of a short value would show most of it — of a
# 7-character password, six. Below the threshold only the length is shown.
#
# Sourced; defines functions only and does no top-level work.

secret_mask() {
  local v="${1:-}" n out
  n=${#v}
  [ "$n" -gt 0 ] || return 0
  if [ "$n" -lt 8 ]; then
    out="($n merkkiä)"
  else
    out="${v:0:4}…${v: -2} ($n merkkiä)"
  fi
  out=${out//|/ }
  out=${out//$'\r'/ }
  out=${out//$'\n'/ }
  out=${out//$'\t'/ }
  printf '%s' "$out"
}
