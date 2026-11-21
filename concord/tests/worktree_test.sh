#!/bin/bash
# Worktree regression (no network, fake qwen executor): wt.py new/list/done/fork/join, concord.py locks per set of
# files (disjoint runs share a checkout), per-checkout "last", main-checkout snapshot ignoring nested worktrees, done
# refusals (untracked and ignored files, edited copies), plan archive on done, join (committed work, the checkout it runs
# in, staged and ignored work of the fork), OVERLAP and DRIFT lines in `wt.py list`.
# Run: bash ~/.claude/concord/tests/worktree_test.sh   (exit 0 = all passed; temp repo under $TMPDIR, removed).
# Tests the dispatcher this file belongs to, copied into the temp dir, so runs.jsonl stays untouched.
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/wt-test.XXXXXX")" && pwd -P)"; mkdir -p "$T/bin" "$T/concord"   # -P: git reports /private/tmp
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
M="$T/mainrepo"; mkdir -p "$M"
printf '#!/bin/sh\nsleep ${FAKE_SLEEP:-0}\nsh -c "${FAKE_ACTIONS:-true}"\n' > "$T/bin/qwen"; chmod +x "$T/bin/qwen"
# The /usr/bin git and python3 are xcrun shims; inside the macOS sandbox xcrun cannot write its cache and prints
# "couldn't create cache file" on stderr, which pollutes captured output. Prefer the developer dir's real binaries.
XDEV="$(xcode-select -p 2>/dev/null)"; [ -n "$XDEV" ] && [ -x "$XDEV/usr/bin/git" ] && [ -x "$XDEV/usr/bin/python3" ] && export PATH="$XDEV/usr/bin:$PATH"
export PATH="$T/bin:$PATH"
DP="python3 $T/concord/concord.py"
WT="python3 $T/concord/wt.py"
. "$(dirname "$0")/lib.sh"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
(
  cd "$M" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > a.py; printf '.claude/\nbuild/\nresults/\n' > .gitignore
  git add -A && git commit -qm init
  mkdir -p data bench && dd if=/dev/zero of=data/blob bs=1k count=64 2>/dev/null && printf 'b\n' > bench/b.json
  echo "data/" >> .git/info/exclude                       # data = ignored folder (like .venv); bench = untracked (??)
  mkdir -p .claude && printf -- '---\nname: t\nenabled: true\nevent: bash\npattern: never-matches-xyz\n---\nx\n' > .claude/hookify.t.local.md
  printf '{"permissions": {"allow": []}}\n' > .claude/settings.local.json
)
plan(){ cat > "$1/PLAN_T.md" <<'EOF'
# Plan
## Phase 1 - change a
Executor: deepseek-flash
Files: a.py
Acceptance:
- `grep -q y a.py`
EOF
}
mstat(){ git -C "$M" status --porcelain -uall --ignored | grep -v "^!! .claude/worktrees/"; }
MAIN_BEFORE=$(mstat)
echo "== wt.py new (links + copies)"
$WT new T1 --repo "$M" --no-fetch --base main --link data --link bench > "$T/n1.txt" 2>&1; sed 's/^/     /' "$T/n1.txt"
W1="$M/.claude/worktrees/T1"
[ -L "$W1/data" ] && [ "$(readlink "$W1/data")" = "$M/data" ] && [ -L "$W1/bench" ] && ok "data + bench linked to main checkout" || bad "links"
[ -f "$W1/.claude/hookify.t.local.md" ] && [ ! -L "$W1/.claude/hookify.t.local.md" ] && ok "hookify rule copied (not linked)" || bad "hookify copy"
[ -f "$W1/.claude/settings.local.json" ] && ok "settings.local.json copied" || bad "settings copy"
[ "$(git -C "$W1" branch --show-current)" = "feature/T1" ] && ok "branch feature/T1" || bad "branch name"
[ -z "$(git -C "$W1" status --porcelain)" ] && ok "worktree status clean (links hidden)" || bad "worktree status: $(git -C "$W1" status --porcelain | tr '\n' ' ')"
[ -z "$(git -C "$W1" add -A --dry-run)" ] && ok "git add -A in worktree adds nothing" || bad "add -A would add: $(git -C "$W1" add -A --dry-run | tr '\n' ' ')"
[ "$(mstat)" = "$MAIN_BEFORE" ] && ok "main checkout status unchanged apart from the worktree (bench ??, data !!)" \
  || { bad "main status changed"; echo "before: $MAIN_BEFORE" | tr '\n' ' '; echo; echo "after:  $(mstat | tr '\n' ' ')"; }
$WT new T2 --repo "$M" --no-fetch --base main --link data --link bench > /dev/null 2>&1; W2="$M/.claude/worktrees/T2"
[ "$(grep -c '^/bench$' "$M/.git/info/exclude")" = 1 ] && ok "exclude patterns added once" || bad "duplicate patterns: $(tr '\n' ' ' < "$M/.git/info/exclude")"
plan "$W1"; plan "$W2"; plan "$M"; mkdir -p "$T/orig"; plan "$T/orig"; approve PLAN_T.md "$M" || exit 1
echo "== parallel runs: T1 and T2 at once, main too"
# T1 holds its lock until $T/release exists (at most 30 s), so the same-checkout block does not depend on runner speed.
FAKE_ACTIONS="i=0; while [ ! -e '$T/release' ] && [ \$i -lt 300 ]; do sleep 0.1; i=\$((i+1)); done; echo y >> a.py" \
  $DP 1 --plan PLAN_T.md --via qwen --model fake/m --no-baseline --repo "$W1" > "$T/r1.txt" 2>&1 & P1=$!
