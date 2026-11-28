#!/bin/bash
# concord.py regressions for the outside review's package D (plan parsing, approval, path grammar, dispatch, executor
# environment, mutation probes): R-20 the hard-denied credential names, R-21 one fence-aware reading of phases, fields
# and acceptance commands, R-22 the plan read and the verdict file, R-23 one path grammar, R-24 OpenCode's edit rules,
# R-39 --estimate on a cycle or an unknown wait, R-45 --mutate on the graded candidate under the grading rules.
# No network: fake qwen and opencode executors.
# Run: bash ~/.claude/concord/tests/codex_D_test.sh   (exit 0 = all passed).
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/codexD-test.XXXXXX")" && pwd -P)"; export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/concord" "$T/home/.claude" "$T/tmp"
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
printf '#!/bin/sh\nsh -c "${FAKE_ACTIONS:-true}"\n' > "$T/bin/qwen"; chmod +x "$T/bin/qwen"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/opencode"; chmod +x "$T/bin/opencode"
XDEV="$(xcode-select -p 2>/dev/null)"; [ -n "$XDEV" ] && [ -x "$XDEV/usr/bin/git" ] && [ -x "$XDEV/usr/bin/python3" ] && export PATH="$XDEV/usr/bin:$PATH"
export PATH="$T/bin:$PATH" HOME="$T/home" CONCORD_NO_SANDBOX=1
DP="python3 $T/concord/concord.py"
R="$T/repo"; export R
. "$(dirname "$0")/lib.sh"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
has(){ grep -F -- "$1" "$T/out.txt" > /dev/null; }
rid(){ sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1; }
bid(){ sed -n 's/.*concord.py --end \([^ ]*\).*/\1/p' "$T/out.txt" | tail -1; }
mj(){ python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"m": m}))' "$1" "$2" 2>&1; }
# newrepo PLAN_TEXT: a fresh repository with a.py, b.py and PLAN_T.md holding PLAN_TEXT (printf format)
newrepo(){ rm -rf "$R"; mkdir -p "$R"; ( cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > a.py; printf 'y = 2\n' > b.py; printf '.claude/\n' > .gitignore; git add -A && git commit -qm init
  printf "$1" > PLAN_T.md ) || { echo "setup failed: newrepo"; exit 1; }; }
dry(){ $DP "${@:2}" 1 --plan PLAN_T.md --dry-run --repo "$R" --via "$1" --model fake/m > "$T/out.txt" 2>&1; }
run(){ FAKE_ACTIONS="$1" $DP 1 --plan PLAN_T.md --via qwen --model fake/m --no-baseline --repo "$R" > "$T/out.txt" 2>&1; }
acc(){ sed -n 's/^acceptance: //p' "$T/out.txt"; }

echo "== R-20 hard-denied credential names stay out of an executor's environment"
newrepo '# Plan\n## Phase 1 - a\nFiles: a.py\nAcceptance:\n- `grep -q y a.py`\n'
printf 'qwen.env = ANTHROPIC_* CLAUDE_CODE_OAUTH_TOKEN CLAUDECODE ZZ_KEEP\n' >> "$T/concord/executors.conf"
ANTHROPIC_API_KEY=zz CLAUDE_CODE_OAUTH_TOKEN=zz CLAUDECODE=1 ZZ_KEEP=1 dry qwen
N=$(sed -n 's/^environment names passed to the executor: //p' "$T/out.txt")
case " ${N//,/ } " in *" ZZ_KEEP "*) case "$N" in *ANTHROPIC*|*CLAUDE*) bad "an allow-list entry forwarded an Anthropic or Claude name: $N";;
  *) ok "an executors.conf allow-list entry cannot forward ANTHROPIC_*, CLAUDE_* or CLAUDECODE; other listed names pass";; esac;;
  *) bad "the listed name ZZ_KEEP did not pass: $N";; esac
cp -p "$SRC/executors.conf" "$T/concord/executors.conf"; fake_env

