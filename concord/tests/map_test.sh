#!/bin/bash
# concord.py (PLAN_concord-repo Phase 15): the layered plan map. --map prints the Intent/Structure/Work tree with
# per-phase status (A) and a Mermaid mindmap (B); --lint prints MAP LINT lines for a broken map (C); a plan without a
# Map block keeps working, warning only (D). Zero model tokens, offline, fake HOME.
# Run: bash ~/.claude/concord/tests/map_test.sh [ABCD]   (exit 0 = every selected check passed).
set -u
SEL="${1:-ABCD}"
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/map-test.XXXXXX")" && pwd -P)"; export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/concord" "$T/home/.claude"
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
cat > "$T/bin/qwen" <<'Q'
#!/bin/sh
echo ran >> "$T/qwen_calls"
printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n'
Q
chmod +x "$T/bin/qwen"
XDEV="$(xcode-select -p 2>/dev/null)"; [ -n "$XDEV" ] && [ -x "$XDEV/usr/bin/git" ] && [ -x "$XDEV/usr/bin/python3" ] && export PATH="$XDEV/usr/bin:$PATH"
export PATH="$T/bin:$PATH" HOME="$T/home"
DP="python3 $T/concord/concord.py"
R="$T/repo"; RUNS="$R/.git/concord"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
has(){ grep -F -- "$1" "$T/out.txt" > /dev/null; }
sel(){ case "$SEL" in *$1*) return 0;; esac; return 1; }
mapcmd(){ $DP --map "$1" --repo "$R" > "$T/out.txt" 2>&1; }
lint(){ $DP --lint "$1" --dry-run --via qwen --model fake/m --plan "$2" --repo "$R" > "$T/out.txt" 2>&1; }
mlint(){ sed -n 's/^MAP LINT: //p' "$T/out.txt"; }

mkdir -p "$R/docs" && ( cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > a.py; printf 'doc\n' > docs/x.md; printf '.claude/\n' > .gitignore
  git add -A && git commit -qm init ) || { echo "setup failed"; exit 1; }

cat > "$R/PLAN_M.md" <<'P'
# Plan: demo map

## Map
### Intent
- I1 ship the feature; metric pass rate
- I2 keep docs honest
### Structure
- S1 <- I1 the module that changes
- S2 <- I2 the docs page
### Work
- P1 <- S1 phase one; deepseek-flash; low
- P2 <- S2 phase two; deepseek-flash; medium; after P1
- P3 <- S1 phase three; planner; low
- P4 <- S1 phase four; planner; low

## Open questions
- Q1 -> S2 should the docs mention X

## Phase 1 - first (P1 <- S1)
Executor: deepseek-flash
Files: a.py
Acceptance:
- `grep -q x a.py`
## Phase 2 - second (P2 <- S2)
Executor: deepseek-flash
Files: docs/x.md
Acceptance:
- `grep -q doc docs/x.md`
## Phase 3 - third (P3 <- S1)
Executor: planner
Files: a.py
## Phase 4 - fourth (P4 <- S1)
Executor: planner
Files: a.py
P

cat > "$R/PLAN_BAD.md" <<'P'
# Plan: bad map

## Map
### Intent
- I1 used intent
- I2 orphan intent with no work
### Structure
- S1 <- I1 ok structure
- S2 <- I9 structure pointing at an unknown intent
- S3 structure serving no intent
### Work
- P1 <- S1 good work
- P2 <- S9 work pointing at an unknown structure
- P3 no parent work

## Phase 1 - a (P1 <- S1)
Executor: deepseek-flash
Files: a.py
Acceptance:
- `grep -q x a.py`
## Phase 2 - b
Executor: deepseek-flash
Files: a.py
Acceptance:
- `grep -q x a.py`
P

# a legacy plan with no Map block (must keep working)
cat > "$R/PLAN_OLD.md" <<'P'
# Plan: old

## Phase 1 - p1
Executor: deepseek-flash
Files: a.py
Acceptance:
- `grep -q x a.py`
P

# fabricate run metas so the work items carry a status
mkdir -p "$RUNS"
mkmeta(){ mkdir -p "$RUNS/$1"; python3 -I -c "import json,sys; json.dump({'run_id':sys.argv[1],'repo':sys.argv[2],'plan':'PLAN_M.md','phase':int(sys.argv[3]),'verdict':(sys.argv[4] or None),'cause':(sys.argv[5] or None),'started':float(sys.argv[6]),'kind':'run'}, open(sys.argv[7],'w'))" "$1" "$R" "$2" "$3" "$4" "$5" "$RUNS/$1/meta.json"; }
mkmeta 20260101-000001-x-p1 1 PASS "" 100
mkmeta 20260101-000002-x-p2 2 FAIL EXECUTOR 200
# phase 3: no run at all -> not started; phase 4: a run with state.json but no meta -> running
mkdir -p "$RUNS/20260101-000003-x-p4"
python3 -I -c "import json,sys; json.dump({'repo':sys.argv[1],'plan':'PLAN_M.md','phase':4,'started':300.0}, open(sys.argv[2],'w'))" "$R" "$RUNS/20260101-000003-x-p4/state.json"
# a lint-prefixed run for phase 1 must be ignored (not a real attempt)
mkdir -p "$RUNS/20260101-000004-lint-x-p3"
python3 -I -c "import json,sys; json.dump({'run_id':'20260101-000004-lint-x-p3','repo':sys.argv[1],'plan':'PLAN_M.md','phase':3,'verdict':'PASS','started':400.0,'kind':'run'}, open(sys.argv[2],'w'))" "$R" "$RUNS/20260101-000004-lint-x-p3/meta.json"

