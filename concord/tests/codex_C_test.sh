#!/bin/bash
# Reviews and the PR gate, one check per defect of an outside review (R-14 to R-18, R-33 to R-36):
# a review process that failed earns no coverage and exits non-zero; an answer must hold the whole schema; a phase review
# counts per file it read, both families at high, and a binary or cut file counts for no review; a delta hunk counts only
# inside the scope of the finding it closes; a tier drops below medium only through PR commits that PASS runs made; a
# deletion-only phase takes a direct review; a binary-only PR can be waived, an empty or closed PR is not REVIEWED, a
# missing gh head is an unverified head; a retarget starts the coverage over; pi's malformed-answer retry runs; a forced
# PASS lowers no tier; reviews recorded by 3.3.0 keep that version's rules.
# No network: fake gh, fake qwen and pi, a local bare repository as the remote.
# Run: bash concord/tests/codex_C_test.sh   (exit 0 = every check passed)
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/codexC-test.XXXXXX")" && pwd -P)"; export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/concord" "$T/home/.claude"
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
cat > "$T/bin/qwen" <<'Q'
#!/bin/sh
echo ran >> "$T/qwen_calls"
if [ -n "${FAKE_ACTIONS:-}" ]; then sh -c "$FAKE_ACTIONS"; exit 0; fi
if [ -n "${FAKE_GARBAGE:-}" ]; then echo "looks fine to me"; exit 0; fi
cat "${FAKE_JSON:-$T/clean.txt}"; exit "${FAKE_RC:-0}"
Q
cat > "$T/bin/gh" <<'G'
#!/bin/sh
[ "$1" = pr ] && [ "$2" = view ] || exit 1
n=$(printf '%s' "$3" | sed -E 's|.*/pull/||; s|.*#||')
[ -f "$T/pr$n.json" ] || { echo "no pull requests found for $3" >&2; exit 1; }
cat "$T/pr$n.json"
G
cat > "$T/bin/pi" <<'PI'
#!/bin/sh
d=""; prev=""; for a in "$@"; do [ "$prev" = "--session-dir" ] && d="$a"; prev="$a"; done
echo ran >> "$T/pi_calls"; k=$(wc -l < "$T/pi_calls" | tr -d ' ')
mkdir -p "$d" && printf '{"type":"message","message":{"role":"assistant","usage":{"input":100,"output":20,"cacheRead":5,"cacheWrite":0,"totalTokens":125,"cost":{"input":0.01,"output":0.0023,"cacheRead":0,"cacheWrite":0,"total":0.0123}}}}\n' > "$d/s$k.jsonl"
if [ "$k" = 1 ]; then echo "looks fine to me"; else cat "$T/clean.txt"; fi
PI
chmod +x "$T/bin/qwen" "$T/bin/gh" "$T/bin/pi"
XDEV="$(xcode-select -p 2>/dev/null)"; [ -n "$XDEV" ] && [ -x "$XDEV/usr/bin/git" ] && [ -x "$XDEV/usr/bin/python3" ] && export PATH="$XDEV/usr/bin:$PATH"
export PATH="$T/bin:$PATH" HOME="$T/home"
DP="python3 $T/concord/concord.py"
O="$T/origin.git"; C="$T/clone"; RUNS="$C/.git/concord"
. "$(dirname "$0")/lib.sh"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
has(){ grep -F -- "$1" "$T/out.txt" > /dev/null; }
calls(){ [ -f "$T/qwen_calls" ] && wc -l < "$T/qwen_calls" | tr -d ' ' || echo 0; }
mj(){ python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"m": m}))' "$1" "$2"; }
printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n' > "$T/clean.txt"
printf 'REVIEW-JSON\n{"findings": [{"severity": "HIGH", "path": "a.py", "line": 1, "problem": "wrong constant", "fix": "use 2", "repro": {"input": "x", "expected": "2", "actual": "1"}}], "clauses": [], "tests": [], "verdict": "FIX"}\nEND-REVIEW-JSON\n' > "$T/high_a.txt"

