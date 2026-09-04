#!/usr/bin/env bash
# test-publish-release.sh — publish-release.sh, the surface that turns the
# private upstream into a public mirror with a deterministically rewritten
# history (issue #155; model changed from an orphan commit to a rewrite).
#
# The script's job is mostly REFUSAL: five fail-closed gates run before anything
# is written, and a single refusal must leave both the local repository and the
# target untouched. Its second job is a rewrite that is the SAME every time, so
# that publishing is a fast-forward. Both are exercised here against a LOCAL
# BARE REPO — no network is contacted anywhere in this file.
#
# Cases:
#   1. usage errors -> exit 1 (missing --target, bad flag)
#   2. --dry-run writes nothing and never contacts the target (the target path
#      does not even exist and the run still succeeds)
#   3. --dry-run against a real target leaves it without a single ref
#   4. an empty or missing denylist, and a replacement that contains a forbidden
#      term, are refusals (exit 3), never a green light; the BUILT-IN denylist
#      refuses a real forbidden name -> exit 3
#   5. the leak gate reports matches as tiedosto:rivi and refuses -> exit 3,
#      while the same term inside an EXCLUDED file is NOT a match. Every entry
#      on publish-release.sh's exclusion list is checked, not just the first
#   6. boundaries are required BEFORE a term and not after (an inflected name,
#      a name inside an identifier) — that asymmetry is the gate's whole reach
#   7. dirty working tree -> exit 2
#   8. HEAD != origin/main -> exit 2
#   9. no LICENSE at HEAD -> exit 2
#  10. a missing rewrite tool -> exit 6, and a tool that exits non-zero -> exit 6
#  11. the history gate: a tool that rewrites NOTHING leaves the forbidden
#      history in place and the gate refuses -> exit 4 (the result is checked,
#      not the rules)
#  12. publish: the target's main carries the whole history, rewritten — no
#      forbidden term in any message, path or blob; the personal e-mail is
#      mapped; the excluded files are absent from EVERY commit; LICENSE and the
#      tracked content are present at the tip
#  13. determinism and fast-forward: a repeated publish is a no-op with the same
#      SHA and no new tag; a new upstream commit publishes as a fast-forward
#      whose parent is the previous tip; a rules change is rejected as
#      non-fast-forward (exit 5) and accepted with --force
#  14. the local repository is byte-for-byte unchanged by all of the above
#
# Cases 12–13 need a real `git filter-repo`; without it they are reported as
# SKIP and the file still exits 0, so the gate cases hold everywhere.
#
# Fixtures live under a mktemp HOME + TMPDIR, so neither the real home directory
# nor the real package tree is touched. The forbidden term used against the
# built-in denylist is ASSEMBLED AT RUNTIME from fragments on purpose: writing it
# literally here would plant a real name in the package and make the gate refuse
# every future release of this very repository.
#
# Run: bash tests/test-publish-release.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PUB="$ROOT/publish-release.sh"

command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }
# The maintainer tool is deliberately absent from the public mirror (it carries
# the denylist); this test ships with the mirror, so absence is a SKIP there.
[ -e "$PUB" ] || { echo "SKIP: publish-release.sh not shipped in this tree (public mirror)"; exit 0; }
[ -x "$PUB" ] || { echo "FAIL: publish-release.sh present but not executable"; exit 1; }

WORK="$(mktemp -d -t publish-release-test.XXXXXX)" || { echo "SKIP: mktemp failed"; exit 0; }
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"; mkdir -p "$HOME"
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
export GIT_CONFIG_NOSYSTEM=1
unset RUN_ISSUES_PUBLISH_DENYLIST_FILE RUN_ISSUES_PUBLISH_MAILMAP_FILE RUN_ISSUES_PUBLISH_FILTER_REPO

FAIL=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAIL=1; }

gitf() {
  git -c user.name=Fixture -c user.email=fixture@example.invalid \
      -c commit.gpgsign=false -c init.defaultBranch=main "$@"
}

HAVE_FILTER_REPO=0
git filter-repo --version >/dev/null 2>&1 && HAVE_FILTER_REPO=1

# --- fixture: a source repo with an origin, and an empty target bare repo -----
SRC="$WORK/src"
ORIGIN="$WORK/origin.git"
TARGET="$WORK/target.git"

