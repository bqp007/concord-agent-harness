#!/bin/bash
# concord.py fix-round review cost (2026-10-22, PLAN_kit-fixreview): a fix commit is reviewed as a delta whatever files
# it touches, with the touched functions as context instead of each file's full PR change; only a fix that rewrites
# most of an existing file needs a full review; a fix that changes only tests, docs or comments after a reviewed head
# runs at low; a PR review with findings keeps the credit of the files it found nothing in.
# Sections: delta (P1), credit (P2); no argument = all. No network: fake gh, bare origin, fake qwen reviewer.
# Run: bash ~/.claude/concord/tests/fixreview_test.sh [delta|credit]   (exit 0 = all passed).
set -u
SECTION=${1:-all}
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fixreview-test.XXXXXX")" && pwd -P)"; export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/concord" "$T/home/.claude"
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
cat > "$T/bin/qwen" <<'EOF'
#!/bin/sh
echo ran >> "$T/qwen_calls"; printf '%s\n' "$1" > "$T/last_prompt.txt"
if [ -n "${FAKE_CLEAN:-}" ]; then printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n'; exit 0; fi
printf 'REVIEW-JSON\n{"findings": [{"severity": "HIGH", "path": "%s",' "${FAKE_PATH:-a.py}"
printf ' "line": 1, "problem": "wrong constant", "fix": "use 2", "repro": {"input": "x", "expected": "2", "actual": "1"}}], "clauses": [], "tests": [], "verdict": "FIX"}\nEND-REVIEW-JSON\n'
EOF
cat > "$T/bin/gh" <<'EOF'
#!/bin/sh
[ "$1" = pr ] && [ "$2" = view ] || exit 1
n=$(printf '%s' "$3" | sed -E 's|.*/pull/||; s|.*#||')
[ -f "$T/pr$n.json" ] && cat "$T/pr$n.json" && exit 0
echo "no pull requests found for $3" >&2; exit 1
EOF
# gen.py NAME COUNT PREFIX: a file of COUNT lines "PREFIX_0000 = 0"
printf '%s\n' 'import sys' 'n, k, p = sys.argv[1], int(sys.argv[2]), sys.argv[3]' \
  "open(n, 'w').write(''.join('%s_%04d = 0\\n' % (p, i) for i in range(k)))" > "$T/gen.py"
chmod +x "$T/bin/qwen" "$T/bin/gh"
# The /usr/bin git and python3 are xcrun shims; inside the macOS sandbox xcrun cannot write its cache and prints
# "couldn't create cache file" on stderr, which pollutes captured output. Prefer the developer dir's real binaries.
XDEV="$(xcode-select -p 2>/dev/null)"; [ -n "$XDEV" ] && [ -x "$XDEV/usr/bin/git" ] && [ -x "$XDEV/usr/bin/python3" ] && export PATH="$XDEV/usr/bin:$PATH"
export PATH="$T/bin:$PATH" HOME="$T/home"
DP="python3 $T/concord/concord.py"
O="$T/origin.git"; R="$T/clone"; RUNS="$R/.git/concord"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
has(){ grep -F -- "$1" "$T/out.txt" > /dev/null; }
rid(){ sed -n 's/^PR REVIEW \([^ ]*\).*/\1/p' "$T/out.txt" | head -1; }
mj(){ python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"m": m}))' "$1" "$2" 2>&1; }
calls(){ if [ -f "$T/qwen_calls" ]; then wc -l < "$T/qwen_calls" | tr -d ' '; else echo 0; fi; }
prjson(){ printf '{"baseRefName": "main", "headRefOid": "%s", "title": "t", "body": "b"}\n' "$2" > "$T/pr$1.json"; }
headn(){ git -C "$O" rev-parse "refs/pull/$1/head"; }
stn(){ $DP --pr-status "$1" --repo "$R" > "$T/out.txt" 2>&1; }
pushn(){ # pushn N 'shell' : commit a change on top of the PR N head and push it as the new head
  ( set -e; cd "$R"; git fetch -q origin "refs/pull/$1/head"; git checkout -q FETCH_HEAD; sh -c "$2"; git add -A; git commit -qm fix
    git push -q origin "HEAD:refs/pull/$1/head"; git checkout -q main ) || { echo "setup failed: pushn $1"; exit 1; }
  prjson "$1" "$(headn "$1")"; }
newpr(){ # newpr N 'shell' : a PR N branch off main with the given change
  ( set -e; cd "$R"; git checkout -q main; git checkout -qb "pr$1"; sh -c "$2"; git add -A; git commit -qm "pr$1"
    git push -qf origin "HEAD:refs/pull/$1/head"; git checkout -q main; git branch -qD "pr$1" ) || { echo "setup failed: newpr $1"; exit 1; }
  prjson "$1" "$(headn "$1")"; }
