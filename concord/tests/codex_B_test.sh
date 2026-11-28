#!/bin/bash
# concord.py run lifecycle, locks, verdicts, recovery and the report (outside review, package B): a PASS with no
# acceptance command or no change is listed under Overrides (A); a crash other than an abort is no red result (B); --abort and a signal
# stop a live executor before its lock goes (C); run ids pass the run-selection rules and --end checks its run first
# (D); --grade and --restore hold the checkout (E); a timed-out check whose output pipe stays open (F); a damaged lock
# and parallel run folders (G); meta.json before report.md (H); verdict history and the grade it judged (I); --grade
# runs the static checks (J); --restore backs up links as links and reports a partial restore (K); skipped or forced
# red runs and expected-result counts (L); --check exits non-zero for a missing required tool (M); private run
# folders (N). Zero model tokens, offline, fake HOME, fake qwen executor.
# Run: bash ~/.claude/concord/tests/codex_B_test.sh [A-N]...   (no letter = every letter; exit 0 = every selected check passed).
set -u
SEL="${*:-ABCDEFGHIJKLMN}"
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/codexB-test.XXXXXX")" && pwd -P)"; export T
cleanup(){ for f in "$T"/*.pid; do [ -f "$f" ] && kill -9 "$(cat "$f")" 2> /dev/null; done; chmod -R u+rwx "$T" 2> /dev/null; rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/bin" "$T/concord" "$T/home/.claude"
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
rm -f "$T/concord/runs.jsonl"   # an installed copy holds an index
cat > "$T/bin/qwen" <<'Q'
#!/bin/sh
# executor when FAKE_ACTIONS is set (its output is the run log); otherwise a reviewer that answers CLEAN
if [ -n "${FAKE_ACTIONS:-}" ]; then sh -c "$FAKE_ACTIONS"; exit 0; fi
cat "$T/clean.txt"
Q
cat > "$T/bin/fakeruff" <<'F'
#!/usr/bin/env python3
# ruff check --output-format=json ... -- FILES: one finding for each file that holds BAD
import json, os, sys
files = sys.argv[sys.argv.index("--") + 1:]
print(json.dumps([{"filename": os.path.abspath(f), "code": "F999", "message": "bad"} for f in files if "BAD" in open(f).read()]))
F
chmod +x "$T/bin/qwen" "$T/bin/fakeruff"
XDEV="$(xcode-select -p 2>/dev/null)"; [ -n "$XDEV" ] && [ -x "$XDEV/usr/bin/git" ] && [ -x "$XDEV/usr/bin/python3" ] && export PATH="$XDEV/usr/bin:$PATH"
export PATH="$T/bin:$PATH" HOME="$T/home"
PY="$(command -v python3)"
DP="$PY $T/concord/concord.py"
. "$(dirname "$0")/lib.sh"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
has(){ grep -F -- "$1" "$T/out.txt" > /dev/null; }
sel(){ case "$SEL" in *$1*) return 0;; esac; return 1; }
rid(){ sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1; }
bid(){ sed -n 's/^BEGIN \([^ ]*\).*/\1/p' "$T/out.txt" | head -1; }
mj(){ python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"m": m}))' "$1" "$2" 2>&1; }
meta(){ mj "$RUNS/$1/meta.json" "m.get('$2')"; }
conf(){ cp -p "$SRC/executors.conf" "$T/concord/executors.conf"; fake_env; for l in "$@"; do printf '%s\n' "$l" >> "$T/concord/executors.conf"; done; }
printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n' > "$T/clean.txt"
# newrepo NAME PLAN-TEXT: a fresh repository at $T/NAME holding PLAN_B.md (R and RUNS point at it), the plan approved
newrepo(){ R="$T/$1"; RUNS="$R/.git/concord"; rm -rf "${R:?}"; mkdir -p "$R" && ( cd "$R" && git init -q -b main && git config user.email t@t \
  && git config user.name t && printf 'x = 1\n' > a.py && printf 'b = 1\n' > b.py && printf '.claude/\n' > .gitignore \
  && printf '%b' "$2" > PLAN_B.md && git add a.py b.py .gitignore && git commit -qm init ) || { echo "setup failed: $1"; exit 1; }
  approve PLAN_B.md "$R" || exit 1; }
