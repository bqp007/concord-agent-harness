#!/bin/bash
# concord.py fixes for C++ phases (2026-10-22, PLAN_kit-cpptools; issues found on a C++ ticket): the acceptance-file
# snapshot skips command words, git-ignored paths and CMake build trees and never derives "added" files from a capped
# list, so a clean C++ run takes --verdict PASS without --force (1, 1c); --restore leaves restored sources newer than
# the build (2); --mutate runs C/C++ and listed mutants in an isolated copy (3; 3b: NUL strings, over-long path parts
# and C/C++ files in build trees, found by the third P3 review, and a generated isolated run with no candidate, found
# by the P3.1 mutation probe); the (characterization) marker variants (4); --repo takes a directory (8); the field
# heading "Inputs and failure classes:" (9); the lint of git inside $( ) (10); a Files: glob on Python 3.9 (11, found
# while planning). Sections 1c, 2 and 3 build a small CMake project (SKIP without cmake, ctest, c++).
# Sections 5-7 (--stats, --map, --close-round) went with those commands in the lean revision (2026-10-23, kit-lean).
# No network: fake qwen executor and reviewer.
# Run: bash ~/.claude/concord/tests/cpptools_test.sh [SECTION ...]   (default all; exit 0 = every selected check passed)
set -u
SEL=" ${*:-all} "
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/cpptools-test.XXXXXX")" && pwd -P)"; export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/concord" "$T/home/.claude" "$T/tmp"
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
cat > "$T/bin/qwen" <<'Q'
#!/bin/sh
if [ -n "${FAKE_ACTIONS:-}" ]; then sh -c "$FAKE_ACTIONS"; exit 0; fi
printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n'
Q
chmod +x "$T/bin/qwen"
# Prefer the developer dir's real git/python3 over the /usr/bin xcrun shims (they print cache errors in the sandbox).
XDEV="$(xcode-select -p 2>/dev/null)"; [ -n "$XDEV" ] && [ -x "$XDEV/usr/bin/git" ] && [ -x "$XDEV/usr/bin/python3" ] && export PATH="$XDEV/usr/bin:$PATH"
export PATH="$T/bin:$PATH" HOME="$T/home"
DP="python3 $T/concord/concord.py"
R="$T/repo"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
has(){ grep -F -- "$1" "$T/out.txt" > /dev/null; }
sel(){ case "$SEL" in *" all "*|*" $1 "*) return 0;; esac; return 1; }
rid(){ sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1; }
bid(){ sed -n 's/.*concord.py --end \([^ ]*\).*/\1/p' "$T/out.txt" | tail -1; }
mj(){ python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"m": m}))' "$1" "$2" 2>&1; }
lint(){ sed -n 's/^ACCEPTANCE LINT: //p' "$T/out.txt"; }
sha(){ shasum -a 256 "$1" | cut -d' ' -f1; }
mtime(){ python3 -I -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$1"; }
counted(){ [ "$1" -eq 0 ] && pass=$((pass+1)) || fail=$((fail+1)); }
gitrepo(){ mkdir -p "$1" && ( cd "$1" && git init -q -b main && git config user.email t@t && git config user.name t ); }
# newrepo PLAN_BODY: a.py, tests/test_a.py (passes) and PLAN_T.md whose phase 1 text is PLAN_BODY (printf format)
newrepo(){ rm -rf "$R"; gitrepo "$R"; ( cd "$R" && mkdir -p tests
  printf 'x = 1\n' > a.py; printf 'assert True\n' > tests/test_a.py; printf '.claude/\n' > .gitignore
  git add -A && git commit -qm init
  printf "# Plan\n## Phase 1 - change a\nExecutor: deepseek-flash\n$1" > PLAN_T.md ); }
run(){ FAKE_ACTIONS="$1" $DP 1 --plan PLAN_T.md --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1; }
# mut FILE [ARGS]: --mutate run $MR with the mutants listed in FILE; the isolated copy goes under $T/tmp
mut(){ TMPDIR="$T/tmp" $DP --mutate "$MR" --mutants "$1" "${@:2}" --repo "$R" > "$T/out.txt" 2>&1; }
# PLAN_L.md: phases for --lint with a Claude executor (dry runs: no model call)
lintplan(){ cat > "$R/PLAN_L.md" <<'P'
# Plan
## Phase 1 - git inside a command substitution
Executor: concord:implementer-opus48
Risk: medium
Files: a.py
Acceptance:
- `test -z "$(git diff --name-only HEAD -- include)"`
- `git diff --quiet HEAD -- include`
## Phase 2 - characterization markers
Executor: concord:implementer-opus48
Risk: medium
Files: a.py
Acceptance:
- `python3 tests/test_a.py` characterization of the old output
- `true` (characterization: the P4 list)
- `ls`
  (characterization)
P
}

if sel 1; then
echo "== 1 acceptance files: command words, git-ignored paths and CMake build trees are not acceptance files"
A="$T/af"; gitrepo "$A"; ( cd "$A" && mkdir -p cmake tests data build out2
  printf 'set(X 1)\n' > cmake/a.cmake; printf 'exit 0\n' > cmake/x.sh; printf 'exit 0\n' > tests/run.sh; printf 'd\n' > data/d.txt
  printf 'build/\nign.txt\n.claude/\n' > .gitignore; git add -A && git commit -qm init
  : > build/CMakeCache.txt; echo g > build/gen.txt; : > out2/CMakeCache.txt; echo o > out2/o.txt; echo i > ign.txt )
python3 -I - "$T/concord/concord.py" "$A" <<'EOF'
import importlib.util, sys
from pathlib import Path
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("d", sys.argv[1]); d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
repo = Path(sys.argv[2])
cases = [
    ("cmake -S . -B build -DBUILD_TESTING=ON > /dev/null && cmake --build build -j6 && ctest --test-dir build -R '^(a_test|b_test)$'", []),
    ("bash tests/run.sh", ["tests/run.sh"]),
    ("cmake/x.sh --flag", ["cmake/x.sh"]),
    ("FOO=1 cmake --version; echo $(cmake --version) | cmake -E echo x", []),
    ("true && tests", []),
    ("ls out2 && cat ign.txt && cat build/gen.txt", []),
    ("ls data", ["data/d.txt"]),
]
p = []
for cmd, want in cases:
    got = d.acceptance_files(repo, [cmd], [])
    if got != want:
        p.append(f"{cmd!r}: {got[:6]} (want {want})")
print("  ok   acceptance files skip the command word of each simple command, git-ignored paths and directories holding "
      "CMakeCache.txt; arguments and command words with a / still count" if not p else "  FAIL acceptance files: " + "; ".join(p))
sys.exit(1 if p else 0)
EOF
counted $?

echo "== 1 acceptance files keep the files a command names: after a closing ), as NAME=value values, beside an in-source CMakeCache.txt, in another case, next to a non-UTF-8 name"
A2="$T/af2"; gitrepo "$A2"; ( cd "$A2" && mkdir -p tests
  printf 'g\n' > golden.txt; printf 'e\n' > expected.txt; printf 'o\n' > out.txt; printf 'x\n' > x; printf 'c\n' > tests/conf.ini
  printf 't\n' > tests/t.py; printf 'true\n' > run.sh; git add -A && git commit -qm init
  git update-index --add --cacheinfo 100644 "$(printf 'x\n' | git hash-object -w --stdin)" "$(printf 'tests/bad\377.txt')"
  : > CMakeCache.txt; mkdir -p tests/__pycache__ && printf 'c\n' > tests/__pycache__/t.cpython-39.pyc )
python3 -I - "$T/concord/concord.py" "$A2" <<'EOF'
import importlib.util, sys
from pathlib import Path
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("d", sys.argv[1]); d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
repo = Path(sys.argv[2])
folded = (repo / "Tests/t.py").exists()      # a case-insensitive filesystem (macOS default)
cases = [
    ("diff <( sort out.txt ) golden.txt", ["golden.txt", "out.txt"]),
    ("echo $( cat x ) expected.txt", ["expected.txt", "x"]),
    ("echo $(./run.sh)", ["run.sh"]),
    ("CONF=tests/conf.ini bash run.sh", ["run.sh", "tests/conf.ini"]),
    ("GOLDEN=golden.txt make check", ["golden.txt"]),
    ("python3 -m pytest tests/t.py golden.txt", ["golden.txt", "tests/t.py"]),
    ("python3 -m pytest Tests/t.py", ["tests/t.py"] if folded else []),
    ("ls Tests", ["tests/conf.ini", "tests/t.py"] if folded else []),
    ("python3 -m pytest tests", ["tests/conf.ini", "tests/t.py"]),
]
p = []
for cmd, want in cases:
    try:
        got = d.acceptance_files(repo, [cmd], [])
    except Exception as exc:  # a non-UTF-8 name in the index must not raise
        got = f"{type(exc).__name__}: {exc}"
    if got != want:
        p.append(f"{cmd!r}: {got if isinstance(got, str) else got[:6]} (want {want})")
print("  ok   acceptance files keep named files after a closing ), as NAME=value values, beside an untracked root "
      "CMakeCache.txt (in-source build), in git's spelling when the command uses another case, and next to a non-UTF-8 "
      "name in the index" if not p else "  FAIL acceptance files keep named files: " + "; ".join(p))
sys.exit(1 if p else 0)
EOF
counted $?

echo "== 1 a build tree whose CMakeCache.txt is git-ignored by name (GitHub's CMake.gitignore), not the tree, is still a build tree"
A3="$T/af3"; gitrepo "$A3"; ( cd "$A3" && mkdir -p cmake tests
  printf 'CMakeCache.txt\nCMakeFiles\nMakefile\ncmake_install.cmake\nCTestTestfile.cmake\nTesting\n' > .gitignore
  printf 'm\n' > cmake/m.cmake; printf 't\n' > tests/a_test.cc; git add -A && git commit -qm init
  mkdir -p build/sub && for f in CMakeCache.txt Makefile a_test build.ninja sub/b_test; do printf 'x\n' > "build/$f"; done )
python3 -I - "$T/concord/concord.py" "$A3" <<'EOF'
import importlib.util, sys
from pathlib import Path
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("d", sys.argv[1]); d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
repo = Path(sys.argv[2])
cases = [
    ("cmake -S . -B build && cmake --build build && ctest --test-dir build -R '^a_test$'", []),
    ("./build/a_test", []),
    ("ls build", []),
    ("ls build/sub", []),
    ("cat tests/a_test.cc", ["tests/a_test.cc"]),
]
p = []
for cmd, want in cases:
    got = d.acceptance_files(repo, [cmd], [])
    if got != want:
        p.append(f"{cmd!r}: {got[:6]} (want {want})")
print("  ok   acceptance files skip a build tree found on disk by its CMakeCache.txt when only the cache and the "
      "Makefiles are git-ignored, not the tree" if not p else "  FAIL acceptance files with a name-ignored CMakeCache.txt: "
      + "; ".join(p))
sys.exit(1 if p else 0)
EOF
counted $?

echo "== 1 capped acceptance list: no 'added' file derived from a recomputed list; the dropped files are named"
newrepo 'Files: a.py\nAcceptance:\n- `ls data > /dev/null && grep -q y a.py`\n'
( cd "$R" && mkdir data && for i in $(seq -w 0 599); do echo "$i" > "data/f$i.txt"; done && git add data && git commit -qm data )
run 'rm data/f000.txt; echo y >> a.py'
grep -F "ACCEPTANCE FILES CHANGED:" "$T/out.txt" | grep -qF "data/f000.txt (removed)" && ! has "data/f500.txt (added)" \
  && has "not hashed: data/f500.txt" && has "files added under acceptance directories are not checked" \
  && ok "capped list: the removed file is reported, the file at the cap boundary is not called added, the dropped files are named" \
  || { bad "capped list"; grep -e ACCEPT -e capped "$T/out.txt" | cut -c1-300; }
fi

if sel 4; then
echo "== 4 the (characterization) marker: a qualifier inside the parentheses, the wrapped next line, a lint near miss"
python3 -I - "$T/concord/concord.py" <<'EOF'
import importlib.util, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("d", sys.argv[1]); d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
p = []
got = d.parse_acceptance_marked("Acceptance:\n- `true` (characterization: the P4 list)\n- `ls`\n  (characterization)\n"
                                "- `pwd` characterization of x\n- `id` (Characterization)\n")
if got != [("true", True), ("ls", True), ("pwd", False), ("id", True)]:
    p.append(f"variants: {got}")
got = d.parse_acceptance_marked("Acceptance:\n- `a`\n- (characterization) `b`\n- `c` (characterizations)\n")
if got != [("a", False), ("b", False), ("c", False)]:
    p.append(f"a marker before a command or on the next bullet, or another word, must not mark: {got}")
print("  ok   parse_acceptance_marked: (characterization...) after the command or on its wrapped next line; nothing else marks"
      if not p else "  FAIL marker: " + "; ".join(p))
sys.exit(1 if p else 0)
EOF
counted $?
newrepo 'Files: a.py\nAcceptance:\n- `grep -q y a.py`\n- `python3 tests/test_a.py` (characterization: kept as is)\n'
run 'echo y >> a.py'; RC=$?
[ $RC -eq 0 ] && has "changed in scope: a.py" && ! has "NOT RUN" && ok "a green command marked (characterization: why) -> the run proceeds" \
  || { bad "qualified marker rc=$RC"; tail -3 "$T/out.txt"; }
newrepo 'Files: a.py\nAcceptance:\n- `grep -q y a.py`\n- `python3 tests/test_a.py`\n  (characterization)\n'
run 'echo y >> a.py'; RC=$?
[ $RC -eq 0 ] && has "changed in scope: a.py" && ! has "NOT RUN" && ok "the marker on the wrapped next line of the bullet -> the run proceeds" \
  || { bad "wrapped marker rc=$RC"; tail -3 "$T/out.txt"; }
newrepo ''; lintplan
$DP --lint 2 --plan PLAN_L.md --dry-run --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1; RC=$?
N=$(lint | grep -ci characterization); L=$(lint | grep -i characterization)
[ $RC -eq 0 ] && [ "$N" = 1 ] && case "$L" in *"python3 tests/test_a.py"*"(characterization)"*|*"(characterization)"*"python3 tests/test_a.py"*) true;; *) false;; esac \
  && ok "--lint: one ACCEPTANCE LINT line for the word characterization without a marker, none for the marked variants" \
  || { bad "near-miss lint rc=$RC n=$N"; lint; }