L1="$(git -C "$W1" rev-parse --path-format=absolute --git-dir)/concord.lock"
i=0; until [ -e "$L1" ] || [ $i -ge 100 ]; do sleep 0.1; i=$((i+1)); done
FAKE_ACTIONS='echo y >> a.py' $DP 1 --plan PLAN_T.md --via qwen --model fake/m --no-baseline --repo "$W2" > "$T/r2.txt" 2>&1; R2=$?
FAKE_ACTIONS='echo y >> a.py' $DP 1 --plan PLAN_T.md --via qwen --model fake/m --no-baseline --repo "$M" > "$T/r3.txt" 2>&1; R3=$?
FAKE_ACTIONS='true' $DP 1 --plan PLAN_T.md --via qwen --model fake/m --no-baseline --repo "$W1" > "$T/r4.txt" 2>&1; R4=$?
touch "$T/release"; wait $P1; R1=$?
[ $R1 -eq 0 ] && grep -q "a.py" "$T/r1.txt" && ok "T1 run completed" || { bad "T1 run rc=$R1"; tail -4 "$T/r1.txt"; }
[ $R2 -eq 0 ] && ok "T2 ran while T1 was running (no lock wait)" || { bad "T2 rc=$R2"; tail -3 "$T/r2.txt"; }
[ $R3 -eq 0 ] && ok "main checkout ran while T1 was running" || { bad "main rc=$R3"; tail -3 "$T/r3.txt"; }
[ $R4 -eq 2 ] && grep -q "another delegated run is active in this checkout" "$T/r4.txt" && grep -qF "both list a.py" "$T/r4.txt" \
  && ok "second run in T1 blocked (same checkout), naming the shared file" || { bad "same-checkout block rc=$R4"; tail -3 "$T/r4.txt"; }
grep "OUT OF SCOPE" "$T/r3.txt" | grep -qv ": none" && bad "main run flagged out-of-scope files: $(grep -i 'out of scope' "$T/r3.txt")" || ok "main run saw no worktree files"
echo "== lock per set of files: disjoint runs share a checkout (2026-11-15, kit-flow)"
printf '# Plan\n## Test plan\n| Behavior | Existing tests | Action | Home |\n|---|---|---|---|\n| b | none | ADD | b.py |\n| c | none | ADD | c.py |\n\n## Phase 1 - change a\nExecutor: deepseek-flash\nFiles: a.py\nAcceptance:\n- `grep -q y a.py b.py c.py`\n\n## Phase 2 - make b\nExecutor: deepseek-flash\nFiles: b.py, z.py, c.py\nAcceptance:\n- `grep -q y b.py`\n\n## Phase 3 - no Files\nExecutor: deepseek-flash\nAcceptance:\n- `true`\n' > "$W1/PLAN_F.md"; printf 'c\n' > "$W1/c.py"
approve PLAN_F.md "$W1" || exit 1
FAKE_ACTIONS="i=0; while [ ! -e '$T/release2' ] && [ \$i -lt 300 ]; do sleep 0.1; i=\$((i+1)); done; echo y >> a.py" \
  $DP 1 --plan PLAN_F.md --via qwen --model fake/m --no-baseline --repo "$W1" > "$T/f1.txt" 2>&1 & PF=$!
i=0; until [ -e "$L1" ] || [ $i -ge 100 ]; do sleep 0.1; i=$((i+1)); done
printf 'z\n' > "$W1/z.py"; FAKE_ACTIONS='echo y > b.py; rm z.py; echo y >> c.py' $DP 2 --plan PLAN_F.md --via qwen --model fake/m --no-baseline --repo "$W1" > "$T/f2.txt" 2>&1; F2=$?
FAKE_ACTIONS='true' $DP 3 --plan PLAN_F.md --via qwen --model fake/m --no-baseline --repo "$W1" > "$T/f3.txt" 2>&1; F3=$?
touch "$T/release2"; wait $PF; F1=$?
[ $F2 -eq 0 ] && grep -q "b.py" "$T/f2.txt" && ok "a run with disjoint Files ran in the same checkout while another ran" \
  || { bad "disjoint run rc=$F2"; tail -3 "$T/f2.txt"; }
[ $F3 -eq 2 ] && grep -q "another delegated run is active in this checkout" "$T/f3.txt" \
  && ok "a run with no Files is refused while another runs (exit 2)" || { bad "no-Files run rc=$F3"; tail -3 "$T/f3.txt"; }
[ $F1 -eq 0 ] && ! grep -E "^(OUT OF SCOPE|DELETED)" "$T/f1.txt" | grep -qE "b.py|z.py" && grep -q "^diff size: 2 lines (+2 -0)" "$T/f1.txt" \
  && grep -qxF "ACCEPTANCE FILES CHANGED: c.py (modified; in a concurrent run's Files: re-run this phase once that run ends)" "$T/f1.txt" \
  && ok "the long run leaves the concurrent run's b.py and deleted z.py out of OUT OF SCOPE, DELETED, ACCEPTANCE FILES CHANGED and its diff size; its change of c.py, there at the start, stays" \
  || { bad "concurrent scope rc=$F1"; grep -iE "scope|deleted|acceptance|diff size" "$T/f1.txt"; }
[ ! -e "$L1" ] && ok "the lock file is gone once both runs ended" || bad "lock file left: $(cat "$L1" 2>&1)"
printf '{"pid": %s, "child": null, "run": "old-run", "manual": false, "repo": "%s"}\n' "$(sh -c 'echo $$')" "$W1" > "$L1"      # one holder (a dead pid), no files: written before 2026-11-15
FAKE_ACTIONS='true' $DP 3 --plan PLAN_F.md --via qwen --model fake/m --no-baseline --repo "$W1" > "$T/f4.txt" 2>&1; F4=$?
[ $F4 -ne 0 ] && grep -q "pre-3.0 format" "$T/f4.txt" && grep -q '"old-run"' "$L1" \
  && ok "a concord.lock in the single-holder format (before 2026-11-15) is refused with the pre-3.0 explanation and left in place" || { bad "single-holder lock rc=$F4"; tail -3 "$T/f4.txt"; }
