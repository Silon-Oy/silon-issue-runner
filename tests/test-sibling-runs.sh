#!/usr/bin/env bash
# test-sibling-runs.sh — the cycle review's sibling-run section (issue #337).
#
# lib/sibling-runs.sh lists the same repo's other runs: open runner PRs (ONE
# REST listing per repo) and this machine's live run-dirs. Built against a real
# bare origin + clone so the changed files come from real git refs, with gh
# mocked and every call counted (CLAUDE.md §5.4: the guard is the call count).
#
# Cases:
#   (a) sibling as a PR: issue number from `Closes #N`, title, files from the
#       remote-tracking refs; a non-runner PR is not listed.
#   (b) live local run: issue.json title, started_at, worktree diff.
#   (c) no siblings: the section says so out loud.
#   (d) the listing fails: the section says it could not read, rc 0, not empty.
#   (e) cost: exactly one gh call per listing; a terminal and a foreign-host
#       run-dir are not listed and their worktrees are never touched.
#   (f) the own run-dir and the own issue are left out; a PR of a live local
#       run is listed once, as the local run.
#   (g) both cycle-review prompts carry the {{SIBLING_RUNS}} placeholder, and
#       orchestrate.sh renders it into both.
#   (h) the optional rows file (issue #338): written with the rendered rows on a
#       good read, empty when there are no siblings, absent on a read failure.
#
# Run: bash tests/test-sibling-runs.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Hermetic: never source this machine's real env file (CLAUDE.md §5.5, #358).
export RUN_ISSUES_ENV_FILE="$HERE/.no-such-machine-env"
export RUN_ISSUES_CLAIM_VERIFY_DELAY=0
ROOT="$HERE/.."

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

WORK=$(mktemp -d -t sibling-runs.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
ok()  { echo "PASS ($1) $2"; }
bad() { echo "FAIL ($1) $2"; FAIL=1; }

ORIGIN="$WORK/origin.git"
REPO="$WORK/repo"
git init -q --bare "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q "$REPO"
git -C "$REPO" symbolic-ref HEAD refs/heads/main
(
  cd "$REPO"
  git config user.email t@t.t; git config user.name t
  git remote add origin "$ORIGIN"
  echo v0 > base.txt; git add base.txt; git commit -qm init
  git push -q origin main
  # The remote sibling's branch: one changed file.
  git checkout -q -b auto-run/issue-10-remote
  echo r > remote-change.txt; git add remote-change.txt; git commit -qm remote
  git push -q origin auto-run/issue-10-remote
  # A live local run's branch that also has a PR (case f's dedup).
  git checkout -q main
  git checkout -q -b auto-run/issue-20-local
  git push -q origin auto-run/issue-20-local
  git checkout -q main
  git fetch -q origin
  git remote set-head origin main
) || { echo "FAIL setup"; exit 1; }

# Live local run #20 in its own worktree with one committed change.
WT20="$REPO/.claude/worktrees/run-20"
git -C "$REPO" worktree add -q "$WT20" auto-run/issue-20-local
( cd "$WT20" && echo l > local-change.txt && git add local-change.txt && git commit -qm local )

THIS_HOST=$(bash -c ". '$ROOT/lib/host.sh'; runner_host")
RUNS="$REPO/.claude/run-issues"

# mk_run <dir> <issue> <status> <host> <worktree> [<title>]
mk_run() {
  mkdir -p "$RUNS/$1"
  jq -n --arg st "$3" --arg h "$4" --arg wt "$5" --argjson n "$2" \
    '{issue_number: $n, status: $st, host: $h, started_at: "2026-10-23T10:00:00Z",
      branch: "auto-run/issue-\($n)", worktree_path: $wt, remote: "origin", base_branch: ""}' \
    > "$RUNS/$1/run.json"
  [ -n "${6:-}" ] && jq -n --arg t "$6" '{title: $t}' > "$RUNS/$1/issue.json"
  return 0
}
mk_run r20   20 initialized "$THIS_HOST" "$WT20" "Local sibling"
mk_run self  30 initialized "$THIS_HOST" "$REPO"  "This run"
# Terminal and foreign-host runs: existing worktree dirs that the git shim below
# would log if anything ran git in them.
mkdir -p "$WORK/TOUCHED-terminal" "$WORK/TOUCHED-foreign"
mk_run term  40 completed   "$THIS_HOST" "$WORK/TOUCHED-terminal" "Done run"
mk_run alien 50 initialized "other-host" "$WORK/TOUCHED-foreign"  "Foreign run"

