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
#   F) one package version, three advisories in two groups (#397) -> one issue:
#                                  every id, the worst severity, the lowest
#                                  version fixing all, the merge label
#   G) a new advisory of the same version -> the open issue is updated, no new one
#   H) an upgraded version      -> the old version's closed issue is not reopened,
#                                  the new version's advisory is a new issue
#   I) per-advisory issues of before #397 -> closed with a comment naming the
#                                  package issue; a dry run only prints it
#   J) merge policy             -> off in the repo / the watchlist / poller.env:
#                                  no merge label; below the auto-run threshold:
#                                  none either; PR_WATCH_MERGE_LABEL is the label
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
  *"--method PATCH repos/Silon-Oy/app/issues/"*)
    n=\${4##*/}
    upd='.'
    for a in "\$@"; do
      case "\$a" in
        body=*) printf '%s' "\${a#body=}" > "$WORK/patched-body"
                upd="\$upd"' | (.[] | select(.number == \$n) | .body) = \$b' ;;
        state=*) upd="\$upd"' | (.[] | select(.number == \$n) | .state) = '"\"\${a#state=}\"" ;;
        state_reason=*) upd="\$upd"' | (.[] | select(.number == \$n) | .state_reason) = '"\"\${a#state_reason=}\"" ;;
      esac
    done
    jq --argjson n "\$n" --rawfile b "$WORK/patched-body" "\$upd" "$WORK/issues.json" > "$WORK/issues.tmp" \
      && mv "$WORK/issues.tmp" "$WORK/issues.json"
    echo '{"assignees":[]}'
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$BIN/gh"
  : > "$WORK/patched-body"

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
# A case's own report (osv.json, @R@ = the scanned root) wins over the default.
if [ -f "$WORK/osv.json" ]; then sed "s#@R@#\$r#g" "$WORK/osv.json"; exit 1; fi
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
    RUN_ISSUES_POLLER_ENV_FILE="$WORK/poller.env" \
    ${SCAN_ENV:-} "$SCAN" "$REPO" "$@" 2>&1 )
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
FP=$( . "$HERE/../lib/finding-issues.sh"; finding_fingerprint osv-scanner-pkg npm/lodash@4.17.20 npm/lodash@4.17.20 )
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

# osv_report <version> <ids...> — an osv-scanner report of fast-uri@<version> in
# package-lock.json: one group per argument (`GHSA-a+CVE-1` is one group of two
# aliases), severities 7.5, 9.1, 5.0, … in turn, each fixed in <version>.<n+1>.
osv_report() {
  local ver="$1" g i=0 vulns="" groups="" scores=(7.5 9.1 5.0 5.0 5.0) id
  shift
  for g in "$@"; do
    i=$((i + 1))
    for id in $(printf '%s' "$g" | tr '+' ' '); do
      vulns="$vulns${vulns:+,}{\"id\":\"$id\",\"summary\":\"issue $id\",\"affected\":[{\"package\":{\"name\":\"fast-uri\",\"ecosystem\":\"npm\"},\"ranges\":[{\"events\":[{\"introduced\":\"0\"},{\"fixed\":\"$ver.$i\"}]}]}]}"
    done
    groups="$groups${groups:+,}{\"ids\":$(printf '%s' "$g" | jq -R 'split("+")'),\"max_severity\":\"${scores[$((i - 1))]}\"}"
  done
  printf '{"results":[{"source":{"path":"@R@/package-lock.json"},"packages":[{"package":{"name":"fast-uri","version":"%s","ecosystem":"npm"},"vulnerabilities":[%s],"groups":[%s]}]}]}\n' \
    "$ver" "$vulns" "$groups" > "$WORK/osv.json"
}
labels_of() { tr '\n' ',' < "$WORK/created/$1.labels" 2>/dev/null; }
state_of() { jq -r --argjson n "$1" '.[] | select(.number == $n) | .state + "/" + (.state_reason // "")' "$WORK/issues.json"; }
fp_pkg() { ( . "$HERE/../lib/finding-issues.sh"; finding_fingerprint osv-scanner-pkg "$1" "$1" ); }

