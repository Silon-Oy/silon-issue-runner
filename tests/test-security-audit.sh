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
#   O) assignee routing   -> (issue #374) a watchlist `assignees` list routes an
#                            auto-run issue to its first allowed login and the
#                            issue then matches pickup; no key / only `not:` /
#                            below threshold => no assignee; a reopened issue
#                            is routed only when it has no assignee
#   P) unchanged code     -> (issue #382) a scheduled run at the commit of the
#                            last successful audit: no agent call, the scanners
#                            ran, exit 6 and the skip on the output; with no
#                            scanner installed exit 7, not clean
#   Q) changed base / no recorded commit / hand run / dry run -> full audit
#   R) accepted full audit -> leaves the audited commit pending for audit_run;
#                            a rejected one does not
#   S) --scanners-only     -> no agent call, no launch check
#   V) finding verification (#394, RUN_ISSUES_AUDIT_VERIFY=1) -> CONFIRMED is
#                            filed as before with its pickup labels; REFUTED is
#                            dropped and logged; UNSURE is filed with the
#                            security label only, no assignee and a note; a
#                            verifier that fails (rc 1, rc 124, unparseable)
#                            reads as UNSURE; one that moves HEAD or dirties
#                            the worktree rejects the audit (exit 3, no write);
#                            scanner rows are not verified; off => no verifier
#                            call; --dry-run marks [unsure]
#
# Run: bash tests/test-security-audit.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Hermetic: never source this machine's real env file (CLAUDE.md §5.5, #358).
export RUN_ISSUES_ENV_FILE="$HERE/.no-such-machine-env"
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
        assignees\[\]=*) printf '%s\n' "\${a#assignees[]=}" >> "$WORK/created/\$n.assignees" ;;
      esac
    done
    if [ -f "$WORK/created/\$n.assignees" ] && [ ! -f "$WORK/drop-assignee" ]; then
      printf '{"number":%s,"assignees":[{"login":"%s"}]}\n' "\$n" "\$(head -1 "$WORK/created/\$n.assignees")"
    else
      printf '{"number":%s,"assignees":[]}\n' "\$n"
    fi
    exit 0 ;;
  *"--method PATCH repos/Silon-Oy/app/issues/"*)
    cat "$WORK/patch-resp" 2>/dev/null || echo '{"assignees":[]}'
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$BIN/gh"

  # A verifier call (prompts/13-finding-verify.md, #394) answers from
  # verify/<slug>.txt for the finding whose description holds [<slug>] —
  # CONFIRMED when there is none — with verify/<slug>.rc and verify/<slug>.sh
  # as the exit code and a side effect.
  mkdir -p "$WORK/verify"
  cat > "$BIN/claude-mock" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"VERIFY_RESULT: CONFIRMED|REFUTED|UNSURE"*)
    echo VERIFY >> "$WORK/calls.log"
    for f in "$WORK"/verify/*.txt; do
      [ -f "\$f" ] || continue
      slug=\$(basename "\$f" .txt)
      case "\$*" in *"[\$slug]"*)
        [ -f "$WORK/verify/\$slug.sh" ] && bash "$WORK/verify/\$slug.sh"
        cat "\$f"
        [ -f "$WORK/verify/\$slug.rc" ] && exit "\$(cat "$WORK/verify/\$slug.rc")"
        exit 0 ;;
      esac
    done
    printf 'Looks real: src/a.php:1\nVERIFY_RESULT: CONFIRMED\n'
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

# ===========================================================================
echo "=== O: assignee routing (issue #374) ==="
F0=$FAIL
# wl_with <assignees-json-or-empty> — a watchlist entry for the repo.
wl_with() {
  if [ -n "$1" ]; then
    jq -n --arg p "$REPO" --argjson a "$1" '{repos: [{path: $p, labels: ["auto-run"], assignees: $a}]}'
  else
    jq -n --arg p "$REPO" '{repos: [{path: $p, labels: ["auto-run"]}]}'
  fi > "$WORK/wl.json"
}
# picked_by_filter <n> <assignees-csv> — does issue <n>, as created (labels,
# assignees, author = the runner's own identity), pass the pickup filter?
picked_by_filter() (
  . "$HERE/../lib/issue.sh"; set +e
  jq -n --argjson n "$1" \
    --rawfile l "$WORK/created/$1.labels" \
    --arg a "$(cat "$WORK/created/$1.assignees" 2>/dev/null)" \
    '[{number:$n, labels:($l | split("\n") | map(select(length > 0)) | map({name:.})),
       assignees:($a | split("\n") | map(select(length > 0)) | map({login:.})),
       user:{login:"runner-app[bot]"}}]' \
  | RUN_ISSUES_PICK_ASSIGNEES="$2" RUN_ISSUES_PICK_CLEAN=auto-clean RUN_ISSUES_PICK_RESET=auto-reset \
      jq -r "$(_pick_filter_jq)"
)

setup O1   # routed repo: first allowed login, and pickup matches
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_HIGH" > "$WORK/review.txt"
wl_with '["not:runner-b","runner-a","other"]'
WL="$WORK/wl.json" run_audit
if [ "$RC" = 0 ] && [ "$(cat "$WORK/created/100.assignees" 2>/dev/null)" = runner-a ] \
   && grep -qx auto-run "$WORK/created/100.labels" \
   && [ "$(picked_by_filter 100 'not:runner-b,runner-a,other')" = 100 ]; then
  ok O1 "routed to the first allowed login, and the issue matches pickup"
else show O1; bad O1 "rc $RC, assignee '$(cat "$WORK/created/100.assignees" 2>/dev/null)', want runner-a and a pickup match"; fi
# Without the route the same issue would not match: the guard is not vacuous.
rm -f "$WORK/created/100.assignees"
[ -z "$(picked_by_filter 100 'not:runner-b,runner-a,other')" ] || bad O1 "the unrouted issue matches too — the check proves nothing"
done_case

no_assignee_case() { # <label> <assignees-json-or-empty> <finding> <what>
  setup "$1"
  printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$3" > "$WORK/review.txt"
  wl_with "$2"
  WL="$WORK/wl.json" run_audit
  if [ "$RC" = 0 ] && [ "$(creates)" = 1 ] && [ ! -e "$WORK/created/100.assignees" ] \
     && ! grep -q 'assignees\[\]' "$WORK/gh.log"; then
    ok "$1" "$4: no assignee"
  else show "$1"; bad "$1" "$4: rc $RC, assignee '$(cat "$WORK/created/100.assignees" 2>/dev/null)'"; fi
  done_case
}
no_assignee_case O2 "" "$F_HIGH" "no assignees key"
no_assignee_case O3 '["not:someone"]' "$F_HIGH" "only a negation"
no_assignee_case O4 '["runner-a"]' "$F_MED" "below the auto-run threshold"

setup O5   # the route is shown in the dry-run plan
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_HIGH" > "$WORK/review.txt"
wl_with '["runner-a"]'
WL="$WORK/wl.json" run_audit --dry-run
grep -q '^create \[security,auto-run\] @runner-a' <<<"$OUT" && [ "$(writes)" = 0 ] \
  && ok O5 "dry run names the route" || { show O5; bad O5 "dry-run plan lacks '@runner-a'"; }
done_case

setup O6   # reopen of an unassigned issue: routed
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_HIGH" > "$WORK/review.txt"
issue_json 8 closed completed "$FP_XSS" > "$WORK/issues.json"
wl_with '["runner-a"]'
WL="$WORK/wl.json" run_audit
grep -q 'POST repos/Silon-Oy/app/issues/8/assignees -f assignees\[\]=runner-a' "$WORK/gh.log" \
  && [ "$RC" = 0 ] && ok O6 "reopened unassigned issue routed" \
  || { show O6; bad O6 "rc $RC, no assignee write on reopen"; }
done_case

setup O7   # reopen of an assigned issue: the human's routing stays
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_HIGH" > "$WORK/review.txt"
issue_json 8 closed completed "$FP_XSS" > "$WORK/issues.json"
echo '{"assignees":[{"login":"human"}]}' > "$WORK/patch-resp"
wl_with '["runner-a"]'
WL="$WORK/wl.json" run_audit
! grep -q 'issues/8/assignees' "$WORK/gh.log" && [ "$RC" = 0 ] \
  && ok O7 "reopened assigned issue keeps its assignee" \
  || { show O7; bad O7 "rc $RC, the existing assignment was touched"; }
done_case

setup O8   # GitHub drops the assignee (no repo access): warning, not a failure
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_HIGH" > "$WORK/review.txt"
touch "$WORK/drop-assignee"
wl_with '["runner-a"]'
WL="$WORK/wl.json" run_audit
[ "$RC" = 0 ] && grep -q 'did not keep the assignee' <<<"$OUT" \
  && ok O8 "dropped assignee reported, issue still filed" \
  || { show O8; bad O8 "rc $RC, dropped assignee not reported"; }
done_case
[ "$FAIL" = "$F0" ] && ok O "assignee routing"

# ---- unchanged code (#382) -----------------------------------------------------
# gitleaks_clean — a gitleaks shim that finds nothing and counts its calls.
gitleaks_clean() {
  cat > "$BIN/gitleaks-clean" <<SH
#!/usr/bin/env bash
echo SCAN >> "$WORK/scans.log"
r=""
while [ \$# -gt 0 ]; do [ "\$1" = --report-path ] && r="\$2"; shift; done
echo '[]' > "\$r"
exit 0
SH
  chmod +x "$BIN/gitleaks-clean"
  GITLEAKS="$BIN/gitleaks-clean"
}
agent_calls() { grep -c AUDIT "$WORK/calls.log" 2>/dev/null || true; }
origin_sha() { git -C "$REPO" rev-parse origin/main; }

echo "=== P: unchanged code -> scanners only ==="
F0=$FAIL; setup P; gitleaks_clean
ST="$WORK/state"; origin_sha > "$ST.sha"
AUDIT_ENV="RUN_ISSUES_AUDIT_STATE_FILE=$ST" run_audit
[ "$RC" = 6 ] || { show P; bad P "rc $RC, want 6"; }
[ "$(agent_calls)" = 0 ] || bad P "$(agent_calls) agent call(s), want 0"
[ "$(grep -c SCAN "$WORK/scans.log" 2>/dev/null)" = 1 ] || bad P "the scanner did not run"
grep -q 'code unchanged since last successful audit' <<<"$OUT" || bad P "the skip is not on the output"
grep -q '(code unchanged: scanners only)' <<<"$OUT" || bad P "the summary does not name the mode"
[ ! -e "$ST.sha.pending" ] || bad P "a skipped audit left a commit to record"
[ "$FAIL" = "$F0" ] && ok P "unchanged code: scanners only, no agent"
done_case

F0=$FAIL; setup P2   # unchanged, and no scanner installed: nothing was checked
ST="$WORK/state"; origin_sha > "$ST.sha"
AUDIT_ENV="RUN_ISSUES_AUDIT_STATE_FILE=$ST" run_audit
[ "$RC" = 7 ] || { show P2; bad P2 "rc $RC, want 7"; }
[ "$(agent_calls)" = 0 ] || bad P2 "$(agent_calls) agent call(s), want 0"
grep -q 'NOT CHECKED' <<<"$OUT" || bad P2 "the summary reads as clean"
[ "$FAIL" = "$F0" ] && ok P2 "unchanged code without scanners is not clean"
done_case

F0=$FAIL; setup P3   # the agent CLI is missing: no launch check when it is not needed
gitleaks_clean
ST="$WORK/state"; origin_sha > "$ST.sha"
AUDIT_ENV="RUN_ISSUES_AUDIT_STATE_FILE=$ST RUN_ISSUES_CLAUDE_CMD=$WORK/no-such-cli" run_audit
[ "$RC" = 6 ] || { show P3; bad P3 "rc $RC, want 6 (no agent runs, so no launch check)"; }
[ "$FAIL" = "$F0" ] && ok P3 "unchanged code needs no agent CLI"
done_case

echo "=== Q: full audit when the base moved, nothing is recorded, or by hand ==="
F0=$FAIL
full_case() { # <label> <what> <prepare-cmd> [args...]
  local label="$1" what="$2" prep="$3"; shift 3
  setup "$label"; gitleaks_clean
  ST="$WORK/state"
  eval "$prep"
  AUDIT_ENV="${QENV-RUN_ISSUES_AUDIT_STATE_FILE=$ST}" run_audit "$@"
  if [ "$RC" = 0 ] && [ "$(agent_calls)" = 1 ]; then
    ok "$label" "$what: full audit"
  else show "$label"; bad "$label" "$what: rc $RC, $(agent_calls) agent call(s), want 0 and 1"; fi
  done_case
}
full_case Q1 "base moved" 'echo 0000000000000000000000000000000000000000 > "$ST.sha"'
full_case Q2 "no recorded commit" ':'
QENV="" full_case Q3 "hand run (no state file)" 'origin_sha > "$ST.sha"'
full_case Q4 "dry run" 'origin_sha > "$ST.sha"' --dry-run
[ "$FAIL" = "$F0" ] && ok Q "full audit unless the code is unchanged"

echo "=== R: the audited commit is left for audit_run ==="
F0=$FAIL; setup R
ST="$WORK/state"
AUDIT_ENV="RUN_ISSUES_AUDIT_STATE_FILE=$ST" run_audit
[ "$RC" = 0 ] || bad R "rc $RC, want 0"
[ "$(cat "$ST.sha.pending" 2>/dev/null)" = "$(origin_sha)" ] || bad R "pending commit '$(cat "$ST.sha.pending" 2>/dev/null)', want $(origin_sha)"
[ ! -e "$ST.sha" ] || bad R "the script promoted the commit itself (audit_run's job)"
done_case
setup R2   # a rejected audit (unparseable answer) records nothing
ST="$WORK/state"; printf 'nothing useful\n' > "$WORK/review.txt"
AUDIT_ENV="RUN_ISSUES_AUDIT_STATE_FILE=$ST" run_audit
[ "$RC" = 3 ] || bad R2 "rc $RC, want 3"
[ ! -e "$ST.sha.pending" ] || bad R2 "a rejected audit left a commit to record"
done_case
setup R3   # end to end through audit_run: the next scheduled start skips the agent
gitleaks_clean
ST="$WORK/state"
r3() {
  set +e
  OUT=$( env PATH="$BIN:$PATH" HOME="$HOME" RUN_ISSUES_CLAUDE_CMD="$BIN/claude-mock" \
    RUN_ISSUES_SECURITY_AUDIT_TIMEOUT=60 RUN_ISSUES_WATCHLIST="$WORK/no-watchlist.json" \
    RUN_ISSUES_GITLEAKS_BIN="$GITLEAKS" RUN_ISSUES_OSV_SCANNER_BIN="$WORK/no-osv" \
    bash -c '. "$0"; audit_run "$@"' "$HERE/../lib/audit-schedule.sh" "$ST" 1800000000 "$AUDIT" "$REPO" 2>&1 )
  RC=$?
}
r3; [ "$RC" = 0 ] || { show R3; bad R3 "first run rc $RC, want 0"; }
r3; [ "$RC" = 6 ] || { show R3; bad R3 "second run rc $RC, want 6"; }
[ "$(agent_calls)" = 1 ] || bad R3 "$(agent_calls) agent call(s) over two runs, want 1"
[ "$(cat "$ST.result" 2>/dev/null)" = "1800000000 6" ] || bad R3 "result '$(cat "$ST.result" 2>/dev/null)', want '1800000000 6'"
done_case
[ "$FAIL" = "$F0" ] && ok R "audited commit recorded only through audit_run"

echo "=== S: --scanners-only ==="
F0=$FAIL; setup S; gitleaks_clean
AUDIT_ENV="RUN_ISSUES_CLAUDE_CMD=$WORK/no-such-cli" run_audit --scanners-only
[ "$RC" = 0 ] || { show S; bad S "rc $RC, want 0"; }
[ "$(agent_calls)" = 0 ] || bad S "$(agent_calls) agent call(s), want 0"
grep -q '(scanners only)' <<<"$OUT" || bad S "the summary does not name the mode"
done_case
[ "$FAIL" = "$F0" ] && ok S "scanners only: no agent, no launch check"

echo "=== V: finding verification ==="
F0=$FAIL
F_SQL='FINDING: high | high | src/a.php:1 | [sql-injection] q reaches a query unescaped'
F_CMD='FINDING: high | high | src/a.php:1 | [command-injection] q reaches a shell'
verify_calls() { grep -c VERIFY "$WORK/calls.log" 2>/dev/null || true; }
# created_for <slug> — the number of the created issue whose title names [slug].
created_for() { grep -l -F "[$1]" "$WORK"/created/*.title 2>/dev/null | sed -E 's#.*/([0-9]+)\.title#\1#' | head -1; }
VON="RUN_ISSUES_AUDIT_VERIFY=1"

