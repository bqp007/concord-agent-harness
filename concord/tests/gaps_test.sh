#!/bin/bash
# concord.py plan-gap loop (PLAN_kit-plangap, lean revision 2026-10-23): the verdict cause rules (A: --cause is for
# FAIL verdicts only, SPEC_GAP is not a cause, FAIL BLOCKED is stored), the EXECUTOR BLOCKED report line (B), one
# BLOCKED per phase (C), sub-phase ids N.k (D) and the delta review of a sub-phase run (E).
# Zero model tokens, offline, fake HOME, fake qwen executor and reviewer.
# Run: bash ~/.claude/concord/tests/gaps_test.sh [A-E]...   (no letter = every letter; exit 0 = every selected check passed).
set -u
SEL="${*:-ABCDE}"
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/gaps-test.XXXXXX")" && pwd -P)"; export T
trap 'chmod -R u+rwx "$T" 2> /dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/concord" "$T/home/.claude" "$T/logs"
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
rm -f "$T/concord/runs.jsonl"   # an installed copy holds an index
cat > "$T/bin/qwen" <<'Q'
#!/bin/sh
# executor when FAKE_ACTIONS is set (its output is the run log); otherwise a reviewer that answers CLEAN
if [ -n "${FAKE_ACTIONS:-}" ]; then sh -c "$FAKE_ACTIONS"; exit 0; fi
echo ran >> "$T/qwen_calls"
cat "$T/clean.txt"
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
# newrepo NAME: a fresh repository at $T/NAME (R and RUNS point at it)
newrepo(){ R="$T/$1"; RUNS="$R/.git/concord"; rm -rf "${R:?}"; mkdir -p "$R" && ( cd "$R" && git init -q -b main && git config user.email t@t \
  && git config user.name t && printf 'x = 1\n' > a.py && printf 'a = 1\nb = 2\n' > b.py && printf 'seed\n' > big.txt \
  && printf '.claude/\n' > .gitignore && git add -A && git commit -qm init ) || { echo "setup failed: $1"; exit 1; }; }
# run PHASE PLAN [args]: one fake executor run (FA = its shell actions, default: append to a.py); output in out.txt
run(){ local ph=$1 pl=$2; shift 2
  FAKE_ACTIONS="${FA:-echo '# r' >> a.py}" $DP "$ph" --plan "$pl" --via qwen --model fake/m --no-baseline --repo "$R" "$@" > "$T/out.txt" 2>&1; }
verdict(){ $DP --verdict "$@" --repo "$R" > "$T/out.txt" 2>&1; }
flash(){ $DP --review "$1" --via qwen --model fake/m --repo "$R" > "$T/rev.txt" 2>&1; }
# phase N [extra field lines]: a minimal phase on a.py whose acceptance fails before the change
phase(){ printf '## Phase %s - p%s\nExecutor: deepseek-flash\n%bFiles: a.py\nAcceptance:\n- `grep -q NEVER a.py`\n\n' "$1" "$1" "${2:-Risk: low\n}"; }
# local epoch seconds of "YYYY-MM-DD HH:MM"
ts(){ python3 -I -c 'import sys; from datetime import datetime; print(datetime.strptime(sys.argv[1], "%Y-%m-%d %H:%M").timestamp())' "$1"; }
# mkmeta DIR-ID PHASE EXECUTOR VERDICT CAUSE STARTED: a fabricated run meta of plan PLAN_S.md in $RUNS (an empty
# PHASE, VERDICT or CAUSE is stored as null)
mkmeta(){ mkdir -p "$RUNS/$1"; python3 -I - "$RUNS/$1/meta.json" "$R" "$@" <<'PY'
import json, sys
out, repo, run_id, phase, executor, verdict, cause, started = sys.argv[1:9]
rec = {"run_id": run_id, "repo": repo, "plan": "PLAN_S.md", "kind": "run", "executor": executor, "model": "m",
       "phase": (int(phase) if phase.isdigit() else phase) if phase else None, "verdict": verdict or None, "cause": cause or None,
       "started": float(started)}
json.dump(rec, open(out, "w"))
PY
}
rline(){ sed -n "${2}p" "$RUNS/$1/report.md" 2> /dev/null; }
# idx RUN FIELD: the field of the run's last row in the cross-repo index, as a Python list
idx(){ python3 -I -c 'import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print([r.get(sys.argv[3]) for r in rows if r.get("run_id") == sys.argv[2]][-1:])' "$T/concord/runs.jsonl" "$1" "$2" 2>&1; }
lint(){ $DP --lint "$1" --dry-run --via qwen --model fake/m --plan "$2" --repo "$R" > "$T/out.txt" 2>&1; }
# lastp PATTERN: prompt.txt of the newest run directory whose name contains PATTERN
lastp(){ cat "$(ls -td "$RUNS"/*"$1"* 2> /dev/null | head -1)/prompt.txt" 2> /dev/null; }
packet(){ $DP --review "$1" --packet --repo "$R" > "$T/out.txt" 2>&1; cat "$(sed -n 's/^PACKET //p' "$T/out.txt" | head -1)" > "$T/pk.txt" 2> /dev/null; }
pk(){ grep -F -- "$1" "$T/pk.txt" > /dev/null; }

