#!/bin/bash
# concord.py delta-review regression (2026-10-19, PLAN_kit-delta): after a fix commit, `--review-pr N --delta`
# reviews only the fix (the fix diff with function context + the ledger), and `--pr-status` carries the evidence
# of the previously reviewed head forward (2026-10-22, PLAN_kit-fixreview: whatever files the fix touches; only a
# file rewritten past half of its lines needs a full review). No network: fake gh, bare origin, fake qwen reviewer.
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
printf '%s\n' "open('big.py', 'w').write(''.join('v_%04d = %r\\n' % (i, 'x' * 30) for i in range(2000)))" > "$T/gen.py"
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
prjson(){ printf '{"baseRefName": "main", "headRefOid": "%s", "title": "t", "body": "b"}\n' "$2" > "$T/pr$1.json"; }
head7(){ git -C "$O" rev-parse refs/pull/7/head; }
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
  n=$1; shift; env "$@" $DP --review-pr "$n" --via qwen --model fake/m --user-approved "test go-ahead" --tier high --repo "$R" > "$T/out.txt" 2>&1; RC=$?; RD="$RUNS/$(rid)"; }
st(){ $DP --pr-status 7 --repo "$R" > "$T/out.txt" 2>&1; }
push7(){ # push7 'shell' : commit a change on top of the PR 7 head and push it as the new head
  ( set -e; cd "$R"; git fetch -q origin refs/pull/7/head; git checkout -q FETCH_HEAD; sh -c "$1"; git add -A; git commit -qm fix
    git push -q origin HEAD:refs/pull/7/head; git checkout -q main ) || { echo "setup failed: push7"; exit 1; }
  prjson 7 "$(head7)"; }
JCLEAN='REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n'
rec(){ printf '%b' "$JCLEAN" > "$T/rev.txt"; $DP --review-record "$1" --reviewer "$2" --file "$T/rev.txt" --repo "$R" > /dev/null 2>&1; }

git init -q --bare -b main "$O" && git clone -q "$O" "$R" 2> /dev/null || { echo "setup failed: repos"; exit 1; }
( set -e; cd "$R" && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > a.py; printf 'q = 1\n' > b.py; printf '.claude/\n' > .gitignore; git add -A && git commit -qm init && git push -q origin main
  git checkout -qb pr7; printf 'x = 2\n' > a.py; printf 'c = 3\n' > c.py; git add -A && git commit -qm pr7 && git push -q origin HEAD:refs/pull/7/head
  git checkout -q main; git branch -qD pr7 ) || { echo "setup failed: pr7"; exit 1; }
H0=$(head7); prjson 7 "$H0"

echo "== full review, then a fix commit"
$DP --review-pr 7 --via qwen --model fake/m --user-approved "test go-ahead" --tier high --repo "$R" > "$T/out.txt" 2>&1; RC=$?
D0="$RUNS/$(rid)"; FL=$(mj "$D0/meta.json" 'm["reviews"][-1]["reviewer"]')
[ $RC -eq 0 ] && [ -f "$RUNS/ledger/pr7.json" ] && ok "full review at H0 recorded; ledger pr7 has the finding on a.py" || { bad "full review rc=$RC"; tail -3 "$T/out.txt"; }
rec "$(basename "$D0")" "$FL"; st
has "CURRENT HEAD ${H0:0:8}: REVIEWED at high" && ok "H0 REVIEWED after the reviewer's clean follow-up" || { bad "H0 not reviewed"; cat "$T/out.txt"; }
push7 "printf 'x = 3\n' > a.py"; H1=$(head7); st
has "CURRENT HEAD ${H1:0:8}: UNREVIEWED (head moved; last reviewed ${H0:0:8}; changed since: a.py; delta review possible)" \
  && ok "--pr-status: head moved, names the last reviewed head and the changed file, offers a delta" || { bad "moved hint"; cat "$T/out.txt"; }