review(){ # review N [env...] : a full review of PR N at tier high by the fake reviewer; sets RD to its run dir
  n=$1; shift; env "$@" $DP --review-pr "$n" --via qwen --model fake/m --user-approved "test go-ahead" --tier "${RT:-high}" --repo "$R" > "$T/out.txt" 2>&1; RC=$?; RD="$RUNS/$(rid)"; }
delta(){ # delta N [env...] : a delta review of PR N at tier high by the fake reviewer; sets RC and RD
  n=$1; shift; env "$@" $DP --review-pr "$n" --delta --via qwen --model fake/m --user-approved "test go-ahead" --tier high --repo "$R" > "$T/out.txt" 2>&1; RC=$?; RD="$RUNS/$(rid)"; }
JFIX='REVIEW-JSON\n{"findings": [{"severity": "HIGH", "path": "a.py", "line": 1, "problem": "wrong constant", "fix": "use 2", "repro": {"input": "x", "expected": "2", "actual": "1"}}], "clauses": [], "tests": [], "verdict": "FIX"}\nEND-REVIEW-JSON\n'

git init -q --bare -b main "$O" && git clone -q "$O" "$R" 2> /dev/null || { echo "setup failed: repos"; exit 1; }
( set -e; cd "$R" && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > a.py
  printf 'def one():\n    a = 1\n    b = 2\n    c = 3\n    d = 4\n    e = 5\n    return a\n\n\ndef two():\n    return 2\n' > f.py
  printf 'int one() {\n  return 1;  // one\n}\nconst char* s = "// a";\n' > k.cpp
  python3 "$T/gen.py" r.py 60 r; printf 't1 = 1\nt2 = 2\nt3 = 3\n' > t.py
  mkdir -p tests docs; printf 'def test_a():\n    assert True\n' > tests/test_a.py; printf '# X\n' > docs/x.md
  printf '.claude/\n' > .gitignore; git add -A && git commit -qm init && git push -q origin main ) || { echo "setup failed: main"; exit 1; }

if [ "$SECTION" != credit ]; then
echo "== a fix touching files no finding names is still a delta, with the touched function as context"
newpr 21 "sed -i.bak 's/return 2/return 3/' f.py && rm f.py.bak; printf 'x = 2\n' > a.py"; A0=$(headn 21)
review 21 FAKE_CLEAN=1; stn 21
has "CURRENT HEAD ${A0:0:8}: REVIEWED at high" || { bad "setup: A0 not reviewed"; cat "$T/out.txt"; }
pushn 21 "sed -i.bak 's/a = 1/a = 10/' f.py && rm f.py.bak; printf 'def test_f():\n    assert True\n' > tests/test_f.py"; A1=$(headn 21); stn 21
has "CURRENT HEAD ${A1:0:8}: UNREVIEWED (head moved; last reviewed ${A0:0:8}; changed since: f.py, tests/test_f.py; delta review possible)" \
  && ok "--pr-status: files no finding names no longer force a full review" || { bad "unnamed files status"; cat "$T/out.txt"; }
C0=$(calls); delta 21 FAKE_CLEAN=1; D="$RD"
[ $RC -eq 0 ] && [ "$(mj "$D/meta.json" '(m["since"], m["delta_files"], m["tier"])')" = "('$A0', ['f.py', 'tests/test_f.py'], 'high')" ] \
  && [ "$(calls)" = $((C0 + 1)) ] && ok "--delta accepted: since, both files, tier high (f.py is code), one model call" \
  || { bad "delta rc=$RC: $(mj "$D/meta.json" '(m.get("since"), m.get("delta_files"), m.get("tier"))')"; tail -3 "$T/out.txt"; }
P="$D/prompt.txt"
grep -q "^Changed since the last reviewed head ${A0:0:8}" "$P" && grep -q '^+    a = 10$' "$P" && grep -q '^     return a$' "$P" \
  && ok "delta prompt: the fix diff carries the touched function as context" || bad "function context: $(grep -n '^[-+ @]' "$P" | head -20)"
! grep -q '^+    return 3$' "$P" && ! grep -q '^-    return 2$' "$P" \
  && ok "delta prompt: no full PR change of the touched file" || bad "full PR change still in the delta prompt"
grep -qE "^Full PR change of a file, when the function context is not enough: git diff [0-9a-f]{40}\.\.\.${A1} -- <file>$" "$P" \
  && ok "delta prompt: names the command for a file's full PR change" || bad "no full-change pointer: $(grep -n 'Full PR' "$P")"