# phase N ACCEPTANCE-LINES [EXTRA-FIELDS]: one phase on a.py
phase(){ printf '## Phase %s - p%s\nExecutor: deepseek-flash\nRisk: low\n%sFiles: a.py\n%s\n' "$1" "$1" "${3:-}" "$2"; }
run(){ local ph=$1; shift; FAKE_ACTIONS="${FA:-echo '# r' >> a.py}" $DP "$ph" --plan PLAN_B.md --via qwen --model fake/m --repo "$R" "$@" > "$T/out.txt" 2>&1; }
begin(){ local ph=$1; shift; $DP --begin "$ph" --label planner --plan PLAN_B.md --repo "$R" "$@" > "$T/out.txt" 2>&1; }
verdict(){ $DP --verdict "$@" --repo "$R" > "$T/out.txt" 2>&1; }
report(){ $DP --report --plan PLAN_B.md --repo "$R" > "$T/out.txt" 2>&1; cat "$RUNS"/reports/REPORT_B-*.md > "$T/rep.txt" 2> /dev/null; }
overrides(){ sed -n '/^## Overrides/,/^## Phases/p' "$T/rep.txt"; }
row(){ grep -E "^\| $1 \|" "$T/rep.txt"; }
# waitfor FILE: up to 30 s for FILE to appear
waitfor(){ local k=0; while [ ! -s "$1" ] && [ $k -lt 150 ]; do sleep 0.2; k=$((k+1)); done; [ -s "$1" ]; }
# bgrun PIDFILE: phase 1 in the background, its executor writing its pid to PIDFILE, then sleeping; DPID = the dispatcher
bgrun(){ FAKE_ACTIONS="echo \$\$ > '$1'; sleep 20; echo late >> a.py" $DP 1 --plan PLAN_B.md --via qwen --model fake/m --repo "$R" --no-baseline > "$T/bg.txt" 2>&1 & DPID=$!; }
alive(){ kill -0 "$1" 2> /dev/null; }
holds(){ python3 -I -c 'import json,sys
try: h = json.load(open(sys.argv[1])).get("holders") or []
except OSError: h = []
sys.exit(0 if any(x.get("run") == sys.argv[2] for x in h) else 1)' "$R/.git/concord.lock" "$1"; }
conf

if sel A; then echo "== A. a PASS with no acceptance command, and a session PASS with no change, are listed under Overrides"
newrepo a1 "$(phase 1 '')"
begin 1; A1=$(bid); printf 'x = 2\n' > "$R/a.py"; $DP --end "$A1" --repo "$R" > /dev/null 2>&1; verdict "$A1" PASS; RC=$?; report
[ $RC -eq 0 ] && overrides | grep -qF -- "- PASS with no acceptance command: run $A1 (phase 1)" \
  && ok "A PASS of a phase with no acceptance command is recorded (exit 0) and listed under Overrides" \
  || { bad "A no acceptance: verdict rc=$RC"; overrides; }
newrepo a2 "$(phase 1 'Acceptance:\n- `true`')"
begin 1; A2=$(bid); $DP --end "$A2" --repo "$R" > /dev/null 2>&1; verdict "$A2" PASS; RC=$?; report
[ $RC -eq 0 ] && overrides | grep -qF -- "- PASS with no change (the graded candidate is the start tree): run $A2 (phase 1)" \
  && ok "A a session PASS whose candidate is its start tree is recorded and listed under Overrides" \
  || { bad "A no change: verdict rc=$RC"; overrides; }
fi

if sel B; then echo "== B. a timeout, a command that cannot run or a signal other than an abort is no red result"
newrepo b1 "$(phase 1 'Acceptance:\n- `kill -TERM $$` (fails until phase 2)')"
run 1 --no-baseline; B1=$(rid); verdict "$B1" PASS --note "kill fails until phase 2"; RC=$?
[ "$(meta "$B1" acceptance_after_rc)" = "[-15]" ] && [ $RC -eq 7 ] && [ "$(meta "$B1" verdict)" = "None" ] && has "not red as expected" \
  && ok "B an expected-red command ended by a signal: PASS refused (exit 7), nothing recorded" \
  || { bad "B signal accepted as red: rc=$RC after=$(meta "$B1" acceptance_after_rc)"; cat "$T/out.txt"; }
newrepo b3 "$(phase 1 'Acceptance:\n- `exit 134` (fails until phase 2)')"
run 1 --no-baseline; B3=$(rid); verdict "$B3" PASS --note "the assertion fails until phase 2"; RC=$?
[ "$(meta "$B3" acceptance_after_rc)" = "[134]" ] && [ $RC -eq 0 ] && [ "$(meta "$B3" verdict)" = "PASS" ] \
  && ok "B an expected-red command ended by an abort (134, a failed C or C++ assertion) is a failing test: PASS recorded" \
  || { bad "B abort not red: rc=$RC after=$(meta "$B3" acceptance_after_rc)"; cat "$T/out.txt"; }
newrepo b2 "$(phase 1 'Acceptance:\n- `no-such-command-zq7`')"
begin 1; RC=$?; B2=$(bid); cp "$T/out.txt" "$T/b2.txt"; $DP --end "$B2" --repo "$R" > "$T/out.txt" 2>&1
[ $RC -eq 0 ] && grep -qF "baseline: 0/1 acceptance commands fail before the change" "$T/b2.txt" \
  && grep -qF "BASELINE WARNING: no failing test before the change" "$T/b2.txt" && has "BASELINE WARNING: no failing test before the change" \
  && has "no-such-command-zq7 (exit 127)" && ! has "all acceptance commands failed before the change, as expected" \
  && ok "B a red run whose command cannot run (exit 127) counts no failing test: --begin and the report warn" \
  || { bad "B exit 127 counted as red: rc=$RC"; cat "$T/b2.txt"; grep -i baseline "$T/out.txt"; }
fi

if sel C; then echo "== C. --abort and a SIGTERM stop a live executor before its lock is released"
newrepo c1 "$(phase 1 'Acceptance:\n- `grep -q late a.py`')"
bgrun "$T/c1.pid"
if waitfor "$T/c1.pid"; then CPID=$(cat "$T/c1.pid"); C1=$(ls -t "$RUNS" | grep -- '-p1$' | head -1)
  $DP --abort last --repo "$R" > "$T/out.txt" 2>&1; RC=$?; ALIVE=$(alive "$CPID" && echo yes || echo no); wait $DPID 2> /dev/null
  [ $RC -eq 0 ] && [ "$ALIVE" = no ] && ! holds "$C1" && [ -f "$RUNS/$C1/aborted" ] \
    && ok "C --abort of a live executor run stops the executor, then releases its lock and marks the run aborted" \
    || { bad "C --abort left the executor running: rc=$RC alive=$ALIVE"; cat "$T/out.txt"; }
else bad "C setup: the executor did not start"; cat "$T/out.txt"; fi
newrepo c2 "$(phase 1 'Acceptance:\n- `grep -q late a.py`')"
bgrun "$T/c2.pid"
if waitfor "$T/c2.pid"; then CPID=$(cat "$T/c2.pid"); C2=$(ls -t "$RUNS" | grep -- '-p1$' | head -1)
  kill -TERM $DPID; wait $DPID 2> /dev/null; sleep 0.5
  ! alive "$CPID" && ! holds "$C2" \
    && ok "C a SIGTERM to the dispatcher stops and reaps its executor and releases the lock" \
    || bad "C SIGTERM left the executor running: alive=$(alive "$CPID" && echo yes || echo no), lock held=$(holds "$C2" && echo yes || echo no)"
else bad "C setup: the executor did not start"; fi
fi

if sel D; then echo "== D. explicit run ids pass the run-selection rules; --end checks the run before it writes"
newrepo d1 "$(phase 1 'Acceptance:\n- `grep -q r a.py`')"
run 1 --no-baseline; D1=$(rid); $DP --abort "$D1" --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 2 ] && [ ! -e "$RUNS/$D1/aborted" ] && has "already has a report" \
  && ok "D --abort RUN of a reported run is refused (exit 2) and marks nothing, as --abort last skips it" \
  || { bad "D --abort of a reported run: rc=$RC aborted=$([ -e "$RUNS/$D1/aborted" ] && echo yes || echo no)"; cat "$T/out.txt"; }
