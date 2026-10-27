#!/usr/bin/env bash
# test-dependencies.sh — lib/deps.tsv is the package's ONE dependency list, and
# every consumer must follow it (issue #376).
#
# Before the list, dependencies were written by hand into the S0 gate, the
# installer, README §2 and each runner guide, and nothing compared the copies:
# #336's scanners reached the README and nothing else, so a Sprite ran the merge
# gate without them and no output said so. This test turns each way of drifting
# into a red test.
#
# Cases:
#   1. the list itself: at least 8 rows, anchors `gh` and `gitleaks` present,
#      every row has exactly 7 non-empty tab-separated fields and a known level
#      and scope. Fail-closed: a list that parses to nearly nothing must not make
#      every later case pass vacuously.
#   2. docs/dependencies.md's table (between the deps-table markers) is exactly
#      deps_markdown_table's output — a list change without a regenerated table
#      is red.
#   3. every runner guide (README.md + docs/*-runner.md, derived by glob,
#      fail-closed below three) links docs/dependencies.md or names every
#      dependency in the list.
#   4. code -> list: every key the code passes to preflight_install_hint and
#      every scanner in lib/security-scan.sh's SECURITY_SCANNERS is in the list,
#      and no consumer keeps its own hand-written list any more.
#   5. the guard in case 3 can fail: a temporary list with a new row and a
#      guide that neither links the table nor names the row is reported.
#
# Reads repository files only; writes into its own mktemp tree.
#
# Run: bash tests/test-dependencies.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DEPS_TSV="$ROOT/lib/deps.tsv"
DEPS_MD="$ROOT/docs/dependencies.md"
FAIL=0

ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAIL=1; }

# The real list, whatever the caller's environment says.
unset RUN_ISSUES_DEPS_FILE RUN_ISSUES_DEPS_PLATFORM

# shellcheck source=lib/deps.sh
. "$ROOT/lib/deps.sh"

WORK=$(mktemp -d -t deps.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ---- Case 1: the list is well formed ----
if [ ! -s "$DEPS_TSV" ]; then
  bad "case1 lib/deps.tsv missing or empty"
  echo "----------------------------------------"
  echo "dependencies: FAILURES"
  exit 1
fi

names="$(deps_names)"
count=$(printf '%s\n' "$names" | grep -c .)
if [ "$count" -ge 8 ]; then
  ok "case1 the list has $count rows"
else
  bad "case1 the list has only $count rows (expected >= 8) — reader or file broken"
fi
for anchor in gh gitleaks; do
  if printf '%s\n' "$names" | grep -qx -- "$anchor"; then
    ok "case1 anchor '$anchor' is listed"
  else
    bad "case1 anchor '$anchor' missing from the list"
  fi
done

# Field count is checked on the raw text, not through `read`: IFS collapses
# consecutive tabs, so an empty field would silently shift every later column.
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  line="${line%$'\r'}"
  case "$line" in ''|'#'*) continue ;; esac
  tabs="${line//[^$'\t']/}"
  if [ "${#tabs}" -ne 6 ]; then
    bad "case1 line $lineno has ${#tabs} tabs (expected 6): $line"
    continue
  fi
  IFS=$'\t' read -r name level scope brew apt license purpose <<< "$line"
  for f in "$name" "$level" "$scope" "$brew" "$apt" "$license" "$purpose"; do
    [ -n "$f" ] || bad "case1 line $lineno has an empty field"
  done
  case "$level" in
    required|optional) : ;;
    *) bad "case1 '$name' has unknown level '$level'" ;;
  esac
  case "$scope" in
    core|security|poller|action|reviewer|driver|maintenance) : ;;
    *) bad "case1 '$name' has unknown scope '$scope' (add it to docs/dependencies.md's scope list and here)" ;;
  esac
done < "$DEPS_TSV"
ok "case1 field layout checked on $lineno lines"

# ---- Case 2: the committed table matches the list ----
if [ ! -f "$DEPS_MD" ]; then
  bad "case2 docs/dependencies.md missing"
else
  committed=$(awk '/^<!-- deps-table:end -->$/{f=0} f{print} /^<!-- deps-table:begin -->$/{f=1}' "$DEPS_MD")
  generated=$(deps_markdown_table)
  if [ -z "$committed" ]; then
    bad "case2 docs/dependencies.md has no table between the deps-table markers"
  elif [ "$committed" = "$generated" ]; then
    ok "case2 docs/dependencies.md matches deps_markdown_table"
  else
    bad "case2 docs/dependencies.md is stale — regenerate it: bash -c '. lib/deps.sh; deps_markdown_table'"
    diff <(printf '%s\n' "$committed") <(printf '%s\n' "$generated") | head -20
  fi
fi

