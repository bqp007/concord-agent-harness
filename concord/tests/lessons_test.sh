#!/bin/bash
# Live lessons: --lesson appends, --lessons-hook shows each session only the [plan] lines it has not seen, executor tasks carry [exec] ones.
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/lessons-test.XXXXXX")" && pwd -P)"; trap 'rm -rf "$T"' EXIT
cp -R "$SRC" "$T/c"; rm -f "$T/c/LESSONS.md"; rm -rf "$T/c/lessons-seen"
P=0; F=0
check() { if eval "$2"; then P=$((P+1)); echo "check $1: ok"; else F=$((F+1)); echo "check $1: FAIL"; fi; }
run() { python3 "$T/c/concord.py" "$@"; }
hook() { echo "$1" | python3 "$T/c/concord.py" --lessons-hook; }

check missing-file-silent '[ -z "$(hook "{\"session_id\":\"s1\"}")" ]'
check append-format 'run --lesson "name exact   checks" --tag plan --tag exec | grep -qE "^L1 [0-9-]{10} \[plan\] \[exec\] name exact checks$"'
run --lesson "plan only" >/dev/null
check hook-first '[ "$(hook "{\"session_id\":\"s1\"}" | python3 -c "import json,sys;print(json.load(sys.stdin)[\"hookSpecificOutput\"][\"additionalContext\"].count(\"\nL\"))")" = 2 ]'
check hook-second-silent '[ -z "$(hook "{\"session_id\":\"s1\"}")" ]'
check other-session '[ -n "$(hook "{\"session_id\":\"s2\"}")" ]'
run --lesson "third" >/dev/null
check delta-only 'out=$(hook "{\"session_id\":\"s1\"}"); echo "$out" | grep -q "L3 " && ! echo "$out" | grep -q "L1 "'
python3 -c 'import sys; p=sys.argv[1]; L=open(p).read().splitlines(); open(p,"w").write("\n".join(l for l in L if not l.startswith(("L2 ","L3 ")))+"\n")' "$T/c/LESSONS.md"
check fold-new-id 'run --lesson "after fold" | grep -q "^L4 "'
check fold-delta 'hook "{\"session_id\":\"s1\"}" | grep -q "after fold"'
check bad-json-exit0 'echo nope | python3 "$T/c/concord.py" --lessons-hook >/dev/null; [ $? = 0 ]'
check exec-in-task 'python3 -c "import sys;sys.path.insert(0,\"$T/c\");import concord;t=concord.build_task(\"$SRC/..\",\"P.md\",1,\"do\",\"\");assert \"Lessons (current; binding):\" in t and \"name exact checks\" in t and \"plan only\" not in t"'
echo "passed $P, failed $F"
[ "$F" = 0 ]
