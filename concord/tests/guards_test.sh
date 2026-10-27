#!/bin/bash
# concord.py guards (2026-10-20, PLAN_kit-guards; lean revision 2026-10-23): the 4th start of a phase after three
# EXECUTOR failures is refused (exit 8) and --user-approved records the user's go-ahead; what counts as an attempt;
# the plugin agent names (concord:<name>) in the packet hint, --review-record --reviewer and --begin --label.
# No network: fake qwen executor.
# Run: bash ~/.claude/concord/tests/guards_test.sh   (exit 0 = all passed).
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/guards-test.XXXXXX")" && pwd -P)"; export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/concord" "$T/home/.claude"
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
cat > "$T/bin/qwen" <<'Q'
#!/bin/sh
echo ran >> "$T/qwen_calls"
sh -c "${FAKE_ACTIONS:-true}"; exit 0
Q
chmod +x "$T/bin/qwen"
# Prefer the developer dir's real git/python3 over the /usr/bin xcrun shims (they print cache errors in the sandbox).
XDEV="$(xcode-select -p 2>/dev/null)"; [ -n "$XDEV" ] && [ -x "$XDEV/usr/bin/git" ] && [ -x "$XDEV/usr/bin/python3" ] && export PATH="$XDEV/usr/bin:$PATH"
export PATH="$T/bin:$PATH" HOME="$T/home"
DP="python3 $T/concord/concord.py"
R="$T/repo"; RUNS="$R/.git/concord"; LOCK="$R/.git/concord.lock"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
has(){ grep -F -- "$1" "$T/out.txt" > /dev/null; }
calls(){ [ -f "$T/qwen_calls" ] && wc -l < "$T/qwen_calls" | tr -d ' ' || echo 0; }
ndirs(){ find "$RUNS" -mindepth 1 -maxdepth 1 -type d ! -name ledger | wc -l | tr -d ' '; }
rid(){ sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1; }
# run PHASE PLAN [args]: one fake executor run that appends to a.py; output in out.txt
run(){ local ph=$1 pl=$2; shift 2
  FAKE_ACTIONS="echo '# r' >> a.py" $DP "$ph" --plan "$pl" --via qwen --model fake/m --no-baseline --repo "$R" "$@" > "$T/out.txt" 2>&1; }
verdict(){ $DP --verdict "$@" --repo "$R" > "$T/out.txt" 2>&1; }
printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n' > "$T/clean.txt"
phase(){ printf '## Phase %s - p%s\nExecutor: deepseek-flash\n%bFiles: a.py\nAcceptance:\n- `%s`\n' "$1" "$1" "$2" "$3"; }
mkdir -p "$R" && ( cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > a.py; printf '.claude/\n' > .gitignore; git add -A && git commit -qm init
  { echo '# Plan'; phase 1 '' 'grep -q 2 a.py'; phase 2 '' 'grep -q 2 a.py'; phase 3 'Risk: medium\n' 'grep -q 2 a.py'
    phase 5 'Risk: low\n' 'grep -q 2 a.py'; } > PLAN_G.md
  { echo '# Plan'; phase 1 '' 'grep -q 2 a.py'; } > PLAN_H.md ) || { echo "setup failed"; exit 1; }

echo "== attempt cap"
for i in 1 2 3; do
  run 1 PLAN_G.md; X=$(rid); [ -n "$X" ] || { echo "setup failed: run $i"; cat "$T/out.txt"; exit 1; }
  verdict "$X" FAIL --cause EXECUTOR
done
C0=$(calls); N0=$(ndirs)
run 1 PLAN_G.md; RC=$?
[ $RC -eq 8 ] && [ "$(calls)" = "$C0" ] && [ "$(ndirs)" = "$N0" ] && [ ! -e "$LOCK" ] && grep -q "^REFUSED:" "$T/out.txt" \
  && has "--user-approved" && ok "4th start refused (exit 8): no executor call, no run dir, no lock" \
  || { bad "4th start rc=$RC"; tail -3 "$T/out.txt"; }
