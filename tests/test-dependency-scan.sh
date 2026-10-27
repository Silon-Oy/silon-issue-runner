#!/usr/bin/env bash
# test-dependency-scan.sh — dependency-scan.sh end to end (issue #382): the
# security audit's scanners with no agent call. The agent CLI is a counting stub
# set explicitly through RUN_ISSUES_CLAUDE_CMD (CLAUDE.md §5.5) — it must never
# run. gh is a PATH shim that records every call; a git shim routes `fetch` of
# the github.com remote to a local bare repo — no network. osv-scanner is a shim.
#
#   A) no scanner installed     -> exit 7, the summary is not clean, no write
#   B) osv-scanner finding      -> one issue with the `security` label, the
#                                  security audit's fingerprint; a second run
#                                  files nothing new
#   C) severity threshold       -> a high finding gets the pickup label, a
#                                  medium one does not
#   D) assignee routing (#374)  -> the watchlist route reaches the issue
#   E) no agent call in any case above
#
# Run: bash tests/test-dependency-scan.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Hermetic: never source this machine's real env file (CLAUDE.md §5.5, #358).
export RUN_ISSUES_ENV_FILE="$HERE/.no-such-machine-env"
SCAN="$HERE/../dependency-scan.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available"
  exit 0
fi

FAIL=0
bad() { echo "FAIL $1: $2"; FAIL=1; }
ok()  { echo "PASS $1: $2"; }

REAL_GIT=$(command -v git)
AGENT_CALLS_TOTAL=0

# setup <name> [<osv-severity>] — origin (bare) + clone whose origin is a
# github.com URL, gh / git / agent shims, and an osv-scanner shim reporting one
# vulnerability of the given CVSS score (none when omitted).
setup() {
  WORK=$(mktemp -d -t depscan-"$1".XXXXXX)
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
    echo '{}' > package-lock.json
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

  # The gh shim keeps created issues in issues.json, so a second run sees them
  # in the index exactly as GitHub would list them.
  echo '[]' > "$WORK/issues.json"
  : > "$WORK/gh.log"; echo 100 > "$WORK/next"
  mkdir -p "$WORK/created"
  cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/gh.log"
[ "\$1" = api ] || exit 0
case "\$*" in
  *--paginate*) cat "$WORK/issues.json"; exit 0 ;;
  *"--method POST repos/Silon-Oy/app/issues -f"*)
    n=\$(cat "$WORK/next"); echo \$((n + 1)) > "$WORK/next"
    body=""; title=""
    for a in "\$@"; do
      case "\$a" in
        body=*)  body="\${a#body=}"; printf '%s' "\$body" > "$WORK/created/\$n.body" ;;
        title=*) title="\${a#title=}" ;;
        labels\[\]=*) printf '%s\n' "\${a#labels[]=}" >> "$WORK/created/\$n.labels" ;;
        assignees\[\]=*) printf '%s\n' "\${a#assignees[]=}" >> "$WORK/created/\$n.assignees" ;;
      esac
    done
    jq --argjson n "\$n" --arg b "\$body" --arg t "\$title" \
      '. + [{number:\$n, state:"open", state_reason:null, title:\$t, body:\$b}]' \
      "$WORK/issues.json" > "$WORK/issues.tmp" && mv "$WORK/issues.tmp" "$WORK/issues.json"
    if [ -f "$WORK/created/\$n.assignees" ]; then
      printf '{"number":%s,"assignees":[{"login":"%s"}]}\n' "\$n" "\$(head -1 "$WORK/created/\$n.assignees")"
    else
      printf '{"number":%s,"assignees":[]}\n' "\$n"
    fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$BIN/gh"

  : > "$WORK/calls.log"
  cat > "$BIN/claude-mock" <<SH
#!/usr/bin/env bash
echo AGENT >> "$WORK/calls.log"
echo 'MERGE_GATE_RESULT: CLEAN'
SH
  chmod +x "$BIN/claude-mock"

  OSV="$WORK/no-osv"
  if [ -n "${2:-}" ]; then
    OSV="$BIN/osv-mock"
    cat > "$OSV" <<SH
#!/usr/bin/env bash
echo SCAN >> "$WORK/scans.log"
r=""
while [ \$# -gt 0 ]; do [ "\$1" = -r ] && r="\$2"; shift; done
cat <<JSON
{"results":[{"source":{"path":"\$r/package-lock.json"},"packages":[{"package":{"name":"lodash","version":"4.17.20","ecosystem":"npm"},
 "vulnerabilities":[{"id":"GHSA-xxxx-yyyy-zzzz","summary":"Prototype pollution"}],
 "groups":[{"ids":["GHSA-xxxx-yyyy-zzzz"],"max_severity":"$2"}]}]}]}
JSON
exit 1
SH
    chmod +x "$OSV"
  fi
}

