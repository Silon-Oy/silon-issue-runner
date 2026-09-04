#!/usr/bin/env bash
set -uo pipefail
hr() { printf '\n===== %s =====\n' "$1"; }

hr "uname / env"
uname -s; echo "TMPDIR=${TMPDIR:-<unset>}"; echo "TEMP=${TEMP:-<unset>}"; echo "HOME=$HOME"; echo "PWD=$PWD"

hr "H1 jq line endings"
printf '{"p":"/tmp/x","n":10}\n' > /tmp/probe.json
jq -r .p /tmp/probe.json | od -c | head -3
echo "--- jq -r .n"
jq -r .n /tmp/probe.json | od -c | head -3

hr "H2 mktemp path forms"
A=$(mktemp -d); echo "mktemp -d           => $A"
B=$(mktemp -d -t probe.XXXXXX); echo "mktemp -d -t        => $B"
C=$(mktemp -d "/tmp/probe.XXXXXX"); echo "mktemp -d /tmp/tmpl => $C"

hr "H2b MSYS arg mangling into git.exe"
R=$(mktemp -d "/tmp/probeg.XXXXXX")
git -C "$R" init -q . 2>/dev/null || git init -q "$R"
( cd "$R" && git config user.email a@b.c && git config user.name a && git commit -q --allow-empty -m x )
W="/tmp/probew.$$"
git -C "$R" worktree add -q "$W" -b wt 2>&1 | head -3
echo "--- worktree list (raw) ---"
git -C "$R" worktree list
echo "--- remove using the same literal string ---"
git -C "$R" worktree remove --force "$W" 2>&1 | head -3; echo "remove rc=$?"

hr "H3 stat -f %m"
stat -f %m /tmp/probe.json; echo "rc(stat -f)=$?"
echo "--- combined as in lib/version.sh ---"
out=$(stat -f %m /tmp/probe.json 2>/dev/null || stat -c %Y /tmp/probe.json 2>/dev/null || printf '')
printf 'combined=[%s]\n' "$out"

hr "H4 exec bit"
F=/tmp/probe-hook.sh; printf '#!/usr/bin/env bash\necho hi\n' > "$F"
chmod +x "$F"; [ -x "$F" ] && echo "after chmod +x: -x TRUE" || echo "after chmod +x: -x FALSE"
chmod -x "$F"; [ -x "$F" ] && echo "after chmod -x: -x TRUE (BAD)" || echo "after chmod -x: -x FALSE (good)"
ls -l "$F"

hr "H5 chmod 600"
G=/tmp/probe-secret; echo x > "$G"; chmod 600 "$G"
stat -c '%a' "$G" 2>/dev/null || stat -f '%Lp' "$G"
ls -l "$G"

hr "H6 hostname"
hostname -s; echo "rc(hostname -s)=$?"
hostname; echo "rc(hostname)=$?"
echo "COMPUTERNAME=${COMPUTERNAME:-<unset>}"

hr "H7 PATH shim"
SB=/tmp/probe-bin; mkdir -p "$SB"
printf '#!/usr/bin/env bash\necho SHIMMED "$@"\n' > "$SB/gh"; chmod +x "$SB/gh"
PATH="$SB:$PATH" command -v gh
PATH="$SB:$PATH" gh api hello
echo "--- with a PATH that has NO gh at all ---"
PATH="$SB/none" bash -c 'command -v gh; echo "cv rc=$?"; gh --version; echo "gh rc=$?"' 2>&1 | head -5

hr "H8 misc"
echo "timeout: $(command -v timeout) $(timeout --version 2>/dev/null | head -1)"
date -u +%s
echo "readlink -f /tmp: $(readlink -f /tmp)"
ln -s /tmp/probe.json /tmp/probe-link && readlink /tmp/probe-link && echo "symlink ok"