fi

if sel 8; then
echo "== 8 --repo takes a directory"
( cd "$T" && $DP --show last --repo no-such-checkout ) > "$T/out2.txt" 2>&1; RC2=$?
( cd "$T" && $DP --show last --repo "$(python3 -I -c 'print("a" * 300)')" ) > "$T/out3.txt" 2>&1; RC3=$?
( cd "$T" && $DP --lint 1 --plan PLAN_T.md --dry-run --repo no-such-checkout ) > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 2 ] && [ $RC2 -eq 2 ] && [ $RC3 -eq 2 ] && has "--repo takes a directory" && grep -qF -- "--repo takes a directory" "$T/out2.txt" \
  && grep -qF -- "--repo takes a directory" "$T/out3.txt" && ! has "Traceback" && ! grep -q Traceback "$T/out3.txt" \
  && ok "--repo with a name that is not a directory or is too long to look up: exit 2 saying --repo takes a directory" \
  || { bad "--repo name rc=$RC/$RC2/$RC3"; tail -2 "$T/out.txt" "$T/out3.txt"; }
fi

if sel 9; then
echo "== 9 'Inputs and failure classes:' is the Inputs field"
python3 -I - "$T/concord/concord.py" <<'EOF'
import importlib.util, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("d", sys.argv[1]); d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
p = []
got = d.field_block("## Phase 1 - x\nInputs and failure classes:\n- n: int in [0, 9]\nAcceptance:\n- `true`\n", "Inputs")
if got != ("", ["- n: int in [0, 9]"]):
    p.append(f"qualified Inputs heading: {got}")