# ===========================================================================
echo "=== F: one package version, three advisories -> one issue ==="
F0=$FAIL; setup F 1
osv_report 3.1 "GHSA-a+CVE-1" "GHSA-b"
run_scan
[ "$RC" = 0 ] || { show F; bad F "rc $RC, want 0"; }
[ "$(creates)" = 1 ] || bad F "created $(creates) issues, want 1"
B="$WORK/created/100.body"
for id in GHSA-a CVE-1 GHSA-b; do grep -q "$id" "$B" 2>/dev/null || bad F "body lacks $id"; done
grep -q '^- \*\*Vakavuus:\*\* critical' "$B" || bad F "severity is not the worst advisory's"
grep -q 'Pienin kaikki korjaava versio:\*\* `3.1.2`' "$B" || bad F "the lowest version fixing all is not 3.1.2"
grep -q 'vähintään versioon `3.1.2`' "$B" || bad F "the acceptance criterion does not name 3.1.2"
grep -qF "<!-- run-issues:finding kind=security fp=$(fp_pkg npm/fast-uri@3.1) -->" "$B" || bad F "package version fingerprint missing"
grep -qF "<!-- run-issues:finding-ids fp=$(fp_pkg npm/fast-uri@3.1) ids=GHSA-a,CVE-1,GHSA-b -->" "$B" || bad F "ids marker missing"
grep -q 'päivitä riippuvuus npm/fast-uri@3.1 (3 tunnistetta)' "$WORK/created/100.title" 2>/dev/null \
  || grep -q 'title=Tietoturva (critical): päivitä riippuvuus npm/fast-uri@3.1 (3 tunnistetta)' "$WORK/gh.log" || bad F "title"
[ "$(labels_of 100)" = "security,auto-run,auto-merge," ] || bad F "labels '$(labels_of 100)', want security,auto-run,auto-merge"
[ "$FAIL" = "$F0" ] && ok F "one issue per package version, with the merge label"

# ===========================================================================
echo "=== G: a new advisory of the same version -> update ==="
F0=$FAIL
osv_report 3.1 "GHSA-a+CVE-1" "GHSA-b" "GHSA-c"
: > "$WORK/gh.log"
run_scan
[ "$RC" = 0 ] || { show G; bad G "rc $RC, want 0"; }
[ "$(creates)" = 1 ] || bad G "a new issue was created ($(creates))"
grep -q '^updated #100' <<<"$OUT" || { show G; bad G "the open issue was not updated"; }
grep -q 'ids=GHSA-a,CVE-1,GHSA-b,GHSA-c' "$WORK/patched-body" || bad G "the new body does not list the new id"
grep -q 'issues/100/comments -f body=.*uusia tunnisteita: GHSA-c\.' "$WORK/gh.log" || bad G "no comment naming the new id"
grep -q 'Pienin kaikki korjaava versio:\*\* `3.1.3`' "$WORK/patched-body" || bad G "the fix version did not follow the new advisory"
run_scan
grep -q '^exists #100' <<<"$OUT" || { show G; bad G "a third run does not see the update"; }
[ "$FAIL" = "$F0" ] && ok G "new advisory updates the open issue"

# ===========================================================================
echo "=== H: upgraded version -> no reopen, new issue ==="
F0=$FAIL
jq '(.[] | select(.number == 100)) |= (.state = "closed" | .state_reason = "completed")' "$WORK/issues.json" > "$WORK/i.tmp" \
  && mv "$WORK/i.tmp" "$WORK/issues.json"
osv_report 3.2 "GHSA-d"
: > "$WORK/gh.log"
run_scan
[ "$RC" = 0 ] || { show H; bad H "rc $RC, want 0"; }
grep -q 'issues/100 -f state=open' "$WORK/gh.log" && bad H "the old version's issue was reopened"
[ "$(state_of 100)" = "closed/completed" ] || bad H "old issue state $(state_of 100)"
[ "$(creates)" = 2 ] || bad H "$(creates) issues, want 2 (the new version's own)"
grep -q 'ids=GHSA-d ' "$WORK/created/101.body" 2>/dev/null || grep -q 'ids=GHSA-d -->' "$WORK/created/101.body" || bad H "new issue lacks the new advisory"
[ "$FAIL" = "$F0" ] && ok H "upgrade: no reopen, new version is a new issue"
done_case

# ===========================================================================
echo "=== I: per-advisory issues of before #397 are superseded ==="
F0=$FAIL; setup I 1
osv_report 3.1 "GHSA-a+CVE-1" "GHSA-b"
OLD_A=$( . "$HERE/../lib/finding-issues.sh"; finding_fingerprint osv-scanner package-lock.json "fast-uri GHSA-a,CVE-1" )
OLD_B=$( . "$HERE/../lib/finding-issues.sh"; finding_fingerprint osv-scanner package-lock.json "fast-uri GHSA-b" )
jq -n --arg a "$OLD_A" --arg b "$OLD_B" '[
  {number:10, state:"open", state_reason:null, title:"a", body:("x\n<!-- run-issues:finding kind=security fp=" + $a + " -->")},
  {number:11, state:"open", state_reason:null, title:"b", body:("x\n<!-- run-issues:finding kind=security fp=" + $b + " -->")}]' > "$WORK/issues.json"