stn 21; has "CURRENT HEAD ${A1:0:8}: REVIEWED at high (via delta from ${A0:0:8})" && ok "clean delta carries the reviewed head" || { bad "carry"; cat "$T/out.txt"; }

echo "== only a fix that rewrites most of an existing file needs a full review"
newpr 22 "printf 'x = 3\n' > a.py"; B0=$(headn 22); review 22 FAKE_CLEAN=1
pushn 22 "sed -i.bak '1,40s/= 0/= 1/' r.py && rm r.py.bak; python3 $T/gen.py n.py 100 n"; B1=$(headn 22)
C0=$(calls); delta 22 FAKE_CLEAN=1
[ $RC -eq 2 ] && has "delta review not sufficient for PR 22: r.py rewritten since ${B0:0:8} (40+/40- of 60 lines); run a full review" \
  && [ "$(calls)" = "$C0" ] && ok "--delta: 40 of 60 lines rewritten -> exit 2, names the file, no model call" || { bad "rewrite rc=$RC"; tail -3 "$T/out.txt"; }
stn 22
has "CURRENT HEAD ${B1:0:8}: UNREVIEWED (head moved; last reviewed ${B0:0:8}; changed since: n.py, r.py; full review needed (rewritten: r.py (40+/40- of 60 lines)))" \
  && ok "--pr-status names the rewritten file (the new n.py is exempt)" || { bad "rewrite status"; cat "$T/out.txt"; }
newpr 23 "printf 'x = 5\n' > a.py"; review 23 FAKE_CLEAN=1
pushn 23 "sed -i.bak '1,15s/= 0/= 2/' r.py && rm r.py.bak; printf 'u1 = 1\nu2 = 2\nu3 = 3\n' > t.py; python3 $T/gen.py n.py 100 n"
delta 23 FAKE_CLEAN=1
[ $RC -eq 0 ] && [ "$(mj "$RD/meta.json" 'm["delta_files"]')" = "['n.py', 'r.py', 't.py']" ] \
  && ok "--delta accepts 15 of 60 lines, a fully changed 3-line file and a new file" || { bad "small edits rc=$RC"; tail -3 "$T/out.txt"; }

echo "== a fix that changes only tests, docs or comments after a reviewed head runs at low"
newpr 24 "printf 'x = 4\n' > a.py; sed -i.bak 's/return 1;/return 2;/' k.cpp && rm k.cpp.bak"; L0=$(headn 24); review 24 FAKE_CLEAN=1
pushn 24 "printf '# why four\nx = 4  # four\n' > a.py; sed -i.bak 's|// one|// uno|' k.cpp && rm k.cpp.bak && printf '/* block */\n' >> k.cpp; printf 'def test_a():\n    assert 1\n' > tests/test_a.py; printf '# X\nmore\n' > docs/x.md"
L1=$(headn 24); delta 24 FAKE_CLEAN=1
[ $RC -eq 0 ] && has "note: tier lowered to low: the fix changes only tests, docs or comments (a.py, docs/x.md, k.cpp, tests/test_a.py)" \
  && [ "$(mj "$RD/meta.json" '(m["tier"], m.get("light"))')" = "('low', True)" ] \
  && ok "--delta: comment-only Python and C++, a test and a doc -> tier low, meta light" || { bad "light rc=$RC: $(mj "$RD/meta.json" '(m.get("tier"), m.get("light"))')"; tail -3 "$T/out.txt"; }
stn 24; has "CURRENT HEAD ${L1:0:8}: REVIEWED at high (via delta from ${L0:0:8}; light fix at low)" \
  && ok "--pr-status: a light delta keeps the reviewed head's tier" || { bad "light status"; cat "$T/out.txt"; }
pushn 24 "sed -i.bak 's|\"// a\"|\"// b\"|' k.cpp && rm k.cpp.bak"; delta 24 FAKE_CLEAN=1
[ $RC -eq 0 ] && ! has "tier lowered" && [ "$(mj "$RD/meta.json" '(m["tier"], m.get("light", False))')" = "('high', False)" ] \
  && ok "--delta: a string literal holding // is code -> tier stays high" || { bad "string literal rc=$RC"; tail -3 "$T/out.txt"; }
