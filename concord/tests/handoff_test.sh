#!/bin/bash
# Knowledge handoff from the planner to executors (2026-10-23, concord-diffusion). (1) A phase's Notes: pointers
# (path:function, path:a-b) are resolved at dispatch and the current code is inlined into the executor's task; a
# pointer that resolves to nothing is marked. (2) FOUND: lines of an executor's report land once in the plan's notes
# file, and later executor and --review tasks of that plan include it. (3) Retry feedback is not called verifier
# feedback. (4) --report writes the test report from recorded data, opens with the overrides, attributes each finding
# outcome to its round, head and closing review, and stops the drift clock. No network: fake qwen executor, fake gh.
# Run: bash ~/.claude/concord/tests/handoff_test.sh   (exit 0 = every check passed)
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/handoff-test.XXXXXX")" && pwd -P)"; export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/concord" "$T/home/.claude"
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
printf '#!/bin/sh\nsh -c "${FAKE_ACTIONS:-true}"\n' > "$T/bin/qwen"; chmod +x "$T/bin/qwen"
cat > "$T/bin/gh" <<'G'
#!/bin/sh
[ "$1" = pr ] && [ "$2" = view ] || exit 1
n=$(printf '%s' "$3" | sed -E 's|.*/pull/||; s|.*#||')
[ -f "$T/pr$n.json" ] && cat "$T/pr$n.json" && exit 0
echo "no pull requests found for $3" >&2; exit 1
G
chmod +x "$T/bin/gh"
# Prefer the developer dir's real git/python3 over the /usr/bin xcrun shims (they print cache errors in the sandbox).
XDEV="$(xcode-select -p 2>/dev/null)"; [ -n "$XDEV" ] && [ -x "$XDEV/usr/bin/git" ] && [ -x "$XDEV/usr/bin/python3" ] && export PATH="$XDEV/usr/bin:$PATH"
export PATH="$T/bin:$PATH" HOME="$T/home"
DP="python3 $T/concord/concord.py"
. "$(dirname "$0")/lib.sh"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
R="$T/repo"; RUNS="$R/.git/concord"; mkdir -p "$R"
( set -e; cd "$R"; git init -q -b main; git config user.email t@t; git config user.name t
  cat > a.py <<'PY'
def keep():
    return 'helper-line-two'


def total(items):
    s = 0
    for it in items:
        s += it["price"]  # marker-inside-total
    return s


def after():
    return 'marker-after-total'
PY
  printf 'const out = helper(2);\nfunction main(x) {\n  return helper(x);\n}\n\nfunction helper(x) {\n  return x * 2; // marker-js-def\n}\n' > h.js
  printf 'fn main() {\n    let v = helper(2);\n}\npub(crate) fn helper(x: i32) -> i32 {\n    x // marker-rs-def\n}\n' > h.rs
  printf '.claude/\n' > .gitignore; git add -A; git commit -qm init
  cat > PLAN_T.md <<'P'
# Plan
## Phase 1 - count quantities
Executor: deepseek-flash
Risk: low
Files: a.py
Notes:
- a.py:total - sums prices, ignores qty
- a.py:1-2 - the helper above it
- a.py:no_such_fn - gone
- h.js:helper - the JS helper
- h.rs:helper - the Rust helper
Acceptance:
- `grep -q qty a.py`
P
) || { echo "setup failed: repo"; exit 1; }
approve PLAN_T.md "$R" || exit 1
dry(){ $DP 1 --plan PLAN_T.md --via qwen --model fake/m --dry-run "$@" --repo "$R" > "$T/out.txt" 2>&1
  local id; id=$(sed -n 's/^DRY RUN \([^ ]*\)$/\1/p' "$T/out.txt" | head -1); cat "$RUNS/${id:-none}/prompt.txt" 2>/dev/null; }

echo "== 1 Notes: pointers are inlined at dispatch"
dry > "$T/p1.txt"
grep -qF 'marker-inside-total' "$T/p1.txt" && ! grep -qF 'marker-after-total' "$T/p1.txt" \
  && ok "1 a.py:total inlines that function and stops at its end" || { bad "1 function pointer"; tail -3 "$T/out.txt"; }
grep -qF 'helper-line-two' "$T/p1.txt" && ok "1 a.py:1-2 inlines the line range" || bad "1 range pointer"
grep -qF '(not found: a.py:no_such_fn)' "$T/p1.txt" && ok "1 a pointer that resolves to nothing is marked" || bad "1 missing pointer"
grep -qF 'marker-js-def' "$T/p1.txt" && ok "1 h.js:helper inlines the definition, not an earlier call line" || bad "1 JS pointer"
grep -qF 'marker-rs-def' "$T/p1.txt" && ok "1 h.rs:helper resolves a pub(crate) fn" || bad "1 Rust pointer"