setup V1   # CONFIRMED / REFUTED / UNSURE in one audit, with assignee routing
printf '%s\n%s\n%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_HIGH" "$F_SQL" "$F_CMD" > "$WORK/review.txt"
printf 'Escaped at src/a.php:1\nVERIFY_RESULT: REFUTED\n' > "$WORK/verify/sql-injection.txt"
printf 'Depends on config\nVERIFY_RESULT: UNSURE\n' > "$WORK/verify/command-injection.txt"
jq -n --arg p "$REPO" '{repos: [{path: $p, labels: ["auto-run"], assignees: ["bot-a"]}]}' > "$WORK/wl.json"
WL="$WORK/wl.json" AUDIT_ENV="$VON" run_audit
[ "$RC" = 0 ] || { show V1; bad V1 "rc $RC, want 0"; }
[ "$(verify_calls)" = 3 ] || bad V1 "$(verify_calls) verifier call(s), want 3"
[ "$(creates)" = 2 ] || bad V1 "created $(creates) issues, want 2 (refuted dropped)"
[ -z "$(created_for sql-injection)" ] || bad V1 "the refuted finding was filed"
grep -q 'finding refuted by verifier: src/a.php:1 — \[sql-injection\]' <<<"$OUT" || bad V1 "the refuted finding is not logged"
grep -q 'verified: 1 confirmed, 1 refuted, 1 unsure' <<<"$OUT" || bad V1 "no summary line"
n=$(created_for xss)
grep -qx auto-run "$WORK/created/$n.labels" 2>/dev/null || bad V1 "the confirmed finding lost its pickup label"
grep -qx bot-a "$WORK/created/$n.assignees" 2>/dev/null || bad V1 "the confirmed finding lost its route"
grep -q 'Tarkistus:' "$WORK/created/$n.body" 2>/dev/null && bad V1 "the confirmed finding carries the unsure note"
n=$(created_for command-injection)
[ "$(cat "$WORK/created/$n.labels" 2>/dev/null)" = security ] || bad V1 "unsure labels '$(tr '\n' ',' < "$WORK/created/$n.labels" 2>/dev/null)', want security only"
[ ! -e "$WORK/created/$n.assignees" ] || bad V1 "the unsure finding was routed"
grep -q '^> \*\*Tarkistus:\*\*' "$WORK/created/$n.body" 2>/dev/null || bad V1 "the unsure finding lacks the note"
grep -qF '<!-- run-issues:finding kind=security' "$WORK/created/$n.body" 2>/dev/null || bad V1 "the unsure finding lost its marker"
[ "$FAIL" = "$F0" ] && ok V1 "confirmed filed, refuted dropped, unsure filed without pickup"
done_case

