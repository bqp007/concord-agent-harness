#!/bin/bash
# concord.py candidate, grading and scope state: the paths a plan declares stay inside the checkout; the candidate holds
# a skip-worktree file's change; a pinned grading input inside a linked folder is the pinned one in every grading copy;
# the index is compared entry by entry; a verdict and --grade recheck the state a run is rejected for (permission
# bits, the index, ignored files) and the plan; a deleted bytecode cache is build output like a new one; the start
# state is taken before the red run; the run size runs from the start tree to the candidate; drift compares content.
# Session runs (--begin, --end), no executor, no network.
# Run: bash ~/.claude/concord/tests/codex_A_test.sh   (exit 0 = all passed).
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/codex-a-test.XXXXXX")" && pwd -P)"; export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/concord" "$T/home/.claude"
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
# Prefer the developer dir's real git/python3 over the /usr/bin xcrun shims (they print cache errors in the sandbox).
XDEV="$(xcode-select -p 2>/dev/null)"; [ -n "$XDEV" ] && [ -x "$XDEV/usr/bin/git" ] && [ -x "$XDEV/usr/bin/python3" ] && export PATH="$XDEV/usr/bin:$PATH"
export PATH="$T/bin:$PATH" HOME="$T/home"
DP="python3 $T/concord/concord.py"
. "$(dirname "$0")/lib.sh"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
# newrepo NAME ACCEPTANCE [FILES] [HOME] [HEAD]: repo $T/NAME (R) with a.py, b.py, c.py (three lines) and README.md
# committed, and PLAN_A.md: HEAD lines, a Test plan whose Home is HOME (default tests/t.sh) and phase 1 with FILES
# (default a.py) and ACCEPTANCE
newrepo(){ R="$T/$1"; mkdir -p "$R/tests" && ( cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > a.py; printf 'y = 1\n' > b.py; printf 'c1\nc2\nc3\n' > c.py; printf 'readme\n' > README.md
  printf 'true\n' > tests/t.sh; printf '.claude/\n' > .gitignore; git add -A && git commit -qm init
  printf '# Plan\n%b\n## Test plan\n| Behavior | Existing tests | Action | Home |\n|---|---|---|---|\n| a | t | KEEP | %s |\n\n## Phase 1 - change a\nExecutor: deepseek-flash\nFiles: %s\nAcceptance:\n- `%s`\n' \
    "${5:-}" "${4:-tests/t.sh}" "${3:-a.py}" "$2" > PLAN_A.md ) || { echo "setup failed: $1"; exit 1; }
  approve PLAN_A.md "$R" || exit 1; }
begin(){ $DP --begin 1 --label implementer --plan PLAN_A.md --repo "$R" "$@" > "$T/b.txt" 2>&1; }
end(){ $DP --end last --repo "$R" > "$T/e.txt" 2>&1; }
verdict(){ $DP --verdict last PASS --repo "$R" "$@" > "$T/v.txt" 2>&1; }
grade(){ $DP --grade last --repo "$R" > "$T/g.txt" 2>&1; }
rejected(){ head -3 "$T/e.txt" | grep -F "REJECTED (not graded)" | grep -qF -- "$1"; }
meta(){ python3 -I -c "import json,sys,glob; m=json.load(open(sorted(glob.glob(sys.argv[1]+'/*/meta.json'))[-1])); print(m.get(sys.argv[2]))" "$R/.git/concord" "$1"; }

echo "== declared paths stay inside the checkout (R-02)"
newrepo r02 'grep -q 2 a.py' '../outside.txt'; printf 'secret\n' > "$T/outside.txt"
begin; RC=$?; [ $RC -eq 0 ] && $DP --abort last --repo "$R" > /dev/null 2>&1
[ $RC -eq 2 ] && grep -qF "../outside.txt" "$T/b.txt" && ! ls "$R/.git/concord"/*/outside.txt > /dev/null 2>&1 \
  && ok "a Files: entry with a parent part is refused (exit 2) before anything is backed up, naming it" \
  || { bad "Files: ../outside.txt: --begin rc=$RC"; ls "$R/.git/concord"/*/ 2>/dev/null | head; tail -3 "$T/b.txt"; }
