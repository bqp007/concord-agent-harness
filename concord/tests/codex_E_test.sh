#!/bin/bash
# Worktree regressions (no network, no model): wt.py done consults the worktree's Concord run lock before it removes
# anything, and a lock it cannot read stops it; join checks the fork's work only once it holds both run locks; a fork that no Concord run graded joins only
# with --ungraded.
# Run: bash ~/.claude/concord/tests/codex_E_test.sh   (exit 0 = all passed; temp repo under $TMPDIR, removed).
# Tests the dispatcher this file belongs to, copied into the temp dir.
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/codexE-test.XXXXXX")" && pwd -P)"; mkdir -p "$T/concord" "$T/home"   # -P: git reports /private/tmp
trap 'rm -rf "$T"' EXIT
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
# The /usr/bin git and python3 are xcrun shims that print cache warnings inside the macOS sandbox: prefer the real ones.
XDEV="$(xcode-select -p 2>/dev/null)"; [ -n "$XDEV" ] && [ -x "$XDEV/usr/bin/git" ] && [ -x "$XDEV/usr/bin/python3" ] && export PATH="$XDEV/usr/bin:$PATH"
export HOME="$T/home"; unset CLAUDE_HOME
DP="python3 $T/concord/concord.py"
WT="python3 $T/concord/wt.py"
. "$(dirname "$0")/lib.sh"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
gd(){ git -C "$1" rev-parse --path-format=absolute --git-dir; }
M="$T/main"; mkdir -p "$M"
( cd "$M" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > a.py; printf '.claude/\n' > .gitignore; git add -A && git commit -qm init )
printf '# Plan\n## Phase 1 - change a\nExecutor: deepseek-flash\nFiles: a.py\nAcceptance:\n- `grep -q y a.py`\n' > "$T/PLAN_E.md"

echo "== done refuses while a Concord run holds the worktree's run lock, even with --force"
$WT new TD --repo "$M" --no-fetch --base main > /dev/null 2>&1; WD="$M/.claude/worktrees/TD"
cp "$T/PLAN_E.md" "$WD/PLAN_E.md"; approve PLAN_E.md "$WD" || exit 1
$DP --begin 1 --label implementer --plan PLAN_E.md --repo "$WD" > "$T/b.txt" 2>&1
OB=$(sed -n 's/^BEGIN \([^ ]*\)$/\1/p' "$T/b.txt" | head -1)
$WT done TD --repo "$M" > "$T/d1.txt" 2>&1; D1=$?
$WT done TD --repo "$M" --force > "$T/d2.txt" 2>&1; D2=$?
[ -n "$OB" ] && [ $D1 -ne 0 ] && [ $D2 -ne 0 ] && [ -f "$WD/a.py" ] && [ -f "$WD/PLAN_E.md" ] && grep -qF "$OB" "$T/d1.txt" \
  && grep -qF "nothing removed" "$T/d2.txt" \
  && ok "an open --begin run: done refuses with and without --force, names the run, removes nothing" \
  || { bad "done under an open run rc=$D1/$D2 run=$OB"; cat "$T/b.txt" "$T/d1.txt" "$T/d2.txt"; }
$DP --abort "$OB" --repo "$WD" > /dev/null 2>&1
$WT done TD --repo "$M" > "$T/d3.txt" 2>&1 && [ ! -e "$WD" ] && ok "after --abort the same done removes the worktree" \
  || { bad "done after --abort"; cat "$T/d3.txt"; }
# a run lock that cannot be read may hold live runs: concord.py refuses beside it, and so does done
$WT new TL --repo "$M" --no-fetch --base main > /dev/null 2>&1; WL="$M/.claude/worktrees/TL"
printf '{"holders": [' > "$(gd "$WL")/concord.lock"
$WT done TL --repo "$M" --force > "$T/d4.txt" 2>&1; D4=$?
[ $D4 -ne 0 ] && [ -d "$WL" ] && grep -qF "cannot be read as a lock" "$T/d4.txt" \
  && ok "a damaged run lock: done refuses even with --force and removes nothing" || { bad "done beside a damaged lock rc=$D4"; cat "$T/d4.txt"; }
