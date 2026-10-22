#!/bin/bash
# concord.py plan-gap loop (PLAN_kit-plangap): verdict causes SPEC_GAP and BLOCKED (A), the EXECUTOR BLOCKED report
# line (B), one BLOCKED per phase (C), sub-phase ids N.k (D), the map and the delta review of a sub-phase run (E), the
# lint gap checklist (F), PROMOTE (G), plan depth by risk (H), the --stats plan-gap block (I) and its date window (J).
# Zero model tokens, offline, fake HOME, fake qwen executor and reviewer.
# Run: bash ~/.claude/concord/tests/gaps_test.sh [A-J]...   (no letter = every letter; exit 0 = every selected check passed).
set -u
SEL="${*:-ABCDEFGHIJ}"
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/gaps-test.XXXXXX")" && pwd -P)"; export T
trap 'chmod -R u+rwx "$T" 2> /dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/concord" "$T/home/.claude" "$T/logs"
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
rm -f "$T/concord/repo-notes/"*.gaps.md "$T/concord/runs.jsonl"   # an installed copy holds real gap logs and an index
NOTES="$T/concord/repo-notes"
cat > "$T/bin/qwen" <<'Q'
#!/bin/sh
# executor when FAKE_ACTIONS is set (its output is the run log); otherwise a reviewer that prints FAKE_REVIEW
if [ -n "${FAKE_ACTIONS:-}" ]; then sh -c "$FAKE_ACTIONS"; exit 0; fi
echo ran >> "$T/qwen_calls"
cat "${FAKE_REVIEW:-$T/clean.txt}"
Q
chmod +x "$T/bin/qwen"
XDEV="$(xcode-select -p 2>/dev/null)"; [ -n "$XDEV" ] && [ -x "$XDEV/usr/bin/git" ] && [ -x "$XDEV/usr/bin/python3" ] && export PATH="$XDEV/usr/bin:$PATH"
export PATH="$T/bin:$PATH" HOME="$T/home"
DP="python3 $T/concord/concord.py"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
has(){ grep -F -- "$1" "$T/out.txt" > /dev/null; }
sel(){ case "$SEL" in *$1*) return 0;; esac; return 1; }
rid(){ sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1; }
mj(){ python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"m": m}))' "$1" "$2" 2>&1; }
meta(){ mj "$RUNS/$1/meta.json" "m.get('$2')"; }
newest(){ ls -td "$RUNS"/*"$1"* 2> /dev/null | head -1; }
printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n' > "$T/clean.txt"
cat > "$T/finding.txt" <<'J'
REVIEW-JSON
{"findings": [{"severity": "HIGH", "path": "a.py", "line": 1, "problem": "off by one", "fix": "use <=",
  "repro": {"input": "f(2)", "expected": "2", "actual": "1"}}], "clauses": [], "tests": [], "verdict": "FIX"}
END-REVIEW-JSON
J
# newrepo NAME: a fresh repository at $T/NAME (R and RUNS point at it)
newrepo(){ R="$T/$1"; RUNS="$R/.git/concord"; rm -rf "${R:?}"; mkdir -p "$R" && ( cd "$R" && git init -q -b main && git config user.email t@t \
  && git config user.name t && printf 'x = 1\n' > a.py && printf 'a = 1\nb = 2\n' > b.py && printf 'seed\n' > big.txt \
  && printf '.claude/\n' > .gitignore && git add -A && git commit -qm init ) || { echo "setup failed: $1"; exit 1; }; }
# run PHASE PLAN [args]: one fake executor run (FA = its shell actions, default: append to a.py); output in out.txt
run(){ local ph=$1 pl=$2; shift 2
  FAKE_ACTIONS="${FA:-echo '# r' >> a.py}" $DP "$ph" --plan "$pl" --via qwen --model "${MOD:-fake/m}" --no-baseline --repo "$R" "$@" > "$T/out.txt" 2>&1; }
verdict(){ $DP --verdict "$@" --repo "$R" > "$T/out.txt" 2>&1; }
closer(){ $DP --close-round "$@" --repo "$R" > "$T/out.txt" 2>&1; }
flash(){ FAKE_REVIEW="${FR:-$T/clean.txt}" $DP --review "$1" --via qwen --model fake/m --repo "$R" > "$T/rev.txt" 2>&1; }
# phase N [extra field lines]: a minimal phase on a.py whose acceptance fails before the change
phase(){ printf '## Phase %s - p%s\nExecutor: deepseek-flash\n%bFiles: a.py\nAcceptance:\n- `grep -q NEVER a.py`\n\n' "$1" "$1" "${2:-Risk: low\n}"; }
# local epoch seconds of "YYYY-MM-DD HH:MM"
ts(){ python3 -I -c 'import sys; from datetime import datetime; print(datetime.strptime(sys.argv[1], "%Y-%m-%d %H:%M").timestamp())' "$1"; }
# mkmeta DIR-ID PHASE EXECUTOR VERDICT CAUSE STARTED TOKENS [MODEL]: a fabricated run meta in $RUNS for plan
# ${PL:-PLAN_S.md} (empty = missing)
mkmeta(){ mkdir -p "$RUNS/$1"; python3 -I - "$RUNS/$1/meta.json" "$R" "$@" <<'PY'
import json, os, sys
out, repo, run_id, phase, executor, verdict, cause, started, tokens = sys.argv[1:10]
model = sys.argv[10] if len(sys.argv) > 10 else "m"
rec = {"run_id": run_id, "repo": repo, "plan": os.environ.get("PL", "PLAN_S.md"), "kind": "run", "executor": executor, "model": model,
       "phase": (int(phase) if phase.isdigit() else phase) if phase else None, "verdict": verdict or None, "cause": cause or None,
       "started": float(started)}
if tokens:
    rec["frontier_tokens"] = int(tokens)
json.dump(rec, open(out, "w"))
PY
}
rline(){ sed -n "${2}p" "$RUNS/$1/report.md" 2> /dev/null; }
# idx RUN FIELD: the field of the run's last row in the cross-repo index, as a Python list
idx(){ python3 -I -c 'import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print([r.get(sys.argv[3]) for r in rows if r.get("run_id") == sys.argv[2]][-1:])' "$T/concord/runs.jsonl" "$1" "$2" 2>&1; }
snap(){ find "$RUNS" -type f -exec cksum {} + 2> /dev/null | sort; }
lint(){ $DP --lint "$1" --dry-run --via qwen --model fake/m --plan "$2" --repo "$R" > "$T/out.txt" 2>&1; }
# lastp PATTERN: prompt.txt of the newest run directory whose name contains PATTERN
lastp(){ cat "$(ls -td "$RUNS"/*"$1"* 2> /dev/null | head -1)/prompt.txt" 2> /dev/null; }
packet(){ $DP --review "$1" --packet --repo "$R" > "$T/out.txt" 2>&1; cat "$(sed -n 's/^PACKET //p' "$T/out.txt" | head -1)" > "$T/pk.txt" 2> /dev/null; }
pk(){ grep -F -- "$1" "$T/pk.txt" > /dev/null; }
nogaps(){ rm -f "${NOTES:?}"/*.gaps.md; }
# block FILE WANTFILE: FILE holds the gap checklist WANTFILE, framed exactly as cmd_lint frames it, before phase 1
block(){ python3 -I -c 'import sys
p = open(sys.argv[1], encoding="utf-8", errors="replace").read()
w = open(sys.argv[2], encoding="utf-8", errors="replace").read()
h = "\nGap checklist (past plan gaps in this repository; check each against this phase):\n"
sys.exit(0 if h + w + "\n\nPhase 1 under review:" in p else 1)' "$1" "$2"; }

if sel A; then echo "== A. verdict causes SPEC_GAP and BLOCKED, stats cause codes"
newrepo a; { phase 1; phase 2; } > "$R/PLAN_A.md"
MOD=fake/s run 1 PLAN_A.md; A1=$(rid)
verdict "$A1" PASS --cause SPEC_GAP --user-approved ok; RC=$?
[ $RC -eq 0 ] && [ "$(meta "$A1" cause)" = SPEC_GAP ] && [ "$(idx "$A1" cause)" = "['SPEC_GAP']" ] \
  && ok "A.1 PASS --cause SPEC_GAP stored in meta.json and the index (--verdict)" || { bad "A.1 rc=$RC"; tail -3 "$T/out.txt"; }
verdict "$A1" FAIL --cause SPEC_GAP; RC=$?
[ $RC -eq 2 ] && has "SPEC_GAP applies to PASS verdicts only" && ok "A.2 FAIL SPEC_GAP refused (--verdict)" || { bad "A.2 rc=$RC"; tail -3 "$T/out.txt"; }
verdict "$A1" PASS --cause PLAN_GAP --user-approved ok; RC=$?
[ $RC -eq 2 ] && has "--cause applies to FAIL verdicts only (a PASS takes only SPEC_GAP)" \
  && ok "A.3 PASS PLAN_GAP refused (--verdict)" || { bad "A.3 rc=$RC"; tail -3 "$T/out.txt"; }
run 1 PLAN_A.md; A2=$(rid)
closer "$A2" --verdict-result FAIL --cause SPEC_GAP; RC=$?
[ $RC -eq 2 ] && has "SPEC_GAP applies to PASS verdicts only" && ok "A.4 FAIL SPEC_GAP refused (--close-round)" || { bad "A.4 rc=$RC"; tail -3 "$T/out.txt"; }
closer "$A2" --verdict-result PASS --cause PLAN_GAP --user-approved ok; RC=$?
[ $RC -eq 2 ] && has "--cause applies to FAIL verdicts only (a PASS takes only SPEC_GAP)" \
  && ok "A.5 PASS PLAN_GAP refused (--close-round)" || { bad "A.5 rc=$RC"; tail -3 "$T/out.txt"; }
closer "$A2" --verdict-result FAIL; RC=$?
[ $RC -eq 2 ] && has "EXECUTOR|PLAN_GAP|TEST_DEFECT|FLAKY|PROVIDER|BLOCKED" && ! has "SPEC_GAP" \
  && ok "A.6 --close-round FAIL without a cause lists the FAIL causes only" || { bad "A.6 rc=$RC"; tail -3 "$T/out.txt"; }
closer "$A2" --verdict-result PASS --cause SPEC_GAP --user-approved ok; RC=$?
[ $RC -eq 0 ] && [ "$(meta "$A2" cause)" = SPEC_GAP ] && ok "A.7 PASS SPEC_GAP stored (--close-round)" || { bad "A.7 rc=$RC"; tail -3 "$T/out.txt"; }
MOD=fake/b run 2 PLAN_A.md; A3=$(rid)
verdict "$A3" FAIL --cause BLOCKED; RC=$?
[ $RC -eq 0 ] && [ "$(meta "$A3" cause)" = BLOCKED ] && ok "A.8 FAIL BLOCKED stored" || { bad "A.8 rc=$RC"; tail -3 "$T/out.txt"; }
$DP --stats --repo "$R" > "$T/out.txt" 2>&1
grep 'fake/b' "$T/out.txt" | grep -q 'E0 P0 T0 F0 R0 B1$' && grep 'fake/s' "$T/out.txt" | grep -q ' -$' \
  && grep '^1st-pass = ' "$T/out.txt" | grep -q 'causes E/P/T/F/R/B = executor / plan gap / test defect / flaky / provider / blocked$' \
  && ok "A.9 stats: codes E P T F R B, '-' for an executor without a FAIL, legend" || { bad "A.9"; cat "$T/out.txt"; }
fi

if sel B; then echo "== B. the EXECUTOR BLOCKED report line"
newrepo b; { phase 1; phase 2; } > "$R/PLAN_B.md"
Q='1. Should parse() strip a BOM or reject it?'
SUF=" (answer it in the phase's Decisions, record FAIL --cause BLOCKED: not an attempt; a second BLOCKED on this phase is a PLAN_GAP)"
# brun CONTENT: one phase-1 run whose executor log is CONTENT (printf %b); BR = its run id
brun(){ printf '%b' "$1" > "$T/blog.txt"; FA="echo '# r' >> a.py; cat '$T/blog.txt'" run 1 PLAN_B.md; BR=$(rid); }
noblk(){ [ -n "$BR" ] && [ -f "$RUNS/$BR/report.md" ] && ! grep -q '^EXECUTOR BLOCKED' "$RUNS/$BR/report.md"; }
brun "work done\nSTATUS: BLOCKED\nQUESTIONS: $Q\nFILES: a.py\n"
[ "$(rline "$BR" 2)" = "EXECUTOR BLOCKED: $Q$SUF" ] && ok "B.1 report line 2 names the question" || { bad "B.1"; rline "$BR" 2; }
brun "**STATUS:** BLOCKED\n**QUESTIONS:** which file?\n"
[ "$(rline "$BR" 2)" = "EXECUTOR BLOCKED: which file?$SUF" ] && ok "B.2 markdown-decorated STATUS and QUESTIONS" || { bad "B.2"; rline "$BR" 2; }
brun "\033[1mSTATUS: BLOCKED - need a decision\033[0m\nQUESTIONS: q3\n"
[ "$(rline "$BR" 2)" = "EXECUTOR BLOCKED: q3$SUF" ] && ok "B.3 ANSI colour and text after BLOCKED" || { bad "B.3"; rline "$BR" 2; }
brun "STATUS: PASS | FAIL | BLOCKED\n"; noblk && ok "B.4 the contract's template line is not a status" || bad "B.4"
brun "STATUS: BLOCKED | waiting\n"; noblk && ok "B.5 a pipe right after BLOCKED is not a status" || bad "B.5"
brun "STATUS: BLOCKED\nQUESTIONS: x\nSTATUS: PASS\n"; noblk && ok "B.6 a later STATUS PASS wins" || bad "B.6"
brun "STATUS: BLOCKED\nQUESTIONS:\n1. first part\n2. second part\n\nFILES: a.py\n"
[ "$(rline "$BR" 2)" = "EXECUTOR BLOCKED: 1. first part 2. second part$SUF" ] && ok "B.7 continuation lines after an empty QUESTIONS" || { bad "B.7"; rline "$BR" 2; }
Y=$(printf 'y%.0s' $(seq 1 400))
brun "STATUS: BLOCKED\nQUESTIONS: $Y\n"
[ "$(rline "$BR" 2)" = "EXECUTOR BLOCKED: ${Y:0:297}...$SUF" ] && ok "B.8 a question over 300 characters is cut" || { bad "B.8"; rline "$BR" 2 | cut -c1-80; }
brun "STATUS: BLOCKED\n"; N1="$(rline "$BR" 2)"
brun "STATUS: BLOCKED\nQUESTIONS: None.\n"; N2="$(rline "$BR" 2)"
[ "$N1" = "EXECUTOR BLOCKED: (no question given)$SUF" ] && [ "$N2" = "$N1" ] && ok "B.9 no question / None. -> (no question given)" || { bad "B.9"; echo "$N1"; echo "$N2"; }
brun "usage limit exceeded\nSTATUS: BLOCKED\nQUESTIONS: q\n"
case "$(rline "$BR" 2)" in "PROVIDER LIMIT: "*) [ "$(rline "$BR" 3)" = "EXECUTOR BLOCKED: q$SUF" ] && ok "B.10 a provider refusal line sits above the BLOCKED line" || { bad "B.10"; rline "$BR" 3; } ;;
  *) bad "B.10"; rline "$BR" 2 ;; esac
brun "a\rb\rQUESTIONS: STALE\nSTATUS: BLOCKED\nQUESTIONS: real\n"
[ "$(rline "$BR" 2)" = "EXECUTOR BLOCKED: real$SUF" ] && ok "B.12 a bare carriage return before STATUS does not shift the question" || { bad "B.12"; rline "$BR" 2; }
for c in EXECUTOR EXECUTOR BLOCKED; do run 2 PLAN_B.md; verdict "$(rid)" FAIL --cause $c; done
run 2 PLAN_B.md; RC=$?
[ $RC -ne 8 ] && [ -n "$(rid)" ] && ok "B.11 BLOCKED is not an attempt: EXECUTOR, EXECUTOR, BLOCKED leaves a third attempt" || { bad "B.11 rc=$RC"; tail -3 "$T/out.txt"; }
fi

if sel C; then echo "== C. one BLOCKED per phase"
newrepo c; { phase 1; phase 2; } > "$R/PLAN_S.md"
run 1 PLAN_S.md; C1=$(rid)
verdict "$C1" FAIL --cause BLOCKED; R1=$?; verdict "$C1" FAIL --cause BLOCKED; R2=$?
[ $R1 -eq 0 ] && [ $R2 -eq 0 ] && ok "C.1 a first BLOCKED is recorded, and re-recording it is accepted" || { bad "C.1 rc=$R1/$R2"; tail -3 "$T/out.txt"; }
run 1 PLAN_S.md; C2=$(rid)
FR="$T/finding.txt" flash "$C2"
snap > "$T/snap1"; closer "$C2" --adopt F1 --verdict-result FAIL --cause BLOCKED; RC=$?; snap > "$T/snap2"
[ $RC -eq 2 ] && has "second BLOCKED on phase 1 (first: $C1)" && has "PLAN_GAP" && cmp -s "$T/snap1" "$T/snap2" \
  && ok "C.2 a second BLOCKED is refused through --close-round, nothing written" || { bad "C.2 rc=$RC"; tail -3 "$T/out.txt"; diff "$T/snap1" "$T/snap2" | head -5; }
verdict "$C2" FAIL --cause BLOCKED; RC=$?
[ $RC -eq 2 ] && has "second BLOCKED on phase 1 (first: $C1)" && [ "$(meta "$C2" verdict)" = None ] \
  && ok "C.3 a second BLOCKED is refused through --verdict" || { bad "C.3 rc=$RC"; tail -3 "$T/out.txt"; }
run 2 PLAN_S.md; verdict "$(rid)" FAIL --cause BLOCKED; RC=$?
[ $RC -eq 0 ] && ok "C.4 BLOCKED on another phase is accepted" || { bad "C.4 rc=$RC"; tail -3 "$T/out.txt"; }
mkmeta 20000101-000000-x-p1 1 qwen FAIL BLOCKED "$(ts '2000-01-01 00:00')" ""
verdict "$C2" FAIL --cause BLOCKED; RC=$?
[ $RC -eq 2 ] && has "(first: 20000101-000000-x-p1)" && ok "C.5 the oldest earlier BLOCKED run is named" || { bad "C.5 rc=$RC"; tail -3 "$T/out.txt"; }
mkmeta 20000101-000001-x-p0 "" qwen "" "" "$(ts '2000-01-01 00:01')" ""
verdict 20000101-000001-x-p0 FAIL --cause BLOCKED; RC=$?
[ $RC -eq 0 ] && ok "C.6 a run without a phase records FAIL BLOCKED" || { bad "C.6 rc=$RC"; tail -3 "$T/out.txt"; }
fi

if sel D; then echo "== D. sub-phase ids N.k"
newrepo d
cat > "$R/PLAN_D.md" <<'P'
# Plan: d

## Phase 2 - two (P2 <- S1)
Executor: deepseek-flash
Risk: low
Files: a.py
Acceptance:
- `grep -q NEVER a.py`

### Notes
NOTE_TWO

## Phase 2.1 - two one (P2.1 <- S1)
Executor: deepseek-flash
Risk: low
Purpose: SUB_ONE
Files: a.py
Acceptance:
- `grep -q NEVER a.py`

## Phase 2.10 - two ten (P2.10 <- S1)
Executor: deepseek-flash
Risk: low
Purpose: TEN_TEXT
Files: a.py
Acceptance:
- `grep -q NEVER a.py`

## Phase 2.0 - not a phase
BOGUS_TEXT

## Phase 03 - three (P3 <- S1)
Executor: deepseek-flash
Risk: low
Purpose: THREE_TEXT
Files: a.py
Acceptance:
- `grep -q NEVER a.py`

## Phase 13b - not a phase either
P
sed -e 's/^## Phase 2\.1 /### Phase 2.1 /' -e '/^## Phase 2\.10 /,$d' "$R/PLAN_D.md" > "$R/PLAN_DN.md"
dry(){ run "$1" "$2" --dry-run; DRC=$?; DD="$(ls -td "$RUNS"/*-dry-* 2> /dev/null | head -1)"; cat "$DD/prompt.txt" > "$T/p.txt" 2> /dev/null; }
ph(){ grep -F -- "$1" "$T/p.txt" > /dev/null; }
dry 2.1 PLAN_D.md
[ $DRC -eq 0 ] && case "$DD" in *-p2.1) true;; *) false;; esac && ph SUB_ONE && ! ph NOTE_TWO && ! ph TEN_TEXT \
  && ok "D.1 phase 2.1: its own text only, run id ends -p2.1" || { bad "D.1 rc=$DRC $DD"; tail -3 "$T/out.txt"; }
dry 2 PLAN_D.md
[ $DRC -eq 0 ] && ph NOTE_TWO && ph "### Notes" && ! ph SUB_ONE && ok "D.2 phase 2 stops at the 2.1 heading, keeps its own subheading" || { bad "D.2 rc=$DRC"; tail -3 "$T/out.txt"; }
dry 2 PLAN_DN.md; R1=$DRC; ph NOTE_TWO && ph "### Notes" && ! ph SUB_ONE; N1=$?
dry 2.1 PLAN_DN.md
[ $R1 -eq 0 ] && [ $N1 -eq 0 ] && [ $DRC -eq 0 ] && ph SUB_ONE && ok "D.3 the same with ### Phase 2.1 nested under ## Phase 2" || { bad "D.3 rc=$R1/$DRC n=$N1"; tail -3 "$T/out.txt"; }
lint 2.1 PLAN_D.md; R1=$?
$DP --begin 2.1 --label planner --plan PLAN_D.md --repo "$R" > "$T/out.txt" 2>&1; R2=$?
BD="$(ls -td "$RUNS"/*-planner-p2.1 2> /dev/null | head -1)"
[ $R1 -eq 0 ] && [ $R2 -eq 0 ] && [ "$(mj "$BD/state.json" "m.get('phase')")" = 2.1 ] && ok "D.4 --lint 2.1 and --begin 2.1 accepted; state phase \"2.1\"" \
  || { bad "D.4 rc=$R1/$R2"; tail -3 "$T/out.txt"; }
$DP --abort last --repo "$R" > /dev/null 2>&1
B5=0
for w in 2. 2.0 2.01 2.1.1 x; do run "$w" PLAN_D.md --dry-run; [ $? -eq 2 ] || { B5=1; echo "    PHASE word '$w' not refused"; }; done
$DP --lint 2.0 --dry-run --via qwen --model fake/m --plan PLAN_D.md --repo "$R" > /dev/null 2>&1; [ $? -eq 2 ] || B5=1
$DP --begin 2.01 --label planner --plan PLAN_D.md --repo "$R" > /dev/null 2>&1; [ $? -eq 2 ] || { B5=1; $DP --abort last --repo "$R" > /dev/null 2>&1; }
[ $B5 -eq 0 ] && ok "D.5 phase words 2. 2.0 2.01 2.1.1 x refused (exit 2) by PHASE, --lint and --begin" || bad "D.5"
dry ' 2.1 ' PLAN_D.md
[ $DRC -eq 0 ] && case "$DD" in *-p2.1) true;; *) false;; esac && ok "D.6 ' 2.1 ' is accepted as 2.1" || { bad "D.6 rc=$DRC $DD"; tail -3 "$T/out.txt"; }
dry 3 PLAN_D.md; R1=$DRC; ph THREE_TEXT; N1=$?
dry 2.10 PLAN_D.md
[ $R1 -eq 0 ] && [ $N1 -eq 0 ] && [ $DRC -eq 0 ] && ph TEN_TEXT && ! ph SUB_ONE && ok "D.7 3 selects '## Phase 03'; 2.10 is not 2.1" || { bad "D.7 rc=$R1/$DRC"; tail -3 "$T/out.txt"; }
run 9 PLAN_D.md --dry-run; RC=$?
[ $RC -eq 2 ] && has "(phases found: 2, 2.1, 2.10, 3)" && ok "D.8 a missing phase lists the valid ids (2.0 and 13b are not phases)" || { bad "D.8 rc=$RC"; tail -3 "$T/out.txt"; }
cat > "$R/PLAN_DL.md" <<'P'
# Plan: dl

## Map
### Intent
- I1 demo
### Structure
- S1 <- I1 module
### Work
- P1 <- S1 one; deepseek-flash; low

## Phase 1 - one (P1 <- S1)
Executor: deepseek-flash
Risk: low
Files: a.py
Acceptance:
- `grep -q NEVER a.py`

## Phase 1.1 - one one
Executor: deepseek-flash
Risk: low
Files: a.py
Acceptance:
- `grep -q NEVER a.py`

## Phase 1.0 - not a phase
P
lint 1 PLAN_DL.md
has "MAP LINT: phase heading without an ID: Phase 1.1" && ! grep -q '^MAP LINT: .*Phase 1\.0' "$T/out.txt" && ! grep -q '^MAP LINT: .*Phase 1$' "$T/out.txt" \
  && ok "D.9 MAP LINT names the sub-phase heading without an ID, skips 1.0" || { bad "D.9"; grep '^MAP LINT' "$T/out.txt"; }
fi

if sel E; then echo "== E. the map and the delta review of a sub-phase run"
newrepo e
cat > "$R/PLAN_E.md" <<'P'
# Plan: e

## Map
### Intent
- I1 demo
### Structure
- S1 <- I1 module
### Work
- P2 <- S1 parent; deepseek-flash; low
- P2.1 <- S1 sub one; deepseek-flash; low
- P2.2 <- S1 sub two; deepseek-flash; low

## Open questions
- Q1 -> P2.1 which way

## Phase 2 - parent (P2 <- S1)
Executor: deepseek-flash
Risk: low
Files: b.py, big.txt
Acceptance:
- `grep -q NEVER b.py`

## Phase 2.1 - sub one (P2.1 <- S1)
Executor: deepseek-flash
Risk: low
Files: b.py, c.py
Acceptance:
- `grep -q NEVER b.py`

## Phase 2.2 - sub two (P2.2 <- S1)
Executor: deepseek-flash
Risk: low
Files: big.txt
Acceptance:
- `grep -q NEVER big.txt`
P
cp "$R/PLAN_E.md" "$R/PLAN_EM.md"
PL=PLAN_EM.md mkmeta 20260101-000001-x-p2 2 qwen FAIL EXECUTOR "$(ts '2026-01-01 00:01')" ""
PL=PLAN_EM.md mkmeta 20260101-000002-x-p2.1 2.1 qwen PASS "" "$(ts '2026-01-01 00:02')" ""
$DP --map PLAN_EM.md --repo "$R" > "$T/out.txt" 2>&1
has "P2 <- S1  [FAIL [EXECUTOR]]  parent" && has "P2.1 <- S1  [PASS]  sub one" && ok "E.1 --map: P2.1 has its own status" || { bad "E.1"; cat "$T/out.txt"; }
has "Q1 -> P2.1  which way" && ok "E.2 an open question can block P2.1" || { bad "E.2"; grep Q1 "$T/out.txt"; }
for n in 8 9; do
  { printf '# Plan: cap\n\n## Map\n### Intent\n- I1 demo\n### Structure\n- S1 <- I1 module\n### Work\n'
    for i in $(seq 1 $n); do printf -- '- P%s <- S1 w%s; deepseek-flash; low\n' "$i" "$i"; done
    printf -- '- P2.1 <- S1 sub; deepseek-flash; low\n\n## Phase 1 - one (P1 <- S1)\nExecutor: deepseek-flash\nRisk: low\nFiles: a.py\n'
    printf 'Acceptance:\n- `grep -q NEVER a.py`\n'; } > "$R/PLAN_E$n.md"
done
lint 1 PLAN_E8.md; ! has "cap exceeded"; N1=$?
lint 1 PLAN_E9.md
[ $N1 -eq 0 ] && has "MAP LINT: cap exceeded: Work has 9 items (max 8)" && ok "E.3 the Work cap counts whole phases only" || { bad "E.3 n8=$N1"; grep '^MAP LINT' "$T/out.txt"; }
FA="echo 'PARENT_LINE = 1' >> b.py; echo PARENT_BIG >> big.txt" run 2 PLAN_E.md; EP=$(rid)
FA="echo 'SUB_LINE = 2' >> b.py; printf 'NEW_FILE = 1\n' > c.py" run 2.1 PLAN_E.md; ES=$(rid)
packet "$ES"
[ -n "$ES" ] && pk "+SUB_LINE = 2" && pk "+NEW_FILE = 1" && ! pk "PARENT_LINE" \
  && pk "Sub-phase 2.1: the diff shows only this run's change, from the files as they were when it started" \
  && ok "E.4 a 2.1 packet holds only its own change, a new file whole, and the header" || { bad "E.4 $ES"; tail -3 "$T/out.txt"; }
flash "$ES"; lastp -review- > "$T/p.txt"
[ -n "$ES" ] && grep -qF "+SUB_LINE = 2" "$T/p.txt" && ! grep -qF "PARENT_LINE" "$T/p.txt" && ok "E.5 the flash review of 2.1 sends only its own change" || { bad "E.5"; tail -3 "$T/rev.txt"; }
FA="seq 1 20000 >> big.txt" run 2.2 PLAN_E.md; E2=$(rid)
packet "$E2"
[ -n "$E2" ] && pk "[diff truncated at" && ! pk "PARENT_BIG" && ok "E.6 a sub-phase delta over the cap is cut and still holds no parent hunk" || { bad "E.6 $E2"; tail -3 "$T/out.txt"; }
packet "$EP"
pk "+PARENT_LINE = 1" && pk "+SUB_LINE = 2" && ok "E.7 a whole-phase run still shows every change since its start commit" || { bad "E.7"; tail -3 "$T/out.txt"; }
fi

if sel F; then echo "== F. the lint gap checklist"
nogaps; newrepo demo; phase 1 > "$R/PLAN_F.md"; G="$NOTES/demo.gaps.md"
L1='- [nan-gate] what does each gate do with NaN? (T-101, 2026-10-18, found: review)'
L4='- [fmt] an empty rule is no rule (T-103, 2026-10-20, found: lint, rule: )'
L5='- a free-form note'
printf '%s\n' '# Gap log' '' "$L1" '- [enc] which encoding? (T-102, 2026-10-19, found: verify, rule: tests/enc_test.sh)' \
  '- [x] malformed, rule: x' "$L4" "$L5" > "$G"
printf '%s\n%s\n%s' "$L1" "$L4" "$L5" > "$T/want.txt"
lint 1 PLAN_F.md; RC=$?; lastp -lint- > "$T/p.txt"
[ $RC -eq 0 ] && block "$T/p.txt" "$T/want.txt" && ok "F.1 checklist: rule-less bullets in file order, right before the phase" || { bad "F.1 rc=$RC"; grep -n -A6 'Gap checklist' "$T/p.txt" | head -9; }
python3 -I -c 'import sys
p = open(sys.argv[1]).read()
sys.exit(0 if p.index("\nRISKS:") < p.index("\nGAPS:") < p.index("\nVERDICT:") and "\nINPUTS:" in p
         and "no Inputs field" in p and "not required (Risk: low)" in p else 1)' "$T/p.txt" 2> /dev/null \
  && ok "F.2 LINT_TASK: GAPS between RISKS and VERDICT; INPUTS knows Risk: low" || bad "F.2"
python3 -I -c 'import sys
lines = ["- [c%02d] " % i + "q" * 91 for i in range(60)]
open(sys.argv[1], "w").write("\n".join(lines) + "\n")
open(sys.argv[2], "w").write("[21 older gap lines omitted]\n" + "\n".join(lines[21:]))
assert len(lines[0]) == 99 and len(open(sys.argv[2]).read()) == 3928' "$G" "$T/want.txt"
lint 1 PLAN_F.md; lastp -lint- > "$T/p.txt"
block "$T/p.txt" "$T/want.txt" && ok "F.3 over 4000 characters: newest lines kept, exact omission count" || { bad "F.3"; grep -A1 'Gap checklist' "$T/p.txt" | head -2 | cut -c1-80; }
python3 -I -c 'import sys
line = "- " + "z" * 4998
open(sys.argv[1], "w").write(line + "\n"); open(sys.argv[2], "w").write(line[:4000])' "$G" "$T/want.txt"
lint 1 PLAN_F.md; lastp -lint- > "$T/p.txt"
block "$T/p.txt" "$T/want.txt" && ok "F.4 one 5000-character line: cut to exactly 4000, no note" || bad "F.4"
printf '\357\273\277- [bom] first line (T-1, 2026-10-01, found: review)\r\n- [bad] caf\351 (T-2, 2026-10-02, found: lint)\r\n' > "$G"
printf '%s\n%s' '- [bom] first line (T-1, 2026-10-01, found: review)' "- [bad] caf$(printf '\357\277\275') (T-2, 2026-10-02, found: lint)" > "$T/want.txt"
lint 1 PLAN_F.md; RC=$?; lastp -lint- > "$T/p.txt"
[ $RC -eq 0 ] && block "$T/p.txt" "$T/want.txt" && ok "F.5 byte-order mark, CRLF and non-UTF-8 bytes" || { bad "F.5 rc=$RC"; grep -A2 'Gap checklist' "$T/p.txt" | od -c | head -5; }
F6=0
for k in dir mode000 empty header rules; do
  rm -rf "${G:?}"
  case $k in dir) mkdir "$G";; mode000) printf '%s\n' "$L1" > "$G"; chmod 000 "$G";; empty) : > "$G";;
    header) printf '# Gap log\n\n' > "$G";; rules) printf '%s\n' '- [r] q (T-1, 2026-10-01, found: review, rule: tests/r.sh)' > "$G";; esac
  lint 1 PLAN_F.md; RC=$?; lastp -lint- > "$T/p.txt"
  { [ $RC -eq 0 ] && [ -s "$T/p.txt" ] && ! grep -q 'Gap checklist' "$T/p.txt"; } || { F6=1; echo "    $k: rc=$RC"; }
  chmod 644 "$G" 2> /dev/null
done
[ $F6 -eq 0 ] && ok "F.6 a directory, mode 000, empty, header-only or rule-only gaps.md adds no checklist" || bad "F.6"
rm -rf "${G:?}"; printf '%s\n' "$L1" > "$G"
run 1 PLAN_F.md --dry-run; lastp -dry- > "$T/p.txt"; N1=0; grep -q 'nan-gate' "$T/p.txt" && N1=1; [ -s "$T/p.txt" ] || N1=1
run 1 PLAN_F.md; flash "$(rid)"; lastp -review- > "$T/p.txt"; N2=0; grep -q 'nan-gate' "$T/p.txt" && N2=1; [ -s "$T/p.txt" ] || N2=1
[ $N1 -eq 0 ] && [ $N2 -eq 0 ] && ok "F.7 gaps.md text never reaches an executor or a reviewer prompt" || bad "F.7 exec=$N1 review=$N2"
lint 1 PLAN_F.md; lastp -lint- | grep -q 'nan-gate' && ok "F.8 (control) the lint prompt does hold it" || bad "F.8"
nogaps
fi

if sel G; then echo "== G. PROMOTE"
nogaps; newrepo demo; { phase 1; phase 2 | sed 's/^Executor: deepseek-flash$/Executor: sonnet/'; } > "$R/PLAN_G.md"
printf '%s\n' '# Gap log' \
  '- [nan-gate] what does each gate do with NaN? (T-101, 2026-10-18, found: review)' \
  '- [NaN-gate] is the comparison NaN-safe? (T-102, 2026-10-21, found: blocked)' \
  '- [mixed] a (T-200, 2026-10-01, found: review, rule: tests/x.sh)' \
  '- [mixed] b (T-201, 2026-10-02, found: review)' \
  '- [Mixed] c (T-202, 2026-10-03, found: lint)' \
  '- [dup] d (T-301, 2026-10-04, found: review)' \
  '- [dup] e (T-301, 2026-10-05, found: verify)' \
  '- [once] f (T-401, 2026-10-06, found: review)' \
  '- [ruled] g (T-501, 2026-10-07, found: review, rule: a)' \
  '- [ruled] h (T-502, 2026-10-08, found: review, rule: b)' \
  '- [solo] a free-form bullet' \
  '- [solo] i (T-601, 2026-10-09, found: review)' \
  '- [bad-date] j (T-701, 2026-02-30, found: review)' \
  '- [bad-date] k (T-702, 2026-10-10, found: review)' > "$NOTES/demo.gaps.md"
TAIL=': make it a rule (a line in repo-notes/demo.md, a test or a hook), then add "rule: <where>" to those lines'
printf '%s\n' "PROMOTE nan-gate: 2 gaps without a rule (T-101, T-102)$TAIL" "PROMOTE mixed: 2 gaps without a rule (T-201, T-202)$TAIL" \
  "PROMOTE dup: 2 gaps without a rule (T-301)$TAIL" > "$T/want.txt"
order(){ awk -v x="$1" '/^MAP LINT/{m=NR} /^PROMOTE/{if(!p)p=NR; q=NR} index($0, x)==1{d=NR} END{exit !(m && p > m && q < d)}' "$T/out.txt"; }
lint 1 PLAN_G.md; grep '^PROMOTE' "$T/out.txt" > "$T/got.txt"
cmp -s "$T/want.txt" "$T/got.txt" && ok "G.1 exact PROMOTE lines: classes seen twice without a rule, case-insensitive, tickets once" || { bad "G.1"; diff "$T/want.txt" "$T/got.txt"; }
order "DRY RUN LINT" && ok "G.2 PROMOTE after MAP LINT, before DRY RUN LINT" || { bad "G.2"; cut -c1-90 "$T/out.txt"; }
$DP --lint 2 --plan PLAN_G.md --repo "$R" > "$T/out.txt" 2>&1
order "LINT SKIPPED" && ok "G.3 PROMOTE also before LINT SKIPPED (Claude executor)" || { bad "G.3"; cut -c1-90 "$T/out.txt"; }
nogaps
fi

if sel H; then echo "== H. plan depth by risk"
newrepo h; { phase 1 'Risk: low\n'; phase 2 'Risk: high\n'; phase 3 'Purpose: no risk line\n'; } > "$R/PLAN_H.md"
run 1 PLAN_H.md; H1=$(rid); run 2 PLAN_H.md; H2=$(rid); run 3 PLAN_H.md; H3=$(rid)
[ -n "$H1" ] && [ -f "$RUNS/$H1/report.md" ] && ! grep -q 'no Inputs field' "$RUNS/$H1/report.md" && ok "H.1 a Risk: low phase without Inputs gets no note" || bad "H.1 $H1"
grep -q 'no Inputs field' "$RUNS/$H2/report.md" 2> /dev/null && grep -q 'no Inputs field' "$RUNS/$H3/report.md" 2> /dev/null \
  && ok "H.2 Risk: high and a phase without Risk still get it" || bad "H.2"
fi

# ifix NAME: repository NAME with fabricated runs 10-22 October and a gap log (the I and J fixture)
ifix(){ newrepo "$1"; mkdir -p "$RUNS"
  mkmeta 20261012-090000-r01 1 qwen FAIL PLAN_GAP "$(ts '2026-10-12 09:00')" 1000000
  mkmeta 20261012-100000-r02 1 qwen FAIL PLAN_GAP "$(ts '2026-10-12 10:00')" 2000000
  mkmeta 20261012-110000-r03 1 qwen PASS "" "$(ts '2026-10-12 11:00')" 3000000
  mkmeta 20261013-090000-r04 2 planner FAIL PLAN_GAP "$(ts '2026-10-13 09:00')" 4000000
  mkmeta 20261013-100000-r05 2 planner PASS "" "$(ts '2026-10-13 10:00')" 5000000
  mkmeta 20261014-090000-r06 3 qwen FAIL PLAN_GAP "$(ts '2026-10-14 09:00')" 6000000
  mkmeta 20261014-100000-r07 3 qwen "" "" "$(ts '2026-10-14 10:00')" ""
  mkmeta 20261021-090000-r08 4 qwen FAIL PLAN_GAP "$(ts '2026-10-21 09:00')" 7000000
  mkmeta 20261022-090000-r09 4 qwen PASS "" "$(ts '2026-10-22 09:00')" 8000000
  mkmeta 20261015-090000-r10 5 qwen PASS SPEC_GAP "$(ts '2026-10-15 09:00')" 9000000
  mkmeta 20261015-100000-r11 5.1 qwen FAIL BLOCKED "$(ts '2026-10-15 10:00')" 500000
  mkmeta 20261010-090000-r12 6 qwen FAIL EXECUTOR "$(ts '2026-10-10 09:00')" 10000000
  mkmeta 20261016-090000-r13 7 qwen FAIL EXECUTOR "$(ts '2026-10-16 09:00')" ""
  printf '%s\n' '# Gap log' '- [a] q1 (T-1, 2026-10-12, found: review)' '- [b] q2 (T-2, 2026-10-20, found: review)' \
    '- [c] q3 (T-3, 2026-10-14, found: verify)' '- [d] q4 (T-4, 2026-10-21, found: lint)' '- [e] q5 (T-5, 2026-10-11, found: blocked)' \
    '- [f] q6 (T-6, 2026-10-10, found: review)' '- [g] q7 (T-7, 2026-10-22, found: lint)' '- [h] q8 (T-8, 2026-02-30, found: review)' \
    '- a free-form line' > "$NOTES/$1.gaps.md"; }
st(){ $DP --stats --repo "$R" "$@" > "$T/out.txt" 2>&1; }
# blk5: out.txt holds the five lines of want.txt, consecutive, right before the legend line
blk5(){ python3 -I -c 'import sys
o = open(sys.argv[1]).read().splitlines(); w = open(sys.argv[2]).read().splitlines()
i = o.index(w[0]) if w[0] in o else -1
sys.exit(0 if i >= 0 and o[i:i + 5] == w and len(o) > i + 5 and o[i + 5].startswith("1st-pass = ") else 1)' "$T/out.txt" "$T/want.txt"; }

if sel I; then echo "== I. the --stats plan-gap block"
nogaps; ifix istat
st --since 2026-10-11 --until 2026-10-21
printf '%s\n' 'plan gaps 2026-10-11..2026-10-21: implementing phases 6 (accepted 2)' \
  '  gap verdicts: PLAN_GAP 5, SPEC_GAP 1, BLOCKED 1 (1.17 per implementing phase)' '  after a gap: full re-runs 4, sub-phase runs 1' \
  '  found (gaps.md): review 2, verify 1, lint 1, blocked 1' '  frontier tokens per accepted implementing phase: 18.75M' > "$T/want.txt"
blk5 && ok "I.1 window 11-21 October: exact five lines right before the legend" || { bad "I.1"; grep -A5 '^plan gaps' "$T/out.txt"; }
st; has "plan gaps (all dates): implementing phases 7 (accepted 3)" && ok "I.2 no flags: (all dates)" || { bad "I.2"; grep '^plan gaps' "$T/out.txt"; }
st --since 2026-10-13 --until 2026-10-13
printf '%s\n' 'plan gaps 2026-10-13..2026-10-13: implementing phases 0 (accepted 0)' \
  '  gap verdicts: PLAN_GAP 1, SPEC_GAP 0, BLOCKED 0 (- per implementing phase)' '  after a gap: full re-runs 1, sub-phase runs 0' \
  '  found (gaps.md): review 0, verify 0, lint 0, blocked 0' '  frontier tokens per accepted implementing phase: -' > "$T/want.txt"
blk5 && ok "I.3 a window with runs but no implementing phase: 0 and -" || { bad "I.3"; grep -A5 '^plan gaps' "$T/out.txt"; }
IX="$T/concord/runs.jsonl"; [ -f "$IX" ] && cp "$IX" "$T/index.bak"
python3 -I -c 'import json, sys
rows = [("20261012-090000-x01", "FAIL", "PLAN_GAP", 1), ("20261012-100000-x02", "FAIL", "PLAN_GAP", 2), ("20261012-110000-x03", "PASS", None, 3)]
with open(sys.argv[1], "w") as f:
    for i, (rid, v, c, t) in enumerate(rows):
        f.write(json.dumps({"run_id": rid, "repo": sys.argv[2], "plan": "PLAN_S.md", "phase": 1, "executor": "qwen", "model": "m",
                            "verdict": v, "cause": c, "started": 1760259600.0 + 3600 * i, "frontier_tokens": t * 1000000}) + "\n")' "$IX" "$R"
printf '%s\n' '- [z] q (T-9, 2026-10-15, found: review)' > "$NOTES/other.gaps.md"
$DP --stats --all --repo "$R" > "$T/out.txt" 2>&1
has "plan gaps (all dates): implementing phases 1 (accepted 1)" && has "  found (gaps.md): review 4, verify 1, lint 2, blocked 1" \
  && has "  frontier tokens per accepted implementing phase: 6.00M" && ok "I.4 --all: the index and every gaps.md" || { bad "I.4"; grep -A5 '^plan gaps' "$T/out.txt"; }
nogaps; $DP --stats --all --repo "$R" > "$T/out.txt" 2>&1
has "  found (gaps.md): review 0, verify 0, lint 0, blocked 0" && ok "I.5 --all without gaps files: zeros" || { bad "I.5"; grep -A5 '^plan gaps' "$T/out.txt"; }
rm -f "${IX:?}"; [ -f "$T/index.bak" ] && mv "$T/index.bak" "$IX"
fi

if sel J; then echo "== J. --since/--until edges"
nogaps; ifix jwin
J1=0
for a in "--since 2026-13-01" "--since 2026-02-30" "--until yesterday" "--since 20261011"; do
  st $a; RC=$?; { [ $RC -eq 2 ] && has "YYYY-MM-DD"; } || { J1=1; echo "    $a: rc=$RC"; }
done
st --since ''; RC=$?; { [ $RC -eq 2 ] && has "YYYY-MM-DD"; } || { J1=1; echo "    empty --since: rc=$RC"; }
[ $J1 -eq 0 ] && ok "J.1 invalid dates exit 2 naming YYYY-MM-DD" || bad "J.1"
st --since 2026-10-11; has "plan gaps 2026-10-11..now: implementing phases 6 (accepted 3)"; N1=$?
st --until 2026-10-21
[ $N1 -eq 0 ] && has "plan gaps start..2026-10-21: implementing phases 7 (accepted 2)" && ok "J.2 one flag alone: an open side" || { bad "J.2"; grep '^plan gaps' "$T/out.txt"; }
st --since 2026-10-21 --until 2026-10-11; has "no recorded runs in the window" && ! has "plan gaps"; N1=$?
st --since 2030-01-01
[ $N1 -eq 0 ] && has "no recorded runs in the window" && ok "J.3 an empty window (since after until, or after every run)" || { bad "J.3"; head -3 "$T/out.txt"; }
newrepo jnone; st --since 2026-10-11
has "no recorded runs in this repo" && ! has "plan gaps" && ok "J.4 no runs at all: today's message" || { bad "J.4"; head -3 "$T/out.txt"; }
nogaps
fi

echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
