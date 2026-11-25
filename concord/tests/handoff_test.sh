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
NF="$RUNS/notes/$(python3 -I -c 'import hashlib,sys; print(hashlib.sha256(("%s::PLAN_T.md" % open(sys.argv[1]).read().strip()).encode()).hexdigest()[:8])' "$R/.git/concord-id")-PLAN_T.md"
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
TID8=$(python3 -I -c 'import hashlib,sys; print(hashlib.sha256(("%s::PLAN_rep.md" % open(sys.argv[1]).read().strip()).encode()).hexdigest()[:8])' "$H/.git/concord-id")
mkdir -p "$H/.git/concord/ledger"
python3 -I -c 'import json, sys
f = lambda i, sev, st, text: dict(id=f"F{i}", severity=sev, path="a.py", line=1, line_end=1, problem=text, fix="", repro={},
                                  reviewer="opus55", run="r1", at="2026-11-15T00:00:00", status=st)
json.dump(dict(key="PLAN_rep", next_finding=3, next_decision=1, decisions=[], findings=[
          f(1, "MEDIUM", "open", "medium-thing"), f(2, "NOTE", "note", "note-thing")]), open(sys.argv[1], "w"))' "$H/.git/concord/ledger/PLAN_rep-$TID8.json"
perl -pi -e 's/marker-behavior-row/marker-live-edit/' "$H/PLAN_rep.md"      # an unapproved edit of the live Test plan
$DP --report --plan PLAN_rep.md --repo "$H" > "$T/rep.txt" 2>&1; RC=$?
REP=$(sed -n 's/^report: //p' "$T/rep.txt" | head -1)
[ $RC -eq 0 ] && [ "$REP" = "$H/.git/concord/reports/REPORT_rep-$TID8.md" ] && [ -f "$REP" ] \
  && ok "4.1 --report writes REPORT_<ticket>-<ticket id>.md in the runs root and prints its path" || { bad "4.1 rc=$RC path=$REP"; tail -3 "$T/rep.txt"; }
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
CAND=$(sed -n 's/^graded candidate: \([0-9a-f]\{12\}\).*/\1/p' "$T/r1.txt" | head -1)
grep -qE '^plan revision: 1 \([0-9a-f]{12}\)$' "$T/r1.txt" && [ -n "$CAND" ] \
  && sec Phases | grep -Eq "^\| 1 \| [^|]+ \| 1 \| PASS[^|]* \| [^|]+ \| 1 \| $CAND \| none \|\$" \
  && ok "4.3 phase row: one run of phase 1, at plan revision 1, its graded candidate, no review of it; the run report names the revision" \
  || { bad "4.3 phases"; sec Phases; grep -E '^(plan revision|graded candidate)' "$T/r1.txt"; }
sec "Test plan" | grep -qF "marker-behavior-row" && ! sec "Test plan" | grep -qF "marker-live-edit" \
  && ok "4.4 the Test plan is the approved revision's, not an unapproved edit of the plan on disk" || { bad "4.4 test plan"; sec "Test plan"; }
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
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert [t for t in d["tickets"].values() if t["checkout"] == sys.argv[2]][0].get("reported")' "$H/.git/concord/drift.json" "$H" 2>/dev/null \
  && $DP --drift --plan PLAN_rep.md --repo "$H" 2>&1 | grep -q "DRIFT OFF" && ok "4.9 the report stops the drift clock" || bad "4.9 drift still on"
python3 -I -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); [t for t in d["tickets"].values() if t["checkout"] == sys.argv[2]][0]["estimate"] = 12; json.dump(d,open(p,"w"))' "$H/.git/concord/drift.json" "$H"
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

echo "== 7 provenance: a phase row names the revision its run followed and the review of its graded candidate; a planner run no review read is an override"
H7="$T/h7"; mkdir -p "$H7"
( set -e; cd "$H7"; git init -q -b main; git config user.email t@t; git config user.name t; printf 'x = 1\n' > a.py; printf 'y = 1\n' > b.py; printf '.claude/\n' > .gitignore; git add -A; git commit -qm init
  printf '# Plan\nTier: M\nSize: ~10 lines\nETA: 30 min\n\n## Phase 1 - change a\nExecutor: planner\nFiles: a.py\nAcceptance:\n- `grep -q 2 a.py`\n\n## Phase 2 - change b\nExecutor: deepseek-flash\nRisk: low\nFiles: b.py\nAcceptance:\n- `grep -q 2 b.py`\n' > PLAN_p.md ) || { echo "setup failed: repo 7"; exit 1; }