rm -f "$L1"
rm -f "$W1/b.py" "$W1/c.py" "$W1/PLAN_F.md"
echo "== 'last' is per checkout"
L1=$($DP --show last --repo "$W1" 2>&1 | grep -m1 "^DELEGATE RESULT"); L2=$($DP --show last --repo "$W2" 2>&1 | grep -m1 "^DELEGATE RESULT")
[ -n "$L1" ] && [ "$L1" != "$L2" ] && ok "--show last differs per worktree ($L1 / $L2)" || { bad "last isolation: [$L1] [$L2]"; $DP --show last --repo "$W1" 2>&1 | head -3; }
python3 -I - "$M" "$W1" "$T/concord/concord.py" <<'EOF' && pass=$((pass+2)) || bad "python checks (repo notes name, main snapshot) failed"
import importlib.util, sys
from pathlib import Path
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("d", sys.argv[3])
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
main, w1 = Path(sys.argv[1]), Path(sys.argv[2])
assert d.repo_name(w1) == "mainrepo", d.repo_name(w1)
print("  ok   repo notes keyed by main checkout name from inside a worktree")
pre = d.snapshot(main)
(w1 / "new_root_file.txt").write_text("x")            # another session's executor creates a file in its worktree
post = d.snapshot(main)
assert d.compare(pre, post, main) == ([], [], []), d.compare(pre, post, main)
print("  ok   main snapshot ignores files created inside a worktree")
(w1 / "new_root_file.txt").unlink()
EOF
echo "== wt.py list: overlap between worktrees, drift of the base"
printf 't\n' > "$W1/t1_only.py"
mkdir -p "$W1/newdir" "$W2/newdir"; printf '1\n' > "$W1/newdir/one.py"; printf '2\n' > "$W2/newdir/two.py"
$WT list --repo "$M" > "$T/l1.txt" 2>&1; sed 's/^/     /' "$T/l1.txt"
! grep -q "^OVERLAP newdir" "$T/l1.txt" && ok "different new files in a same-named new folder are no overlap" || bad "false overlap: $(grep '^OVERLAP newdir' "$T/l1.txt")"
rm -rf "$W1/newdir" "$W2/newdir"
grep -qx "OVERLAP a.py: T1, T2" "$T/l1.txt" && ok "a.py changed in both T1 and T2 -> OVERLAP line" || bad "OVERLAP line missing"
! grep -q "^OVERLAP t1_only.py" "$T/l1.txt" && ok "a file changed in one worktree only is no overlap" || bad "single-worktree file reported as overlap"
! grep -q "^OVERLAP PLAN_T.md" "$T/l1.txt" && ok "plan files never count as overlap" || bad "plan file reported as overlap"
! grep -q "^DRIFT" "$T/l1.txt" && ok "no DRIFT while the base has not moved" || bad "DRIFT before the base moved: $(grep '^DRIFT' "$T/l1.txt")"
git -C "$M" commit -qm "main moves" a.py
$WT list --repo "$M" > "$T/l2.txt" 2>&1; sed 's/^/     /' "$T/l2.txt"
grep -q "^DRIFT T1: HEAD moved 1 commit.*; also changed upstream: a\.py$" "$T/l2.txt" \
  && ok "base moved and touched a.py -> DRIFT line for T1" || bad "DRIFT line for T1 missing"
echo "== wt.py done refuses while dirty, touches nothing"
$WT done T1 --repo "$M" > "$T/d1.txt" 2>&1; D1=$?
[ $D1 -ne 0 ] && grep -q "uncommitted changes" "$T/d1.txt" && [ -L "$W1/data" ] && [ -f "$W1/.claude/hookify.t.local.md" ] && ok "done refused (dirty), links + rules intact" || { bad "dirty done rc=$D1"; cat "$T/d1.txt"; }
! grep -q "PLAN_T.md" "$T/d1.txt" && [ -f "$W1/PLAN_T.md" ] && ok "untracked plan file is not uncommitted work; still in place after the refusal" || { bad "plan listed or moved"; cat "$T/d1.txt"; }
git -C "$W1" add a.py t1_only.py && git -C "$W1" commit -qm "t1 work"
$WT done T1 --repo "$M" > "$T/d2.txt" 2>&1; D2=$?
[ $D2 -eq 0 ] && [ ! -e "$W1" ] && ok "done removed T1 after commit (plan file left in it)" || { bad "done rc=$D2"; cat "$T/d2.txt"; git -C "$W1" status --porcelain; }
cmp -s "$T/orig/PLAN_T.md" "$M/.git/concord/plans/T1/PLAN_T.md" && grep -q "^archived: .*plans/T1/PLAN_T.md" "$T/d2.txt" \
  && ok "plan archived to .git/concord/plans/T1 before removal" || { bad "plan archive"; cat "$T/d2.txt"; ls -R "$M/.git/concord/plans" 2>&1 | head; }
[ -f "$M/data/blob" ] && [ -f "$M/bench/b.json" ] && ok "linked folders intact in main checkout" || bad "data lost"
git -C "$M" show-ref --verify --quiet refs/heads/feature/T1 && ok "branch feature/T1 kept" || bad "branch deleted"
git -C "$W2" checkout -q -- a.py
echo "== done refuses to drop ignored data, refuses on protected files, never half-removes"
mkdir -p "$W2/build" "$W2/results" && printf 'o\n' > "$W2/build/out.o" && printf 'r\n' > "$W2/results/r.json"
$WT done T2 --repo "$M" > "$T/d3.txt" 2>&1; D3=$?
[ $D3 -ne 0 ] && grep -q "results/" "$T/d3.txt" && grep -q "build/" "$T/d3.txt" && [ -L "$W2/data" ] && [ -f "$W2/results/r.json" ] && [ -f "$W2/build/out.o" ] \
  && ok "refused: lists the ignored results/ and build/ (build output is no longer disposable), worktree intact" || { bad "ignored-data check rc=$D3"; cat "$T/d3.txt"; }
