#!/usr/bin/env bash
# test-status-github.sh — end-to-end guard for status.sh --github (issue #60).
#
# A `gh` shim on PATH (written into a mktemp bin dir) returns stored JSON
# fixtures and counts its invocations, so the whole enrichment path runs with no
# GitHub access. Covers: the confidence bump (low -> high on a confirmed PR), the
# pr_ci_red path, the UNSTABLE edge (a non-required red does NOT become
# pr_ci_red), a cache hit (the shim's call counter proves gh is NOT called), a
# stale cache (--cache-ttl 0 refetches), a NOT_OPEN PR (=> cleanup), and one
# repo whose fetch fails (repos_failed; the OTHER repo still enriches; exit 0).
# Issue #78: also covers issue titles — github.issue_title joined per run (open
# PR + no-PR issue-only rows), fetched ONCE per repo into the same TTL cache,
# with the title never leaking to a top-level field.
#
# Run: bash tests/test-status-github.sh   (exit 0 = all pass)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
STATUS="$ROOT/status.sh"

# Preconditions. jq is the hard dependency of status.sh; git is needed to plant
# the fake remotes that owner-resolution reads. gh itself is provided by the
# shim below — this test never touches the real gh (SKIP: gh not in PATH is thus
# handled structurally: the shim IS the PATH gh for the duration of the run).
if ! command -v jq >/dev/null 2>&1; then echo "SKIP: jq not installed"; exit 0; fi
if ! command -v git >/dev/null 2>&1; then echo "SKIP: git not installed"; exit 0; fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got=[$2] expected=[$3]"; fi; }

FX="$(mktemp -d "${TMPDIR:-/tmp}/status-github-test.XXXXXX")"
trap 'rm -rf "$FX"' EXIT
HOST="$(hostname -s 2>/dev/null || echo unknown)"

# ---- two fake repos with GitHub remotes (owner-resolution reads these) ----
REPO_A="$FX/repo-a"; mkdir -p "$REPO_A"
git -C "$REPO_A" init -q
git -C "$REPO_A" remote add origin https://github.com/o/repo-a.git
RUNS_A="$REPO_A/.claude/run-issues"; mkdir -p "$RUNS_A"

REPO_B="$FX/repo-b"; mkdir -p "$REPO_B"
git -C "$REPO_B" init -q
git -C "$REPO_B" remote add origin https://github.com/o/repo-b.git
RUNS_B="$REPO_B/.claude/run-issues"; mkdir -p "$RUNS_B"

# run_json <dir> <issue> <pr_number> — a completed run whose PR is <pr_number>.
# No pr_classified event => local verdict unknown => pr_in_flight/low locally, so
# a successful enrichment is observable as a confidence bump to high.
run_json() {
  local dir="$1" repo="$2" issue="$3" pr="$4"
  mkdir -p "$dir"
  cat > "$dir/run.json" <<JSON
{"run_id":"$(basename "$dir")","repo":"$repo","issue_number":$issue,"status":"completed","started_at":"2026-08-01T10:00:00Z","finished_at":"2026-08-01T10:05:00Z","host":"$HOST","current_state":"S12_Finalize","remote":"origin","repo_slug":"$(basename "$repo")","pr_url":"https://github.com/o/$(basename "$repo")/pull/$pr"}
JSON
}

run_json "$RUNS_A/r1" "$REPO_A" 1 1   # open, green, CLEAN     -> confidence bump
run_json "$RUNS_A/r2" "$REPO_A" 2 2   # open, RED required      -> pr_ci_red
run_json "$RUNS_A/r3" "$REPO_A" 3 3   # open, UNSTABLE red      -> NOT pr_ci_red
run_json "$RUNS_A/r5" "$REPO_A" 5 5   # PR not in open set      -> NOT_OPEN/cleanup
run_json "$RUNS_A/r6" "$REPO_A" 6 6   # open, CHANGES_REQUESTED -> pr_changes_requested
run_json "$RUNS_A/r7" "$REPO_A" 7 7   # open, draft, age > 7d   -> pr_draft_stale
run_json "$RUNS_B/r9" "$REPO_B" 9 9   # repo-b fetch fails      -> repos_failed

