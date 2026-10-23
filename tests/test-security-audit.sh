#!/usr/bin/env bash
# test-security-audit.sh — security-audit.sh end to end (issue #339). The agent
# is stubbed through RUN_ISSUES_CLAUDE_CMD (CLAUDE.md §5.5), gh is a PATH shim
# that records every call, and a git shim routes `fetch` of the github.com
# remote to a local bare repo — no network. Scanners are hidden unless a case
# installs a shim.
#
#   A) finding            -> one issue: security + pickup label, marker, the
#                            issue format (Tavoite / Hyväksyntäkriteerit /
#                            Rajaukset), exactly one finding in the body
#   B) open duplicate     -> no write, "exists #N"
#   C) closed, recurs     -> reopened + comment
#   D) closed, no recur   -> stays closed, no write
#   E) closed not planned -> never reopened
#   F) same finding twice in one audit -> one issue
#   G) policy             -> default: medium gets no pickup label; repo `low`
#                            beats machine `critical`; machine `medium` applies
#                            without a repo value (also from poller.env); repo
#                            `none` stops even a high;
#                            watchlist labels are the pickup labels
#   H) launch failure     -> CLI missing (preflight) and rc 127: exit 3, no write
#   I) unparseable result -> exit 3, no write
#   J) worktree changed   -> exit 3, no write
#   K) --dry-run          -> plan printed, no write
#   L) scanner failed     -> exit 5, the failure is not an issue
#   M) listing failed     -> exit 4, no agent call, no write
#   N) scanner finding    -> a gitleaks row becomes an issue keyed on its rule
#
# Run: bash tests/test-security-audit.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="$HERE/../security-audit.sh"

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
  WORK=$(mktemp -d -t secaudit-"$1".XXXXXX)
  export HOME="$WORK/home"; mkdir -p "$HOME"
  # The audit keeps its work dir on exit 3 — inside WORK, so it is cleaned too.
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
    mkdir -p src; echo '<?php echo $_GET["q"];' > src/a.php
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
  # The audit resolves the default branch from origin/HEAD.
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
  *--paginate*)
    [ -f "$WORK/list-fail" ] && { echo "HTTP 502" >&2; exit 1; }
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
    RUN_ISSUES_CLAUDE_CMD="$BIN/claude-mock" \
    RUN_ISSUES_SECURITY_AUDIT_TIMEOUT=60 \
    RUN_ISSUES_WATCHLIST="${WL:-$WORK/no-watchlist.json}" \
    RUN_ISSUES_GITLEAKS_BIN="${GITLEAKS:-$WORK/no-gitleaks}" RUN_ISSUES_OSV_SCANNER_BIN="$WORK/no-osv" \
    ${AUDIT_ENV:-} "$AUDIT" "$REPO" "$@" 2>&1 )
  RC=$?
}

writes() { grep -c -- '--method' "$WORK/gh.log" 2>/dev/null || true; }
creates() { find "$WORK/created" -name '*.body' | wc -l | tr -d ' '; }
show() { echo "$OUT" | sed "s/^/$1| /"; echo "$1| (rc=$RC)"; }
done_case() { [ -n "${KEEP:-}" ] || rm -rf "$WORK"; }

# fp_of <source> <location> <key> — the fingerprint the audit computes.
fp_of() { ( . "$HERE/../lib/finding-issues.sh"; finding_fingerprint "$@" ); }

# issue_json <number> <state> <state_reason> <fp>
issue_json() {
  jq -n --argjson n "$1" --arg s "$2" --arg r "$3" --arg fp "$4" \
    '[{number:$n, state:$s, state_reason:(if $r == "" then null else $r end), title:"old",
       body:("text\n<!-- run-issues:finding kind=security fp=" + $fp + " -->")}]'
}

F_HIGH='FINDING: high | high | src/a.php:1 | [xss] GET parameter q is echoed unescaped into HTML'
FP_XSS=$(fp_of agent src/a.php xss)