rm -rf "$W2/results" "$W2/build"; chmod 444 "$W2/.claude/settings.local.json"     # stands in for the sandbox's write protection
$WT done T2 --repo "$M" > "$T/d4.txt" 2>&1; D4=$?
[ $D4 -ne 0 ] && grep -q "write-protects" "$T/d4.txt" && grep -q "settings.local.json" "$T/d4.txt" && [ -L "$W2/data" ] \
  && ok "refused: protected file reported, nothing touched" || { bad "protected check rc=$D4"; cat "$T/d4.txt"; }
[ ! -e "$M/.git/concord/plans/T2/PLAN_T.md" ] && ok "refused runs archive nothing" || bad "plan archived although done refused"
chmod 644 "$W2/.claude/settings.local.json"
$WT done T2 --repo "$M" > "$T/d5.txt" 2>&1 && [ ! -e "$W2" ] && ok "T2 removed (its copies of .claude files unchanged, no ignored output left)" || { bad "T2 remove"; cat "$T/d5.txt"; }
$WT new T9 --repo "$M" --no-fetch --base main > /dev/null 2>&1; W9="$M/.claude/worktrees/T9"
git -C "$M" config status.showUntrackedFiles no; printf 'mine\n' > "$W9/notes9.txt"
$WT done T9 --repo "$M" > "$T/d9a.txt" 2>&1; D9A=$?; git -C "$M" config --unset status.showUntrackedFiles
[ $D9A -ne 0 ] && grep -q "notes9.txt" "$T/d9a.txt" && [ -f "$W9/notes9.txt" ] \
  && ok "an untracked file is user work even when status.showUntrackedFiles is no: done refuses and names it" || { bad "untracked under showUntrackedFiles=no rc=$D9A"; cat "$T/d9a.txt"; }
$WT new T10 --repo "$M" --no-fetch --base main > /dev/null 2>&1; W10="$M/.claude/worktrees/T10"
mkdir -p "$W10/build"; printf 'o\n' > "$W10/build/out.o"
$WT done T10 --repo "$M" > "$T/d9b.txt" 2>&1; D9B=$?
[ $D9B -ne 0 ] && grep -q "build/" "$T/d9b.txt" && [ -f "$W10/build/out.o" ] && ok "an ignored file under build/ makes done refuse and names it" || { bad "build/ output rc=$D9B"; cat "$T/d9b.txt"; }
$WT new T11 --repo "$M" --no-fetch --base main > /dev/null 2>&1; W11="$M/.claude/worktrees/T11"
printf '{"permissions": {"allow": ["Bash(ls)"]}}\n' > "$W11/.claude/settings.local.json"
$WT done T11 --repo "$M" > "$T/d9c.txt" 2>&1; D9C=$?
[ $D9C -ne 0 ] && grep -q "settings.local.json" "$T/d9c.txt" && [ -f "$W11/.claude/settings.local.json" ] && ok "an edited copy of .claude/settings.local.json is user work: done refuses and names it" || { bad "edited copy rc=$D9C"; cat "$T/d9c.txt"; }
cp -p "$M/.claude/settings.local.json" "$W11/.claude/settings.local.json"; $WT done T11 --repo "$M" --force > /dev/null 2>&1
rm -rf "$W9/notes9.txt"; $WT done T9 --repo "$M" --force > /dev/null 2>&1; rm -rf "$W10/build"; $WT done T10 --repo "$M" --force > /dev/null 2>&1
echo "== done without a plan; done --force keeps the plan"
$WT new T3 --repo "$M" --no-fetch --base main > /dev/null 2>&1; W3="$M/.claude/worktrees/T3"
$WT done T3 --repo "$M" > "$T/d6.txt" 2>&1 && [ ! -e "$W3" ] && ! grep -q "^archived:" "$T/d6.txt" && [ -z "$(ls -A "$M/.git/concord/plans/T3" 2>/dev/null)" ] \
  && ok "worktree without a plan removed, nothing archived" || { bad "no-plan done"; cat "$T/d6.txt"; }
$WT new T4 --repo "$M" --no-fetch --base main > /dev/null 2>&1; W4="$M/.claude/worktrees/T4"; plan "$W4"; printf 'n\n' > "$W4/notes.txt"
printf 'my own notes\n' > "$W4/PLANNING.md"
$WT done T4 --repo "$M" > "$T/d7.txt" 2>&1; D7=$?
[ $D7 -ne 0 ] && grep -q "notes.txt" "$T/d7.txt" && ! grep -q "PLAN_T.md" "$T/d7.txt" && [ -f "$W4/PLAN_T.md" ] \
  && ok "refused: lists uncommitted notes.txt, not the plan" || { bad "T4 refusal rc=$D7"; cat "$T/d7.txt"; }
grep -q "PLANNING.md" "$T/d7.txt" && [ -f "$W4/PLANNING.md" ] && [ ! -e "$M/.git/concord/plans/T4/PLANNING.md" ] \
  && ok "only PLAN_*.md is a plan: PLANNING.md stays user work (listed, not archived)" || { bad "PLANNING.md treated as a plan"; cat "$T/d7.txt"; }
