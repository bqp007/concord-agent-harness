#!/bin/bash
# concord.py delta reviews: `--review-pr N --delta` reviews only the fix (the delta with function context, the open
# findings and the hunks, numbered) and a cheap delta can close a finding and cover a file. A finding closes only by a
# resolution (fixed yes, with evidence) of a review of a later head; a hunk is covered only when it is explained by a
# finding the same answer closes (closure follows the finding, not the file). No network: fake gh, bare origin, fake qwen.
# Run: bash ~/.claude/concord/tests/delta_test.sh   (exit 0 = all passed).
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/delta-test.XXXXXX")" && pwd -P)"; export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/concord" "$T/home/.claude"
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
cat > "$T/bin/qwen" <<'EOF'
#!/bin/sh
echo ran >> "$T/qwen_calls"; printf '%s\n' "$1" > "$T/last_prompt.txt"
if [ -n "${FAKE_ACTIONS:-}" ]; then sh -c "$FAKE_ACTIONS"; exit 0; fi
if [ -n "${FAKE_GARBAGE:-}" ]; then echo 'not a review'; exit 0; fi
if [ -n "${FAKE_CLEAN:-}" ]; then printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n'; exit 0; fi
printf 'REVIEW-JSON\n{"findings": [{"severity": "%s", "path": "%s",' "${FAKE_SEV:-HIGH}" "${FAKE_PATH:-a.py}"
printf ' "line": 1, "problem": "wrong constant", "fix": "use 2", "repro": {"input": "x", "expected": "2", "actual": "1"}}], "clauses": [], "tests": [], "verdict": "FIX"}\nEND-REVIEW-JSON\n'
EOF
cat > "$T/bin/gh" <<'EOF'
#!/bin/sh
[ "$1" = pr ] && [ "$2" = view ] || exit 1
n=$(printf '%s' "$3" | sed -E 's|.*/pull/||; s|.*#||')
[ -f "$T/pr$n.json" ] && cat "$T/pr$n.json" && exit 0
echo "no pull requests found for $3" >&2; exit 1
EOF
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
calls(){ [ -f "$T/qwen_calls" ] && wc -l < "$T/qwen_calls" | tr -d ' ' || echo 0; }
rid(){ sed -n 's/^PR REVIEW \([^ ]*\).*/\1/p' "$T/out.txt" | head -1; }
mj(){ python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"m": m}))' "$1" "$2" 2>&1; }
headn(){ git -C "$O" rev-parse "refs/pull/$1/head"; }
prjson(){ printf '{"baseRefName": "main", "headRefName": "pr%s", "headRefOid": "%s", "title": "t", "body": "b"}\n' "$1" "$(headn "$1")" > "$T/pr$1.json"; }
st(){ $DP --pr-status "$1" --repo "$R" > "$T/out.txt" 2>&1; RC=$?; }
pushn(){ # pushn N 'shell' : commit a change on top of the PR N head and push it as the new head
  ( set -e; cd "$R"; git fetch -q origin "refs/pull/$1/head"; git checkout -q FETCH_HEAD; sh -c "$2"; git add -A; git commit -qm fix
    git push -q origin "HEAD:refs/pull/$1/head"; git checkout -q main ) || { echo "setup failed: pushn $1"; exit 1; }
  prjson "$1"; }
newpr(){ # newpr N 'shell' : a PR N branch off main with the given change
  ( set -e; cd "$R"; git checkout -q main; git checkout -qb "pr$1"; sh -c "$2"; git add -A; git commit -qm "pr$1"
    git push -qf origin "HEAD:refs/pull/$1/head"; git checkout -q main; git branch -qD "pr$1" ) || { echo "setup failed: newpr $1"; exit 1; }
  prjson "$1"; }
