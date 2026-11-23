#!/bin/bash
# concord.py (PLAN_kit-lint2): ACCEPTANCE LINT lines of --lint (A-C); a planner may edit its plan inside its own
# --begin/--end run, an executor may not (D); --review/--packet scoped by --files/--exclude (E). No network.
# Run: bash ~/.claude/concord/tests/acclint_test.sh [ABCDE]   (exit 0 = every selected check passed).
set -u
SEL="${1:-ABCDE}"
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/acclint-test.XXXXXX")" && pwd -P)"; export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/concord" "$T/home/.claude"
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
cat > "$T/bin/qwen" <<'Q'
#!/bin/sh
echo ran >> "$T/qwen_calls"
if [ -n "${FAKE_ACTIONS:-}" ]; then sh -c "$FAKE_ACTIONS"; exit 0; fi
printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n'
Q
chmod +x "$T/bin/qwen"
XDEV="$(xcode-select -p 2>/dev/null)"; [ -n "$XDEV" ] && [ -x "$XDEV/usr/bin/git" ] && [ -x "$XDEV/usr/bin/python3" ] && export PATH="$XDEV/usr/bin:$PATH"
export PATH="$T/bin:$PATH" HOME="$T/home"
DP="python3 $T/concord/concord.py"
R="$T/repo"; RUNS="$R/.git/concord"
. "$(dirname "$0")/lib.sh"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
has(){ grep -F -- "$1" "$T/out.txt" > /dev/null; }
sel(){ case "$SEL" in *$1*) return 0;; esac; return 1; }
calls(){ [ -f "$T/qwen_calls" ] && wc -l < "$T/qwen_calls" | tr -d ' ' || echo 0; }
rid(){ sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1; }
bid(){ sed -n 's/.*concord.py --end \([^ ]*\).*/\1/p' "$T/out.txt" | tail -1; }
meta(){ python3 -I -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))" "$RUNS/$1/meta.json" "$2"; }
lint(){ sed -n 's/^ACCEPTANCE LINT: //p' "$T/out.txt"; }
nlint(){ lint | wc -l | tr -d ' '; }
first(){ grep -n -- "$1" "$T/out.txt" | head -1 | cut -d: -f1; }
last(){ grep -n -- "$1" "$T/out.txt" | tail -1 | cut -d: -f1; }
run(){ FAKE_ACTIONS="$1" $DP 1 --plan "${2:-PLAN_E.md}" --via qwen --model fake/m --no-baseline --repo "$R" > "$T/out.txt" 2>&1
  grep -q '^DELEGATE RESULT' "$T/out.txt" || { echo "setup failed: the run did not start"; cat "$T/out.txt"; exit 1; }; }
