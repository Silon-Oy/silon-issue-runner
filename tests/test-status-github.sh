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
# Epic list: REST (issue #133). `--label` is what routes gh's issue list through
# the GraphQL search connection, which was blocked for 27 hours on 2026-08-28/29
# while REST answered normally, so this one call had to move. The shim emits the
# POST-jq shape the real --jq projects.
if [ "\$1" = "api" ] && case "\$*" in *"labels=epic"*) true ;; *) false ;; esac; then
  repo=\$(printf '%s' "\$2" | sed -n 's|^repos/\\([^/]*/[^/]*\\)/issues?.*|\\1|p')
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
fi
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then
    case "\$repo" in
      o/repo-a)
        # Titles + labels for the open issues (issue #106 added labels). #1 has a
        # special-char title (JSON round-trip) and ONLY a non-whitelisted label
        # (auto-merge => issue_labels []). #4 (the no-PR blocked run) carries
        # needs-human PLUS a non-whitelisted label (wip => filtered out, proving the
        # whitelist). The rest carry no labels (=> issue_labels []).
        cat <<'JSON'
[
 {"number":1,"title":"Fix <b>bug</b> & ship ä title","labels":[{"name":"auto-merge"}]},
 {"number":2,"title":"Red CI issue","labels":[]},
 {"number":3,"title":"Unstable issue","labels":[]},
 {"number":4,"title":"Blocked no-PR issue","labels":[{"name":"needs-human"},{"name":"wip"}]},
 {"number":5,"title":"Closed-PR issue","labels":[]},
 {"number":6,"title":"Changes requested issue","labels":[]},
 {"number":7,"title":"Draft issue","labels":[]}
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
fi
# issue view <n> --json state,stateReason,title (issue #96 read #103): the explicit
# per-issue detail read for an issue ABSENT from the open list. #8 is CLOSED as
# NOT_PLANNED (with a title only reachable via this read — the open list is
# --state open); #90 is CLOSED as COMPLETED (an open PR whose issue closed); #89
# simulates a read failure (=> unconfirmed => fail-soft). The shim prints the JSON
# object the caller's jq consumes.
if [ "\$1" = "issue" ] && [ "\$2" = "view" ]; then
  case "\$repo:\$3" in
    o/repo-a:8)  echo '{"state":"CLOSED","stateReason":"NOT_PLANNED","title":"Closed not-planned issue","labels":[{"name":"auto-clean"},{"name":"needs-human"},{"name":"bug"}]}'; exit 0 ;;
    o/repo-a:90) echo '{"state":"CLOSED","stateReason":"COMPLETED","title":"Closed-issue open-PR","labels":[{"name":"auto-clean-skipped"}]}'; exit 0 ;;
    o/repo-a:89) echo "gh: could not read issue (simulated failure)" >&2; exit 1 ;;
    # #91 — a NEW closed issue introduced only by the carry-forward test (#125);
    # untouched by earlier tests because no run references it until then.
    o/repo-a:91) echo '{"state":"CLOSED","stateReason":"COMPLETED","title":"Newly closed issue","labels":[]}'; exit 0 ;;
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
      # cross-repo child is now SUPPORTED (issue #92) and resolved IDENTICALLY on
      # the view side (issue #91 AC5), carrying its own repo (o/other-repo).
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
# The epic list moved to REST (issue #133), so `issue list` is now the title
# fetch alone and the epic call is counted by its REST path.
issue_list_calls() { grep -c 'issue list' "$CALLS" 2>/dev/null || true; }
epic_list_calls() { grep -c 'labels=epic' "$CALLS" 2>/dev/null || true; }
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
check "#4 github.issue_state OPEN (in map, no read)" "$(gi 4 | jq -r '.github.issue_state')" "OPEN"
check "#4 class attention (untouched)"  "$(gi 4 | jq -r '.class')" "attention"
check "#4 reason blocked (untouched)"   "$(gi 4 | jq -r '.class_reason')" "blocked"
check "#4 confidence high (untouched)"  "$(gi 4 | jq -r '.class_confidence')" "high"

# ---- issue #96: no-PR run + confirmed-closed issue => cleanup/issue_closed ----
# #8: no PR, issue absent from the open map, explicit state read confirms CLOSED
# => cleanup/issue_closed/high (was attention/blocked, the dashboard's busiest
# class, forever).
check "#8 github.pr_state null (no PR)" "$(gi 8 | jq -r '.github.pr_state')" "null"
check "#8 github.issue_state CLOSED"    "$(gi 8 | jq -r '.github.issue_state')" "CLOSED"
# issue #103: the closed issue's stateReason + title come from the SAME per-issue
# read (the open list is --state open, so the title is otherwise null).
check "#8 github.issue_state_reason NOT_PLANNED" "$(gi 8 | jq -r '.github.issue_state_reason')" "NOT_PLANNED"
check "#8 github.issue_title (closed, from detail read)" "$(gi 8 | jq -r '.github.issue_title')" "Closed not-planned issue"
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
# issue #103 AC1: issue_state is carried on PR rows too — #90's issue is CLOSED, so
# the field is populated even though the OPEN-PR branch owns classification (the
# reclassifier's OPEN branch wins before the issue_state elif => view-only here).
check "#90 github.issue_state CLOSED (AC1: PR row too)" "$(gi 90 | jq -r '.github.issue_state')" "CLOSED"
check "#90 github.issue_state_reason COMPLETED" "$(gi 90 | jq -r '.github.issue_state_reason')" "COMPLETED"