echo "== delta review"
C0=$(wc -l < "$T/qwen_calls" | tr -d ' ')
FAKE_CLEAN=1 $DP --review-pr 7 --delta --via qwen --model fake/m --user-approved "test go-ahead" --tier high --repo "$R" > "$T/out.txt" 2>&1; RC=$?
D1="$RUNS/$(rid)"
[ $RC -eq 0 ] && [ "$(mj "$D1/meta.json" '(m["since"], m["delta_files"], m["head"])')" = "('$H0', ['a.py'], '$H1')" ] \
  && [ "$(mj "$D1/meta.json" 'm["reviews"][-1]["since"]')" = "$H0" ] && [ "$(wc -l < "$T/qwen_calls" | tr -d ' ')" = $((C0 + 1)) ] \
  && ok "--delta: meta carries since/delta_files, one model call" || { bad "delta rc=$RC: $(mj "$D1/meta.json" 'm' 2>&1 | head -c 300)"; tail -3 "$T/out.txt"; }
P="$D1/prompt.txt"
grep -q "^Delta review since ${H0:0:8}: files a.py$" "$P" && grep -q "^Changed since the last reviewed head ${H0:0:8}" "$P" \
  && grep -q "^Review ledger pr7" "$P" && grep -q "^diff --git a/a.py" "$P" && ! grep -q "^diff --git a/c.py" "$P" && grep -q "^+x = 3$" "$P" \
  && ok "delta prompt: delta line, fix-commit diff, ledger, only the touched file" || bad "delta prompt: $(grep -n 'Delta\|Changed since\|^diff --git' "$P" | head)"
st; has "CURRENT HEAD ${H1:0:8}: REVIEWED at high (via delta from ${H0:0:8})" && ok "--pr-status: clean delta carries H0's evidence to H1" || { bad "carry"; cat "$T/out.txt"; }
has "since ${H0:0:8}" && ok "recorded review lines show the delta's since head" || bad "no since in listing"

echo "== chain, open delta, unreferenced file, rebase"
push7 "printf 'x = 4\n' > a.py"; H2=$(head7)
FAKE_CLEAN=1 $DP --review-pr 7 --delta --via qwen --model fake/m --user-approved "test go-ahead" --tier high --repo "$R" > "$T/out.txt" 2>&1; st
has "CURRENT HEAD ${H2:0:8}: REVIEWED at high (via delta from ${H1:0:8})" && ok "a chain of deltas carries the evidence" || { bad "chain"; cat "$T/out.txt"; }
push7 "printf 'x = 5\n' > a.py"; H3=$(head7)
$DP --review-pr 7 --delta --via qwen --model fake/m --user-approved "test go-ahead" --tier high --repo "$R" > "$T/out.txt" 2>&1; D3="$RUNS/$(rid)"; st
has "CURRENT HEAD ${H3:0:8}: FINDINGS OPEN ($FL: FIX, 1 HIGH)" && ok "a delta review with an open finding -> FINDINGS OPEN" || { bad "open delta"; cat "$T/out.txt"; }
rec "$(basename "$D3")" "$FL"; st
has "REVIEWED at high (via delta from ${H2:0:8})" && ok "clean follow-up on the delta head -> REVIEWED via the chain" || { bad "delta follow-up"; cat "$T/out.txt"; }
push7 "printf 'q = 2\n' > b.py"; H4=$(head7)
st; has "CURRENT HEAD ${H4:0:8}: UNREVIEWED (head moved; last reviewed ${H3:0:8}; changed since: b.py; delta review possible)" \
  && ok "--pr-status: a fix touching a file no finding references still allows a delta" || { bad "unreferenced hint"; cat "$T/out.txt"; }