for DRY in "" --dry-run; do
  N0=$(ndirs); $DP --begin 1 --label implementer --plan PLAN_G.md $DRY --repo "$R" > "$T/out.txt" 2>&1; RC=$?
  [ $RC -eq 0 ] && $DP --abort last --repo "$R" > /dev/null 2>&1
  [ $RC -eq 8 ] && [ "$(ndirs)" = "$N0" ] && [ ! -e "$LOCK" ] && ok "--begin $DRY refused (exit 8)" || bad "--begin $DRY rc=$RC"
done
FAKE_ACTIONS=true $DP --dry-run 1 --plan PLAN_G.md --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "DRY RUN" && ok "a dry run is not refused" || { bad "dry run rc=$RC"; tail -2 "$T/out.txt"; }
run 2 PLAN_G.md; RC=$?; S1=$(rid)
[ $RC -eq 0 ] && [ -n "$S1" ] && ok "another phase is not blocked" || { bad "other phase rc=$RC"; tail -2 "$T/out.txt"; }
run 1 PLAN_H.md; RC=$?
[ $RC -eq 0 ] && ok "another plan file with the same phase is not blocked" || { bad "other plan rc=$RC"; tail -2 "$T/out.txt"; }
git -C "$R" worktree add -q "$T/wt" -b wt && cp "$R/PLAN_G.md" "$T/wt/"
FAKE_ACTIONS=true $DP 1 --plan PLAN_G.md --via qwen --model fake/m --no-baseline --repo "$T/wt" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && ok "a worktree with the same plan path is not blocked" || { bad "worktree rc=$RC"; tail -2 "$T/out.txt"; }
run 1 PLAN_G.md --user-approved "   "; RC=$?
[ $RC -eq 8 ] && ok "a whitespace-only --user-approved is no approval" || bad "blank approval rc=$RC"
run 1 PLAN_G.md --user-approved "$(printf 'go\nahead')"; RC=$?; RA=$(rid)
[ $RC -eq 0 ] && [ -n "$RA" ] && grep -qF "user approved a run beyond the attempt cap: go ahead" "$RUNS/$RA/report.md" \
  && ok "--user-approved starts the run; the quote is one report line" || { bad "approved run rc=$RC"; tail -3 "$T/out.txt"; }
verdict "$RA" PASS
run 1 PLAN_G.md; RC=$?
[ $RC -eq 0 ] && ok "a PASS resets the count" || { bad "after PASS rc=$RC"; tail -2 "$T/out.txt"; }

echo "== what counts"
verdict "$S1" FAIL --cause EXECUTOR; verdict "$S1" FAIL --cause EXECUTOR
run 2 PLAN_G.md; verdict "$(rid)" FAIL --cause PLAN_GAP
run 2 PLAN_G.md; verdict "$(rid)" FAIL --cause EXECUTOR
mkdir -p "$RUNS/20000101-000000-junk-p2" "$RUNS/20000101-000001-junk-p2"
printf '[]' > "$RUNS/20000101-000000-junk-p2/meta.json"
printf '{"run_id": "20000101-000001-junk-p2", "plan": "PLAN_G.md", "phase": 2, "verdict": "FA' > "$RUNS/20000101-000001-junk-p2/meta.json"
run 2 PLAN_G.md; RC=$?
[ $RC -eq 0 ] && ! has "Traceback" \
  && ok "two counted fails: other causes, a second verdict on one run and broken meta.json files do not count" \
  || { bad "count rc=$RC"; tail -2 "$T/out.txt"; }
rm -rf "$RUNS"/20000101-*

echo "== plugin names (agents are concord:<name> inside the Claude Code plugin)"
run 3 PLAN_G.md; P=$(rid)
$DP --review "$P" --packet --repo "$R" > "$T/out.txt" 2>&1
has "subagent_type concord:reviewer-opus55 with prompt" && ok "the packet hint names the plugin agent" || bad "packet hint"
$DP --review-record "$P" --reviewer concord:reviewer-opus48 --file "$T/clean.txt" --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && [ "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["reviews"][-1]["reviewer"])' "$RUNS/$P/meta.json")" = reviewer-opus48 ] \
  && ok "--review-record --reviewer concord:reviewer-opus48 is stored as reviewer-opus48" || { bad "plugin reviewer rc=$RC"; tail -2 "$T/out.txt"; }
