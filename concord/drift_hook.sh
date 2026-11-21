#!/bin/sh
# PostToolUse hook: tick the drift clock of the repository the tool ran in. It reads the hook JSON from stdin, takes the
# first `cwd` key, and starts Python only when that repository's runs root holds a drift.json (a gated run registered a plan there).
# Never fails the tool call.
input=$(cat)
cwd=$(printf '%s' "$input" | grep -E -o '"cwd"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"' | head -1 | sed -E 's/^"cwd"[[:space:]]*:[[:space:]]*"//; s/"$//; s/\\\//\//g; s/\\\\/\\/g')
{ [ -n "$cwd" ] && [ -d "$cwd" ]; } || cwd=$PWD
common=$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null) || exit 0
case "$common" in /*) ;; *) common="$cwd/$common" ;; esac
[ -f "$common/concord/drift.json" ] || exit 0
here=$(cd "$(dirname "$0")" && pwd -P) || exit 0
printf '%s' "$input" | python3 "$here/concord.py" --drift-hook 2>/dev/null
exit 0