FAKE_CLEAN=1 $DP --review-pr 7 --delta --via qwen --model fake/m --user-approved "test go-ahead" --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && ok "fix touching a file no finding references: --delta runs" || { bad "unreferenced rc=$RC"; tail -3 "$T/out.txt"; }
FAKE_CLEAN=1 $DP --review-pr 7 --via qwen --model fake/m --user-approved "test go-ahead" --tier medium --repo "$R" > "$T/out.txt" 2>&1; st
has "CURRENT HEAD ${H4:0:8}: REVIEWED at medium" && ! has "via delta" && ok "a full review at the new head is REVIEWED directly" || { bad "full after delta"; cat "$T/out.txt"; }
$DP --review-pr 7 --delta --packet --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 2 ] && has "nothing changed since" && ok "--delta with nothing changed since the reviewed head: exit 2" || { bad "no-change delta rc=$RC"; tail -2 "$T/out.txt"; }
push7 "printf 'x = 6\n' > a.py"; H5=$(head7)
$DP --review-pr 7 --delta --packet --repo "$R" > "$T/out.txt" 2>&1; RC=$?
PK=$(sed -n 's/^PACKET \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
[ $RC -eq 0 ] && [ -f "$PK" ] && grep -q "^Delta review since ${H4:0:8}: files a.py$" "$PK" && grep -q "^Review ledger pr7" "$PK" \
  && ok "--delta --packet writes a delta packet for an Opus reviewer" || { bad "delta packet rc=$RC"; tail -2 "$T/out.txt"; }
for flt in "--files a.py" "--exclude c.py"; do
  $DP --review-pr 7 --delta --packet $flt --repo "$R" > "$T/out.txt" 2>&1; RC=$?
  [ $RC -eq 2 ] && has "--delta cannot be combined with --files/--exclude" && ok "--delta with $flt: exit 2 (a delta covers every changed file)" \
    || { bad "--delta $flt rc=$RC"; tail -2 "$T/out.txt"; }
done
( set -e; cd "$R"; git checkout -q main; git checkout -qb pr7r; printf 'x = 9\n' > a.py; git add -A; git commit -qm rebuilt
  git push -qf origin HEAD:refs/pull/7/head; git checkout -q main; git branch -qD pr7r ) || { echo "setup failed: rebuild"; exit 1; }
H6=$(head7); prjson 7 "$H6"; st
has "CURRENT HEAD ${H6:0:8}: UNREVIEWED (head moved; no reviewed ancestor: full review needed)" \
  && ok "rebuilt branch (no reviewed ancestor): full review needed" || { bad "no ancestor hint"; cat "$T/out.txt"; }
$DP --review-pr 7 --delta --via qwen --model fake/m --user-approved "test go-ahead" --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 2 ] && has "no reviewed ancestor" && ok "--delta on a rebuilt branch: exit 2" || { bad "rebuilt delta rc=$RC"; tail -2 "$T/out.txt"; }
mkdir -p "$RUNS/pr7-deadbeef-gone"; printf 'VERDICT: CLEAN\n' > "$RUNS/pr7-deadbeef-gone/report.md"
printf '{"kind": "pr-review", "pr": 7, "head": "%s", "tier": "high", "run_id": "pr7-deadbeef-gone", "reviews": [{"reviewer": "reviewer-opus55", "verdict": "CLEAN", "blockers": 0, "highs": 0, "report": "%s", "at": "2999-01-01T00:00:00+00:00"}]}\n' \
  "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$RUNS/pr7-deadbeef-gone/report.md" > "$RUNS/pr7-deadbeef-gone/meta.json"
st; RC=$?
[ $RC -eq 0 ] && has "CURRENT HEAD ${H6:0:8}: UNREVIEWED (head moved; last reviewed deadbeef not available locally: full review needed)" \
  && ok "--pr-status: a reviewed head missing from this clone gets a status line, exit 0" || { bad "missing head rc=$RC"; cat "$T/out.txt"; }

echo "== an open head between the reviewed head and the fix is never skipped"
newpr 8 "printf 'x = 2\n' > a.py; printf 'z = 1\n' > z.py"; P0=$(headn 8)
review 8; rec "$(basename "$RD")" "$FL"; stn 8
has "CURRENT HEAD ${P0:0:8}: REVIEWED at high" || { bad "setup: P0 not reviewed"; cat "$T/out.txt"; }
pushn 8 "printf 'z = 2\n' > z.py"; P1=$(headn 8)
review 8 FAKE_PATH=z.py; stn 8
has "CURRENT HEAD ${P1:0:8}: FINDINGS OPEN" || { bad "setup: P1 not open"; cat "$T/out.txt"; }
pushn 8 "printf 'x = 3\n' > a.py"; P2=$(headn 8)
C0=$(wc -l < "$T/qwen_calls" | tr -d ' ')
FAKE_CLEAN=1 $DP --review-pr 8 --delta --via qwen --model fake/m --user-approved "test go-ahead" --tier high --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 2 ] && has "delta review not sufficient for PR 8: open findings at ${P1:0:8} on z.py are not touched since; fix them or run a full review" \
  && [ "$(wc -l < "$T/qwen_calls" | tr -d ' ')" = "$C0" ] \
  && ok "--delta: base = the open intermediate head; its open finding's file untouched -> exit 2, no model call" || { bad "open base rc=$RC"; tail -3 "$T/out.txt"; }