echo "== R-21 one fence-aware reading of phases, fields and acceptance commands"
newrepo '# Plan\n## Design\nA phase looks like this:\n```markdown\n## Phase 1 - example\nAcceptance:\n- `false`\n```\n## Phase 1 - real\nFiles: a.py\nAcceptance:\n- `true`\n'
dry qwen
[ "$(acc)" = "['true']" ] && ok "a phase heading inside a code fence is no phase: the real Phase 1 and its command are read" \
  || bad "fenced example phase heading: acceptance $(acc)"
newrepo '# Plan\n## Phase 1 - real\nFiles: a.py\nSteps:\n1. Add:\n```python\n# helper\ndef f(): pass\n```\nAcceptance:\n- `grep -q y a.py`\n'
dry qwen
[ "$(acc)" = "['grep -q y a.py']" ] && ok "a # line inside a code fence ends neither the phase nor a field: the Acceptance after it is read" \
  || bad "fenced # line: acceptance $(acc)"
newrepo '# Plan\n## Phase 1 - real\nFiles: a.py\nNotes:\n```text\nAcceptance: `false`\n```\nAcceptance:\n- `true`\n'
dry qwen
[ "$(acc)" = "['true']" ] && ok "a field line inside a code fence is no field: the real Acceptance is read" || bad "fenced field line: acceptance $(acc)"
newrepo '# Plan\n## Phase 1 - real\nFiles: a.py\nAcceptance:\n- `true`\n  It needs `PYTHONPATH=src` set.\n- `grep -q x a.py` (fails until `parse()` exists)\n'
dry qwen
[ "$(acc)" = "['true', 'grep -q x a.py']" ] && ok "inline code on a continuation line or in a parenthesised note is prose, not a command" \
  || bad "prose spans: acceptance $(acc)"
$DP --lint 1 --plan PLAN_T.md --repo "$R" > "$T/out.txt" 2>&1
grep -q '^ACCEPTANCE LINT: not run.*PYTHONPATH=src' "$T/out.txt" && grep -q '^ACCEPTANCE LINT: not run.*parse()' "$T/out.txt" \
  && ok "--lint names each span that does not run (a continuation line, a parenthesised note)" \
  || { bad "lint of prose spans"; grep LINT "$T/out.txt"; }
newrepo '# Plan\n## Phase 1 - real\nFiles: a.py\nAcceptance:\n- `true` (characterization: like `make check`)\n'
$DP --lint 1 --plan PLAN_T.md --repo "$R" > "$T/out.txt" 2>&1
! has "characterization without the marker" && ok "a (characterization: ...) note holding inline code still marks its command" \
  || { bad "marker with inline code in the note"; grep LINT "$T/out.txt"; }
newrepo '# Plan\n## Phase 1 - a\nFiles: a.py\nAcceptance:\n- `true`\nAcceptance:\n- `false`\n## Phase 2 - b\nFiles: b.py\nAcceptance:\n- `true`\n## Phase 2 - b again\nFiles: b.py\nAcceptance:\n- `true`\n'
$DP --lint 1 --plan PLAN_T.md --repo "$R" > "$T/out.txt" 2>&1
grep -q '^PLAN LINT: .*phase 2.*2 ' "$T/out.txt" && grep -q '^PLAN LINT: .*phase 1.*Acceptance' "$T/out.txt" \
  && ok "--lint reports a duplicate phase and a duplicate field" || { bad "duplicates not linted"; grep LINT "$T/out.txt"; }

echo "== R-22 the plan read and the verdict file"
newrepo '# Plan\n## Phase 1 - a\nFiles: a.py\nAcceptance:\n- `grep -q y a.py`\n'
approve PLAN_T.md "$R" || exit 1; HV=$(vhash "$R/PLAN_T.md"); PR="$R/.git/concord/plan-reads/$HV.md"
I1=$(ls -i "$PR" | awk '{print $1}'); $DP --lint 1 --plan PLAN_T.md --repo "$R" > /dev/null 2>&1; I2=$(ls -i "$PR" | awk '{print $1}')
[ -n "$I1" ] && [ "$I1" != "$I2" ] && ok "--lint replaces the plan read whole (a new file renamed over it), never rewrites it in place" \
  || bad "plan read rewritten in place (inode $I1 -> $I2)"