echo "== 2 FOUND: lines flow to later tasks of the plan"
FAKE_ACTIONS='echo "# qty" >> a.py; printf "STATUS: DONE\nFOUND: a.py:8 marker-found-fact\n"' \
  $DP 1 --plan PLAN_T.md --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1
RID=$(sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
NF="$RUNS/notes/PLAN_T.md"
[ -n "$RID" ] && [ "$(grep -c 'marker-found-fact' "$NF" 2>/dev/null)" = 1 ] \
  && ok "2 the executor's FOUND: line lands once in the plan's notes file" || { bad "2 notes file (run $RID)"; tail -3 "$T/out.txt"; }
dry > "$T/p2.txt"
grep -qF 'marker-found-fact' "$T/p2.txt" && ok "2 the next executor task of the plan includes it" || bad "2 next task"
$DP --review "${RID:-none}" --via qwen --model fake/m --dry-run --repo "$R" > "$T/out.txt" 2>&1
RV=$(sed -n 's/^DRY RUN REVIEW \([^ ]*\) of.*/\1/p' "$T/out.txt" | head -1)
grep -qF 'marker-found-fact' "$RUNS/${RV:-none}/prompt.txt" 2>/dev/null && ok "2 a --review task of the plan includes it" \
  || { bad "2 review task (review run $RV)"; tail -3 "$T/out.txt"; }

echo "== 3 retry feedback"
dry --extra "EVIDENCE: marker-feedback" > "$T/p3.txt"
grep -qF 'marker-feedback' "$T/p3.txt" \
  && ok "3 --extra reaches the task as feedback from the previous attempt" \
  || { bad "3 feedback wording"; grep -i -m2 'feedback' "$T/p3.txt"; }


echo "== 4 --report: the test report for the Dev Acceptance Test (2026-11-15, kit-flow)"
H="$T/h"; mkdir -p "$H/tests"
( set -e; cd "$H"; git init -q -b main; git config user.email t@t; git config user.name t
  printf 'x = 1\n' > a.py; printf 'echo old\n' > tests/a_test.sh; git add -A; git commit -qm init
  printf '# Plan\nTier: M\nSize: ~10 lines\nTests: +1/−0 lines, net ≤ +1\nETA: 30 min\n\n## Open questions\n- Q1 which name to show\n
## Test plan (behavior ledger)\n| Behavior | Existing tests | Action | Home |\n|---|---|---|---|\n| marker-behavior-row | none | ADD | tests/a_test.sh |
\n## Phase 1 - change a\nExecutor: deepseek-flash\nFiles: a.py, tests/a_test.sh\nAcceptance:\n- `grep -q 2 a.py`\n- `grep -q NEVER a.py`\n' > PLAN_rep.md
) || { echo "setup failed"; exit 1; }
approve PLAN_rep.md "$H" || exit 1
FAKE_ACTIONS='echo "x = 2" > a.py; printf "echo new1\necho new2\n" >> tests/a_test.sh' \
  $DP 1 --plan PLAN_rep.md --via qwen --model fake/m --no-baseline --repo "$H" > "$T/r1.txt" 2>&1 || { bad "4 setup run"; tail -3 "$T/r1.txt"; }
RID=$(sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/r1.txt" | head -1); [ -n "$RID" ] || { echo "setup failed: the run did not start"; cat "$T/r1.txt"; exit 1; }
$DP --verdict "$RID" PASS --force --note "owner accepts the failing NEVER check" --repo "$H" > "$T/v.txt" 2>&1 || { echo "setup failed: forced PASS"; cat "$T/v.txt"; exit 1; }
mkdir -p "$H/.git/concord/ledger"
python3 -I -c 'import json, sys
f = lambda i, sev, st, text: dict(id=f"F{i}", severity=sev, path="a.py", line=1, line_end=1, problem=text, fix="", repro={},
                                  reviewer="opus55", run="r1", at="2026-11-15T00:00:00", status=st)
json.dump(dict(key="PLAN_rep", next_finding=3, next_decision=1, decisions=[], findings=[
          f(1, "MEDIUM", "open", "medium-thing"), f(2, "NOTE", "note", "note-thing")]), open(sys.argv[1], "w"))' "$H/.git/concord/ledger/PLAN_rep.json"
$DP --report --plan PLAN_rep.md --repo "$H" > "$T/rep.txt" 2>&1; RC=$?
REP=$(sed -n 's/^report: //p' "$T/rep.txt" | head -1)
[ $RC -eq 0 ] && [ "$REP" = "$H/.git/concord/reports/REPORT_rep.md" ] && [ -f "$REP" ] \
  && ok "4.1 --report writes REPORT_<ticket>.md in the runs root and prints its path" || { bad "4.1 rc=$RC path=$REP"; tail -3 "$T/rep.txt"; }
[ -f "$REP" ] || REP="$T/none"
prev=0; order=ok
for h in "# Test report: rep" "## Overrides" "## Phases" "## Test plan" "## Test lines" "## Review" "## Open items for the DAT" "## Time"; do
  n=$(grep -nxF -- "$h" "$REP" | head -1 | cut -d: -f1); { [ -n "$n" ] && [ "$n" -gt "$prev" ]; } || order="missing or out of order: $h"; prev=${n:-0}
done
[ "$order" = ok ] && ok "4.2 the report opens with Overrides, then six more sections in order" || { bad "4.2 $order"; grep "^#" "$REP"; }
sec(){ sed -n "/^## $1/,/^## /p" "$REP"; }
ov=$(sed -n '/^## Overrides/,/^## [^O]/p' "$REP")
echo "$ov" | grep -qF "grep -q NEVER a.py" && echo "$ov" | grep -qF "owner accepts the failing NEVER check" \
  && ok "4.2b Overrides: the forced PASS, its failed command beside the owner's reason" || { bad "4.2b overrides"; echo "$ov"; }
sec Phases | grep -Eq '^\| 1 \| [^|]+ \| 1 \|' && ok "4.3 phase row: one run of phase 1" || { bad "4.3 phases"; sec Phases; }
sec "Test plan" | grep -qF "marker-behavior-row" && ok "4.4 the plan's Test plan is copied" || { bad "4.4 test plan"; sec "Test plan"; }
sec "Test lines" | grep -qF "| tests/a_test.sh | 2 | 0 |" && ! sec "Test lines" | grep -qF "| a.py |" \
  && sec "Test lines" | grep -qF "Total: +2 -0 lines; plan Tests: +1/−0 lines, net ≤ +1" \
  && ok "4.5 test lines: test files only, the actual total beside the plan's Tests: estimate, which fails nothing though the actual is above it" || { bad "4.5 test lines"; sec "Test lines"; }
sec Review | grep -qF "| r1 | opus55 | 0 | 0 | 1 | 1 |" && ok "4.6 review row: BLOCKER/HIGH/MEDIUM/NOTE per reviewer and run" || { bad "4.6 review"; sec Review; }
O=$(sec "Open items for the DAT")
echo "$O" | grep -qF "medium-thing" && echo "$O" | grep -qF "note-thing" \
  && echo "$O" | grep -qF "Q1 which name to show" \
  && ok "4.7 open items: open and note findings, open questions" || { bad "4.7 open items"; echo "$O"; }
grep -Eq '^Elapsed [0-9]+ min against ETA 30 min \(plan\)' "$REP" && grep -q '^Concurrency: 1.00' "$REP" \
  && ok "4.8 time against the plan's ETA; concurrency of one run" || { bad "4.8 time"; sec Time; }
python3 -I -c 'import json,sys; p,r=sys.argv[1:3]; d=json.load(open(p)); assert d[r].get("reported"), d[r]' "$H/.git/concord/drift.json" "$H" 2>/dev/null \
  && $DP --drift --plan PLAN_rep.md --repo "$H" 2>&1 | grep -q "DRIFT OFF" && ok "4.9 the report stops the drift clock" || bad "4.9 drift still on"
python3 -I -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["estimates"]={"PLAN_rep.md": 12}; json.dump(d,open(p,"w"))' "$H/.git/concord/drift.json"
$DP --report --plan PLAN_rep.md --repo "$H" > /dev/null 2>&1
grep -Eq '^Elapsed [0-9]+ min against ETA 12 min \(computed\)' "$REP" && ok "4.10 a stored estimate is the ETA the report uses" || { bad "4.10"; grep '^Elapsed' "$REP"; }
git -C "$H" commit -qam pr && P7=$(git -C "$H" rev-parse HEAD) && git -C "$H" checkout -qb other HEAD~1 && echo s > "$H/s.txt" && git -C "$H" add s.txt \
  && git -C "$H" commit -qm other && P20=$(git -C "$H" rev-parse HEAD) && git -C "$H" checkout -q - && git -C "$H" merge -q --no-edit other   # PR 20 comes in with main
for x in "7 $P7 pr-thing" "20 $P20 other-thing"; do read -r n h p <<< "$x"; mkdir -p "$H/.git/concord/pr$n-a"; printf '{"kind": "pr-review", "pr": %s, "head": "%s"}' "$n" "$h" > "$H/.git/concord/pr$n-a/meta.json"
  python3 -I -c 'import json,sys; n,p=sys.argv[2:]; json.dump(dict(key="pr"+n, next_finding=2, next_decision=1, decisions=[], findings=[dict(id="F1", severity="HIGH", status="open", problem=p, run=f"pr{n}-a", reviewer="opus55")]), open(sys.argv[1], "w"))' "$H/.git/concord/ledger/pr$n.json" "$n" "$p"; done
$DP --report --plan PLAN_rep.md --repo "$H" > /dev/null 2>&1
sec "Open items for the DAT" | grep -qF "pr-thing" && sec Review | grep -qF "| pr7-a | opus55 | 0 | 1 | 0 | 0 |" && ! grep -qF "other-thing" "$REP" \
  && ok "4.11 the reviews of the ticket's PR are in the report, not those of a PR merged in with main" || { bad "4.11 PR ledger"; sec Review; grep -F "other-thing" "$REP"; }


echo "== 5 the report attributes each finding outcome to its round, head and closing review (S11)"
O5="$T/o5.git"; HC="$T/hc"
git init -q --bare -b main "$O5" && git clone -q "$O5" "$HC" 2> /dev/null || { echo "setup failed: repos"; exit 1; }
( set -e; cd "$HC"; git config user.email t@t; git config user.name t; printf 'x = 1\n' > a.py; printf '.claude/\n' > .gitignore; git add -A; git commit -qm init; git push -q origin main
  printf '# Plan\nTier: M\nSize: ~10 lines\nETA: 30 min\n\n## Phase 1 - change a\nExecutor: deepseek-flash\nFiles: a.py\nAcceptance:\n- `grep -q 2 a.py`\n' > PLAN_o.md
  git checkout -qb pr7 ) || { echo "setup failed: pr repo"; exit 1; }
approve PLAN_o.md "$HC" || exit 1
FAKE_ACTIONS='echo "x = 2" > a.py' $DP 1 --plan PLAN_o.md --via qwen --model fake/m --no-baseline --repo "$HC" > "$T/out.txt" 2>&1
RIDO=$(sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
[ -n "$RIDO" ] || { echo "setup failed: phase run of PLAN_o"; cat "$T/out.txt"; exit 1; }
$DP --verdict "$RIDO" PASS --repo "$HC" > "$T/v.txt" 2>&1 || { echo "setup failed: PASS of the run of PLAN_o (a run with no verdict blocks --report)"; cat "$T/v.txt"; exit 1; }
( cd "$HC" && git add a.py && git commit -qm "pr7 head 1" && git push -q origin HEAD:refs/pull/7/head ); H71=$(git -C "$HC" rev-parse HEAD)
pj(){ printf '{"baseRefName": "main", "headRefName": "pr7", "headRefOid": "%s", "title": "t", "body": "b"}\n' "$(git -C "$HC" rev-parse HEAD)" > "$T/pr7.json"; }
pj
opus7(){ $DP --review-pr 7 --packet --tier medium --repo "$HC" > "$T/out.txt" 2>&1; local pk; pk=$(sed -n 's/^PACKET \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
  [ -n "$pk" ] || { echo "setup failed: no packet for PR 7"; cat "$T/out.txt"; exit 1; }
  cp "$1" "$T/ans.txt"; sign "$T/ans.txt" "$pk"; RV7=$(basename "$(dirname "$pk")")
  $DP --review-record "$RV7" --reviewer concord:reviewer-opus55 --file "$T/ans.txt" --repo "$HC" > "$T/rec.txt" 2>&1 || { echo "setup failed: record"; cat "$T/rec.txt"; exit 1; }; }
printf 'REVIEW-JSON\n{"findings": [{"severity": "HIGH", "path": "a.py", "line": 1, "problem": "wrong constant", "fix": "use 3", "repro": {"input": "x", "expected": "3", "actual": "2"}}], "clauses": [], "tests": [], "verdict": "FIX"}\nEND-REVIEW-JSON\n' > "$T/h1.txt"
printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN", "resolutions": [{"finding": "F1", "fixed": "yes", "evidence": "a.py:1 it is 3 now"}]}\nEND-REVIEW-JSON\n' > "$T/h2.txt"
opus7 "$T/h1.txt"; RV71="$RV7"
( cd "$HC" && echo "x = 3" > a.py && git commit -qam "pr7 head 2" && git push -q origin HEAD:refs/pull/7/head ); H72=$(git -C "$HC" rev-parse HEAD); pj
opus7 "$T/h2.txt"; RV72="$RV7"
$DP --report --plan PLAN_o.md --repo "$HC" > "$T/rep.txt" 2>&1; RC=$?; REP5=$(sed -n 's/^report: //p' "$T/rep.txt" | head -1)
[ $RC -eq 0 ] && [ -f "$REP5" ] && grep -F "F1" "$REP5" | grep -qF "${H71:0:8}" && grep -F "F1" "$REP5" | grep -qF "${H72:0:8}" && grep -F "F1" "$REP5" | grep -qF "$RV72" \
  && ok "5 the outcome of F1 names the head it was found at, the head that fixed it and the review that closed it" \
  || { bad "5 outcome attribution rc=$RC"; sed -n 1,40p "$REP5" 2>/dev/null; }

echo "== 6 a forced PASS shows the owner's reason, or 'reason: not recorded', never a failed command as the reason (S47)"
H6="$T/h6"; mkdir -p "$H6"
( set -e; cd "$H6"; git init -q -b main; git config user.email t@t; git config user.name t; printf 'x = 1\n' > a.py; printf '.claude/\n' > .gitignore; git add -A; git commit -qm init
  printf '# Plan\nTier: M\nSize: ~10 lines\nETA: 30 min\n\n## Phase 1 - change a\nExecutor: deepseek-flash\nFiles: a.py\nAcceptance:\n- `grep -q NEVER a.py`\n' > PLAN_f.md ) || { echo "setup failed: repo 6"; exit 1; }
approve PLAN_f.md "$H6" || exit 1
f6(){ FAKE_ACTIONS='echo "x = 2" >> a.py' $DP 1 --plan PLAN_f.md --via qwen --model fake/m --no-baseline --repo "$H6" > "$T/out.txt" 2>&1
  RID6=$(sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
  [ -n "$RID6" ] && [ "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["acceptance_after_rc"])' "$H6/.git/concord/$RID6/meta.json")" = "[1]" ] \
    || { echo "setup failed: the run of PLAN_f did not reach a failed acceptance command"; cat "$T/out.txt"; exit 1; }; }
f6; RA="$RID6"; $DP --verdict "$RA" PASS --force --repo "$H6" > "$T/v.txt" 2>&1; grep -qF "PASS (forced)" "$T/v.txt" || { echo "setup failed: forced PASS without a note"; cat "$T/v.txt"; exit 1; }
f6; RB="$RID6"; $DP --verdict "$RB" PASS --force --note "owner accepts the failing NEVER check" --repo "$H6" > "$T/v.txt" 2>&1; grep -qF "PASS (forced)" "$T/v.txt" || { echo "setup failed: forced PASS with a note"; cat "$T/v.txt"; exit 1; }
$DP --report --plan PLAN_f.md --repo "$H6" > "$T/rep.txt" 2>&1; REP6=$(sed -n 's/^report: //p' "$T/rep.txt" | head -1); [ -f "$REP6" ] || { echo "setup failed: --report"; cat "$T/rep.txt"; exit 1; }
LA=$(sed -n '/^## Overrides/,/^## [^O]/p' "$REP6" | grep -F "$RA"); LB=$(sed -n '/^## Overrides/,/^## [^O]/p' "$REP6" | grep -F "$RB")
echo "$LA" | grep -qF "grep -q NEVER a.py" && echo "$LA" | grep -qF "reason: not recorded" \
  && ok "6 a forced PASS with no --note: the failed command is listed and the reason reads 'reason: not recorded'" || { bad "6 forced PASS without a note"; echo "$LA"; }
echo "$LB" | grep -qF "grep -q NEVER a.py" && echo "$LB" | grep -qF "reason: owner accepts the failing NEVER check" && ! echo "$LB" | grep -qF "forced:" \
  && ok "6 a forced PASS with a --note: the reason is the note, not a failed command" || { bad "6 forced PASS with a note"; echo "$LB"; }

echo; echo "passed $pass, failed $fail"; [ $fail -eq 0 ]