stn 8
has "CURRENT HEAD ${P2:0:8}: UNREVIEWED (head moved; last reviewed ${P1:0:8} (findings open on: z.py); changed since: a.py; full review needed (open findings not touched: z.py))" \
  && ! has "REVIEWED at" && ok "--pr-status: the open head is the base, the fix must touch z.py" || { bad "open base status"; cat "$T/out.txt"; }
pushn 8 "printf 'z = 3\n' > z.py"; P3=$(headn 8); stn 8
has "CURRENT HEAD ${P3:0:8}: UNREVIEWED (head moved; last reviewed ${P1:0:8} (findings open on: z.py); changed since: a.py, z.py; delta review possible)" \
  && ok "--pr-status: fix touches the open finding's file -> delta review possible" || { bad "open base fixed status"; cat "$T/out.txt"; }
git -C "$R" config color.diff always; git -C "$R" config color.ui always
FAKE_CLEAN=1 $DP --review-pr 8 --delta --via qwen --model fake/m --user-approved "test go-ahead" --tier high --repo "$R" > "$T/out.txt" 2>&1; RC=$?; D8="$RUNS/$(rid)"
git -C "$R" config --unset color.diff; git -C "$R" config --unset color.ui
[ $RC -eq 0 ] && [ "$(mj "$D8/meta.json" '(m["since"], m["delta_files"])')" = "('$P1', ['a.py', 'z.py'])" ] \
  && ok "--delta since the open head: since = P1, both files" || { bad "delta from open base rc=$RC"; tail -3 "$T/out.txt"; }
! grep -q "$(printf '\033')" "$D8/prompt.txt" && grep -q "^+z = 3$" "$D8/prompt.txt" && ok "delta prompt has no color codes under color.ui=always" || bad "color codes in the delta prompt"
stn 8; has "CURRENT HEAD ${P3:0:8}: REVIEWED at high (via delta from ${P1:0:8}; light fix at low)" && ok "review finds a HIGH, fix lands, clean delta -> REVIEWED via the open head" || { bad "main flow"; cat "$T/out.txt"; }
newpr 19 "printf 'm = 1\n' > m.py"; review 19 FAKE_SEV=MEDIUM FAKE_PATH=m.py
pushn 19 "printf 'm = 1  # todo\n' > m.py"; M1=$(headn 19)
FAKE_SEV=MEDIUM FAKE_PATH=m.py $DP --review-pr 19 --delta --via qwen --model fake/m --user-approved "test go-ahead" --tier high --repo "$R" > "$T/out.txt" 2>&1
stn 19; has "CURRENT HEAD ${M1:0:8}: FINDINGS OPEN" && ok "a cheap delta keeps a MEDIUM the fix leaves open: the gate stays shut" || { bad "delta MEDIUM"; cat "$T/out.txt"; }

echo "== a delta never clears a full review at the same head"
# --force-review: a clean delta already covers this head; force the full review this case deliberately re-runs
$DP --review-pr 8 --via qwen --model fake/m --user-approved "test go-ahead" --tier high --force-review --repo "$R" > "$T/out.txt" 2>&1; RC=$?; RD="$RUNS/$(rid)"
F8="$RD"; rec "$(basename "$D8")" "$FL"; stn 8
has "CURRENT HEAD ${P3:0:8}: FINDINGS OPEN" && ok "open full review + newer clean delta entry by the same reviewer -> FINDINGS OPEN" || { bad "delta cleared full"; cat "$T/out.txt"; }
rec "$(basename "$F8")" "$FL"; stn 8
has "CURRENT HEAD ${P3:0:8}: REVIEWED at high" && ! has "via delta" && ok "clean follow-up on the full review -> REVIEWED directly" || { bad "full follow-up"; cat "$T/out.txt"; }

echo "== renames list both paths"
pushn 8 "git mv z.py y.py"; P4=$(headn 8); stn 8
has "changed since: y.py, z.py; delta review possible)" && ok "--no-renames: a rename lists the old and the new path" || { bad "rename"; cat "$T/out.txt"; }

