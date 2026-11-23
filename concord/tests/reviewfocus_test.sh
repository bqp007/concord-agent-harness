#!/bin/bash
# Repo notes in every review prompt and the repo-notes risk floor: reviewers get the repo's binding notes (flash prompt,
# phase packet, PR packet); a `Risk floor <tier>: <globs>` line raises the review tier of a phase or PR whose change
# touches a matching non-test file. For a phase run, --review and --packet name the floor; --review-pr records the
# raised tier of a PR. A review of a low-tier phase is approve-only: it judges only BLOCKER and HIGH findings and keeps
# a MEDIUM as a note; a Risk: high phase keeps its tier whatever its Baseline: is, and a cheap review of it is an
# override the test report lists; --review-record --tokens stores the reviewer's token count. No network: fake qwen and gh.
# Run: bash ~/.claude/concord/tests/reviewfocus_test.sh   (exit 0 = all passed).
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/reviewfocus-test.XXXXXX")" && pwd -P)"; export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/concord" "$T/home/.claude"
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
cat > "$T/bin/qwen" <<'Q'
#!/bin/sh
if [ -n "${FAKE_ACTIONS:-}" ]; then sh -c "$FAKE_ACTIONS"; exit 0; fi
printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n'
Q
cat > "$T/bin/gh" <<'G'
#!/bin/sh
[ "$1" = pr ] && [ "$2" = view ] || exit 1
n=$(printf '%s' "$3" | sed -E 's|.*/pull/||; s|.*#||')
[ -f "$T/pr$n.json" ] && cat "$T/pr$n.json" && exit 0
echo "no pull requests found for $3" >&2; exit 1
G
chmod +x "$T/bin/qwen" "$T/bin/gh"
# Prefer the developer dir's real git/python3 over the /usr/bin xcrun shims (they print cache errors in the sandbox).
XDEV="$(xcode-select -p 2>/dev/null)"; [ -n "$XDEV" ] && [ -x "$XDEV/usr/bin/git" ] && [ -x "$XDEV/usr/bin/python3" ] && export PATH="$XDEV/usr/bin:$PATH"
export PATH="$T/bin:$PATH" HOME="$T/home"
DP="python3 $T/concord/concord.py"
. "$(dirname "$0")/lib.sh"
O="$T/origin.git"; R="$T/clone"; RUNS="$R/.git/concord"; NOTES="$T/concord/repo-notes/clone.md"
MARK="FAILURE-MARKER-7f3a"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
has(){ grep -F -- "$1" "$T/out.txt" > /dev/null; }
rid(){ sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1; }
pk(){ sed -n 's/^PACKET \([^ ]*\).*/\1/p' "$T/out.txt" | head -1; }
meta(){ python3 -I -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))" "$1/meta.json" "$2"; }
# run PHASE ACTIONS: one fake executor run of PLAN_F.md; ACTIONS is the shell the fake executor runs in the repo
run(){ FAKE_ACTIONS="$2" $DP "$1" --plan PLAN_F.md --via qwen --model fake/m --no-baseline --repo "$R" > "$T/out.txt" 2>&1
  grep -q '^DELEGATE RESULT' "$T/out.txt" || { echo "setup failed: the run of phase $1 did not start"; cat "$T/out.txt"; exit 1; }; }