EXCLUDED_PATHS=()
while IFS= read -r line; do
  EXCLUDED_PATHS+=("$line")
done < <(sed -n '/^EXCLUDED_FROM_RELEASE=(/,/^)/p' "$PUB" \
           | sed -n 's/^[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p')

if [ "${#EXCLUDED_PATHS[@]}" -lt 2 ]; then
  echo "FAIL: could not read EXCLUDED_FROM_RELEASE from publish-release.sh (got ${#EXCLUDED_PATHS[@]} entr(y|ies))"
  echo "publish-release: FAILURES"
  exit 1
fi

mkdir -p "$SRC/lib"
printf 'Paketti.\n' > "$SRC/README.md"
printf '#!/usr/bin/env bash\necho hei\n' > "$SRC/lib/thing.sh"
printf 'Fixture licence text.\n' > "$SRC/LICENSE"
# Every excluded file carries a forbidden term on purpose (case 5): each must be
# excluded from BOTH the release and the scan, or the gate would refuse forever.
for _ex in "${EXCLUDED_PATHS[@]}"; do
  mkdir -p "$SRC/$(dirname "$_ex")"
  printf '#!/usr/bin/env bash\n# denylist: zapcorp qxname\n' > "$SRC/$_ex"
done

gitf init -q "$SRC"
gitf -C "$SRC" symbolic-ref HEAD refs/heads/main
gitf -C "$SRC" add -A
gitf -C "$SRC" commit -q -m "init"

# History that must be rewritten: a message, a blob and a PATH carrying a term,
# authored under a personal address (case 12). The tip is clean again so the
# working-tree gate passes; only the HISTORY is dirty.
printf 'asiakas qxname tilasi\n' > "$SRC/notes.md"
printf 'x\n' > "$SRC/zapcorp-config.md"
gitf -C "$SRC" add -A
gitf -C "$SRC" -c user.name="Fixture Two" -c user.email="two@personal.invalid" \
  commit -q -m "fix zapcorp bug reported by qxname"
rm -f "$SRC/notes.md" "$SRC/zapcorp-config.md"
gitf -C "$SRC" add -A
gitf -C "$SRC" commit -q -m "tidy"

git init --bare -q "$ORIGIN"
git init --bare -q "$TARGET"
gitf -C "$SRC" remote add origin "$ORIGIN"
gitf -C "$SRC" push -q origin main
gitf -C "$SRC" fetch -q origin

# sync <msg> — commit every fixture change AND push it, so the "HEAD ==
# origin/main" gate stays satisfied except where a case deliberately breaks it.
sync() {
  gitf -C "$SRC" add -A
  gitf -C "$SRC" commit -q -m "$1"
  gitf -C "$SRC" push -q origin main
  gitf -C "$SRC" fetch -q origin
}

DENY="$WORK/denylist.txt"
printf '# fixture terms\nzapcorp==>zc\nqxname\n' > "$DENY"
MAILMAP="$WORK/mailmap"
printf 'Fixture Two <two@users.noreply.example> <two@personal.invalid>\n' > "$MAILMAP"
export RUN_ISSUES_PUBLISH_MAILMAP_FILE="$MAILMAP"

target_refs() { git -C "$TARGET" for-each-ref --format='%(refname)' 2>/dev/null; }

run_pub() { "$PUB" --repo "$SRC" "$@" >"$WORK/out" 2>"$WORK/err"; }

# ---- Case 1: usage errors ----
"$PUB" --repo "$SRC" >/dev/null 2>&1
[ "$?" = "1" ] && ok "missing --target -> exit 1" || bad "missing --target did not exit 1"
"$PUB" --bogus >/dev/null 2>&1
[ "$?" = "1" ] && ok "unknown flag -> exit 1" || bad "unknown flag did not exit 1"