newrepo d2 "$(phase 1 'Acceptance:\n- `grep -q late a.py`')"
bgrun "$T/d2.pid"
if waitfor "$T/d2.pid"; then D2=$(ls -t "$RUNS" | grep -- '-p1$' | head -1); kill -KILL $DPID; wait $DPID 2> /dev/null
  $DP --end "$D2" --repo "$R" > "$T/out.txt" 2>&1; RC=$?
  [ $RC -eq 2 ] && [ ! -e "$RUNS/$D2/report.md" ] && has "is an executor run, not a session run" \
    && ok "D --end of an executor run whose dispatcher died is refused (exit 2) before any report is written" \
    || { bad "D --end of an executor run: rc=$RC report=$([ -e "$RUNS/$D2/report.md" ] && echo yes || echo no)"; cat "$T/out.txt"; }
  $DP --abort "$D2" --repo "$R" > /dev/null 2>&1
else bad "D setup: the executor did not start"; fi
newrepo d3 "$(phase 1 'Acceptance:\n- `grep -q 2 a.py`')"
git -C "$R" worktree add -q "$T/d3w" -b other > /dev/null 2>&1 || { echo "setup failed: worktree"; exit 1; }
begin 1; D3=$(bid); printf 'x = 2\n' > "$R/a.py"; $DP --end "$D3" --repo "$T/d3w" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 2 ] && [ ! -e "$RUNS/$D3/report.md" ] && holds "$D3" && has "not in $T/d3w" \
  && ok "D --end from another checkout of the repository is refused (exit 2): no report, the run keeps its lock" \
  || { bad "D --end from another checkout: rc=$RC"; cat "$T/out.txt"; }
