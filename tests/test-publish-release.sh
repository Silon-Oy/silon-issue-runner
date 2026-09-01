#!/usr/bin/env bash
# test-publish-release.sh — publish-release.sh, the handover surface that turns
# the current working tree into a history-free release in a customer repository
# (issue #155).
#
# The script's job is mostly REFUSAL: four fail-closed gates run before anything
# is written, and a single refusal must leave both the local repository and the
# target untouched. That is what this test exercises. It uses a LOCAL BARE REPO
# as the target — no network is contacted anywhere in this file.
#
# Cases (mirroring the issue's acceptance criteria):
#   1. usage errors -> exit 1 (missing --target, missing --customer, bad flag)
#   2. --dry-run writes nothing and never contacts the target (the target path
#      does not even exist and the run still succeeds)
#   3. --dry-run against a real target leaves it without a single ref
#   4. the BUILT-IN denylist refuses a real forbidden name -> exit 3
#   5. the leak gate reports matches as tiedosto:rivi and refuses -> exit 3,
#      while the same term inside publish-release.sh is NOT a match (the
#      maintainer tool is excluded from both the release and the scan)
#   6. word boundaries: a term that only appears as a substring is not a match
#   7. dirty working tree -> exit 2
#   8. HEAD != origin/main -> exit 2
#   9. missing LICENSE template -> exit 4
#  10. publish: the target's main is ONE commit with NO parent, carries the
#      rendered LICENSE, and carries neither the maintainer tool nor the template
#  11. a repeated publish produces another parentless commit and a second
#      release tag (the target's history is a queue of releases)
#  12. the local repository is byte-for-byte unchanged by all of the above
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
[ -x "$PUB" ] || { echo "FAIL: publish-release.sh missing or not executable"; exit 1; }

WORK="$(mktemp -d -t publish-release-test.XXXXXX)" || { echo "SKIP: mktemp failed"; exit 0; }
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"; mkdir -p "$HOME"
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
export GIT_CONFIG_NOSYSTEM=1
unset RUN_ISSUES_PUBLISH_DENYLIST_FILE

FAIL=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAIL=1; }

gitf() {
  git -c user.name=Fixture -c user.email=fixture@example.invalid \
      -c commit.gpgsign=false -c init.defaultBranch=main "$@"
}

# --- fixture: a source repo with an origin, and an empty target bare repo -----
SRC="$WORK/src"
ORIGIN="$WORK/origin.git"
TARGET="$WORK/target.git"
CUSTOMER="Esimerkki Oy"

mkdir -p "$SRC/lib"
printf 'Paketti.\n' > "$SRC/README.md"
printf '#!/usr/bin/env bash\necho hei\n' > "$SRC/lib/thing.sh"
printf 'Käyttöoikeus myönnetään: {{CUSTOMER}}\n' > "$SRC/LICENSE.customer-grant.template"
# The maintainer tool carries a forbidden term on purpose (case 5): it must be
# excluded from BOTH the release and the scan, or the gate would refuse forever.
printf '#!/usr/bin/env bash\n# denylist: zapcorp qxname\n' > "$SRC/publish-release.sh"

gitf init -q "$SRC"
gitf -C "$SRC" symbolic-ref HEAD refs/heads/main
gitf -C "$SRC" add -A
gitf -C "$SRC" commit -q -m "init"
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
printf '# fixture terms\nzapcorp\nqxname\n' > "$DENY"

target_refs() { git -C "$TARGET" for-each-ref --format='%(refname)' 2>/dev/null; }

run_pub() { "$PUB" --repo "$SRC" --customer "$CUSTOMER" "$@" >"$WORK/out" 2>"$WORK/err"; }

# ---- Case 1: usage errors ----
"$PUB" --repo "$SRC" --customer "$CUSTOMER" >/dev/null 2>&1
[ "$?" = "1" ] && ok "missing --target -> exit 1" || bad "missing --target did not exit 1"
"$PUB" --repo "$SRC" --target "$TARGET" >/dev/null 2>&1
[ "$?" = "1" ] && ok "missing --customer -> exit 1" || bad "missing --customer did not exit 1"
"$PUB" --bogus >/dev/null 2>&1
[ "$?" = "1" ] && ok "unknown flag -> exit 1" || bad "unknown flag did not exit 1"

