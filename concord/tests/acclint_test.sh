#!/bin/bash
# concord.py (PLAN_kit-lint2): ACCEPTANCE LINT lines of --lint (A-C); a planner may edit its plan inside its own
# --begin/--end run, an executor may not (D); --review/--packet scoped by --files/--exclude (E); CONTEXT LINT (F). No network.
# Run: bash ~/.claude/concord/tests/acclint_test.sh [ABCDEF]   (exit 0 = every selected check passed).
set -u
SEL="${1:-ABCDEF}"
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
run(){ FAKE_ACTIONS="$1" $DP 1 --plan "${2:-PLAN_E.md}" --via qwen --model fake/m --no-baseline --repo "$R" > "$T/out.txt" 2>&1; }
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

if sel A; then echo "== A. lint lines, dirty block"
$DP --lint 2 --dry-run --via qwen --model fake/m --plan PLAN_L.md --repo "$R" > "$T/out.txt" 2>&1; RC=$?
printf '%s\n' 'vacuous on empty input: grep -c x f | grep -qx 0' 'vacuous on empty input: grep -vc x f | grep -qx 0' \
  'string compare of wc output: test "$(wc -l < f)" = 7' 'not run (no backticks): bash tests/x.sh' \
  'names a missing file outside Files: tests/nothere.sh' 'vacuous on empty input: grep -c x concord/nothere.md | grep -qx 0' \
  'names a missing file outside Files: concord/nothere.md' > "$T/want.txt"
[ $RC -eq 0 ] && has "DRY RUN LINT" && ok "A.1 dry-run lint exits 0" || bad "A.1 dry-run lint rc=$RC"
lint > "$T/got.txt"; diff -u "$T/want.txt" "$T/got.txt" > "$T/diff.txt" && ok "A.2 seven lint lines: plan order, two rules per command, one line per missing path" \
  || { bad "A.2 lint lines differ"; cat "$T/diff.txt"; }
L1=$(last "^ACCEPTANCE LINT"); L2=$(first "^DRY RUN LINT")
[ -n "$L1" ] && [ -n "$L2" ] && [ "$L1" -lt "$L2" ] && ok "A.3 lint lines come before DRY RUN LINT" || bad "A.3 order: last lint line ${L1:-none}, DRY RUN LINT ${L2:-none}"
$DP --lint 5 --dry-run --via qwen --model fake/m --plan PLAN_L.md --repo "$R" > "$T/out.txt" 2>&1
[ "$(lint)" = "vacuous on empty input: grep -c x f | grep -qx 0" ] && ok "A.4 an inline Acceptance: command is linted" || { bad "A.4 inline Acceptance: not linted"; lint; }
fi

if sel B; then echo "== B. clean block, no lines"
$DP --lint 3 --dry-run --via qwen --model fake/m --plan PLAN_L.md --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "DRY RUN LINT" && ! has "ACCEPTANCE LINT" && ok "B.1 clean block: no lint line (Files entry/dir, ./ path, globs, redirections, VAR=, ::, sed, -c code, wc pipe, continuation)" \
  || { bad "B.1 clean block rc=$RC"; lint; }
$DP --lint 4 --dry-run --via qwen --model fake/m --plan PLAN_L.md --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "DRY RUN LINT" && ! has "ACCEPTANCE LINT" && ok "B.2 no Acceptance block: no lint line" || bad "B.2 no block rc=$RC"
fi

if sel C; then echo "== C. lint lines with a model run and without one"
FAKE_ACTIONS="echo 'QUESTIONS: none'" $DP --lint 2 --via qwen --model fake/m --plan PLAN_L.md --repo "$R" > "$T/out.txt" 2>/dev/null; RC=$?
L1=$(last "^ACCEPTANCE LINT"); L2=$(first "^LINT ")
[ $RC -eq 0 ] && [ "$(nlint)" = 7 ] && [ -n "$L1" ] && [ -n "$L2" ] && [ "$L1" -lt "$L2" ] && has "QUESTIONS: none" \
  && ok "C.1 model lint: seven lines on stdout before the model body" || { bad "C.1 model lint rc=$RC lines $(nlint) L1=${L1:-none} L2=${L2:-none}"; head -12 "$T/out.txt"; }
$DP --lint 2 claude --plan PLAN_L.md --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 3 ] && [ "$(nlint)" = 7 ] && ok "C.2 refused model (exit 3): lint lines still printed before the exit" || bad "C.2 rc=$RC lines $(nlint)"
fi

if sel D; then echo "== D. planner edits its plan inside a planner run"
$DP --begin 1 --label me --plan PLAN_D.md --repo "$R" > "$T/out.txt" 2>&1; B1=$(bid)
[ -n "$B1" ] || { echo "setup failed: --begin"; cat "$T/out.txt"; exit 1; }
echo "- Handoff: edited by the planner" >> "$R/PLAN_D.md"
$DP --end "$B1" --repo "$R" > "$T/out.txt" 2>&1; RC=$?
has "plan edited during the planner run (allowed; executor runs would FAIL)" && ! has "PLAN FILE MODIFIED" && has "plan.snapshot.md" \
  && ok "D.1 planner run (--label me) report: allowed line with the snapshot path, no PLAN FILE MODIFIED" || { bad "D.1 report rc=$RC"; grep -i 'plan' "$T/out.txt" | head -3; }
