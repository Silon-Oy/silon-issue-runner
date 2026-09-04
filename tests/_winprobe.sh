#!/usr/bin/env bash
set -uo pipefail
hr() { printf '\n===== %s =====\n' "$1"; }

hr "jq version + binary flag"
jq --version
jq --help 2>&1 | grep -iE '(^| )-b|binary' || echo "(no -b in help)"
echo "--- jq -b -r"
printf '{"p":"/tmp/x"}\n' > /tmp/p.json
jq -b -r .p /tmp/p.json | od -c | head -2; echo "rc=${PIPESTATUS[0]}"
echo "--- jq -b with -e exit code (false => rc 1)"
jq -b -e '.missing' /tmp/p.json >/dev/null 2>&1; echo "rc(-e missing)=$?"
jq -b -e '.p' /tmp/p.json >/dev/null 2>&1; echo "rc(-e present)=$?"
echo "--- jq -b reading stdin heredoc"
jq -b -r .p <<< '{"p":"a/b"}' | od -c | head -2
echo "--- jq -b -n"
jq -b -n '1' | od -c | head -2
echo "--- jq -b --arg"
jq -b -rn --arg x hello '\$x' | od -c | head -2
echo "--- jq -b with a file arg after the filter"
jq -b -r '.p' /tmp/p.json | od -c | head -2
echo "--- jq -b --raw-input --slurp"
printf 'a\nb\n' | jq -b -Rs . | od -c | head -3

hr "function shadow + export -f"
jqb() { command jq -b "\$@"; }
jq() { command jq -b "\$@"; }
export -f jq
jq -r .p /tmp/p.json | od -c | head -2
echo "--- inherited by a child bash script?"
cat > /tmp/child.sh <<'CH'
#!/usr/bin/env bash
jq -r .p /tmp/p.json | od -c | head -2
CH
bash /tmp/child.sh
unset -f jq

hr "command -v forms for native exes"
for t in git jq bash sed grep cat mktemp env stat uname tr cut dirname basename rm mkdir cp; do
  printf '%-10s %s\n' "$t" "$(command -v "$t" 2>/dev/null || echo MISSING)"
done

hr "FAKEBIN symlink-to-exe experiment (test-cleanup-run-report case C)"
FB=/tmp/fakebin; rm -rf "$FB"; mkdir -p "$FB"
for t in bash dirname basename git jq sed cat tr cut grep mktemp rm mkdir cp uname stat env; do
  p=$(command -v "$t" 2>/dev/null) || { echo "MISSING $t"; continue; }
  ln -s "$p" "$FB/$t"
done
ls -l "$FB" | head -5
echo "--- run bash from FAKEBIN only"
PATH="$FB" bash -c 'echo alive; command -v gh || echo "gh: not found (good)"; git --version; jq --version' 2>&1 | head -6
echo "rc=$?"

hr "worktree path forms"
R=$(mktemp -d "/tmp/pg.XXXXXX"); git init -q "$R"
( cd "$R" && git config user.email a@b.c && git config user.name a && git commit -q --allow-empty -m x )
W="$R/../pw.$$"
git -C "$R" worktree add -q "$W" -b wt 2>&1 | head -2
git -C "$R" worktree list
echo "cygpath -u of the recorded path:"
git -C "$R" worktree list --porcelain | sed -n '3p'
