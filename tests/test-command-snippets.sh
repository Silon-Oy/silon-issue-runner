#!/usr/bin/env bash
# test-command-snippets.sh — shell snippets in the command markdown must survive
# the way Claude Code actually runs them.
#
# Two failures, both silent, both reported repeatedly from real sessions:
#
#   1. Positional parameters in a command that takes arguments. Claude Code
#      substitutes the numbered positional placeholders in a command body with
#      the words of the user's argument BEFORE the snippet reaches bash. A
#      function written with them rendered as `--arg t "käytettävyyskierros:"
#      --rawfile b "7"`, so every issue got the same wrong title and jq read a
#      file named after a word of the description.
#   2. Bash-only snippets run in zsh. The Bash tool runs the user's login shell,
#      zsh on macOS, where `read -r -a` dies with `bad option: -a` — and
#      lib/poller-config.sh still returns the built-in default label, so the
#      wrong label looks like a successful resolution. The commands now say to
#      run every block in bash, and each block that breaks in zsh starts with a
#      guard that turns the silent failure into a loud one.
#
# Cases:
#   (1) no command that takes an argument contains a positional parameter
#   (2) every new-issue/new-epic block that sources the lib or uses read -a
#       starts with the bash guard
#   (3) the guard passes in bash and stops the block in zsh (skipped without zsh)
#   (4) both commands carry the run-in-bash instruction
#
# Run: bash tests/test-command-snippets.sh   (exit 0 = all pass)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CMD_DIR="$ROOT/commands/issue-runner"
NEW_ISSUE="$CMD_DIR/new-issue.md"
NEW_EPIC="$CMD_DIR/new-epic.md"

FAIL=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAIL=1; }

GUARD_PREFIX='[ -n "${BASH_VERSION:-}" ] ||'

# ------------------------------------------------------------------- case 1
for f in "$CMD_DIR"/*.md; do
  b=$(basename "$f")
  hint=$(awk '/^---$/ { n++; next } n == 1 && /^argument-hint:/ { print; exit }' "$f")
  case "$hint" in
    ''|*'(ei argumentteja)'*) continue ;;
  esac
  hits=$(grep -nE '\$\{?[0-9]' "$f" || true)
  if [ -n "$hits" ]; then
    bad "case1 $b takes an argument but contains positional parameters:"
    printf '        %s\n' "$hits"
  else
    ok "case1 $b has no positional parameters"
  fi
done

# ------------------------------------------------------------------- case 2
for f in "$NEW_ISSUE" "$NEW_EPIC"; do
  b=$(basename "$f")
  # Print "<line>\t<first body line>" for every bash fence needing bash.
  needing=$(awk '
    /^```bash$/ { inb = 1; start = NR; first = ""; buf = ""; next }
    /^```$/ && inb {
      if (buf ~ /read -r -a/ || buf ~ /poller-config\.sh/) print start "\t" first
      inb = 0; next
    }
    inb { if (first == "") first = $0; buf = buf $0 "\n" }
  ' "$f")
  if [ -z "$needing" ]; then
    bad "case2 $b: found no bash-only block (extraction broken?)"
    continue
  fi
  while IFS=$'\t' read -r line first; do
    case "$first" in
      "$GUARD_PREFIX"*) ok "case2 $b block at line $line starts with the bash guard" ;;
      *)                bad "case2 $b block at line $line needs bash but has no guard" ;;
    esac
  done <<<"$needing"
done

# ------------------------------------------------------------------- case 3
guard=$(grep -m1 -F "$GUARD_PREFIX" "$NEW_ISSUE")
if [ -z "$guard" ]; then
  bad "case3 no guard line found in new-issue.md"
else
  out=$(bash -c "$guard"$'\necho reached' 2>&1)
  [ "$out" = "reached" ] && ok "case3 guard lets the block run in bash" \
    || bad "case3 guard stopped the block in bash (got: $out)"

  if command -v zsh >/dev/null 2>&1; then
    out=$(zsh -f -c "$guard"$'\necho reached' 2>&1); rc=$?
    if [ "$rc" -ne 0 ] && [[ "$out" == *FAIL* ]] && [[ "$out" != *reached* ]]; then
      ok "case3 guard stops the block in zsh with a FAIL line"
    else
      bad "case3 guard did not stop the block in zsh (rc=$rc, out: $out)"
    fi
  else
    echo "SKIP: case3 zsh not installed"
  fi
fi

# ------------------------------------------------------------------- case 4
for f in "$NEW_ISSUE" "$NEW_EPIC"; do
  b=$(basename "$f")
  if grep -q '^## Shell-lohkot ajetaan bashilla$' "$f" && grep -qF 'bash -c "$(cat <<'"'"'SH'"'" "$f"; then
    ok "case4 $b tells to run the blocks in bash"
  else
    bad "case4 $b lacks the run-in-bash instruction"
  fi
done

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && echo "command-snippets: all passed" || echo "command-snippets: FAILURES"
[ "$FAIL" -eq 0 ]