# #1 (open PR, OPEN issue in the map) carries issue_state OPEN with no extra read
# (the open list already proves it) — AC1: every enriched run gets issue_state.
check "#1 github.issue_state OPEN (from open map, no read)" "$(gi 1 | jq -r '.github.issue_state')" "OPEN"
check "#1 github.issue_state_reason null (open)" "$(gi 1 | jq -r '.github.issue_state_reason')" "null"

# ---- issue #106: issue state-labels on the github sub-object -----------------
# AC1: every enriched run's github object carries issue_labels — a WHITELISTED
# array of only {auto-clean, auto-clean-skipped, needs-human}. Open-issue labels
# come from the open list (with title), closed-issue labels from the detail read
# (the SAME read that yields the closed title/state), so a closed issue's lingering
# auto-clean is visible too (edge case). Non-whitelisted labels are filtered out.

# #1: open issue, only a non-whitelisted label (auto-merge) => [] (filtered).
check "#1 github.issue_labels is []" "$(gi 1 | jq -c '.github.issue_labels')" "[]"
# #4: no-PR blocked run, needs-human + wip => ["needs-human"] (wip filtered out).
check "#4 github.issue_labels [needs-human]" "$(gi 4 | jq -c '.github.issue_labels')" '["needs-human"]'
# #8: closed issue via detail read, auto-clean + needs-human + bug => the two
# whitelisted labels, bug filtered out (a closed run's cleanup queue IS visible).
check "#8 issue_labels has auto-clean" \
  "$(gi 8 | jq -r '.github.issue_labels | index("auto-clean") != null')" "true"
check "#8 issue_labels has needs-human" \
  "$(gi 8 | jq -r '.github.issue_labels | index("needs-human") != null')" "true"
check "#8 issue_labels drops non-whitelisted bug" \
  "$(gi 8 | jq -r '.github.issue_labels | index("bug")')" "null"
# #90: OPEN PR whose CLOSED issue carries auto-clean-skipped — a PR row carries
# issue_labels too (AC1), from the same detail read as its issue_state.
check "#90 issue_labels [auto-clean-skipped]" "$(gi 90 | jq -c '.github.issue_labels')" '["auto-clean-skipped"]'
# #89: detail read FAILED => fail-soft, issue_labels defaults to [] (AC6: an error
# drops the chips, never manufactures a label).
check "#89 issue_labels [] (fail-soft)" "$(gi 89 | jq -c '.github.issue_labels')" "[]"
# Every enriched run carries issue_labels as an ARRAY (never null / never the full
# label set) — the schema invariant the render side relies on.
check "every enriched run issue_labels is an array" \
  "$(jq -c '[.runs[] | select(.github != null) | .github.issue_labels | type] | unique' "$OUT")" '["array"]'

# Call count (criterion 6/AC5): the detail read runs ONCE per issue ABSENT from the
# open map (#8 + #89 + #90 = 3), deduped across runs, never for issues present in
# the map (#1–#7). repo-b failed the PR fetch first, so it is never probed.
check "gh issue view once per absent issue (3)" "$(issue_view_calls)" "3"

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
check "epic #10 sub_issues count (incl cross-repo)" "$(ge 10 | jq '.sub_issues | length')" "3"
check "epic #10 sub #11 open"    "$(ge 10 | jq -r '.sub_issues[] | select(.number==11) | .state')" "open"
check "epic #10 sub #12 closed"  "$(ge 10 | jq -r '.sub_issues[] | select(.number==12) | .state')" "closed"
# AC5 (issue #92): the cross-repo child #13 is now INCLUDED and carries its own
# repo (o/other-repo), resolved IDENTICALLY on the view and run sides.
check "epic #10 cross-repo #13 included (AC5, #92)" \
  "$(ge 10 | jq '[.sub_issues[] | select(.number==13)] | length')" "1"
check "epic #10 #13 repo o/other-repo" \
  "$(ge 10 | jq -r '.sub_issues[] | select(.number==13) | .repo')" "o/other-repo"
check "epic #10 same-repo #11 repo o/repo-a" \
  "$(ge 10 | jq -r '.sub_issues[] | select(.number==11) | .repo')" "o/repo-a"