if d.field_block("Inputs:\n- x\n", "Inputs") != ("", ["- x"]):
    p.append("plain Inputs: broken")
got = d.field_block("Steps:\n- a\n- Files of note: x\n- b\n", "Steps")
if got != ("", ["- a", "- Files of note: x", "- b"]):
    p.append(f"a qualifier after another field name must not start that field: {got}")
print("  ok   field_block reads 'Inputs <qualifier>:' as Inputs; other field names take no qualifier"
      if not p else "  FAIL Inputs field: " + "; ".join(p))
sys.exit(1 if p else 0)
EOF
counted $?
fi

if sel 10; then
echo "== 10 --lint: git inside \$( ) gets the git diff --quiet form"
newrepo ''; lintplan
$DP --lint 1 --plan PLAN_L.md --dry-run --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1; RC=$?
N=$(lint | grep -cF 'git diff --quiet HEAD --'); L=$(lint | grep -F 'git diff --quiet HEAD --')
[ $RC -eq 0 ] && [ "$N" = 1 ] && case "$L" in *'test -z "$(git diff'*) true;; *) false;; esac \
  && ok "one ACCEPTANCE LINT line for test -z \"\$(git diff ...)\", suggesting git diff --quiet HEAD --; none for that form itself" \
  || { bad "git lint rc=$RC n=$N"; lint; }
# the form passes before any change, so the template's example must carry the marker (else a copied phase gets exit 6)
L=$(grep -F 'git diff --quiet HEAD --' "$SRC/PLAN_TEMPLATE.md")
[ -n "$L" ] && case "$L" in *'(characterization'*) true;; *) false;; esac \
  && ok "PLAN_TEMPLATE.md shows the git diff --quiet HEAD -- form with the (characterization) marker" \
  || bad "template lacks the git diff --quiet form with the (characterization) marker: $L"
fi

if sel 11; then
echo "== 11 a Files: glob works on the oldest supported Python ($(python3 -c 'import sys; print(sys.version.split()[0])'))"
newrepo 'Files: a*.py\nAcceptance:\n- `grep -q y a.py`\n'
run 'echo y >> a.py'; RC=$?; RUN="$R/.git/concord/$(rid)"
[ $RC -eq 0 ] && has "changed in scope: a.py" && ! has "Traceback" && [ "$(mj "$RUN/meta.json" 'm.get("backed_up")')" = "['a.py']" ] \
  && ok "Files: a*.py backs up and scopes a.py, no traceback" \
  || { bad "Files glob rc=$RC backed_up=$(mj "$RUN/meta.json" 'm.get("backed_up")' | tail -1)"; tail -3 "$T/out.txt"; }
fi

