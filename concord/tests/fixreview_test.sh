#!/bin/bash
# concord.py fix-round review cost: a fix commit is reviewed as a delta whatever files it touches, with the touched
# functions as context instead of each file's full PR change; a fix that rewrites most of an existing file needs a full
# review. No network: fake gh, bare origin, fake qwen reviewer.
# Run: bash ~/.claude/concord/tests/fixreview_test.sh   (exit 0 = all passed).
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fixreview-test.XXXXXX")" && pwd -P)"; export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/concord" "$T/home/.claude"
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
cat > "$T/bin/qwen" <<'EOF'
#!/bin/sh
echo ran >> "$T/qwen_calls"; printf '%s\n' "$1" > "$T/last_prompt.txt"
printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n'
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
. "$(dirname "$0")/lib.sh"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
has(){ grep -F -- "$1" "$T/out.txt" > /dev/null; }
rid(){ sed -n 's/^PR REVIEW \([^ ]*\).*/\1/p' "$T/out.txt" | head -1; }
mj(){ python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"m": m}))' "$1" "$2" 2>&1; }
calls(){ if [ -f "$T/qwen_calls" ]; then wc -l < "$T/qwen_calls" | tr -d ' '; else echo 0; fi; }
prjson(){ printf '{"baseRefName": "main", "headRefName": "pr%s", "headRefOid": "%s", "title": "t", "body": "b"}\n' "$1" "$(headn "$1")" > "$T/pr$1.json"; }
headn(){ git -C "$O" rev-parse "refs/pull/$1/head"; }
pushn(){ # pushn N 'shell' : commit a change on top of the PR N head and push it as the new head
  ( set -e; cd "$R"; git fetch -q origin "refs/pull/$1/head"; git checkout -q FETCH_HEAD; sh -c "$2"; git add -A; git commit -qm fix
    git push -q origin "HEAD:refs/pull/$1/head"; git checkout -q main ) || { echo "setup failed: pushn $1"; exit 1; }
  prjson "$1"; }
newpr(){ # newpr N 'shell' : a PR N branch off main with the given change
  ( set -e; cd "$R"; git checkout -q main; git checkout -qb "pr$1"; sh -c "$2"; git add -A; git commit -qm "pr$1"
    git push -qf origin "HEAD:refs/pull/$1/head"; git checkout -q main; git branch -qD "pr$1" ) || { echo "setup failed: newpr $1"; exit 1; }
  prjson "$1"; }