run_scan --dry-run
[ "$RC" = 0 ] || { show I; bad I "dry run rc $RC"; }
grep -q '^supersede #10 → (uusi)' <<<"$OUT" || { show I; bad I "dry run does not plan the supersede of #10"; }
grep -q '^supersede #11 → (uusi)' <<<"$OUT" || bad I "dry run does not plan the supersede of #11"
[ "$(writes)" = 0 ] || bad I "dry run wrote ($(writes))"
run_scan
[ "$RC" = 0 ] || { show I; bad I "rc $RC, want 0"; }
[ "$(creates)" = 1 ] || bad I "created $(creates), want 1"
for n in 10 11; do
  [ "$(state_of $n)" = "closed/completed" ] || bad I "#$n is $(state_of $n), want closed/completed"
  grep -q "issues/$n/comments -f body=.*issueen #100" "$WORK/gh.log" || bad I "#$n has no comment naming #100"
done
grep -q '^superseded #10 → #100' <<<"$OUT" || { show I; bad I "output does not report the supersede"; }
: > "$WORK/gh.log"
run_scan
[ "$(writes)" = 0 ] || bad I "a second run wrote again ($(writes))"
[ "$FAIL" = "$F0" ] && ok I "old per-advisory issues closed with a reference"
done_case

# Supersede into an EXISTING package issue: it is named, nothing new is created.
F0=$FAIL; setup I2 1
osv_report 3.1 "GHSA-b"
run_scan
OLD_B=$( . "$HERE/../lib/finding-issues.sh"; finding_fingerprint osv-scanner package-lock.json "fast-uri GHSA-b" )
jq --arg b "$OLD_B" '. + [{number:11, state:"open", state_reason:null, title:"b", body:("<!-- run-issues:finding kind=security fp=" + $b + " -->")}]' \
  "$WORK/issues.json" > "$WORK/i.tmp" && mv "$WORK/i.tmp" "$WORK/issues.json"
run_scan
grep -q '^superseded #11 → #100' <<<"$OUT" || { show I2; bad I2 "not superseded into the existing #100"; }
[ "$(creates)" = 1 ] || bad I2 "$(creates) issues, want 1"
[ "$FAIL" = "$F0" ] && ok I2 "superseded into the existing package issue"
done_case

# ===========================================================================
echo "=== J: merge policy ==="
F0=$FAIL
setup J1 1; osv_report 3.1 "GHSA-b"
( cd "$REPO" && mkdir -p .claude && echo '{"security":{"dependency_auto_merge":false}}' > .claude/run-issues.json \
  && git add . && git commit -qm cfg && git push -q "$ORIGIN" main )
run_scan
[ "$(labels_of 100)" = "security,auto-run," ] || bad J1 "repo off: labels '$(labels_of 100)'"
done_case
setup J2 1; osv_report 3.1 "GHSA-b"
jq -n --arg p "$REPO" '{repos: [{path: $p, labels: ["auto-run"], security_dependency_auto_merge: false}]}' > "$WORK/wl.json"
WL="$WORK/wl.json" run_scan
[ "$(labels_of 100)" = "security,auto-run," ] || bad J2 "watchlist off: labels '$(labels_of 100)'"
done_case
setup J3 1; osv_report 3.1 "GHSA-b"
printf 'RUN_ISSUES_SECURITY_AUDIT_DEPENDENCY_AUTO_MERGE=false\nPR_WATCH_MERGE_LABEL=ship-it\n' > "$WORK/poller.env"
run_scan
[ "$(labels_of 100)" = "security,auto-run," ] || bad J3 "poller.env off: labels '$(labels_of 100)'"
done_case
setup J4 1; osv_report 3.1 "GHSA-b"
printf 'PR_WATCH_MERGE_LABEL=ship-it\n' > "$WORK/poller.env"
run_scan
[ "$(labels_of 100)" = "security,auto-run,ship-it," ] || bad J4 "merge label not resolved: '$(labels_of 100)'"
done_case
setup J5 1; osv_report 3.1 "GHSA-c+GHSA-x"
# Only a medium group: below the default auto-run threshold.
sed -i.bak 's/"max_severity":"7.5"/"max_severity":"5.0"/' "$WORK/osv.json"
run_scan
[ "$(labels_of 100)" = "security," ] || bad J5 "below threshold: labels '$(labels_of 100)'"
done_case
[ "$FAIL" = "$F0" ] && ok J "merge policy: repo, watchlist and poller.env switch it off"

# ===========================================================================
echo "=== E: no agent call ==="
[ "$AGENT_CALLS_TOTAL" = 0 ] && ok E "no agent call in any case" || bad E "$AGENT_CALLS_TOTAL agent call(s), want 0"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "dependency-scan: all passed" || echo "dependency-scan: FAILURES"
[ "$FAIL" -eq 0 ]