# ---- Case 3: every runner guide follows the list ----
# guide_uncovered <guide> — print the dependency names <guide> neither names
# nor reaches through a link to docs/dependencies.md; nothing when covered.
# Reads the list in use (RUN_ISSUES_DEPS_FILE), so case 5 can point it at a
# temporary one.
guide_uncovered() {
  local guide="$1" n
  if grep -qE '\]\(([^)]*/)?dependencies\.md[)#]' "$guide"; then
    return 0
  fi
  for n in $(deps_names); do
    grep -qF -- "\`$n\`" "$guide" || printf '%s\n' "$n"
  done
}

guides=("$ROOT/README.md")
for g in "$ROOT"/docs/*-runner.md; do
  [ -f "$g" ] && guides+=("$g")
done
if [ "${#guides[@]}" -lt 3 ]; then
  bad "case3 only ${#guides[@]} runner guides found (expected >= 3: README.md + docs/*-runner.md)"
fi
for g in "${guides[@]}"; do
  missing=$(guide_uncovered "$g")
  if [ -z "$missing" ]; then
    ok "case3 ${g#"$ROOT"/} follows the dependency list"
  else
    bad "case3 ${g#"$ROOT"/} neither links docs/dependencies.md nor names: $(printf '%s ' $missing)"
  fi
done

# ---- Case 4: code -> list ----
# Every literal key handed to preflight_install_hint is a dependency name,
# except the two fixes that are not packages.
keys=$(grep -rhoE 'preflight_install_hint [a-z0-9-]+' \
         "$ROOT"/*.sh "$ROOT"/lib/*.sh 2>/dev/null \
       | awk '{print $2}' | sort -u | grep -vxE 'gh-auth|jq-binary')
if [ "$(printf '%s\n' "$keys" | grep -c .)" -lt 3 ]; then
  bad "case4 derived fewer than 3 install-hint keys from the code — the derivation is broken"
fi
for k in $keys; do
  if printf '%s\n' "$names" | grep -qx -- "$k"; then
    ok "case4 install-hint key '$k' is in the list"
  else
    bad "case4 install-hint key '$k' is used in the code but missing from lib/deps.tsv"
  fi
done

scanners=$(bash -c '. "$1"; printf "%s\n" $SECURITY_SCANNERS' _ "$ROOT/lib/security-scan.sh")
if [ -z "$scanners" ]; then
  bad "case4 SECURITY_SCANNERS could not be read from lib/security-scan.sh"
fi
for s in $scanners; do
  if [ "$(deps_field "$s" scope)" = "security" ]; then
    ok "case4 scanner '$s' is in the list with scope security"
  else
    bad "case4 scanner '$s' is not in lib/deps.tsv with scope security — the S0 gate would never warn about it"
  fi
done

# No consumer keeps its own list: the shapes the hand-written copies had.
if grep -nE 'for cmd in git gh jq' "$ROOT/lib/preflight.sh" >/dev/null; then
  bad "case4 lib/preflight.sh still iterates a hand-written list"
else
  ok "case4 lib/preflight.sh reads its list from lib/deps.tsv"
fi
if grep -nE 'preflight_report_tool (git|gh|jq|claude|tmux|python3) ' "$ROOT/install.sh" >/dev/null; then
  bad "case4 install.sh still reports a hand-written list"
else
  ok "case4 install.sh reads its list from lib/deps.tsv"
fi

# ---- Case 5: the guide guard can fail ----
cp "$DEPS_TSV" "$WORK/deps.tsv"
printf 'run-issues-new-dep\toptional\tcore\tbrew install x\tapt-get install x\tMIT\ttest row\n' >> "$WORK/deps.tsv"
{
  for n in $(deps_names); do printf -- '- `%s`\n' "$n"; done
} > "$WORK/guide-names.md"
printf 'See [the table](../docs/dependencies.md).\n' > "$WORK/guide-link.md"

missing=$(guide_uncovered "$WORK/guide-names.md")
if [ -z "$missing" ]; then
  ok "case5 a guide naming every current dependency passes"
else
  bad "case5 a guide naming every dependency was rejected: $missing"
fi
missing=$(RUN_ISSUES_DEPS_FILE="$WORK/deps.tsv" guide_uncovered "$WORK/guide-names.md")
if [ "$missing" = "run-issues-new-dep" ]; then
  ok "case5 a dependency added to the list without a guide line is reported"
else
  bad "case5 the new dependency was not reported (got: '$missing')"
fi
missing=$(RUN_ISSUES_DEPS_FILE="$WORK/deps.tsv" guide_uncovered "$WORK/guide-link.md")
if [ -z "$missing" ]; then
  ok "case5 a guide linking the shared table follows every new row"
else
  bad "case5 a guide linking the table was rejected: $missing"
fi
generated_tmp=$(RUN_ISSUES_DEPS_FILE="$WORK/deps.tsv" deps_markdown_table)
if [ "$generated_tmp" != "$(deps_markdown_table)" ]; then
  ok "case5 a list change changes the generated table (case 2 would turn red)"
else
  bad "case5 the generated table ignored a new row"
fi

echo "----------------------------------------"
if [ "$FAIL" -eq 0 ]; then
  echo "dependencies: all passed"
  exit 0
fi
echo "dependencies: FAILURES"
exit 1