if sel A; then echo "== A. verdict causes: FAIL verdicts only, no SPEC_GAP, BLOCKED stored"
newrepo a; { phase 1; phase 2; } > "$R/PLAN_A.md"
run 1 PLAN_A.md; A1=$(rid)
A1F=0
for c in EXECUTOR PLAN_GAP TEST_DEFECT FLAKY PROVIDER BLOCKED; do
  verdict "$A1" PASS --cause $c; RC=$?
  { [ $RC -eq 2 ] && has "--cause applies to FAIL verdicts only" && [ "$(meta "$A1" verdict)" = None ]; } \
    || { A1F=1; echo "    PASS --cause $c: rc=$RC"; tail -1 "$T/out.txt"; }
done
[ -n "$A1" ] && [ $A1F -eq 0 ] && ok "A.1 a PASS with any --cause is refused (exit 2), no verdict recorded" || bad "A.1"
A2F=0
for v in PASS FAIL; do
  verdict "$A1" $v --cause SPEC_GAP; RC=$?
  { [ $RC -eq 2 ] && has "invalid choice: 'SPEC_GAP'" && [ "$(meta "$A1" verdict)" = None ]; } \
    || { A2F=1; echo "    $v --cause SPEC_GAP: rc=$RC"; tail -1 "$T/out.txt"; }
done
[ -n "$A1" ] && [ $A2F -eq 0 ] && ok "A.2 --cause SPEC_GAP is an argparse invalid choice (exit 2) with PASS and FAIL" || bad "A.2"
run 2 PLAN_A.md; A3=$(rid)
verdict "$A3" FAIL --cause BLOCKED; RC=$?
[ $RC -eq 0 ] && [ "$(meta "$A3" cause)" = BLOCKED ] && [ "$(idx "$A3" cause)" = "['BLOCKED']" ] \
  && ok "A.3 FAIL --cause BLOCKED stored in meta.json and the index" || { bad "A.3 rc=$RC"; tail -3 "$T/out.txt"; }
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
verdict "$C2" FAIL --cause BLOCKED; RC=$?
[ $RC -eq 2 ] && has "second BLOCKED on phase 1 (first: $C1)" && has "PLAN_GAP" && [ "$(meta "$C2" verdict)" = None ] \
  && ok "C.3 a second BLOCKED is refused through --verdict" || { bad "C.3 rc=$RC"; tail -3 "$T/out.txt"; }
run 2 PLAN_S.md; verdict "$(rid)" FAIL --cause BLOCKED; RC=$?
[ $RC -eq 0 ] && ok "C.4 BLOCKED on another phase is accepted" || { bad "C.4 rc=$RC"; tail -3 "$T/out.txt"; }
mkmeta 20000101-000000-x-p1 1 qwen FAIL BLOCKED "$(ts '2000-01-01 00:00')"
verdict "$C2" FAIL --cause BLOCKED; RC=$?
[ $RC -eq 2 ] && has "(first: 20000101-000000-x-p1)" && ok "C.5 the oldest earlier BLOCKED run is named" || { bad "C.5 rc=$RC"; tail -3 "$T/out.txt"; }
mkmeta 20000101-000001-x-p0 "" qwen "" "" "$(ts '2000-01-01 00:01')"
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
fi

if sel E; then echo "== E. the delta review of a sub-phase run"
newrepo e
cat > "$R/PLAN_E.md" <<'P'
# Plan: e

## Phase 2 - parent
Executor: deepseek-flash
Risk: low
Files: b.py, big.txt
Acceptance:
- `grep -q NEVER b.py`

## Phase 2.1 - sub one
Executor: deepseek-flash
Risk: low
Files: b.py, c.py
Acceptance:
- `grep -q NEVER b.py`

## Phase 2.2 - sub two
Executor: deepseek-flash
Risk: low
Files: big.txt
Acceptance:
- `grep -q NEVER big.txt`
P
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
pk "+PARENT_LINE = 1" && pk "+SUB_LINE = 2" && ! pk "Re-run of phase" && ok "E.7 a whole-phase run that started clean shows every change since its start commit, no re-run header" || { bad "E.7"; tail -3 "$T/out.txt"; }
FA="echo 'FIX_LINE = 3' >> b.py" run 2 PLAN_E.md; ER=$(rid)
packet "$ER"
[ -n "$ER" ] && pk "+FIX_LINE = 3" && ! pk "PARENT_LINE" && ! pk "SUB_LINE" && pk "Re-run of phase 2: the diff shows only this run's change" \
  && ok "E.8 a whole-phase re-run on changed files shows only its own change, with the header" || { bad "E.8 $ER"; tail -3 "$T/out.txt"; }
fi

echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