if sel 3; then
echo "== 3 --mutants and the isolated copy without cmake: bytes, occurrences, paths, in-source builds, meta, timing, operators"
newrepo 'Files: a.py\nAcceptance:\n- `grep -q y a.py`\n'
( cd "$R" && printf 'const char *s = "caf\351"; int k=1;\n' > s.c && printf 'f(1, 1, 1, 1);\n' > f.c && git add s.c f.c \
  && git commit -qm src && mkdir -p .claude && printf 'int v = 1;\n' > .claude/x.c )
run 'echo y >> a.py'; MR=$(rid); MRUN="$R/.git/concord/$MR"
[ -n "$MR" ] && [ -f "$MRUN/meta.json" ] || { echo "setup failed: no run for the --mutants checks"; tail -5 "$T/out.txt"; exit 1; }
cat > "$T/stamp.py" <<'P'
import sys, time
with open(sys.argv[1], "a") as fh:
    fh.write(f"{sys.argv[2]} {time.time():.3f}\n")
P
cat > "$T/touchmeta.py" <<'P'
import json, sys
m = json.load(open(sys.argv[1])); m["probe_verdict"] = "PASS"; m.setdefault("reviews", []).append({"reviewer": "probe"})
open(sys.argv[1], "w").write(json.dumps(m))
P

python3 -I -c 'import sys; d = open(sys.argv[1], "rb").read(); open(sys.argv[2], "wb").write(d.replace(b"k=1", b"k=2"))' "$R/s.c" "$T/s_want.c"
printf 'f(1, 1, 9, 9);\n' > "$T/f_want.c"
cat > "$T/m_bytes.json" <<J
[{"id": "B1", "file": "s.c", "old": "k=1", "new": "k=2", "check": "! cmp -s s.c '$T/s_want.c'", "what": "only the old text changes"},
 {"id": "O2", "file": "f.c", "old": "1, 1", "new": "9, 9", "occ": 2, "check": "! cmp -s f.c '$T/f_want.c'", "what": "the 2nd of 2 occurrences"}]
J
mut "$T/m_bytes.json"; RC=$?
GOT=$(mj "$MRUN/meta.json" '[s["result"] for s in m["mutation"]["sampled"]]')
[ $RC -eq 0 ] && has "killed 2, survived 0" && [ -z "$(ls -A "$T/tmp")" ] && [ "$GOT" = "['killed', 'killed']" ] \
  && ok "3 a listed mutant changes only its old text (a non-UTF-8 byte elsewhere is kept) and occ counts non-overlapping occurrences; meta records each as killed" \
  || { bad "3 listed bytes/occ rc=$RC results=$GOT"; head -6 "$T/out.txt"; }

cat > "$T/m_timeout.json" <<'J'
[{"id": "X1", "file": "f.c", "old": "f(", "new": "g(", "check": "if grep -q 'g(' f.c; then exit 124; fi"}]
J
mut "$T/m_timeout.json"; RC=$?
GOT=$(mj "$MRUN/meta.json" '[s["result"] for s in m["mutation"]["sampled"]]')
[ $RC -eq 0 ] && has "killed 1, survived 0" && [ "$GOT" = "['timeout']" ] \
  && ok "3 a mutant whose every failing check exits 124 (the timeout code) counts as killed and meta records it as timeout" \
  || { bad "3 timeout result rc=$RC results=$GOT"; head -4 "$T/out.txt"; }

mkdir -p "$T/outside" && printf 'int v = 1;\n' > "$T/outside/x.c" && ln -s "$T/outside" "$R/vendor"
printf '[{"id": "L1", "file": "vendor/x.c", "old": "v = 1", "new": "v = 2"}]' > "$T/m_link.json"
mut "$T/m_link.json"; RC=$?
[ $RC -eq 2 ] && grep -qx 'int v = 1;' "$T/outside/x.c" && [ -z "$(ls -A "$T/tmp")" ] && ! has Traceback \
  && ! has "unrecognized arguments" && ok "3 a listed file whose path resolves outside the checkout (a symlinked directory): exit 2 before any copy, the target untouched" \
  || { bad "3 symlinked path rc=$RC"; head -4 "$T/out.txt"; }
rm -f "$R/vendor"

mkdir -p "$R/bld" && : > "$R/bld/CMakeCache.txt" && printf 'int v = 1;\n' > "$R/bld/gen.c"
printf '[{"id": "C1", "file": ".claude/x.c", "old": "v = 1", "new": "v = 2"}]' > "$T/m_claude.json"
printf '[{"id": "C2", "file": "bld/gen.c", "old": "v = 1", "new": "v = 2"}]' > "$T/m_bld.json"
mut "$T/m_claude.json"; R1=$?; T1=$(grep -c -e Traceback -e "unrecognized arguments" "$T/out.txt")
mut "$T/m_bld.json"; R2=$?; T2=$(grep -c -e Traceback -e "unrecognized arguments" "$T/out.txt")
[ $R1 -eq 2 ] && [ $R2 -eq 2 ] && [ "$T1$T2" = 00 ] && [ -z "$(ls -A "$T/tmp")" ] \
  && ok "3 a listed file the copy leaves out (.claude, a directory holding CMakeCache.txt): exit 2 before any copy" \
  || bad "3 left-out paths rc=$R1/$R2 tracebacks=$T1$T2"
rm -rf "$R/bld"

python3 -I -c 'print("[" * 100000 + "]" * 100000)' > "$T/m_deep.json"
printf '[{"id": "O0", "file": "f.c", "old": "f(", "new": "g(", "occ": 0}]' > "$T/m_occ0.json"
mut "$T/m_deep.json"; R1=$?; T1=$(grep -c -e Traceback -e "unrecognized arguments" "$T/out.txt")
mut "$T/m_occ0.json"; R2=$?; T2=$(grep -c -e Traceback -e "unrecognized arguments" "$T/out.txt")
[ $R1 -eq 2 ] && [ $R2 -eq 2 ] && [ "$T1$T2" = 00 ] && ok "3 a --mutants file nested too deep to parse, or a mutant with occ 0: exit 2, no traceback" \
  || { bad "3 deep JSON / occ 0 rc=$R1/$R2 tracebacks=$T1$T2"; tail -2 "$T/out.txt"; }

: > "$R/CMakeCache.txt"
printf '[{"id": "I1", "file": "f.c", "old": "f(", "new": "g("}]' > "$T/m_in.json"
mut "$T/m_in.json"; RC=$?
[ $RC -eq 2 ] && has "in-source CMake build" && [ -z "$(ls -A "$T/tmp")" ] \
  && ok "3 an in-source CMake build (CMakeCache.txt at the repository root): exit 2 before any copy, named in the message" \
  || { bad "3 in-source build rc=$RC"; head -4 "$T/out.txt"; }