$DP --begin 5 --label Concord:Implementer --plan PLAN_G.md --repo "$R" > "$T/out.txt" 2>&1; RC=$?
B=$(sed -n 's/.*concord.py --end \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
[ $RC -eq 0 ] && [ -n "$B" ] && ok "--begin --label Concord:Implementer is accepted as implementer" || { bad "plugin label rc=$RC"; tail -2 "$T/out.txt"; }
[ -z "$B" ] || $DP --abort "$B" --repo "$R" > /dev/null 2>&1

echo "== drift brakes and the plan-verifier gate (2026-10-25)"
D="$T/d"; mkdir -p "$D" && ( cd "$D" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > a.py; git add -A && git commit -qm init
  { printf '# Plan\nTier: M\nSize: ~4 lines\nETA: 10 min\n\n## Open questions\n- Q1 none\n\n'; phase 1 '' 'grep -q 2 a.py'; } > PLAN_D.md ) \
  || { echo "setup failed"; exit 1; }
drun(){ FAKE_ACTIONS=true $DP 1 --plan PLAN_D.md --via qwen --model fake/m --no-baseline --repo "$D" "$@" > "$T/out.txt" 2>&1; }
drift(){ $DP --drift --plan PLAN_D.md --repo "$D" > "$T/out.txt" 2>&1; }
hook(){ printf '{"cwd": "%s"}' "$D" | $DP --drift-hook > "$T/out.txt" 2>&1; }
clock(){ python3 -I -c 'import json,sys,time; p,r=sys.argv[1:3]; d=json.load(open(p)); d[r].update(elapsed=float(sys.argv[3]), last=time.time()-float(sys.argv[4])); json.dump(d,open(p,"w"))' "${3:-$D}/.git/concord/drift.json" "${3:-$D}" "$1" "$2"; }
drun; RC=$?
[ $RC -eq 11 ] && has "no plan-verifier APPROVE" && ok "a Tier: plan with no plan-verifier APPROVE is refused (exit 11)" || { bad "no verdict rc=$RC"; tail -2 "$T/out.txt"; }
printf 'VERDICT: REVISE\n' > "$T/v.txt"; $DP --plan-verdict "$T/v.txt" --plan PLAN_D.md --repo "$D" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 1 ] && has "nothing recorded" && ok "--plan-verdict REVISE records nothing" || bad "REVISE rc=$RC"
printf '**VERDICT:** APPROVE\n' > "$T/v.txt"; $DP --plan-verdict "$T/v.txt" --plan PLAN_D.md --repo "$D" > /dev/null 2>&1
perl -pi -e 's/Q1 none/Q1 settled by the owner/' "$D/PLAN_D.md"; drun; RC=$?
[ $RC -eq 0 ] && ok "APPROVE recorded; an Open questions edit keeps it" || { bad "approved run rc=$RC"; tail -2 "$T/out.txt"; }
drift; RC=$?; [ $RC -eq 0 ] && has "DRIFT OK" && ok "--drift: OK after the first run" || { bad "drift OK rc=$RC"; tail -2 "$T/out.txt"; }
clock 780 3600; drift
has "time 13/10 min (1.30x)" && has "DRIFT WARN" && ok "time warns at 1.2x; an idle gap of 10 minutes or more does not count" || { bad "time warn"; tail -2 "$T/out.txt"; }
clock 0 0; drift; printf '# 1\n# 2\n# 3\n# 4\n# 5\n' >> "$D/a.py"; hook
has '"hookEventName": "PostToolUse"' && has "DRIFT WARN" && has "size 5/4 lines" && ok "the hook prints a level change (size 1.25x)" || { bad "hook warn"; cat "$T/out.txt"; }
hook; [ ! -s "$T/out.txt" ] && ok "the hook is silent while the level stays" || bad "hook repeat"
printf '# 6\n# 7\n' >> "$D/a.py"; drun; RC=$?
[ $RC -eq 10 ] && has "DRIFT BLOCK" && ok "size at 1.5x blocks the next run (exit 10)" || { bad "size block rc=$RC"; tail -2 "$T/out.txt"; }
drun --user-approved "go on"; RC=$?; drift
[ $RC -eq 0 ] && has "DRIFT WARN" && ok "--user-approved lifts the block until the measure grows 50% more" || { bad "approved rc=$RC"; tail -2 "$T/out.txt"; }
grep -rqs "user approved: go on" "$D/.git/concord" && ok "the run records the owner's words that passed a gate" || bad "approval note"
printf 'y = 1\n' > "$D/b.py"; drun; RC=$?
[ $RC -eq 10 ] && has "changed outside Files: b.py" && ok "a changed file outside Files blocks (exit 10)" || { bad "scope rc=$RC"; tail -2 "$T/out.txt"; }
git -C "$D" worktree add -q "$T/df" > /dev/null 2>&1; cp "$D/PLAN_D.md" "$T/df/"
FAKE_ACTIONS=true $DP 1 --plan PLAN_D.md --via qwen --model fake/m --no-baseline --repo "$T/df" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 10 ] && has "DRIFT BLOCK" && ok "a run in a fork (another worktree) is gated by the ticket checkout's drift (exit 10)" \
  || { bad "fork rc=$RC"; tail -2 "$T/out.txt"; }