# ---- Case 2: --dry-run never contacts the target ----
GHOST="$WORK/never-created.git"
RUN_ISSUES_PUBLISH_DENYLIST_FILE="$DENY" run_pub --target "$GHOST" --dry-run
rc=$?
if [ "$rc" = "0" ]; then ok "--dry-run succeeds against a target that does not exist"
else bad "--dry-run exited $rc against a nonexistent target (network/target contact?)"; fi
if [ ! -e "$GHOST" ]; then ok "--dry-run created nothing at the target path"
else bad "--dry-run created $GHOST"; fi
grep -q 'dry-run' "$WORK/out" && ok "--dry-run output is marked as such" \
  || bad "--dry-run output does not say dry-run"
grep -q 'vuotoportti: OK' "$WORK/out" && ok "--dry-run reports the leak-gate result" \
  || bad "--dry-run does not report the leak-gate result"
grep -qE 'tiedostot: *[1-9]' "$WORK/out" && ok "--dry-run reports a file count" \
  || bad "--dry-run does not report a file count"

# ---- Case 3: --dry-run leaves a real target refless ----
RUN_ISSUES_PUBLISH_DENYLIST_FILE="$DENY" run_pub --target "$TARGET" --dry-run
rc=$?
[ "$rc" = "0" ] && ok "--dry-run against a real target -> exit 0" || bad "--dry-run exited $rc"
if [ -z "$(target_refs)" ]; then ok "--dry-run wrote no ref into the target"
else bad "--dry-run wrote refs into the target: $(target_refs)"; fi

# ---- Case 4: the BUILT-IN denylist refuses a real name ----
# Assembled at runtime (see header) — never written literally in this file.
REAL_TERM="$(printf '%s%s' 'Sil' 'on')"
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
grep -q 'publish-release.sh:' "$WORK/err" \
  && bad "the maintainer tool was scanned (it must be excluded)" \
  || ok "publish-release.sh is excluded from the scan"
if [ -z "$(target_refs)" ]; then ok "leak refusal wrote nothing into the target"
else bad "leak refusal still wrote refs: $(target_refs)"; fi
rm -f "$SRC/leak.md"; sync "remove the planted term"

# ---- Case 6: word boundaries ----
# "zapcorporation" contains "zapcorp" but is a different word; a substring match
# would make the gate refuse trees that leak nothing.
printf 'zapcorporation on eri sana\n' > "$SRC/boundary.md"
sync "plant a substring-only occurrence"
RUN_ISSUES_PUBLISH_DENYLIST_FILE="$DENY" run_pub --target "$TARGET" --dry-run
rc=$?
[ "$rc" = "0" ] && ok "substring-only occurrence is not a match (word boundaries)" \
  || bad "substring-only occurrence refused (exit $rc) — boundary check is wrong"
rm -f "$SRC/boundary.md"; sync "remove the substring fixture"

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

# ---- Case 9: missing LICENSE template ----
cp "$SRC/LICENSE.customer-grant.template" "$WORK/template.bak"
rm -f "$SRC/LICENSE.customer-grant.template"
sync "drop the license template"
RUN_ISSUES_PUBLISH_DENYLIST_FILE="$DENY" run_pub --target "$TARGET" --yes
rc=$?
[ "$rc" = "4" ] && ok "missing license template -> exit 4" || bad "missing template exited $rc"
if [ -z "$(target_refs)" ]; then ok "template refusal wrote nothing into the target"
else bad "template refusal wrote refs: $(target_refs)"; fi
cp "$WORK/template.bak" "$SRC/LICENSE.customer-grant.template"
sync "restore the license template"

# ---- snapshot the local repo before the first real publish (case 12) ----
snapshot() {
  gitf -C "$SRC" rev-parse HEAD
  gitf -C "$SRC" status --porcelain
  gitf -C "$SRC" branch --list
  gitf -C "$SRC" remote -v
  gitf -C "$SRC" tag -l
  gitf -C "$SRC" worktree list
}
snapshot > "$WORK/before.txt"