rm -f "$R/CMakeCache.txt"

cat > "$T/m_meta.json" <<J
[{"id": "V1", "file": "f.c", "old": "f(", "new": "g(", "check": "python3 -I '$T/touchmeta.py' '$MRUN/meta.json'"}]
J
mut "$T/m_meta.json"; RC=$?
[ $RC -eq 0 ] && [ "$(mj "$MRUN/meta.json" '(m.get("probe_verdict"), len(m.get("reviews") or []) > 0, m["mutation"]["mode"])')" = "('PASS', True, 'isolated')" ] \
  && ok "3 meta.json keeps what other commands recorded during an isolated --mutate (a verdict, a review) and gains mutation" \
  || { bad "3 meta merge rc=$RC: $(mj "$MRUN/meta.json" 'sorted(m)')"; head -4 "$T/out.txt"; }

: > "$T/ev.txt"
cat > "$T/m_wait.json" <<J
[{"id": "W1", "file": "f.c", "old": "f(", "new": "g(", "check": "python3 -I '$T/stamp.py' '$T/ev.txt' C"},
 {"id": "W2", "file": "f.c", "old": "1);", "new": "2);", "check": "python3 -I '$T/stamp.py' '$T/ev.txt' C"},
 {"id": "W3", "file": "s.c", "old": "k=1", "new": "k=3", "check": "python3 -I '$T/stamp.py' '$T/ev.txt' C"}]
J
mut "$T/m_wait.json" --build "python3 -I '$T/stamp.py' '$T/ev.txt' B"; RC=$?
python3 -I - "$T/ev.txt" <<'EOF'
import sys
ev = [line.split() for line in open(sys.argv[1]) if line.strip()]
kinds = "".join(e[0] for e in ev)
late = [f"{ev[i - 1]} -> {ev[i]}" for i in range(1, len(ev)) if ev[i][0] == "B" and int(float(ev[i][1])) <= int(float(ev[i - 1][1]))]
sys.exit(0 if kinds == "BCBCBCBC" and not late else (print(f"    events {kinds}; same-second builds: {late}") or 1))
EOF
[ $? -eq 0 ] && [ $RC -eq 0 ] && has "MUTATION $MR: 3 mutants (listed in" \
  && ok "3 each mutant's build starts in a later wall-clock second than the last command in the copy ended (make compares mtimes to the second)" \
  || { bad "3 build timing rc=$RC"; head -3 "$T/out.txt"; }

# a concurrent record_verdict()/record_review() truncates meta.json, then writes it (write_text): a read in between
# sees an empty file. The writer below keeps it empty for 1.5 s; --mutate must not replace meta.json with only its key.
cat > "$T/tornmeta.py" <<'P'
import json, sys, time
p = sys.argv[1]
m = json.load(open(p)); m["probe_torn"] = "kept"
open(p, "w").close()
open(sys.argv[3], "w").close()            # tell the check the file is empty now
time.sleep(float(sys.argv[2]))
with open(p, "w") as fh:
    fh.write(json.dumps(m))
P
cat > "$T/m_torn.json" <<J
[{"id": "T1", "file": "f.c", "old": "f(", "new": "g(", "check": "if grep -q 'g(' f.c; then python3 -I '$T/tornmeta.py' '$MRUN/meta.json' 1.5 '$T/torn.ready' > /dev/null 2>&1 & i=0; while [ ! -f '$T/torn.ready' ] && [ \$i -lt 200 ]; do sleep 0.05; i=\$((i+1)); done; fi"}]
J
# drop the mutation key the checks above recorded, so only this --mutate can supply it
python3 -I -c 'import json, sys; m = json.load(open(sys.argv[1])); m.pop("mutation", None); open(sys.argv[1], "w").write(json.dumps(m))' "$MRUN/meta.json"
rm -f "$T/torn.ready"; mut "$T/m_torn.json"; RC=$?; sleep 2
[ $RC -eq 0 ] && [ "$(mj "$MRUN/meta.json" '(m.get("probe_torn"), "acceptance" in m, (m.get("mutation") or {}).get("mode"))')" = "('kept', True, 'isolated')" ] \
  && ok "3 meta.json read while another command rewrites it (empty for a moment): --mutate waits for it and keeps what that command wrote" \
  || { bad "3 torn meta rc=$RC: $(mj "$MRUN/meta.json" 'sorted(m)')"; head -4 "$T/out.txt"; }

printf '[{"id": "C3", "file": ".Claude/x.c", "old": "v = 1", "new": "v = 2"}]' > "$T/m_case.json"
mut "$T/m_case.json"; RC=$?
[ $RC -eq 2 ] && ! has Traceback && ! has "unrecognized arguments" && [ -z "$(ls -A "$T/tmp")" ] \
  && ok "3 a listed file under a case variant of .claude (.Claude/x.c on a case-insensitive filesystem): exit 2 before any copy" \
  || { bad "3 case-variant left-out path rc=$RC"; head -4 "$T/out.txt"; }

printf '[{"id": "N1", "file": "f\\u0000.c", "old": "f(", "new": "g("}]' > "$T/m_nul.json"
printf '[{"id": "N2", "file": "f.c", "old": "\\ud800", "new": "x"}]' > "$T/m_sur.json"
mut "$T/m_nul.json"; R1=$?; T1=$(grep -c -e Traceback -e "unrecognized arguments" "$T/out.txt")
mut "$T/m_sur.json"; R2=$?; T2=$(grep -c -e Traceback -e "unrecognized arguments" "$T/out.txt")
[ $R1 -eq 2 ] && [ $R2 -eq 2 ] && [ "$T1$T2" = 00 ] && [ -z "$(ls -A "$T/tmp")" ] \
  && ok "3 a --mutants string that cannot name a file or be encoded (a NUL in file, a lone surrogate in old): exit 2 before any copy" \
  || bad "3 NUL/surrogate rc=$R1/$R2 tracebacks=$T1$T2"

mkfifo "$R/pipe"
printf '[{"id": "P1", "file": "f.c", "old": "f(", "new": "g("}]' > "$T/m_pipe.json"
mut "$T/m_pipe.json"; RC=$?
[ $RC -eq 2 ] && ! has Traceback && ! has "unrecognized arguments" && [ -z "$(ls -A "$T/tmp")" ] \
  && ok "3 a checkout file the copy cannot copy (a named pipe): exit 2 with a message, no traceback, no copy left" \
  || { bad "3 uncopyable file rc=$RC"; tail -3 "$T/out.txt"; }