flash(){ $DP --review "$1" --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1; }
packet(){ $DP --review "$1" --packet --repo "$R" > "$T/out.txt" 2>&1; }
prpacket(){ $DP --review-pr "$@" --packet --repo "$R" > "$T/out.txt" 2>&1; }
# before FILE A B: the first line containing A comes before the first line containing B (both present)
before(){ awk -v a="$2" -v b="$3" 'index($0,a)&&!x{x=NR} index($0,b)&&!y{y=NR} END{exit !(x&&y&&x<y)}' "$1"; }
printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n' > "$T/clean.txt"
phase(){ printf '## Phase %s - p%s\nExecutor: deepseek-flash\nRisk: %s\nFiles: %s\nAcceptance:\n- `true`\n' "$1" "$1" "$2" "$3"; }
notes(){ printf '# clone: binding facts\n- %s\n- Risk floor high: sec/*, *.lock\n- Risk floor medium: docs/*\n- Risk floor extreme: a.py\n- Risk floor high:\n' "$MARK" > "$NOTES"; }
notes
git init -q --bare -b main "$O" && git clone -q "$O" "$R" 2> /dev/null || { echo "setup failed: repos"; exit 1; }
( set -e; cd "$R" && git config user.email t@t && git config user.name t && git config diff.renames true
  mkdir sec docs big lib other; printf 'm = 1\n' > lib/m.py; printf 'o = 1\n' > other/o.py; printf 'x = 1\n' > a.py; printf 'k = 1\n' > sec/key.py; printf 'o = 1\n' > sec/old.py
  printf 't = 1\n' > sec/key_test.py; printf 'doc\n' > docs/x.md; printf 'b = 1\n' > big/f.py; printf '.claude/\n' > .gitignore
  { echo '# Plan'; phase 1 medium sec/key.py; phase 2 medium a.py; phase 3 low docs/x.md; phase 4 high docs/x.md
    phase 5 low sec/key_test.py; phase 6 medium 'sec/old.py, a.py'; phase 7 medium big/f.py; phase 8 low lib/m.py
    phase 9 medium 'lib/m.py, other/o.py'; phase 10 medium lib/m.py | sed 's/^Risk: medium$/&\nBaseline: skip/'
    phase 11 high lib/m.py | sed 's/^Risk: high$/&\nBaseline: skip/'; phase 12 medium docs/x.md; phase 13 medium 'sec/key.py, a.py'; } > PLAN_F.md
  git add -A && git commit -qm init && git push -q origin main
  git checkout -qb pr7; printf 'x = 2\n' > a.py; git commit -qam pr7; git push -q origin HEAD:refs/pull/7/head
  git checkout -q main; git checkout -qb pr9; printf 'x = 3\n' > a.py; printf 'k = 9\n' > sec/key.py
  git commit -qam pr9; git push -q origin HEAD:refs/pull/9/head
  git checkout -q main; git checkout -qb pr11; mkdir moved; git mv sec/key.py moved/key.py
  git commit -qm pr11; git push -q origin HEAD:refs/pull/11/head
  git checkout -q main; git branch -qD pr7 pr9 pr11 ) || { echo "setup failed: history"; exit 1; }
for n in 7 9 11; do printf '{"baseRefName": "main", "headRefName": "pr%s", "headRefOid": "%s", "title": "pr%s", "body": "b"}\n' \
  "$n" "$(git -C "$O" rev-parse "refs/pull/$n/head")" "$n" > "$T/pr$n.json"; done
approve PLAN_F.md "$R" || exit 1

echo "== notes reach reviewers"
run 2 "echo '# r' >> a.py"; A=$(rid); [ -n "$A" ] || { echo "setup failed: run p2"; cat "$T/out.txt"; exit 1; }
flash "$A"; RV=$(sed -n 's/^REVIEW \([^ ]*\) of .*/\1/p' "$T/out.txt" | head -1)
[ -n "$RV" ] && [ -f "$RUNS/$RV/prompt.txt" ] && before "$RUNS/$RV/prompt.txt" "Files changed:" "$MARK" \
  && before "$RUNS/$RV/prompt.txt" "$MARK" "The phase that was implemented" \
  && ok "flash review prompt carries the repo notes right after Files changed" || { bad "flash review prompt has no repo notes ('$RV')"; tail -2 "$T/out.txt"; }
packet "$A"; P=$(pk)
[ -n "$P" ] && before "$P" "Files changed:" "$MARK" && before "$P" "$MARK" "The phase that was implemented" \
  && ok "phase packet: repo notes right after Files changed, before the phase text" \
  || { bad "phase packet '$P'"; tail -2 "$T/out.txt"; }
prpacket 7; P=$(pk)
[ -n "$P" ] && before "$P" "<<<END-PR-TEXT-" "$MARK" \
  && ok "PR packet: repo notes after the PR-text block" || { bad "PR packet '$P'"; tail -2 "$T/out.txt"; }