$WT done T4 --repo "$M" --force > "$T/d8.txt" 2>&1 && [ ! -e "$W4" ] && ok "--force removed T4" || { bad "T4 --force"; cat "$T/d8.txt"; }
cmp -s "$T/orig/PLAN_T.md" "$M/.git/concord/plans/T4/PLAN_T.md" && ok "--force still archived the plan" || bad "T4 plan lost by --force"
echo "== done never deletes a real folder that replaced a link"
$WT new T6 --repo "$M" --no-fetch --base main --link data > /dev/null 2>&1; W6="$M/.claude/worktrees/T6"
rm "$W6/data"; mkdir "$W6/data"; printf 'mine\n' > "$W6/data/work.csv"
$WT done T6 --repo "$M" > "$T/d9.txt" 2>&1; D9=$?
[ $D9 -ne 0 ] && grep -q "data" "$T/d9.txt" && [ -f "$W6/data/work.csv" ] && [ -f "$M/data/blob" ] \
  && ok "refused: real data/ folder inside the worktree listed, nothing deleted" || { bad "real-folder done rc=$D9"; cat "$T/d9.txt"; }
rm -rf "$W6/data"; $WT done T6 --repo "$M" > /dev/null 2>&1
echo "== failed removal leaves plan and links in place"
$WT new T7 --repo "$M" --no-fetch --base main --link bench > /dev/null 2>&1; W7="$M/.claude/worktrees/T7"; plan "$W7"
git -C "$M" worktree lock "$W7"
$WT done T7 --repo "$M" > "$T/d10.txt" 2>&1; D10=$?
[ $D10 -ne 0 ] && [ -f "$W7/PLAN_T.md" ] && [ -L "$W7/bench" ] && ok "locked worktree: removal refused, plan and link restored" \
  || { bad "locked done rc=$D10"; cat "$T/d10.txt"; ls -la "$W7"; }
git -C "$M" worktree unlock "$W7"
$WT done T7 --repo "$M" > "$T/d11.txt" 2>&1 && [ ! -e "$W7" ] && ok "unlocked: T7 removed" || { bad "T7 remove"; cat "$T/d11.txt"; }
echo "== archive never overwrites an earlier plan of the same ticket"
$WT new T1 --repo "$M" --no-fetch > /dev/null 2>&1; plan "$W1"; echo "# second round" >> "$W1/PLAN_T.md"
$WT done T1 --repo "$M" > "$T/d12.txt" 2>&1 || { bad "second T1 done"; cat "$T/d12.txt"; }
SECOND=$(ls "$M/.git/concord/plans/T1/" | grep -x 'PLAN_T\.[0-9]\{8\}-[0-9]\{6\}\.md' | head -1)
cmp -s "$T/orig/PLAN_T.md" "$M/.git/concord/plans/T1/PLAN_T.md" && [ -n "$SECOND" ] && grep -q "second round" "$M/.git/concord/plans/T1/$SECOND" \
  && ok "first archive intact, second plan saved as $SECOND" || { bad "archive overwrite"; ls -la "$M/.git/concord/plans/T1/"; }
echo "== fork and join: a phase's own worktree holding the ticket's uncommitted work"
$WT new T8 --repo "$M" --no-fetch --base main --link data > /dev/null 2>&1; W8="$M/.claude/worktrees/T8"
printf 'x = 2\n' > "$W8/a.py"; printf 'n = 1\n' > "$W8/new.py"; printf '# Plan T8\n' > "$W8/PLAN_T8.md"
st8(){ git -C "$W8" status --porcelain -uall; git -C "$W8" rev-parse HEAD; git -C "$W8" ls-files -s; }
B8=$(st8)
$WT fork T8 2 --repo "$W8" > "$T/f1.txt" 2>&1; RF=$?; F8="$M/.claude/worktrees/T8-p2"
[ $RF -eq 0 ] && grep -qF "$F8" "$T/f1.txt" && [ "$(cat "$F8/a.py" 2>/dev/null)" = "x = 2" ] && [ -f "$F8/new.py" ] \
  && [ -f "$F8/PLAN_T8.md" ] && [ -L "$F8/data" ] && ok "fork holds the tracked edit, the untracked file, the plan and the links" \
  || { bad "fork rc=$RF"; cat "$T/f1.txt"; }
[ "$(st8)" = "$B8" ] && ok "fork leaves the ticket's HEAD, index and status alone" || bad "fork changed the ticket worktree"
$WT fork T8 2 --repo "$W8" > "$T/f2.txt" 2>&1; RF2=$?
[ $RF2 -eq 2 ] && grep -q "exists" "$T/f2.txt" && ok "a second fork of the same phase exits 2" || { bad "second fork rc=$RF2"; cat "$T/f2.txt"; }
printf 'x = 3\n' > "$F8/a.py"; printf 'm = 1\n' > "$F8/made.py"
$WT join T8 2 --repo "$W8" > "$T/j1.txt" 2>&1; RJ=$?
[ $RJ -eq 0 ] && [ "$(cat "$W8/a.py")" = "x = 3" ] && [ "$(cat "$W8/made.py" 2>/dev/null)" = "m = 1" ] && [ "$(cat "$W8/new.py")" = "n = 1" ] \
  && [ ! -e "$F8" ] && [ -f "$M/data/blob" ] && ok "join applies the phase's changes and removes the fork (link target kept)" \
  || { bad "join rc=$RJ"; cat "$T/j1.txt"; }
$WT fork T8 3 --repo "$W8" > /dev/null 2>&1; F9="$M/.claude/worktrees/T8-p3"
[ -d "$F9" ] && printf 'x = 4\n' > "$F9/a.py"; printf 'x = 5\n' > "$W8/a.py"
$WT join T8 3 --repo "$W8" > "$T/j2.txt" 2>&1; RJ2=$?
[ $RJ2 -eq 2 ] && [ -d "$F9" ] && [ "$(cat "$W8/a.py")" = "x = 5" ] && grep -q "a.py" "$T/j2.txt" \
  && ok "a conflicting ticket edit: join exits 2, names a.py, keeps the fork" || { bad "conflict join rc=$RJ2"; cat "$T/j2.txt"; }