newrepo d4 "$(phase 1 'Acceptance:\n- `grep -q 2 a.py`')"
begin 1; D3=$(bid); printf 'x = 2\n' > "$R/a.py"; rm -f "$R/.git/concord.lock"; $DP --end "$D3" --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 2 ] && [ ! -e "$RUNS/$D3/report.md" ] && has "holds no session lock in this checkout" \
  && ok "D --end of a session run whose lock holder is gone is refused (exit 2) before any report is written" \
  || { bad "D --end without its holder: rc=$RC"; cat "$T/out.txt"; }
fi

if sel E; then echo "== E. --grade and --restore hold the checkout while they read and write it"
newrepo e1 "$(phase 1 'Acceptance:\n- `grep -q r a.py`')\n$(phase 2 'Acceptance:\n- `grep -q 3 a.py`')"
run 1 --no-baseline; E1=$(rid); begin 2; E2=$(bid)
$DP --grade "$E1" --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 2 ] && has "run $E2 holds its lock" && ! grep -q '"graded"' "$RUNS/$E1/meta.json" \
  && ok "E --grade while a session run holds the checkout is refused (exit 2) and records no grade" \
  || { bad "E --grade beside an open run: rc=$RC"; cat "$T/out.txt"; }
$DP --restore "$E1" --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 2 ] && has "run $E2 holds its lock" && grep -q '# r' "$R/a.py" \
  && ok "E --restore while a session run holds the checkout is refused (exit 2) and writes nothing" \
  || { bad "E --restore beside an open run: rc=$RC"; cat "$T/out.txt"; }
fi

if sel F; then echo "== F. a check that times out while a detached process holds its output pipe"
conf "check_timeout = 2s"
newrepo f1 "$(phase 1 'Acceptance:\n- `python3 hold.py`')"
cat > "$R/hold.py" <<'H'
import os, sys, time
if os.fork() == 0:              # a process outside the check's group keeps the output pipe open
    os.setsid()
    open(os.environ["T"] + "/hold.pid", "w").write(str(os.getpid()))
    time.sleep(40)
    sys.exit(0)
time.sleep(40)
H
( cd "$R" && git add hold.py && git commit -qm hold ) || { echo "setup failed: hold"; exit 1; }
S0=$(date +%s); begin 1; RC=$?; S1=$(date +%s)
[ $RC -eq 0 ] && [ $((S1 - S0)) -lt 25 ] && grep -q "exit 124" "$RUNS/$(bid)/baseline.txt" \
  && ok "F the red run of a timed-out check returns after a bounded wait for its output ($((S1 - S0)) s), exit 124" \
  || { bad "F timed-out check: rc=$RC after $((S1 - S0)) s"; tail -3 "$T/out.txt"; }
[ -f "$T/hold.pid" ] && kill -9 "$(cat "$T/hold.pid")" 2> /dev/null
conf
fi