# ---- Case 10: publish ----
RUN_ISSUES_PUBLISH_DENYLIST_FILE="$DENY" run_pub --target "$TARGET" --yes
rc=$?
if [ "$rc" = "0" ]; then ok "publish -> exit 0"
else bad "publish exited $rc; stderr: $(head -3 "$WORK/err")"; fi

COUNT="$(git -C "$TARGET" rev-list --count main 2>/dev/null)"
[ "$COUNT" = "1" ] && ok "target main holds exactly one commit" \
  || bad "target main holds '$COUNT' commits, expected 1"

PARENTS="$(git -C "$TARGET" rev-list --parents -n 1 main 2>/dev/null | wc -w | tr -d ' ')"
[ "$PARENTS" = "1" ] && ok "release commit has no parent (orphan)" \
  || bad "release commit has $((PARENTS - 1)) parent(s), expected 0"

TREE="$(git -C "$TARGET" ls-tree -r --name-only main 2>/dev/null)"
printf '%s\n' "$TREE" | grep -qx 'LICENSE' && ok "release carries a rendered LICENSE" \
  || bad "release has no LICENSE"
printf '%s\n' "$TREE" | grep -qx 'publish-release.sh' \
  && bad "release still carries publish-release.sh" \
  || ok "release excludes publish-release.sh"
printf '%s\n' "$TREE" | grep -qx 'LICENSE.customer-grant.template' \
  && bad "release still carries the license template" \
  || ok "release excludes the license template"
printf '%s\n' "$TREE" | grep -qx 'README.md' && ok "release carries the tracked content" \
  || bad "release is missing README.md"

git -C "$TARGET" show "main:LICENSE" 2>/dev/null | grep -qF "$CUSTOMER" \
  && ok "LICENSE names the customer given with --customer" \
  || bad "LICENSE does not name the customer"
git -C "$TARGET" show "main:LICENSE" 2>/dev/null | grep -qF '{{CUSTOMER}}' \
  && bad "LICENSE still holds the {{CUSTOMER}} placeholder" \
  || ok "LICENSE placeholder was substituted"

TAGS="$(git -C "$TARGET" tag -l 'release/*' | wc -l | tr -d ' ')"
[ "$TAGS" = "1" ] && ok "publish left one release tag in the target" \
  || bad "target holds $TAGS release tags, expected 1"

AUTHOR="$(git -C "$TARGET" log -1 --format='%an <%ae>' main 2>/dev/null)"
[ "$AUTHOR" = "release <release@example.invalid>" ] \
  && ok "release commit carries the neutral identity" \
  || bad "release commit author is '$AUTHOR' — commit metadata ships too"

# ---- Case 11: a repeated publish ----
sleep 1  # release tags are stamped to the second; a same-second repeat collides
RUN_ISSUES_PUBLISH_DENYLIST_FILE="$DENY" run_pub --target "$TARGET" --yes
rc=$?
[ "$rc" = "0" ] && ok "repeated publish -> exit 0" \
  || bad "repeated publish exited $rc; stderr: $(head -3 "$WORK/err")"
PARENTS2="$(git -C "$TARGET" rev-list --parents -n 1 main 2>/dev/null | wc -w | tr -d ' ')"
[ "$PARENTS2" = "1" ] && ok "the repeated release is parentless too" \
  || bad "the repeated release has $((PARENTS2 - 1)) parent(s)"
TAGS2="$(git -C "$TARGET" tag -l 'release/*' | wc -l | tr -d ' ')"
[ "$TAGS2" = "2" ] && ok "the target keeps a queue of release tags ($TAGS2)" \
  || bad "target holds $TAGS2 release tags after two publishes, expected 2"

# ---- Case 12: the local repository is unchanged ----
snapshot > "$WORK/after.txt"
if diff -q "$WORK/before.txt" "$WORK/after.txt" >/dev/null 2>&1; then
  ok "local repository unchanged (HEAD, status, branches, remotes, tags, worktrees)"
else
  bad "local repository changed:"; diff "$WORK/before.txt" "$WORK/after.txt" | sed 's/^/    /'
fi

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "publish-release: all passed" || echo "publish-release: FAILURES"
[ "$FAIL" -eq 0 ]