mv "$NOTES" "$T/notes.off"
packet "$A"; P1=$(pk); prpacket 7; P2=$(pk)
run 2 "echo '# n' >> a.py"; A2=$(rid)
$DP --review "$A2" --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1
RV2=$(sed -n 's/^REVIEW \([^ ]*\) of .*/\1/p' "$T/out.txt" | head -1); P3="$RUNS/$RV2/prompt.txt"
[ -n "$P1" ] && [ -n "$P2" ] && [ -n "$RV2" ] && [ -f "$P3" ] && ! grep -q "Repository notes" "$P1" "$P2" "$P3" \
  && ok "no notes file: no notes block in the packets or the flash prompt" || bad "notes block without a notes file ('$P1' '$P2' '$P3')"
mv "$T/notes.off" "$NOTES"

echo "== phase floor"
run 1 "echo '# r' >> sec/key.py"; S=$(rid)
packet "$S"
has "risk floor high" && has "sec/key.py matches sec/*" && has "reviewer-opus55" \
  && ok "--packet names the floor, the matched path and the reviewer the phase needs" \
  || { bad "--packet printed no floor note"; tail -3 "$T/out.txt"; }
flash "$S"
has "risk floor high" && has "sec/key.py matches sec/*" && has "reviewer-opus55" \
  && ok "--review (flash) names the floor, the matched path and the reviewer the phase needs" \
  || { bad "--review printed no floor note"; tail -3 "$T/out.txt"; }
packet "$S"
has "needs concord:reviewer-opus55" && ok "--packet of a medium phase on a high-floor path names the reviewer the raised tier needs" \
  || { bad "no needs-reviewer note"; tail -3 "$T/out.txt"; }
run 3 "echo '# r' >> docs/x.md"; L=$(rid); flash "$L"; packet "$L"
has "risk floor medium" && has "docs/x.md matches docs/*" && has "needs concord:reviewer-opus55" \
  && ok "low phase on a medium-floor path: --packet names the floor and reviewer-opus55" \
  || { bad "medium floor"; tail -2 "$T/out.txt"; }
run 12 "echo '# m' >> docs/x.md"; Q=$(rid); packet "$Q"
[ -n "$(pk)" ] && ! has "risk floor" && ok "medium phase on a medium-floor path: no floor note (the floor must rank above the tier)" \
  || { bad "floor note at an equal tier"; tail -3 "$T/out.txt"; }
run 4 "echo '# s' >> docs/x.md"; H=$(rid); packet "$H"
[ -n "$(pk)" ] && ! has "risk floor" && ok "high phase on a medium-floor path: no floor note (a floor never lowers the tier)" \
  || { bad "floor lowered the tier"; tail -2 "$T/out.txt"; }
run 5 "echo '# r' >> sec/key_test.py"; K=$(rid); packet "$K"; ! has "risk floor"; NOTE=$?; [ -n "$(pk)" ] || NOTE=9; flash "$K"
[ $NOTE -eq 0 ] && ! has "risk floor" \
  && ok "low phase changing only sec/key_test.py: no floor note from --review or --packet (test files never trigger a floor)" \
  || { bad "test file triggered the floor note=$NOTE"; tail -2 "$T/out.txt"; }
run 2 "echo '# g' >> a.py; mkdir -p sec/__pycache__; printf c > sec/__pycache__/k.pyc"; G=$(rid); packet "$G"
case "$(meta "$RUNS/$G" generated)" in *"sec/__pycache__/k.pyc"*) GEN=1 ;; *) GEN=0 ;; esac
[ $GEN -eq 1 ] && [ -n "$(pk)" ] && ! has "risk floor" \
  && ok "medium phase on a.py leaving sec/__pycache__/k.pyc: no floor note (generated files never trigger a floor)" \
  || { bad "generated file gen=$GEN"; tail -2 "$T/out.txt"; }
