#!/usr/bin/env bash
# test-answer-detection.sh — Phase 0 probe, promoted to a permanent regression
# test for α2 answer detection.
#
# INVARIANT PROTECTED: parse_marker / detect_answer compare GitHub's
# `createdAt` against an awaiting-answer marker timestamp purely by
# lexicographic string comparison in jq. This is only correct because gh
# returns createdAt in the SAME `%FT%TZ` (Zulu, no offset, no milliseconds)
# format that _state_now writes into the marker. If gh ever changes its
# timestamp format (offset like +03:00, or fractional seconds) this test
# fails loudly, signalling that detect_answer needs an epoch-normalisation
# fallback. Probed empirically against Silon-Oy/dotfiles issue #4 with
# gh — createdAt = "2026-05-20T11:45:39Z".
#
# A human reply is detected by TIMESTAMP, not by author: the bot and the human
# share the same GitHub account, so the only durable discriminator is "a
# comment created after the marker that does NOT itself contain run-issues:".
#
# No network: a synthetic issue-JSON fixture drives both functions.
#
# Run: bash tests/test-answer-detection.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISSUE_LIB="$HERE/../lib/issue.sh"

WORK=$(mktemp -d -t answer-detect.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=lib/issue.sh
. "$ISSUE_LIB"

MARKER_TS="2026-05-21T10:00:00Z"
RUN_ID="20260521-095900-issue-7"

# Build the awaiting-answer marker the orchestrator would have posted, then a
# fixture issue JSON whose comments interleave bot markers and human replies.
MARKER=$(build_marker "$RUN_ID" 7 "$MARKER_TS" 1)

FIX="$WORK/issue.json"
jq -n \
  --arg marker "$MARKER" \
  --arg replyC "Tarkennus C: käytä Postgresia, ei MySQL:ää." \
  --arg replyD "Tarkennus D (uudempi): itse asiassa SQLite riittää." \
  '{
    title: "t",
    body: "b",
    comments: [
      # The awaiting-answer situation comment posted by the bot at the marker ts.
      { author: {login: "maintainer"}, createdAt: "2026-05-21T10:00:00Z",
        body: ($marker + "\n## /run-issues — tarkennus tarvitaan") },
      # A (bot): contains run-issues: AND is after the marker -> NOT an answer.
      { author: {login: "maintainer"}, createdAt: "2026-05-21T10:00:01Z",
        body: "<!-- run-issues:noise --> bottikommentti" },
      # B (human): plain reply but BEFORE the marker -> NOT an answer.
      { author: {login: "maintainer"}, createdAt: "2026-05-21T09:59:00Z",
        body: "vanha kommentti ennen markeria" },
      # C (human): plain reply after the marker -> IS an answer (until D wins).
      { author: {login: "maintainer"}, createdAt: "2026-05-21T10:05:00Z",
        body: $replyC },
      # D (human): newest plain reply after the marker -> WINS.
      { author: {login: "maintainer"}, createdAt: "2026-05-21T10:10:00Z",
        body: $replyD }
    ]
  }' > "$FIX"

FAIL=0

# === parse_marker: finds the newest awaiting-answer marker ==================
PM=$(parse_marker "$FIX")
echo "--- parse_marker output ---"; echo "$PM"
echo "$PM" | grep -q "ts=$MARKER_TS" || { echo "FAIL: parse_marker did not return marker ts"; FAIL=1; }
echo "$PM" | grep -q "round=1" || { echo "FAIL: parse_marker did not return round=1"; FAIL=1; }
echo "$PM" | grep -q "run=$RUN_ID" || { echo "FAIL: parse_marker did not return run id"; FAIL=1; }

# === detect_answer: newest plain comment after the marker ts ================
ANS=$(detect_answer "$FIX" "$MARKER_TS")
echo "--- detect_answer output ---"; echo "$ANS"
echo "$ANS" | grep -q "SQLite riittää" || { echo "FAIL: detect_answer did not pick newest reply D"; FAIL=1; }
echo "$ANS" | grep -q "Postgresia" && { echo "FAIL: detect_answer returned older reply C instead of D"; FAIL=1; }
echo "$ANS" | grep -q "run-issues:" && { echo "FAIL: detect_answer returned a bot marker comment"; FAIL=1; }
echo "$ANS" | grep -q "ennen markeria" && { echo "FAIL: detect_answer returned a pre-marker comment"; FAIL=1; }

# === detect_answer: no reply yet (race) -> empty ============================
# A fixture whose only post-marker comment is the bot's own marker comment.
FIX2="$WORK/issue-noanswer.json"
jq -n --arg marker "$MARKER" '{
    title: "t", body: "b",
    comments: [
      { author: {login: "maintainer"}, createdAt: "2026-05-21T10:00:00Z",
        body: ($marker + "\n## tarkennus") }
    ]
  }' > "$FIX2"
ANS2=$(detect_answer "$FIX2" "$MARKER_TS")
echo "--- detect_answer (no reply) output ---"; echo "[$ANS2]"
[ -z "$ANS2" ] || { echo "FAIL: detect_answer returned non-empty when no human reply present"; FAIL=1; }

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "answer-detection: all passed" || echo "answer-detection: FAILURES"
[ "$FAIL" -eq 0 ]
