#!/usr/bin/env bash
# test-quality-audit.sh — quality-audit.sh end to end (issue #395). The agent
# is stubbed through RUN_ISSUES_CLAUDE_CMD (CLAUDE.md §5.5), gh is a PATH shim
# that records every call, and a git shim routes `fetch` of the github.com
# remote to a local bare repo — no network.
#
#   A) findings           -> one issue each with the `quality` label only (the
#                            default threshold is none), marker, class named in
#                            the body, issue format; the prompt carries all
#                            seven classes
#   B) threshold          -> machine `high` (env and poller.env) gives a high
#                            finding the pickup labels, not a medium one; the
#                            repo's `none` beats the machine's `high`; the
#                            repo's `low` applies with no machine value
#   C) not a result       -> unparseable, empty and launch-failure output: exit 3,
#                            no issue write
#   D) worktree changed   -> exit 3, no write
#   E) --dry-run          -> plan printed, no write
#   F) verification       -> RUN_ISSUES_AUDIT_VERIFY=1 drops a refuted finding
#   G) one class, two files -> two issues; one class, one file twice -> one
#
# Run: bash tests/test-quality-audit.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=case-workdir.sh
. "$HERE/case-workdir.sh"
# Hermetic: never source this machine's real env file (CLAUDE.md §5.5, #358).
export RUN_ISSUES_ENV_FILE="$HERE/.no-such-machine-env"
AUDIT="$HERE/../quality-audit.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available"
  exit 0
fi

FAIL=0
bad() { echo "FAIL $1: $2"; FAIL=1; }
ok()  { echo "PASS $1: $2"; }

REAL_GIT=$(command -v git)