rm -f "$R/pipe"

python3 -I - "$T/concord/concord.py" <<'EOF'
import importlib.util, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("d", sys.argv[1]); d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
def ops(src):
    return [(c["operator"], c["source"]) for c in d.c_mutation_candidates(src, [(1, 1)])]
p = []
got = ops("  total += x;  // accumulate")
if ("delete", "") not in got:
    p.append(f"a statement with a trailing // comment gets no delete candidate: {got}")
got = ops("  int y = f(a,  // first arg;")
if any(op == "delete" for op, _ in got):
    p.append(f"a line whose comment (not its code) ends with ; gets a delete candidate: {got}")
got = ops("  x = f(a) + g(b, c);")
if ("drop-arg", "  x = f(a) + g(b);") not in got:
    p.append(f"drop-arg stops at a one-argument call: {got}")
got = ops("  r = f(g(a, b));")
if ("drop-arg", "  r = f(g(a));") not in got:
    p.append(f"drop-arg stops at the outer one-argument call: {got}")
got = ops("  y = h(f(a), b);")
if ("drop-arg", "  y = h(f(a));") not in got:
    p.append(f"drop-arg miscounts the top-level commas after a nested call: {got}")
got = ops("&& ready)")
if ("boolop", "|| ready)") not in got:
    p.append(f"a && at the very start of the line gets no boolop candidate: {got}")
print("  ok   3 operators: delete reads the code part before //; drop-arg passes over calls with fewer than two arguments"
      " and counts commas after a nested call; a && at column 0 is swapped"
      if not p else "  FAIL 3 operators: " + "; ".join(p))
sys.exit(1 if p else 0)
EOF
counted $?
fi

if sel 3b; then
echo "== 3b --mutate: a NUL in any --mutants string, a path part too long to look up, a C/C++ file inside a build tree the copy leaves out, nothing to mutate"
newrepo 'Files: a.py\nAcceptance:\n- `grep -q y a.py`\n'
( cd "$R" && printf 'f(1, 1, 1, 1);\n' > f.c && git add f.c && git commit -qm src )
run 'echo y >> a.py'; MR=$(rid)
[ -n "$MR" ] && [ -f "$R/.git/concord/$MR/meta.json" ] || { echo "setup failed: no run for the 3b checks"; tail -5 "$T/out.txt"; exit 1; }

printf '[{"id": "Q1", "file": "f.c", "old": "f(", "new": "g(", "check": "true\\u0000x"}]' > "$T/m_nulcheck.json"
printf '[{"id": "Q2", "file": "f.c", "old": "f(\\u0000", "new": "g("}]' > "$T/m_nulold.json"
mut "$T/m_nulcheck.json"; R1=$?; T1=$(grep -c -e Traceback -e "unrecognized arguments" -e "isolated copy" "$T/out.txt")
mut "$T/m_nulold.json"; R2=$?; T2=$(grep -c -e Traceback -e "unrecognized arguments" -e "isolated copy" "$T/out.txt")
[ $R1 -eq 2 ] && [ $R2 -eq 2 ] && [ "$T1$T2" = 00 ] && [ -z "$(ls -A "$T/tmp")" ] \
  && ok "3b a NUL in any --mutants string (check, old), not only in file: exit 2 before any copy, no traceback" \
  || { bad "3b NUL in check/old rc=$R1/$R2 traceback-or-copy=$T1$T2"; tail -2 "$T/out.txt"; }

L=$(python3 -I -c 'print("a" * 300)')
printf '[{"id": "Q3", "file": "%s/x.c", "old": "f(", "new": "g("}]' "$L" > "$T/m_longdir.json"
printf '[{"id": "Q4", "file": "%s.c", "old": "f(", "new": "g("}]' "$L" > "$T/m_longfile.json"
mut "$T/m_longdir.json"; R1=$?; T1=$(grep -c -e Traceback -e "unrecognized arguments" "$T/out.txt"); H1=$(grep -c "file not found in the checkout" "$T/out.txt")
mut "$T/m_longfile.json"; R2=$?; T2=$(grep -c -e Traceback -e "unrecognized arguments" "$T/out.txt"); H2=$(grep -c "file not found in the checkout" "$T/out.txt")
[ $R1 -eq 2 ] && [ $R2 -eq 2 ] && [ "$T1$T2" = 00 ] && [ "$H1$H2" = 11 ] && [ -z "$(ls -A "$T/tmp")" ] \
  && ok "3b a listed path with a part longer than the filesystem allows (a directory part, the file name): a missing file, exit 2, no traceback" \
  || { bad "3b over-long path part rc=$R1/$R2 tracebacks=$T1$T2 not-found=$H1$H2"; tail -2 "$T/out.txt"; }

# generated mode: the run adds a line to f.c (2 candidates: drop-arg, delete; the hunks' context lines are comments,
# so a.py and f.c add none) and creates a C file in a build tree
newrepo 'Files: a.py, f.c\nAcceptance:\n- `grep -q y a.py`\n'
( cd "$R" && printf '// f\n' > f.c && printf '# a\n' > a.py && git add -A && git commit -qm src )
run 'echo y >> a.py; printf "int t = f(1, 2);\n" >> f.c; mkdir -p bld && : > bld/CMakeCache.txt && printf "int v = 1;\n" > bld/gen.c'; MR=$(rid)
[ -n "$MR" ] || { echo "setup failed: no run for the generated-mode check"; tail -5 "$T/out.txt"; exit 1; }
TMPDIR="$T/tmp" $DP --mutate "$MR" --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && ! has Traceback && has "MUTATION $MR: 2 mutants (sampled from 2, seed 0)" && ! has "bld/gen.c" \
  && grep -qx 'int v = 1;' "$R/bld/gen.c" && [ -z "$(ls -A "$T/tmp")" ] \
  && ok "3b generated mode takes no candidate from a created C/C++ file inside a directory holding CMakeCache.txt (the copy leaves it out)" \
  || { bad "3b generated mode, left-out created file rc=$RC"; tail -3 "$T/out.txt"; }