newpr 25 "printf 'x = 6\n' > a.py; printf 'def test_a():\n    assert 2\n' > tests/test_a.py"; O0=$(headn 25)
review 25 FAKE_PATH=tests/test_a.py; stn 25
has "CURRENT HEAD ${O0:0:8}: FINDINGS OPEN" || { bad "setup: O0 not open"; cat "$T/out.txt"; }
pushn 25 "printf 'def test_a():\n    assert 3\n' > tests/test_a.py"; delta 25 FAKE_CLEAN=1
[ $RC -eq 0 ] && has "tier lowered to low" && [ "$(mj "$RD/meta.json" '(m["tier"], m.get("light", False))')" = "('low', True)" ] \
  && ok "--delta: a fix of an open finding runs at low; the full review's tier carries (2026-10-25)" || { bad "open light rc=$RC"; tail -3 "$T/out.txt"; }
newpr 37 "printf 'int a;\n' > m.c"; review 37 FAKE_CLEAN=1
pushn 37 "printf 'int a;  /* why */\n' > m.c; printf 'int b;\n' > n.c"; delta 37 FAKE_CLEAN=1
[ $RC -eq 0 ] && ! has "tier lowered" && ! has "Traceback" && [ "$(mj "$RD/meta.json" '(m["tier"], m.get("light", False))')" = "('high', False)" ] \
  && ok "--delta: a fix that adds a new C file is code -> tier stays high, no crash" || { bad "new file rc=$RC"; tail -3 "$T/out.txt"; }

echo "== a fix round names the code files no open finding names (NOTE fixes wait for one final commit)"
newpr 26 "printf 'x = 7\n' > a.py; printf 'c = 1\n' > c.py"; N0=$(headn 26); review 26; stn 26
has "CURRENT HEAD ${N0:0:8}: FINDINGS OPEN" || { bad "setup: N0 not open"; cat "$T/out.txt"; }
pushn 26 "printf 'x = 8\n' > a.py; printf 'c = 2\n' > c.py; printf 'def test_a():\n    assert 4\n' > tests/test_a.py"; delta 26 FAKE_CLEAN=1
[ $RC -eq 0 ] && has "note: no open finding names c.py; batch NOTE fixes in one final commit" \
  && ok "--delta on an open head: names c.py, not the test file" || { bad "note rc=$RC"; tail -3 "$T/out.txt"; }

echo "== function context falls back to 10 lines; an oversized fix still refuses"
newpr 30 "python3 $T/gen.py big.py 2000 v; printf 's = 1\n' > s.py"; Q0=$(headn 30); review 30 FAKE_CLEAN=1
pushn 30 "sed -i.bak 's/^v_1999 = 0/v_1999 = 1/' big.py && rm big.py.bak"; delta 30 FAKE_CLEAN=1; P="$RD/prompt.txt"
[ $RC -eq 0 ] && grep -q '^+v_1999 = 1$' "$P" && grep -q '^ v_1989 = 0$' "$P" && ! grep -q 'v_0000' "$P" \
  && grep -q '^\[function context of big.py over 12,000 chars; 10 lines of context shown\]$' "$P" \
  && ok "--delta: function context over 12,000 chars -> 10 lines of context, marked" || { bad "fallback rc=$RC: $(grep -n 'function context\|^@@' "$P" | head)"; tail -3 "$T/out.txt"; }
pushn 30 "python3 $T/gen.py huge.py 7000 h"; delta 30 FAKE_CLEAN=1
[ $RC -eq 2 ] && has "fix diff since" && has "over the 60,000 cap; run a full review" \
  && ok "--delta: a fix diff over the cap refuses (exit 2)" || { bad "huge fix rc=$RC"; tail -3 "$T/out.txt"; }

echo "== the 12,000-char cap is on a file's function context, not on the file; C/C++ use the cpp driver"
cat > "$T/genfn.py" <<'EOF'
import sys
n, k = sys.argv[1], int(sys.argv[2])
fn = lambda i: "def fn_%d(x):\n%s    return v15\n" % (i, "".join("    v%d = x + %d\n" % (j, j) for j in range(16)))
open(n, "w").write("\n\n".join(fn(i) for i in range(k)))
EOF
newpr 31 "python3 $T/genfn.py p.py 45"; review 31 FAKE_CLEAN=1
pushn 31 "sed -i.bak '116s/= x + 14$/= x + 140/' p.py && rm p.py.bak"; delta 31 FAKE_CLEAN=1; P="$RD/prompt.txt"
[ $RC -eq 0 ] && grep -q '^+    v14 = x + 140$' "$P" && grep -q '^ def fn_5(x):$' "$P" && ! grep -q '^ def fn_4(x):$' "$P" \
  && ! grep -q 'function context of p.py' "$P" \
  && ok "--delta: a 12,723-char file with a small touched function keeps -W, no marker" || { bad "big file -W rc=$RC: $(grep -n 'function context\|^@@' "$P" | head)"; tail -3 "$T/out.txt"; }