mkdir -p "$W8/sub"; printf 's\n' > "$W8/sub/s.txt"; F10="$M/.claude/worktrees/T8-p4"
( cd "$W8/sub" && $WT fork T8 4 > /dev/null 2>&1 ); FA=$(cat "$F10/a.py" 2>/dev/null); [ -d "$F10" ] && printf 't\n' > "$F10/top2.txt"
( cd "$W8/sub" && $WT join T8 4 > "$T/j3.txt" 2>&1 ); RJ3=$?
[ "$FA" = "x = 5" ] && [ -f "$W8/top2.txt" ] && [ ! -e "$F10" ] \
  && ok "fork and join from a subdirectory work on the whole checkout" || { bad "subdir join rc=$RJ3"; cat "$T/j3.txt"; }
echo "== join: committed work, the checkout it runs in, staged and ignored work of the fork"
git -C "$M" worktree remove --force "$F9" > /dev/null 2>&1
printf 'x = 5\n' > "$W8/a.py"; $WT fork T8 5 --repo "$W8" > /dev/null 2>&1; F5="$M/.claude/worktrees/T8-p5"; [ -d "$F5" ] || { echo "setup failed: fork 5"; exit 1; }
printf 'x = 7\n' > "$F5/a.py"; printf 'k = 1\n' > "$F5/kept.py"; git -C "$F5" add -A; git -C "$F5" -c user.email=t@t -c user.name=t commit -qm "work in the fork"
$WT join T8 5 --repo "$W8" > "$T/j5.txt" 2>&1; RJ5=$?
[ $RJ5 -eq 0 ] && [ "$(cat "$W8/a.py")" = "x = 7" ] && [ "$(cat "$W8/kept.py" 2>/dev/null)" = "k = 1" ] && [ ! -e "$F5" ] \
  && ok "join applies work committed in the fork (an edit and a new file)" || { bad "committed work lost rc=$RJ5 a.py='$(cat "$W8/a.py")'"; cat "$T/j5.txt"; }
$WT fork T8 6 --repo "$W8" > /dev/null 2>&1; F6="$M/.claude/worktrees/T8-p6"; [ -d "$F6" ] || { echo "setup failed: fork 6"; exit 1; }
printf 'o = 1\n' > "$F6/only6.py"
$WT join T8 6 --repo "$M" > "$T/j6.txt" 2>&1; RJ6=$?
[ $RJ6 -ne 0 ] && [ -d "$F6" ] && [ ! -e "$M/only6.py" ] && ok "join from a checkout other than the fork's origin is refused, the fork kept, that checkout untouched" \
  || { bad "join from another checkout rc=$RJ6"; cat "$T/j6.txt"; }
$WT join T8 6 --repo "$W8" > /dev/null 2>&1
printf 'x = 8\n' > "$W8/a.py"; $WT fork T8 7 --repo "$W8" > /dev/null 2>&1; F7="$M/.claude/worktrees/T8-p7"; [ -d "$F7" ] || { echo "setup failed: fork 7"; exit 1; }
printf 'x = 10\n' > "$F7/a.py"; git -C "$F7" add a.py; printf 'x = 11\n' > "$F7/a.py"
$WT join T8 7 --repo "$W8" > "$T/j7.txt" 2>&1; RJ7=$?
[ $RJ7 -ne 0 ] && [ -d "$F7" ] && [ "$(cat "$W8/a.py")" = "x = 8" ] && ok "join with staged content that differs from the working file is refused, the fork kept" \
  || { bad "staged differs rc=$RJ7"; cat "$T/j7.txt"; }
git -C "$F7" reset -q a.py; git -C "$F7" rm -q --cached a.py      # a staged deletion; the working file stays, untracked
$WT join T8 7 --repo "$W8" > "$T/j7b.txt" 2>&1; RJ7B=$?
[ $RJ7B -ne 0 ] && [ -d "$F7" ] && [ "$(cat "$W8/a.py")" = "x = 8" ] && grep -q 'a\.py' "$T/j7b.txt" \
  && ok "join with a staged deletion whose path exists again in the fork is refused, the fork kept, the path named" \
  || { bad "staged deletion of a recreated path rc=$RJ7B"; cat "$T/j7b.txt"; }
git -C "$F7" reset -q a.py; git -C "$F7" rm -q --cached a.py; git -C "$F7" -c user.email=t@t -c user.name=t commit -qm "drop a.py"   # a committed deletion; the file stays, untracked
$WT join T8 7 --repo "$W8" > "$T/j7c.txt" 2>&1; RJ7C=$?
[ $RJ7C -ne 0 ] && [ -d "$F7" ] && [ "$(cat "$W8/a.py")" = "x = 8" ] && grep -q 'a\.py' "$T/j7c.txt" \
  && ok "join with a committed deletion whose path exists again in the fork is refused, the fork kept, the path named" \
  || { bad "committed deletion of a recreated path rc=$RJ7C"; cat "$T/j7c.txt"; }
git -C "$F7" reset -q HEAD~1; $WT join T8 7 --repo "$W8" > /dev/null 2>&1
$WT fork T8 8 --repo "$W8" > /dev/null 2>&1; F8="$M/.claude/worktrees/T8-p8"; [ -d "$F8" ] || { echo "setup failed: fork 8"; exit 1; }
printf 'x = 12\n' > "$F8/a.py"; mkdir -p "$F8/build"; printf 'o\n' > "$F8/build/only-here.o"
$WT join T8 8 --repo "$W8" > "$T/j8.txt" 2>&1; RJ8=$?
[ $RJ8 -ne 0 ] && [ -d "$F8" ] && [ -f "$F8/build/only-here.o" ] && grep -q "build" "$T/j8.txt" \
  && ok "join with an ignored file only the fork holds (build/only-here.o) is refused, the fork kept, the file named" || { bad "ignored file only in the fork rc=$RJ8"; cat "$T/j8.txt"; }