BIN="$WORK/bin"
mkdir -p "$BIN"
GH_LOG="$WORK/gh.log"
GH_MODE="$WORK/gh-mode"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"
case "\$(cat "$GH_MODE")" in
  fail) echo "HTTP 502" >&2; exit 1 ;;
  none) echo '[]' ;;
  *) cat <<'JSON'
[
 {"number": 101, "title": "Remote sibling", "created_at": "2026-10-22T08:00:00Z",
  "body": "Text\n\nCloses #10", "head": {"ref": "auto-run/issue-10-remote"}, "base": {"ref": "main"}},
 {"number": 102, "title": "Local sibling PR", "created_at": "2026-10-22T09:00:00Z",
  "body": "Closes #20", "head": {"ref": "auto-run/issue-20-local"}, "base": {"ref": "main"}},
 {"number": 103, "title": "Own issue PR", "created_at": "2026-10-22T09:30:00Z",
  "body": "Fixes #30", "head": {"ref": "auto-run/issue-30-x"}, "base": {"ref": "main"}},
 {"number": 104, "title": "Human PR", "created_at": "2026-10-22T10:00:00Z",
  "body": "Closes #60", "head": {"ref": "feature/human"}, "base": {"ref": "main"}}
]
JSON
  ;;
esac
SH
chmod +x "$BIN/gh"

GIT_LOG="$WORK/git.log"
REAL_GIT=$(command -v git)
cat > "$BIN/git" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$GIT_LOG"
exec "$REAL_GIT" "\$@"
SH
chmod +x "$BIN/git"

# section <mode> [<rows-file>] — runs sibling_runs_section as the run "self" (issue 30).
section() {
  printf '%s' "$1" > "$GH_MODE"
  : > "$GH_LOG"
  ( PATH="$BIN:$PATH"
    . "$ROOT/lib/sibling-runs.sh"
    sibling_runs_section "$REPO" "acme/app" origin "$RUNS/self" 30 ${2:+"$2"} ) 2>"$WORK/stderr"
}
list() {
  printf '%s' "$1" > "$GH_MODE"
  : > "$GH_LOG"
  ( PATH="$BIN:$PATH"
    . "$ROOT/lib/sibling-runs.sh"
    list_sibling_runs "$REPO" "acme/app" origin "$RUNS/self" 30 ) 2>"$WORK/stderr"
}

OUT=$(section full); RC=$?
ROWS=$(list full)

# (a)
row10=$(printf '%s\n' "$ROWS" | jq -c 'select(.issue == 10)')
if printf '%s' "$row10" | jq -e '.source == "pr" and .pr == 101 and .title == "Remote sibling"
     and .started_at == "2026-10-22T08:00:00Z" and .files == ["remote-change.txt"]' >/dev/null \
   && printf '%s' "$OUT" | grep -q '#10 Remote sibling.*PR #101' \
   && printf '%s' "$OUT" | grep -q '`remote-change.txt`' \
   && ! printf '%s' "$OUT" | grep -q 'Human PR'; then
  ok a "PR sibling listed with issue, title, start time and files; non-runner PR left out"
else
  bad a "row10='$row10' out='$OUT'"
fi

# (b)
row20=$(printf '%s\n' "$ROWS" | jq -c 'select(.issue == 20)')
if printf '%s' "$row20" | jq -e '.source == "local" and .title == "Local sibling"
     and .started_at == "2026-10-23T10:00:00Z" and .files == ["local-change.txt"]' >/dev/null \
   && printf '%s' "$OUT" | grep -q '#20 Local sibling.*paikallinen ajo'; then
  ok b "live local run listed with its worktree diff"