# ===========================================================================
echo "=== A: finding -> issue ==="
setup A
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_HIGH" > "$WORK/review.txt"
run_audit; show A
[ "$RC" = 0 ] || bad A "rc $RC, want 0"
[ "$(creates)" = 1 ] || bad A "created $(creates) issues, want 1"
B="$WORK/created/100.body"
grep -qF "<!-- run-issues:finding kind=security fp=$FP_XSS -->" "$B" 2>/dev/null || bad A "marker with the fingerprint missing"
for h in '## Tavoite' '## Hyväksyntäkriteerit' '## Rajaukset'; do
  grep -qx "$h" "$B" 2>/dev/null || bad A "body lacks '$h'"
done
[ "$(grep -c '^- \*\*Vakavuus:\*\*' "$B" 2>/dev/null)" = 1 ] || bad A "body does not hold exactly one finding"
grep -qx security "$WORK/created/100.labels" 2>/dev/null || bad A "security label missing"
grep -qx auto-run "$WORK/created/100.labels" 2>/dev/null || bad A "high finding lacks the default pickup label"
grep -q 'labels -f name=security' "$WORK/gh.log" || bad A "security label not ensured"
grep -q "^created #100" <<<"$OUT" || bad A "output does not report the created issue"
[ -z "$(git -C "$REPO" worktree list | sed 1d)" ] || bad A "temporary worktree left behind"
[ -z "$(ls -A "$TMPDIR")" ] || bad A "work dir left behind after a successful audit"
[ "$FAIL" = 0 ] && ok A "finding filed as one issue"
done_case

# ===========================================================================
echo "=== B: open duplicate ==="
F0=$FAIL; setup B
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_HIGH" > "$WORK/review.txt"
issue_json 7 open "" "$FP_XSS" > "$WORK/issues.json"
run_audit; show B
[ "$RC" = 0 ] || bad B "rc $RC, want 0"
[ "$(writes)" = 0 ] || bad B "$(writes) write call(s), want 0"
grep -q "^exists #7" <<<"$OUT" || bad B "output does not name the existing issue"
grep -q '#7 (open) old' "$WORK/prompt-seen" || bad B "known finding not given to the agent"
[ "$FAIL" = "$F0" ] && ok B "open issue not duplicated"
done_case

# ===========================================================================
echo "=== C: closed + recurs -> reopened ==="
F0=$FAIL; setup C
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_HIGH" > "$WORK/review.txt"
issue_json 8 closed completed "$FP_XSS" > "$WORK/issues.json"
run_audit; show C
[ "$RC" = 0 ] || bad C "rc $RC, want 0"
grep -q 'PATCH repos/Silon-Oy/app/issues/8 -f state=open' "$WORK/gh.log" || bad C "not reopened"
grep -q 'POST repos/Silon-Oy/app/issues/8/comments' "$WORK/gh.log" || bad C "no reopen comment"
[ "$(creates)" = 0 ] || bad C "a new issue was created"
[ "$FAIL" = "$F0" ] && ok C "recurring finding reopened its issue"
done_case

# ===========================================================================
echo "=== D: closed, does not recur ==="
F0=$FAIL; setup D
issue_json 8 closed completed "$FP_XSS" > "$WORK/issues.json"
run_audit; show D
[ "$RC" = 0 ] || bad D "rc $RC, want 0"
[ "$(writes)" = 0 ] || bad D "$(writes) write call(s), want 0"
[ "$FAIL" = "$F0" ] && ok D "fixed finding stays closed"
done_case

# ===========================================================================
echo "=== E: closed as not planned ==="
F0=$FAIL; setup E
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_HIGH" > "$WORK/review.txt"
issue_json 9 closed not_planned "$FP_XSS" > "$WORK/issues.json"
run_audit; show E
[ "$RC" = 0 ] || bad E "rc $RC, want 0"
[ "$(writes)" = 0 ] || bad E "$(writes) write call(s), want 0"
grep -q "^dismissed #9" <<<"$OUT" || bad E "not reported as dismissed"
[ "$FAIL" = "$F0" ] && ok E "dismissed finding never reopened"
done_case

# ===========================================================================
echo "=== F: same finding twice in one audit ==="
F0=$FAIL; setup F
printf '%s\n%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_HIGH" \
  'FINDING: high | medium | src/a.php:9 | [xss] another echo of q' > "$WORK/review.txt"