# sub_issues carry number+state+repo (no title/body leak) plus repo_slug, which
# status.sh injects at emit for the view's local grouping (issue #92).
check "epic #10 sub keys number+repo+repo_slug+state" \
  "$(ge 10 | jq -r '.sub_issues[0] | keys | sort | join(",")')" "number,repo,repo_slug,state"
# A same-repo child's repo_slug is the epic's slug; a cross-repo child with no
# local run falls back to the repo basename (issue #92).
check "epic #10 #11 repo_slug == epic slug (repo-a)" \
  "$(ge 10 | jq -r '.sub_issues[] | select(.number==11) | .repo_slug')" "repo-a"
check "epic #10 #13 repo_slug basename fallback (other-repo)" \
  "$(ge 10 | jq -r '.sub_issues[] | select(.number==13) | .repo_slug')" "other-repo"

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
# issue #106: labels ride the SAME cache entry — a repo-a cache hit serves #8's
# auto-clean from cache with no gh call (the raw issues array + detail reads carry
# labels, both cached).
check "cache hit: #8 issue_labels served from cache (auto-clean)" \
  "$(jq -r '.runs[] | select(.issue_number==8) | .github.issue_labels | index("auto-clean") != null' "$FX/out2.json")" "true"
check "cache hit: cache_age_seconds >= 0" \
  "$(jq -r '.enrichment.cache_age_seconds >= 0' "$FX/out2.json")" "true"

# ---------------------------------------------------------------------------
# 3) Stale cache: --cache-ttl 0 forces a refetch of repo-a too.
# ---------------------------------------------------------------------------
: > "$CALLS"
run_status --json --github --cache-ttl 0 > /dev/null 2>&1
check "stale cache (--cache-ttl 0) refetches both repos (2)" "$(pr_list_calls)" "2"

# ---------------------------------------------------------------------------
# 3b) Boundary: --cache-ttl 0 refetches even when the cache entry was written the
#     SAME second (age == 0). This is the exact coincidence that made this test
#     flaky (issue #147): status.sh's owner cache used inclusive `-le` (age<=TTL,
#     so age==0 is a HIT at TTL 0) while the detail carry-forward used exclusive
#     `< $ttl`. Two TTL comparisons, two answers at the boundary. With both
#     exclusive, TTL 0 disables the owner cache regardless of whether the clock
#     ticked between the write and the read — same semantics as DETAIL_TTL=0 on
#     the carry-forward path. Rebuild a fresh cache, stamp every entry to the
#     current second, then assert TTL 0 still refetches both repos. Under the old
#     `-le` this was a same-second cache HIT (0 refetches); under `-lt` it is a
#     deterministic MISS.
: > "$CALLS"
run_status --json --github --no-cache > /dev/null 2>&1   # rebuild a fresh cache
NOW_SEC="$(date -u +%s)"
SAME_SEC="$(jq -c --argjson now "$NOW_SEC" 'with_entries(.value.fetched_epoch = $now)' "$CACHE" 2>/dev/null || true)"
[ -n "$SAME_SEC" ] && printf '%s' "$SAME_SEC" > "$CACHE"
: > "$CALLS"
run_status --json --github --cache-ttl 0 > /dev/null 2>&1
check "boundary: --cache-ttl 0 refetches a same-second entry (age==0 is a MISS)" "$(pr_list_calls)" "2"

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

# ---------------------------------------------------------------------------
# 6) Carry-forward of resolved per-issue details across cache misses (issue #125).
#    A closed issue's detail (state/reason/title/labels) is terminal, so it is
#    carried across a cache MISS instead of re-read. Steady state: 318 -> ~0 calls.
# ---------------------------------------------------------------------------
# Count `gh issue view <n>` calls for ONE issue (trailing space disambiguates
# 8 from 89). The shim logs "$*", so a view call is "issue view <n> --repo …".
iv_calls() { grep -c "issue view $1 " "$CALLS" 2>/dev/null || true; }

# Re-establish a known-fresh cache: details for #8 and #90 (closed, absent from
# the open list) are resolved and cached; #89's read fails and is never cached.
: > "$CALLS"
run_status --json --github --no-cache > /dev/null 2>&1

