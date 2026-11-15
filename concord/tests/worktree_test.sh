#!/bin/bash
# Worktree regression (53 checks, ~20 s, no network, fake qwen executor): wt.py new/list/done/fork/join, concord.py
# locks per set of files (disjoint runs share a checkout), per-checkout "last", main-checkout snapshot ignoring nested worktrees, done refusals,
# plan archive on done, OVERLAP and DRIFT lines in `wt.py list`.
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
plan "$W1"; plan "$W2"; plan "$M"; mkdir -p "$T/orig"; plan "$T/orig"
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
printf '# Plan\n## Phase 1 - change a\nExecutor: deepseek-flash\nFiles: a.py\nAcceptance:\n- `grep -q y a.py`\n\n## Phase 2 - make b\nExecutor: deepseek-flash\nFiles: b.py, z.py\nAcceptance:\n- `grep -q y b.py`\n\n## Phase 3 - no Files\nExecutor: deepseek-flash\nAcceptance:\n- `true`\n' > "$W1/PLAN_F.md"
FAKE_ACTIONS="i=0; while [ ! -e '$T/release2' ] && [ \$i -lt 300 ]; do sleep 0.1; i=\$((i+1)); done; echo y >> a.py" \
  $DP 1 --plan PLAN_F.md --via qwen --model fake/m --no-baseline --repo "$W1" > "$T/f1.txt" 2>&1 & PF=$!
i=0; until [ -e "$L1" ] || [ $i -ge 100 ]; do sleep 0.1; i=$((i+1)); done
printf 'z\n' > "$W1/z.py"; FAKE_ACTIONS='echo y > b.py; rm z.py' $DP 2 --plan PLAN_F.md --via qwen --model fake/m --no-baseline --repo "$W1" > "$T/f2.txt" 2>&1; F2=$?
FAKE_ACTIONS='true' $DP 3 --plan PLAN_F.md --via qwen --model fake/m --no-baseline --repo "$W1" > "$T/f3.txt" 2>&1; F3=$?
touch "$T/release2"; wait $PF; F1=$?
[ $F2 -eq 0 ] && grep -q "b.py" "$T/f2.txt" && ok "a run with disjoint Files ran in the same checkout while another ran" \
  || { bad "disjoint run rc=$F2"; tail -3 "$T/f2.txt"; }
[ $F3 -eq 2 ] && grep -q "another delegated run is active in this checkout" "$T/f3.txt" \
  && ok "a run with no Files is refused while another runs (exit 2)" || { bad "no-Files run rc=$F3"; tail -3 "$T/f3.txt"; }
[ $F1 -eq 0 ] && ! grep -E "^(OUT OF SCOPE|DELETED)" "$T/f1.txt" | grep -qE "b.py|z.py" && grep -q "^diff size: 2 lines (+2 -0)" "$T/f1.txt" \
  && ok "the long run leaves the concurrent run's b.py and deleted z.py out of OUT OF SCOPE, DELETED and its diff size" \
  || { bad "concurrent scope rc=$F1"; grep -iE "scope|deleted|diff size" "$T/f1.txt"; }
[ ! -e "$L1" ] && ok "the lock file is gone once both runs ended" || bad "lock file left: $(cat "$L1" 2>&1)"
rm -f "$W1/b.py" "$W1/PLAN_F.md"
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
[ $D3 -ne 0 ] && grep -q "results/" "$T/d3.txt" && ! grep -q "build/" "$T/d3.txt" && [ -L "$W2/data" ] && [ -f "$W2/results/r.json" ] \
  && ok "refused: lists ignored results/ (not build/), worktree intact" || { bad "ignored-data check rc=$D3"; cat "$T/d3.txt"; }
rm -rf "$W2/results"; chmod 444 "$W2/.claude/settings.local.json"     # stands in for the sandbox's write protection
$WT done T2 --repo "$M" > "$T/d4.txt" 2>&1; D4=$?
[ $D4 -ne 0 ] && grep -q "write-protects" "$T/d4.txt" && grep -q "settings.local.json" "$T/d4.txt" && [ -L "$W2/data" ] && [ -f "$W2/build/out.o" ] \
  && ok "refused: protected file reported, nothing touched" || { bad "protected check rc=$D4"; cat "$T/d4.txt"; }
[ ! -e "$M/.git/concord/plans/T2/PLAN_T.md" ] && ok "refused runs archive nothing" || bad "plan archived although done refused"
chmod 644 "$W2/.claude/settings.local.json"
$WT done T2 --repo "$M" > "$T/d5.txt" 2>&1 && [ ! -e "$W2" ] && ok "T2 removed (build/ output went with it)" || { bad "T2 remove"; cat "$T/d5.txt"; }
[ -f "$M/.git/concord/plans/T2/PLAN_T.md" ] && ok "T2 plan archived" || bad "T2 plan not archived"
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
git -C "$M" worktree remove --force "$F9" > /dev/null 2>&1; $WT done T8 --repo "$M" --force > /dev/null 2>&1
[ "$(git -C "$M" worktree list --porcelain | grep -c 'worktrees/T')" = 0 ] && ok "worktree list clean" || bad "worktrees left"
echo; echo "passed $pass, failed $fail"; rm -rf "$T"; [ $fail -eq 0 ]
