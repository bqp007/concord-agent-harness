#!/bin/bash
# concord.py test-quality regression (2026-10-19, PLAN_kit-testquality; --mutate reworked 2026-10-23, kit-lean):
# per-command red run (an acceptance command that already passes before an implementing change must be marked
# "(characterization)" or the executor is not started), the (characterization) marker, and --mutate (opt-in,
# seeded, bounded mutation testing of a run's own changed lines in an isolated copy of the checkout; each mutant
# stops at its first failing non-characterization acceptance command). No network, fake qwen executor.
# Run: bash ~/.claude/concord/tests/testquality_test.sh
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/tq-test.XXXXXX")" && pwd -P)"; export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/concord" "$T/home/.claude"
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
printf '#!/bin/sh\nsh -c "${FAKE_ACTIONS:-true}"\n' > "$T/bin/qwen"; chmod +x "$T/bin/qwen"
# The /usr/bin git and python3 are xcrun shims; inside the macOS sandbox xcrun cannot write its cache and prints
# "couldn't create cache file" on stderr, which pollutes captured output. Prefer the developer dir's real binaries.
XDEV="$(xcode-select -p 2>/dev/null)"; [ -n "$XDEV" ] && [ -x "$XDEV/usr/bin/git" ] && [ -x "$XDEV/usr/bin/python3" ] && export PATH="$XDEV/usr/bin:$PATH"
export PATH="$T/bin:$PATH" HOME="$T/home"
DP="python3 $T/concord/concord.py"
R="$T/repo"; export R
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
has(){ grep -F -- "$1" "$T/out.txt" > /dev/null; }
rid(){ sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1; }
mj(){ python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"m": m}))' "$1" "$2" 2>&1; }
# newrepo PLAN_BODY: a.py, tests/test_a.py (passes) and a plan whose phase 1 text is PLAN_BODY (printf format)
newrepo(){ rm -rf "$R"; mkdir -p "$R/tests"; (
  cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > a.py; printf 'assert True\n' > tests/test_a.py; printf '.claude/\n' > .gitignore
  git add -A && git commit -qm init
  printf "# Plan\n## Phase 1 - change a\nExecutor: deepseek-flash\n$1" > PLAN_T.md
); }
run(){ FAKE_ACTIONS="$1" $DP 1 --plan PLAN_T.md --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1; }
BASE='Files: a.py\nAcceptance:\n- `grep -q y a.py`\n- `python3 tests/test_a.py`%s\n'
sha(){ shasum -a 256 "$1" | cut -d" " -f1; }
mut(){ sed -n "s/^MUTATION .*$1 \([0-9]*\).*/\1/p" "$T/out.txt"; }

echo "== per-command red run"
newrepo "$(printf "$BASE" "")"
run 'echo y >> a.py; touch ran.txt'; RC=$?
[ $RC -eq 6 ] && [ ! -e "$R/ran.txt" ] && has "NOT RUN" && has "python3 tests/test_a.py" && ! has "grep -q y a.py." \
  && ok "one acceptance command already green and unmarked -> exit 6, executor never started, the command named" \
  || { bad "partial green rc=$RC"; tail -4 "$T/out.txt"; }