$WT join T8 8 --repo "$W8" --force > "$T/j8f.txt" 2>&1; RJ8F=$?
[ $RJ8F -eq 0 ] && [ ! -e "$F8" ] && grep -q "^dropped (--force):" "$T/j8f.txt" && grep -q "only-here.o" "$T/j8f.txt" \
  && ok "join --force joins anyway and prints 'dropped (--force):' naming the ignored file it dropped" || { bad "join --force rc=$RJ8F"; cat "$T/j8f.txt"; }
$WT fork T8 9 --repo "$W8" > /dev/null 2>&1; F9B="$M/.claude/worktrees/T8-p9"; [ -d "$F9B" ] || { echo "setup failed: fork 9"; exit 1; }
printf 'o9 = 1\n' > "$F9B/only9.py"; rm -f "$(git -C "$F9B" rev-parse --path-format=absolute --git-dir)/.wt-fork"
$WT join T8 9 --repo "$W8" > "$T/j9.txt" 2>&1; RJ9=$?
[ $RJ9 -ne 0 ] && [ -d "$F9B" ] && [ ! -e "$W8/only9.py" ] && grep -q "before 3.0" "$T/j9.txt" \
  && ok "a fork without .wt-fork (made by an older wt.py) is refused and kept, with the reason" || { bad "fork without .wt-fork rc=$RJ9"; cat "$T/j9.txt"; }
$WT join T8 9 --repo "$W8" --force > /dev/null 2>&1
echo "== done and join do not over-refuse: tracked .claude files, cache folders, unchanged copies, copies of an older wt.py"
# mkr DIR [TRACKED_CLAUDE]: a repo with mod.py, an ignored __pycache__/ and, with the argument, a tracked .claude/settings.json
mkr(){ rm -rf "$1"; mkdir -p "$1"; ( cd "$1" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > mod.py; printf '__pycache__/\n' > .gitignore
  if [ -n "${2:-}" ]; then mkdir -p .claude; printf '{}\n' > .claude/settings.json; else printf '.claude/\n' >> .gitignore; fi
  git add -A && git commit -qm init ); }
mkr "$T/r5" tracked; $WT new T5 --repo "$T/r5" --no-fetch > /dev/null 2>&1
$WT done T5 --repo "$T/r5" > "$T/d5.txt" 2>&1; RD5=$?
[ $RD5 -eq 0 ] && [ ! -e "$T/r5/.claude/worktrees/T5" ] \
  && ok "done removes a clean worktree of a repo that tracks .claude/settings.json" || { bad "tracked .claude/settings.json rc=$RD5"; cat "$T/d5.txt"; }
mkr "$T/r6"; $WT new T6 --repo "$T/r6" --no-fetch > /dev/null 2>&1; W6="$T/r6/.claude/worktrees/T6"
$WT fork T6 1 --repo "$W6" > /dev/null 2>&1; F6B="$T/r6/.claude/worktrees/T6-p1"
printf 'x = 2\n' > "$F6B/mod.py"; mkdir -p "$F6B/__pycache__"; printf 'pyc\n' > "$F6B/__pycache__/mod.cpython-39.pyc"
$WT join T6 1 --repo "$W6" > "$T/j6b.txt" 2>&1; RJ6B=$?
[ $RJ6B -eq 0 ] && [ "$(cat "$W6/mod.py")" = "x = 2" ] && [ ! -e "$F6B" ] \
  && ok "join ignores an ignored __pycache__ folder of the fork (the folders done treats as disposable)" || { bad "join with __pycache__ rc=$RJ6B"; cat "$T/j6b.txt"; }
mkr "$T/r7"; $WT new T7 --repo "$T/r7" --no-fetch > /dev/null 2>&1; W7="$T/r7/.claude/worktrees/T7"
printf '# Plan\n' > "$W7/PLAN_T7.md"; $WT fork T7 1 --repo "$W7" > /dev/null 2>&1; F7B="$T/r7/.claude/worktrees/T7-p1"
printf 'x = 3\n' > "$F7B/mod.py"; printf '# Plan\n## Passes\n- pass 1 done\n' > "$W7/PLAN_T7.md"
$WT join T7 1 --repo "$W7" > "$T/j7b.txt" 2>&1; RJ7B=$?
[ $RJ7B -eq 0 ] && [ "$(cat "$W7/mod.py")" = "x = 3" ] && grep -q "^## Passes" "$W7/PLAN_T7.md" && [ ! -e "$F7B" ] \
  && ok "join: the fork's copy of the plan, unchanged, is not unique to the fork although the ticket's plan was edited since" || { bad "edited ticket plan blocks join rc=$RJ7B"; cat "$T/j7b.txt"; }
mkr "$T/r8"; mkdir -p "$T/r8/.claude"; printf '{}\n' > "$T/r8/.claude/settings.local.json"; $WT new T8b --repo "$T/r8" --no-fetch > /dev/null 2>&1
rm -f "$(git -C "$T/r8/.claude/worktrees/T8b" rev-parse --path-format=absolute --git-dir)/.wt-copies"      # a worktree an older wt.py made
$WT done T8b --repo "$T/r8" > "$T/d8b.txt" 2>&1; RD8B=$?
[ $RD8B -eq 0 ] && [ ! -e "$T/r8/.claude/worktrees/T8b" ] \
  && ok "done on a worktree without .wt-copies: a .claude copy equal to the main checkout's file is disposable" || { bad "worktree without .wt-copies rc=$RD8B"; cat "$T/d8b.txt"; }
