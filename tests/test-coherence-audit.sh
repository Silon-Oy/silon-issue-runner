#!/usr/bin/env bash
# test-coherence-audit.sh — coherence-audit.sh end to end (issue #342). The agent
# is stubbed through RUN_ISSUES_CLAUDE_CMD (CLAUDE.md §5.5), gh is a PATH shim
# that records every call and serves merged PRs and their files from fixtures,
# and a git shim routes `fetch` of the github.com remote to a local bare repo.
#
#   A) finding            -> one issue: the coherence label and NO pickup label,
#                            marker, issue format, the review set in the body;
#                            the cursor moves to the newest reviewed merge
#   B) recurring finding  -> no duplicate: "exists #N", no write
#   C) no new PRs         -> exit 0, no agent call, no worktree, cursor unchanged
#   D) review set         -> a non-`auto-run/` PR, an unmerged PR and a PR merged
#                            before the cursor are not reviewed; the change
#                            surface names the reviewed PRs only
#   E) launch failure     -> rc 127 and a missing CLI: exit 3, no write, cursor
#                            unchanged
#   F) unreadable PR set or change surface -> exit 4, no agent call
#   G) --dry-run          -> plan printed, no write, cursor unchanged
#   H) pagination stops at PRs updated before the cursor (cost, §5.4)
#   I) first run without a cursor: the window is the interval (repo setting wins)
#
# Run: bash tests/test-coherence-audit.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Hermetic: never source this machine's real env file (CLAUDE.md §5.5, #358).
export RUN_ISSUES_ENV_FILE="$HERE/.no-such-machine-env"
AUDIT="$HERE/../coherence-audit.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available"
  exit 0
fi

FAIL=0
bad() { echo "FAIL $1: $2"; FAIL=1; }
ok()  { echo "PASS $1: $2"; }

REAL_GIT=$(command -v git)
iso_ago() { jq -rn --argjson d "$1" 'now - $d * 86400 | floor | todate'; }
epoch_of() { jq -rn --arg t "$1" '$t | fromdateiso8601'; }

# setup <name> — origin (bare) + clone whose origin is a github.com URL, shims.
setup() {
  WORK=$(mktemp -d -t cohaudit-"$1".XXXXXX)
  export HOME="$WORK/home"; mkdir -p "$HOME"
  export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
  LOGS="$WORK/logs"; mkdir -p "$LOGS"
  ORIGIN="$WORK/origin.git"; REPO="$WORK/repo"; BIN="$WORK/bin"
  mkdir -p "$BIN" "$WORK/files" "$WORK/created"
  git init -q --bare "$ORIGIN"
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  git init -q "$REPO"
  (
    cd "$REPO"
    git symbolic-ref HEAD refs/heads/main
    git config user.email t@t.t; git config user.name t
    mkdir -p lib; echo 'a() { :; }' > lib/a.sh; echo 'b() { :; }' > lib/b.sh
    git add .; git commit -qm init
    git push -q "$ORIGIN" main
    git remote add origin https://github.com/Silon-Oy/app.git
  )
  cat > "$BIN/git" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = fetch ]; then
    exec "$REAL_GIT" -c "url.$ORIGIN.insteadOf=https://github.com/Silon-Oy/app.git" "\$@"
  fi
done
exec "$REAL_GIT" "\$@"
SH
  chmod +x "$BIN/git"
  PATH="$BIN:$PATH" git -C "$REPO" fetch -q origin
  git -C "$REPO" remote set-head origin main >/dev/null

  # pulls/page-<N>.json: the closed-PR listing, page by page.
  mkdir -p "$WORK/pulls"
  echo '[]' > "$WORK/pulls/page-1.json"
  echo '[]' > "$WORK/issues.json"
  : > "$WORK/gh.log"; : > "$WORK/calls.log"; echo 100 > "$WORK/next"
  cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/gh.log"