RD=$(ls -d "$R"/.git/concord/*-p1 2>/dev/null | tail -1)
[ -n "$RD" ] && grep -q "NOT RUN" "$RD/report.md" 2>/dev/null && ok "refused run keeps a report.md (not an open session run)" || bad "no report.md in refused run dir '$RD'"
newrepo "$(printf "$BASE" " (characterization)")"
run 'echo y >> a.py'; RC=$?
[ $RC -eq 0 ] && has "changed in scope: a.py" && ! has "NOT RUN" && ! has "forced: acceptance" \
  && ok "the green command marked (characterization) -> the run proceeds" || { bad "marked rc=$RC"; tail -4 "$T/out.txt"; }
newrepo "$(printf "$BASE" " (Characterization)")"
run 'echo y >> a.py'; RC=$?
[ $RC -eq 0 ] && has "changed in scope: a.py" && ok "marker is case-insensitive" || bad "marker case rc=$RC"
newrepo "$(printf "$BASE" "")"
FAKE_ACTIONS='echo y >> a.py' $DP 1 --plan PLAN_T.md --via qwen --model fake/m --force --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "forced: acceptance already green before the change" && has "python3 tests/test_a.py" \
  && ok "--force runs anyway and the report notes the green command" || { bad "force rc=$RC"; grep -i "forced\|note" "$T/out.txt" | head -3; }
newrepo 'Files: a.py\nAcceptance:\n- `grep -q y a.py`\n- `python3 tests/test_b.py` (characterization)\n'
run 'echo y >> a.py'; RC=$?
[ $RC -eq 0 ] && has "characterization command failed before the change: python3 tests/test_b.py" \
  && ok "a marked command that fails before the change -> run proceeds with a note" || { bad "marked-red rc=$RC"; grep -i "characterization" "$T/out.txt" | head -3; }
newrepo 'Files: a.py\nAcceptance:\n- `python3 tests/test_a.py` (characterization)\n- `test -f a.py` (characterization)\n'
run 'echo y >> a.py'; RC=$?
[ $RC -eq 0 ] && ! has "TEST_DEFECT" && has "marked (characterization)" && ok "all acceptance commands green and marked: no TEST_DEFECT warning in the report" || { bad "all-marked rc=$RC"; grep -i baseline "$T/out.txt" | head -2; }
newrepo 'Files: a.py\nBaseline: pass\nAcceptance:\n- `python3 tests/test_a.py`\n- `test -f a.py`\n'
run 'echo y >> a.py'; RC=$?
[ $RC -eq 0 ] && ! has "NOT RUN" && ok "Baseline: pass with all-green acceptance is unchanged (runs)" || { bad "baseline pass rc=$RC"; tail -3 "$T/out.txt"; }
newrepo "$(printf "$BASE" "")"
$DP --begin 1 --label planner --plan PLAN_T.md --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && ! has "NOT RUN" && has "baseline:" && ok "--begin (session run) with a green command: warning only, not refused" || { bad "begin rc=$RC"; tail -3 "$T/out.txt"; }
BID=$(sed -n 's/.*concord.py --end \([^ ]*\).*/\1/p' "$T/out.txt" | tail -1); echo y >> "$R/a.py"; $DP --end "$BID" --repo "$R" > /dev/null 2>&1

echo "== the (characterization) marker"
python3 -I - "$T/concord/concord.py" <<'EOF'
import importlib.util, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("d", sys.argv[1]); d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
p = []
text = "## Phase 1 - x\nFiles: a.py\nAcceptance: `true` (characterization)\n- `python3 -m pytest tests/t.py::k`\n- `ls` (Characterization) note\nInputs:\n- n: `int` in `[0, 9]`; `None` -> ValueError\n"
try:
    if d.parse_acceptance(text) != ["true", "python3 -m pytest tests/t.py::k", "ls"]:
        p.append(f"parse_acceptance swallows the backticks of a later field: {d.parse_acceptance(text)}")
    got = d.parse_acceptance_marked(text)
    if got != [("true", True), ("python3 -m pytest tests/t.py::k", False), ("ls", True)]:
        p.append(f"parse_acceptance_marked: {got}")
    bare = d.parse_acceptance_marked("Acceptance:\n- `pytest` # not a characterization, a real test\n- `ls` (characterization) ok\n")
    if bare != [("pytest", False), ("ls", True)]:
        p.append(f"bare word 'characterization' must not mark: {bare}")
except AttributeError as exc:
    p.append(f"missing: {exc}")
print("  ok   parse_acceptance_marked reads the (characterization) marker inline and in the body; a later field ends Acceptance"
      if not p else "  FAIL fields: " + "; ".join(p))
sys.exit(1 if p else 0)
EOF
[ $? -eq 0 ] && pass=$((pass+1)) || fail=$((fail+1))

echo "== mutation candidates (unit)"
python3 -I - "$T/concord/concord.py" <<'EOF'
import importlib.util, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("d", sys.argv[1]); d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
p = []
src = "def clamp(x, strict=True):\n    if x < 0 and strict:\n        return 0\n    y = x + 1\n    return not y\n"
try:
    c = d.mutation_candidates(src, [(1, 5)])
    ops = sorted({(x["line"], x["operator"]) for x in c})
    for want in ((2, "compare"), (2, "boolop"), (2, "negate-if"), (3, "const"), (3, "return-none"), (4, "arith"), (4, "const"), (5, "not"), (5, "return-none")):
        if want not in ops:
            p.append(f"missing candidate {want}")
    if any(x["operator"] == "const" and x["line"] == 1 for x in c) or any(x["operator"] == "boolconst" and x["line"] != 1 for x in c):
        p.append("True handled as a number or boolconst on the wrong line")
    if not any(x["operator"] == "boolconst" and x["line"] == 1 for x in c):
        p.append("no boolconst candidate for the default True")
    cmp = next(x for x in c if x["operator"] == "compare" and x["line"] == 2)
    if "<=" not in cmp["mutated"] or "<=" not in cmp["source"] or cmp["source"].count("\n") != src.count("\n"):
        p.append(f"compare mutant: {cmp['mutated']!r}")
    for x in c:
        compile(x["source"], "m", "exec")
    if c != d.mutation_candidates(src, [(1, 5)]):
        p.append("not deterministic")
    if [x["line"] for x in c] != sorted(x["line"] for x in c):
        p.append("not sorted by line")
    if d.mutation_candidates(src, [(4, 4)]) and {x["line"] for x in d.mutation_candidates(src, [(4, 4)])} != {4}:
        p.append("range not respected")
    if d.mutation_candidates("def f(:\n", [(1, 1)]) != []:
        p.append("syntax error not skipped")
    nonascii = 'msg = "Đã chặn"; ok = n > 0\n'
    cm = [x for x in d.mutation_candidates(nonascii, [(1, 1)]) if x["operator"] == "compare"]
    if not cm or 'ok = n >= 0' not in cm[0]["source"] or '"Đã chặn"' not in cm[0]["source"]:
        p.append(f"non-ASCII before the node: {[x['source'] for x in cm]!r}")
    nt = [x for x in d.mutation_candidates("r = not (a or b) and c\n", [(1, 1)]) if x["operator"] == "not"]
    if not nt or "r = (a or b) and c" not in nt[0]["source"]:
        p.append(f"not without parentheses: {[x['source'] for x in nt]!r}")
except AttributeError as exc:
    p.append(f"missing: {exc}")
except SyntaxError as exc:
    p.append(f"mutant does not compile: {exc}")
print("  ok   mutation_candidates: every operator, True/False never numeric, compiling mutants, sorted, deterministic, range-bound"
      if not p else "  FAIL candidates: " + "; ".join(p))
sys.exit(1 if p else 0)
EOF
[ $? -eq 0 ] && pass=$((pass+1)) || fail=$((fail+1))

echo "== --mutate on a run"
newrepo 'Files: lib.py\nAcceptance:\n- `python3 -c "import lib; assert lib.clamp(5) == 5"`\n'
run 'printf "def clamp(x):\n    if x < 0:\n        return 0\n    return x\n" > lib.py'; RID=$(rid)
H0=$(sha "$R/lib.py")
$DP --mutate "$RID" --seed 0 --max 20 --repo "$R" > "$T/out.txt" 2>&1; RC=$?
K=$(mut killed); SV=$(mut survived)
[ $RC -eq 0 ] && has "MUTATION $RID:" && has "seed 0" && [ "${K:-0}" -ge 1 ] && [ "${SV:-0}" -ge 1 ] && grep -q "^SURVIVED lib.py:L2: compare: " "$T/out.txt" \
  && ok "mutants sampled and run: some killed, the untested boundary survives (SURVIVED lib.py:L2: compare)" || { bad "mutate rc=$RC"; head -8 "$T/out.txt"; }
case "$(head -1 "$T/out.txt")" in "note: mutating an isolated copy of the checkout ("*) ok "first output line names the isolated copy";;
  *) bad "first line: $(head -1 "$T/out.txt")";; esac