# a packet needs a file that still exists, so the run also touches a.py (no floor of its own)
run 6 "rm sec/old.py; echo '# d' >> a.py"; D=$(rid); packet "$D"
[ -n "$(pk)" ] && has "risk floor high" && has "sec/old.py matches sec/*" && ok "deleting a high-floor file: --packet names the floor (deletions count)" \
  || { bad "deletion"; tail -2 "$T/out.txt"; }
{ printf '# clone: binding facts\n'; python3 -I -c "print('- filler ' + 'x' * 4200)"; printf -- '- Risk floor high: big/*\n'; } > "$NOTES"
run 7 "echo '# r' >> big/f.py"; B=$(rid); packet "$B"
[ -n "$(pk)" ] && has "risk floor high" && has "big/f.py matches big/*" && ok "a floor line past the 4000-character notes cap still counts" \
  || { bad "capped floor"; tail -2 "$T/out.txt"; }
notes
mv "$NOTES" "$T/notes.off"
run 1 "echo '# u' >> sec/key.py"; U=$(rid); packet "$U"
[ -n "$(pk)" ] && ! has "risk floor" && ok "no notes file: medium phase on sec/key.py has no floor note" || { bad "no notes file"; tail -2 "$T/out.txt"; }
mv "$T/notes.off" "$NOTES"
run 13 "echo '# v' >> sec/key.py; echo '# v' >> a.py"; X=$(rid)
$DP --review "$X" --packet --files a.py --repo "$R" > "$T/out.txt" 2>&1
has "risk floor high" && has "sec/key.py matches sec/*" && ok "--review --packet --files a.py still names the run's floor (--files never narrows it)" \
  || { bad "phase --files narrowed the floor"; tail -3 "$T/out.txt"; }
printf 'stray \377 byte\n' >> "$NOTES"
run 1 "echo '# w' >> sec/key.py"; W=$(rid); packet "$W"
[ -n "$(pk)" ] && has "risk floor high" && has "sec/key.py matches sec/*" && ! has "Traceback" \
  && ok "notes with a stray non-UTF-8 byte: the floor still applies to --packet, no traceback" \
  || { bad "stray byte"; tail -3 "$T/out.txt"; }
$DP --review "$W" --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1
RV3=$(sed -n 's/^REVIEW \([^ ]*\) of .*/\1/p' "$T/out.txt" | head -1)
[ -n "$RV3" ] && grep -qF "$MARK" "$RUNS/$RV3/prompt.txt" && ! has "Traceback" && ok "notes with a stray non-UTF-8 byte: flash prompt still carries the notes" \
  || { bad "stray byte broke the flash prompt ('$RV3')"; tail -3 "$T/out.txt"; }
notes

echo "== PR floor"
prpacket 9; P=$(pk)
[ -n "$P" ] && has "tier raised to high" && [ "$(meta "$(dirname "$P")" tier)" = high ] \
  && ok "PR touching sec/key.py: tier raised to high and recorded" || { bad "PR floor '$P'"; tail -3 "$T/out.txt"; }
prpacket 9 --files a.py; P=$(pk)
$DP --pr-status 9 --repo "$R" > "$T/st.txt" 2>&1
[ -n "$P" ] && ! has "tier raised" && [ "$(meta "$(dirname "$P")" tier)" = medium ] && grep -qE '^  sec/key\.py: needs high$' "$T/st.txt" \
  && ok "--files a.py runs at a.py's needed tier (medium); the floor file keeps its own: --pr-status lists sec/key.py: needs high" \
  || { bad "PR floor with --files '$P'"; tail -3 "$T/out.txt"; cat "$T/st.txt"; }
prpacket 7; P=$(pk)
[ -n "$P" ] && ! has "tier raised" && [ "$(meta "$(dirname "$P")" tier)" = medium ] && ok "PR without floor files keeps tier medium" \
  || { bad "PR 7 tier '$P'"; tail -3 "$T/out.txt"; }