# ---- Case 2: --dry-run never contacts the target ----
GHOST="$WORK/never-created.git"
RUN_ISSUES_PUBLISH_DENYLIST_FILE="$DENY" run_pub --target "$GHOST" --dry-run
rc=$?
if [ "$HAVE_FILTER_REPO" = "1" ]; then
  if [ "$rc" = "0" ]; then ok "--dry-run succeeds against a target that does not exist"
  else bad "--dry-run exited $rc against a nonexistent target (network/target contact?): $(head -3 "$WORK/err")"; fi
  grep -q 'dry-run' "$WORK/out" && ok "--dry-run output is marked as such" \
    || bad "--dry-run output does not say dry-run"
  grep -q 'vuotoportti: OK' "$WORK/out" && ok "--dry-run reports the leak-gate result" \
    || bad "--dry-run does not report the leak-gate result"
  grep -qE 'historia: *OK' "$WORK/out" && ok "--dry-run reports the history-gate result" \
    || bad "--dry-run does not report the history-gate result"
else
  [ "$rc" = "6" ] && ok "--dry-run without filter-repo -> exit 6 (tool gate)" \
    || bad "--dry-run without filter-repo exited $rc, expected 6"
fi
if [ ! -e "$GHOST" ]; then ok "--dry-run created nothing at the target path"
else bad "--dry-run created $GHOST"; fi

# ---- Case 3: --dry-run leaves a real target refless ----
RUN_ISSUES_PUBLISH_DENYLIST_FILE="$DENY" run_pub --target "$TARGET" --dry-run
if [ -z "$(target_refs)" ]; then ok "--dry-run wrote no ref into the target"
else bad "--dry-run wrote refs into the target: $(target_refs)"; fi

# ---- Case 4: an unusable denylist is a refusal, not a green light ----
printf '# pelkkiä kommentteja\n\n' > "$WORK/empty-denylist.txt"
RUN_ISSUES_PUBLISH_DENYLIST_FILE="$WORK/empty-denylist.txt" run_pub --target "$TARGET" --yes
rc=$?
[ "$rc" = "3" ] && ok "empty denylist -> exit 3 (fail-closed)" \
  || bad "empty denylist exited $rc, expected 3 — the gate failed OPEN"
RUN_ISSUES_PUBLISH_DENYLIST_FILE="$WORK/no-such-denylist.txt" run_pub --target "$TARGET" --yes
rc=$?
[ "$rc" = "3" ] && ok "missing denylist file -> exit 3 (fail-closed)" \
  || bad "missing denylist file exited $rc, expected 3"
# A replacement that re-plants a forbidden term would make the history gate
# refuse on every publish; it is caught once, up front.
printf 'zapcorp==>qxname-ltd\nqxname\n' > "$WORK/replant-denylist.txt"
RUN_ISSUES_PUBLISH_DENYLIST_FILE="$WORK/replant-denylist.txt" run_pub --target "$TARGET" --yes
rc=$?
[ "$rc" = "3" ] && ok "a replacement containing a forbidden term -> exit 3" \
  || bad "replanting replacement exited $rc, expected 3"
if [ -z "$(target_refs)" ]; then ok "denylist refusals wrote nothing into the target"
else bad "denylist refusal wrote refs: $(target_refs)"; fi

# The BUILT-IN denylist refuses a real name. Assembled at runtime (see header).
REAL_TERM="$(printf '%s%s' 'sad' 'ex')"
printf 'Tekijä: %s Oy\n' "$REAL_TERM" > "$SRC/notes.md"
sync "plant a real name"
run_pub --target "$TARGET" --yes
rc=$?
[ "$rc" = "3" ] && ok "built-in denylist refuses a real name -> exit 3" \
  || bad "built-in denylist did not refuse (exit $rc)"
if [ -z "$(target_refs)" ]; then ok "refusal wrote nothing into the target"
else bad "refusal still wrote refs: $(target_refs)"; fi
rm -f "$SRC/notes.md"; sync "remove the planted name"

# ---- Case 5: file:line reporting + the maintainer tool is excluded ----
printf 'rivi yksi\nasiakas zapcorp mainittu\n' > "$SRC/leak.md"
sync "plant a fixture term"
RUN_ISSUES_PUBLISH_DENYLIST_FILE="$DENY" run_pub --target "$TARGET" --yes
rc=$?
[ "$rc" = "3" ] && ok "leak gate refuses a planted term -> exit 3" \
  || bad "leak gate did not refuse (exit $rc)"
grep -q 'leak.md:2' "$WORK/err" && ok "match reported as tiedosto:rivi (leak.md:2)" \
  || bad "no tiedosto:rivi match for leak.md:2 in stderr"