newpr 32 "printf 'int f(int x)\n{\n  int y = 0;\nretry:\n  y++;\n  if (y < x) goto retry;\n  return y;\n}\n' > m.c"; review 32 FAKE_CLEAN=1
pushn 32 "sed -i.bak 's/  return y;/  return y + 1;/' m.c && rm m.c.bak"; delta 32 FAKE_CLEAN=1; P="$RD/prompt.txt"
[ $RC -eq 0 ] && grep -q '^+  return y + 1;$' "$P" && grep -q '^ int f(int x)$' "$P" \
  && ok "--delta: a C function with a label keeps its signature as context (diff=cpp)" || { bad "cpp driver rc=$RC: $(grep -n '^[-+ @]' "$P" | head -12)"; tail -3 "$T/out.txt"; }
newpr 33 "mkdir -p src && printf 'def parse():\n    return 1\n' > src/spec_parser.py"; review 33 FAKE_CLEAN=1
pushn 33 "printf 'def parse():\n    return 2\n' > src/spec_parser.py"; delta 33 FAKE_CLEAN=1
[ $RC -eq 0 ] && ! has "tier lowered" && [ "$(mj "$RD/meta.json" '(m["tier"], m.get("light", False))')" = "('high', False)" ] \
  && ok "--delta: a code change in src/spec_parser.py is code, not a test (tier stays high)" || { bad "spec_ path rc=$RC: $(mj "$RD/meta.json" '(m.get("tier"), m.get("light"))')"; tail -3 "$T/out.txt"; }

echo "== property (seeded): comments and blank lines never change the code; one changed token always does"
python3 -I - "$T/concord/concord.py" > "$T/out.txt" 2>&1 <<'EOF'
import importlib.util, random, sys
spec = importlib.util.spec_from_file_location("concord", sys.argv[1]); c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
import signal
def _hang(*_): raise TimeoutError("the stripper did not return (a loop that never advances)")
signal.signal(signal.SIGALRM, _hang); signal.alarm(30)
eq, rnd = c.code_equal_ignoring_comments, random.Random(7)
def check(path, base, commented, mutated):
    assert eq(path, base, base), (path, base)
    assert eq(path, base, commented), (path, base, commented)
    assert not eq(path, base, mutated), (path, base, mutated)
for _ in range(150):
    n = rnd.randint(1, 8); vals = [rnd.randint(0, 99) for _ in range(n)]
    py = [f"v{i} = {v}" for i, v in enumerate(vals)]; cc = [f"int v{i} = {v};" for i, v in enumerate(vals)]
    cc.append(f'const char* s = "//{rnd.randint(0, 9)}";')
    pyc, ccc = [], []
    for a, b in zip(py, cc):
        if rnd.random() < 0.5: pyc.append(f"# note {rnd.randint(0, 9)}"); ccc.append(f"// note {rnd.randint(0, 9)}")
        if rnd.random() < 0.3: pyc.append(""); ccc.append("/* block */")
        pyc.append(a + ("  # tail" if rnd.random() < 0.5 else "")); ccc.append(b + ("  // tail" if rnd.random() < 0.5 else ""))
    ccc.append(cc[-1] + "  /* end */")
    k = rnd.randrange(n)
    pym = py[:k] + [f"v{k} = {vals[k] + 1}"] + py[k + 1:]
    ccm = cc[:k] + [f"int v{k} = {vals[k] + 1};"] + cc[k + 1:]
    check("m.py", "\n".join(py) + "\n", "\n".join(pyc) + "\n", "\n".join(pym) + "\n")
    check("m.cpp", "\n".join(cc) + "\n", "\n".join(ccc) + "\n", "\n".join(ccm) + "\n")
    check("m.cpp", "\n".join(cc) + "\n", "\n".join(ccc) + "\n", "\n".join(cc[:-1] + [cc[-1].replace("//", "// x")]) + "\n")
for path, old, new in (("m.py", "x = (1\n", "x = (1\n"), ("m.cpp", "int a; /* open\n", "int a; /* open\n"),
                       ("m.cpp", 'char* s = "open;\n', 'char* s = "open;\n'), ("m.cpp", 'auto s = R"(// a)";\n', 'auto s = R"(// a)";\n'),
                       ("m.cpp", "#define X 1 \\\nint y;\n", "#define X 1\nint y;\n"), ("m.sh", "x=1\n", "x=1  # c\n")):
    assert not eq(path, old, new), (path, old, new)   # unparsable, raw string, line join, unknown language: code