if sel G; then echo "== G. a damaged lock never reads as free; parallel runs get their own folders"
newrepo g1 "$(phase 1 'Acceptance:\n- `grep -q 2 a.py`')\n$(phase 2 'Acceptance:\n- `grep -q 3 a.py`')"
begin 1; G1=$(bid); printf '{"holders": [' > "$R/.git/concord.lock"
begin 2; RC=$?
[ $RC -eq 2 ] && has "cannot be read as a lock" && [ -z "$(bid)" ] \
  && ok "G an interrupted lock write (a truncated lock) refuses the next run (exit 2) instead of reading as free" \
  || { bad "G truncated lock read as free: rc=$RC"; cat "$T/out.txt"; }
newrepo g2 "$(phase 1 'Acceptance:\n- `true`')"
for i in $(seq 1 24); do ( $DP 1 --plan PLAN_B.md --via qwen --model fake/m --dry-run --repo "$R" > "$T/g$i.out" 2>&1; echo $? > "$T/g$i.rc" ) & done; wait
NBAD=$(cat "$T"/g*.rc | grep -vcx 0); NDIR=$(ls "$RUNS" | grep -c -- '-dry-')
[ "$NBAD" = 0 ] && [ "$NDIR" = 24 ] && ok "G 24 parallel runs of one phase in one second: 24 folders, no crash" \
  || { bad "G parallel run folders: $NBAD failed, $NDIR folders"; grep -h "Error" "$T"/g*.out | sort | uniq -c | head -3; }
fi

if sel H; then echo "== H. meta.json is written before report.md"
newrepo h1 "$(phase 1 'Acceptance:\n- `grep -q 2 a.py`')"
begin 1; H1=$(bid); printf 'x = 2\n' > "$R/a.py"; mkdir "$RUNS/$H1/meta.json"
$DP --end "$H1" --repo "$R" > "$T/out.txt" 2>&1; RC=$?
rmdir "$RUNS/$H1/meta.json"; $DP --end "$H1" --repo "$R" > "$T/out2.txt" 2>&1; RC2=$?
[ $RC -ne 0 ] && [ $RC2 -eq 0 ] && [ -f "$RUNS/$H1/meta.json" ] && [ -f "$RUNS/$H1/report.md" ] && grep -q "DELEGATE RESULT $H1" "$T/out2.txt" \
  && ok "H a finish whose meta.json cannot be written leaves no report.md, so --end finishes the run again" \
  || { bad "H report.md before meta.json: first rc=$RC, second rc=$RC2"; tail -2 "$T/out.txt"; tail -2 "$T/out2.txt"; }
fi

if sel I; then echo "== I. a later verdict replaces the earlier one's fields; the report shows what a verdict judged"
newrepo i1 "$(phase 1 'Acceptance:\n- `grep -q NEVER a.py`')"
run 1 --no-baseline; I1=$(rid)
verdict "$I1" PASS --force --note "owner accepts"; RC1=$?; verdict "$I1" FAIL --cause EXECUTOR; RC2=$?; report
FORCED=$(python3 -I -c 'import json,sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print([r.get("forced") for r in rows if r.get("run_id") == sys.argv[2] and r.get("verdict")])' "$T/concord/runs.jsonl" "$I1")
[ $RC1 -eq 0 ] && [ $RC2 -eq 0 ] && [ "$(meta "$I1" verdict_forced)" = "None" ] && ! overrides | grep -qF "forced PASS, run $I1" \
  && [ "$FORCED" = "[True, False]" ] \
  && ok "I forced PASS then FAIL: the forced fields go, the report lists no forced PASS, the run index records each verdict's forced flag" \
  || { bad "I forced fields kept: rc=$RC1/$RC2 forced=$(meta "$I1" verdict_forced) index=$FORCED"; overrides; }
newrepo i2 "$(phase 1 'Acceptance:\n- `grep -q y a.py`')"
FA='echo y >> a.py' run 1 --no-baseline; I2=$(rid); verdict "$I2" PASS; RC1=$?
printf 'x = 1\n' > "$R/a.py"; $DP --grade "$I2" --repo "$R" > "$T/out.txt" 2>&1; RC2=$?; report
[ $RC1 -eq 0 ] && [ $RC2 -eq 0 ] && [ "$(meta "$I2" acceptance_after_rc)" = "[1]" ] && row 1 | grep -qE '^\| 1 \| [^|]+ \| 1 \| PASS \| 1/1 pass \|' \
  && ok "I after a regrade, the report row of a PASS shows the acceptance results that PASS judged" \
  || { bad "I regrade paired with an older verdict: rc=$RC1/$RC2"; row 1; }