rm -f "$PR"; $DP --begin 1 --label implementer --plan PLAN_T.md --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 11 ] && has "$HV" && ok "an approved revision whose plan read is gone opens nothing (--begin exit 11, naming the read)" \
  || { bad "missing plan read: --begin rc=$RC"; tail -2 "$T/out.txt"; [ $RC -eq 0 ] && $DP --abort last --repo "$R" > /dev/null 2>&1; }
newrepo '# Plan\n## Phase 1 - a\nFiles: a.py\nAcceptance:\n- `grep -q y a.py`\n'
approve PLAN_T.md "$R" || exit 1; HV=$(vhash "$R/PLAN_T.md")
printf '## Phase 3 - unapproved\nFiles: b.py\nAcceptance:\n- `true`\n' >> "$R/PLAN_T.md"; rm -f "$R/.git/concord/plan-reads/$HV.md"
$DP --phases --plan PLAN_T.md --repo "$R" > "$T/out.txt" 2>&1
! has "phase 3" && ok "a revision whose plan read is gone never takes the unapproved text on disk (--phases lists no phase 3)" \
  || { bad "--phases read the unapproved text"; cat "$T/out.txt"; }
newrepo '# Plan\n## Phase 1 - a\nFiles: a.py\nAcceptance:\n- `grep -q y a.py`\n'
$DP --lint 1 --plan PLAN_T.md --repo "$R" > /dev/null 2>&1; HV=$(vhash "$R/PLAN_T.md")
printf 'VERDICT: APPROVE\nPLAN-HASH: %s\nquoted from an earlier answer:\nVERDICT: REVISE\n' "$HV" > "$T/v.txt"
$DP --plan-verdict "$T/v.txt" --plan PLAN_T.md --repo "$R" > "$T/out.txt" 2>&1; R1=$?
printf 'VERDICT: APPROVE\nPLAN-HASH: %s\nPLAN-HASH: 0123456789abcdef\n' "$HV" > "$T/v.txt"
$DP --plan-verdict "$T/v.txt" --plan PLAN_T.md --repo "$R" > "$T/out.txt" 2>&1; R2=$?
$DP --begin 1 --label implementer --plan PLAN_T.md --repo "$R" > "$T/out.txt" 2>&1; R3=$?
[ $R1 -eq 2 ] && [ $R2 -eq 2 ] && [ $R3 -eq 11 ] && ok "a verdict file with two VERDICT lines or two PLAN-HASH lines records nothing (exit 2; --begin exit 11)" \
  || { bad "verdict file lines: rc $R1 $R2, then --begin $R3"; [ $R3 -eq 0 ] && $DP --abort last --repo "$R" > /dev/null 2>&1; }

echo "== R-23 one path grammar"
newrepo '# Plan\n## Phase 1 - a\nFiles: `folder with spaces/a.py`\nAcceptance:\n- `true`\n'
dry qwen
has "files in scope: ['folder with spaces/a.py']" && ok "a backticked path with spaces is one path" || bad "spaced path: $(grep '^files in scope' "$T/out.txt")"
newrepo '# Plan\n## Phase 1 - a\nFiles: a/*.py\nAcceptance:\n- `grep -q y a/sub/b.py`\n'
mkdir -p "$R/a/sub" && printf 'b = 1\n' > "$R/a/sub/b.py" && git -C "$R" add -A && git -C "$R" commit -qm sub
approve PLAN_T.md "$R" || exit 1
run 'echo y >> a/sub/b.py'; RUN="$R/.git/concord/$(rid)"
$DP --restore "$(rid)" --repo "$R" > "$T/rs.txt" 2>&1
! grep -q '^REJECTED' "$T/out.txt" && [ "$(mj "$RUN/meta.json" 'm.get("backed_up")')" = "['a/sub/b.py']" ] && [ "$(cat "$R/a/sub/b.py")" = "b = 1" ] \
  && ok "a file that Files: a/*.py scopes (a/sub/b.py) is backed up and --restore puts it back" \
  || { bad "a/*.py backup: backed_up $(mj "$RUN/meta.json" 'm.get("backed_up")')"; cat "$T/rs.txt"; }