prpacket 11; P=$(pk)
[ -n "$P" ] && has "tier raised to high" && [ "$(meta "$(dirname "$P")" tier)" = high ] \
  && ok "PR renaming sec/key.py out of the floor path: tier still raised (rename source counts)" || { bad "PR rename dodged the floor '$P'"; tail -3 "$T/out.txt"; }
python3 -I -B -c "import sys; sys.path.insert(0, sys.argv[1]); import concord as d; sys.exit(0 if d.parse_risk_floors('\ufeff- Risk floor high: sec/*\n') == [('high', ['sec/*'])] else 1)" "$T/concord" 2> /dev/null \
  && ok "a floor line right after a UTF-8 byte-order mark still parses" || bad "a byte-order mark hid the first floor line"

echo "== a review judges the phase the run followed"
run 9 "echo '# o1' >> other/o.py"; V=$(rid)
python3 -I -c "
import sys; p = sys.argv[1]; s = open(p).read(); h = s.index('## Phase 9 '); e = s.index('## Phase 10 ')
open(p, 'w').write(s[:h] + s[h:e].replace('- \`true\`', '- \`echo REVISED-ACCEPTANCE-4c1\`') + s[e:])" "$R/PLAN_F.md"
packet "$V"; P=$(pk)
grep -q 'REVISED-ACCEPTANCE-4c1' "$P" && NOTAPPROVED=0 || NOTAPPROVED=1
approve PLAN_F.md "$R" 9 || exit 1; packet "$V"; P=$(pk)
[ $NOTAPPROVED -eq 1 ] && [ -n "$P" ] && grep -q 'REVISED-ACCEPTANCE-4c1' "$P" && before "$P" "The phase that was implemented" "REVISED-ACCEPTANCE-4c1" \
  && sed -n '/The phase that was implemented/,/REVISED-ACCEPTANCE-4c1/p' "$P" | grep -qF '`true`' && grep -q 'later approved revision 2' "$P" \
  && ok "a later approved revision's acceptance shows in the packet apart from the phase the run followed; an unapproved edit of the plan does not" \
  || { bad "packet shows the revised phase as implemented ('$P', unapproved edit in packet: $((1 - NOTAPPROVED)))"; sed -n '/The phase that was implemented/,/Acceptance/p' "$P" 2>/dev/null; }
python3 -I -c "
import sys; p = sys.argv[1]; s = open(p).read(); open(p, 'w').write(s.replace('- \`echo REVISED-ACCEPTANCE-4c1\`', '- \`true\`'))" "$R/PLAN_F.md"
printf 'REVIEW-JSON\n{"findings": [{"severity": "HIGH", "path": "other/o.py", "line": 8, "problem": "late line", "fix": "Guard it", "repro": {"input": "i", "expected": "e", "actual": "a"}}], "clauses": [], "tests": [], "verdict": "BLOCK"}\nEND-REVIEW-JSON\n' > "$T/late.json"
run 9 "printf 'a = 1\\nb = 2\\nc = 3\\nd = 4\\ne = 5\\nf = 6\\ng = 7\\n' >> other/o.py"; W=$(rid); packet "$W"; PW=$(pk)
printf 'o = 1\nz = 0\n' > "$R/other/o.py"
cp "$T/late.json" "$T/late.sig.json"; sign "$T/late.sig.json" "$PW"
$DP --review-record "$W" --reviewer reviewer-opus55 --file "$T/late.sig.json" --repo "$R" > "$T/out.txt" 2>&1; RC=$?
REP=$(python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]+'/meta.json'))['reviews'][-1]['report'])" "$RUNS/$W")
[ $RC -eq 0 ] && grep -q '^\[HIGH\] other/o.py:L8:' "$REP" && ! grep -q '^\[HIGH\] other/o.py:L8:.*outside diff' "$REP" \
  && ok "an answer quoting a packet is anchored to that packet's diff after the files changed" \
  || { bad "finding judged against the later checkout: rc=$RC"; cat "$REP" 2>/dev/null; }
printf 'o = 1\n' > "$R/other/o.py"