for path, old, new in (("m.cpp", "int a;\n// c\nint b;\n", "int a;\n// c \\ \nint b;\n"),        # splice: backslash, space
                       ("m.cpp", "int a;\r\n// c\r\nint b;\r\n", "int a;\r\n// c \\\r\nint b;\r\n"),  # splice: backslash, CRLF
                       ("m.cpp", 'const char* s = "a  b";\n', 'const char* s = "a b";\n'),
                       ("m.cpp", "char c = ' ';\n", "char c = '\t';\n"),
                       ("m.cpp", 'const char* s = "a\\\n  b";\n', 'const char* s = "a\\\nb";\n'),
                       ("m.py", 's = "é"\n', '# -*- coding: latin-1 -*-\ns = "é"\n'),
                       ("m.py", "#!/usr/bin/env python3\nx = 1\n", "#!/usr/bin/env python2\nx = 1\n"),
                       ("m.cpp", "int a = 1'000; const char *s = \"x'; // y\"; g();\n",        # digit separator (F8)
                        "int a = 1'000; const char *s = \"x'; // y\"; launch();\n"),
                       ("n.c", "/* c *\\\n/\nint a = 1;\n/* x */\n", "/* c *\\\n/\nint a = 2;\n/* x */\n"),  # spliced */ (F9)
                       ("n.c", "/* c *??/\n/\nint a = 1;\n/* x */\n", "/* c *??/\n/\nint a = 2;\n/* x */\n"),  # trigraph ??/
                       ("h.c", "#include <a//b.h>\nint x;\n", "#include <a//evil.h>\nint x;\n"),    # header name
                       ("h.c", "#include \\\n<a//b.h>\nint x;\n", "#include \\\n<a//evil.h>\nint x;\n"),
                       ("h.c", "%:include <a/*b.h>\nint x; /* c */\n", "%:include <a/*b.h>\nint y; /* c */\n"),
                       ("m.cpp", "#define S(x) #x\nconst char *a = S(1.'2); const char *s = \"'; // \"; int g;\n",  # separator after . (F12)
                        "#define S(x) #x\nconst char *a = S(1.'2); const char *s = \"'; // \"; int h;\n"),
                       ("m.cpp", "#define S(x) #x\nconst char *a = S(1e+'2); const char *s = \"'; // \"; int g;\n",  # after an exponent sign
                        "#define S(x) #x\nconst char *a = S(1e+'2); const char *s = \"'; // \"; int h;\n"),
                       ("m.cpp", "#define S(x) #x\nconst char *a = S(1é'2); const char *s = \"'; // \"; int g;\n",  # after a combining mark
                        "#define S(x) #x\nconst char *a = S(1é'2); const char *s = \"'; // \"; int h;\n"),
                       ("n.c", "int f(void);\n/* c *\\\r/ int g = 1; /* d */\nint h;\n",                 # backslash + lone CR (F13)
                        "int f(void);\n/* c *\\\r/ int g = 2; /* d */\nint h;\n"),
                       ("n.c", "int a = 1;\n// c\rint g = 2;\n", "int a = 1;\n// c\rint g = 3;\n"),      # a lone CR ends a // comment (F17)
                       ("n.c", "int a, b; int x = a ??' b; const char *s = \"'; // \"; int g;\n",          # trigraph ??' (F14)
                        "int a, b; int x = a ??' b; const char *s = \"'; // \"; int h;\n"),
                       ("h.c", "??=include <a//b.h>\nint x;\n", "??=include <a//evil.h>\nint x;\n"),      # trigraph ??=
                       ("h.c", "/**/#include <a//b.h>\nint x;\n", "/**/#include <a//evil.h>\nint x;\n"),  # comment before # (F15)
                       ("h.c", "#include /*\n*/ <a//b.h>\nint x;\n", "#include /*\n*/ <a//evil.h>\nint x;\n"),  # comment inside the directive
                       ("h.cpp", "import <a//b.h>;\nint x;\n", "import <a//evil.h>;\nint x;\n"),          # C++20 header unit
                       ("h.c", "#define X a < \">//\" int g;\n", "#define X a < \">//\" int h;\n"),      # a quote in a header candidate
                       ("h.cpp", "import <a//b.h>;\nint x", "import <a//evil.h>;\nint x")):            # import at index 0, no final newline
    assert not eq(path, old, new), (path, old, new)   # comment splices, whitespace in literals, coding cookie, shebang