# run_scan [args...] — sets RC, OUT. The agent stub is set explicitly: should
# the scan ever call the agent, the call is counted, never billed.
run_scan() {
  set +e
  OUT=$( env PATH="$BIN:$PATH" HOME="$HOME" \
    RUN_ISSUES_CLAUDE_CMD="$BIN/claude-mock" \
    RUN_ISSUES_WATCHLIST="${WL:-$WORK/no-watchlist.json}" \
    RUN_ISSUES_GITLEAKS_BIN="$WORK/no-gitleaks" RUN_ISSUES_OSV_SCANNER_BIN="$OSV" \
    "$SCAN" "$REPO" "$@" 2>&1 )
  RC=$?
}

writes() { grep -c -- '--method' "$WORK/gh.log" 2>/dev/null || true; }
creates() { find "$WORK/created" -name '*.body' | wc -l | tr -d ' '; }
agent_calls() { grep -c AGENT "$WORK/calls.log" 2>/dev/null || true; }
show() { echo "$OUT" | sed "s/^/$1| /"; echo "$1| (rc=$RC)"; }
done_case() {
  AGENT_CALLS_TOTAL=$((AGENT_CALLS_TOTAL + $(agent_calls)))
  [ -n "${KEEP:-}" ] || rm -rf "$WORK"
}

# ===========================================================================
echo "=== A: no scanner installed ==="
F0=$FAIL; setup A
run_scan
[ "$RC" = 7 ] || { show A; bad A "rc $RC, want 7"; }
grep -q 'NOT CHECKED: no scanner installed' <<<"$OUT" || bad A "the summary does not say nothing was checked"
grep -q 'nothing was checked (not a clean result)' <<<"$OUT" || bad A "no diagnostic"
[ "$(writes)" = 0 ] || bad A "$(writes) write call(s), want 0"
[ "$FAIL" = "$F0" ] && ok A "no scanner: exit 7, not clean"
done_case

# ===========================================================================
echo "=== B: finding -> one issue, no duplicate on the next run ==="
F0=$FAIL; setup B 7.5
run_scan
[ "$RC" = 0 ] || { show B; bad B "rc $RC, want 0"; }
[ "$(creates)" = 1 ] || bad B "created $(creates) issues, want 1"
grep -qx security "$WORK/created/100.labels" 2>/dev/null || bad B "security label missing"
FP=$( . "$HERE/../lib/finding-issues.sh"; finding_fingerprint osv-scanner package-lock.json "lodash GHSA-xxxx-yyyy-zzzz" )
grep -qF "<!-- run-issues:finding kind=security fp=$FP -->" "$WORK/created/100.body" 2>/dev/null \
  || bad B "the security audit's fingerprint is missing"
grep -q '(scanners only)' <<<"$OUT" || bad B "the summary does not name the mode"
run_scan
[ "$RC" = 0 ] || { show B; bad B "second run rc $RC, want 0"; }
[ "$(creates)" = 1 ] || bad B "second run created a duplicate ($(creates) issues)"
grep -q '^exists #100' <<<"$OUT" || { show B; bad B "second run does not name the existing issue"; }
[ "$(grep -c SCAN "$WORK/scans.log")" = 2 ] || bad B "the scanner did not run on both runs"
[ "$FAIL" = "$F0" ] && ok B "finding filed once"
done_case

# ===========================================================================
echo "=== C: severity threshold ==="
F0=$FAIL; setup C1 7.5
run_scan
grep -qx auto-run "$WORK/created/100.labels" 2>/dev/null || bad C1 "a high finding lacks the default pickup label"
done_case
setup C2 5.0
run_scan
[ "$RC" = 0 ] && [ "$(creates)" = 1 ] || bad C2 "rc $RC, $(creates) issues"
grep -qx auto-run "$WORK/created/100.labels" 2>/dev/null && bad C2 "a medium finding got the pickup label"
done_case
[ "$FAIL" = "$F0" ] && ok C "the security audit's auto-run threshold applies"

# ===========================================================================
echo "=== D: assignee routing (#374) ==="
F0=$FAIL; setup D 9.8
jq -n --arg p "$REPO" '{repos: [{path: $p, labels: ["auto-run"], assignees: ["runner-a"]}]}' > "$WORK/wl.json"
WL="$WORK/wl.json" run_scan
[ "$RC" = 0 ] || { show D; bad D "rc $RC, want 0"; }
[ "$(cat "$WORK/created/100.assignees" 2>/dev/null)" = runner-a ] || bad D "issue not routed to runner-a"
[ "$FAIL" = "$F0" ] && ok D "routed like the security audit"
done_case

# ===========================================================================
echo "=== E: no agent call ==="
[ "$AGENT_CALLS_TOTAL" = 0 ] && ok E "no agent call in any case" || bad E "$AGENT_CALLS_TOTAL agent call(s), want 0"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "dependency-scan: all passed" || echo "dependency-scan: FAILURES"
[ "$FAIL" -eq 0 ]