# A run with an issue but NO PR yet (blocked): issue #78 gives it an issue-only
# github object with a title and no chips (pr_state null). Its local class must
# be untouched (attention/blocked, high) — enrichment adds a title, not a verdict.
mkdir -p "$RUNS_A/r4"
cat > "$RUNS_A/r4/run.json" <<JSON
{"run_id":"r4","repo":"$REPO_A","issue_number":4,"status":"blocked","started_at":"2026-08-01T10:00:00Z","finished_at":"2026-08-01T10:05:00Z","host":"$HOST","current_state":"S6_CycleReview","blocked_reason":"cycle_review_blocker","remote":"origin","repo_slug":"repo-a"}
JSON

# issue #96: no-PR runs whose issue is absent from the OPEN-issue map (suspected
# closed). Absence is a hint, not proof — enrichment confirms with an explicit
# `gh issue view --json state` before letting it drive classification.
#   #8  -> issue confirmed CLOSED  => cleanup/issue_closed/high
#   #89 -> issue-state read FAILS   => fail-soft, local class (attention/blocked)
mkdir -p "$RUNS_A/r8"
cat > "$RUNS_A/r8/run.json" <<JSON
{"run_id":"r8","repo":"$REPO_A","issue_number":8,"status":"blocked","started_at":"2026-08-01T10:00:00Z","finished_at":"2026-08-01T10:05:00Z","host":"$HOST","current_state":"S6_CycleReview","blocked_reason":"cycle_review_blocker","remote":"origin","repo_slug":"repo-a"}
JSON
mkdir -p "$RUNS_A/r89"
cat > "$RUNS_A/r89/run.json" <<JSON
{"run_id":"r89","repo":"$REPO_A","issue_number":89,"status":"blocked","started_at":"2026-08-01T10:00:00Z","finished_at":"2026-08-01T10:05:00Z","host":"$HOST","current_state":"S6_CycleReview","blocked_reason":"cycle_review_blocker","remote":"origin","repo_slug":"repo-a"}
JSON
# A run with an OPEN PR whose issue is closed (#90): the PR state wins, so the run
# stays pr_in_flight and NEVER becomes issue_closed (a PR run's suspected-closed
# path is the pr_not_open branch, not this one). No issue-state read for it either
# (only no-PR runs are suspected-closed candidates).
run_json "$RUNS_A/r90" "$REPO_A" 90 90

WL="$FX/watchlist.json"
cat > "$WL" <<JSON
{"global_max_concurrent":2,"repos":[{"path":"$REPO_A","remotes":["origin"]},{"path":"$REPO_B","remotes":["origin"]}]}
JSON

# ---- gh shim: returns fixtures for repo-a, FAILS for repo-b, counts calls ----
BIN="$FX/bin"; mkdir -p "$BIN"
CALLS="$FX/gh-calls.txt"; : > "$CALLS"
cat > "$BIN/gh" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS"
repo=""; prev=""
for a in "\$@"; do [ "\$prev" = "--repo" ] && repo="\$a"; prev="\$a"; done
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then
  case "\$repo" in
    o/repo-a)
      cat <<'JSON'
[
 {"number":1,"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","labels":[{"name":"auto-merge"}],"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","name":"ci"}],"reviewDecision":"","headRefName":"h1","baseRefName":"main"},
 {"number":2,"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","labels":[{"name":"auto-merge"}],"statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE","name":"ci"}],"reviewDecision":"","headRefName":"h2","baseRefName":"main"},
 {"number":3,"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"UNSTABLE","labels":[{"name":"auto-merge"}],"statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE","name":"non-required-lint"}],"reviewDecision":"","headRefName":"h3","baseRefName":"main"},
 {"number":6,"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","labels":[{"name":"auto-merge"}],"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","name":"ci"}],"reviewDecision":"CHANGES_REQUESTED","headRefName":"h6","baseRefName":"main"},
 {"number":7,"state":"OPEN","isDraft":true,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","labels":[{"name":"auto-merge"}],"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","name":"ci"}],"reviewDecision":"","headRefName":"h7","baseRefName":"main"},
 {"number":90,"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","labels":[{"name":"auto-merge"}],"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","name":"ci"}],"reviewDecision":"","headRefName":"h90","baseRefName":"main"}
]
JSON
      exit 0
      ;;
    o/repo-b)
      # Simulate a network / rate-limit failure for this repo only.
      echo "gh: could not fetch (simulated failure)" >&2
      exit 1
      ;;
    *) echo "[]"; exit 0 ;;
  esac