verifier_fails() { # <label> <what> <reply> [<rc>]
  setup "$1"
  printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_HIGH" > "$WORK/review.txt"
  printf '%b' "$3" > "$WORK/verify/xss.txt"
  [ -n "${4:-}" ] && echo "$4" > "$WORK/verify/xss.rc"
  AUDIT_ENV="$VON" run_audit
  if [ "$RC" = 0 ] && [ "$(creates)" = 1 ] && [ "$(cat "$WORK/created/100.labels" 2>/dev/null)" = security ] \
     && grep -q 'Tarkistus:' "$WORK/created/100.body"; then
    ok "$1" "$2: filed as unsure"
  else show "$1"; bad "$1" "$2: rc $RC, $(creates) issue(s), labels '$(tr '\n' ',' < "$WORK/created/100.labels" 2>/dev/null)'"; fi
  done_case
}
verifier_fails V2 "verifier rc 1" 'VERIFY_RESULT: REFUTED\n' 1
verifier_fails V3 "verifier timeout (rc 124)" '' 124
verifier_fails V4 "unparseable answer" 'I think it is refuted.\n'
verifier_fails V5 "result not on the last line" 'VERIFY_RESULT: REFUTED\nmore text\n'

for v in V6 V7; do   # a verifier that moves HEAD / dirties the worktree
  setup "$v"
  printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_HIGH" > "$WORK/review.txt"
  printf 'VERIFY_RESULT: CONFIRMED\n' > "$WORK/verify/xss.txt"
  if [ "$v" = V6 ]; then
    echo 'git -c user.email=t@t.t -c user.name=t commit -q --allow-empty -m moved' > "$WORK/verify/xss.sh"
  else
    echo 'echo dirt >> src/a.php' > "$WORK/verify/xss.sh"
  fi
  AUDIT_ENV="$VON" run_audit
  if [ "$RC" = 3 ] && [ "$(writes)" = 0 ] && grep -q 'finding verifier changed the worktree' <<<"$OUT"; then
    ok "$v" "a verifier that writes rejects the audit"
  else show "$v"; bad "$v" "rc $RC, $(writes) write(s), want 3 and 0"; fi
  done_case