newrepo '# Plan\n## Test plan\n| Behavior | Existing tests | Action | Home |\n|---|---|---|---|\n| t | none | ADD | tests/test_a.py |\n\n## Phase 1 - a\nExecutor: planner\nFiles: tests/*.txt\nAcceptance:\n- `true`\n'
mkdir -p "$R/tests" && printf 'pass\n' > "$R/tests/test_a.py" && git -C "$R" add -A && git -C "$R" commit -qm t
approve PLAN_T.md "$R" || exit 1
$DP --begin 1 --label planner --plan PLAN_T.md --no-baseline --repo "$R" > "$T/out.txt" 2>&1; B=$(bid)
echo 'assert True' >> "$R/tests/test_a.py"; $DP --end "$B" --repo "$R" > "$T/out.txt" 2>&1
[ -n "$B" ] && ! grep -q '^REJECTED' "$T/out.txt" && [ "$(mj "$R/.git/concord/$B/meta.json" 'm.get("grading_files")')" = "['tests/test_a.py']" ] \
  && ok "a Test plan Home outside Files: tests/*.txt stays a grading file (membership, not lock overlap), so the planner may write it" \
  || { bad "grading file dropped by overlap"; grep -E '^(REJECTED|OUT OF)' "$T/out.txt"; }
newrepo '# Plan\nTests: +1/-0 lines\n## Phase 1 - a\nExecutor: deepseek-flash\nFiles: a.py, my cases.md\nAcceptance:\n- `true`\n'
printf 'Cases: `my cases.md`\n' > "$T/concord/repo-notes/repo.md"
$DP --lint 1 --plan PLAN_T.md --repo "$R" > "$T/out.txt" 2>&1
has "PLAN LINT: phase 1 lists the Cases file my cases.md" && ok "a backticked Cases: path with a space is one path" || { bad "Cases with a space"; grep LINT "$T/out.txt"; }
rm -f "$T/concord/repo-notes/repo.md"

echo "== R-24 OpenCode's edit rules follow the write policy"
perm(){ sed -n 's/^opencode permission: //p' "$T/out.txt" | python3 -I -c "import json,sys; e=json.load(sys.stdin)['permission'].get('edit'); print(eval(sys.argv[1], {'e': e}))" "$1" 2>&1; }
newrepo '# Plan\n## Phase 1 - a\nAcceptance:\n- `true`\n'
dry opencode
[ "$(perm 'isinstance(e, dict) and e.get("*") == "deny" and set(e.values()) == {"deny"}')" = "True" ] \
  && ok "a phase with no Files: denies every edit explicitly" || bad "empty scope edit rule: $(perm 'e')"
newrepo '# Plan\n## Test plan\n| Behavior | Existing tests | Action | Home |\n|---|---|---|---|\n| t | none | ADD | tests/test_a.py |\n\n## Phase 1 - a\nFiles: a.py, newdir/\nFollow-through: *.md, tests/**\nAcceptance:\n- `true`\n'
dry opencode
[ "$(perm '(e.get("PLAN_T.md"), e.get("tests/test_a.py"), list(e)[-1] in ("PLAN_T.md", "tests/test_a.py") or str(list(e)[-1]).endswith(("PLAN_T.md", "tests/test_a.py")))')" = "('deny', 'deny', True)" ] \
  && ok "the plan and the grading files are denied after the allowed patterns that cover them" || bad "plan/grader edit rules: $(perm 'e')"