echo "== the fix block is the whole delta context; a rewrite needs a full review"
newpr 9 "python3 $T/gen.py; printf 's = 1\\n' > s.py"; Q0=$(headn 9)
FAKE_PATH=big.py $DP --review-pr 9 --exclude big.py --via qwen --model fake/m --user-approved "test go-ahead" --tier high --repo "$R" > "$T/out.txt" 2>&1; RD="$RUNS/$(rid)"
rec "$(basename "$RD")" "$FL"; stn 9
has "CURRENT HEAD ${Q0:0:8}: REVIEWED at high" || { bad "setup: Q0 not reviewed"; cat "$T/out.txt"; }
pushn 9 "sed -i.bak 's/^v_1999 = .*/v_1999 = 0/' big.py && rm big.py.bak"; Q1=$(headn 9)
FAKE_CLEAN=1 $DP --review-pr 9 --delta --dry-run --via qwen --model fake/m --user-approved "test go-ahead" --tier high --repo "$R" > "$T/out.txt" 2>&1; RC=$?
DR=$(sed -n 's/^DRY RUN PR REVIEW \([^:]*\):.*/\1/p' "$T/out.txt" | head -1)
SP=$(grep -l "^Changed since the last reviewed head ${Q0:0:8}" "$RUNS/$DR/prompt.txt" 2> /dev/null | head -1)
if [ $RC -eq 0 ] && [ -n "$SP" ] && grep -q "^+v_1999 = 0$" "$SP"; then
  LC=$(grep -n "^Changed since the last reviewed head" "$SP" | head -1 | cut -d: -f1); LD=$(grep -n "^diff --git a/big.py" "$SP" | head -1 | cut -d: -f1)
  [ "$LC" -lt "$LD" ] && ! grep -q "truncated at the cap" "$SP" && [ "$(grep -c '^diff --git a/big.py' "$SP")" = 1 ] \
    && ok "big PR file: one prompt, the fix block alone, no full-change context" || bad "full-change context in the delta prompt ($LC >= $LD)"
else bad "fix block lost over the cap rc=$RC prompt=${SP:-none}"; tail -3 "$T/out.txt"; fi
$DP --review-pr 9 --delta --packet --repo "$R" > "$T/out.txt" 2>&1; RC=$?
PK=$(sed -n 's/^PACKET \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
[ $RC -eq 0 ] && [ -f "$PK" ] && grep -q "^+v_1999 = 0$" "$PK" && ! grep -q "truncated at the cap" "$PK" \
  && ok "--delta --packet on a big PR file: packet written, fix block whole" || { bad "delta packet cap rc=$RC"; tail -3 "$T/out.txt"; }
pushn 9 "sed -i.bak 's/x/y/g' big.py && rm big.py.bak"
FAKE_CLEAN=1 $DP --review-pr 9 --delta --via qwen --model fake/m --user-approved "test go-ahead" --tier high --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 2 ] && has "big.py rewritten since ${Q0:0:8} (2000+/2000- of 2000 lines); run a full review" && ok "every line of big.py rewritten: --delta refuses (exit 2)" || { bad "rewrite rc=$RC"; tail -3 "$T/out.txt"; }

echo "== ledger paths: non-ASCII names, a/ b/ prefixes, open review without paths"
newpr 10 "printf 'e = 1\n' > é.py; printf 'w = 1\n' > w.py"; U0=$(headn 10)
review 10 FAKE_PATH=é.py; review 10 FAKE_PATH=b/w.py; rec "$(basename "$RD")" "$FL"; stn 10
has "CURRENT HEAD ${U0:0:8}: REVIEWED at high" || { bad "setup: U0 not reviewed"; cat "$T/out.txt"; }
pushn 10 "printf 'e = 2\n' > é.py; printf 'w = 2\n' > w.py"; U1=$(headn 10); stn 10
has "CURRENT HEAD ${U1:0:8}: UNREVIEWED (head moved; last reviewed ${U0:0:8}; changed since: w.py, é.py; delta review possible)" \
  && ok "quotePath off + b/ prefix: é.py and w.py are referenced" || { bad "path matching"; cat "$T/out.txt"; }