python3 -I - "$D/.git/concord" "$D" "$T/held" <<'EOF' &
import fcntl, json, sys, time
root, key, flag = sys.argv[1:4]
with open(root + "/drift.lock", "a") as lock:      # another writer (an approval) holds the lock for 1.5 s
    fcntl.flock(lock, fcntl.LOCK_EX); open(flag, "w").close(); time.sleep(1.5)
    d = json.load(open(root + "/drift.json")); d[key]["ok"] = {"time": 99.0, "files": ["held.py"]}
    json.dump(d, open(root + "/drift.json", "w"))
EOF
HP=$!; for i in $(seq 100); do [ -e "$T/held" ] && break; sleep 0.05; done; hook; wait $HP
python3 -I -c 'import json,sys; sys.exit(json.load(open(sys.argv[1]))[sys.argv[2]].get("ok", {}).get("files") != ["held.py"])' "$D/.git/concord/drift.json" "$D" \
  && ok "a hook tick during another writer's drift.lock keeps that writer's approval" || { bad "approval lost to a hook tick"; cat "$T/out.txt"; }
$DP --lint 1 --via qwen --model fake/m --plan PLAN_G.md --repo "$R" > "$T/out.txt" 2>&1
has 'PLAN LINT: no `Size:` line' && has 'PLAN LINT: no `ETA:` line' && ok "--lint flags a plan with no Size: or ETA:" || { bad "lint"; tail -3 "$T/out.txt"; }

E="$T/e"; mkdir -p "$E" && ( cd "$E" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > café.py; git add -A && git commit -qm init
  printf '# Plan\nTier: L\nSize: ~1,200 lines\nETA: 10 min\n\n### Phase 1 - p\nExecutor: deepseek-flash\nFiles: café.py\nAcceptance:\n- `true`\n' > PLAN_E.md ) \
  || { echo "setup failed"; exit 1; }
$DP --plan-verdict "$T/v.txt" --plan PLAN_E.md --repo "$E" > /dev/null 2>&1
FAKE_ACTIONS=true $DP 1 --plan PLAN_E.md --via qwen --model fake/m --no-baseline --repo "$E" > /dev/null 2>&1
printf 'y = 2\n' >> "$E/café.py"; $DP --drift --plan PLAN_E.md --repo "$E" > "$T/out.txt" 2>&1
has "DRIFT OK" && has "size 1/1200 lines" && has "every changed file is in Files" \
  && ok "### Phase heads, a non-ASCII path and Size: ~1,200 are read right" || { bad "heads, path, size"; tail -2 "$T/out.txt"; }