newrepo r02b 'grep -q 2 a.py' 'a.py' "$T/outside.txt"
begin; RC=$?; [ $RC -eq 0 ] && $DP --abort last --repo "$R" > /dev/null 2>&1
[ $RC -eq 2 ] && grep -qF "$T/outside.txt" "$T/b.txt" && ! grep -q Traceback "$T/b.txt" \
  && ok "an absolute Test plan Home is refused (exit 2), naming it" || { bad "absolute Home: --begin rc=$RC"; tail -3 "$T/b.txt"; }

echo "== a skip-worktree file is in the candidate (R-03)"
newrepo r03 'grep -q 2 a.py'; git -C "$R" update-index --skip-worktree README.md
begin; echo 'x = 2' > "$R/a.py"; echo changed >> "$R/README.md"; end
rejected "README.md (out of scope)" && [ "$(git -C "$R" ls-files -v README.md | cut -c1)" = S ] \
  && ok "an out-of-scope edit of a skip-worktree file rejects the run, and the real index keeps the bit" \
  || { bad "skip-worktree README.md edit not rejected"; head -4 "$T/e.txt"; }

echo "== a pinned grading input inside a linked folder (R-04)"
newrepo r04 'grep -q 2 a.py && grep -q gold data/golden.txt' 'a.py' 'data/golden.txt'
mkdir -p "$T/shared4" && printf 'lead\n' > "$T/shared4/golden.txt" && ln -s "$T/shared4" "$R/data" && printf 'data\n' >> "$R/.git/info/exclude"
printf 'data\n' > "$(git -C "$R" rev-parse --path-format=absolute --git-dir)/.wt-links"
begin; echo 'x = 2' > "$R/a.py"; end
printf 'gold\n' > "$T/shared4/golden.txt"; grade; GA=$(grep -o 'acceptance after run: [0-9]*/[0-9]*' "$T/g.txt")
printf 'lead\n' > "$T/shared4/golden.txt"; verdict; RC=$?
[ $RC -eq 7 ] && [ "$(meta verdict)" = None ] \
  && ok "--grade runs on the pinned input, not the live one in the linked folder; PASS stays refused (exit 7) once the live file is back" \
  || { bad "linked pinned input: grade said '$GA', then PASS rc=$RC"; cat "$T/v.txt"; }

echo "== the index is compared entry by entry (R-11)"
newrepo r11 'grep -q 2 a.py'; echo 'x = 0' > "$R/a.py"; git -C "$R" add a.py
begin; echo 'x = 2' > "$R/a.py"; git -C "$R" add a.py; end
rejected "a.py (staged)" && ok "restaging a path that was already staged at the start rejects the run" \
  || { bad "restaged a.py not rejected"; head -4 "$T/e.txt"; }

echo "== a verdict and --grade recheck the state a run is rejected for (R-12)"
newrepo r12 'grep -q 2 a.py'; begin; echo 'x = 2' > "$R/a.py"; end
chmod 600 "$R/README.md"; verdict; RC=$?
[ $RC -eq 7 ] && grep -qF "README.md" "$T/v.txt" && ok "a permission change of a tracked file after the run refuses PASS (exit 7), naming it" \
  || { bad "chmod 600 README.md after --end: PASS rc=$RC"; cat "$T/v.txt"; }
chmod 644 "$R/README.md"; git -C "$R" add a.py; verdict; RC=$?
[ $RC -eq 7 ] && grep -qF "a.py (staged)" "$T/v.txt" && ok "an index change after the run refuses PASS (exit 7), naming the path" \
  || { bad "git add a.py after --end: PASS rc=$RC"; cat "$T/v.txt"; }
git -C "$R" reset -q
newrepo r12b 'grep -q 2 a.py' 'a.py, local.cfg'; printf 'local.cfg\n' >> "$R/.gitignore"; git -C "$R" commit -qam ignore
begin; echo 'x = 2' > "$R/a.py"; echo 'k = 1' > "$R/local.cfg"; end
echo 'k = 2' > "$R/local.cfg"; verdict; RC=$?
[ $RC -eq 7 ] && grep -qF "local.cfg" "$T/v.txt" && ok "an ignored file in the write scope that changed after the run refuses PASS (exit 7)" \
  || { bad "ignored in-scope local.cfg changed after --end: PASS rc=$RC"; head -4 "$T/e.txt"; cat "$T/v.txt"; }
newrepo r12c 'grep -q 2 a.py'; begin; echo 'x = 2' > "$R/a.py"; end; chmod 600 "$R/README.md"; grade; RC=$?
[ $RC -eq 7 ] && grep -qF "README.md" "$T/g.txt" \
  && ok "--grade refuses a permission change outside the write scope since the start (exit 7)" \
  || { bad "--grade over chmod 600 README.md rc=$RC"; cat "$T/g.txt"; }