# 6a) Main cache TTL expires (--cache-ttl 0) but the detail TTL has NOT: the PR/
#     issue/epic lists are refetched, yet the carried details are NOT re-read.
: > "$CALLS"
run_status --json --github --cache-ttl 0 > "$FX/out_cf.json" 2>/dev/null
check "carry-forward: PR lists refetched (main TTL 0 => 2)" "$(pr_list_calls)" "2"
check "carry-forward: #8 detail NOT re-read (carried across miss)"  "$(iv_calls 8)"  "0"
check "carry-forward: #90 detail NOT re-read (carried across miss)" "$(iv_calls 90)" "0"
# A failed read is not negatively cached (spec edge), so #89 is legitimately
# retried — the only detail call on an unchanged issue set.
check "carry-forward: #89 (failed read) IS retried" "$(iv_calls 89)" "1"
check "carry-forward: total detail calls == just the failing #89" "$(issue_view_calls)" "1"
# The carried detail still drives classification: #8 stays cleanup/issue_closed.
check "carry-forward: #8 still issue_closed from carried detail" \
  "$(jq -r '.runs[] | select(.issue_number==8) | .class_reason' "$FX/out_cf.json")" "issue_closed"

# 6b) A NEW closed issue in the set costs EXACTLY ONE new detail read; the carried
#     ones are still not re-read.
mkdir -p "$RUNS_A/r91"
cat > "$RUNS_A/r91/run.json" <<JSON
{"run_id":"r91","repo":"$REPO_A","issue_number":91,"status":"blocked","started_at":"2026-08-01T10:00:00Z","finished_at":"2026-08-01T10:05:00Z","host":"$HOST","current_state":"S6_CycleReview","blocked_reason":"cycle_review_blocker","remote":"origin","repo_slug":"repo-a"}
JSON
: > "$CALLS"
run_status --json --github --cache-ttl 0 > "$FX/out_new.json" 2>/dev/null
check "carry-forward: new closed #91 => exactly one new detail read" "$(iv_calls 91)" "1"
check "carry-forward: carried #8 still NOT re-read with new issue present" "$(iv_calls 8)" "0"
check "carry-forward: #91 classified issue_closed" \
  "$(jq -r '.runs[] | select(.issue_number==91) | .class_reason' "$FX/out_new.json")" "issue_closed"

# 6c) Reopened issue: a detail cached as CLOSED for an issue that now appears in
#     the FRESH open list must be dropped (spec decision 3), so issue_state is
#     OPEN — not the masked CLOSED — and it is NOT re-read (the open map proves
#     it open). Seed the cache with a stale CLOSED detail for #4 (a run that IS in
#     the open list), then force a cache miss.
SEED_NOW="$(date -u +%s)"
SEEDED="$(jq -c --arg k "o/repo-a" --argjson now "$SEED_NOW" '
  .[$k].issue_details["4"] = {state:"CLOSED",state_reason:"COMPLETED",title:"Was closed",labels:[],fetched_epoch:$now}
' "$CACHE" 2>/dev/null || true)"
[ -n "$SEEDED" ] && printf '%s' "$SEEDED" > "$CACHE"
: > "$CALLS"
run_status --json --github --cache-ttl 0 > "$FX/out_reopen.json" 2>/dev/null
check "reopened: #4 issue_state OPEN (carried CLOSED dropped, openmap wins)" \
  "$(jq -r '.runs[] | select(.issue_number==4) | .github.issue_state' "$FX/out_reopen.json")" "OPEN"
check "reopened: #4 NOT re-read (open map proves it open, no detail call)" "$(iv_calls 4)" "0"

# 6d) Detail-TTL expiry: with RUN_ISSUES_STATUS_DETAIL_TTL=0 the carried details
#     are all considered stale, so #8/#90 ARE re-read — the carry-forward has a
#     bounded exit, it is not permanent.
: > "$CALLS"
RUN_ISSUES_STATUS_DETAIL_TTL=0 run_status --json --github --cache-ttl 0 > /dev/null 2>&1
check "detail-TTL 0: #8 re-read (bounded exit from carry-forward)"  "$(iv_calls 8)"  "1"
check "detail-TTL 0: #90 re-read" "$(iv_calls 90)" "1"

# 6e) #96's legacy guard is intact: a FRESH cache entry that PRE-DATES the
#     issue_details key still forces a full refetch (a closed issue is re-resolved,
#     not served as {} on the cache-hit path). Strip issue_details from the cached
#     repo-a entry and keep it fresh; the hit path must fall through to a fetch.
run_status --json --github --no-cache > /dev/null 2>&1  # rebuild a fresh cache
LEGACY="$(jq -c --arg k "o/repo-a" 'if .[$k] then .[$k] |= del(.issue_details) else . end' "$CACHE" 2>/dev/null || true)"
[ -n "$LEGACY" ] && printf '%s' "$LEGACY" > "$CACHE"
: > "$CALLS"
run_status --json --github > "$FX/out_legacy.json" 2>/dev/null
check "legacy guard: issue_details-less fresh entry forces refetch (pr list 2)" \
  "$(pr_list_calls)" "2"
check "legacy guard: #8 still issue_closed after forced re-resolve" \
  "$(jq -r '.runs[] | select(.issue_number==8) | .class_reason' "$FX/out_legacy.json")" "issue_closed"

echo "----------------------------------------"
echo "status-github: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