fi
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then
  # An epic list (--label epic) is distinct from the title list (no label).
  case "\$*" in
  *"--label epic"*)
    case "\$repo" in
      o/repo-a)
        # Three epics: #10 has native sub-issues (API path below), #20 is a legacy
        # epic whose sub-issues live in a body task-list (API returns empty), and
        # #30's sub-issues API ERRORS (issue #91 AC4: the view must mark it
        # unreadable and NOT fall back to its body task-list).
        cat <<'JSON'
[
 {"number":10,"title":"Epic Alpha","body":"An epic with native sub-issues."},
 {"number":20,"title":"Epic Beta (legacy)","body":"Legacy epic\n- [x] Done thing #1\n- [ ] Pending thing #2\n- [ ] Ghost thing #999\n"},
 {"number":30,"title":"Epic Gamma (unreadable)","body":"Broken epic\n- [ ] Should-not-appear #1\n"}
]
JSON
        exit 0
        ;;
      o/repo-b)
        echo "gh: could not fetch (simulated failure)" >&2
        exit 1
        ;;
      *) echo "[]"; exit 0 ;;
    esac
    ;;
  *)
    case "\$repo" in
      o/repo-a)
        # Titles for the open issues, including a special-char title (#1) to prove
        # the JSON round-trip preserves it, and issue 4 (the no-PR blocked run).
        cat <<'JSON'
[
 {"number":1,"title":"Fix <b>bug</b> & ship ä title"},
 {"number":2,"title":"Red CI issue"},
 {"number":3,"title":"Unstable issue"},
 {"number":4,"title":"Blocked no-PR issue"},
 {"number":5,"title":"Closed-PR issue"},
 {"number":6,"title":"Changes requested issue"},
 {"number":7,"title":"Draft issue"}
]
JSON
        exit 0
        ;;
      o/repo-b)
        echo "gh: could not fetch (simulated failure)" >&2
        exit 1
        ;;
      *) echo "[]"; exit 0 ;;
    esac
    ;;
  esac
fi
# issue view <n> --json state (issue #96): the explicit per-issue state read for a
# suspected-closed no-PR issue. #8 is confirmed CLOSED; #89 simulates a read
# failure (=> unconfirmed => fail-soft). The shim prints the final --jq value.
if [ "\$1" = "issue" ] && [ "\$2" = "view" ]; then
  case "\$repo:\$3" in
    o/repo-a:8)  echo "CLOSED"; exit 0 ;;
    o/repo-a:89) echo "gh: could not read issue (simulated failure)" >&2; exit 1 ;;
    *) echo "gh: issue not found (simulated)" >&2; exit 1 ;;
  esac