approve PLAN_p.md "$H7" || exit 1
$DP --begin 1 --label planner --plan PLAN_p.md --repo "$H7" > "$T/b7.txt" 2>&1; RP=$(sed -n 's/^BEGIN \([^ ]*\).*/\1/p' "$T/b7.txt" | head -1)
[ -n "$RP" ] || { echo "setup failed: --begin of PLAN_p"; cat "$T/b7.txt"; exit 1; }
echo "x = 2" > "$H7/a.py"
{ $DP --end "$RP" --repo "$H7" > "$T/e7.txt" 2>&1 && $DP --verdict "$RP" PASS --repo "$H7" > "$T/v.txt" 2>&1; } || { echo "setup failed: planner run of PLAN_p"; cat "$T/e7.txt" "$T/v.txt"; exit 1; }
perl -pi -e 's/^Size: ~10 lines$/Size: ~12 lines/' "$H7/PLAN_p.md"; approve PLAN_p.md "$H7" || exit 1   # revision 2, approved after phase 1 ran
FAKE_ACTIONS='echo "y = 2" > b.py' $DP 2 --plan PLAN_p.md --via qwen --model fake/m --repo "$H7" > "$T/r7.txt" 2>&1
RQ=$(sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/r7.txt" | head -1); [ -n "$RQ" ] || { echo "setup failed: phase 2 run of PLAN_p"; cat "$T/r7.txt"; exit 1; }
FAKE_ACTIONS='printf "REVIEW-JSON\n{\"findings\": [], \"clauses\": [], \"tests\": [], \"verdict\": \"CLEAN\"}\nEND-REVIEW-JSON\n"' \
  $DP --review "$RQ" --via qwen --model fake/m --repo "$H7" > "$T/rv7.txt" 2>&1 || { echo "setup failed: review of the first candidate"; cat "$T/rv7.txt"; exit 1; }
echo "y = 22" > "$H7/b.py"
{ $DP --grade "$RQ" --repo "$H7" > "$T/g7.txt" 2>&1 && $DP --verdict "$RQ" PASS --repo "$H7" > "$T/v.txt" 2>&1; } || { echo "setup failed: regrade and PASS"; cat "$T/g7.txt" "$T/v.txt"; exit 1; }
$DP --report --plan PLAN_p.md --repo "$H7" > "$T/rep.txt" 2>&1; REP7=$(sed -n 's/^report: //p' "$T/rep.txt" | head -1); [ -f "$REP7" ] || { echo "setup failed: --report of PLAN_p"; cat "$T/rep.txt"; exit 1; }
row7(){ sed -n '/^## Phases/,/^## [^P]/p' "$REP7" | grep -E "^\| $1 \|"; }
ov7=$(sed -n '/^## Overrides/,/^## [^O]/p' "$REP7")
row7 1 | grep -Eq '^\| 1 \| planner \| 1 \| PASS \| 1/1 pass \| 1 \|' && row7 2 | grep -Eq '^\| 2 \| [^|]+ \| 1 \| PASS \| 1/1 pass \| 2 \|' \
  && grep -qE '^plan revision: 1 ' "$T/e7.txt" && grep -qE '^plan revision: 2 ' "$T/r7.txt" \
  && ok "7.1 each phase row and run report name the revision that run followed, not the newest approved one" || { bad "7.1 revisions"; row7 1; row7 2; grep '^plan revision' "$T/e7.txt" "$T/r7.txt"; }
row7 2 | grep -Eq '\| none \|$' && echo "$ov7" | grep -F "phase 2 (run $RQ)" | grep -qF "its other reviews saw an earlier candidate" \
  && ok "7.2 a review of an earlier candidate is not shown as the graded candidate's review" || { bad "7.2 review column"; row7 2; echo "$ov7"; }
echo "$ov7" | grep -qF "phase 1 (run $RP) not reviewed (needs medium)" \
  && ok "7.3 a planner run that no review read is listed under Overrides, like an executor run" || { bad "7.3 planner override"; echo "$ov7"; }

echo "== 8 resume: a PASS holds for the requirements it graded; a revision that changes a phase needs a new run of it, one that changes only its Executor:, Size: or Notes:, or another phase, does not"
H8="$T/h8"; mkdir -p "$H8"
( set -e; cd "$H8"; git init -q -b main; git config user.email t@t; git config user.name t
  printf 'x = 1\n' > a.py; printf 'y = 1\n' > b.py; printf 'z = 1\n' > c.py; printf '.claude/\n' > .gitignore; git add -A; git commit -qm init
  printf '# Plan\nTier: M\nSize: ~40 lines\nETA: 30 min\n\n## Phase 1 - change a\nExecutor: planner\nFiles: a.py\nAcceptance:\n- `grep -q 2 a.py`\n\n## Phase 2 - change b\nExecutor: planner\nFiles: b.py\nAcceptance:\n- `grep -q 2 b.py`\n\n## Phase 3 - change c\nExecutor: planner\nFiles: c.py\nAcceptance:\n- `grep -q 2 c.py`\n\n## Phase 4 - add d\nExecutor: planner\nFiles: d.py\nAcceptance:\n- `test -f d.py`\n\n## Phase 5 - add e\nExecutor: planner\nKeep e.py to one line.\nFiles: e.py\nAcceptance:\n- `test -f e.py`\n\n## Phase 6 - add f\nExecutor: planner\nFiles: f.py\nSteps:\n1. Write the settings:\n```yaml\nsize: 512\n```\nAcceptance:\n- `test -f f.py`\n\n## Phase 7 - add g\nExecutor: planner\nFiles: g.py\nSteps:\n1. Write g.py.\n   - Size: under 3 lines\nAcceptance:\n- `test -f g.py`\n\n## Phase 8 - add h\nExecutor: planner\nFiles: h.py\nNotes:\n- a.py:1-1 - the style to follow\nKeep h.py short.\nAcceptance:\n- `test -f h.py`\n\n## Phase 9 - add i\nExecutor: planner\nFiles: i.py\nNotes:\n- a.py:1-1 - the style to follow\n- Decisions: one assignment\nAcceptance:\n- `test -f i.py`\n' > PLAN_r.md ) || { echo "setup failed: repo 8"; exit 1; }
$DP --phases --plan PLAN_r.md --repo "$H8" > "$T/ph8.txt" 2>&1; RC=$?
[ $RC -eq 11 ] && grep -qxF "phase 1: NOT RUN" "$T/ph8.txt" && grep -q "^NOTE: the plan on disk has no recorded APPROVE" "$T/ph8.txt" \
  && ok "8.1 --phases on a plan nobody approved says so and exits 11" || { bad "8.1 unapproved plan rc=$RC"; cat "$T/ph8.txt"; }
approve PLAN_r.md "$H8" || exit 1
p8(){ RID8=""   # a planner run of phase $1 that writes $3 into $2 and passes
  $DP --begin "$1" --label planner --plan PLAN_r.md --repo "$H8" > "$T/b8.txt" 2>&1; RID8=$(sed -n 's/^BEGIN \([^ ]*\).*/\1/p' "$T/b8.txt" | head -1)
  [ -n "$RID8" ] || { echo "setup failed: --begin $1 of PLAN_r"; cat "$T/b8.txt"; exit 1; }
  echo "$3" > "$H8/$2"
  { $DP --end "$RID8" --repo "$H8" > "$T/e8.txt" 2>&1 && $DP --verdict "$RID8" PASS --repo "$H8" > "$T/v8.txt" 2>&1; } \
    || { echo "setup failed: planner run of phase $1"; cat "$T/e8.txt" "$T/v8.txt"; exit 1; }; }
p8 1 a.py "x = 2"; P81=$RID8; p8 2 b.py "y = 2"; P82=$RID8; p8 3 c.py "z = 2"; p8 5 e.py "w = 1"; P85=$RID8
p8 6 f.py "v = 1"; P86=$RID8; p8 7 g.py "u = 1"; P87=$RID8; p8 8 h.py "t = 1"; P88=$RID8; p8 9 i.py "s = 1"; P89=$RID8
perl -0pi -e 's/Executor: planner\nFiles: a\.py/Executor: implementer\nSize: ~1 lines\nNotes:\n- a.py:1-1 - the line to change\nFiles: a.py/; s/grep -q 2 b\.py/grep -q 3 b.py/; s/grep -q 2 c\.py/grep -q 3 c.py/; s/one line\./two lines./; s/size: 512/size: 1024/; s/under 3 lines/under 4 lines/; s/h\.py short\./h.py shorter./; s/one assignment/two assignments/' "$H8/PLAN_r.md"
$DP --phases --plan PLAN_r.md --repo "$H8" > "$T/ph8.txt" 2>&1; RC=$?
[ $RC -eq 11 ] && grep -qxF "phase 2: PASS (run $P82, revision 1)" "$T/ph8.txt" && grep -q "^NOTE: the plan on disk has no recorded APPROVE.* revision 1" "$T/ph8.txt" \
  && ok "8.2 before its APPROVE, a revision is not read: --phases gives revision 1's states, says so and exits 11" || { bad "8.2 unapproved revision rc=$RC"; cat "$T/ph8.txt"; }
approve PLAN_r.md "$H8" || exit 1   # revision 2: phase 1 gets another executor, a size and notes; phases 2, 3 and 5 to 9 other requirements
$DP --begin 1 --label planner --plan PLAN_r.md --repo "$H8" > "$T/b8.txt" 2>&1; A81=$(sed -n 's/^BEGIN \([^ ]*\).*/\1/p' "$T/b8.txt" | head -1)
{ [ -n "$A81" ] && $DP --abort "$A81" --repo "$H8" > "$T/a8.txt" 2>&1; } || { echo "setup failed: aborted run of phase 1"; cat "$T/b8.txt" "$T/a8.txt"; exit 1; }
p8 3 c.py "z = 3"; P83=$RID8
$DP --phases --plan PLAN_r.md --repo "$H8" > "$T/ph8.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && grep -qxF "phase 1: PASS (run $P81, revision 1)" "$T/ph8.txt" \
  && ok "8.3 a phase whose new revision changed only its Executor:, Size: and Notes: keeps its PASS; an aborted run since does not count" || { bad "8.3 unchanged requirements rc=$RC"; cat "$T/ph8.txt"; }
grep -qxF "phase 2: CHANGED (run $P82 passed revision 1; revision 2 changed the phase)" "$T/ph8.txt" \
  && ok "8.4 a phase whose acceptance changed after its PASS reads CHANGED, not PASS" || { bad "8.4 changed acceptance"; cat "$T/ph8.txt"; }
grep -qxF "phase 5: CHANGED (run $P85 passed revision 1; revision 2 changed the phase)" "$T/ph8.txt" \
  && ok "8.5 a requirement line below the Executor: line is part of what the PASS graded" || { bad "8.5 line after Executor:"; cat "$T/ph8.txt"; }
grep -qxF "phase 6: CHANGED (run $P86 passed revision 1; revision 2 changed the phase)" "$T/ph8.txt" \
  && ok "8.6 a line in a code fence that reads like a Size: field is part of what the PASS graded" || { bad "8.6 fenced line"; cat "$T/ph8.txt"; }
grep -qxF "phase 7: CHANGED (run $P87 passed revision 1; revision 2 changed the phase)" "$T/ph8.txt" \
  && ok "8.7 an indented line that reads like a Size: field is part of what the PASS graded" || { bad "8.7 indented line"; cat "$T/ph8.txt"; }
grep -qxF "phase 8: CHANGED (run $P88 passed revision 1; revision 2 changed the phase)" "$T/ph8.txt" \
  && ok "8.8 a line below a Notes: list that is no list item is part of what the PASS graded" || { bad "8.8 line after Notes:"; cat "$T/ph8.txt"; }
grep -qxF "phase 9: CHANGED (run $P89 passed revision 1; revision 2 changed the phase)" "$T/ph8.txt" \
  && ok "8.9 a field written as a list item ends a Notes: list" || { bad "8.9 field after Notes:"; cat "$T/ph8.txt"; }
grep -qxF "phase 3: PASS (run $P83, revision 2)" "$T/ph8.txt" && grep -qxF "phase 4: NOT RUN" "$T/ph8.txt" \
  && ok "8.10 a run under the new revision restores the PASS; a phase that never ran reads NOT RUN" || { bad "8.10 rerun"; cat "$T/ph8.txt"; }
p8 5 e.py "w = 1"; P85B=$RID8
$DP --phases --plan PLAN_r.md --repo "$H8" > "$T/ph8.txt" 2>&1
grep -qxF "phase 5: PASS (run $P85B, revision 2)" "$T/ph8.txt" \
  && ok "8.11 a planner run that changes nothing re-grades a CHANGED phase whose code already meets it" || { bad "8.11 re-grade"; cat "$T/ph8.txt"; }
$DP --report --plan PLAN_r.md --repo "$H8" > "$T/rep.txt" 2>&1; REP8=$(sed -n 's/^report: //p' "$T/rep.txt" | head -1)
[ -f "$REP8" ] || { echo "setup failed: --report of PLAN_r"; cat "$T/rep.txt"; exit 1; }
row8(){ sed -n '/^## Phases/,/^## [^P]/p' "$REP8" | grep -E "^\| $1 \|"; }
ov8=$(sed -n '/^## Overrides/,/^## [^O]/p' "$REP8")
row8 2 | grep -qF "| PASS (phase changed since) |" && row8 3 | grep -qF "| PASS |" \
  && echo "$ov8" | grep -qxF -- "- phase 2: run $P82 passed revision 1; revision 2 changed the phase, so that PASS does not cover it" \
  && ! echo "$ov8" | grep -qE -- "^- phase (1|3): run " \
  && ok "8.12 the report does not count a PASS of other requirements: its row says so and Overrides names it" || { bad "8.12 report"; row8 2; row8 3; echo "$ov8"; }
row8 1 | grep -Eq '^\| 1 \| planner \| [0-9]+ \| PASS \| 1/1 pass \| 1 \|' && echo "$ov8" | grep -qF "phase 1 (run $P81) not reviewed" \
  && ok "8.13 an aborted run leaves the phase's row and review line to its last counted run" || { bad "8.13 aborted run in the report"; row8 1; echo "$ov8"; }

echo; echo "passed $pass, failed $fail"; [ $fail -eq 0 ]
