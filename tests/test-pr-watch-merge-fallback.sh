#!/usr/bin/env bash
# test-pr-watch-merge-fallback.sh — P6 merge fallback --rebase -> --merge (#41).
#
# A CLEAN, green, auto-merge PR whose feature branch carries a merge commit:
# GitHub rejects `gh pr merge --rebase` PERMANENTLY for such a branch, so the
# watcher must fall back to `gh pr merge --merge` and complete the merge instead
# of looping `merge failed` on every tick. This test drives watch_one with a gh
# mock whose `pr merge --rebase` fails and `pr merge --merge` succeeds, and
# asserts: exit 0, both strategies were attempted in order, and the run is
# finalized "merged".
#
# A FOREIGN host is used so P9 local cleanup is skipped and the run-dir +
# state.jsonl survive for assertions (the merge itself is unaffected — the host
# gate only governs local cleanup).
#
# Run: bash tests/test-pr-watch-merge-fallback.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRWATCH="$HERE/../pr-watch.sh"
STATE_LIB="$HERE/../lib/state.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed"
  exit 0
fi

WORK=$(mktemp -d -t prwatch-mergefb.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# --- minimal repo (no worktree needed — MERGE path does not rebase) ------
ORIGIN="$WORK/origin.git"
REPO="$WORK/repo"
git init -q --bare "$ORIGIN"
# Force `main` regardless of the machine's init.defaultBranch.
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q "$REPO"
git -C "$REPO" symbolic-ref HEAD refs/heads/main
(
  cd "$REPO"
  git config user.email t@t.t; git config user.name t
  git remote add origin "$ORIGIN"
  echo v0 > f.txt
  git add f.txt; git commit -qm init
  git push -q origin main
)

# --- gh mock: CLEAN/green PR; rebase-merge fails, merge-commit succeeds ---
BIN="$WORK/bin"; mkdir -p "$BIN"
MERGE_LOG="$WORK/merge_calls.log"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
case "\$1 \$2" in
  "pr view")
    cat <<'JSON'
{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN",
 "labels":[{"name":"auto-merge"}],"statusCheckRollup":[],
 "headRefName":"feature/x","baseRefName":"main"}
JSON
    ;;
  "pr merge")
    # Record every strategy attempt so the test can assert ordering.
    strat=rebase
    for a in "\$@"; do
      case "\$a" in
        --rebase) strat=rebase ;;
        --merge)  strat=merge ;;
        --squash) strat=squash ;;
      esac
    done
    echo "\$strat" >> "$MERGE_LOG"
    if [ "\$strat" = "rebase" ]; then
      # Mimic GitHub's permanent refusal for a branch with a merge commit.
      echo "failed to rebase and merge: Rebase merges are not allowed on this branch (merge commit present)" >&2
      exit 1
    fi
    echo "merged (mock, strategy=\$strat)"
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN/gh"

# --- completed run.json, FOREIGN host so cleanup is skipped --------------
RID="20260521-1400-issue-99"
RD="$REPO/.claude/run-issues/$RID"
# shellcheck source=../lib/state.sh
. "$STATE_LIB"
state_init "$RD" "$RID" "$REPO" "99"
state_set "$RD" "pr_url" "https://github.com/Silon-Oy/dotfiles/pull/999"
state_set "$RD" "branch" "feature/x"
tmp=$(mktemp); jq '.host = "some-other-host"' "$RD/run.json" > "$tmp"; mv "$tmp" "$RD/run.json"
state_finalize "$RD" "completed"

export PATH="$BIN:$PATH"
export RUN_ISSUES_LOCK_ROOT="$WORK/locks"

set +e
OUT=$( "$PRWATCH" "$REPO" 999 2>&1 )
RC=$?
set -e
echo "--- pr-watch output ---"; echo "$OUT"; echo "--- (rc=$RC) ---"

FAIL=0
[ "$RC" = "0" ] || { echo "FAIL expected rc 0, got $RC"; FAIL=1; }

# Both strategies attempted, rebase FIRST then the merge-commit fallback.
CALLS=$(tr '\n' ' ' < "$MERGE_LOG" 2>/dev/null | sed 's/ *$//')
[ "$CALLS" = "rebase merge" ] || { echo "FAIL merge strategy sequence: expected 'rebase merge', got '$CALLS'"; FAIL=1; }

# gh's own error text must survive into the log (issue #41 point 2).
echo "$OUT" | grep -q "rebase merge failed" || { echo "FAIL log did not report the rebase-merge failure"; FAIL=1; }
echo "$OUT" | grep -q "Rebase merges are not allowed" || { echo "FAIL log dropped gh's own error text"; FAIL=1; }

# The run must finalize merged, exactly as a first-try rebase merge would.
grep -q '"event":"pr_merged"' "$RD/state.jsonl" || { echo "FAIL no pr_merged event"; FAIL=1; }
[ "$(jq -r '.status' "$RD/run.json")" = "merged" ] || { echo "FAIL status not merged"; FAIL=1; }

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "pr-watch-merge-fallback: all passed" || echo "pr-watch-merge-fallback: FAILURES"
[ "$FAIL" -eq 0 ]