[ "$(perm '"newdir/*" in e and e["newdir/*"] == "allow"')" = "True" ] && ok "a declared directory that does not exist yet gets its child pattern" \
  || bad "declared directory children: $(perm 'e')"

echo "== R-39 --estimate reports a cycle and a wait on no phase"
newrepo '# Plan\nTier: S\n## Phase 1 - a\nExecutor: deepseek-flash\nSize: ~100 lines\nAfter: 2 (needs b)\nFiles: a.py\nAcceptance:\n- `true`\n## Phase 2 - b\nExecutor: deepseek-flash\nSize: ~100 lines\nAfter: 1 (needs a), 7 (needs g)\nFiles: b.py\nAcceptance:\n- `true`\n'
$DP --estimate --plan PLAN_T.md --repo "$R" > "$T/out.txt" 2>&1
grep -q '^ESTIMATE LINT: .*cycle' "$T/out.txt" && grep -q '^ESTIMATE LINT: .*Phase 7' "$T/out.txt" \
  && ok "--estimate names an After: cycle and a wait on a phase the plan does not have" || { bad "estimate lint"; grep LINT "$T/out.txt"; }

echo "== R-45 --mutate grades the recorded candidate under the grading rules"
newrepo '# Plan\n## Phase 1 - a\nExecutor: deepseek-flash\nFiles: lib.py\nAcceptance:\n- `python3 -c "import lib; assert lib.f(1) == 2"`\n'
approve PLAN_T.md "$R" || exit 1
run 'printf "def f(x):\n    return x + 1\n" > lib.py'; MR=$(rid)
printf 'raise SystemExit(3)\n' > "$R/lib.py"
TMPDIR="$T/tmp" $DP --mutate "$MR" --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "MUTATION $MR:" && [ "$(cat "$R/lib.py")" = "raise SystemExit(3)" ] && [ -z "$(ls -A "$T/tmp" | grep -v '^xcrun_db')" ] \
  && ok "the mutants come from the graded candidate, not from the checkout's later edit; the live file is untouched" \
  || { bad "mutate after a later edit rc=$RC"; head -4 "$T/out.txt"; }
newrepo '# Plan\n## Phase 1 - a\nExecutor: deepseek-flash\nFiles: lib.py\nAcceptance:\n- `python3 -c "import lib; assert lib.f(1) == 99"` (fails until Phase 2)\n'
approve PLAN_T.md "$R" || exit 1
run 'printf "def f(x):\n    return x + 1\n" > lib.py'; MR=$(rid)
TMPDIR="$T/tmp" $DP --mutate "$MR" --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "MUTATION $MR:" && ! has "unmutated copy" && ok "an expected-red command that fails on the candidate is its expected result, not a setup failure" \
  || { bad "expected-red setup rc=$RC"; head -4 "$T/out.txt"; }
newrepo '# Plan\n## Phase 1 - a\nExecutor: deepseek-flash\nFiles: lib.py\nAcceptance:\n- `python3 -c "import lib, sys; sys.exit(0 if lib.f(1) == 2 else 127)"`\n- `python3 -c "import lib, os, signal; lib.f(2) == 3 or os.kill(os.getpid(), signal.SIGTERM)"`\n'
approve PLAN_T.md "$R" || exit 1
run 'printf "def f(x):\n    return x + 1\n" > lib.py'; MR=$(rid)
TMPDIR="$T/tmp" $DP --mutate "$MR" --repo "$R" > "$T/out.txt" 2>&1; RC=$?
G=$(mj "$R/.git/concord/$MR/meta.json" '(m["mutation"]["killed"], m["mutation"].get("invalid", 0) == len(m["mutation"]["sampled"]) > 0)')
[ $RC -eq 0 ] && [ "$G" = "(0, True)" ] && ok "a mutant whose check exits 127 or ends by a signal is invalid, not killed" \
  || { bad "tool error or signal counted: rc=$RC (killed, all invalid) = $G"; head -4 "$T/out.txt"; }

echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
