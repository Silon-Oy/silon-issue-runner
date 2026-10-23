#!/usr/bin/env bash
# test-security-scan.sh — lib/security-scan.sh (issue #336): optional
# deterministic scanners. Both scanners are shims in a temp dir, selected through
# RUN_ISSUES_GITLEAKS_BIN / RUN_ISSUES_OSV_SCANNER_BIN — nothing needs to be
# installed, and a real scanner on the machine is never run.
#
#   1  missing scanners      -> "ei asennettu" summary rows, no findings, no failure
#   2  gitleaks leak         -> high row with rule + location, the secret's
#                               value appears in no output file
#   3  gitleaks diff mode    -> base-ref..HEAD range, config pinned to the base
#   4  gitleaks crash/garbage-> scan.failed + summary row, gate row `low`
#   5  osv severity map      -> CVSS 9.8 critical, 7.5 high, 5 medium, 2 low,
#                               no score -> advisory rating / medium
#   6  osv diff mode         -> only changed lockfiles, only vulns the base lacked
#   7  osv crash             -> failed, not clean
#   8  audit mode            -> no base-ref; gitleaks without --log-opts, osv -r
#   9  tamper signals        -> head edits .gitleaksignore / adds gitleaks:allow
#  10  usage errors          -> unknown mode, diff without base-ref: rc 1
#  11  gate rows             -> no out-dir => one failure row; prompt text
#
# Run: bash tests/test-security-scan.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib/security-scan.sh"

for c in git jq; do
  if ! command -v "$c" >/dev/null 2>&1; then
    echo "SKIP: $c not available"
    exit 0
  fi
done

# shellcheck source=../lib/security-scan.sh
. "$LIB"
# shellcheck source=../lib/merge-gate.sh
. "$HERE/../lib/merge-gate.sh"

FAIL=0
WORK=$(mktemp -d -t security-scan.XXXXXX)
trap '[ -n "${KEEP:-}" ] || rm -rf "$WORK"' EXIT

check() { # <name> <want> <got>
  if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 — want '$2', got '$3'"; FAIL=1; fi
}
yes_() { # <name> <command...>
  local n="$1"; shift
  if "$@"; then echo "PASS: $n"; else echo "FAIL: $n"; FAIL=1; fi
}
no_() {
  local n="$1"; shift
  if "$@"; then echo "FAIL: $n"; FAIL=1; else echo "PASS: $n"; fi
}
has() { printf '%s\n' "$2" | grep -q -- "$1"; }   # <pattern> <text>

SECRET="AKIAZZSUPERSECRETVALUE123"
BIN="$WORK/bin"; mkdir -p "$BIN"

# gitleaks shim: behaviour from $WORK/gitleaks.mode (clean|leak|crash|garbage);
# arguments logged one per line to $WORK/gitleaks.args.
cat > "$BIN/gitleaks" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$WORK/gitleaks.args"
report="" code=1
while [ \$# -gt 0 ]; do
  case "\$1" in
    --report-path) report="\$2"; shift ;;
    --exit-code) code="\$2"; shift ;;
    --config) cp "\$2" "$WORK/gitleaks.config-seen" ;;
  esac
  shift
done
case "\$(cat "$WORK/gitleaks.mode" 2>/dev/null || echo clean)" in
  clean) echo '[]' > "\$report"; exit 0 ;;
  leak)
    jq -n --arg s "$SECRET" '[{Description:"AWS Access Key",StartLine:3,File:"conf/app.env",
      Commit:"0123456789abcdef0123",RuleID:"aws-access-token",Secret:\$s,Match:("key=" + \$s)}]' > "\$report"
    echo "leaks found: 1" >&2
    exit "\$code" ;;
  crash) echo "fatal: could not read git log" >&2; exit 1 ;;
  garbage) echo 'not json' > "\$report"; exit 0 ;;
esac
SH

# osv-scanner shim: a "lockfile" is lines "<name> <version> <score|-> [<db-severity>]";
# every line is a vulnerable package with id GHSA-<name>-<version>. -r <dir>
# scans every package-lock.json below <dir>. $WORK/osv.mode = crash fails it.
cat > "$BIN/osv-scanner" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/osv.calls"
[ "\$(cat "$WORK/osv.mode" 2>/dev/null)" = crash ] && { echo "network unreachable" >&2; exit 127; }
files=()
while [ \$# -gt 0 ]; do
  case "\$1" in
    -L) files+=("\$2"); shift ;;
    -r) while IFS= read -r f; do files+=("\$f"); done < <(find "\$2" -name package-lock.json -not -path '*/.git/*'); shift ;;
  esac
  shift