if sel A; then echo "== A. --map tree with per-phase status"
mapcmd PLAN_M.md; RC=$?
[ $RC -eq 0 ] && ok "A.1 --map exits 0" || { bad "A.1 rc=$RC"; cat "$T/out.txt"; }
has "Map: PLAN_M.md" && has "Intent" && has "Structure" && has "Work" && ok "A.2 tree has the three section headings" || bad "A.2 headings"
has "I1  ship the feature" && has "S1 <- I1  the module that changes" && ok "A.3 intent and structure lines with parents" || { bad "A.3"; cat "$T/out.txt"; }
has "P1 <- S1  [PASS]  phase one" && ok "A.4 PASS status from the ledger" || { bad "A.4"; grep P1 "$T/out.txt"; }
has "P2 <- S2  [FAIL [EXECUTOR]]  phase two" && ok "A.5 FAIL status carries the cause" || { bad "A.5"; grep P2 "$T/out.txt"; }
has "P3 <- S1  [not started]" && ok "A.6 not started when no run (lint-prefixed run ignored)" || { bad "A.6"; grep P3 "$T/out.txt"; }
has "P4 <- S1  [running]" && ok "A.7 running when a run has state but no verdict" || { bad "A.7"; grep P4 "$T/out.txt"; }
has "Open questions (blocked):" && has "Q1 -> S2  should the docs mention X" && ok "A.8 blocked open question names its node" || { bad "A.8"; cat "$T/out.txt"; }
fi

if sel B; then echo "== B. --map --mermaid"
$DP --map PLAN_M.md --mermaid --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && [ "$(head -1 "$T/out.txt")" = "mindmap" ] && ok "B.1 first line is mindmap" || { bad "B.1 rc=$RC"; head -2 "$T/out.txt"; }
has "root((Plan: demo map))" && ok "B.2 root node is the plan title" || { bad "B.2"; cat "$T/out.txt"; }
has "I1 ship the feature" && has "S1 the module that changes" && has "P1 phase one" && has "[PASS]" && ok "B.3 nested intent/structure/work with status" || { bad "B.3"; cat "$T/out.txt"; }
fi

if sel C; then echo "== C. MAP LINT on a broken map"
lint 1 PLAN_BAD.md; RC=$?
[ $RC -eq 0 ] && has "DRY RUN LINT" && ok "C.1 lint still exits 0 (warnings are advisory)" || { bad "C.1 rc=$RC"; mlint; }
mlint > "$T/got.txt"
printf '%s\n' \
  'unknown ID: S2 <- I9 (no such intent)' \
  'unknown ID: P2 <- S9 (no such structure)' \
  'work item without a structure parent: P2' \
  'work item without a structure parent: P3' \
  'structure node serving no intent: S2' \
  'structure node serving no intent: S3' \
  'intent with no work item: I2' \
  'phase heading without an ID: Phase 2' > "$T/want.txt"
diff -u "$T/want.txt" "$T/got.txt" > "$T/diff.txt" && ok "C.2 every MAP LINT line, in order" || { bad "C.2 MAP LINT lines differ"; cat "$T/diff.txt"; }
# a cap over its limit is flagged
python3 -I -c "import sys; open(sys.argv[1],'w').write('# Plan: cap\n\n## Map\n### Intent\n'+''.join('- I%d x\n'%i for i in range(1,8))+'### Structure\n- S1 <- I1 s\n### Work\n- P1 <- S1 w\n\n## Phase 1 - a (P1 <- S1)\nExecutor: deepseek-flash\nFiles: a.py\nAcceptance:\n- \x60grep -q x a.py\x60\n')" "$R/PLAN_CAP.md"
lint 1 PLAN_CAP.md; mlint > "$T/got.txt"
grep -qx 'cap exceeded: Intent has 7 items (max 6)' "$T/got.txt" && ok "C.3 cap exceeded flagged" || { bad "C.3"; cat "$T/got.txt"; }
fi

if sel D; then echo "== D. no Map block keeps working (warning only)"
mapcmd PLAN_OLD.md; RC=$?
[ $RC -eq 0 ] && has "MAP: no Map block in PLAN_OLD.md" && ok "D.1 --map on a plan without a Map block: one line, exit 0" || { bad "D.1 rc=$RC"; cat "$T/out.txt"; }
lint 1 PLAN_OLD.md; RC=$?
[ $RC -eq 0 ] && has "DRY RUN LINT" && [ "$(mlint)" = "no Map block (warning only)" ] && ok "D.2 --lint on a legacy plan: the warning only, lint still runs" || { bad "D.2 rc=$RC"; mlint; }
fi

echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