[ "\$1" = api ] || exit 0
case "\$*" in
  *"repos/Silon-Oy/app/pulls?state=closed"*)
    [ -f "$WORK/pulls-fail" ] && { echo "HTTP 502" >&2; exit 1; }
    p=\$(printf '%s' "\$*" | sed -nE 's/.*[?&]page=([0-9]+).*/\1/p')
    cat "$WORK/pulls/page-\${p:-1}.json" 2>/dev/null || echo '[]'
    exit 0 ;;
  *"repos/Silon-Oy/app/pulls/"*"/files"*)
    [ -f "$WORK/files-fail" ] && { echo "HTTP 502" >&2; exit 1; }
    n=\$(printf '%s' "\$*" | sed -nE 's#.*pulls/([0-9]+)/files.*#\1#p')
    cat "$WORK/files/\$n" 2>/dev/null
    exit 0 ;;
  *--paginate*)
    cat "$WORK/issues.json"; exit 0 ;;
  *"--method POST repos/Silon-Oy/app/issues -f"*)
    n=\$(cat "$WORK/next"); echo \$((n + 1)) > "$WORK/next"
    for a in "\$@"; do
      case "\$a" in
        body=*)  printf '%s' "\${a#body=}" > "$WORK/created/\$n.body" ;;
        title=*) printf '%s' "\${a#title=}" > "$WORK/created/\$n.title" ;;
        labels\[\]=*) printf '%s\n' "\${a#labels[]=}" >> "$WORK/created/\$n.labels" ;;
      esac
    done
    printf '{"number":%s}\n' "\$n"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$BIN/gh"

  cat > "$BIN/claude-mock" <<SH
#!/usr/bin/env bash
echo AUDIT >> "$WORK/calls.log"
printf '%s\n' "\$*" > "$WORK/prompt-seen"
cat "$WORK/review.txt"
[ -f "$WORK/review-rc" ] && exit "\$(cat "$WORK/review-rc")"
exit 0
SH
  chmod +x "$BIN/claude-mock"
  printf 'MERGE_GATE_RESULT: CLEAN\n' > "$WORK/review.txt"
}

# pr <number> <merged_at|null> <head-ref> [updated_at] — one listing entry.
pr() {
  jq -nc --argjson n "$1" --arg m "$2" --arg h "$3" --arg u "${4:-$2}" \
    '{number:$n, title:("PR " + ($n|tostring)), merged_at:(if $m == "null" then null else $m end),
      updated_at:(if $u == "null" then "2020-01-01T00:00:00Z" else $u end), head:{ref:$h}}'
}
# page <N> <entry...>
page() { local n="$1"; shift; printf '%s\n' "$@" | jq -s . > "$WORK/pulls/page-$n.json"; }

cursor_file() { echo "$LOGS/.audit-coherence-cursor-silon-oy-app"; }
set_cursor() { printf '%s coherence\n' "$(epoch_of "$1")" > "$(cursor_file)"; }
cursor() { awk '{print $1}' "$(cursor_file)" 2>/dev/null; }

run_audit() {
  set +e
  OUT=$( env PATH="$BIN:$PATH" HOME="$HOME" \
    RUN_ISSUES_CLAUDE_CMD="$BIN/claude-mock" \
    RUN_ISSUES_COHERENCE_AUDIT_TIMEOUT=60 \
    RUN_ISSUES_LOG_DIR="$LOGS" \
    ${AUDIT_ENV:-} "$AUDIT" "$REPO" "$@" 2>&1 )
  RC=$?
}

writes() { grep -c -- '--method' "$WORK/gh.log" 2>/dev/null || true; }
creates() { find "$WORK/created" -name '*.body' | wc -l | tr -d ' '; }
agent_calls() { grep -c AUDIT "$WORK/calls.log" 2>/dev/null || true; }
show() { echo "$OUT" | sed "s/^/$1| /"; echo "$1| (rc=$RC)"; }
done_case() { [ -n "${KEEP:-}" ] || rm -rf "$WORK"; }

fp_of() { ( . "$HERE/../lib/finding-issues.sh"; finding_fingerprint "$@" ); }