done
[ \${#files[@]} -gt 0 ] || { echo "No package sources found" >&2; exit 128; }
found=0
results='[]'
for f in "\${files[@]}"; do
  pk='[]'
  while read -r name ver score db; do
    [ -n "\$name" ] || continue
    found=1
    pk=\$(jq -c --arg n "\$name" --arg v "\$ver" --arg s "\$score" --arg d "\${db:-}" '. + [{
      package:{name:\$n,version:\$v,ecosystem:"npm"},
      vulnerabilities:[{id:("GHSA-" + \$n + "-" + \$v),summary:("bad " + \$n),
        database_specific:(if \$d == "" then {} else {severity:\$d} end)}],
      groups:[{ids:[("GHSA-" + \$n + "-" + \$v)]} + (if \$s == "-" then {} else {max_severity:\$s} end)]}]' <<<"\$pk")
  done < "\$f"
  results=\$(jq -c --arg p "\$f" --argjson pk "\$pk" '. + [{source:{path:\$p,type:"lockfile"},packages:\$pk}]' <<<"\$results")
done
jq -n --argjson r "\$results" '{results:\$r}'
exit \$found
SH
chmod +x "$BIN/gitleaks" "$BIN/osv-scanner"

# A repo with main and a feature branch; REMOTE-less, so base-ref is "main".
REPO="$WORK/repo"
git init -q "$REPO"
(
  cd "$REPO"
  git symbolic-ref HEAD refs/heads/main
  git config user.email t@t.t; git config user.name t
  printf 'left-pad 1.0.0 9.8\nold-dep 2.0.0 7.5\n' > package-lock.json
  echo base > README
  git add .; git commit -qm init
  git checkout -q -b feature
  printf 'left-pad 1.0.0 9.8\nold-dep 2.0.0 7.5\nnew-crit 1.0.0 9.8\nnew-high 1.0.0 7.5\nnew-med 1.0.0 5.0\nnew-low 1.0.0 2.0\nnew-noscore 1.0.0 -\nnew-db 1.0.0 - HIGH\n' > package-lock.json
  echo feature > README
  git commit -qam feature
)

with_bins() { RUN_ISSUES_GITLEAKS_BIN="$BIN/gitleaks" RUN_ISSUES_OSV_SCANNER_BIN="$BIN/osv-scanner" "$@"; }
no_bins()   { RUN_ISSUES_GITLEAKS_BIN="$WORK/none/gitleaks" RUN_ISSUES_OSV_SCANNER_BIN="$WORK/none/osv-scanner" "$@"; }
status_clean() { [ -z "$(git -C "$REPO" status --porcelain)" ]; }

# --- 1 ------------------------------------------------------------------------
echo "=== 1: missing scanners ==="
O="$WORK/o1"
rc=0; no_bins security_scan diff "$REPO" "$O" main || rc=$?
check "1 rc" 0 "$rc"
yes_ "1 gitleaks not installed" grep -q '^gitleaks: ei asennettu' "$O/scan.summary"
yes_ "1 osv not installed" grep -q '^osv-scanner: ei asennettu' "$O/scan.summary"
check "1 no findings" "" "$(cat "$O/scan.findings")"
check "1 no failures" "" "$(cat "$O/scan.failed")"
check "1 no gate rows" "" "$(security_scan_gate_findings "$O")"
yes_ "1 worktree untouched" status_clean

# --- 2 + 3 --------------------------------------------------------------------
echo "=== 2/3: gitleaks leak in diff mode ==="
echo leak > "$WORK/gitleaks.mode"
O="$WORK/o2"
rc=0; RUN_ISSUES_OSV_SCANNER_BIN="$WORK/none" RUN_ISSUES_GITLEAKS_BIN="$BIN/gitleaks" security_scan diff "$REPO" "$O" main || rc=$?
check "2 rc" 0 "$rc"
row=$(grep '^high|high|conf/app.env:3|gitleaks: aws-access-token' "$O/scan.findings" || true)
yes_ "2 leak is a high row with rule and location" test -n "$row"
no_ "2 secret value in no output file" grep -rqF "$SECRET" "$O/scan.findings" "$O/scan.summary" "$O/scan.failed"
no_ "2 secret value not in the prompt text" has "$SECRET" "$(security_scan_prompt_text "$O")"
yes_ "2 summary counts the leak" grep -q '^gitleaks: OK, 1 löydöstä' "$O/scan.summary"
printf 'FINDING: %s\n' "$(sed 's/|/ | /g' "$O/scan.findings")" > "$WORK/as-gate.out"
check "2 row is valid merge-gate form" "$(cat "$O/scan.findings")" "$(merge_gate_findings "$WORK/as-gate.out")"
yes_ "3 range base..HEAD" grep -qx 'main..HEAD' "$WORK/gitleaks.args"
yes_ "3 --redact passed" grep -qx -- '--redact' "$WORK/gitleaks.args"
yes_ "3 config pinned (default when the base has none)" grep -q 'useDefault = true' "$WORK/gitleaks.config-seen"
yes_ "2 worktree untouched" status_clean

# --- 4 ------------------------------------------------------------------------
echo "=== 4: gitleaks fails ==="
for m in crash garbage; do
  echo "$m" > "$WORK/gitleaks.mode"
  O="$WORK/o4-$m"
  RUN_ISSUES_OSV_SCANNER_BIN="$WORK/none" RUN_ISSUES_GITLEAKS_BIN="$BIN/gitleaks" security_scan diff "$REPO" "$O" main
  yes_ "4 $m recorded as failed" grep -q '^gitleaks|' "$O/scan.failed"
  yes_ "4 $m summary says FAILED" grep -q '^gitleaks: EPÄONNISTUI (rc=' "$O/scan.summary"
  yes_ "4 $m gate row is low|high" has '^low|high|gitleaks|skanneri gitleaks epäonnistui' "$(security_scan_gate_findings "$O")"
done
yes_ "4 crash excerpt carries stderr" grep -q 'could not read git log' "$WORK/o4-crash/scan.summary"
echo clean > "$WORK/gitleaks.mode"

# --- 5 + 6 --------------------------------------------------------------------
echo "=== 5/6: osv-scanner diff mode ==="
O="$WORK/o5"
: > "$WORK/osv.calls"
RUN_ISSUES_GITLEAKS_BIN="$WORK/none" RUN_ISSUES_OSV_SCANNER_BIN="$BIN/osv-scanner" security_scan diff "$REPO" "$O" main
sev_of() { grep "osv-scanner: $1@" "$O/scan.findings" | cut -d'|' -f1; }
check "5 9.8 -> critical" critical "$(sev_of new-crit)"
check "5 7.5 -> high" high "$(sev_of new-high)"
check "5 5.0 -> medium" medium "$(sev_of new-med)"
check "5 2.0 -> low" low "$(sev_of new-low)"
check "5 no score -> medium" medium "$(sev_of new-noscore)"
check "5 no score, advisory HIGH -> high" high "$(sev_of new-db)"
check "6 base vulns dropped" "" "$(grep -E 'left-pad|old-dep' "$O/scan.findings")"
check "6 location is the repo-relative lockfile" "package-lock.json" "$(grep 'new-crit@' "$O/scan.findings" | cut -d'|' -f3)"
check "6 two osv calls (head + base)" 2 "$(grep -c . "$WORK/osv.calls")"
yes_ "6 config pinned" grep -q -- '--config' "$WORK/osv.calls"
yes_ "6 worktree untouched" status_clean
printf 'FINDING: %s\n' "$(sed 's/|/ | /g' "$O/scan.findings")" > "$WORK/as-gate.out"
yes_ "5 rows are valid merge-gate form" merge_gate_findings "$WORK/as-gate.out" >/dev/null

echo "=== 6b: diff without lockfile changes ==="
( cd "$REPO" && git checkout -q -b feature2 main && echo x > README && git commit -qam readme )
O="$WORK/o6b"; : > "$WORK/osv.calls"
RUN_ISSUES_GITLEAKS_BIN="$WORK/none" RUN_ISSUES_OSV_SCANNER_BIN="$BIN/osv-scanner" security_scan diff "$REPO" "$O" main
check "6b osv not called" 0 "$(grep -c . "$WORK/osv.calls")"
yes_ "6b summary says no lockfile change" grep -q '^osv-scanner: OK, 0 löydöstä (diff ei muuta lukkotiedostoja)' "$O/scan.summary"
( cd "$REPO" && git checkout -q feature )

# --- 7 ------------------------------------------------------------------------
echo "=== 7: osv-scanner fails ==="
echo crash > "$WORK/osv.mode"
O="$WORK/o7"
RUN_ISSUES_GITLEAKS_BIN="$WORK/none" RUN_ISSUES_OSV_SCANNER_BIN="$BIN/osv-scanner" security_scan diff "$REPO" "$O" main
yes_ "7 failed" grep -q '^osv-scanner|127|network unreachable' "$O/scan.failed"
check "7 no partial findings" "" "$(cat "$O/scan.findings")"
yes_ "7 gate row" has '^low|high|osv-scanner|' "$(security_scan_gate_findings "$O")"
rm -f "$WORK/osv.mode"

# --- 8 ------------------------------------------------------------------------
echo "=== 8: audit mode ==="
O="$WORK/o8"; : > "$WORK/osv.calls"
rc=0; with_bins security_scan audit "$REPO" "$O" || rc=$?
check "8 rc" 0 "$rc"
no_ "8 gitleaks without --log-opts" grep -qx -- '--log-opts' "$WORK/gitleaks.args"
yes_ "8 osv recursive" grep -q -- "-r $REPO" "$WORK/osv.calls"
yes_ "8 base vulns reported in audit" grep -q 'left-pad@1.0.0' "$O/scan.findings"
check "8 audit location repo-relative" "package-lock.json" "$(grep 'left-pad@' "$O/scan.findings" | cut -d'|' -f3)"
yes_ "8 both scanners OK" sh -c "grep -q '^gitleaks: OK' '$O/scan.summary' && grep -q '^osv-scanner: OK' '$O/scan.summary'"

# --- 9 ------------------------------------------------------------------------
echo "=== 9: tamper signals ==="
( cd "$REPO" && git checkout -q -b feature3 main && echo 'abc:conf/app.env:aws:3' > .gitleaksignore \
  && printf 'token = "x" # gitleaks:allow\n' > a.py && git add . && git commit -qm tamper )
O="$WORK/o9"
RUN_ISSUES_OSV_SCANNER_BIN="$WORK/none" RUN_ISSUES_GITLEAKS_BIN="$BIN/gitleaks" security_scan diff "$REPO" "$O" main
yes_ "9 ignore-file change is high" grep -q '^high|medium|.gitleaksignore|' "$O/scan.findings"
yes_ "9 gitleaks:allow is high with line" grep -q '^high|medium|a.py:1|' "$O/scan.findings"
yes_ "9 ignore file came from the base (none)" sh -c "! grep -rqs abc '$O/gitleaks-base-ignore'"
( cd "$REPO" && git checkout -q feature )

# --- 10 -----------------------------------------------------------------------
echo "=== 10: usage errors ==="
rc=0; security_scan bogus "$REPO" "$WORK/o10" 2>/dev/null || rc=$?; check "10 unknown mode" 1 "$rc"
rc=0; security_scan diff "$REPO" "$WORK/o10" 2>/dev/null || rc=$?; check "10 diff without base" 1 "$rc"
rc=0; security_scan diff "$REPO" "$WORK/o10" no-such-ref 2>/dev/null || rc=$?; check "10 unresolvable base" 1 "$rc"
rc=0; security_scan audit "$WORK/not-a-repo" "$WORK/o10" 2>/dev/null || rc=$?; check "10 not a repo" 1 "$rc"

# --- 11 -----------------------------------------------------------------------
echo "=== 11: gate rows and prompt text ==="
yes_ "11 scan that never ran is a failure row" has '^low|high|security-scan|' "$(security_scan_gate_findings "$WORK/never-ran")"
yes_ "11 prompt text lists the summary" has 'gitleaks: ei asennettu' "$(security_scan_prompt_text "$WORK/o1")"
yes_ "11 prompt text lists findings" has 'critical | high | package-lock.json' "$(security_scan_prompt_text "$WORK/o5")"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "security-scan: all passed" || echo "security-scan: FAILURES"
[ "$FAIL" -eq 0 ]