review 10 FAKE_GARBAGE=1; stn 10
has "CURRENT HEAD ${U1:0:8}: FINDINGS OPEN" || { bad "setup: unparsed review not open"; cat "$T/out.txt"; }
pushn 10 "printf 'w = 3\n' > w.py"; U2=$(headn 10)
FAKE_CLEAN=1 $DP --review-pr 10 --delta --via qwen --model fake/m --user-approved "test go-ahead" --tier high --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 2 ] && has "the open review at ${U1:0:8} records no finding paths; run a full review" && ok "open base without finding paths: --delta refuses" || { bad "unknown open rc=$RC"; tail -3 "$T/out.txt"; }
stn 10; has "full review needed (open review without finding paths))" && ok "--pr-status: open review without finding paths -> full review" || { bad "unknown open status"; cat "$T/out.txt"; }
echo "== first review finds a HIGH, the fix lands, a delta confirms (no earlier reviewed head)"
newpr 11 "mkdir -p a; printf 'k = 1\n' > a/k.py; printf 'm = 1\n' > m.py"; V0=$(headn 11)
review 11 FAKE_PATH=a/k.py; stn 11
has "CURRENT HEAD ${V0:0:8}: FINDINGS OPEN" || { bad "setup: V0 not open"; cat "$T/out.txt"; }
pushn 11 "printf 'k = 9\n' > k.py"; V1=$(headn 11); stn 11
has "CURRENT HEAD ${V1:0:8}: UNREVIEWED (head moved; last reviewed ${V0:0:8} (findings open on: a/k.py); changed since: k.py; full review needed (open findings not touched: a/k.py))" \
  && ok "first review open, fix adds a root k.py: a/k.py (real folder) is NOT touched" || { bad "first open base"; cat "$T/out.txt"; }
pushn 11 "rm k.py; printf 'k = 2\n' > a/k.py"; V2=$(headn 11); stn 11
has "CURRENT HEAD ${V2:0:8}: UNREVIEWED (head moved; last reviewed ${V0:0:8} (findings open on: a/k.py); changed since: a/k.py; delta review possible)" \
  && ok "fix touches a/k.py: delta review possible from the first (open) review" || { bad "first open fixed"; cat "$T/out.txt"; }
FAKE_CLEAN=1 $DP --review-pr 11 --delta --via qwen --model fake/m --user-approved "test go-ahead" --tier high --repo "$R" > "$T/out.txt" 2>&1; RC=$?; stn 11
[ $RC -eq 0 ] && has "CURRENT HEAD ${V2:0:8}: REVIEWED at high (via delta from ${V0:0:8}; light fix at low)" \
  && ok "main flow from the first review: open -> fix -> clean delta -> REVIEWED via the open head" || { bad "first-review main flow rc=$RC"; cat "$T/out.txt"; }

echo "== a delta that fixes open findings runs at low on a cheap model; the full review's tier carries (2026-10-25)"
newpr 71 "printf 'n = 1\n' > n.py"; U0=$(headn 71)
review 71 FAKE_PATH=n.py; stn 71
has "CURRENT HEAD ${U0:0:8}: FINDINGS OPEN" || { bad "setup: U0 not open"; cat "$T/out.txt"; }
pushn 71 "printf 'n = 2\n' > n.py"; U1=$(headn 71)
FAKE_CLEAN=1 $DP --review-pr 71 --delta --via qwen --model fake/m --tier high --repo "$R" > "$T/out.txt" 2>&1; RC=$?
grep -qF "tier lowered to low" "$T/out.txt"; LOW=$?; stn 71
[ $RC -eq 0 ] && [ $LOW -eq 0 ] && has "CURRENT HEAD ${U1:0:8}: REVIEWED at high" \
  && ok "open -> fix -> cheap delta at low without a go-ahead -> REVIEWED at high" || { bad "cheap open delta rc=$RC"; cat "$T/out.txt"; }

echo "== merged reviewed lineages, quoted file names, rebuilt head with only open reviews"
newpr 12 "printf 'x = 2\n' > a.py"; X0=$(headn 12); review 12; rec "$(basename "$RD")" "$FL"
newpr 12 "printf 'z = 1\n' > z.py"; Y0=$(headn 12); review 12 FAKE_PATH=z.py
( set -e; cd "$R"; git fetch -q origin refs/pull/12/head; git checkout -q FETCH_HEAD; git merge -q --no-edit "$X0" > /dev/null
  git push -q origin HEAD:refs/pull/12/head; git checkout -q main ) || { echo "setup failed: merge"; exit 1; }