[ "$(meta "$B1" plan_modified)" = True ] && ok "D.2 meta.plan_modified stays true (ledger truth)" || bad "D.2 plan_modified=$(meta "$B1" plan_modified)"
$DP --begin 1 --label planner --plan PLAN_D.md --repo "$R" > "$T/out.txt" 2>&1; RC=$?; B2=$(bid)
[ $RC -eq 0 ] && has "plan changed since run" && ! has "still the version the executor wrote" && ok "D.3 next planner --begin accepted with the note" \
  || { bad "D.3 next begin rc=$RC"; head -3 "$T/out.txt"; }
[ -n "$B2" ] && $DP --end "$B2" --repo "$R" > /dev/null 2>&1
$DP --begin 1 --label implementer --plan PLAN_D2.md --repo "$R" > "$T/out.txt" 2>&1; B3=$(bid)
[ -n "$B3" ] || { echo "setup failed: implementer --begin"; cat "$T/out.txt"; exit 1; }
echo "- edited by the implementer" >> "$R/PLAN_D2.md"
$DP --end "$B3" --repo "$R" > "$T/out.txt" 2>&1
has "PLAN FILE MODIFIED" && ! has "plan edited during the planner run" && ok "D.4 implementer (claude) session run: PLAN FILE MODIFIED kept" || { bad "D.4 implementer report"; grep -i plan "$T/out.txt" | head -3; }
$DP --begin 1 --label planner --plan PLAN_D2.md --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -ne 0 ] && has "still the version the executor wrote" && ok "D.5 --begin after an executor's plan edit refused" || { bad "D.5 rc=$RC"; head -3 "$T/out.txt"; $DP --abort last --repo "$R" > /dev/null 2>&1; }
run "echo '- edited by a harness executor' >> PLAN_D3.md" PLAN_D3.md; $DP --begin 1 --label planner --plan PLAN_D3.md --repo "$R" > "$T/out.txt" 2>&1; RC=$?
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
run "python3 -c \"open('big.py','w').write(''.join('v_%04d = %r\\\\n' % (i, 'x' * 30) for i in range(2000)))\"; echo y > docs/y.md"; BIG=$(rid)
C0=$(calls); review "$BIG"; RC=$?
[ $RC -eq 2 ] && [ "$(calls)" = "$C0" ] && has "split the change, or use --packet for an Opus reviewer" && has "--files GLOB" \
  && ok "E.5 over the cap without --files: refusal unchanged" || { bad "E.5 rc=$RC"; tail -3 "$T/out.txt"; }
C0=$(calls); review "$BIG" --files 'docs/*'; RC=$?
[ $RC -eq 0 ] && [ "$(calls)" = "$((C0+1))" ] && ok "E.6 over the cap with --files on the small group: reviewer runs" || { bad "E.6 rc=$RC calls $C0->$(calls)"; tail -3 "$T/out.txt"; }
fi

if sel F; then echo "== F. CONTEXT LINT: a Context file without a function or line range"
cat > "$R/PLAN_C.md" <<'P'
# Plan: ctx

## Phase 1 - inline
Executor: qwen
Files: a.py
Context: a.py, docs/, tests/exists.sh:run(), conf/x.yaml:10-40, b.py: parse_args main, c.py `helper`, d.py L12-30, e.py (read-only), see the callers
Acceptance:
- `test -f a.py`

## Phase 2 - bullets
Executor: qwen
Files: a.py
Context:
- concord/concord.py:acceptance_lint()
- tests/, f.md lines 3-9
Acceptance:
- `test -f a.py`

## Phase 3 - none
Executor: qwen
Files: a.py
Acceptance:
- `test -f a.py`
P
ctx(){ sed -n 's/^CONTEXT LINT: //p' "$T/out.txt"; }
$DP --lint 1 --dry-run --via qwen --model fake/m --plan PLAN_C.md --repo "$R" > "$T/out.txt" 2>&1; RC=$?
printf '%s\n' 'no function or line range: a.py' 'no function or line range: docs/' 'no function or line range: e.py (read-only)' > "$T/want.txt"
ctx > "$T/got.txt"; [ $RC -eq 0 ] && diff -u "$T/want.txt" "$T/got.txt" > "$T/diff.txt" && ok "F.1 inline Context: bare file, directory and a note flagged; :func(), :lines, ': names', backticks, L12-30 and prose pass" || { bad "F.1 rc=$RC"; cat "$T/diff.txt"; }
L1=$(last "^CONTEXT LINT"); L2=$(first "^DRY RUN LINT")
[ -n "$L1" ] && [ -n "$L2" ] && [ "$L1" -lt "$L2" ] && ok "F.2 CONTEXT LINT comes before DRY RUN LINT" || bad "F.2 order ${L1:-none} ${L2:-none}"
$DP --lint 2 --dry-run --via qwen --model fake/m --plan PLAN_C.md --repo "$R" > "$T/out.txt" 2>&1
[ "$(ctx)" = "no function or line range: tests/" ] && ok "F.3 bullet Context: each bullet split on commas, 'lines 3-9' passes" || { bad "F.3"; ctx; }
$DP --lint 3 --dry-run --via qwen --model fake/m --plan PLAN_C.md --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "DRY RUN LINT" && ! has "CONTEXT LINT" && ok "F.4 no Context field: no line" || bad "F.4 rc=$RC"
fi

echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