fi
# Sub-issues API: repos/{owner}/{repo}/issues/{n}/sub_issues (issue #79). The
# shared resolver list_epic_children (issue #91) calls this with --paginate, so
# the path is not positional — scan for the repos/… argument (like test-epic.sh).
# repository_url is included because list_epic_children's cross-repo filter reads
# it (a real sub_issues response always carries it).
if [ "\$1" = "api" ]; then
  apipath=""
  for a in "\$@"; do case "\$a" in repos/*) [ -z "\$apipath" ] && apipath="\$a";; esac; done
  case "\$apipath" in
    repos/o/repo-a/issues/10/sub_issues)
      # Native sub-issues: #11 open, #12 closed, plus #13 in ANOTHER repo — the
      # cross-repo child must be filtered IDENTICALLY on the view side (issue #91
      # AC5), exactly as the run side drops it (scope-out).
      cat <<'JSON'
[
 {"number":11,"state":"open","title":"Alpha sub one","repository_url":"https://api.github.com/repos/o/repo-a"},
 {"number":12,"state":"closed","title":"Alpha sub two","repository_url":"https://api.github.com/repos/o/repo-a"},
 {"number":13,"state":"open","title":"Cross-repo sub","repository_url":"https://api.github.com/repos/o/other-repo"}
]
JSON
      exit 0
      ;;
    repos/o/repo-a/issues/20/sub_issues)
      # Legacy epic: no native sub-issues => caller falls back to the task list.
      echo "[]"
      exit 0
      ;;
    repos/o/repo-a/issues/30/sub_issues)
      # Unreadable native graph: the API errors (issue #91 AC4, view fail-closed).
      echo "gh: sub_issues fetch failed (simulated)" >&2
      exit 1
      ;;
    *) echo "[]"; exit 0 ;;
  esac
fi
exit 0
SHIM
chmod +x "$BIN/gh"

CACHE="$FX/cache.json"
run_status() {
  HOME="$FX/home" PATH="$BIN:$PATH" \
    RUN_ISSUES_WATCHLIST="$WL" RUN_ISSUES_STATUS_CACHE_FILE="$CACHE" \
    bash "$STATUS" "$@"
}
# grep -c prints "0" even on no match (then exits 1); swallow that exit so the
# count is a single clean integer.
pr_list_calls() { grep -c 'pr list' "$CALLS" 2>/dev/null || true; }
# Title-list calls only (exclude the epic list, which also uses `issue list`).
issue_list_calls() { grep 'issue list' "$CALLS" 2>/dev/null | grep -vc 'label epic' || true; }
epic_list_calls() { grep -c 'label epic' "$CALLS" 2>/dev/null || true; }
sub_issue_calls() { grep -c 'sub_issues' "$CALLS" 2>/dev/null || true; }
issue_view_calls() { grep -c 'issue view' "$CALLS" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# 1) First --github run: fetches, enriches repo-a, fails repo-b.
# ---------------------------------------------------------------------------
: > "$CALLS"
OUT="$FX/out1.json"
run_status --json --github > "$OUT" 2>"$FX/err1.txt"; rc=$?
check "exit 0 on first --github run" "$rc" "0"
jq -e . "$OUT" >/dev/null 2>&1 && ok "output is valid JSON" || bad "output not valid JSON"

check "enrichment.mode github" "$(jq -r '.enrichment.mode' "$OUT")" "github"
check "repos_enriched == 1" "$(jq -r '.enrichment.repos_enriched' "$OUT")" "1"
check "repos_failed == [o/repo-b]" "$(jq -c '.enrichment.repos_failed' "$OUT")" '["o/repo-b"]'
check "enrichment.fetched_at is set" "$(jq -r '.enrichment.fetched_at != null' "$OUT")" "true"
check "enrichment.cache_age_seconds is a number" "$(jq -r '.enrichment.cache_age_seconds | type' "$OUT")" "number"

# gh pr list called ONCE per owner/repo (repo-a + repo-b = 2), not per run.
check "gh pr list called once per owner/repo (2)" "$(pr_list_calls)" "2"
# gh issue list called ONCE for repo-a; repo-b fails the PR fetch first so its
# issue titles are never fetched (a failed repo gets no enrichment at all).
check "gh issue list called once (repo-a only)" "$(issue_list_calls)" "1"

# by-issue lookups.
gi() { jq -c --argjson n "$1" '.runs[] | select(.issue_number==$n)' "$OUT"; }

# #1 confirmed OPEN => confidence bumped low->high; class stays pr_in_flight.
check "#1 github.pr_state OPEN"      "$(gi 1 | jq -r '.github.pr_state')" "OPEN"
check "#1 confidence bumped to high" "$(gi 1 | jq -r '.class_confidence')" "high"
check "#1 class pr_in_flight"        "$(gi 1 | jq -r '.class')" "pr_in_flight"
check "#1 github.ci GREEN"           "$(gi 1 | jq -r '.github.ci')" "GREEN"
check "#1 verdict from pr_decide"    "$(gi 1 | jq -r '.github.pr_decide_verdict')" "MERGE"
# #1 issue title joined into the github sub-object, special chars preserved
# verbatim (JSON round-trip), and NOT leaked to a top-level field (provenance).
check "#1 github.issue_title set"    "$(gi 1 | jq -r '.github.issue_title')" 'Fix <b>bug</b> & ship ä title'
check "#1 no top-level issue_title"  "$(gi 1 | jq -r 'has("issue_title")')" "false"

# #4 issue but no PR => issue-only github object: title present, pr_state null,
# no chips, and the LOCAL class is untouched (enrichment adds a title, not a
# verdict). This is what puts titles on attention/running rows, not just PR rows.
check "#4 github not null (issue-only)" "$(gi 4 | jq -r '.github != null')" "true"
check "#4 github.pr_state null"         "$(gi 4 | jq -r '.github.pr_state')" "null"
check "#4 github.ci null (no chips)"    "$(gi 4 | jq -r '.github.ci')" "null"
check "#4 github.issue_title set"       "$(gi 4 | jq -r '.github.issue_title')" "Blocked no-PR issue"
check "#4 class attention (untouched)"  "$(gi 4 | jq -r '.class')" "attention"
check "#4 reason blocked (untouched)"   "$(gi 4 | jq -r '.class_reason')" "blocked"
check "#4 confidence high (untouched)"  "$(gi 4 | jq -r '.class_confidence')" "high"

# ---- issue #96: no-PR run + confirmed-closed issue => cleanup/issue_closed ----
# #8: no PR, issue absent from the open map, explicit state read confirms CLOSED
# => cleanup/issue_closed/high (was attention/blocked, the dashboard's busiest
# class, forever).
check "#8 github.pr_state null (no PR)" "$(gi 8 | jq -r '.github.pr_state')" "null"
check "#8 github.issue_state CLOSED"    "$(gi 8 | jq -r '.github.issue_state')" "CLOSED"
check "#8 class cleanup"                "$(gi 8 | jq -r '.class')" "cleanup"
check "#8 reason issue_closed"          "$(gi 8 | jq -r '.class_reason')" "issue_closed"
check "#8 confidence high"              "$(gi 8 | jq -r '.class_confidence')" "high"

# #89: fail-soft — the issue-state read fails, so absence from the open map stays
# an unproven hint and the LOCAL class stands (attention/blocked). A network error
# must never manufacture a cleanup.
check "#89 github not null (issue-only)" "$(gi 89 | jq -r '.github != null')" "true"
check "#89 github.issue_state null"      "$(gi 89 | jq -r '.github.issue_state')" "null"
check "#89 class attention (fail-soft)"  "$(gi 89 | jq -r '.class')" "attention"
check "#89 reason blocked (fail-soft)"   "$(gi 89 | jq -r '.class_reason')" "blocked"

# #90: an OPEN PR whose issue is closed — the PR state wins (pr_not_open owns the
# closed-PR case), so the run stays pr_in_flight (confidence confirmed high) and is
# NEVER reclassified issue_closed. Its reason is the local pr_state_unknown (no
# pr_classified event on disk), exactly like #1 — the OPEN branch bumps confidence,
# not the reason. The point: an open PR is never touched by the issue_closed path.
check "#90 github.pr_state OPEN"        "$(gi 90 | jq -r '.github.pr_state')" "OPEN"
check "#90 class pr_in_flight"          "$(gi 90 | jq -r '.class')" "pr_in_flight"
check "#90 confidence high (PR confirmed)" "$(gi 90 | jq -r '.class_confidence')" "high"
check "#90 reason not issue_closed"     "$(gi 90 | jq -r '.class_reason')" "pr_state_unknown"

# Call count (criterion 6): the state read runs ONCE per suspected-closed no-PR
# issue (#8 + #89 = 2), never for #90 (it has a PR) nor #4 (present in the open
# map). repo-b failed the PR fetch first, so it is never probed for issue state.
check "gh issue view once per suspected-closed no-PR issue (2)" "$(issue_view_calls)" "2"

# #2 required check red => attention/pr_ci_red.
check "#2 class attention"        "$(gi 2 | jq -r '.class')" "attention"
check "#2 reason pr_ci_red"       "$(gi 2 | jq -r '.class_reason')" "pr_ci_red"
check "#2 github.ci RED"          "$(gi 2 | jq -r '.github.ci')" "RED"

# #3 UNSTABLE + non-required red => ci RED but NOT pr_ci_red (same edge as pr_decide).
check "#3 github.ci RED"                 "$(gi 3 | jq -r '.github.ci')" "RED"
check "#3 merge_state UNSTABLE"          "$(gi 3 | jq -r '.github.merge_state_status')" "UNSTABLE"
check "#3 reason is NOT pr_ci_red"       "$(gi 3 | jq -r '.class_reason != "pr_ci_red"')" "true"
check "#3 confidence high (confirmed)"   "$(gi 3 | jq -r '.class_confidence')" "high"

# #5 not in the open set => NOT_OPEN => cleanup/pr_not_open.
check "#5 github.pr_state NOT_OPEN" "$(gi 5 | jq -r '.github.pr_state')" "NOT_OPEN"
check "#5 class cleanup"            "$(gi 5 | jq -r '.class')" "cleanup"
check "#5 reason pr_not_open"       "$(gi 5 | jq -r '.class_reason')" "pr_not_open"

# #6 review CHANGES_REQUESTED (green CI) => attention/pr_changes_requested.
check "#6 review_decision CHANGES_REQUESTED" "$(gi 6 | jq -r '.github.review_decision')" "CHANGES_REQUESTED"
check "#6 class attention"                   "$(gi 6 | jq -r '.class')" "attention"
check "#6 reason pr_changes_requested"       "$(gi 6 | jq -r '.class_reason')" "pr_changes_requested"

# #7 draft PR whose run is older than 7d => attention/pr_draft_stale.
check "#7 github.is_draft true"      "$(gi 7 | jq -r '.github.is_draft')" "true"
check "#7 class attention"           "$(gi 7 | jq -r '.class')" "attention"
check "#7 reason pr_draft_stale"     "$(gi 7 | jq -r '.class_reason')" "pr_draft_stale"

# #9 repo-b failed => github null + low confidence (local classification untouched).
check "#9 github null (repo failed)" "$(gi 9 | jq -r '.github')" "null"
check "#9 confidence low"            "$(gi 9 | jq -r '.class_confidence')" "low"

# ---- epic collection (issue #79, shared resolver issue #91) ---------------
# Epics are fetched ONCE per repo: repo-a succeeds (1 epic-list call, 3 sub-issue
# API calls — one per epic #10/#20/#30, i.e. ONE per epic, no per-child reads),
# repo-b fails the PR fetch first so it is never queried for epics.
check "epic list called once (repo-a)" "$(epic_list_calls)" "1"
check "sub-issue API called once per epic (3)" "$(sub_issue_calls)" "3"
check "epics[] has 3 entries" "$(jq '.epics | length' "$OUT")" "3"

# by-epic-number lookup.
ge() { jq -c --argjson n "$1" '.epics[] | select(.epic_number==$n)' "$OUT"; }

# Epic #10: native sub-issues => source "sub_issues", verbatim {number,state}.
check "epic #10 repo_slug"       "$(ge 10 | jq -r '.repo_slug')" "repo-a"
check "epic #10 title"           "$(ge 10 | jq -r '.epic_title')" "Epic Alpha"
check "epic #10 url"             "$(ge 10 | jq -r '.epic_url')" "https://github.com/o/repo-a/issues/10"
check "epic #10 source sub_issues" "$(ge 10 | jq -r '.source')" "sub_issues"
check "epic #10 sub_issues count" "$(ge 10 | jq '.sub_issues | length')" "2"
check "epic #10 sub #11 open"    "$(ge 10 | jq -r '.sub_issues[] | select(.number==11) | .state')" "open"
check "epic #10 sub #12 closed"  "$(ge 10 | jq -r '.sub_issues[] | select(.number==12) | .state')" "closed"
# AC5: the cross-repo child #13 is excluded on the view side, just as on the run
# side — the same list_epic_children filter, so the two can never disagree.
check "epic #10 cross-repo #13 excluded (AC5)" \
  "$(ge 10 | jq '[.sub_issues[] | select(.number==13)] | length')" "0"
# sub_issues carry ONLY number+state (no title/body leak from the API payload).
check "epic #10 sub keys number+state" \
  "$(ge 10 | jq -r '.sub_issues[0] | keys | sort | join(",")')" "number,state"

# Epic #20: no native sub-issues => task-list fallback (source "task_list"). The
# open-issue map is authoritative for state (#1 is checked but IS open => open),
# and a reference to a non-existent issue (#999, unchecked, not in the map) is
# skipped silently (spec edge).
check "epic #20 source task_list" "$(ge 20 | jq -r '.source')" "task_list"
check "epic #20 sub_issues count (ghost skipped)" "$(ge 20 | jq '.sub_issues | length')" "2"
check "epic #20 sub #1 open (map authoritative over checkbox)" \
  "$(ge 20 | jq -r '.sub_issues[] | select(.number==1) | .state')" "open"
check "epic #20 sub #2 open" \
  "$(ge 20 | jq -r '.sub_issues[] | select(.number==2) | .state')" "open"
check "epic #20 ghost #999 absent" \
  "$(ge 20 | jq '[.sub_issues[] | select(.number==999)] | length')" "0"

# Epic #30: the native sub-issues API errors. FAIL-CLOSED (issue #91 AC4): the
# view marks it source "unreadable" with an EMPTY sub_issues set and does NOT
# fall back to its body task-list (which would have drawn false progress off a
# child #1 that the fallback would otherwise have picked up).
check "epic #30 source unreadable (fail-closed)" "$(ge 30 | jq -r '.source')" "unreadable"
check "epic #30 sub_issues empty (no false progress)" "$(ge 30 | jq '.sub_issues | length')" "0"
check "epic #30 did NOT fall back to task-list #1" \
  "$(ge 30 | jq '[.sub_issues[] | select(.number==1)] | length')" "0"

# ---------------------------------------------------------------------------
# 2) Cache hit: rerun within TTL => the shim is NOT called for repo-a.
#    (repo-b failed and was not cached, so it is retried — 1 call, not 2.)
# ---------------------------------------------------------------------------
: > "$CALLS"
run_status --json --github > "$FX/out2.json" 2>/dev/null
check "cache hit: repo-a NOT refetched (repo-b retried => 1 call)" "$(pr_list_calls)" "1"
# Issue titles come from the SAME cache entry: repo-a is a cache hit (0 issue
# calls), repo-b fails the PR fetch again so its issue titles are never fetched.
check "cache hit: no issue list calls (repo-a cached, repo-b fails first)" "$(issue_list_calls)" "0"
check "cache hit: #1 still enriched from cache" \
  "$(jq -r '.runs[] | select(.issue_number==1) | .github.pr_state' "$FX/out2.json")" "OPEN"
check "cache hit: #1 title served from cache" \
  "$(jq -r '.runs[] | select(.issue_number==1) | .github.issue_title' "$FX/out2.json")" 'Fix <b>bug</b> & ship ä title'
# Epics are cached fully resolved: a cache hit makes NO epic-list and NO
# sub-issue API call, yet epics[] is still served (issue #79).
check "cache hit: no epic list call" "$(epic_list_calls)" "0"
check "cache hit: no sub-issue API call" "$(sub_issue_calls)" "0"
check "cache hit: epics[] still served (3)" "$(jq '.epics | length' "$FX/out2.json")" "3"
# issue-state reads are cached in the SAME owner entry (issue #96): a repo-a cache
# hit makes NO issue-view call, yet #8 is still classified cleanup/issue_closed.
check "cache hit: no issue view call (repo-a cached)" "$(issue_view_calls)" "0"
check "cache hit: #8 still issue_closed from cache" \
  "$(jq -r '.runs[] | select(.issue_number==8) | .class_reason' "$FX/out2.json")" "issue_closed"
check "cache hit: cache_age_seconds >= 0" \
  "$(jq -r '.enrichment.cache_age_seconds >= 0' "$FX/out2.json")" "true"

# ---------------------------------------------------------------------------
# 3) Stale cache: --cache-ttl 0 forces a refetch of repo-a too.
# ---------------------------------------------------------------------------
: > "$CALLS"
run_status --json --github --cache-ttl 0 > /dev/null 2>&1
check "stale cache (--cache-ttl 0) refetches both repos (2)" "$(pr_list_calls)" "2"

# ---------------------------------------------------------------------------
# 4) --no-cache also refetches.
# ---------------------------------------------------------------------------
: > "$CALLS"
run_status --json --github --no-cache > /dev/null 2>&1
check "--no-cache refetches (2)" "$(pr_list_calls)" "2"

# ---------------------------------------------------------------------------
# 5) Without --github: behaviour is unchanged — github null, gh never called.
# ---------------------------------------------------------------------------
: > "$CALLS"
run_status --json > "$FX/out_local.json" 2>/dev/null
check "local mode: gh never called" "$(pr_list_calls)" "0"
check "local mode: enrichment.mode local" "$(jq -r '.enrichment.mode' "$FX/out_local.json")" "local"
check "local mode: every github null" \
  "$(jq '[.runs[] | select(.github != null)] | length' "$FX/out_local.json")" "0"

echo "----------------------------------------"
echo "status-github: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