# generated mode with nothing to mutate: the run's C change is a comment line, so the run is isolated and has no candidate
newrepo 'Files: a.py, f.c\nAcceptance:\n- `grep -q y a.py`\n'
( cd "$R" && printf '// f\n' > f.c && printf '# a\n' > a.py && git add -A && git commit -qm src )
run 'echo y >> a.py; printf "// g\n" >> f.c'; MR=$(rid)
[ -n "$MR" ] || { echo "setup failed: no run for the no-candidate check"; tail -5 "$T/out.txt"; exit 1; }
TMPDIR="$T/tmp" $DP --mutate "$MR" --repo "$R" > "$T/out.txt" 2>&1; RC=$?
GOT=$(mj "$R/.git/concord/$MR/meta.json" '(m["mutation"]["mode"], m["mutation"]["candidates"])')
[ $RC -eq 0 ] && ! has Traceback && has "MUTATION $MR: no mutable" && [ "$GOT" = "('isolated', 0)" ] && [ -z "$(ls -A "$T/tmp")" ] \
  && ok "3b generated mode whose C/C++ change has nothing to mutate (a comment line): exit 0, meta records an isolated run with 0 candidates" \
  || { bad "3b isolated run without candidates rc=$RC meta=$GOT"; tail -3 "$T/out.txt"; }

newrepo 'Files: a.py\nAcceptance:\n- `grep -q y a.py`\n'
run 'echo y >> a.py; mkdir -p bld && : > bld/CMakeCache.txt && printf "int v = 1;\n" > bld/gen.c'; MR=$(rid)
[ -n "$MR" ] || { echo "setup failed: no run for the live-mode check"; tail -5 "$T/out.txt"; exit 1; }
TMPDIR="$T/tmp" $DP --mutate "$MR" --repo "$R" > "$T/out.txt" 2>&1; RC=$?
GOT=$(mj "$R/.git/concord/$MR/meta.json" '(m["mutation"]["mode"], m["mutation"]["candidates"])')
[ $RC -eq 0 ] && ! has Traceback && has "MUTATION $MR: no mutable" && [ "$GOT" = "('isolated', 0)" ] \
  && grep -qx 'int v = 1;' "$R/bld/gen.c" && [ -z "$(ls -A "$T/tmp")" ] \
  && ok "3b a run whose only C/C++ file lies inside a build tree: nothing to mutate, the file untouched, no copy left" \
  || { bad "3b build-tree C file rc=$RC meta=$GOT"; tail -3 "$T/out.txt"; }
fi

if sel 1c || sel 2 || sel 3; then
echo "== 1c 2 3 a C++ phase in a CMake-shaped repo"
if ! command -v cmake > /dev/null 2>&1 || ! command -v ctest > /dev/null 2>&1 || ! command -v c++ > /dev/null 2>&1; then
  echo "  SKIP cmake, ctest or c++ not on PATH: sections 1c, 2 and 3 did not run"
else
C="$T/cxx"; gitrepo "$C"
( cd "$C" && mkdir -p src tests cmake
cat > CMakeLists.txt <<'X'
cmake_minimum_required(VERSION 3.10)
project(calc CXX)
include(cmake/flags.cmake)
enable_testing()
add_library(calc STATIC src/calc.cpp)
target_include_directories(calc PUBLIC src)
add_executable(calc_test tests/calc_test.cpp)
target_link_libraries(calc_test calc)
add_test(NAME calc_test COMMAND calc_test)
add_executable(calc_print tests/calc_print.cpp)
target_link_libraries(calc_print calc)
X
printf 'set(CMAKE_CXX_STANDARD 11)\n' > cmake/flags.cmake
printf 'int clamp_add(int a, int b);\n' > src/calc.h
printf '#include "calc.h"\nint clamp_add(int a, int b) { return -1; }\n' > src/calc.cpp
cat > tests/calc_test.cpp <<'X'
#include "calc.h"
#include <cstdio>
int main() {
  int bad = 0;
  if (clamp_add(2, 3) != 5) { std::printf("FAIL: 2+3 is 5\n"); bad = 1; }
  if (clamp_add(9, 9) != 10) { std::printf("FAIL: 9+9 clamps to 10\n"); bad = 1; }
  return bad;
}
X
cat > tests/calc_print.cpp <<'X'
#include "calc.h"
#include <cstdio>
int main() { std::printf("%d\n", clamp_add(2, 3)); return 0; }
X
printf 'build/\n.claude/\n' > .gitignore
git add -A && git commit -qm init
mkdir -p build/gen && for i in $(seq -w 0 599); do echo "$i" > "build/gen/f$i.txt"; done )
cat > "$T/calc_impl.cpp" <<'X'
#include "calc.h"
int clamp_add(int a, int b) {
  if (a + b > 10) return 10;
  return a + b;
}
X
cat > "$C/PLAN_C.md" <<'P'
# Plan
## Phase 1 - clamp_add
Executor: deepseek-flash
Risk: low
Files: src/calc.cpp
Acceptance:
- `cmake -S . -B build -DBUILD_TESTING=ON > /dev/null && cmake --build build -j4 > /dev/null && ctest --test-dir build -R '^calc_test$'`
## Phase 2 - a session run that holds the checkout lock
Executor: deepseek-flash
Risk: low
Files: src/calc.h
Acceptance:
- `true`
P
printf '\nacceptance_hash_max_bytes = 1000\n' >> "$T/concord/executors.conf"
# Like a real executor, the fake one builds after its edit; the touch stands for build files of a test target. make
# compares mtimes to the second here, so the edit waits one second after the red run's build (a real executor does).
FAKE_ACTIONS="sleep 1; cp '$T/calc_impl.cpp' src/calc.cpp && cmake --build build -j4 > /dev/null 2>&1; touch build/CMakeFiles/calc_test.dir/flags.make" \
  $DP 1 --plan PLAN_C.md --via qwen --model fake/m --repo "$C" > "$T/out.txt" 2>&1; RC=$?
CR=$(rid); RUN="$C/.git/concord/$CR"
[ -n "$CR" ] && [ -f "$RUN/meta.json" ] && [ -x "$C/build/calc_print" ] || { echo "setup failed: C++ run rc=$RC"; tail -5 "$T/out.txt"; exit 1; }