T_OLD=$(iso_ago 3)
T1=$(iso_ago 2)
T2=$(iso_ago 1)
F_DUP='FINDING: medium | high | lib/b.sh:1 | [duplicate-implementation] b() repeats a() from lib/a.sh (PR #11, #12)'
FP_DUP=$(fp_of agent lib/b.sh duplicate-implementation)

# ===========================================================================
echo "=== A: finding -> issue without pickup labels ==="
setup A
set_cursor "$T_OLD"
page 1 "$(pr 12 "$T2" auto-run/x-issue-2-b)" "$(pr 11 "$T1" auto-run/x-issue-1-a)"
printf 'lib/a.sh\n' > "$WORK/files/11"; printf 'lib/b.sh\nlib/a.sh\n' > "$WORK/files/12"
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_DUP" > "$WORK/review.txt"
run_audit; show A
[ "$RC" = 0 ] || bad A "rc $RC, want 0"
[ "$(creates)" = 1 ] || bad A "created $(creates) issues, want 1"
B="$WORK/created/100.body"
grep -qF "<!-- run-issues:finding kind=coherence fp=$FP_DUP -->" "$B" 2>/dev/null || bad A "marker with the fingerprint missing"
for h in '## Tavoite' '## Hyväksyntäkriteerit' '## Rajaukset'; do
  grep -qx "$h" "$B" 2>/dev/null || bad A "body lacks '$h'"
done
grep -q '#11' "$B" 2>/dev/null && grep -q '#12' "$B" 2>/dev/null || bad A "body does not name the review set"
[ "$(cat "$WORK/created/100.labels" 2>/dev/null)" = coherence ] \
  || bad A "labels are '$(tr '\n' ',' < "$WORK/created/100.labels" 2>/dev/null)', want only coherence"
grep -q 'labels -f name=coherence' "$WORK/gh.log" || bad A "coherence label not ensured"
grep -q -- '- `lib/a.sh` (#11, #12)' "$WORK/prompt-seen" || bad A "change surface missing from the prompt"
grep -q 'duplicate-implementation' "$WORK/prompt-seen" || bad A "prompt does not name the failure model"
[ "$(cursor)" = "$(epoch_of "$T2")" ] || bad A "cursor $(cursor), want the newest merge $(epoch_of "$T2")"
[ -z "$(git -C "$REPO" worktree list | sed 1d)" ] || bad A "temporary worktree left behind"
[ "$FAIL" = 0 ] && ok A "finding filed as one coherence issue, cursor moved"
done_case

# ===========================================================================
echo "=== B: recurring finding -> no duplicate ==="
F0=$FAIL; setup B
set_cursor "$T_OLD"
page 1 "$(pr 13 "$T2" auto-run/x-issue-3-c)"
printf 'lib/b.sh\n' > "$WORK/files/13"
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_DUP" > "$WORK/review.txt"
jq -n --arg fp "$FP_DUP" '[{number:7, state:"open", title:"old",
  body:("x\n<!-- run-issues:finding kind=coherence fp=" + $fp + " -->")}]' > "$WORK/issues.json"
run_audit; show B
[ "$RC" = 0 ] || bad B "rc $RC, want 0"
[ "$(writes)" = 0 ] || bad B "$(writes) write call(s), want 0"
grep -q "^exists #7" <<<"$OUT" || bad B "output does not name the existing issue"
[ "$FAIL" = "$F0" ] && ok B "recurring finding not duplicated"
done_case

# ===========================================================================
echo "=== C: no new PRs -> no agent call ==="
F0=$FAIL; setup C
set_cursor "$T1"
page 1 "$(pr 11 "$T1" auto-run/x-issue-1-a)"
run_audit; show C
[ "$RC" = 0 ] || bad C "rc $RC, want 0"
[ "$(agent_calls)" = 0 ] || bad C "agent called $(agent_calls) time(s), want 0"
[ "$(writes)" = 0 ] || bad C "$(writes) write call(s), want 0"
grep -q '/files' "$WORK/gh.log" && bad C "change surface read without a review set"
grep -q 'issues?labels' "$WORK/gh.log" && bad C "issue index read without a review set"
[ -z "$(ls -A "$TMPDIR")" ] || bad C "a work area was created"
[ "$(cursor)" = "$(epoch_of "$T1")" ] || bad C "cursor moved"
grep -q 'no new PRs' <<<"$OUT" || bad C "output does not say there was nothing to audit"
[ "$FAIL" = "$F0" ] && ok C "no PRs, no agent"
done_case