for _ex in "${EXCLUDED_PATHS[@]}"; do
  grep -qF -- "$_ex:" "$WORK/err" \
    && bad "$_ex was scanned (every excluded file must be out of the scan)" \
    || ok "$_ex is excluded from the scan"
done
if [ -z "$(target_refs)" ]; then ok "leak refusal wrote nothing into the target"
else bad "leak refusal still wrote refs: $(target_refs)"; fi
rm -f "$SRC/leak.md"; sync "remove the planted term"

# ---- Case 6: the boundary is required before the term, not after ----
# The gate cases below only need to reach gate 3, so a stub tool keeps them
# independent of filter-repo; the stub is never reached when gate 3 refuses.
STUB_OK="$WORK/stub-ok.sh"
printf '#!/usr/bin/env bash\ncase "${1:-}" in --version) echo stub-ok; exit 0 ;; esac\nexit 0\n' > "$STUB_OK"
chmod +x "$STUB_OK"

printf 'kvazapcorp on eri sana\n' > "$SRC/boundary.md"
sync "plant a mid-word occurrence"
if [ "$HAVE_FILTER_REPO" = "1" ]; then
  RUN_ISSUES_PUBLISH_DENYLIST_FILE="$DENY" run_pub --target "$TARGET" --dry-run
  rc=$?
  [ "$rc" = "0" ] && ok "mid-word occurrence is not a match (leading boundary required)" \
    || bad "mid-word occurrence refused (exit $rc) — boundary check is wrong: $(head -3 "$WORK/err")"
else
  echo "SKIP: mid-word acceptance needs git filter-repo (the run continues past gate 3)"
fi
rm -f "$SRC/boundary.md"

for form in 'zapcorpin taivutettu muoto' 'zapcorpqxname yhdyssana' 'qxname_lock tunnisteessa' 'wp_qxname tunnisteessa'; do
  printf '%s\n' "$form" > "$SRC/suffix.md"
  sync "plant a suffixed form"
  RUN_ISSUES_PUBLISH_DENYLIST_FILE="$DENY" RUN_ISSUES_PUBLISH_FILTER_REPO="$STUB_OK" run_pub --target "$TARGET" --dry-run
  rc=$?
  [ "$rc" = "3" ] && ok "suffixed/embedded form is a match: '$form'" \
    || bad "suffixed/embedded form passed the gate (exit $rc): '$form'"
  rm -f "$SRC/suffix.md"
done
sync "remove the boundary fixtures"

# ---- Case 7: dirty working tree ----
printf 'kesken\n' > "$SRC/wip.txt"
RUN_ISSUES_PUBLISH_DENYLIST_FILE="$DENY" run_pub --target "$TARGET" --yes
rc=$?
[ "$rc" = "2" ] && ok "dirty working tree -> exit 2" || bad "dirty tree exited $rc, expected 2"
rm -f "$SRC/wip.txt"

# ---- Case 8: HEAD != origin/main ----
printf 'vain paikallinen\n' > "$SRC/local-only.md"
gitf -C "$SRC" add -A
gitf -C "$SRC" commit -q -m "local only"
RUN_ISSUES_PUBLISH_DENYLIST_FILE="$DENY" run_pub --target "$TARGET" --yes
rc=$?
[ "$rc" = "2" ] && ok "HEAD ahead of origin/main -> exit 2" || bad "desynced HEAD exited $rc"
gitf -C "$SRC" reset -q --hard origin/main
rm -f "$SRC/local-only.md"

# ---- Case 9: no LICENSE at HEAD ----
git -C "$SRC" rm -q LICENSE
sync "drop the licence"
RUN_ISSUES_PUBLISH_DENYLIST_FILE="$DENY" run_pub --target "$TARGET" --yes
rc=$?
[ "$rc" = "2" ] && ok "missing LICENSE -> exit 2" || bad "missing LICENSE exited $rc, expected 2"
if [ -z "$(target_refs)" ]; then ok "licence refusal wrote nothing into the target"
else bad "licence refusal wrote refs: $(target_refs)"; fi
printf 'Fixture licence text.\n' > "$SRC/LICENSE"
sync "restore the licence"