review(){ $DP --review "$@" --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1; }
newest_review(){ ls -td "$RUNS"/*-review-* | head -1; }
mkdir -p "$R/tests" "$R/docs" && ( cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > a.py; printf 'doc\n' > docs/x.md; printf 'exit 0\n' > tests/exists.sh; printf '.claude/\n' > .gitignore
  git add -A && git commit -qm init
  cat > PLAN_L.md <<'P'
# Plan
## Phase 1 - p1
Executor: deepseek-flash
Files: a.py
Acceptance:
- `grep -q 2 a.py`
## Phase 2 - dirty
Executor: deepseek-flash
Files: a.py, tests/new.sh
Acceptance:
- `grep -c x f | grep -qx 0`
- `grep -vc x f | grep -qx 0`
- `test "$(wc -l < f)" = 7`
- bash tests/x.sh
- `bash tests/nothere.sh`
- `grep -c x concord/nothere.md | grep -qx 0`
- `bash tests/nothere.sh` (again)
## Phase 3 - clean
Executor: deepseek-flash
Files: a.py, tests/missing_in_files.sh, tests/
Acceptance: all of these pass
- `pytest -q`
- `test "$(wc -l < f)" -eq 7`
- `bash tests/exists.sh`
- `bash ./tests/exists.sh`
- `python3 -B -I -c "print(1)"`
- `grep -c x f | wc -l | grep -qx 0`
- `ls tests/*.sh`
- `test -f /dev/null`
- `bash tests/missing_in_files.sh`
- `bash tests/new.sh`
- `bash tests/exists.sh >/dev/null 2>&1` `sed -n 's/^x//p' f`
- `VAR=docs/none bash tests/exists.sh` `pytest concord/x.py::test_y` `python3 -c "open('docs/none.md')"`
- `bash tests/exists.sh && true`
  continuation line without backticks, tests/zzz.sh
## Phase 4 - none
Executor: deepseek-flash
Files: a.py
Out of scope: nothing
## Phase 5 - inline
Executor: deepseek-flash
Files: a.py
Acceptance: `grep -c x f | grep -qx 0`
P
  for f in PLAN_D.md PLAN_D2.md PLAN_D3.md; do printf '# Plan\n## Phase 1 - p1\nExecutor: deepseek-flash\nFiles: a.py\nAcceptance:\n- `grep -q 2 a.py`\n' > $f; done
  printf '# Plan\n## Phase 1 - p1\nExecutor: deepseek-flash\nFiles: a.py, docs/x.md, big.py, docs/y.md\nAcceptance:\n- `grep -q 2 a.py`\n' > PLAN_E.md
  git add -A && git commit -qm plans ) || { echo "setup failed"; exit 1; }
for f in PLAN_D PLAN_D2 PLAN_D3 PLAN_E; do approve $f.md "$R" || exit 1; done

if sel A; then echo "== A. lint lines, dirty block"
$DP --lint 2 --dry-run --via qwen --model fake/m --plan PLAN_L.md --repo "$R" > "$T/out.txt" 2>&1; RC=$?
printf '%s\n' 'vacuous on empty input: grep -c x f | grep -qx 0' 'vacuous on empty input: grep -vc x f | grep -qx 0' \
  'string compare of wc output: test "$(wc -l < f)" = 7' 'not run (no backticks): bash tests/x.sh' \
  'names a missing file outside Files: tests/nothere.sh' 'vacuous on empty input: grep -c x concord/nothere.md | grep -qx 0' \
  'names a missing file outside Files: concord/nothere.md' > "$T/want.txt"
lint > "$T/got.txt"; [ $RC -eq 0 ] && diff -u "$T/want.txt" "$T/got.txt" > "$T/diff.txt" && ok "A.2 exit 0, seven lint lines: plan order, two rules per command, one line per missing path" \
  || { bad "A.2 lint lines differ"; cat "$T/diff.txt"; }
$DP --lint 5 --dry-run --via qwen --model fake/m --plan PLAN_L.md --repo "$R" > "$T/out.txt" 2>&1
[ "$(lint)" = "vacuous on empty input: grep -c x f | grep -qx 0" ] && ok "A.4 an inline Acceptance: command is linted" || { bad "A.4 inline Acceptance: not linted"; lint; }
printf '# Plan: Porting the parser\n## Phase 1 - p1\nFiles: a.py\nAcceptance:\n- `grep -q 2 a.py`\n' > "$T/P.md"; $DP --lint 1 --dry-run --via qwen --model fake/m --plan "$T/P.md" --repo "$R" > "$T/out.txt" 2>&1
lint | grep -q "differential oracle" && ok "A.5 a port plan without a mismatch oracle is linted" || { bad "A.5 port without oracle not linted"; lint; }
sed 's/^## Phase/### Phase/; s/grep -q 2 a.py/grep -qx "mismatches: 0" a.py/' "$T/P.md" > "$T/P6.md"; $DP --lint 1 --dry-run --via qwen --model fake/m --plan "$T/P6.md" --repo "$R" > "$T/out.txt" 2>&1; ! lint | grep -q "differential oracle" && ok "A.6 a ### port plan with a mismatch oracle is not linted" || { bad "A.6 oracle did not silence the port lint"; lint; }
fi

if sel B; then echo "== B. clean block, no lines"
$DP --lint 3 --dry-run --via qwen --model fake/m --plan PLAN_L.md --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && ! has "ACCEPTANCE LINT" && ok "B.1 clean block: no lint line (Files entry/dir, ./ path, globs, redirections, VAR=, ::, sed, -c code, wc pipe, continuation)" \
  || { bad "B.1 clean block rc=$RC"; lint; }
$DP --lint 4 --dry-run --via qwen --model fake/m --plan PLAN_L.md --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && ! has "ACCEPTANCE LINT" && ok "B.2 no Acceptance block: no lint line" || bad "B.2 no block rc=$RC"
fi

if sel C; then echo "== C. no model call; Tests: and Cases: lint lines; a Cases: file edit blocks PASS (2026-11-15, kit-flow)"
C0=$(calls); $DP --lint 2 --via qwen --model fake/m --plan PLAN_L.md --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && [ "$(calls)" = "$C0" ] && [ "$(nlint)" = 7 ] && has 'PLAN LINT: no `Tests:` line' \
  && ok "C.1 --lint calls no model, prints its seven lines and the missing Tests: line" || { bad "C.1 rc=$RC calls $C0 -> $(calls) lines $(nlint)"; head -12 "$T/out.txt"; }
printf 'Cases: cases.md\n' > "$T/concord/repo-notes/repo.md"
( cd "$R" && printf 'case 1\n' > cases.md && git add cases.md && git commit -qm cases ) > /dev/null 2>&1
printf '# Plan\nTests: +1/-0 lines, net <= +1\n## Phase 1 - p1\nExecutor: deepseek-flash\nFiles: a.py, cases.md\nAcceptance:\n- `grep -q 2 a.py`\n## Phase 2 - p2\nExecutor: planner\nFiles: cases.md\nAcceptance:\n- `true`\n' > "$R/PLAN_C.md"
approve PLAN_C.md "$R" || exit 1
$DP --lint 1 --plan PLAN_C.md --repo "$R" > "$T/out.txt" 2>&1; $DP --lint 2 --plan PLAN_C.md --repo "$R" > "$T/out2.txt" 2>&1
has "PLAN LINT: phase 1 lists the Cases file cases.md" && ! has 'no `Tests:` line' && ! grep -q "lists the Cases file" "$T/out2.txt" \
  && ok "C.2 an executor phase listing the Cases file is linted; a planner phase may list it" || { bad "C.2"; cat "$T/out.txt" "$T/out2.txt"; }
FAKE_ACTIONS='echo "x = 2" > a.py; echo "case 2" >> cases.md' $DP 1 --plan PLAN_C.md --via qwen --model fake/m --no-baseline --repo "$R" > "$T/out.txt" 2>&1
has "REJECTED (not graded)" && grep "^REJECTED" "$T/out.txt" | grep -qF "cases.md" \
  && ok "C.3 an executor edit of the Cases file is out of its write scope: the run is rejected" || { bad "C.3"; head -4 "$T/out.txt"; }
rm -f "$T/concord/repo-notes/repo.md"
fi

if sel D; then echo "== D. planner edits its plan inside a planner run"
$DP --begin 1 --label me --plan PLAN_D.md --repo "$R" > "$T/out.txt" 2>&1; B1=$(bid)
[ -n "$B1" ] || { echo "setup failed: --begin"; cat "$T/out.txt"; exit 1; }
echo "- Handoff: edited by the planner" >> "$R/PLAN_D.md"
$DP --end "$B1" --repo "$R" > "$T/out.txt" 2>&1; RC=$?
has "plan edited during the planner run (allowed; executor runs would FAIL)" && ! has "PLAN FILE MODIFIED" && has "plan.snapshot.md" \
  && ok "D.1 planner run (--label me) report: allowed line with the snapshot path, no PLAN FILE MODIFIED" || { bad "D.1 report rc=$RC"; grep -i 'plan' "$T/out.txt" | head -3; }
[ "$(meta "$B1" plan_modified)" = True ] && ok "D.2 meta.plan_modified stays true (ledger truth)" || bad "D.2 plan_modified=$(meta "$B1" plan_modified)"
approve PLAN_D.md "$R" || exit 1      # the planner has the edited plan verified
$DP --begin 1 --label planner --plan PLAN_D.md --repo "$R" > "$T/out.txt" 2>&1; RC=$?; B2=$(bid)
[ $RC -eq 0 ] && has "plan changed since run" && ! has "still the version the executor wrote" && ok "D.3 next planner --begin accepted with the note" \
  || { bad "D.3 next begin rc=$RC"; head -3 "$T/out.txt"; }
[ -n "$B2" ] && $DP --end "$B2" --repo "$R" > /dev/null 2>&1
$DP --begin 1 --label implementer --plan PLAN_D2.md --repo "$R" > "$T/out.txt" 2>&1; B3=$(bid)
[ -n "$B3" ] || { echo "setup failed: implementer --begin"; cat "$T/out.txt"; exit 1; }
echo "- edited by the implementer" >> "$R/PLAN_D2.md"
$DP --end "$B3" --repo "$R" > "$T/out.txt" 2>&1
has "PLAN FILE MODIFIED" && ! has "plan edited during the planner run" && ok "D.4 implementer (claude) session run: PLAN FILE MODIFIED kept" || { bad "D.4 implementer report"; grep -i plan "$T/out.txt" | head -3; }
approve PLAN_D2.md "$R" || exit 1      # verified, so only the executor's edit can refuse the next --begin
$DP --begin 1 --label planner --plan PLAN_D2.md --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -ne 0 ] && has "still the version the executor wrote" && ok "D.5 --begin after an executor's plan edit refused" || { bad "D.5 rc=$RC"; head -3 "$T/out.txt"; $DP --abort last --repo "$R" > /dev/null 2>&1; }
run "echo '- edited by a harness executor' >> PLAN_D3.md" PLAN_D3.md; approve PLAN_D3.md "$R" || exit 1; $DP --begin 1 --label planner --plan PLAN_D3.md --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -ne 0 ] && has "still the version the executor wrote" && ok "D.6 --begin after a harness executor's plan edit refused" || { bad "D.6 rc=$RC"; head -3 "$T/out.txt"; $DP --abort last --repo "$R" > /dev/null 2>&1; }
fi

if sel E; then echo "== E. --review --files / --exclude / --packet"
run "echo '# r' >> a.py; echo more >> docs/x.md"; RID=$(rid)
[ -n "$RID" ] || { echo "setup failed: run"; cat "$T/out.txt"; exit 1; }
review "$RID" --files 'docs/*'; RC=$?; P="$(newest_review)/prompt.txt"
[ $RC -eq 0 ] && grep -q '^+more$' "$P" && ! grep -q '^+# r$' "$P" && ok "E.1 --files 'docs/*': prompt holds the docs diff only" || { bad "E.1 rc=$RC $P: +more $(grep -c '^+more$' "$P" 2>/dev/null), +# r $(grep -c '^+# r$' "$P" 2>/dev/null)"; tail -3 "$T/out.txt"; }
review "$RID" --files 'docs/*,a.py' --exclude 'docs/*'; RC=$?; P="$(newest_review)/prompt.txt"
[ $RC -eq 0 ] && grep -q '^+# r$' "$P" && ! grep -q '^+more$' "$P" && ok "E.2 --files 'docs/*,a.py' --exclude 'docs/*': prompt holds a.py only" || { bad "E.2 rc=$RC $P: +more $(grep -c '^+more$' "$P" 2>/dev/null), +# r $(grep -c '^+# r$' "$P" 2>/dev/null)"; tail -3 "$T/out.txt"; }
C0=$(calls); review "$RID" --files 'nothing/*' --exclude zz; RC=$?
[ $RC -eq 2 ] && [ "$(calls)" = "$C0" ] && has "no changed file matches --files nothing/* --exclude zz" && ok "E.3 no match: exit 2, message names both flags, no model call" || { bad "E.3 rc=$RC"; tail -2 "$T/out.txt"; }
$DP --review "$RID" --packet --files 'docs/*' --repo "$R" > "$T/out.txt" 2>&1; RC=$?; PK=$(sed -n 's/^PACKET //p' "$T/out.txt" | head -1)
[ $RC -eq 0 ] && [ -f "$PK" ] && grep -q '^+more$' "$PK" && ! grep -q '^+# r$' "$PK" && ok "E.4 --packet --files: packet holds the docs diff only" || { bad "E.4 packet rc=$RC"; tail -2 "$T/out.txt"; }
run "python3 -c \"open('big.py','w').write(''.join('v_%04d = %r\\\\n' % (i, 'x' * 30) for i in range(8000)))\"; echo y > docs/y.md"; BIG=$(rid)
C0=$(calls); review "$BIG"; RC=$?
[ $RC -eq 2 ] && [ "$(calls)" = "$C0" ] && has "split the change, or use --packet for an Opus reviewer" && has "--files GLOB" \
  && ok "E.5 over the cap without --files: refused (exit 2) with the file groups, no model call" || { bad "E.5 rc=$RC"; tail -3 "$T/out.txt"; }
C0=$(calls); review "$BIG" --files 'docs/*'; RC=$?
[ $RC -eq 0 ] && [ "$(calls)" = "$((C0+1))" ] && ok "E.6 over the cap with --files on the small group: reviewer runs" || { bad "E.6 rc=$RC calls $C0->$(calls)"; tail -3 "$T/out.txt"; }
fi

echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