run_audit; show F
[ "$RC" = 0 ] || bad F "rc $RC, want 0"
[ "$(creates)" = 1 ] || bad F "created $(creates) issues, want 1"
grep -q '^duplicate' <<<"$OUT" || bad F "second occurrence not reported as duplicate"
[ "$FAIL" = "$F0" ] && ok F "one issue per fingerprint per audit"
done_case

# ===========================================================================
echo "=== G: policy ==="
F0=$FAIL
F_MED='FINDING: medium | high | src/a.php:1 | [csrf] form posts without a token'
policy_case() { # <label> <repo-config-or-empty> <machine-or-empty> <finding> <want-auto-run 0|1>
  setup "G$1"
  if [ -n "$2" ]; then
    mkdir -p "$REPO/.claude"; printf '%s\n' "$2" > "$REPO/.claude/run-issues.json"
    git -C "$REPO" add .claude; git -C "$REPO" commit -qm cfg
    git -C "$REPO" push -q "$ORIGIN" main
  fi
  printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$4" > "$WORK/review.txt"
  AUDIT_ENV=""
  [ -n "$3" ] && AUDIT_ENV="RUN_ISSUES_SECURITY_AUDIT_AUTO_RUN_MIN_SEVERITY=$3"
  run_audit
  AUDIT_ENV=""
  local got=0
  grep -qx auto-run "$WORK/created/100.labels" 2>/dev/null && got=1
  if [ "$RC" = 0 ] && [ "$got" = "$5" ] && grep -qx security "$WORK/created/100.labels"; then
    ok "G$1" "pickup label=$got"
  else
    show "G$1"; bad "G$1" "rc $RC, pickup label=$got, want $5"
  fi
  done_case
}
policy_case 1 "" "" "$F_MED" 0
policy_case 2 '{"security":{"audit_auto_run_min_severity":"low"}}' critical "$F_MED" 1
policy_case 3 "" medium "$F_MED" 1
policy_case 4 '{"security":{"audit_auto_run_min_severity":"none"}}' "" "$F_HIGH" 0
policy_case 5 '{"security":{"audit_auto_run_min_severity":"bogus"}}' "" "$F_HIGH" 0

setup G7   # the machine value from poller.env
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_MED" > "$WORK/review.txt"
mkdir -p "$HOME/.config/run-issues"
echo 'RUN_ISSUES_SECURITY_AUDIT_AUTO_RUN_MIN_SEVERITY=medium' > "$HOME/.config/run-issues/poller.env"
run_audit
if grep -qx auto-run "$WORK/created/100.labels" 2>/dev/null; then ok G7 "poller.env threshold applies"
else show G7; bad G7 "poller.env threshold 'medium' not applied"; fi
done_case

setup G6
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_HIGH" > "$WORK/review.txt"
jq -n --arg p "$REPO" '{repos: [{path: $p, labels: ["auto-run", "backend"]}]}' > "$WORK/wl.json"
WL="$WORK/wl.json" run_audit
if grep -qx backend "$WORK/created/100.labels" 2>/dev/null; then ok G6 "watchlist pickup labels used"
else show G6; bad G6 "watchlist label 'backend' missing"; fi
done_case
[ "$FAIL" = "$F0" ] && ok G "policy"

# ===========================================================================
echo "=== H: launch failure ==="
F0=$FAIL; setup H1
AUDIT_ENV="RUN_ISSUES_CLAUDE_CMD=$WORK/no-claude" run_audit; AUDIT_ENV=""; show H1
[ "$RC" = 3 ] || bad H1 "rc $RC, want 3"
[ "$(writes)" = 0 ] || bad H1 "$(writes) write call(s), want 0"
done_case
setup H2
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_HIGH" > "$WORK/review.txt"
echo 127 > "$WORK/review-rc"
run_audit; show H2
[ "$RC" = 3 ] || bad H2 "rc $RC, want 3"
[ "$(writes)" = 0 ] || bad H2 "$(writes) write call(s), want 0"
done_case
[ "$FAIL" = "$F0" ] && ok H "launch failure is not a result"