# ---- Case 10: the rewrite tool is missing or broken -> exit 6 ----
RUN_ISSUES_PUBLISH_DENYLIST_FILE="$DENY" RUN_ISSUES_PUBLISH_FILTER_REPO="$WORK/no-such-tool" run_pub --target "$TARGET" --yes
rc=$?
[ "$rc" = "6" ] && ok "missing rewrite tool -> exit 6" || bad "missing tool exited $rc, expected 6"
grep -qi 'filter-repo' "$WORK/err" && ok "missing tool is named in stderr" || bad "stderr does not name the tool"
STUB_FAIL="$WORK/stub-fail.sh"
printf '#!/usr/bin/env bash\ncase "${1:-}" in --version) echo stub-fail; exit 0 ;; esac\necho boom >&2; exit 1\n' > "$STUB_FAIL"
chmod +x "$STUB_FAIL"
RUN_ISSUES_PUBLISH_DENYLIST_FILE="$DENY" RUN_ISSUES_PUBLISH_FILTER_REPO="$STUB_FAIL" run_pub --target "$TARGET" --yes
rc=$?
[ "$rc" = "6" ] && ok "failing rewrite tool -> exit 6" || bad "failing tool exited $rc, expected 6"
if [ -z "$(target_refs)" ]; then ok "tool refusals wrote nothing into the target"
else bad "tool refusal wrote refs: $(target_refs)"; fi

# ---- Case 11: the history gate checks the result, not the rules ----
# A tool that succeeds but rewrites nothing leaves the forbidden history intact;
# the gate must catch every kind of residue: message, path and blob.
RUN_ISSUES_PUBLISH_DENYLIST_FILE="$DENY" RUN_ISSUES_PUBLISH_FILTER_REPO="$STUB_OK" run_pub --target "$TARGET" --yes
rc=$?
[ "$rc" = "4" ] && ok "unrewritten history -> exit 4 (history gate)" \
  || bad "unrewritten history exited $rc, expected 4: $(head -3 "$WORK/err")"
grep -q '^  commit ' "$WORK/err" && ok "history gate reports the message residue" \
  || bad "history gate did not report a commit message residue"
grep -q 'zapcorp-config.md:0' "$WORK/err" && ok "history gate reports the path residue" \
  || bad "history gate did not report the path residue"
grep -q '^  blob ' "$WORK/err" && ok "history gate reports the blob residue" \
  || bad "history gate did not report a blob residue"
grep -q 'notes.md' "$WORK/err" && ok "blob residue is reported with a path" \
  || bad "blob residue carries no path"
if [ -z "$(target_refs)" ]; then ok "history refusal wrote nothing into the target"
else bad "history refusal wrote refs: $(target_refs)"; fi

# ---- snapshot the local repo before the first real publish (case 14) ----
snapshot() {
  gitf -C "$SRC" rev-parse HEAD
  gitf -C "$SRC" status --porcelain
  gitf -C "$SRC" branch --list
  gitf -C "$SRC" remote -v
  gitf -C "$SRC" tag -l
  gitf -C "$SRC" worktree list | sed -E 's/ [0-9a-f]{7,40} [/ <sha> [/'
}
snapshot > "$WORK/before.txt"

if [ "$HAVE_FILTER_REPO" != "1" ]; then
  echo "SKIP: cases 12–13 need git filter-repo (brew install git-filter-repo)"