# setup <name> — origin (bare) + clone whose origin is a github.com URL, shims.
setup() {
  case_workdir qualaudit-"$1"
  export HOME="$WORK/home"; mkdir -p "$HOME"
  export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
  ORIGIN="$WORK/origin.git"; REPO="$WORK/repo"; BIN="$WORK/bin"
  mkdir -p "$BIN"
  git init -q --bare "$ORIGIN"
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  git init -q "$REPO"
  (
    cd "$REPO"
    git symbolic-ref HEAD refs/heads/main
    git config user.email t@t.t; git config user.name t
    mkdir -p src; echo 'a' > src/a.php; echo 'b' > src/b.php
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

  echo '[]' > "$WORK/issues.json"
  : > "$WORK/gh.log"; : > "$WORK/calls.log"; echo 100 > "$WORK/next"
  mkdir -p "$WORK/created"
  cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/gh.log"
[ "\$1" = api ] || exit 0
case "\$*" in
  *--paginate*) cat "$WORK/issues.json"; exit 0 ;;
  *"--method POST repos/Silon-Oy/app/issues -f"*)
    n=\$(cat "$WORK/next"); echo \$((n + 1)) > "$WORK/next"
    for a in "\$@"; do
      case "\$a" in
        body=*)  printf '%s' "\${a#body=}" > "$WORK/created/\$n.body" ;;
        title=*) printf '%s' "\${a#title=}" > "$WORK/created/\$n.title" ;;
        labels\[\]=*) printf '%s\n' "\${a#labels[]=}" >> "$WORK/created/\$n.labels" ;;
        assignees\[\]=*) printf '%s\n' "\${a#assignees[]=}" >> "$WORK/created/\$n.assignees" ;;
      esac
    done
    printf '{"number":%s,"assignees":[]}\n' "\$n"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$BIN/gh"

  # A verifier call answers from verify/<slug>.txt for the finding whose
  # description holds [<slug>], CONFIRMED when there is none.
  mkdir -p "$WORK/verify"
  cat > "$BIN/claude-mock" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"VERIFY_RESULT: CONFIRMED|REFUTED|UNSURE"*)
    echo VERIFY >> "$WORK/calls.log"
    for f in "$WORK"/verify/*.txt; do
      [ -f "\$f" ] || continue
      slug=\$(basename "\$f" .txt)
      case "\$*" in *"[\$slug]"*) cat "\$f"; exit 0 ;; esac
    done
    printf 'Looks real\nVERIFY_RESULT: CONFIRMED\n'
    exit 0 ;;
esac
echo AUDIT >> "$WORK/calls.log"
printf '%s\n' "\$*" > "$WORK/prompt-seen"
[ -f "$WORK/agent.sh" ] && bash "$WORK/agent.sh"
cat "$WORK/review.txt"
[ -f "$WORK/review-rc" ] && exit "\$(cat "$WORK/review-rc")"
exit 0
SH
  chmod +x "$BIN/claude-mock"
  printf 'MERGE_GATE_RESULT: CLEAN\n' > "$WORK/review.txt"
}

# run_audit [args...] — sets RC, OUT. Env overrides go through AUDIT_ENV.
run_audit() {
  set +e
  OUT=$( env PATH="$BIN:$PATH" HOME="$HOME" \
    RUN_ISSUES_CLAUDE_CMD="${CLAUDE_CMD:-$BIN/claude-mock}" \
    RUN_ISSUES_QUALITY_AUDIT_TIMEOUT=60 \
    RUN_ISSUES_WATCHLIST="${WL:-$WORK/no-watchlist.json}" \
    ${AUDIT_ENV:-} "$AUDIT" "$REPO" "$@" 2>&1 )
  RC=$?
}

writes() { grep -c -- '--method' "$WORK/gh.log" 2>/dev/null || true; }
creates() { find "$WORK/created" -name '*.body' | wc -l | tr -d ' '; }
show() { echo "$OUT" | sed "s/^/$1| /"; echo "$1| (rc=$RC)"; }
done_case() { [ -n "${KEEP:-}" ] || rm -rf "$WORK"; }
# created_for <slug> — the number of the issue whose title holds [<slug>].
created_for() { grep -lF "[$1]" "$WORK"/created/*.title 2>/dev/null | head -1 | xargs -n1 basename 2>/dev/null | sed 's/\.title$//'; }
# commit_cfg <json> — the repo's .claude/run-issues.json on the default branch.
commit_cfg() {
  mkdir -p "$REPO/.claude"; printf '%s\n' "$1" > "$REPO/.claude/run-issues.json"
  git -C "$REPO" add .claude; git -C "$REPO" commit -qm cfg
  git -C "$REPO" push -q "$ORIGIN" main
}

F_DI='FINDING: high | high | src/a.php:3 | [data-integrity] retry re-sends the charge: the write is not idempotent'
F_TR='FINDING: medium | high | src/b.php:1 | [test-reliability] the suite skips itself when the DB is missing and reports green'

# ===========================================================================
echo "=== A: findings become quality issues ==="
F0=$FAIL
setup A
printf '%s\n%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_DI" "$F_TR" > "$WORK/review.txt"
run_audit
[ "$RC" = 0 ] || { show A; bad A "rc $RC, want 0"; }
[ "$(creates)" = 2 ] || bad A "created $(creates) issues, want 2"
for slug in data-integrity test-reliability; do
  n=$(created_for "$slug")
  [ -n "$n" ] || { bad A "no issue for [$slug]"; continue; }
  [ "$(cat "$WORK/created/$n.labels")" = quality ] || bad A "[$slug] labels '$(tr '\n' ',' < "$WORK/created/$n.labels")', want quality only"
  [ ! -e "$WORK/created/$n.assignees" ] || bad A "[$slug] was routed below the threshold"
  grep -qF '<!-- run-issues:finding kind=quality fp=' "$WORK/created/$n.body" || bad A "[$slug] lacks the marker"
  grep -qF "(\`$slug\`)" "$WORK/created/$n.body" || bad A "[$slug] body does not name its class"
  for h in '## Tavoite' '## Hyväksyntäkriteerit' '## Rajaukset'; do
    grep -qF "$h" "$WORK/created/$n.body" || bad A "[$slug] body lacks '$h'"
  done
  case "$(cat "$WORK/created/$n.title")" in 'Laatu ('*) ;; *) bad A "[$slug] title '$(cat "$WORK/created/$n.title")'" ;; esac
done
for c in data-integrity rule-consistency default-allow resilience test-reliability maintainability accessibility; do
  grep -qF "[$c]" "$WORK/prompt-seen" || bad A "prompt lacks class [$c]"
done
grep -q -- '--paginate.*labels=quality' "$WORK/gh.log" || bad A "the index is not read by the quality label"
[ "$FAIL" = "$F0" ] && ok A "findings filed with the quality label, no pickup by default"
done_case

# ===========================================================================
echo "=== B: auto-run threshold ==="
F0=$FAIL
# threshold_case <name> <repo-cfg-or-empty> <machine-env-or-empty> <poller.env-or-empty> <want-high-picked 0|1> <want-medium-picked 0|1>
threshold_case() {
  setup "B$1"
  [ -n "$2" ] && commit_cfg "$2"
  if [ -n "$4" ]; then
    mkdir -p "$HOME/.config/run-issues"; printf '%s\n' "$4" > "$HOME/.config/run-issues/poller.env"
  fi
  printf '%s\n%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_DI" "$F_TR" > "$WORK/review.txt"
  AUDIT_ENV=""
  [ -n "$3" ] && AUDIT_ENV="RUN_ISSUES_QUALITY_AUDIT_AUTO_RUN_MIN_SEVERITY=$3"
  run_audit
  AUDIT_ENV=""
  local hi med
  hi=$(created_for data-integrity); med=$(created_for test-reliability)
  local got_hi=0 got_med=0
  grep -qx auto-run "$WORK/created/$hi.labels" 2>/dev/null && got_hi=1
  grep -qx auto-run "$WORK/created/$med.labels" 2>/dev/null && got_med=1
  if [ "$RC" = 0 ] && [ "$got_hi" = "$5" ] && [ "$got_med" = "$6" ]; then ok "B$1" "high picked=$got_hi, medium picked=$got_med"
  else show "B$1"; bad "B$1" "rc $RC, high picked=$got_hi (want $5), medium picked=$got_med (want $6)"; fi
  done_case
}
threshold_case 1 "" high "" 1 0
threshold_case 2 "" "" 'RUN_ISSUES_QUALITY_AUDIT_AUTO_RUN_MIN_SEVERITY=high' 1 0
threshold_case 3 '{"quality":{"audit_auto_run_min_severity":"none"}}' high "" 0 0
threshold_case 4 '{"quality":{"audit_auto_run_min_severity":"medium"}}' "" "" 1 1
threshold_case 5 '{"security":{"audit_auto_run_min_severity":"low"}}' "" "" 0 0
[ "$FAIL" = "$F0" ] && ok B "threshold: default none, machine opt-in, repo wins"

# ===========================================================================
echo "=== C: not a result is not 'no findings' ==="
F0=$FAIL
not_result_case() { # <name> <review-text> [rc]
  setup "C$1"
  printf '%b' "$2" > "$WORK/review.txt"
  [ -n "${3:-}" ] && echo "$3" > "$WORK/review-rc"
  run_audit
  if [ "$RC" = 3 ] && [ "$(writes)" = 0 ] && [ "$(creates)" = 0 ]; then ok "C$1" "exit 3, nothing written"
  else show "C$1"; bad "C$1" "rc $RC, $(writes) write(s)"; fi
  done_case
}
not_result_case 1 'I looked around and everything seems fine.\n'
not_result_case 2 ''
not_result_case 3 'FINDING: high | high | src/a.php:1 | [resilience] no timeout\nMERGE_GATE_RESULT: CLEAN\n'
not_result_case 4 'MERGE_GATE_RESULT: FINDINGS\n'
not_result_case 5 'MERGE_GATE_RESULT: CLEAN\n' 1
setup C6   # the CLI does not exist: the launch check fails before any cost
CLAUDE_CMD="$WORK/no-such-claude" run_audit
if [ "$RC" = 3 ] && [ "$(writes)" = 0 ] && [ ! -s "$WORK/calls.log" ]; then ok C6 "missing CLI: exit 3, nothing written"
else show C6; bad C6 "rc $RC, $(writes) write(s)"; fi
done_case
[ "$FAIL" = "$F0" ] && ok C "not a result"

# ===========================================================================
echo "=== D: the read-only gate ==="
setup D
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_DI" > "$WORK/review.txt"
echo 'echo patched > src/a.php' > "$WORK/agent.sh"
run_audit
if [ "$RC" = 3 ] && [ "$(writes)" = 0 ] && [ "$(creates)" = 0 ]; then ok D "dirty worktree: exit 3, nothing written"
else show D; bad D "rc $RC, $(writes) write(s)"; fi
[ "$(cat "$REPO/src/a.php")" = a ] || bad D "the operator's checkout changed"
done_case

# ===========================================================================
echo "=== E: --dry-run ==="
setup E
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_DI" > "$WORK/review.txt"
run_audit --dry-run
if [ "$RC" = 0 ] && [ "$(writes)" = 0 ] && grep -q '^create \[quality\]' <<<"$OUT" && grep -q 'dry run: nothing written' <<<"$OUT"
then ok E "plan printed, nothing written"
else show E; bad E "rc $RC, $(writes) write(s)"; fi
done_case

# ===========================================================================
echo "=== F: refutation pass ==="
setup F
printf '%s\n%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_DI" "$F_TR" > "$WORK/review.txt"
printf 'Wrapped in a transaction\nVERIFY_RESULT: REFUTED\n' > "$WORK/verify/data-integrity.txt"
AUDIT_ENV="RUN_ISSUES_AUDIT_VERIFY=1" run_audit
if [ "$RC" = 0 ] && [ "$(grep -c VERIFY "$WORK/calls.log")" = 2 ] && [ "$(creates)" = 1 ] \
   && [ -z "$(created_for data-integrity)" ] && [ -n "$(created_for test-reliability)" ]
then ok F "the refuted finding is dropped, the confirmed one filed"
else show F; bad F "rc $RC, $(grep -c VERIFY "$WORK/calls.log") verifier call(s), $(creates) issue(s)"; fi
done_case

# ===========================================================================
echo "=== G: one issue per class and file ==="
setup G
{
  echo 'FINDING: medium | high | src/a.php:1 | [maintainability] dead helper never called'
  echo 'FINDING: medium | high | src/b.php:9 | [maintainability] copy of the date formatter'
  echo 'FINDING: low | medium | src/a.php:40 | [maintainability] another unused branch'
  echo 'MERGE_GATE_RESULT: FINDINGS'
} > "$WORK/review.txt"
run_audit
if [ "$RC" = 0 ] && [ "$(creates)" = 2 ] && [ "$(grep -c '^duplicate' <<<"$OUT")" = 1 ]
then ok G "two files → two issues, the same file again → duplicate"
else show G; bad G "rc $RC, $(creates) issue(s), want 2 and one duplicate"; fi
done_case

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "quality-audit: all passed" || echo "quality-audit: FAILURES"
[ "$FAIL" -eq 0 ]