fi

if sel J; then echo "== J. --grade runs the static checks a finish runs"
conf "static.ruff = $T/bin/fakeruff"
newrepo j1 "$(phase 1 'Acceptance:\n- `grep -q y a.py`')"
FA='echo "y = 1" >> a.py' run 1 --no-baseline; J1=$(rid)
printf '# BAD\n' >> "$R/a.py"; $DP --grade "$J1" --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "STATIC NEW (ruff): 1 new: a.py F999 bad" && [ "$(meta "$J1" static_new)" = "{'ruff': [['a.py', 'F999', 'bad']]}" ] \
  && ok "J --grade reports and records a static finding the regraded candidate added" \
  || { bad "J --grade skipped the static checks: rc=$RC static_new=$(meta "$J1" static_new)"; cat "$T/out.txt"; }
conf
fi

if sel K; then echo "== K. --restore: a link is backed up as a link; a partial restore exits non-zero; a recorded path never leaves the checkout"
newrepo k1 "$(printf '## Phase 1 - p\nExecutor: deepseek-flash\nRisk: low\nFiles: link.txt\nAcceptance:\n- `test -f link.txt`\n')"
( cd "$R" && printf 'outside bytes\n' > target.txt && ln -s target.txt link.txt && git add target.txt link.txt && git commit -qm link ) \
  || { echo "setup failed: link"; exit 1; }
begin 1; K1=$(bid); rm "$R/link.txt"; printf 'plain\n' > "$R/link.txt"; $DP --end "$K1" --repo "$R" > /dev/null 2>&1
$DP --restore "$K1" --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ -L "$RUNS/$K1/backup/link.txt" ] && [ "$(readlink "$RUNS/$K1/backup/link.txt")" = target.txt ] && [ $RC -eq 0 ] \
  && [ "$(readlink "$R/link.txt")" = target.txt ] \
  && ok "K an in-scope symlink is backed up as the link (not its target's bytes) and --restore puts the link back (exit 0)" \
  || { bad "K link backup: backup is $([ -L "$RUNS/$K1/backup/link.txt" ] && echo link || echo file), restore rc=$RC"; cat "$T/out.txt"; }
newrepo k2 "$(printf '## Phase 1 - p\nExecutor: deepseek-flash\nRisk: low\nFiles: a.py, made.txt\nAcceptance:\n- `grep -q 2 a.py`\n')"
begin 1; K2=$(bid); printf 'x = 2\n' > "$R/a.py"; ln -s nowhere "$R/made.txt"; $DP --end "$K2" --repo "$R" > /dev/null 2>&1
printf 'x = 3\n' > "$R/a.py"
$DP --restore "$K2" --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 1 ] && has "a.py: not restored" && has "files created by the run (not removed; delete them yourself if unwanted): made.txt" \
  && has "PARTIAL RESTORE of $K2" \
  && ok "K a refused file and a created dangling link left in place: --restore names both and exits 1" \
  || { bad "K partial restore: rc=$RC"; cat "$T/out.txt"; }
newrepo k3 "$(printf '## Phase 1 - p\nExecutor: deepseek-flash\nRisk: low\nFiles: a.py\nAcceptance:\n- `grep -q 2 a.py`\n')"
begin 1; K3=$(bid); printf 'x = 2\n' > "$R/a.py"; $DP --end "$K3" --repo "$R" > /dev/null 2>&1
# a hand-edited record: ../k3/a.py resolves back to a.py, and its "backup" is a planted file outside backup/
mkdir -p "$RUNS/$K3/k3"; printf 'planted\n' > "$RUNS/$K3/k3/a.py"
python3 -I -c 'import hashlib, json, sys
p, planted, f = sys.argv[1], sys.argv[2], "../k3/a.py"; m = json.load(open(p))
for k in ("end_hashes", "end_kinds", "end_exec", "start_kinds", "start_exec"): m[k][f] = m[k]["a.py"]
m["backup_hashes"][f] = hashlib.sha256(open(planted, "rb").read()).hexdigest(); m["backed_up"] = [f] + m["backed_up"]
json.dump(m, open(p, "w"))' "$RUNS/$K3/meta.json" "$RUNS/$K3/k3/a.py"
$DP --restore "$K3" --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 1 ] && [ "$(cat "$R/a.py")" = "x = 1" ] && has "../k3/a.py: not restored (its path leaves the repository)" \
  && ok "K a recorded backup path with a .. part is refused even where it resolves inside the checkout (exit 1)" \
  || { bad "K .. path restored: rc=$RC a.py=$(cat "$R/a.py")"; cat "$T/out.txt"; }