Z0=$(headn 12); prjson 12 "$Z0"; stn 12
has "CURRENT HEAD ${Z0:0:8}: UNREVIEWED (head moved; merged reviewed heads: ${X0:0:8}, ${Y0:0:8}: full review needed)" \
  && ok "--pr-status: two reviewed lineages merged -> no delta base, full review" || { bad "merged lineages status"; cat "$T/out.txt"; }
FAKE_CLEAN=1 $DP --review-pr 12 --delta --via qwen --model fake/m --user-approved "test go-ahead" --tier high --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 2 ] && has "several reviewed heads are merged into ${Z0:0:8} (${X0:0:8}, ${Y0:0:8}); run a full review" \
  && ok "--delta over merged reviewed lineages: exit 2" || { bad "merged lineages delta rc=$RC"; tail -3 "$T/out.txt"; }
newpr 13 "printf 't = 1\n' > 'q\"t.py'"; G0=$(headn 13); review 13 'FAKE_PATH=q\"t.py'
grep -q '^+t = 1$' "$RD/prompt.txt" && ok "full review: a file name with a double quote keeps its diff (-z)" || bad "quoted file name lost from the full review"
rec "$(basename "$RD")" "$FL"; pushn 13 "printf 't = 2\n' > 'q\"t.py'"; G1=$(headn 13); stn 13
has "CURRENT HEAD ${G1:0:8}: UNREVIEWED (head moved; last reviewed ${G0:0:8}; changed since: q\"t.py; delta review possible)" \
  && ok "delta: a quoted file name is listed verbatim and referenced" || { bad "quoted name delta"; cat "$T/out.txt"; }
newpr 14 "printf 'x = 2\n' > a.py"; W0=$(headn 14); review 14
newpr 14 "printf 'x = 7\n' > a.py"; W1=$(headn 14); stn 14
has "CURRENT HEAD ${W1:0:8}: UNREVIEWED (head moved; no reviewed ancestor: full review needed)" \
  && ok "rebuilt head whose only recorded head is open: no reviewed ancestor, full review" || { bad "rebuilt open"; cat "$T/out.txt"; }
echo "== open head without a reviewed basis, a late review at a skipped head, pathspec magic, ./ paths"
jhigh(){ printf 'REVIEW-JSON\n{"findings": [{"severity": "HIGH", "path": "%s", "line": 1, "problem": "late finding", "fix": "fix it", "repro": {"input": "x", "expected": "2", "actual": "1"}}], "clauses": [], "tests": [], "verdict": "FIX"}\nEND-REVIEW-JSON\n' "$1" > "$T/late.txt"; }
newpr 15 "printf 'x = 2\n' > a.py; printf 'c = 1\n' > c.py; printf 'z = 1\n' > z.py"; S0=$(headn 15)
review 15; review 15 FAKE_PATH=c.py; S0RUN="$RD"; rec "$(basename "$RD")" "$FL"
pushn 15 "printf 'x = 3\n' > a.py; printf 'c = 2\n' > c.py"; S1=$(headn 15)
FAKE_PATH=c.py $DP --review-pr 15 --delta --via qwen --model fake/m --user-approved "test go-ahead" --tier high --repo "$R" > "$T/out.txt" 2>&1
jhigh z.py; $DP --review-record "$(basename "$S0RUN")" --reviewer late-opus --file "$T/late.txt" --repo "$R" > /dev/null 2>&1
pushn 15 "printf 'x = 4\n' > a.py; printf 'z = 2\n' > z.py"; S2=$(headn 15); stn 15
has "CURRENT HEAD ${S2:0:8}: UNREVIEWED (head moved; last reviewed ${S1:0:8} has open findings without a reviewed basis: full review needed)" \
  && ok "nearest base is an open head whose basis broke (late review at its base): no delta" || { bad "basis-false base status"; cat "$T/out.txt"; }
FAKE_CLEAN=1 $DP --review-pr 15 --delta --via qwen --model fake/m --user-approved "test go-ahead" --tier high --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 2 ] && has "delta review not sufficient for PR 15: the open head ${S1:0:8} has no reviewed basis; run a full review" \
  && ok "--delta from an open head without a reviewed basis: exit 2" || { bad "basis-false delta rc=$RC"; tail -3 "$T/out.txt"; }