else
  bad b "row20='$row20'"
fi

# (e)
calls=$(wc -l < "$GH_LOG" | tr -d ' ')
if [ "$RC" = 0 ] && [ "$calls" = 1 ] && grep -q 'api repos/acme/app/pulls?state=open' "$GH_LOG" \
   && ! grep -q -- '--search' "$GH_LOG" \
   && ! printf '%s\n%s' "$OUT" "$ROWS" | grep -q -e 'Done run' -e 'Foreign run' -e '#40' -e '#50' \
   && grep -q "$WT20" "$GIT_LOG" && ! grep -q TOUCHED "$GIT_LOG"; then
  ok e "one REST listing; terminal and foreign-host runs neither listed nor touched"
else
  bad e "rc=$RC calls=$calls log='$(cat "$GH_LOG")' git='$(cat "$GIT_LOG")'"
fi

# (f)
n20=$(printf '%s\n' "$ROWS" | jq -s '[.[] | select(.issue == 20)] | length')
if [ "$n20" = 1 ] && ! printf '%s\n' "$ROWS" | jq -e 'select(.issue == 30)' >/dev/null \
   && ! printf '%s' "$OUT" | grep -q -e 'This run' -e 'Own issue PR'; then
  ok f "own run and own issue left out; PR of a live local run listed once"
else
  bad f "n20=$n20 rows='$ROWS'"
fi

# (c) — no PRs and no other live local run.
mv "$RUNS/r20" "$WORK/r20.off"
OUT=$(section none); RC=$?
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'Ei rinnakkaisia ajoja'; then
  ok c "no siblings is said out loud"
else
  bad c "rc=$RC out='$OUT'"
fi
mv "$WORK/r20.off" "$RUNS/r20"

# (d)
OUT=$(section fail); RC=$?
list fail >/dev/null; LRC=$?
if [ "$RC" = 0 ] && [ "$LRC" = 2 ] && printf '%s' "$OUT" | grep -q 'Sisarajoja ei voitu lukea' \
   && ! printf '%s' "$OUT" | grep -q -e 'Ei rinnakkaisia' -e 'Local sibling'; then
  ok d "read failure is reported as such, not as an empty or partial list; rc 0"
else
  bad d "rc=$RC list_rc=$LRC out='$OUT'"
fi

# (g)
if grep -q '{{SIBLING_RUNS}}' "$ROOT/prompts/01-cycle-review.md" \
   && grep -q '{{SIBLING_RUNS}}' "$ROOT/prompts/01-cycle-review-light.md" \
   && [ "$(grep -c '"SIBLING_RUNS=\$SIBLING_RUNS"' "$ROOT/orchestrate.sh")" = 2 ]; then
  ok g "both review prompts carry the section and orchestrate.sh renders it into both"
else
  bad g "placeholder or render argument missing"
fi

# (h)
ROWS_F="$WORK/rows-full.jsonl"; ROWS_N="$WORK/rows-none.jsonl"; ROWS_X="$WORK/rows-fail.jsonl"
section full "$ROWS_F" >/dev/null
mv "$RUNS/r20" "$WORK/r20.off"
section none "$ROWS_N" >/dev/null
mv "$WORK/r20.off" "$RUNS/r20"
section fail "$ROWS_X" >/dev/null
if [ -f "$ROWS_F" ] && [ "$(jq -s -c '[.[] | .issue] | sort' "$ROWS_F")" = "$(printf '%s\n' "$ROWS" | jq -s -c '[.[] | .issue] | sort')" ] \
   && [ -f "$ROWS_N" ] && [ ! -s "$ROWS_N" ] && [ ! -e "$ROWS_X" ]; then
  ok h "rows file: the rendered rows on a good read, empty for none, absent on failure"
else
  bad h "full='$(cat "$ROWS_F" 2>/dev/null)' none_exists=$([ -f "$ROWS_N" ] && echo y) fail_exists=$([ -e "$ROWS_X" ] && echo y)"
fi

exit "$FAIL"