echo "== join and done keep a symlink the user made: only the links wt.py made are exempt"
# A fork holds an ignored symlink the user made (*.lnk is excluded) next to the link wt.py made (data). The origin's entry
# is the same only when it is also a link with the same target text.
mkr "$T/r9"; mkdir "$T/r9/data"; printf 'b\n' > "$T/r9/data/blob"; printf '*.lnk\n' >> "$T/r9/.git/info/exclude"
printf 'elsewhere\n' > "$T/elsewhere.txt"; printf 'other\n' > "$T/other.txt"
$WT new T9L --repo "$T/r9" --no-fetch --link data > /dev/null 2>&1; W9L="$T/r9/.claude/worktrees/T9L"
# fork9 N: fork N of T9L holding an edit of mod.py and the user's ignored symlink; setup stops if either is missing
fork9() { $WT fork T9L "$1" --repo "$W9L" > /dev/null 2>&1; F9L="$T/r9/.claude/worktrees/T9L-p$1"
  printf 'x = 5\n' > "$F9L/mod.py"; ln -s "$T/elsewhere.txt" "$F9L/scratch.lnk"
  { [ -L "$F9L/data" ] && [ -L "$F9L/scratch.lnk" ] && git -C "$F9L" status --porcelain --ignored | grep -q '^!! scratch.lnk$'; } \
    || { echo "setup failed: fork $1 with an ignored user symlink"; exit 1; }; }
fork9 1
$WT join T9L 1 --repo "$W9L" > "$T/j9l1.txt" 2>&1; RJ9L1=$?
[ $RJ9L1 -ne 0 ] && [ -d "$F9L" ] && [ -L "$F9L/scratch.lnk" ] && [ "$(cat "$W9L/mod.py")" = "x = 1" ] && grep -q "scratch.lnk" "$T/j9l1.txt" && ! grep -q "^  data" "$T/j9l1.txt" \
  && ok "join with an ignored symlink only the fork holds (made by the user) is refused, the fork and the link kept, the link named and not wt.py's own data link" \
  || { bad "join with a user symlink only in the fork rc=$RJ9L1"; cat "$T/j9l1.txt"; }
[ -d "$F9L" ] || fork9 1
$WT join T9L 1 --repo "$W9L" --force > /dev/null 2>&1; rm -f "$W9L/mod.py"; git -C "$W9L" checkout -q -- mod.py
fork9 2; ln -sf "$T/other.txt" "$W9L/scratch.lnk"
$WT join T9L 2 --repo "$W9L" > "$T/j9l2.txt" 2>&1; RJ9L2=$?
[ $RJ9L2 -ne 0 ] && [ -d "$F9L" ] && grep -q "scratch.lnk" "$T/j9l2.txt" \
  && ok "join: an origin entry that is a link with another target does not make the fork's link the same" || { bad "join with a link of another target rc=$RJ9L2"; cat "$T/j9l2.txt"; }
[ -d "$F9L" ] || fork9 2
$WT join T9L 2 --repo "$W9L" --force > /dev/null 2>&1; git -C "$W9L" checkout -q -- mod.py
fork9 3; ln -sf "$T/elsewhere.txt" "$W9L/scratch.lnk"
$WT join T9L 3 --repo "$W9L" > "$T/j9l3.txt" 2>&1; RJ9L3=$?
[ $RJ9L3 -eq 0 ] && [ ! -e "$F9L" ] && [ "$(cat "$W9L/mod.py")" = "x = 5" ] && [ -L "$W9L/scratch.lnk" ] && [ -f "$T/r9/data/blob" ] \
  && ok "join: the origin holds the same link (same target text): joins, removes the fork, keeps the link and the data folder" || { bad "join with the same link in the origin rc=$RJ9L3"; cat "$T/j9l3.txt"; }
mkr "$T/r10"; mkdir "$T/extdir"; printf 'keep\n' > "$T/extdir/f"
$WT new T10D --repo "$T/r10" --no-fetch > /dev/null 2>&1; W10D="$T/r10/.claude/worktrees/T10D"
$WT new T10F --repo "$T/r10" --no-fetch > /dev/null 2>&1; W10F="$T/r10/.claude/worktrees/T10F"
mkdir -p "$W10D/.claude" "$W10F/.claude"; ln -s "$T/extdir" "$W10D/.claude/extdir"; ln -s "$T/extdir/f" "$W10F/.claude/extfile"
{ [ -L "$W10D/.claude/extdir" ] && [ -L "$W10F/.claude/extfile" ] && [ -z "$(git -C "$W10D" status --porcelain)" ]; } || { echo "setup failed: worktrees with a symlink under .claude"; exit 1; }
$WT done T10D --repo "$T/r10" > "$T/d10d.txt" 2>&1; RD10D=$?
[ $RD10D -ne 0 ] && [ -L "$W10D/.claude/extdir" ] && grep -q ".claude/extdir" "$T/d10d.txt" && [ -f "$T/extdir/f" ] \
  && ok "done with a user symlink to a directory under an ignored .claude/ is refused without --force, the link kept and named" || { bad "done with a symlink to a directory under .claude rc=$RD10D"; cat "$T/d10d.txt"; }
$WT done T10F --repo "$T/r10" > "$T/d10f.txt" 2>&1; RD10F=$?
[ $RD10F -ne 0 ] && [ -L "$W10F/.claude/extfile" ] && grep -q ".claude/extfile" "$T/d10f.txt" \
  && ok "done with a user symlink to a file under an ignored .claude/ is refused without --force, the link kept and named" || { bad "done with a symlink to a file under .claude rc=$RD10F"; cat "$T/d10f.txt"; }
$WT done T10D --repo "$T/r10" --force > /dev/null 2>&1; $WT done T10F --repo "$T/r10" --force > /dev/null 2>&1
$WT done T9L --repo "$T/r9" --force > /dev/null 2>&1
$WT done T8 --repo "$M" --force > /dev/null 2>&1
[ "$(git -C "$M" worktree list --porcelain | grep -c 'worktrees/T')" = 0 ] && ok "worktree list clean" || bad "worktrees left"
echo; echo "passed $pass, failed $fail"; rm -rf "$T"; [ $fail -eq 0 ]