for path, old, new in (("m.cpp", 'puts("a  b");\n', 'puts("a  b");  // say it\n'),
                       ("m.cpp", 'int  a = "x  y"[0];\n', 'int a = "x  y"[0];\n'),
                       ("m.py", "# -*- coding: utf-8 -*-\nx = 1\n", "# -*- coding: utf-8 -*-\nx = 1  # one\n"),
                       ("m.py", "#!/usr/bin/env python3\nx = 1\n", "#!/usr/bin/env python3\n# why\nx = 1\n"),
                       ("m.c", "#define F(x) \\\n  ((x) + 1)\nint y;\n", "#define F(x) \\\n  ((x) + 1)  /* add one */\nint y;\n"),
                       ("m.cpp", "char c = 'a';\nint n = 1;\n", "char c = 'a';  // letter\nint n = 1;\n"),
                       ("m.c", "#include <stdio.h>\nint x;\n", "#include <stdio.h>  // printf\nint x;\n"),
                       ("m.c", "int a;\r\n// c\r\nint b;\r\n", "int a;\r\n// d\r\nint b;\r\n"),          # CRLF is not a lone CR
                       ("m.c", "int x = y-'a';\n", "int x = y-'a';  // offset\n"),                       # '-' after a name: a literal
                       ("m.cpp", "if (a < b) return 'y';\n", "if (a < b) return 'y';  // less\n"),       # '<' outside a directive
                       ("m.c", "#if A < B && C > D\n#endif\n", "#if A < B && C > D  // both\n#endif\n"),  # candidate closed by '>'
                       ("m.c", "#define NL \"\\n\"\n", "#define NL \"\\n\"  // newline\n"),              # a directive with a string
                       ("m.c", "'a' + b", "'a' + /* c */ b"),                                            # ' at index 0, no final newline
                       ("m.c", "\"a\"; int R", "\"a\"; /* c */ int R"),                                # \" at index 0, text ends in R
                       ("m.c", "#include <a.h>\nif (a < b) return 1;\n", "#include <a.h>\nif (a < b) return 1;  // less\n"),  # newline ends it
                       ("m.c", "#include <a.h><b.h>\nint x;\n", "#include <a.h><b.h>  // two\nint x;\n")):   # '>' right before '<'
    assert eq(path, old, new), (path, old, new)       # literals kept whole; whitespace outside them, other comments
import time
t0 = time.monotonic(); eq("m.c", "int a;\n", "int a;\n#" + "<" * 100000 + "\n")
assert time.monotonic() - t0 < 3, "header-name scan is not linear (F16)"
print("property ok")
EOF
[ $? -eq 0 ] && has "property ok" && ok "seeded property: 450 Python and C++ cases, 48 edge inputs" || { bad "property"; tail -5 "$T/out.txt"; }
fi

if [ "$SECTION" != delta ]; then
echo "== a PR review with a finding keeps the credit of its clean files"
newpr 27 "printf 'x = 9\n' > a.py; printf 'c = 3\n' > c.py"; G0=$(headn 27); RT=low review 27; D="$RD"
CB=$(git -C "$O" rev-parse "$G0:c.py")
[ "$(mj "$D/meta.json" '(m["reviews"][-1]["verdict"], m["reviews"][-1].get("covered"), m["reviews"][-1].get("cover_tier"))')" = "('FIX', {'c.py': '$CB'}, 1)" ] \
  && ok "FIX review at low: covered holds c.py only (a.py carries the finding)" || bad "group credit: $(mj "$D/meta.json" 'm["reviews"][-1]')"
pushn 27 "printf 'x = 10\n' > a.py"; RT=low review 27 FAKE_CLEAN=1
has "reused 1 file(s) already reviewed by" && has "c.py; reviewing a.py" && ! grep -q "^diff --git a/c.py" "$RD/prompt.txt" \
  && ok "the next full review skips c.py and reviews a.py only" || { bad "reuse after FIX"; tail -3 "$T/out.txt"; }
newpr 28 "printf 'x = 11\n' > a.py; printf 'c = 4\n' > c.py"; review 28 FAKE_PATH=zz.py
[ "$(mj "$RD/meta.json" '(m["reviews"][-1]["verdict"], bool(m["reviews"][-1].get("covered")))')" = "('FIX', False)" ] \
  && ok "a finding on a path the review did not see: nothing covered" || bad "unplaced: $(mj "$RD/meta.json" 'm["reviews"][-1]')"