done

setup V8   # off: no verifier call
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_HIGH" > "$WORK/review.txt"
run_audit
if [ "$RC" = 0 ] && [ "$(verify_calls)" = 0 ] && [ "$(creates)" = 1 ]; then ok V8 "off: no verifier call"
else show V8; bad V8 "off: rc $RC, $(verify_calls) verifier call(s), want 0 and 0"; fi
done_case
setup V9   # a scanner row is not verified, and keeps its pickup label
cat > "$BIN/gitleaks-mock" <<'SH'
#!/usr/bin/env bash
r=""
while [ $# -gt 0 ]; do [ "$1" = --report-path ] && r="$2"; shift; done
echo '[{"File":"config/app.php","StartLine":3,"RuleID":"generic-api-key","Description":"Generic API Key","Commit":"abcdef1234567890"}]' > "$r"
exit 99
SH
chmod +x "$BIN/gitleaks-mock"
GITLEAKS="$BIN/gitleaks-mock" AUDIT_ENV="$VON" run_audit
if [ "$RC" = 0 ] && [ "$(verify_calls)" = 0 ] && [ "$(creates)" = 1 ] && ! grep -q 'Tarkistus:' "$WORK/created/100.body"; then
  ok V9 "scanner rows pass unverified"
else show V9; bad V9 "rc $RC, $(verify_calls) verifier call(s), $(creates) issue(s)"; fi
done_case

setup V10  # --dry-run marks the unsure plan and writes nothing
printf '%s\nMERGE_GATE_RESULT: FINDINGS\n' "$F_HIGH" > "$WORK/review.txt"
printf 'VERIFY_RESULT: UNSURE\n' > "$WORK/verify/xss.txt"
AUDIT_ENV="$VON" run_audit --dry-run
if [ "$RC" = 0 ] && [ "$(writes)" = 0 ] && grep -q '^create \[security\] \[unsure\]' <<<"$OUT"; then ok V10 "dry run shows the unsure plan"
else show V10; bad V10 "rc $RC, $(writes) write(s), plan not '[security] [unsure]'"; fi
done_case
[ "$FAIL" = "$F0" ] && ok V "finding verification"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "security-audit: all passed" || echo "security-audit: FAILURES"
[ "$FAIL" -eq 0 ]