echo "== approve-only low tier"
lastrev(){ python3 -I -c "import json,sys; r=json.load(open(sys.argv[1]+'/meta.json')).get('reviews') or [{}]; print(r[-1].get(sys.argv[2]))" "$RUNS/$1" "$2"; }
nrevs(){ python3 -I -c "import json,sys; print(len(json.load(open(sys.argv[1]+'/meta.json')).get('reviews') or []))" "$RUNS/$1"; }
ledsev(){ python3 -I -c "import json,sys; L=json.load(open(sys.argv[1])); print(','.join(sorted(f['severity'] for f in L.get('findings', []) if f.get('run') == sys.argv[2])))" "$(ls "$RUNS"/ledger/PLAN_F-*.json | head -1)" "$1"; }
clean(){ git -C "$R" checkout -q -- lib other; }
f(){ printf '{"severity": "%s", "path": "lib/m.py", "line": 2, "line_end": 2, "problem": "%s", "fix": "f", "repro": {"input": "i", "expected": "e", "actual": "a"}, "clause": "", "test": "", "reraise_of": ""}' "$1" "$2"; }
printf 'REVIEW-JSON\n{"findings": [%s], "clauses": [], "tests": [], "verdict": "FIX"}\nEND-REVIEW-JSON\n' "$(f MEDIUM "m only")" > "$T/med.txt"
printf 'REVIEW-JSON\n{"findings": [%s, %s, %s], "clauses": [], "tests": [], "verdict": "FIX"}\nEND-REVIEW-JSON\n' \
  "$(f HIGH "h one")" "$(f MEDIUM "m two")" "$(f NOTE "n three")" > "$T/mix.txt"
clean; run 8 "echo '# a1' >> lib/m.py"; X1=$(rid)
FAKE_ACTIONS="cat $T/med.txt" flash "$X1"
[ "$(lastrev "$X1" verdict)" = CLEAN ] && [ "$(lastrev "$X1" mediums)" = 0 ] \
  && ok "low tier, a MEDIUM-only answer: recorded CLEAN (an approval)" || { bad "MEDIUM-only low review"; tail -3 "$T/out.txt"; }
clean; run 8 "echo '# a2' >> lib/m.py"; X2=$(rid)
FAKE_ACTIONS="cat $T/mix.txt" flash "$X2"; RV4=$(sed -n 's/^REVIEW \([^ ]*\) of .*/\1/p' "$T/out.txt" | head -1)
[ -n "$RV4" ] && grep -qF "APPROVE-ONLY REVIEW" "$RUNS/$RV4/prompt.txt" && [ "$(lastrev "$X2" highs)" = 1 ] \
  && [ "$(lastrev "$X2" mediums)" = 0 ] \
  && ok "low tier, HIGH + MEDIUM + NOTE: prompt says approve-only, the entry counts the HIGH and no MEDIUM" \
  || { bad "approve-only '$RV4'"; tail -3 "$T/out.txt"; }
[ -n "$RV" ] && ! grep -qF "APPROVE-ONLY REVIEW" "$RUNS/$RV/prompt.txt" \
  && ok "a medium-tier flash prompt has no approve-only text" || bad "approve-only text on a medium run ('$RV')"
clean; run 10 "echo '# a4' >> lib/m.py"; X4=$(rid)
FAKE_ACTIONS="cat $T/mix.txt" flash "$X4"; RV5=$(sed -n 's/^REVIEW \([^ ]*\) of .*/\1/p' "$T/out.txt" | head -1)
[ -n "$RV5" ] && ! grep -qF "APPROVE-ONLY REVIEW" "$RUNS/$RV5/prompt.txt" && [ "$(lastrev "$X4" mediums)" = 1 ] \
  && ok "Baseline: skip with Risk: medium is not approve-only: the MEDIUM is kept" || { bad "skip+medium approve-only '$RV5'"; tail -3 "$T/out.txt"; }