# ===========================================================================
echo "=== I: unparseable result ==="
F0=$FAIL; setup I
printf 'I looked around and everything seems fine.\n' > "$WORK/review.txt"
run_audit; show I
[ "$RC" = 3 ] || bad I "rc $RC, want 3"
[ "$(writes)" = 0 ] || bad I "$(writes) write call(s), want 0"
[ "$FAIL" = "$F0" ] && ok I "unparseable result is not 'no findings'"
done_case

# ===========================================================================
echo "=== J: worktree changed ==="
F0=$FAIL; setup J
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_HIGH" > "$WORK/review.txt"
echo 'echo patched > src/a.php' > "$WORK/agent.sh"
run_audit; show J
[ "$RC" = 3 ] || bad J "rc $RC, want 3"
[ "$(writes)" = 0 ] || bad J "$(writes) write call(s), want 0"
[ "$(git -C "$REPO" show HEAD:src/a.php)" = "$(cat "$REPO/src/a.php")" ] || bad J "the operator's working tree changed"
[ "$FAIL" = "$F0" ] && ok J "writing agent rejected"
done_case

# ===========================================================================
echo "=== K: --dry-run ==="
F0=$FAIL; setup K
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_HIGH" > "$WORK/review.txt"
run_audit --dry-run; show K
[ "$RC" = 0 ] || bad K "rc $RC, want 0"
[ "$(writes)" = 0 ] || bad K "$(writes) write call(s), want 0"
grep -q '^create \[security,auto-run\]' <<<"$OUT" || bad K "planned action not printed"
grep -q 'dry run: nothing written' <<<"$OUT" || bad K "summary does not say dry run"
[ "$FAIL" = "$F0" ] && ok K "dry run writes nothing"
done_case

# ===========================================================================
echo "=== L: scanner failed ==="
F0=$FAIL; setup L
printf '#!/usr/bin/env bash\necho boom >&2\nexit 2\n' > "$BIN/gitleaks-broken"; chmod +x "$BIN/gitleaks-broken"
GITLEAKS="$BIN/gitleaks-broken" run_audit; show L
[ "$RC" = 5 ] || bad L "rc $RC, want 5"
[ "$(writes)" = 0 ] || bad L "$(writes) write call(s), want 0 (a failed scanner is not an issue)"
grep -q 'scanner(s) failed: gitleaks' <<<"$OUT" || bad L "failure not reported"
[ "$FAIL" = "$F0" ] && ok L "failed scanner reported, not filed"
done_case

# ===========================================================================
echo "=== M: listing failed ==="
F0=$FAIL; setup M
touch "$WORK/list-fail"
run_audit; show M
[ "$RC" = 4 ] || bad M "rc $RC, want 4"
[ "$(writes)" = 0 ] || bad M "$(writes) write call(s), want 0"
[ ! -s "$WORK/calls.log" ] || bad M "agent called although the index could not be read"
[ "$FAIL" = "$F0" ] && ok M "no index, no audit"
done_case

# ===========================================================================
echo "=== N: scanner finding ==="
F0=$FAIL; setup N
cat > "$BIN/gitleaks-mock" <<'SH'
#!/usr/bin/env bash
r=""
while [ $# -gt 0 ]; do [ "$1" = --report-path ] && r="$2"; shift; done
echo '[{"File":"config/app.php","StartLine":3,"RuleID":"generic-api-key","Description":"Generic API Key","Commit":"abcdef1234567890"}]' > "$r"
exit 99
SH
chmod +x "$BIN/gitleaks-mock"
GITLEAKS="$BIN/gitleaks-mock" run_audit; show N
[ "$RC" = 0 ] || bad N "rc $RC, want 0"
[ "$(creates)" = 1 ] || bad N "created $(creates) issues, want 1"
grep -qF "fp=$(fp_of gitleaks config/app.php generic-api-key) " "$WORK/created/100.body" 2>/dev/null \
  || bad N "gitleaks finding not keyed on its rule"
grep -q 'kierrätys' "$WORK/created/100.body" 2>/dev/null || bad N "secret issue lacks the rotation note"
[ "$FAIL" = "$F0" ] && ok N "scanner finding filed"
done_case

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "security-audit: all passed" || echo "security-audit: FAILURES"
[ "$FAIL" -eq 0 ]