WK=$(sed -n '1s/^note: mutating an isolated copy of the checkout (\(.*\)); the live files are not touched$/\1/p' "$T/out.txt")
[ "$(sha "$R/lib.py")" = "$H0" ] && [ ! -e "$R/.git/concord/$RID/mutation-backup" ] && [ -n "$WK" ] && [ ! -e "$WK" ] \
  && ok "the live lib.py is never written, no mutation-backup/, the copy is removed afterwards" || bad "live file or copy: $WK"
[ "$(mj "$R/.git/concord/$RID/meta.json" '(m["mutation"]["seed"], m["mutation"]["mode"], m["mutation"]["killed"] >= 1, m["mutation"]["survived"] >= 1, len(m["mutation"]["sampled"]) == m["mutation"]["killed"] + m["mutation"]["survived"])')" = "(0, 'isolated', True, True, True)" ] \
  && ok "meta.mutation recorded" || bad "mutation meta: $(mj "$R/.git/concord/$RID/meta.json" 'm.get("mutation")')"
mj "$R/.git/concord/$RID/meta.json" '[(x["line"], x["operator"], x["result"]) for x in m["mutation"]["sampled"]]' > "$T/m1.txt"
$DP --mutate last --seed 0 --max 20 --repo "$R" > "$T/out.txt" 2>&1; RC=$?
mj "$R/.git/concord/$RID/meta.json" '[(x["line"], x["operator"], x["result"]) for x in m["mutation"]["sampled"]]' > "$T/m2.txt"
[ $RC -eq 0 ] && [ -s "$T/m1.txt" ] && cmp -s "$T/m1.txt" "$T/m2.txt" && ok "--mutate last: same seed -> identical sample and results" || bad "determinism rc=$RC"
$DP --mutate "$RID" --seed 0 --max 2 --repo "$R" > "$T/out.txt" 2>&1
has "2 mutants (sampled from" && ok "--max bounds the sample" || { bad "max"; head -2 "$T/out.txt"; }
$DP --mutate "$RID" --max 0 --repo "$R" > "$T/out.txt" 2>&1; R1=$?
$DP --mutate "$RID" --max -1 --repo "$R" > "$T/out.txt" 2>&1; R2=$?
[ "$R1$R2" = "22" ] && ! has Traceback && [ "$(sha "$R/lib.py")" = "$H0" ] && ok "--max below 1: exit 2, nothing touched" || bad "max<1 exits $R1 $R2"
$DP --mutate "$RID/../x" --repo "$R" > "$T/out.txt" 2>&1; [ $? -eq 2 ] && ok "a RUN with a path separator is refused" || bad "path run id accepted"
printf '# edited after the run\n' >> "$R/lib.py"; H0=$(sha "$R/lib.py")
$DP --mutate "$RID" --max 2 --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && [ "$(sha "$R/lib.py")" = "$H0" ] && ok "an edit after the run: --mutate runs and the live file keeps the edit" || { bad "rerun after edit rc=$RC"; head -3 "$T/out.txt"; }
cp "$R/.git/concord/$RID/meta.json" "$T/meta.keep"; printf '{"run_id": ' > "$R/.git/concord/$RID/meta.json"
$DP --mutate "$RID" --repo "$R" > "$T/out.txt" 2>&1; RC=$?; cp "$T/meta.keep" "$R/.git/concord/$RID/meta.json"
[ $RC -eq 2 ] && has "not valid JSON" && ok "truncated meta.json: exit 2, no traceback" || { bad "bad meta rc=$RC"; head -2 "$T/out.txt"; }