( cd "$E" && git commit -qam ticket && git checkout -qb up HEAD~1 && printf 'z = 1\n' > c.py && git add c.py \
  && git commit -qm upstream && git checkout -q main && git merge -q --no-edit up ) > /dev/null 2>&1
$DP --drift --plan PLAN_E.md --repo "$E" > "$T/out.txt" 2>&1
has "size 1/1200 lines" && has "every changed file is in Files" \
  && ok "a merge of upstream work moves the drift base: its files and lines do not count" || { bad "upstream merge"; tail -2 "$T/out.txt"; }
mkdir -p "$E/.git/concord/run-x"; clock 0 1500 "$E"
python3 -I -c 'import json,sys,time; d=sys.argv[1]; json.dump({"plan": "PLAN_E.md", "started": time.time() - 1500, "mode": "edit", "pid": int(sys.argv[2])}, open(d + "/state.json", "w")); json.dump({"seconds": 1500}, open(d + "/meta.json", "w"))' "$E/.git/concord/run-x" $$
$DP --drift --plan PLAN_E.md --repo "$E" > "$T/out.txt" 2>&1
has "time 25/10 min" && ok "a long gap counts where a run of the plan covered it" || { bad "run time"; tail -2 "$T/out.txt"; }
rm "$E/.git/concord/run-x/meta.json"; clock 0 1200 "$E"; $DP --drift --plan PLAN_E.md --repo "$E" > "$T/out.txt" 2>&1
has "time 20/10 min" && ok "a run still in progress covers the gap up to now" || { bad "running time"; tail -2 "$T/out.txt"; }
sh -c 'exit 0' & DEAD=$!; wait $DEAD
python3 -I -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["pid"]=int(sys.argv[2]); json.dump(s,open(p,"w"))' "$E/.git/concord/run-x/state.json" "$DEAD"
clock 0 1200 "$E"; $DP --drift --plan PLAN_E.md --repo "$E" > "$T/out.txt" 2>&1
has "time 0/10 min" && ok "a killed run (no report, its process gone) covers no gap" || { bad "killed run"; tail -2 "$T/out.txt"; }
printf 'NOT RUN\n' > "$E/.git/concord/run-x/report.md"; clock 0 1200 "$E"; $DP --drift --plan PLAN_E.md --repo "$E" > "$T/out.txt" 2>&1
has "time 0/10 min" && ok "a refused run (a report, no meta.json) covers no gap" || { bad "refused run"; tail -2 "$T/out.txt"; }

F="$T/f"; mkdir -p "$F" && ( cd "$F" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > a.py; git add -A && git commit -qm init
  { printf '# Plan\nTier: M\nSize: ~40 lines\nETA: 10 min\n\n'; phase 1 '' 'true'; } > PLAN_F.md ) || { echo "setup failed"; exit 1; }
$DP --plan-verdict "$T/v.txt" --plan PLAN_F.md --repo "$F" > /dev/null 2>&1
git -C "$F" worktree add -q "$T/ff" > /dev/null 2>&1; cp "$F/PLAN_F.md" "$T/ff/"
FAKE_ACTIONS=true $DP 1 --plan PLAN_F.md --via qwen --model fake/m --no-baseline --repo "$T/ff" > /dev/null 2>&1
printf 'y = 2\n' >> "$F/a.py"; git -C "$F" worktree remove --force "$T/ff"      # wt.py join: patch applied, fork removed
$DP --drift --plan PLAN_F.md --repo "$F" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "DRIFT OK" && has "size 1/40 lines" \
  && python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(sys.argv[2] not in d or sys.argv[3] in d)' "$F/.git/concord/drift.json" "$F" "$T/ff" \
  && ok "after a fork is joined and removed, the ticket checkout takes over the fork's drift entry" || { bad "joined fork rc=$RC"; tail -2 "$T/out.txt"; }

echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