newpr 29 "printf 'x = 12\n' > a.py; printf 'c = 5\n' > c.py"; K0=$(headn 29)
$DP --review-pr 29 --packet --tier high --repo "$R" > "$T/out.txt" 2>&1; PK=$(sed -n 's/^PACKET \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
PD=$(dirname "${PK:-/none/x}"); printf '%b' "$JFIX" > "$T/rev.txt"
$DP --review-record "$(basename "$PD")" --reviewer reviewer-opus55 --file "$T/rev.txt" --repo "$R" > "$T/out.txt" 2>&1
CB=$(git -C "$O" rev-parse "$K0:c.py"); AB=$(git -C "$O" rev-parse "$K0:a.py")
[ "$(mj "$PD/meta.json" '(m["reviews"][-1]["verdict"], m["reviews"][-1].get("covered"), m["reviews"][-1].get("cover_tier"), m["reviews"][-1].get("flagged"))')" = "('FIX', {'c.py': '$CB'}, 3, {'a.py': '$AB'})" ] \
  && ok "--review-record of a PR packet with a HIGH on a.py: covered holds c.py, flagged holds a.py" || bad "record credit: $(mj "$PD/meta.json" 'm["reviews"][-1]' | head -c 300)"
JPATHS='REVIEW-JSON\n{"findings": [{"severity": "HIGH", "path": "b/a.py", "line": 1, "problem": "wrong constant", "fix": "use 2", "repro": {"input": "x", "expected": "2", "actual": "1"}}, {"severity": "NOTE", "path": "c.py", "line": 1, "problem": "naming", "fix": "rename"}], "clauses": [], "tests": [], "verdict": "FIX"}\nEND-REVIEW-JSON\n'
newpr 36 "printf 'x = 16\n' > a.py; printf 'c = 9\n' > c.py"; K1=$(headn 36)
$DP --review-pr 36 --packet --tier high --repo "$R" > "$T/out.txt" 2>&1; PK=$(sed -n 's/^PACKET \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
PD=$(dirname "${PK:-/none/x}"); printf '%b' "$JPATHS" > "$T/rev.txt"
$DP --review-record "$(basename "$PD")" --reviewer reviewer-opus55 --file "$T/rev.txt" --repo "$R" > "$T/out.txt" 2>&1
CB=$(git -C "$O" rev-parse "$K1:c.py"); AB=$(git -C "$O" rev-parse "$K1:a.py")
[ "$(mj "$PD/meta.json" '(m["reviews"][-1].get("covered"), m["reviews"][-1].get("flagged"))')" = "({'c.py': '$CB'}, {'a.py': '$AB'})" ] \
  && ok "a HIGH on b/a.py plus a NOTE on c.py: a.py is flagged, c.py stays covered" || bad "b/ path and NOTE: $(mj "$PD/meta.json" 'm["reviews"][-1]' | head -c 300)"
echo "== a file one review flagged is never credited by another review at the same content"
newpr 34 "printf 'x = 14\n' > a.py; printf 'c = 7\n' > c.py; printf 'e = 1\n' > e.py"; F0=$(headn 34)
$DP --review-pr 34 --via qwen --model fake/m --user-approved "test go-ahead" --tier low --repo "$R" > "$T/out.txt" 2>&1           # HIGH on a.py
env FAKE_PATH=c.py $DP --review-pr 34 --via qwen --model fake/m --user-approved "test go-ahead" --tier low --force-review --repo "$R" > "$T/out.txt" 2>&1   # HIGH on c.py
C0=$(calls); $DP --review-pr 34 --via qwen --model fake/m --user-approved "test go-ahead" --tier low --repo "$R" > "$T/out.txt" 2>&1
[ "$(calls)" = $((C0 + 1)) ] && ! has "COVERED:" && has "e.py; reviewing a.py, c.py" \
  && ok "two reviews flag a.py and c.py: the next review reuses e.py only and reviews both flagged files" || { bad "cross credit calls=$(calls) C0=$C0"; tail -3 "$T/out.txt"; }
stn 34; has "CURRENT HEAD ${F0:0:8}: FINDINGS OPEN" && ok "--pr-status: the open findings stay open" || { bad "cross credit status"; cat "$T/out.txt"; }
newpr 35 "printf 'x = 15\n' > a.py; printf 'c = 8\n' > c.py"
env FAKE_CLEAN=1 $DP --review-pr 35 --via qwen --model fake/m --user-approved "test go-ahead" --tier low --repo "$R" > "$T/out.txt" 2>&1        # clean: both files credited
env FAKE_PATH=zz.py $DP --review-pr 35 --via qwen --model fake/m --user-approved "test go-ahead" --tier low --force-review --repo "$R" > "$T/out.txt" 2>&1  # a finding on no file
C0=$(calls); $DP --review-pr 35 --via qwen --model fake/m --user-approved "test go-ahead" --tier low --repo "$R" > "$T/out.txt" 2>&1
[ "$(calls)" = $((C0 + 1)) ] && ! has "COVERED:" && ! has "reused " \
  && ok "a finding on no file flags every file: the clean review's credit covers nothing at that content" || { bad "unplaced flags calls=$(calls) C0=$C0"; tail -3 "$T/out.txt"; }
fi

echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