echo "== --mutate: the run's own lines, first failing check, characterization excluded"
newrepo 'Files: lib.py\nAcceptance:\n- `python3 -c "import lib; assert lib.mid(5)"`\n'
printf 'def lo(x):\n    return x < 0\n' > "$R/lib.py"; git -C "$R" add lib.py; git -C "$R" commit -qm lib
printf 'def pre(x):\n    return x > 9\n' >> "$R/lib.py"            # uncommitted, made before the run: not the run's
run 'printf "def mid(x):\n    return x == 5\n" >> lib.py'; RID=$(rid)
$DP --mutate "$RID" --max 50 --repo "$R" > "$T/out.txt" 2>&1; RC=$?
L=$(mj "$R/.git/concord/$RID/meta.json" 'sorted({x["line"] for x in m["mutation"]["sampled"]})')
[ $RC -eq 0 ] && [ "$L" = "[6]" ] && ok "only the run's own mid() (line 6) is mutated, not the earlier uncommitted pre() (line 4)" \
  || { bad "own lines rc=$RC lines=$L"; head -3 "$T/out.txt"; }
newrepo 'Files: lib.py\nAcceptance:\n- `python3 -c "import lib; assert lib.clamp(5) == 5"`\n- `python3 -c "import lib" && echo graded >> "$T/glog"`\n- `echo char >> "$T/clog"` (characterization)\n'
run 'printf "def clamp(x):\n    if x < 0:\n        return 0\n    return x\n" > lib.py'; RID=$(rid)
rm -f "$T/glog"; C0=$(wc -l < "$T/clog" | tr -d ' ')
$DP --mutate "$RID" --seed 0 --repo "$R" > "$T/out.txt" 2>&1; RC=$?
K=$(mut killed); SV=$(mut survived); G=$(cat "$T/glog" 2> /dev/null | wc -l | tr -d ' ')
[ $RC -eq 0 ] && [ "${K:-0}" -ge 1 ] && [ "$G" -eq $(( ${SV:-0} + 1 )) ] \
  && ok "each mutant stops at its first failing command: the second ran only on the unmutated copy and the $SV survivor(s)" \
  || { bad "early stop rc=$RC killed=$K survived=$SV graded=$G"; head -3 "$T/out.txt"; }