rm -f "$(gd "$WL")/concord.lock"; $WT done TL --repo "$M" > /dev/null 2>&1

echo "== join checks the fork's work once it holds both run locks"
# A process holds the destination's run-lock mutex, as concord.py does while a run starts or ends there. join creates the
# fork's mutex file just before it takes the locks; once that file exists, a file is staged in the fork with content that
# differs from its working file (work join cannot carry), and the mutex is released. A join that checked before it took
# the locks would apply the working file and drop the staged content with the fork.
$WT new TJ --repo "$M" --no-fetch --base main > /dev/null 2>&1; WJ="$M/.claude/worktrees/TJ"
$WT fork TJ 1 --repo "$WJ" > /dev/null 2>&1; FJ="$M/.claude/worktrees/TJ-p1"; [ -d "$FJ" ] || { echo "setup failed: fork"; exit 1; }
[ ! -e "$(gd "$FJ")/concord.lock.mutex" ] || { echo "setup failed: the fork already has a run-lock mutex"; exit 1; }
python3 -I -c '
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o644); fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
while not os.path.exists(sys.argv[3]):
    time.sleep(0.05)' "$(gd "$WJ")/concord.lock.mutex" "$T/held" "$T/release" & HP=$!
i=0; until [ -e "$T/held" ] || [ $i -ge 600 ]; do sleep 0.1; i=$((i+1)); done
$WT join TJ 1 --repo "$WJ" --ungraded > "$T/j1.txt" 2>&1 & JP=$!
i=0; until [ -e "$(gd "$FJ")/concord.lock.mutex" ] || [ $i -ge 600 ]; do sleep 0.1; i=$((i+1)); done
printf 'x = 10\n' > "$FJ/a.py"; git -C "$FJ" add a.py; printf 'x = 11\n' > "$FJ/a.py"
touch "$T/release"; wait $HP; wait $JP; RJ=$?
[ $RJ -ne 0 ] && [ -d "$FJ" ] && [ "$(cat "$WJ/a.py")" = "x = 1" ] && grep -qF "a.py: staged content differs from the working file" "$T/j1.txt" \
  && ok "work that appears before join holds the locks is checked: join refuses, names a.py, keeps the fork, applies nothing" \
  || { bad "join checked the fork before it held the locks rc=$RJ a.py=$(cat "$WJ/a.py")"; cat "$T/j1.txt"; }
git -C "$FJ" reset -q a.py; $WT join TJ 1 --repo "$WJ" --ungraded > /dev/null 2>&1; git -C "$WJ" checkout -q -- a.py

echo "== a fork that no Concord run graded joins only with --ungraded"
$WT fork TJ 2 --repo "$WJ" > /dev/null 2>&1; F2="$M/.claude/worktrees/TJ-p2"; printf 'x = 2\n' > "$F2/a.py"
$WT join TJ 2 --repo "$WJ" > "$T/j2.txt" 2>&1; R2=$?
[ $R2 -ne 0 ] && [ -d "$F2" ] && [ "$(cat "$WJ/a.py")" = "x = 1" ] && grep -qF "no Concord run graded this fork" "$T/j2.txt" \
  && grep -qF -- "--ungraded" "$T/j2.txt" \
  && ok "a fork with no run: join refuses, nothing applied, the fork kept, naming --ungraded" || { bad "ungraded join without --ungraded rc=$R2"; cat "$T/j2.txt"; }
$WT join TJ 2 --repo "$WJ" --ungraded > "$T/j3.txt" 2>&1; R3=$?
[ $R3 -eq 0 ] && [ ! -e "$F2" ] && [ "$(cat "$WJ/a.py")" = "x = 2" ] && grep -qF "joined ungraded (--ungraded): no Concord run graded this fork" "$T/j3.txt" \
  && ok "join --ungraded joins the fork with no run and says it is ungraded" || { bad "--ungraded join of a fork with no run rc=$R3"; cat "$T/j3.txt"; }

echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