# ===========================================================================
echo "=== D: review set ==="
F0=$FAIL; setup D
set_cursor "$T1"
page 1 "$(pr 21 "$T2" auto-run/x-issue-5-a)" "$(pr 22 "$T2" feature/by-hand)" \
  "$(pr 23 null auto-run/x-issue-6-b "$T2")" "$(pr 24 "$T1" auto-run/x-issue-7-c "$T2")"
for n in 21 22 23 24; do printf 'f%s.sh\n' "$n" > "$WORK/files/$n"; done
run_audit; show D
[ "$RC" = 0 ] || bad D "rc $RC, want 0"
grep -q '#21' "$WORK/prompt-seen" || bad D "runner PR #21 not reviewed"
for n in 22 23 24; do
  grep -q "#$n" "$WORK/prompt-seen" && bad D "PR #$n reviewed"
  grep -q "pulls/$n/files" "$WORK/gh.log" && bad D "files of PR #$n read"
done
grep -q '1 PR(s)' <<<"$OUT" || bad D "summary does not count one PR"
[ "$FAIL" = "$F0" ] && ok D "only runner PRs merged after the cursor"
done_case

# ===========================================================================
echo "=== E: launch failure ==="
F0=$FAIL; setup E1
set_cursor "$T_OLD"
page 1 "$(pr 11 "$T1" auto-run/x-issue-1-a)"; printf 'lib/a.sh\n' > "$WORK/files/11"
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_DUP" > "$WORK/review.txt"
echo 127 > "$WORK/review-rc"
run_audit; show E1
[ "$RC" = 3 ] || bad E1 "rc $RC, want 3"
[ "$(writes)" = 0 ] || bad E1 "$(writes) write call(s), want 0"
[ "$(cursor)" = "$(epoch_of "$T_OLD")" ] || bad E1 "cursor moved after a failed audit"
done_case
setup E2
set_cursor "$T_OLD"
page 1 "$(pr 11 "$T1" auto-run/x-issue-1-a)"; printf 'lib/a.sh\n' > "$WORK/files/11"
AUDIT_ENV="RUN_ISSUES_CLAUDE_CMD=$WORK/no-claude" run_audit; AUDIT_ENV=""; show E2
[ "$RC" = 3 ] || bad E2 "rc $RC, want 3"
[ "$(writes)" = 0 ] || bad E2 "$(writes) write call(s), want 0"
[ "$(cursor)" = "$(epoch_of "$T_OLD")" ] || bad E2 "cursor moved after a failed audit"
done_case
setup E3   # unparseable answer
set_cursor "$T_OLD"
page 1 "$(pr 11 "$T1" auto-run/x-issue-1-a)"; printf 'lib/a.sh\n' > "$WORK/files/11"
printf 'All looks coherent to me.\n' > "$WORK/review.txt"
run_audit; show E3
[ "$RC" = 3 ] || bad E3 "rc $RC, want 3"
[ "$(cursor)" = "$(epoch_of "$T_OLD")" ] || bad E3 "cursor moved after an unparseable result"
done_case
[ "$FAIL" = "$F0" ] && ok E "launch failure is not 'no findings'"

# ===========================================================================
echo "=== F: unreadable PR set / change surface ==="
F0=$FAIL; setup F1
set_cursor "$T_OLD"; touch "$WORK/pulls-fail"
run_audit; show F1
[ "$RC" = 4 ] || bad F1 "rc $RC, want 4"
[ "$(agent_calls)" = 0 ] || bad F1 "agent called"
done_case
setup F2
set_cursor "$T_OLD"
page 1 "$(pr 11 "$T1" auto-run/x-issue-1-a)"; touch "$WORK/files-fail"
run_audit; show F2
[ "$RC" = 4 ] || bad F2 "rc $RC, want 4"
[ "$(agent_calls)" = 0 ] || bad F2 "agent called on a partial surface"
[ "$(cursor)" = "$(epoch_of "$T_OLD")" ] || bad F2 "cursor moved"
done_case
[ "$FAIL" = "$F0" ] && ok F "unreadable material is fail-closed"