fi

if sel L; then echo "== L. skipped and forced red runs are Overrides; counts follow the expected result"
newrepo l1 "$(phase 1 'Acceptance:\n- `grep -q r a.py`' 'Baseline: skip\n')"
run 1; L1=$(rid); verdict "$L1" FAIL --cause EXECUTOR; report
overrides | grep -qF -- "- Baseline: skip: run $L1 (phase 1) skipped the red run" \
  && ok "L a phase with Baseline: skip is listed under Overrides" || { bad "L Baseline: skip"; overrides; }
conf "baseline = no"
newrepo l2 "$(phase 1 'Acceptance:\n- `grep -q r a.py`')"
run 1; L2=$(rid); verdict "$L2" FAIL --cause EXECUTOR; report; conf
overrides | grep -qF -- "- baseline = no (executors.conf): run $L2 (phase 1) skipped the red run" \
  && ok "L baseline = no in executors.conf is listed under Overrides" || { bad "L baseline = no"; overrides; }
newrepo l3 "$(phase 1 'Acceptance:\n- `true`')"
run 1 --force; L3=$(rid); verdict "$L3" FAIL --cause EXECUTOR; report
overrides | grep -qF -- "- --force over a green red run: run $L3 (phase 1) started although these acceptance commands passed before the change: true" \
  && ok "L --force over an acceptance command that passed before the change is listed under Overrides" || { bad "L --force"; overrides; }
newrepo l4 "$(phase 1 'Acceptance:\n- `python3 red.py` (fails until phase 2)')"
printf 'import sys\nsys.exit(1)\n' > "$R/red.py"; ( cd "$R" && git add red.py && git commit -qm red ) || { echo "setup failed: red"; exit 1; }
run 1 --no-baseline; L4=$(rid); cp "$T/out.txt" "$T/l4.txt"; verdict "$L4" PASS --note "red.py fails until phase 2"; report
grep -qF "acceptance after run: 1/1 as expected" "$T/l4.txt" && row 1 | grep -qE '^\| 1 \| [^|]+ \| 1 \| PASS \| 1/1 as expected \|' \
  && ok "L an expected-red command that fails as expected counts as an expected result in the run report and the test report" \
  || { bad "L expected-red count"; grep -i "after run" "$T/l4.txt"; row 1; }
fi

if sel M; then echo "== M. --check exits non-zero when a required tool is missing"
mkdir -p "$T/nogit"
PATH="$T/nogit" $DP --check > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 3 ] && has "MISSING required tool(s): git" && ok "M no git on PATH: --check exits 3 and names it" || { bad "M no git: rc=$RC"; cat "$T/out.txt"; }
conf "kimi.bin = $T/no-such-dir/kimi"
PATH="$T/bin:${XDEV:+$XDEV/usr/bin:}/usr/bin:/bin" $DP --check > "$T/out.txt" 2>&1; RC=$?; conf
[ $RC -eq 3 ] && has "MISSING required tool(s): kimi" \
  && ok "M a harness whose binary executors.conf names is missing: --check exits 3" || { bad "M configured binary: rc=$RC"; cat "$T/out.txt"; }
fi

if sel N; then echo "== N. run folders are private to their owner"
newrepo n1 "$(phase 1 'Acceptance:\n- `grep -q r a.py`')"
run 1 --no-baseline; N1=$(rid)
MODES=$(python3 -I -c 'import os,sys; print(" ".join(oct(os.stat(p).st_mode & 0o777) for p in sys.argv[1:]))' "$RUNS" "$RUNS/$N1")
[ "$MODES" = "0o700 0o700" ] && ok "N the runs root and a run folder are created owner-only (0700)" || bad "N run folder modes: $MODES"
fi

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