else
  # ---- Case 12: publish ----
  RUN_ISSUES_PUBLISH_DENYLIST_FILE="$DENY" run_pub --target "$TARGET" --yes
  rc=$?
  if [ "$rc" = "0" ]; then ok "publish -> exit 0"
  else bad "publish exited $rc; stderr: $(head -5 "$WORK/err")"; fi

  SRC_COUNT="$(gitf -C "$SRC" rev-list --count HEAD)"
  COUNT="$(git -C "$TARGET" rev-list --count main 2>/dev/null)"
  [ "$COUNT" = "$SRC_COUNT" ] && ok "target main carries the whole history ($COUNT commits)" \
    || bad "target main holds '$COUNT' commits, source has $SRC_COUNT"

  TIP="$(git -C "$TARGET" rev-parse main 2>/dev/null)"
  [ "$TIP" != "$(gitf -C "$SRC" rev-parse HEAD)" ] && ok "the mirror's SHAs are not the upstream's (no shared ancestry)" \
    || bad "mirror tip equals upstream tip — the history was not rewritten"

  MSGS="$(git -C "$TARGET" log --format=%B main 2>/dev/null)"
  printf '%s\n' "$MSGS" | grep -qi 'zapcorp\|qxname' \
    && bad "a forbidden term survives in a commit message" \
    || ok "no forbidden term in any commit message"
  printf '%s\n' "$MSGS" | grep -q 'fix zc bug reported by redacted' \
    && ok "messages carry the replacements (explicit and default)" \
    || bad "messages do not carry the expected replacements: $(printf '%s' "$MSGS" | tr '\n' '|')"

  PATHS="$(git -C "$TARGET" log --name-only --format= main 2>/dev/null | sort -u)"
  printf '%s\n' "$PATHS" | grep -qi 'zapcorp' \
    && bad "a forbidden term survives in a path" \
    || ok "no forbidden term in any path"
  printf '%s\n' "$PATHS" | grep -qx 'zc-config.md' \
    && ok "paths carry the replacement (zc-config.md)" \
    || bad "the renamed path is missing: $(printf '%s' "$PATHS" | tr '\n' ' ')"

  BLOBS="$(git -C "$TARGET" rev-list --objects main | awk '{print $1}' \
           | git -C "$TARGET" cat-file --batch-check='%(objecttype) %(objectname)' | awk '$1=="blob"{print $2}')"
  RESIDUE=0
  for b in $BLOBS; do
    # Same boundary rule as the gate: a term glued to a preceding word character
    # (the mid-word fixture) is not a leak by design.
    git -C "$TARGET" cat-file -p "$b" | grep -qiE '(^|[^[:alnum:]])(zapcorp|qxname)' && RESIDUE=1
  done
  [ "$RESIDUE" = "0" ] && ok "no forbidden term in any blob of the history" \
    || bad "a forbidden term survives in a blob"

  EMAILS="$(git -C "$TARGET" log --format='%ae%n%ce' main | sort -u)"
  printf '%s\n' "$EMAILS" | grep -q 'personal.invalid' \
    && bad "the personal e-mail survives in the history" \
    || ok "the personal e-mail is mapped away"
  printf '%s\n' "$EMAILS" | grep -q 'two@users.noreply.example' \
    && ok "the mailmap target identity is used" \
    || bad "the mailmap target identity is missing: $(printf '%s' "$EMAILS" | tr '\n' ' ')"

  for _ex in "${EXCLUDED_PATHS[@]}"; do
    if [ -z "$(git -C "$TARGET" log --all --format=%h -- "$_ex" 2>/dev/null)" ]; then
      ok "$_ex is absent from every commit of the mirror"
    else
      bad "$_ex appears in the mirror's history"
    fi
  done

  TREE="$(git -C "$TARGET" ls-tree -r --name-only main 2>/dev/null)"
  printf '%s\n' "$TREE" | grep -qx 'LICENSE' && ok "the tip carries LICENSE" || bad "the tip has no LICENSE"
  printf '%s\n' "$TREE" | grep -qx 'README.md' && ok "the tip carries the tracked content" \
    || bad "the tip is missing README.md"
  [ "$(git -C "$TARGET" show main:README.md)" = "Paketti." ] && ok "unaffected content is byte-identical" \
    || bad "README.md content changed in the rewrite"

  TAGS="$(git -C "$TARGET" tag -l 'release/*' | wc -l | tr -d ' ')"
  [ "$TAGS" = "1" ] && ok "publish left one release tag in the target" \
    || bad "target holds $TAGS release tags, expected 1"

  # ---- Case 13: determinism and fast-forward ----
  sleep 1  # release tags are stamped to the second
  RUN_ISSUES_PUBLISH_DENYLIST_FILE="$DENY" run_pub --target "$TARGET" --yes
  rc=$?
  [ "$rc" = "0" ] && ok "repeated publish -> exit 0" || bad "repeated publish exited $rc: $(head -3 "$WORK/err")"
  [ "$(git -C "$TARGET" rev-parse main)" = "$TIP" ] && ok "repeated publish is deterministic (same tip SHA)" \
    || bad "repeated publish moved the tip: $TIP -> $(git -C "$TARGET" rev-parse main)"
  grep -q 'Ajan tasalla' "$WORK/out" && ok "repeated publish reports up-to-date" \
    || bad "repeated publish did not report up-to-date"
  TAGS2="$(git -C "$TARGET" tag -l 'release/*' | wc -l | tr -d ' ')"
  [ "$TAGS2" = "1" ] && ok "a no-op publish adds no tag" || bad "no-op publish added a tag ($TAGS2 tags)"

  printf 'lisää\n' > "$SRC/more.md"
  sync "feat: more"
  sleep 1
  RUN_ISSUES_PUBLISH_DENYLIST_FILE="$DENY" run_pub --target "$TARGET" --yes
  rc=$?
  [ "$rc" = "0" ] && ok "publish after a new upstream commit -> exit 0" || bad "follow-up publish exited $rc: $(head -3 "$WORK/err")"
  NEWTIP="$(git -C "$TARGET" rev-parse main)"
  [ "$(git -C "$TARGET" rev-parse "$NEWTIP^" 2>/dev/null)" = "$TIP" ] \
    && ok "the follow-up publish is a fast-forward (previous tip is the parent)" \
    || bad "follow-up publish is not a fast-forward of the previous tip"
  TAGS3="$(git -C "$TARGET" tag -l 'release/*' | wc -l | tr -d ' ')"
  [ "$TAGS3" = "2" ] && ok "a publish that moves main adds a tag" || bad "expected 2 tags, found $TAGS3"

  # A rules change rewrites the whole history: rejected without --force.
  printf 'zapcorp==>zc\nqxname\npaketti==>pkg\n' > "$WORK/denylist-v2.txt"
  # "Paketti." is the README at the root commit, so the new rule changes every SHA.
  gitf -C "$SRC" rm -q --cached README.md >/dev/null 2>&1; printf 'Sisältö.\n' > "$SRC/README.md"
  sync "docs: neutral readme"   # keep the tip clean of the new term (gate 3)
  sleep 1
  RUN_ISSUES_PUBLISH_DENYLIST_FILE="$WORK/denylist-v2.txt" run_pub --target "$TARGET" --yes
  rc=$?
  [ "$rc" = "5" ] && ok "a rules change is rejected as non-fast-forward -> exit 5" \
    || bad "rules change exited $rc, expected 5: $(head -3 "$WORK/err")"
  grep -q -- '--force' "$WORK/err" && ok "the rejection names --force" || bad "the rejection does not name --force"
  [ "$(git -C "$TARGET" rev-parse main)" = "$NEWTIP" ] && ok "the rejected push left the mirror untouched" \
    || bad "the rejected push moved the mirror"
  RUN_ISSUES_PUBLISH_DENYLIST_FILE="$WORK/denylist-v2.txt" run_pub --target "$TARGET" --yes --force
  rc=$?
  [ "$rc" = "0" ] && ok "--force publishes the rewritten history -> exit 0" \
    || bad "--force exited $rc: $(head -3 "$WORK/err")"
  [ "$(git -C "$TARGET" rev-parse main)" != "$NEWTIP" ] && ok "--force replaced the mirror's history" \
    || bad "--force did not move the mirror"
  git -C "$TARGET" show main:README.md | grep -q 'Sisältö' && ok "the forced mirror carries the tip content" \
    || bad "the forced mirror tip content is wrong"
  git -C "$TARGET" log --format=%B main | grep -qi 'paketti' \
    && bad "the new rule was not applied to history" \
    || ok "the new rule was applied to the whole history"
fi

# ---- Case 14: the local repository is unchanged ----
snapshot > "$WORK/after.txt"
if diff -q "$WORK/before.txt" "$WORK/after.txt" >/dev/null 2>&1; then
  ok "local repository unchanged (HEAD, status, branches, remotes, tags, worktrees)"
else
  # Case 13 legitimately advanced HEAD through sync(); compare everything else.
  if diff <(sed 1d "$WORK/before.txt") <(sed 1d "$WORK/after.txt") >/dev/null 2>&1; then
    ok "local repository unchanged apart from the fixture's own commits"
  else
    bad "local repository changed:"; diff "$WORK/before.txt" "$WORK/after.txt" | sed 's/^/    /'
  fi
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "publish-release: all passed" || echo "publish-release: FAILURES"
[ "$FAIL" -eq 0 ]