clean='REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n'; printf '%b' "$clean" > "$T/clean.txt"
review(){ # review N : a clean full review of PR N by an Opus reviewer (the base of a delta)
  $DP --review-pr "$1" --packet --tier medium --repo "$R" > "$T/out.txt" 2>&1; local pk; pk=$(sed -n 's/^PACKET \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
  [ -n "$pk" ] || { echo "setup failed: no packet for PR $1"; cat "$T/out.txt"; exit 1; }
  cp "$T/clean.txt" "$T/ans.txt"; sign "$T/ans.txt" "$pk"
  $DP --review-record "$(basename "$(dirname "$pk")")" --reviewer concord:reviewer-opus55 --file "$T/ans.txt" --repo "$R" > "$T/rec.txt" 2>&1 \
    || { echo "setup failed: record for PR $1"; cat "$T/rec.txt"; exit 1; }; }
delta(){ # delta N : a delta review of PR N by the fake reviewer; sets RC and RD (its run dir)
  $DP --review-pr "$1" --delta --via qwen --model fake/m --tier medium --repo "$R" > "$T/out.txt" 2>&1; RC=$?; RD="$RUNS/$(rid)"; }

git init -q --bare -b main "$O" && git clone -q "$O" "$R" 2> /dev/null || { echo "setup failed: repos"; exit 1; }
( set -e; cd "$R" && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > a.py
  printf 'def one():\n    a = 1\n    b = 2\n    c = 3\n    d = 4\n    e = 5\n    return a\n\n\ndef two():\n    return 2\n' > f.py
  python3 "$T/gen.py" r.py 60 r; printf 't1 = 1\nt2 = 2\nt3 = 3\n' > t.py
  mkdir -p tests; printf 'def test_a():\n    assert True\n' > tests/test_a.py
  printf '.claude/\n' > .gitignore; git add -A && git commit -qm init && git push -q origin main ) || { echo "setup failed: main"; exit 1; }

echo "== a fix touching files no finding names is a delta, with the touched function as context"
newpr 21 "sed -i.bak 's/return 2/return 3/' f.py && rm f.py.bak; printf 'x = 2\n' > a.py"; A0=$(headn 21)
review 21
pushn 21 "sed -i.bak 's/a = 1/a = 10/' f.py && rm f.py.bak; printf 'def test_f():\n    assert True\n' > tests/test_f.py"; A1=$(headn 21)
C0=$(calls); delta 21; D="$RD"
[ $RC -eq 0 ] && [ "$(mj "$D/meta.json" '(m["since"], m["delta_files"])')" = "('$A0', ['f.py', 'tests/test_f.py'])" ] && [ "$(calls)" = $((C0 + 1)) ] \
  && ok "--delta accepted: since, both files, one model call" || { bad "delta rc=$RC: $(mj "$D/meta.json" '(m.get("since"), m.get("delta_files"))')"; tail -3 "$T/out.txt"; }
P="$D/prompt.txt"
grep -q "^Changed since the last reviewed head ${A0:0:8}" "$P" && grep -q '^+    a = 10$' "$P" && grep -q '^     return a$' "$P" \
  && ok "delta prompt: the fix diff carries the touched function as context" || bad "function context: $(grep -n '^[-+ @]' "$P" | head -20)"
! grep -q '^+    return 3$' "$P" && ! grep -q '^-    return 2$' "$P" \
  && ok "delta prompt: no full PR change of the touched file" || bad "full PR change still in the delta prompt"
grep -qE "^Full PR change of a file, when the function context is not enough: git diff [0-9a-f]{40}\.\.\.${A1} -- <file>$" "$P" \
  && ok "delta prompt: names the command for a file's full PR change" || bad "no full-change pointer: $(grep -n 'Full PR' "$P")"

echo "== only a fix that rewrites most of an existing file needs a full review"
newpr 22 "printf 'x = 3\n' > a.py"; B0=$(headn 22); review 22
pushn 22 "sed -i.bak '1,40s/= 0/= 1/' r.py && rm r.py.bak; python3 $T/gen.py n.py 100 n"
C0=$(calls); delta 22
[ $RC -eq 2 ] && has "delta review not sufficient for PR 22: r.py rewritten since ${B0:0:8} (40+/40- of 60 lines); run a full review" \
  && [ "$(calls)" = "$C0" ] && ok "--delta: 40 of 60 lines rewritten -> exit 2, names the file, no model call" || { bad "rewrite rc=$RC"; tail -3 "$T/out.txt"; }
newpr 23 "printf 'x = 5\n' > a.py"; review 23
pushn 23 "sed -i.bak '1,15s/= 0/= 2/' r.py && rm r.py.bak; printf 'u1 = 1\nu2 = 2\nu3 = 3\n' > t.py; python3 $T/gen.py n.py 100 n"
delta 23
[ $RC -eq 0 ] && [ "$(mj "$RD/meta.json" 'm["delta_files"]')" = "['n.py', 'r.py', 't.py']" ] \
  && ok "--delta accepts 15 of 60 lines, a fully changed 3-line file and a new file" || { bad "small edits rc=$RC"; tail -3 "$T/out.txt"; }
newpr 37 "printf 'int a;\n' > m.c"; review 37
pushn 37 "printf 'int a;  /* why */\n' > m.c; printf 'int b;\n' > n.c"; delta 37
[ $RC -eq 0 ] && ! has "Traceback" && ok "--delta: a fix that adds a new C file and comments an old one: no crash" || { bad "new file rc=$RC"; tail -3 "$T/out.txt"; }

echo "== function context falls back to 10 lines; an oversized fix still refuses"
newpr 30 "python3 $T/gen.py big.py 2000 v; printf 's = 1\n' > s.py"; review 30
pushn 30 "sed -i.bak 's/^v_1999 = 0/v_1999 = 1/' big.py && rm big.py.bak"; delta 30; P="$RD/prompt.txt"
[ $RC -eq 0 ] && grep -q '^+v_1999 = 1$' "$P" && grep -q '^ v_1989 = 0$' "$P" && ! grep -q 'v_0000' "$P" \
  && grep -q '^\[function context of big.py over 12,000 chars; 10 lines of context shown\]$' "$P" \
  && ok "--delta: function context over 12,000 chars -> 10 lines of context, marked" || { bad "fallback rc=$RC: $(grep -n 'function context\|^@@' "$P" | head)"; tail -3 "$T/out.txt"; }
pushn 30 "python3 $T/gen.py huge.py 30000 h"; delta 30
[ $RC -eq 2 ] && has "fix diff since" && has "over the 300,000 cap; run a full review" \
  && ok "--delta: a fix diff over the cap refuses (exit 2)" || { bad "huge fix rc=$RC"; tail -3 "$T/out.txt"; }

echo "== the 12,000-char cap is on a file's function context, not on the file; C/C++ use the cpp driver"
cat > "$T/genfn.py" <<'EOF'
import sys
n, k = sys.argv[1], int(sys.argv[2])
fn = lambda i: "def fn_%d(x):\n%s    return v15\n" % (i, "".join("    v%d = x + %d\n" % (j, j) for j in range(16)))
open(n, "w").write("\n\n".join(fn(i) for i in range(k)))
EOF
newpr 31 "python3 $T/genfn.py p.py 45"; review 31
pushn 31 "sed -i.bak '116s/= x + 14$/= x + 140/' p.py && rm p.py.bak"; delta 31; P="$RD/prompt.txt"
[ $RC -eq 0 ] && grep -q '^+    v14 = x + 140$' "$P" && grep -q '^ def fn_5(x):$' "$P" && ! grep -q '^ def fn_4(x):$' "$P" \
  && ! grep -q 'function context of p.py' "$P" \
  && ok "--delta: a 12,723-char file with a small touched function keeps -W, no marker" || { bad "big file -W rc=$RC: $(grep -n 'function context\|^@@' "$P" | head)"; tail -3 "$T/out.txt"; }
newpr 32 "printf 'int f(int x)\n{\n  int y = 0;\nretry:\n  y++;\n  if (y < x) goto retry;\n  return y;\n}\n' > m.c"; review 32
pushn 32 "sed -i.bak 's/  return y;/  return y + 1;/' m.c && rm m.c.bak"; delta 32; P="$RD/prompt.txt"
[ $RC -eq 0 ] && grep -q '^+  return y + 1;$' "$P" && grep -q '^ int f(int x)$' "$P" \
  && ok "--delta: a C function with a label keeps its signature as context (diff=cpp)" || { bad "cpp driver rc=$RC: $(grep -n '^[-+ @]' "$P" | head -12)"; tail -3 "$T/out.txt"; }

echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