newpr 16 "printf 'x = 2\n' > a.py; printf 'y = 1\n' > y.py"; Q0=$(headn 16)
review 16; review 16 FAKE_PATH=y.py; rec "$(basename "$RD")" "$FL"
pushn 16 "printf 'x = 3\n' > a.py"; Q1=$(headn 16)
pushn 16 "printf 'y = 2\n' > y.py"; Q2=$(headn 16)
FAKE_CLEAN=1 $DP --review-pr 16 --delta --via qwen --model fake/m --user-approved "test go-ahead" --tier high --repo "$R" > "$T/out.txt" 2>&1; stn 16
has "CURRENT HEAD ${Q2:0:8}: REVIEWED at high (via delta from ${Q0:0:8})" || { bad "setup: Q2 not reviewed via Q0"; cat "$T/out.txt"; }
mkdir -p "$RUNS/pr16-late-q1"; printf '[HIGH] a.py:L1: late finding. fix it.\nVERDICT: FIX\n' > "$RUNS/pr16-late-q1/report.md"
printf '{"kind": "pr-review", "pr": 16, "head": "%s", "tier": "high", "run_id": "pr16-late-q1", "reviews": [{"reviewer": "late-opus", "verdict": "FIX", "blockers": 0, "highs": 1, "report": "%s", "unreviewed": ["a.py"], "at": "2999-01-01T00:00:00+00:00"}]}\n' \
  "$Q1" "$RUNS/pr16-late-q1/report.md" > "$RUNS/pr16-late-q1/meta.json"; stn 16
has "CURRENT HEAD ${Q2:0:8}: UNREVIEWED" && has "open findings not touched: a.py" && ! has "REVIEWED at" \
  && ok "a review recorded later at a skipped intermediate head reopens the delta head" || { bad "late intermediate"; cat "$T/out.txt"; }
newpr 17 "printf 'evil = 1\n' > ':(top)a.py'"; review 17 FAKE_CLEAN=1
grep -q '^+evil = 1$' "$RD/prompt.txt" && ok "a PR file named ':(top)a.py' is diffed literally (no pathspec magic)" || bad "pathspec magic hid a file from the review"
newpr 18 "printf 'w = 1\n' > w2.py"; R0=$(headn 18); review 18 FAKE_PATH=./w2.py
pushn 18 "printf 'w = 2\n' > w2.py"; R1=$(headn 18); stn 18
has "CURRENT HEAD ${R1:0:8}: UNREVIEWED (head moved; last reviewed ${R0:0:8} (findings open on: w2.py); changed since: w2.py; delta review possible)" \
  && ok "a finding reported as ./w2.py is stored as w2.py and counts as touched by a change to w2.py" || { bad "./ open path"; cat "$T/out.txt"; }
python3 -I - "$T/concord/concord.py" <<'PYR'
import importlib.util, sys
sys.dont_write_bytecode = True
sp = importlib.util.spec_from_file_location("d", sys.argv[1]); d = importlib.util.module_from_spec(sp); sp.loader.exec_module(d)
L = {"key": "k", "next_finding": 1, "next_decision": 1, "findings": [], "decisions": []}
f = {"severity": "HIGH", "path": "./a.py", "line": 1, "problem": "wrong constant in a", "fix": "use 2", "repro": {"input": "x", "expected": "2", "actual": "1"}}
clean = d.validate_review({"findings": [f], "clauses": [], "tests": [], "verdict": "FIX"})
d.ledger_add(L, clean[0]["findings"] if isinstance(clean, tuple) else clean["findings"], "r", "run1")
L["findings"][0]["status"] = "declined"
again = dict(f, path="a.py")
c2 = d.validate_review({"findings": [again], "clauses": [], "tests": [], "verdict": "FIX"})
out = d.ledger_add(L, c2[0]["findings"] if isinstance(c2, tuple) else c2["findings"], "r", "run2")
sys.exit(0 if L["findings"][0]["path"] == "a.py" and out[0]["severity"] == "NOTE" else 1)
PYR
[ $? -eq 0 ] && ok "a declined finding reported as ./a.py stays declined when re-raised as a.py (stored stripped)" || bad "re-raise of a ./ ledger entry"
[ -z "$(git -C "$R" for-each-ref refs/review/)" ] && ok "no temp refs left behind by status or delta reviews" || bad "refs left: $(git -C "$R" for-each-ref refs/review/)"

echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