if sel 1c; then
[ $RC -eq 0 ] && has "changed in scope: src/calc.cpp" && ! has "ACCEPTANCE FILES CHANGED" && ! has "acceptance file list capped" \
  && ! has "compared by size and mtime" && ok "1c C++ run: no build/ or cmake/ file reported as a changed acceptance file, no cap or size note" \
  || { bad "1c C++ run rc=$RC"; grep -e ACCEPT -e 'note: acc' -e 'changed in scope' "$T/out.txt" | cut -c1-240; tail -6 "$RUN/acceptance.after.txt" 2>/dev/null; }
[ "$(mj "$RUN/state.json" '[k for k in m["acceptance_hashes"] if k.startswith(("build/", "cmake/"))]')" = "[]" ] \
  && ok "1c the acceptance snapshot holds no build/ or cmake/ file" || bad "1c snapshot: $(mj "$RUN/state.json" 'sorted(m["acceptance_hashes"])[:4]')"
$DP --verdict "$CR" PASS --repo "$C" > "$T/v.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && [ "$(mj "$RUN/meta.json" 'm["verdict"]')" = PASS ] && [ "$(mj "$RUN/meta.json" '"forced" in (m.get("verdict_note") or "")')" = False ] \
  && ok "1c a clean C++ executor run takes --verdict PASS without --force" || { bad "1c verdict PASS rc=$RC"; cat "$T/v.txt"; }
fi

if sel 3; then
H0=$(sha "$C/src/calc.cpp"); M0=$(mtime "$C/src/calc.cpp"); B0=$(sha "$C/build/calc_print")
$DP --begin 2 --label implementer --plan PLAN_C.md --no-baseline --repo "$C" > "$T/out.txt" 2>&1; HB=$(bid)
[ -n "$HB" ] || { echo "setup failed: --begin"; tail -3 "$T/out.txt"; exit 1; }
TMPDIR="$T/tmp" $DP --mutate "$CR" --seed 0 --max 20 --build "cmake --build build -j4" --repo "$C" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "MUTATION $CR:" && has "killed 1, survived 1, stillborn 1" && grep -q "^SURVIVED src/calc.cpp:L3: compare: " "$T/out.txt" \
  && [ "$(mj "$RUN/meta.json" '(m["mutation"]["mode"], m["mutation"]["stillborn"])')" = "('isolated', 1)" ] \
  && ok "3 generated C++ mutants in an isolated copy: one killed, the untested boundary survives, a mutant that does not build is stillborn" \
  || { bad "3 C++ mutate rc=$RC"; head -12 "$T/out.txt"; }
[ $RC -eq 0 ] && [ "$(sha "$C/src/calc.cpp")" = "$H0" ] && [ "$(mtime "$C/src/calc.cpp")" = "$M0" ] && [ "$(sha "$C/build/calc_print")" = "$B0" ] \
  && [ -z "$(ls -A "$T/tmp")" ] && ok "3 the live checkout and its build are untouched while another run holds the lock; the copy is removed" \
  || { bad "3 live checkout touched or copy left"; ls -A "$T/tmp" | head -3; }
cat > "$T/mutants.json" <<'J'
[{"id": "M1", "file": "src/calc.cpp", "old": "return 10;", "new": "return 11;", "what": "clamp value off by one"},
 {"id": "M2", "file": "src/calc.cpp", "old": "a + b", "new": "a - b", "what": "ambiguous: the text occurs twice"},
 {"id": "M3", "file": "src/calc.cpp", "old": "a + b", "new": "a - b", "occ": 2, "what": "returned sum subtracts"},
 {"id": "M4", "file": "src/calc.cpp", "old": "return 10;", "new": "return 10", "what": "does not compile"},
 {"id": "M5", "file": "src/calc.cpp", "old": "> 10", "new": "> 11", "check": "grep -q '> 10' src/calc.cpp", "what": "structural check"}]
J
TMPDIR="$T/tmp" $DP --mutate "$CR" --mutants "$T/mutants.json" --build "cmake --build build -j4" --repo "$C" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "killed 3, survived 0, stillborn 1" && grep "^SKIP M2: " "$T/out.txt" | grep -q "occurs 2 times" \
  && [ "$(sha "$C/src/calc.cpp")" = "$H0" ] && [ -z "$(ls -A "$T/tmp")" ] \
  && ok "3 listed mutants: killed by the acceptance or by their own structural check, one stillborn, the ambiguous one skipped" \
  || { bad "3 listed mutants rc=$RC"; head -12 "$T/out.txt"; }
printf '[{"id": "X", "file": "../outside.cpp", "old": "a", "new": "b"}]' > "$T/bad1.json"
printf '{"id": "X"}' > "$T/bad2.json"
$DP --mutate "$CR" --mutants "$T/bad1.json" --repo "$C" > "$T/out.txt" 2>&1; R1=$?; U1=$(grep -c "unrecognized arguments" "$T/out.txt")
$DP --mutate "$CR" --mutants "$T/bad2.json" --repo "$C" > "$T/out.txt" 2>&1; R2=$?; U2=$(grep -c "unrecognized arguments" "$T/out.txt")
[ $R1 -eq 2 ] && [ $R2 -eq 2 ] && [ "$U1$U2" = 00 ] && ok "3 a mutant outside the checkout, or a mutants file that is not a list: exit 2" || bad "3 bad mutants rc=$R1/$R2"
$DP --abort "$HB" --repo "$C" > /dev/null 2>&1
fi

if sel 2; then
cmake --build "$C/build" -j4 > /dev/null 2>&1; [ "$("$C/build/calc_print")" = 5 ] || { echo "setup failed: the live build does not run the executor's code"; exit 1; }
# a changed file dated in the future (clock skew): the restored source must still come out newer than it
touch -t 203001010000 "$C/src/calc.cpp" "$T/ref2030"
$DP --restore "$CR" --repo "$C" > "$T/out.txt" 2>&1
cmake --build "$C/build" -j4 > /dev/null 2>&1; OUT=$("$C/build/calc_print")
has "restored src/calc.cpp" && [ "$OUT" = "-1" ] \
  && ok "2 after --restore the rebuilt binary runs the restored source" || bad "2 restore: calc_print printed $OUT (5 = the executor's stale object)"
[ "$(mtime "$C/src/calc.cpp")" -ge "$(( $(mtime "$T/ref2030") + 1000000000 ))" ] \
  && ok "2b the restored source is dated at least 1 s after the newest file the run changed" \
  || bad "2b restored mtime $(mtime "$C/src/calc.cpp") < $(mtime "$T/ref2030") + 1 s"
fi
fi
fi

echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