# ===========================================================================
echo "=== G: --dry-run ==="
F0=$FAIL; setup G
set_cursor "$T_OLD"
page 1 "$(pr 11 "$T1" auto-run/x-issue-1-a)"; printf 'lib/b.sh\n' > "$WORK/files/11"
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_DUP" > "$WORK/review.txt"
run_audit --dry-run; show G
[ "$RC" = 0 ] || bad G "rc $RC, want 0"
[ "$(writes)" = 0 ] || bad G "$(writes) write call(s), want 0"
grep -q '^create \[coherence\]' <<<"$OUT" || bad G "planned action not printed (or carries pickup labels)"
[ "$(cursor)" = "$(epoch_of "$T_OLD")" ] || bad G "cursor moved on a dry run"
[ "$FAIL" = "$F0" ] && ok G "dry run writes nothing"
done_case

# ===========================================================================
echo "=== H: pagination stops at the cursor ==="
F0=$FAIL; setup H
set_cursor "$T1"
P1=(); for i in $(seq 1 99); do P1+=("$(pr $((1000 + i)) null feature/x "$T2")"); done
page 1 "$(pr 31 "$T2" auto-run/x-issue-8-a)" "${P1[@]}"
P2=(); for i in $(seq 1 100); do P2+=("$(pr $((2000 + i)) null feature/y "$T_OLD")"); done
page 2 "${P2[@]}"
page 3 "$(pr 41 "$T2" auto-run/never-read)"
printf 'lib/a.sh\n' > "$WORK/files/31"
run_audit; show H
[ "$RC" = 0 ] || bad H "rc $RC, want 0"
grep -q 'page=2' "$WORK/gh.log" || bad H "a full first page did not read the next"
grep -q 'page=3' "$WORK/gh.log" && bad H "listing went past PRs updated before the cursor"
grep -q '#31' "$WORK/prompt-seen" || bad H "PR on the first page not reviewed"
[ "$FAIL" = "$F0" ] && ok H "listing cost bounded by the cursor"
done_case

# ===========================================================================
echo "=== I: first run window ==="
F0=$FAIL; setup I
mkdir -p "$REPO/.claude"; echo '{"coherence":{"audit_interval_days":2}}' > "$REPO/.claude/run-issues.json"
git -C "$REPO" add .claude; git -C "$REPO" commit -qm cfg; git -C "$REPO" push -q "$ORIGIN" main
# 1.5 days ago is inside the repo's 2-day window; 3 days ago is outside it
# (the machine's 30 days would include it).
page 1 "$(pr 51 "$(iso_ago 1.5)" auto-run/x-issue-9-a)" "$(pr 52 "$T_OLD" auto-run/x-issue-10-b)"
printf 'lib/a.sh\n' > "$WORK/files/51"; printf 'lib/a.sh\n' > "$WORK/files/52"
AUDIT_ENV="RUN_ISSUES_COHERENCE_AUDIT_INTERVAL_DAYS=30" run_audit; AUDIT_ENV=""; show I
[ "$RC" = 0 ] || bad I "rc $RC, want 0"
grep -q '#51' "$WORK/prompt-seen" || bad I "PR inside the window not reviewed"
grep -q '#52' "$WORK/prompt-seen" && bad I "PR outside the repo's window reviewed"
[ -s "$(cursor_file)" ] || bad I "cursor not written after the first successful audit"
[ "$FAIL" = "$F0" ] && ok I "first window is the interval, repo wins"
done_case

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "coherence-audit: all passed" || echo "coherence-audit: FAILURES"
[ "$FAIL" -eq 0 ]