[ "$(wc -l < "$T/clog" | tr -d ' ')" = "$C0" ] && ok "a (characterization) command never grades a mutant" || bad "characterization command ran"
newrepo 'Files: a.py, b.py\nAcceptance:\n- `shasum -a 256 a.py b.py >> "$T/mlog"`\n- `python3 -c "import a, b; assert a.f(1) == 2 and b.g(1) == 3"`\n'
run 'printf "def f(x):\n    return x + 1\n" > a.py; printf "def g(x):\n    return x + 2\n" > b.py'; RID=$(rid)
HA=$(sha "$R/a.py"); HB=$(sha "$R/b.py"); rm -f "$T/mlog"
$DP --mutate "$RID" --max 8 --repo "$R" > "$T/out.txt" 2>&1; RC=$?
python3 -I - "$T/mlog" "$HA" "$HB" <<'PYM'
import sys
rows = [l.split() for l in open(sys.argv[1]) if l.strip()]
pairs = list(zip(rows[0::2], rows[1::2]))
both = sum(1 for a, b in pairs if a[0] != sys.argv[2] and b[0] != sys.argv[3])
sys.exit(0 if len(pairs) > 1 and both == 0 else 1)
PYM
[ $? -eq 0 ] && [ $RC -eq 0 ] && ok "two changed files: never more than one mutant in the copy at a time" || { bad "stacked mutants rc=$RC"; head -4 "$T/mlog" 2>/dev/null; }
newrepo 'Files: lib.py\nAcceptance:\n- `python3 -c "import time, lib; time.sleep(4); assert lib.clamp(5) == 5"`\n'
run 'printf "def clamp(x):\n    if x < 0:\n        return 0\n    return x\n" > lib.py'; RID=$(rid); H0=$(sha "$R/lib.py")
$DP --mutate "$RID" --max 2 --repo "$R" > "$T/out.txt" 2>&1 & MP=$!
sleep 1.5; kill -TERM $MP 2>/dev/null; wait $MP; RC=$?
[ "$(sha "$R/lib.py")" = "$H0" ] && [ $RC -eq 130 ] && has "interrupted; the isolated copy was removed" \
  && ok "SIGTERM during grading: exit 130, live file untouched" || { bad "sigterm rc=$RC"; cat "$T/out.txt"; }
newrepo 'Files: notes.txt\nAcceptance:\n- `test -f notes.txt`\n'
run 'echo hi > notes.txt'; RID=$(rid)
$DP --mutate "$RID" --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "no mutable Python lines in the change" && ok "non-Python change: nothing to mutate, exit 0" || { bad "no-python rc=$RC"; head -2 "$T/out.txt"; }
newrepo 'Files: tests/test_z.py\nAcceptance:\n- `python3 tests/test_z.py`\n'
run 'printf "x = 1\nassert x < 2\n" > tests/test_z.py'; RID=$(rid)
$DP --mutate "$RID" --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "no mutable Python lines" && ok "test files are never mutated" || { bad "tests mutated rc=$RC"; head -2 "$T/out.txt"; }
newrepo 'Files: lib.py\n'
FAKE_ACTIONS='printf "def f(x):\n    return x + 1\n" > lib.py' $DP 1 --plan PLAN_T.md --via qwen --model fake/m --no-baseline --repo "$R" > "$T/out.txt" 2>&1; RID=$(rid)
$DP --mutate "$RID" --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 2 ] && ! has "unrecognized arguments" && ok "run without acceptance commands: exit 2" || { bad "no-acceptance rc=$RC"; head -2 "$T/out.txt"; }

echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