clean; run 11 "echo '# a5' >> lib/m.py"; X5=$(rid)
FAKE_ACTIONS="cat $T/mix.txt" flash "$X5"; RV6=$(sed -n 's/^REVIEW \([^ ]*\) of .*/\1/p' "$T/out.txt" | head -1)
[ -n "$RV6" ] && ! grep -qF "APPROVE-ONLY REVIEW" "$RUNS/$RV6/prompt.txt" && [ "$(lastrev "$X5" mediums)" = 1 ] \
  && ok "Baseline: skip with Risk: high keeps the high review tier: not approve-only, the MEDIUM is kept" || { bad "skip+high review tier '$RV6'"; tail -3 "$T/out.txt"; }
clean; run 9 "echo '# a3' >> lib/m.py; echo '# a3' >> other/o.py"; X3=$(rid)
record "$X3" concord:reviewer-opus55 "$T/mix.txt" "$R" > "$T/out.txt" 2>&1
[ "$(lastrev "$X3" mediums)" = 1 ] && [ "$(ledsev "$X3")" = "HIGH,MEDIUM,NOTE" ] \
  && ok "medium tier: --review-record keeps HIGH, MEDIUM and NOTE" || { bad "medium record ledger='$(ledsev "$X3")'"; tail -3 "$T/out.txt"; }
clean

echo "== review tokens"
record "$X1" concord:reviewer-opus55 "$T/clean.txt" "$R" --tokens 12345 > "$T/out.txt" 2>&1
[ "$(lastrev "$X1" tokens)" = 12345 ] && ok "--review-record --tokens 12345 stores tokens on the entry" || { bad "tokens not stored"; tail -3 "$T/out.txt"; }
N0=$(nrevs "$X1")
record "$X1" concord:reviewer-opus55 "$T/clean.txt" "$R" --tokens auto > "$T/out.txt" 2>&1; R1=$?
record "$X1" concord:reviewer-opus55 "$T/clean.txt" "$R" --tokens x > "$T/out.txt" 2>&1; R2=$?
L0=$(ledsev "$X2")
record "$X2" concord:reviewer-opus55 "$T/mix.txt" "$R" --tokens ² > "$T/out.txt" 2>&1; R3=$?
[ $R1 -eq 2 ] && [ $R2 -eq 2 ] && [ $R3 -eq 2 ] && [ "$(nrevs "$X1")" = "$N0" ] && [ "$(ledsev "$X2")" = "$L0" ] && ! has "Traceback" \
  && ok "--tokens auto, x or ² on --review-record: exit 2, nothing recorded, ledger untouched" \
  || bad "bad --tokens rc=$R1/$R2/$R3 reviews $N0 -> $(nrevs "$X1") ledger '$L0' -> '$(ledsev "$X2")'"

echo "== the report lists the cheap review of a Risk: high phase under Overrides (it closes the plan, so it runs last)"
# every run of the plan needs a verdict before --report (Report written: a run with no verdict blocks it)
for RV in $(python3 -I -c "import json,glob,sys; [print(json.load(open(f)).get('run_id') or f.split('/')[-2]) for f in sorted(glob.glob(sys.argv[1] + '/*/meta.json')) if json.load(open(f)).get('plan') == 'PLAN_F.md' and not json.load(open(f)).get('verdict')]" "$RUNS"); do
  $DP --verdict "$RV" PASS --force --note "setup: close the run" --repo "$R" > "$T/rv.txt" 2>&1 || { echo "setup failed: --verdict $RV"; cat "$T/rv.txt"; exit 1; }
done
$DP --report --plan PLAN_F.md --repo "$R" > "$T/rep.txt" 2>&1; REP=$(sed -n 's/^report: //p' "$T/rep.txt" | head -1); [ -f "$REP" ] || REP="$T/none"
[ "$(grep -m1 '^## ' "$REP")" = "## Overrides" ] && sed -n '/^## Overrides/,/^## [^O]/p' "$REP" | grep -qE "^- phase 11 \(run $X5\) reviewed below its tier: needs high" \
  && ok "the report opens with Overrides and lists the cheap review of the Risk: high phase as below its tier (Baseline: skip does not lower the tier)" || { bad "high phase reviewed cheap is not under Overrides"; sed -n 1,12p "$REP" 2>/dev/null; }

echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