echo "== the plan is checked at the end, at --grade and at the verdict (R-13)"
newrepo r13 'grep -q 2 a.py'; begin; echo 'x = 2' > "$R/a.py"; end
printf '\nedited after the run\n' >> "$R/PLAN_A.md"; verdict; RC=$?; grade; RC2=$?
[ $RC -eq 7 ] && grep -qF "PLAN_A.md" "$T/v.txt" && [ $RC2 -eq 7 ] && grep -qF "PLAN_A.md" "$T/g.txt" \
  && ok "a plan edited after the run refuses PASS and --grade (exit 7), naming the plan" \
  || { bad "plan edited after --end: PASS rc=$RC, --grade rc=$RC2"; cat "$T/v.txt" "$T/g.txt"; }
newrepo r13b 'grep -q 2 a.py'; printf 'PLAN_*.md\n' >> "$R/.gitignore"; git -C "$R" commit -qam ignore
begin --no-ignored; echo 'x = 2' > "$R/a.py"; printf '\nedited by the executor\n' >> "$R/PLAN_A.md"; end
rejected "PLAN_A.md" && ok "a plan the run may not write and changed rejects the run, also where no snapshot sees it" \
  || { bad "ignored plan edited during an untracked-ignored run not rejected"; head -4 "$T/e.txt"; }

echo "== generated files by one rule on both sides (R-25)"
newrepo r25 'grep -q 2 a.py'; printf '__pycache__/\n' >> "$R/.gitignore"; git -C "$R" commit -qam ignore
mkdir -p "$R/pkg/__pycache__" "$R/env/lib/__pycache__" && printf 'old' > "$R/pkg/__pycache__/m.cpython-39.pyc"
printf 'old' > "$R/env/lib/__pycache__/v.cpython-39.pyc"      # a virtual-environment folder, untracked and not ignored
begin; echo 'x = 2' > "$R/a.py"; rm "$R/pkg/__pycache__/m.cpython-39.pyc" "$R/env/lib/__pycache__/v.cpython-39.pyc"
printf 'new' > "$R/pkg/__pycache__/n.cpython-39.pyc"; end
! grep -q "REJECTED" "$T/e.txt" && grep "^generated" "$T/e.txt" | grep -F "m.cpython-39.pyc" | grep -qF "v.cpython-39.pyc" \
  && grep -q "^DELETED: none" "$T/e.txt" \
  && ok "a deleted bytecode cache, ignored or untracked, is build output like a new one: listed as generated, not DELETED" \
  || { bad "deleted .pyc"; grep -E "REJECTED|^generated|^DELETED" "$T/e.txt"; }

echo "== the start state is taken before the red run (R-26)"
newrepo r26 'git config --local concord.probe 1; grep -q 2 a.py'; begin; echo 'x = 2' > "$R/a.py"; end
rejected "(git internals)" && ok "a change the red run makes to git internals is a change of the run (rejected), not part of its start" \
  || { bad "red-run git config change hidden in the start state"; head -4 "$T/e.txt"; }

echo "== run size and drift (R-38)"
newrepo r38 'grep -q z a.py' 'a.py, c.py'; echo 'w = 0' >> "$R/a.py"
begin; echo 'z = 2' >> "$R/a.py"; rm "$R/c.py"; end
grep -q "^diff size: 4 lines (+1 -3)" "$T/e.txt" && ok "the run size runs from the start tree to the candidate: an earlier edit is left out, a deletion counts" \
  || { bad "run size"; grep "^diff size" "$T/e.txt"; }
newrepo r38b 'grep -q 2 a.py' 'a.py' 'tests/t.sh' 'Tier: M\nSize: ~4 lines\nETA: 10 min\n'; echo 'y = 5' > "$R/b.py"
begin; echo 'x = 2' > "$R/a.py"; echo 'y = 7' > "$R/b.py"; $DP --drift --plan PLAN_A.md --repo "$R" > "$T/d.txt" 2>&1
grep -qF "changed outside Files: b.py" "$T/d.txt" && ok "drift compares content: replacing an earlier uncommitted edit with other text of the same size counts" \
  || { bad "drift missed the content change of b.py"; cat "$T/d.txt"; }
$DP --abort last --repo "$R" > /dev/null 2>&1

echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