git init -q --bare -b main "$O" && git clone -q "$O" "$C" 2> /dev/null || { echo "setup failed: repos"; exit 1; }
( set -e; cd "$C"; git config user.email t@t; git config user.name t
  printf 'readme\n' > README; printf 'A\n' > f205.txt; printf '.claude/\n' > .gitignore; git add -A; git commit -qm init; git push -q origin main ) \
  || { echo "setup failed: main"; exit 1; }
hd(){ git -C "$O" rev-parse "refs/pull/$1/head"; }
# prjson N [EXTRA]: gh's answer for PR N on main at its pushed head; EXTRA is more JSON members (", \"state\": \"MERGED\"")
prjson(){ printf '{"baseRefName": "main", "headRefName": "pr%s", "headRefOid": "%s", "title": "t", "body": "b"%s}\n' "$1" "$(hd "$1")" "${2:-}" > "$T/pr$1.json"; }
# newpr N FILE TEXT [FILE TEXT ...]: PR N adds each FILE holding TEXT on top of main; pushpr N FILE TEXT [...]: a commit on its head
newpr(){ local n=$1; shift; ( set -e; cd "$C"; git checkout -q main; git checkout -qb "pr$n"
  while [ $# -ge 2 ]; do printf "$2" > "$1"; shift 2; done
  git add -A; git commit -qm "pr$n"; git push -qf origin "HEAD:refs/pull/$n/head"; git checkout -q main; git branch -qD "pr$n" ) \
  || { echo "setup failed: pr$n"; exit 1; }
  prjson "$n"; }
pushpr(){ local n=$1; shift; ( set -e; cd "$C"; git fetch -q origin "refs/pull/$n/head"; git checkout -q FETCH_HEAD
  while [ $# -ge 2 ]; do printf "$2" > "$1"; shift 2; done
  git add -A; git commit -qm fix; git push -q origin "HEAD:refs/pull/$n/head"; git checkout -q main ) || { echo "setup failed: push $n"; exit 1; }
  prjson "$n"; }
# runpr N RISK FILES ACTIONS [BRANCH]: a Concord run of FILES (Risk RISK) on a branch off main, committed and pushed as PR N's
# head; VERDICT=PASS|FAIL records that verdict before the commit (FORCE=1: with --force); ACC is the acceptance (default true)
runpr(){ local n=$1 risk=$2 files=$3 actions=$4 br=${5:-pr$1}
  mkdir -p "$C/.claude"; printf '# Plan\n## Phase 1 - run %s\nExecutor: deepseek-flash\nRisk: %s\nFiles: %s\nAcceptance:\n- `%s`\n' "$n" "$risk" "$files" "${ACC:-true}" > "$C/.claude/PLAN_$n.md"
  ( set -e; cd "$C"; git checkout -q main; git checkout -qb "$br" ) || { echo "setup failed: branch $br"; exit 1; }
  approve ".claude/PLAN_$n.md" "$C" || exit 1
  FAKE_ACTIONS="$actions" $DP 1 --plan ".claude/PLAN_$n.md" --via qwen --model fake/m --no-baseline --repo "$C" > "$T/out.txt" 2>&1
  RUNID=$(sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1); [ -n "$RUNID" ] || { echo "setup failed: run for PR $n"; cat "$T/out.txt"; exit 1; }
  if [ -n "${VERDICT:-}" ]; then $DP --verdict "$RUNID" "$VERDICT" $([ "$VERDICT" = FAIL ] && echo --cause EXECUTOR) $([ -n "${FORCE:-}" ] && echo --force --note forced) --repo "$C" > "$T/v.txt" 2>&1 || { echo "setup failed: $VERDICT of run $n"; cat "$T/v.txt"; exit 1; }; fi
  ( set -e; cd "$C"; git add -A; git commit -qm "run $n"; git push -qf origin "HEAD:refs/pull/$n/head"; git checkout -q main; git branch -qD "$br" ) || { echo "setup failed: commit $n"; exit 1; }
  prjson "$n"; }
flash(){ local n=$1 m=$2; shift 2; $DP --review-pr "$n" --via qwen --model "$m" "$@" --repo "$C" > "$T/out.txt" 2>&1; }
# opus N TIER NAME ANSWER [ARGS]: a packet at TIER, answered with ANSWER (signed), recorded as NAME
opus(){ local n=$1 t=$2 name=$3 ans=$4; shift 4
  $DP --review-pr "$n" --packet --tier "$t" "$@" --repo "$C" > "$T/out.txt" 2>&1
  PK=$(sed -n 's/^PACKET \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
  [ -n "$PK" ] || { echo "    (no packet for PR $n: $(tail -1 "$T/out.txt"))"; return 1; }
  cp "$ans" "$T/ans.txt"; sign "$T/ans.txt" "$PK"
  $DP --review-record "$(basename "$(dirname "$PK")")" --reviewer "$name" --file "$T/ans.txt" --repo "$C" > "$T/rec.txt" 2>&1; }
st(){ $DP --pr-status "$1" --repo "$C" > "$T/out.txt" 2>&1; RC=$?; }
# phrepo DIR PLANBODY FILE TEXT [FILE TEXT ...]: a repository with those files committed and PLAN_T.md approved
phrepo(){ local d=$1 body=$2; shift 2; mkdir -p "$d"
  ( set -e; cd "$d"; git init -q -b main; git config user.email t@t; git config user.name t; printf '.claude/\n' > .gitignore
    while [ $# -ge 2 ]; do printf "$2" > "$1"; shift 2; done; git add -A; git commit -qm init; printf '%b' "$body" > PLAN_T.md ) \
    || { echo "setup failed: repo $d"; exit 1; }
  approve PLAN_T.md "$d" || exit 1; }
# phrun DIR ACTIONS: phase 1 of DIR's plan on the fake executor; RUN is its id
phrun(){ FAKE_ACTIONS="$2" $DP 1 --plan PLAN_T.md --via qwen --model fake/m --no-baseline --repo "$1" > "$T/out.txt" 2>&1
  RUN=$(sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1); [ -n "$RUN" ] || { echo "setup failed: run in $1"; cat "$T/out.txt"; exit 1; }; }
# unset FILE KEY...: drop those keys from every review entry of the run meta FILE (the shape 3.3.0 recorded)
unset_keys(){ python3 -I - "$@" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for r in m.get("reviews") or []:
    for k in sys.argv[2:]:
        r.pop(k, None)
open(sys.argv[1], "w").write(json.dumps(m, indent=1))
PY
}
report(){ $DP --report --plan PLAN_T.md --repo "$1" > "$T/rep.txt" 2>&1; REP=$(sed -n 's/^report: //p' "$T/rep.txt" | head -1); [ -f "$REP" ] || REP="$T/none"
  sed -n '/^## Overrides/,/^## Phases/p' "$REP" 2>/dev/null > "$T/ov.txt"; }

echo "== R-14 a review that failed earns nothing and exits non-zero"
VERDICT=PASS runpr 201 low l201.txt "printf 'l = 201\n' > l201.txt"
FAKE_RC=1 flash 201 fake/m --tier low; RC1=$?; cp "$T/out.txt" "$T/r201.txt"; st 201
[ $RC1 -ne 0 ] && ! has ": REVIEWED" && [ $RC -eq 1 ] \
  && ok "R-14 a review process that exits 1 after printing a CLEAN answer: the review exits non-zero and the head is not REVIEWED" \
  || { bad "R-14 failed process credited: review rc=$RC1, status rc=$RC"; tail -2 "$T/r201.txt"; head -1 "$T/out.txt"; }
newpr 202 g202.py 'g = 202\n'
FAKE_GARBAGE=1 flash 202 fake/m --tier medium; RC1=$?
D=$(sed -n 's/^PR REVIEW \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
[ $RC1 -ne 0 ] && has "verdict UNPARSED" && [ -n "$D" ] && [ "$(mj "$RUNS/$D/meta.json" 'm["reviews"][-1].get("rc")')" = 0 ] \
  && ok "R-14 an answer that never parses, after its retry: the review exits non-zero; the entry keeps UNPARSED and the exit status 0" \
  || { bad "R-14 unparsed review rc=$RC1"; tail -2 "$T/out.txt"; }

echo "== R-15 an answer with findings alone is no review"
newpr 203 h203.py 'h = 203\n'
printf 'REVIEW-JSON\n{"findings": []}\nEND-REVIEW-JSON\n' > "$T/bare.txt"
opus 203 medium concord:reviewer-opus55 "$T/bare.txt"; RC1=$?; cp "$T/rec.txt" "$T/r203.txt"; st 203
[ $RC1 -eq 2 ] && grep -q "not recorded" "$T/r203.txt" && ! has ": REVIEWED" && [ $RC -eq 1 ] \
  && ok "R-15 {\"findings\": []} with the packet's hash is refused (exit 2, not recorded) and the head stays UNREVIEWED" \
  || { bad "R-15 bare answer recorded: rc=$RC1 status rc=$RC"; cat "$T/r203.txt"; head -1 "$T/out.txt"; }

echo "== R-16 a high phase counts per file read, each by both families"
H="$T/high"; phrepo "$H" '# Plan\n## Phase 1 - x\nExecutor: deepseek-flash\nRisk: high\nFiles: a.py, b.py\nAcceptance:\n- `grep -q y a.py`\n' a.py 'x = 1\n' b.py 'x = 1\n'
phrun "$H" "printf 'y = 1\n' > a.py; printf 'y = 1\n' > b.py"; X16=$RUN
$DP --verdict "$X16" PASS --repo "$H" > "$T/v.txt" 2>&1 || { echo "setup failed: PASS"; cat "$T/v.txt"; exit 1; }
$DP --review "$X16" --packet --files a.py --repo "$H" > "$T/pk.txt" 2>&1 || { echo "setup failed: packet"; cat "$T/pk.txt"; exit 1; }
cp "$T/clean.txt" "$T/c16.txt"; record "$X16" concord:reviewer-opus55 "$T/c16.txt" "$H" > "$T/rec.txt" 2>&1 || { echo "setup failed: record"; cat "$T/rec.txt"; exit 1; }
$DP --review "$X16" --via qwen --model fake/m --files b.py --repo "$H" > "$T/out.txt" 2>&1 || { echo "setup failed: flash review"; cat "$T/out.txt"; exit 1; }
report "$H"
grep -qF -- "- phase 1 (run $X16) reviewed below its tier: needs high" "$T/ov.txt" && grep -F -- "- phase 1 (run $X16)" "$T/ov.txt" | grep -qF "b.py" \
  && ok "R-16 reviewer-opus55 read a.py and a flash review read b.py: the report lists the phase, b.py below high" \
  || { bad "R-16 disjoint reviews hid the gap"; cat "$T/ov.txt"; tail -2 "$T/rep.txt"; }

echo "== R-17 a delta hunk counts only inside the scope of the finding it closes"
newpr 204 a.py 'a = 1\n' b.py 'b = 1\n'
opus 204 medium concord:reviewer-opus55 "$T/high_a.txt" || { echo "setup failed: PR 204 review"; cat "$T/out.txt" "$T/rec.txt"; exit 1; }
pushpr 204 a.py 'a = 2\n' b.py 'b = 2\n'
$DP --review-pr 204 --packet --delta --repo "$C" > "$T/out.txt" 2>&1; PK=$(sed -n 's/^PACKET \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
[ -n "$PK" ] || { echo "setup failed: PR 204 delta packet"; cat "$T/out.txt"; exit 1; }
python3 -I - "$(dirname "$PK")/meta.json" "$T/d204.txt" <<'PY'
import json, sys
hunks = json.load(open(sys.argv[1]))["hunks"]
a = {"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN",
     "resolutions": [{"finding": "F1", "fixed": "yes", "evidence": "a.py:1 is now 2"}],
     "hunks": [{"hunk": h, "explained_by": "F1"} for h in hunks]}
open(sys.argv[2], "w").write("REVIEW-JSON\n" + json.dumps(a) + "\nEND-REVIEW-JSON\n")
PY
sign "$T/d204.txt" "$PK"; $DP --review-record "$(basename "$(dirname "$PK")")" --reviewer reviewer-delta --file "$T/d204.txt" --repo "$C" > "$T/rec.txt" 2>&1 \
  || { echo "setup failed: delta record"; cat "$T/rec.txt"; exit 1; }
st 204
! has ": REVIEWED" && [ $RC -eq 1 ] && grep -qE '^  b\.py: needs medium' "$T/out.txt" \
  && ok "R-17 a delta that ties the b.py hunk to a finding on a.py: b.py keeps no coverage (needs medium), exit 1" \
  || { bad "R-17 hunk outside the finding's scope carried coverage, rc=$RC"; cat "$T/out.txt"; }

echo "== R-18 a tier drops below medium only through the PR's own commits, made by runs that passed"
VERDICT=FAIL runpr 205 low f205n.txt "printf 'B\n' > f205n.txt"
$DP --review-pr 205 --packet --tier low --repo "$C" > "$T/out.txt" 2>&1; RC1=$?; cp "$T/out.txt" "$T/r205.txt"
VERDICT=PASS runpr 2060 low f205.txt "printf 'B\n' > f205.txt" pr2060
( set -e; cd "$C"; git checkout -q main; git checkout -qb pr206; printf 'X\n' > f205.txt; git commit -qam "by hand X"; printf 'B\n' > f205.txt
  git commit -qam "by hand B"; git push -qf origin HEAD:refs/pull/206/head; git checkout -q main; git branch -qD pr206 ) || { echo "setup failed: pr206"; exit 1; }
prjson 206
$DP --review-pr 206 --packet --tier low --repo "$C" > "$T/out.txt" 2>&1; RC2=$?
[ $RC1 -eq 2 ] && ! grep -q '^PACKET' "$T/r205.txt" && [ $RC2 -eq 2 ] && ! grep -q '^PACKET' "$T/out.txt" \
  && ok "R-18 a Risk: low run with a FAIL, and a passed one whose A to B the PR made by hand through X: --tier low is refused for both" \
  || { bad "R-18 low tier granted: failed run rc=$RC1, hand-made chain rc=$RC2"; tail -1 "$T/r205.txt"; tail -1 "$T/out.txt"; }

ACC=false FORCE=1 VERDICT=PASS runpr 212 low f212.txt "printf 'C\n' > f212.txt"
[ -n "$(mj "$RUNS/$RUNID/meta.json" 'm.get("verdict_forced") or ""')" ] || { echo "setup failed: forced PASS of run 212"; cat "$T/v.txt"; exit 1; }
$DP --review-pr 212 --packet --tier low --repo "$C" > "$T/out.txt" 2>&1; RC1=$?
[ $RC1 -eq 2 ] && ! grep -q '^PACKET' "$T/out.txt" \
  && ok "R-18 a Risk: low run whose exact change is the PR's commit but whose PASS was forced: --tier low is refused" \
  || { bad "R-18 a forced PASS lowered the tier, rc=$RC1"; tail -1 "$T/out.txt"; }

echo "== R-33 phase reviews read deletions; binary and cut files count for no review"
D3="$T/del"; phrepo "$D3" '# Plan\n## Phase 1 - x\nExecutor: deepseek-flash\nRisk: low\nFiles: gone.py\nAcceptance:\n- `test ! -e gone.py`\n' gone.py 'g = 1\n'
phrun "$D3" "rm gone.py"; X33=$RUN
$DP --review "$X33" --via qwen --model fake/m --repo "$D3" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && [ "$(mj "$D3/.git/concord/$X33/meta.json" 'm["reviews"][-1].get("files")')" = "['gone.py']" ] \
  && ok "R-33 a deletion-only phase takes a direct review, recorded for the deleted file" || { bad "R-33 deletion-only direct review rc=$RC"; tail -2 "$T/out.txt"; }
B3="$T/bin3"; phrepo "$B3" '# Plan\n## Phase 1 - x\nExecutor: deepseek-flash\nRisk: medium\nFiles: a.py, big.txt, bin.dat\nAcceptance:\n- `grep -q y a.py`\n' a.py 'x = 1\n'
phrun "$B3" "printf 'y = 1\n' > a.py; printf 'z\000z\n' > bin.dat; python3 -c 'open(\"big.txt\", \"w\").write(\"line of text\n\" * 26000)'"; X34=$RUN
$DP --verdict "$X34" PASS --repo "$B3" > "$T/v.txt" 2>&1 || { echo "setup failed: PASS"; cat "$T/v.txt"; exit 1; }
cp "$T/clean.txt" "$T/c34.txt"; record "$X34" concord:reviewer-opus55 "$T/c34.txt" "$B3" > "$T/rec.txt" 2>&1 || { echo "setup failed: record"; cat "$T/rec.txt"; exit 1; }
report "$B3"; L=$(grep -F -- "- phase 1 (run $X34)" "$T/ov.txt")
case "$L" in *big.txt*bin.dat*) case "$L" in *a.py*) R33=0;; *) R33=1;; esac;; *) R33=0;; esac
[ $R33 = 1 ] && [ "$(mj "$B3/.git/concord/$X34/meta.json" '(m["reviews"][-1].get("binary"), "big.txt" in (m["reviews"][-1].get("truncated") or []))')" = "(['bin.dat'], True)" ] \
  && ok "R-33 a packet cut at its cap and a binary file: the review entry names both, and the report lists them (not a.py) as unreviewed" \
  || { bad "R-33 binary or cut file counted as reviewed: '$L'"; cat "$T/ov.txt"; }

echo "== R-34 every PR state has a path"
newpr 207 x.bin 'z\000z\n'
$DP --review-pr 207 --exclude x.bin --user-approved "waive x.bin, it is generated data" --repo "$C" > "$T/out.txt" 2>&1; RC1=$?; cp "$T/out.txt" "$T/r207.txt"; st 207
[ $RC1 -eq 0 ] && has "REVIEWED at medium WITH OWNER WAIVER: x.bin excluded" && [ $RC -eq 0 ] \
  && ok "R-34 a binary-only PR: --exclude with the owner's words naming the file records the waiver; the head is REVIEWED WITH OWNER WAIVER" \
  || { bad "R-34 binary-only waiver: review rc=$RC1 status rc=$RC"; tail -1 "$T/r207.txt"; head -1 "$T/out.txt"; }
git -C "$C" push -q origin "main:refs/pull/208/head" && prjson 208
st 208
! has ": REVIEWED" && [ $RC -eq 1 ] && ok "R-34 an empty PR (head = base) is not REVIEWED, exit 1" || { bad "R-34 empty PR rc=$RC"; head -1 "$T/out.txt"; }
newpr 209 m209.py 'm = 209\n'; prjson 209 ', "state": "MERGED"'
C0=$(calls); flash 209 fake/m --tier medium; RC1=$?
[ $RC1 -eq 2 ] && [ "$(calls)" = "$C0" ] && has "MERGED" && ok "R-34 a merged PR is refused before any model call (exit 2)" || { bad "R-34 merged PR reviewed rc=$RC1"; tail -1 "$T/out.txt"; }
newpr 210 m210.py 'm = 210\n'; printf '{"baseRefName": "main", "headRefName": "pr210", "title": "t", "body": "b"}\n' > "$T/pr210.json"
flash 210 fake/m --tier medium; RC1=$?
[ $RC1 -eq 75 ] && ok "R-34 gh reports no headRefOid: exit 75 (unverified head), as when it reports another head" || { bad "R-34 missing gh head rc=$RC1"; tail -1 "$T/out.txt"; }

echo "== R-35 a retarget that keeps the merge base starts the coverage over"
newpr 211 r211.py 'r = 211\n'
opus 211 medium concord:reviewer-opus55 "$T/clean.txt" || { echo "setup failed: PR 211 review"; cat "$T/out.txt"; exit 1; }
git -C "$C" push -q origin "main:refs/heads/rel" || { echo "setup failed: rel"; exit 1; }
printf '{"baseRefName": "rel", "headRefName": "pr211", "headRefOid": "%s", "title": "t", "body": "b"}\n' "$(hd 211)" > "$T/pr211.json"
st 211
! has ": REVIEWED" && [ $RC -eq 1 ] && ok "R-35 the same head retargeted from main to rel at the same commit: the earlier review is uncredited, exit 1" \
  || { bad "R-35 retarget kept coverage rc=$RC"; head -1 "$T/out.txt"; }

echo "== reviews recorded by 3.3.0 or earlier are credited under that version's rules"
flash 201 fake/m --tier low; RC1=$?; D=$(sed -n 's/^PR REVIEW \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
[ $RC1 -eq 0 ] && [ -n "$D" ] || { echo "setup failed: PR 201 review"; cat "$T/out.txt"; exit 1; }
unset_keys "$RUNS/$D/meta.json" rc; st 201
has "REVIEWED at low" && [ $RC -eq 0 ] && ok "3.3.0 record: a model review entry without its exit status counts by its verdict (REVIEWED at low)" \
  || { bad "3.3.0 model review without rc lost its credit, rc=$RC"; head -2 "$T/out.txt"; }
newpr 214 s214.py 's = 214\n'
opus 214 medium concord:reviewer-opus55 "$T/clean.txt" || { echo "setup failed: PR 214 review"; cat "$T/out.txt"; exit 1; }
for m in "$RUNS"/pr214-*/meta.json; do unset_keys "$m" base; done
printf '{"baseRefName": "rel", "headRefName": "pr214", "headRefOid": "%s", "title": "t", "body": "b"}\n' "$(hd 214)" > "$T/pr214.json"
st 214
has "REVIEWED at medium" && [ $RC -eq 0 ] && ok "3.3.0 record: a PR review entry without its base keeps merge base and head as its identity (a retarget keeping the merge base stays REVIEWED)" \
  || { bad "3.3.0 PR review without base lost its credit, rc=$RC"; head -2 "$T/out.txt"; }
unset_keys "$B3/.git/concord/$X34/meta.json" files binary truncated; report "$B3"
! grep -qF -- "- phase 1 (run $X34)" "$T/ov.txt" && grep -q '^## Overrides' "$T/ov.txt" \
  && ok "3.3.0 record: a phase review entry without its files covers the whole graded change (no Overrides line for the phase)" \
  || { bad "3.3.0 phase review without files lost its credit"; cat "$T/ov.txt"; }

echo "== R-36 pi's malformed-answer retry runs on the shipped review route"
P="$T/pi"; phrepo "$P" '# Plan\n## Phase 1 - x\nExecutor: deepseek-flash\nRisk: low\nFiles: a.py\nAcceptance:\n- `grep -q y a.py`\n' a.py 'x = 1\n'
phrun "$P" "printf 'y = 1\n' > a.py"; X36=$RUN
CONCORD_NO_SANDBOX=1 $DP --review "$X36" --repo "$P" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has ", retried" && ! has Traceback && [ "$(mj "$P/.git/concord/$X36/meta.json" '(m["reviews"][-1]["verdict"], m["reviews"][-1].get("tokens"))')" = "('CLEAN', 250)" ] \
  && ok "R-36 the default (pi) reviewer answers prose, then JSON: the retry runs, its answer is recorded, and both attempts' tokens count" \
  || { bad "R-36 pi retry rc=$RC"; tail -4 "$T/out.txt"; }

echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