# opus N TIER NAME ANSWER [ARGS]: an Opus packet (ARGS: --files, --delta, ...) answered with ANSWER and recorded as NAME
opus(){ local n=$1 t=$2 name=$3 ans=$4; shift 4
  $DP --review-pr "$n" --packet --tier "$t" "$@" --repo "$R" > "$T/out.txt" 2>&1
  PK=$(sed -n 's/^PACKET \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
  [ -n "$PK" ] || { echo "    (no packet for PR $n: $(tail -1 "$T/out.txt"))"; return 1; }
  cp "$ans" "$T/ans.txt"; sign "$T/ans.txt" "$PK"
  $DP --review-record "$(basename "$(dirname "$PK")")" --reviewer "$name" --file "$T/ans.txt" --repo "$R" > "$T/rec.txt" 2>&1; }
review(){ # review N [env...] : a full review of PR N at tier medium by the fake reviewer; sets RC and RD (its run dir)
  n=$1; shift; env "$@" $DP --review-pr "$n" --via qwen --model fake/m --tier medium --repo "$R" > "$T/out.txt" 2>&1; RC=$?; RD="$RUNS/$(rid)"; }
CLEAN='REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n'
printf '%b' "$CLEAN" > "$T/clean.txt"
# hfinding PATH LINE... : a HIGH finding answer holding the given (path line problem) triples
hfinding(){ python3 -I -c '
import json, sys
a = sys.argv[2:]; f = [{"severity": "HIGH", "path": a[i], "line": int(a[i + 1]), "problem": a[i + 2], "fix": "fix it",
                        "repro": {"input": "in", "expected": "exp", "actual": "act"}} for i in range(0, len(a), 3)]
open(sys.argv[1], "w").write("REVIEW-JSON\n" + json.dumps({"findings": f, "clauses": [], "tests": [], "verdict": "FIX"}) + "\nEND-REVIEW-JSON\n")' "$@"; }
# dans FILE RESOLUTIONS HUNKS: a clean delta answer with the given resolutions and hunks (JSON)
dans(){ printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN", "resolutions": %s, "hunks": %s}\nEND-REVIEW-JSON\n' "$2" "$3" > "$1"; }
git init -q --bare -b main "$O" && git clone -q "$O" "$R" 2> /dev/null || { echo "setup failed: repos"; exit 1; }
( set -e; cd "$R" && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > a.py; printf 'q = 1\n' > b.py; printf '.claude/\n' > .gitignore; git add -A && git commit -qm init && git push -q origin main ) || { echo "setup failed: main"; exit 1; }

echo "== a delta of a fix commit: meta, prompt, packet"
newpr 7 "printf 'x = 2\n' > a.py; printf 'c = 3\n' > c.py"; H0=$(headn 7)
opus 7 medium concord:reviewer-opus55 "$T/clean.txt" || { echo "setup failed: full review"; cat "$T/out.txt"; exit 1; }
pushn 7 "printf 'x = 3\n' > a.py"; H1=$(headn 7)
C0=$(calls)
FAKE_CLEAN=1 $DP --review-pr 7 --delta --via qwen --model fake/m --tier medium --repo "$R" > "$T/out.txt" 2>&1; RC=$?; D1="$RUNS/$(rid)"
[ $RC -eq 0 ] && [ "$(mj "$D1/meta.json" '(m["since"], m["delta_files"], m["head"])')" = "('$H0', ['a.py'], '$H1')" ] \
  && [ "$(calls)" = $((C0 + 1)) ] \
  && ok "--delta: meta carries since/delta_files, one model call" || { bad "delta rc=$RC: $(mj "$D1/meta.json" 'm' 2>&1 | head -c 300)"; tail -3 "$T/out.txt"; }
P="$D1/prompt.txt"
grep -q "^Delta review since ${H0:0:8}: files a.py$" "$P" && grep -q "^diff --git a/a.py" "$P" && ! grep -q "^diff --git a/c.py" "$P" && grep -q "^+x = 3$" "$P" \
  && ok "delta prompt: delta line, fix-commit diff, only the touched file" || bad "delta prompt: $(grep -n 'Delta\|^diff --git' "$P" | head)"
$DP --review-pr 7 --delta --packet --repo "$R" > "$T/out.txt" 2>&1; RC=$?; PK=$(sed -n 's/^PACKET \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
[ $RC -eq 0 ] && [ -f "$PK" ] && grep -q "^Delta review since ${H0:0:8}: files a.py$" "$PK" \
  && ok "--delta --packet writes a delta packet for an Opus reviewer" || { bad "delta packet rc=$RC"; tail -2 "$T/out.txt"; }
grep -qE '^H1\b' "$PK" && grep -qF '"hunks"' "$PK" && grep -qF "packet_sha" "$PK" \
  && ok "the delta packet numbers its hunks (H1 ...) and its review task states the hunks and packet_sha answer fields" || bad "delta packet: no numbered hunk or answer fields"
opus 7 medium concord:reviewer-opus55 "$T/clean.txt"; $DP --review-pr 7 --delta --packet --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 2 ] && has "nothing changed since" && ok "--delta with nothing changed since the reviewed head: exit 2" || { bad "no-change delta rc=$RC"; tail -2 "$T/out.txt"; }
pushn 7 "printf 'x = 6\n' > a.py"
for flt in "--files a.py" "--exclude c.py"; do
  $DP --review-pr 7 --delta --packet $flt --repo "$R" > "$T/out.txt" 2>&1; RC=$?
  [ $RC -eq 2 ] && has "--delta cannot be combined with --files/--exclude" && ok "--delta with $flt: exit 2 (a delta covers every changed file)" || { bad "--delta $flt rc=$RC"; tail -2 "$T/out.txt"; }
done
( set -e; cd "$R"; git checkout -q main; git checkout -qb pr7r; printf 'x = 9\n' > a.py; git add -A; git commit -qm rebuilt
  git push -qf origin HEAD:refs/pull/7/head; git checkout -q main; git branch -qD pr7r ) || { echo "setup failed: rebuild"; exit 1; }
prjson 7; $DP --review-pr 7 --delta --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 2 ] && has "no reviewed ancestor" && ok "--delta on a rebuilt branch (no reviewed ancestor): exit 2" || { bad "rebuilt delta rc=$RC"; tail -2 "$T/out.txt"; }

echo "== the delta prompt keeps no color codes, a quoted file name and a pathspec-looking file name"
newpr 13 "printf 't = 1\n' > 'q\"t.py'"; opus 13 medium concord:reviewer-opus55 "$T/clean.txt"
pushn 13 "printf 't = 2\n' > 'q\"t.py'"
git -C "$R" config color.diff always; git -C "$R" config color.ui always
FAKE_CLEAN=1 $DP --review-pr 13 --delta --via qwen --model fake/m --tier medium --repo "$R" > "$T/out.txt" 2>&1; RC=$?; D13="$RUNS/$(rid)"
git -C "$R" config --unset color.diff; git -C "$R" config --unset color.ui
[ $RC -eq 0 ] && ! grep -q "$(printf '\033')" "$D13/prompt.txt" && grep -q '^+t = 2$' "$D13/prompt.txt" \
  && ok "delta: a file name with a double quote keeps its diff and the prompt has no color codes under color.ui=always" || { bad "quoted name or color rc=$RC"; tail -2 "$T/out.txt"; }
newpr 17 "printf 'evil = 1\n' > ':(top)a.py'"; review 17 FAKE_CLEAN=1
grep -q '^+evil = 1$' "$RD/prompt.txt" && ok "a PR file named ':(top)a.py' is diffed literally (no pathspec magic)" || bad "pathspec magic hid a file from the review"
opus 17 medium concord:reviewer-opus55 "$T/clean.txt"; st 17
[ $RC -eq 0 ] || { echo "setup failed: PR 17 is not REVIEWED after a clean Opus review"; cat "$T/out.txt"; exit 1; }
pushn 17 "printf 'evil = 2\n' > ':(top)a.py'"; st 17
has "UNREVIEWED" && grep -qF '  :(top)a.py: needs medium' "$T/out.txt" && [ $RC -eq 1 ] \
  && ok "a file named ':(top)a.py' changed after its reviewed head needs a new review (no pathspec magic carries coverage)" || { bad "pathspec magic carried coverage to a changed file rc=$RC"; tail -3 "$T/out.txt"; }

echo "== a finding path is stored without ./ so a resolution finds the file"
newpr 18 "printf 'w = 1\n' > w2.py"; review 18 FAKE_PATH=./w2.py
[ "$(mj "$RUNS/ledger/pr18.json" '[f["path"] for f in m["findings"]]')" = "['w2.py']" ] && ok "a finding reported as ./w2.py is stored as w2.py" || bad "./ path: $(mj "$RUNS/ledger/pr18.json" '[f["path"] for f in m["findings"]]')"

echo "== a delta closes a finding only by a resolution; a hunk is covered only when a closed finding explains it"
# s23 N: PR N holds a.py with one policy() line; an opus55 review at the first head opens F1 on it; the fix changes the line as the caller says
s23(){ n=$1; to=$2
  newpr "$n" "printf 'policy(retries=2, timeout=10)\n' > a.py"; hfinding "$T/f1.txt" a.py 1 "retries too low"
  opus "$n" medium concord:reviewer-opus55 "$T/f1.txt" || { echo "setup failed: PR $n review"; cat "$T/out.txt"; exit 1; }
  st "$n"; has "FINDINGS OPEN" || { echo "setup failed: PR $n has no open finding"; cat "$T/out.txt"; exit 1; }
  pushn "$n" "printf '%s\n' '$to' > a.py"; }
YES='[{"finding": "F1", "fixed": "yes", "evidence": "a.py:1 retries is now 3"}]'
s23 81 'policy(retries=3, timeout=60)'
dans "$T/d.txt" "$YES" '[{"hunk": "H1", "explained_by": "", "change": "timeout 10 to 60"}]'; opus 81 medium reviewer-delta "$T/d.txt" --delta; st 81
has "UNREVIEWED" && has "a.py" && ! has "FINDINGS OPEN" && [ $RC -eq 1 ] \
  && ok "same-line delta (retries=2 -> 3 and timeout 10 -> 60): F1 closes, the hunk is unexplained, a.py stays uncovered (UNREVIEWED, no open finding)" || { bad "unexplained hunk rc=$RC"; tail -4 "$T/out.txt"; }
s23 82 'policy(retries=3, timeout=60)'
dans "$T/d.txt" "$YES" '[]'; opus 82 medium reviewer-delta "$T/d.txt" --delta; st 82
has "UNREVIEWED" && has "a.py" && ! has "FINDINGS OPEN" && [ $RC -eq 1 ] \
  && ok "an answer that omits the hunk: F1 closes, the file stays uncovered" || { bad "omitted hunk rc=$RC"; tail -4 "$T/out.txt"; }
s23 83 'policy(retries=3, timeout=60)'
dans "$T/d.txt" '[]' '[{"hunk": "H1", "explained_by": "F1"}]'; opus 83 medium reviewer-delta "$T/d.txt" --delta; st 83
has "FINDINGS OPEN" && has "F1" && grep -qF '  a.py: needs medium' "$T/out.txt" && ! has "a.py: medium by" && [ $RC -eq 1 ] \
  && ok "no resolution for F1: it stays open, and a hunk naming it is unexplained (a.py needs medium)" || { bad "missing resolution rc=$RC"; tail -4 "$T/out.txt"; }
s23 84 'policy(retries=3, timeout=60)'
dans "$T/d.txt" '[{"finding": "F1", "fixed": "yes", "evidence": "a.py:1 ok"}, {"finding": "F1", "fixed": "no", "evidence": "a.py:1 still 3 but timeout moved"}]' '[]'; opus 84 medium reviewer-delta "$T/d.txt" --delta; st 84
has "FINDINGS OPEN" && has "F1" && [ $RC -eq 1 ] && ok "two resolutions of F1 that disagree: F1 stays open" || { bad "disagreeing resolutions rc=$RC"; tail -4 "$T/out.txt"; }
s23 85 'policy(retries=3, timeout=60)'
dans "$T/d.txt" '[{"finding": "F1", "fixed": "unsure", "evidence": "a.py:1 maybe"}]' '[]'; opus 85 medium reviewer-delta "$T/d.txt" --delta; st 85
has "FINDINGS OPEN" && has "F1" && [ $RC -eq 1 ] && ok "an unsure resolution leaves F1 open" || { bad "unsure rc=$RC"; tail -4 "$T/out.txt"; }
s23 86 'policy(retries=2, timeout=10) # x'
dans "$T/d.txt" '[{"finding": "F1", "fixed": "yes", "evidence": ""}]' '[]'; opus 86 medium reviewer-delta "$T/d.txt" --delta; st 86
has "FINDINGS OPEN" && has "F1" && [ $RC -eq 1 ] && ok "a resolution with empty evidence leaves F1 open" || { bad "empty evidence rc=$RC"; tail -4 "$T/out.txt"; }
s23 87 'policy(retries=3, timeout=10)'
dans "$T/d.txt" "$YES" '[{"hunk": "H1", "explained_by": "F1"}]'; opus 87 medium reviewer-delta "$T/d.txt" --delta; st 87
has "REVIEWED at" && ! has "UNREVIEWED" && ! has "FINDINGS OPEN" && [ $RC -eq 0 ] \
  && ok "a fix that changes only retries: F1 closes, the hunk is explained by it, the file is covered (REVIEWED, exit 0)" || { bad "explained hunk rc=$RC"; tail -4 "$T/out.txt"; }

echo "== a cheap delta closes F1 and leaves F2 open; a later full review covers the file but closes nothing"
newpr 88 "printf 'retries = 2\ntimeout = 10\n' > f.py; printf 'g = 1\n' > g.py"
hfinding "$T/f12.txt" f.py 1 "retries too low" f.py 2 "timeout too short"
opus 88 medium concord:reviewer-opus55 "$T/f12.txt" || { echo "setup failed: PR 88 review"; cat "$T/out.txt"; exit 1; }
pushn 88 "printf 'retries = 3\ntimeout = 99\n' > f.py"
dans "$T/d.txt" '[{"finding": "F1", "fixed": "yes", "evidence": "f.py:1 retries is 3"}]' '[{"hunk": "H1", "explained_by": "", "change": "retries 2 to 3 and timeout 10 to 99"}]'
opus 88 medium reviewer-delta "$T/d.txt" --delta; opus 88 medium concord:reviewer-opus55 "$T/clean.txt" --files f.py; st 88
has "FINDINGS OPEN" && has "F2" && ! grep "FINDINGS OPEN" "$T/out.txt" | grep -q "F1" && [ $RC -eq 1 ] \
  && ok "F1 stays closed, F2 is open, and the later review of f.py (same head) resolves neither" || { bad "two findings rc=$RC"; tail -5 "$T/out.txt"; }
grep -qE '^  f\.py: medium by reviewer-opus55$' "$T/out.txt" \
  && ok "the status lines say the later review of f.py covers f.py at its tier, by its reviewer" || { bad "f.py coverage line"; cat "$T/out.txt"; }

echo "== the fix block is the whole delta context; a rewrite needs a full review"
printf '%s\n' "open('big.py', 'w').write(''.join('v_%04d = %r\\n' % (i, 'x' * 30) for i in range(2000)))" > "$T/gen.py"
newpr 9 "python3 $T/gen.py; printf 's = 1\\n' > s.py"; Q0=$(headn 9)
opus 9 medium concord:reviewer-opus55 "$T/clean.txt" || { echo "setup failed: PR 9 review"; cat "$T/out.txt"; exit 1; }
pushn 9 "sed -i.bak 's/^v_1999 = .*/v_1999 = 0/' big.py && rm big.py.bak"; Q1=$(headn 9)
FAKE_CLEAN=1 $DP --review-pr 9 --delta --dry-run --via qwen --model fake/m --tier medium --repo "$R" > "$T/out.txt" 2>&1; RC=$?
DR=$(sed -n 's/^DRY RUN PR REVIEW \([^:]*\):.*/\1/p' "$T/out.txt" | head -1)
SP=$(grep -l "^Changed since the last reviewed head ${Q0:0:8}" "$RUNS/$DR/prompt.txt" 2> /dev/null | head -1)
if [ $RC -eq 0 ] && [ -n "$SP" ] && grep -q "^+v_1999 = 0$" "$SP"; then
  LC=$(grep -n "^Changed since the last reviewed head" "$SP" | head -1 | cut -d: -f1); LD=$(grep -n "^diff --git a/big.py" "$SP" | head -1 | cut -d: -f1)
  [ "$LC" -lt "$LD" ] && ! grep -q "truncated at the cap" "$SP" && [ "$(grep -c '^diff --git a/big.py' "$SP")" = 1 ] && grep -qE '^H1 big.py @@' "$SP" \
    && ok "big PR file: one prompt, the fix block alone with its numbered hunk, no full-change context" || bad "full-change context in the delta prompt ($LC >= $LD)"
else bad "fix block lost over the cap rc=$RC prompt=${SP:-none}"; tail -3 "$T/out.txt"; fi
$DP --review-pr 9 --delta --packet --repo "$R" > "$T/out.txt" 2>&1; RC=$?
PK=$(sed -n 's/^PACKET \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
[ $RC -eq 0 ] && [ -f "$PK" ] && grep -q "^+v_1999 = 0$" "$PK" && ! grep -q "truncated at the cap" "$PK" \
  && ok "--delta --packet on a big PR file: packet written, fix block whole" || { bad "delta packet cap rc=$RC"; tail -3 "$T/out.txt"; }
pushn 9 "sed -i.bak 's/x/y/g' big.py && rm big.py.bak"
FAKE_CLEAN=1 $DP --review-pr 9 --delta --via qwen --model fake/m --tier medium --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 2 ] && has "big.py rewritten since ${Q0:0:8} (2000+/2000- of 2000 lines); run a full review" && ok "every line of big.py rewritten: --delta refuses (exit 2)" || { bad "rewrite rc=$RC"; tail -3 "$T/out.txt"; }

echo "== a delta chain: a delta that raises a new HIGH, then a delta that resolves it"
# dfind FILE RESOLUTIONS HUNKS PATH LINE PROBLEM: a delta answer that resolves and explains as given and raises one HIGH
dfind(){ python3 -I -c '
import json, sys
f, res, hk, path, line, prob = sys.argv[1:7]
a = {"findings": [{"severity": "HIGH", "path": path, "line": int(line), "problem": prob, "fix": "fix it", "repro": {"input": "in", "expected": "exp", "actual": "act"}}],
     "clauses": [], "tests": [], "verdict": "FIX", "resolutions": json.loads(res), "hunks": json.loads(hk)}
open(f, "w").write("REVIEW-JSON\n" + json.dumps(a) + "\nEND-REVIEW-JSON\n")' "$@"; }
newpr 91 "printf 'policy(retries=2)\n' > a.py"; hfinding "$T/f1.txt" a.py 1 "retries too low"
opus 91 medium concord:reviewer-opus55 "$T/f1.txt" || { echo "setup failed: PR 91 review"; cat "$T/out.txt"; exit 1; }
pushn 91 "printf 'policy(retries=3)\n' > a.py"
dfind "$T/d.txt" '[{"finding": "F1", "fixed": "yes", "evidence": "a.py:1 retries is 3"}]' '[{"hunk": "H1", "explained_by": "F1"}]' a.py 1 "no timeout at all"
opus 91 medium reviewer-delta "$T/d.txt" --delta; st 91
has "FINDINGS OPEN" && has "F2" && ! grep "FINDINGS OPEN" "$T/out.txt" | grep -q "F1" && [ $RC -eq 1 ] \
  && ok "a delta answer that closes F1 and raises a new HIGH: FINDINGS OPEN naming the new finding (F2), not F1" || { bad "new HIGH in a delta rc=$RC"; tail -4 "$T/out.txt"; }
pushn 91 "printf 'policy(retries=3, timeout=30)\n' > a.py"
dans "$T/d.txt" '[{"finding": "F2", "fixed": "yes", "evidence": "a.py:1 the timeout is 30"}]' '[{"hunk": "H1", "explained_by": "F2"}]'
opus 91 medium reviewer-delta "$T/d.txt" --delta; st 91
has "REVIEWED at" && ! has "UNREVIEWED" && ! has "FINDINGS OPEN" && [ $RC -eq 0 ] \
  && ok "full review at H0, a delta at H1 and a delta at H2, each explaining every hunk by a finding it closes: REVIEWED at H2 (exit 0)" || { bad "delta chain rc=$RC"; tail -4 "$T/out.txt"; }

echo "== a delta covers only what its answer explains: a file uncovered at H0 stays uncovered; a hunk listed twice is unexplained; hunks split on header lines only"
newpr 93 "printf 'x = 2\n' > a.py; printf 'q = 2 # not read by the first review\n' > b.py"
hfinding "$T/f93.txt" a.py 1 "x must be 3"
opus 93 medium concord:reviewer-opus55 "$T/f93.txt" --files a.py || { echo "setup failed: PR 93 review"; cat "$T/out.txt"; exit 1; }
pushn 93 "printf 'x = 3\n' > a.py; printf 'q = 3 # still not read\n' > b.py"
dans "$T/d.txt" '[{"finding": "F1", "fixed": "yes", "evidence": "a.py:1 x is 3"}]' '[{"hunk": "H1", "explained_by": "F1"}, {"hunk": "H2", "explained_by": "F1"}]'
opus 93 medium reviewer-delta "$T/d.txt" --delta; st 93
grep -qE '^  b\.py: needs medium$' "$T/out.txt" && [ $RC -eq 1 ] \
  && ok "a file that was in the PR at H0 and that no review read stays uncovered after a delta that explains its hunk" || { bad "b.py covered by a delta rc=$RC"; cat "$T/out.txt"; }
s23 94 'policy(retries=3, timeout=60)'
dans "$T/d.txt" "$YES" '[{"hunk": "H1", "explained_by": "F1"}, {"hunk": "H1", "explained_by": "", "change": "timeout 10 to 60"}]'; opus 94 medium reviewer-delta "$T/d.txt" --delta; st 94
has "UNREVIEWED" && has "a.py" && ! has "REVIEWED at" && [ $RC -eq 1 ] \
  && ok "a hunk listed twice (once explained by F1, once unexplained) is unexplained: the file stays uncovered" || { bad "double-listed hunk rc=$RC"; tail -4 "$T/out.txt"; }
cat > "$T/gen_h.py" <<'PY'
import codecs, sys
fix, other = codecs.decode(sys.argv[1], "unicode_escape"), sys.argv[2]      # \f and \r in the argument are the control characters
lines = ["def f():", f"    s = '{fix}'", "    return s", ""] + ["def h():"] + [f"    v{i} = {i}" for i in range(30)] + ["    return 0", ""]
lines += ["def g():", f"    t = {other}", "    return t", ""]
open("h.py", "w", newline="").write("\n".join(lines))
PY
# a changed line holding the text of a file header, alone, after a form feed and after a lone CR: both hunks of the fix are numbered,
# and an answer that explains only H1 leaves the file uncovered
for spec in "95|diff --git a/x b/x|the text 'diff --git a/x b/x'" "96|\\fdiff --git a/x b/x|a form feed and then 'diff --git a/x b/x'" "97|\\rdiff --git a/x b/x|a lone CR and then 'diff --git a/x b/x'"; do
  n=${spec%%|*}; rest=${spec#*|}; txt=${rest%%|*}; label=${rest#*|}
  newpr "$n" "python3 $T/gen_h.py old 1"; hfinding "$T/f$n.txt" h.py 2 "s must be changed"
  opus "$n" medium concord:reviewer-opus55 "$T/f$n.txt" || { echo "setup failed: PR $n review"; cat "$T/out.txt"; exit 1; }
  pushn "$n" "python3 $T/gen_h.py '$txt' 999"
  $DP --review-pr "$n" --delta --packet --repo "$R" > "$T/out.txt" 2>&1; PK=$(sed -n 's/^PACKET \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
  [ -f "$PK" ] && [ "$(mj "$(dirname "$PK")/meta.json" 'sorted(m["hunks"])')" = "['H1', 'H2']" ] \
    && ok "a changed line that holds $label does not split the fix block: both hunks are numbered" || { bad "hunks numbered for $label: $(mj "$(dirname "$PK")/meta.json" 'sorted(m["hunks"])' 2>&1 | head -c 200)"; }
  dans "$T/dh.txt" '[{"finding": "F1", "fixed": "yes", "evidence": "h.py:2 s is changed"}]' '[{"hunk": "H1", "explained_by": "F1"}]'
  if [ -f "$PK" ]; then sign "$T/dh.txt" "$PK"; $DP --review-record "$(basename "$(dirname "$PK")")" --reviewer reviewer-delta --file "$T/dh.txt" --repo "$R" > "$T/rec.txt" 2>&1; fi
  st "$n"
  has "UNREVIEWED" && ! has "REVIEWED at" && [ $RC -eq 1 ] \
    && ok "an answer that explains only H1 stays UNREVIEWED (exit 1) for $label" || { bad "H1-only answer for $label rc=$RC"; tail -3 "$T/out.txt"; }
done

echo "== a delta that deletes a file shows its removed lines"
newpr 98 "printf 'k = 1\n' > keep.py; printf 'g = 1\ng2 = 2\n' > gone.py"; opus 98 medium concord:reviewer-opus55 "$T/clean.txt" || { echo "setup failed: PR 98 review"; cat "$T/out.txt"; exit 1; }
pushn 98 "git rm -q gone.py; printf 'k = 2\n' > keep.py"
$DP --review-pr 98 --delta --packet --repo "$R" > "$T/out.txt" 2>&1; RC=$?; PK=$(sed -n 's/^PACKET \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
[ $RC -eq 0 ] && [ -f "$PK" ] && [ "$(mj "$(dirname "$PK")/meta.json" 'sorted(m["delta_files"])')" = "['gone.py', 'keep.py']" ] && grep -qxF '+k = 2' "$PK" \
  || { echo "setup failed: PR 98 delta packet rc=$RC"; tail -3 "$T/out.txt"; exit 1; }
grep -qx -- '-g = 1' "$PK" && grep -qx -- '-g2 = 2' "$PK" \
  && ok "the delta packet shows the lines a deleted file lost (the reviewer sees what was removed)" || bad "deleted file's lines missing from the delta packet: $(grep -n 'gone.py' "$PK" | head -3)"

echo "== a low-tier delta review is approve-only like a low-tier full review"
mkdir -p "$R/.claude"; printf '# Plan\n## Phase 1 - low run\nExecutor: deepseek-flash\nRisk: low\nPurpose: PLAN-MARK-99\nFiles: a.py\nAcceptance:\n- `true`\n' > "$R/.claude/PLAN_99.md"
( set -e; cd "$R"; git checkout -q main; git checkout -qb pr99 ) || { echo "setup failed: branch pr99"; exit 1; }
approve .claude/PLAN_99.md "$R" || exit 1
FAKE_ACTIONS='printf "x = 99\n" > a.py' $DP 1 --plan .claude/PLAN_99.md --via qwen --model fake/m --no-baseline --repo "$R" > "$T/out.txt" 2>&1
[ -n "$(sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)" ] || { echo "setup failed: run for PR 99"; cat "$T/out.txt"; exit 1; }
( set -e; cd "$R"; git add -A; git commit -qm "run 99"; git push -qf origin HEAD:refs/pull/99/head; git checkout -q main; git branch -qD pr99 ) || { echo "setup failed: commit 99"; exit 1; }
prjson 99; opus 99 low concord:reviewer-opus55 "$T/clean.txt" || { echo "setup failed: PR 99 low review"; cat "$T/out.txt"; exit 1; }
pushn 99 "printf 'x = 100\n' > a.py"
FAKE_SEV=MEDIUM FAKE_PATH=a.py $DP --review-pr 99 --delta --via qwen --model fake/m --tier low --repo "$R" > "$T/out.txt" 2>&1; RC=$?; RD="$RUNS/$(rid)"
[ $RC -eq 0 ] && [ "$(mj "$RD/meta.json" 'm["tier"]')" = low ] && [ -n "$(mj "$RD/meta.json" 'm.get("since") or ""')" ] \
  || { echo "setup failed: low-tier delta review rc=$RC"; tail -3 "$T/out.txt"; exit 1; }
REP=$(mj "$RD/meta.json" 'm["reviews"][-1]["report"]')
grep -qxF "VERDICT: CLEAN at low (BLOCKER and HIGH only)" "$REP" && grep -q 'wrong constant' "$REP" \
  && ok "a low-tier delta review's MEDIUM is kept as a note and the verdict reads CLEAN at low (BLOCKER and HIGH only)" || { bad "low-tier delta MEDIUM: verdict line or note missing"; cat "$REP"; }

echo "== a delta covers only a file that was covered at its base: a file new since H0 needs a review at its own tier"
newpr 100 "printf 'a = 1\n' > a.py; printf 'c = 1\n' > c.py"
hfinding "$T/f100.txt" a.py 1 "a must be 2" c.py 1 "c must be 2"
opus 100 medium concord:reviewer-opus55 "$T/f100.txt" || { echo "setup failed: PR 100 review"; cat "$T/out.txt"; exit 1; }
st 100; has "FINDINGS OPEN" && has "F1" && has "F2" || { echo "setup failed: PR 100 findings not open"; cat "$T/out.txt"; exit 1; }
pushn 100 "printf 'a = 2\n' > a.py; printf 'c = 2\n' > c.py; printf 'n = 1\n' > n.py"
dans "$T/d.txt" '[{"finding": "F1", "fixed": "yes", "evidence": "a.py:1 a is 2"}, {"finding": "F2", "fixed": "yes", "evidence": "c.py:1 c is 2"}]' \
  '[{"hunk": "H1", "explained_by": "F1"}, {"hunk": "H2", "explained_by": "F2"}, {"hunk": "H3", "explained_by": "F1"}]'
opus 100 medium reviewer-delta "$T/d.txt" --delta; st 100
has "FINDINGS OPEN" && { echo "setup failed: the delta did not close F1 and F2"; cat "$T/out.txt"; exit 1; }
grep -qE '^  n\.py: needs medium$' "$T/out.txt" && has "UNREVIEWED" && [ $RC -eq 1 ] \
  && ok "n.py, new in the fix commit with its hunk tied to a closed finding, stays 'needs medium' after the delta (UNREVIEWED, exit 1)" || { bad "new file covered by the delta rc=$RC"; cat "$T/out.txt"; }
grep -qE '^  a\.py: medium by ' "$T/out.txt" && grep -qE '^  c\.py: medium by ' "$T/out.txt" \
  && ok "a.py and c.py, covered at H0 with every hunk explained by a closed finding, stay covered" || { bad "files covered at H0 lost their coverage"; cat "$T/out.txt"; }
opus 100 medium concord:reviewer-opus55 "$T/clean.txt" --files n.py; st 100
grep -qE '^  n\.py: medium by reviewer-opus55$' "$T/out.txt" && has "REVIEWED at medium" && ! has "UNREVIEWED" && [ $RC -eq 0 ] \
  && ok "a review of n.py at medium covers it: REVIEWED at medium (exit 0)" || { bad "review of the new file rc=$RC"; cat "$T/out.txt"; }

echo "== a rename lists both paths; a head missing from this clone still gets a status; no temporary refs are left"
newpr 20 "printf 'q = 2\n' > b.py"; opus 20 medium concord:reviewer-opus55 "$T/clean.txt"
pushn 20 "git mv b.py bb.py"; st 20
grep -qE '^  b\.py: ' "$T/out.txt" && grep -qE '^  bb\.py: ' "$T/out.txt" \
  && ok "--no-renames: a rename lists the old and the new path, each with its own status line" || { bad "rename status lines"; cat "$T/out.txt"; }
newpr 14 "printf 'm = 14\n' > m14.py"
mkdir -p "$RUNS/pr14-deadbeef-gone"; printf 'VERDICT: CLEAN\n' > "$RUNS/pr14-deadbeef-gone/report.md"
printf '{"kind": "pr-review", "pr": 14, "head": "%s", "tier": "medium", "run_id": "pr14-deadbeef-gone", "reviews": [{"reviewer": "reviewer-opus55", "verdict": "CLEAN", "blockers": 0, "highs": 0, "report": "%s", "at": "2999-01-01T00:00:00+00:00"}]}\n' \
  "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$RUNS/pr14-deadbeef-gone/report.md" > "$RUNS/pr14-deadbeef-gone/meta.json"
st 14
has "UNREVIEWED" && ! has "Traceback" && [ $RC -eq 1 ] && ok "--pr-status: a reviewed head missing from this clone gets a status, no traceback, exit 1" || { bad "missing head rc=$RC"; cat "$T/out.txt"; }
[ -z "$(git -C "$R" for-each-ref refs/review/)" ] && ok "no temp refs left behind by status or delta reviews" || bad "refs left: $(git -C "$R" for-each-ref refs/review/)"

echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
