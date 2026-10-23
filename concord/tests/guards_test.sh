#!/bin/bash
# concord.py guards (2026-10-20, PLAN_kit-guards): the 4th start of a phase after three EXECUTOR failures is refused
# (exit 8) and a PASS whose best review is below the phase's tier is refused (exit 9); --user-approved records the
# user's go-ahead for either. No network: fake qwen executor/reviewer.
# Run: bash ~/.claude/concord/tests/guards_test.sh   (exit 0 = all passed).
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/guards-test.XXXXXX")" && pwd -P)"; export T
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
# Prefer the developer dir's real git/python3 over the /usr/bin xcrun shims (they print cache errors in the sandbox).
XDEV="$(xcode-select -p 2>/dev/null)"; [ -n "$XDEV" ] && [ -x "$XDEV/usr/bin/git" ] && [ -x "$XDEV/usr/bin/python3" ] && export PATH="$XDEV/usr/bin:$PATH"
export PATH="$T/bin:$PATH" HOME="$T/home"
DP="python3 $T/concord/concord.py"
R="$T/repo"; RUNS="$R/.git/concord"; LOCK="$R/.git/concord.lock"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
has(){ grep -F -- "$1" "$T/out.txt" > /dev/null; }
calls(){ [ -f "$T/qwen_calls" ] && wc -l < "$T/qwen_calls" | tr -d ' ' || echo 0; }
ndirs(){ find "$RUNS" -mindepth 1 -maxdepth 1 -type d ! -name ledger | wc -l | tr -d ' '; }
rid(){ sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1; }
meta(){ python3 -I -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))" "$RUNS/$1/meta.json" "$2"; }
# run PHASE PLAN [args]: one fake executor run (appends to a.py unless FA says otherwise); output in out.txt
run(){ local ph=$1 pl=$2; shift 2
  FAKE_ACTIONS="${FA:-echo '# r' >> a.py}" $DP "$ph" --plan "$pl" --via qwen --model fake/m --no-baseline --repo "$R" "$@" > "$T/out.txt" 2>&1; }
verdict(){ $DP --verdict "$@" --repo "$R" > "$T/out.txt" 2>&1; }
flash(){ FAKE_ACTIONS="${FA:-}" $DP --review "$1" --via qwen --model fake/m --repo "$R" > /dev/null 2>&1; }
opus(){ $DP --review-record "$1" --reviewer "$2" --file "$T/clean.txt" --repo "$R" > /dev/null 2>&1; }
printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n' > "$T/clean.txt"
phase(){ printf '## Phase %s - p%s\nExecutor: deepseek-flash\n%bFiles: a.py\nAcceptance:\n- `%s`\n' "$1" "$1" "$2" "$3"; }
mkdir -p "$R" && ( cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > a.py; printf 'assert True\n' > t.py; printf '.claude/\n' > .gitignore; git add -A && git commit -qm init
  { echo '# Plan'; phase 1 '' 'grep -q 2 a.py'; phase 2 '' 'grep -q 2 a.py'; phase 3 'Risk: medium\n' 'grep -q 2 a.py'
    phase 4 'Risk: high\n' 'grep -q 2 a.py'; phase 5 'Risk: low\n' 'grep -q 2 a.py'
    phase 6 'Risk: high\nBaseline: skip\n' 'grep -q 2 a.py'; phase 7 '' 'python3 t.py'; } > PLAN_G.md
  { echo '# Plan'; phase 1 '' 'grep -q 2 a.py'; } > PLAN_H.md ) || { echo "setup failed"; exit 1; }

echo "== attempt cap"
for i in 1 2 3; do
  run 1 PLAN_G.md; X=$(rid); [ -n "$X" ] || { echo "setup failed: run $i"; cat "$T/out.txt"; exit 1; }
  verdict "$X" FAIL --cause EXECUTOR
done
C0=$(calls); N0=$(ndirs)
run 1 PLAN_G.md; RC=$?
[ $RC -eq 8 ] && [ "$(calls)" = "$C0" ] && [ "$(ndirs)" = "$N0" ] && [ ! -e "$LOCK" ] && grep -q "^REFUSED:" "$T/out.txt" \
  && has "--user-approved" && ok "4th start refused (exit 8): no executor call, no run dir, no lock" \
  || { bad "4th start rc=$RC"; tail -3 "$T/out.txt"; }
for DRY in "" --dry-run; do
  N0=$(ndirs); $DP --begin 1 --label implementer --plan PLAN_G.md $DRY --repo "$R" > "$T/out.txt" 2>&1; RC=$?
  [ $RC -eq 0 ] && $DP --abort last --repo "$R" > /dev/null 2>&1
  [ $RC -eq 8 ] && [ "$(ndirs)" = "$N0" ] && [ ! -e "$LOCK" ] && ok "--begin $DRY refused (exit 8)" || bad "--begin $DRY rc=$RC"
done
FAKE_ACTIONS=true $DP --dry-run 1 --plan PLAN_G.md --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "DRY RUN" && ok "a dry run is not refused" || { bad "dry run rc=$RC"; tail -2 "$T/out.txt"; }
run 2 PLAN_G.md; RC=$?; S1=$(rid)
[ $RC -eq 0 ] && [ -n "$S1" ] && ok "another phase is not blocked" || { bad "other phase rc=$RC"; tail -2 "$T/out.txt"; }
run 1 PLAN_H.md; RC=$?
[ $RC -eq 0 ] && ok "another plan file with the same phase is not blocked" || { bad "other plan rc=$RC"; tail -2 "$T/out.txt"; }
git -C "$R" worktree add -q "$T/wt" -b wt && cp "$R/PLAN_G.md" "$T/wt/"
FAKE_ACTIONS=true $DP 1 --plan PLAN_G.md --via qwen --model fake/m --no-baseline --repo "$T/wt" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && ok "a worktree with the same plan path is not blocked" || { bad "worktree rc=$RC"; tail -2 "$T/out.txt"; }
run 1 PLAN_G.md --user-approved "   "; RC=$?
[ $RC -eq 8 ] && ok "a whitespace-only --user-approved is no approval" || bad "blank approval rc=$RC"
run 1 PLAN_G.md --user-approved "$(printf 'go\nahead')"; RC=$?; RA=$(rid)
[ $RC -eq 0 ] && [ -n "$RA" ] && grep -qF "user approved a run beyond the attempt cap: go ahead" "$RUNS/$RA/report.md" \
  && ok "--user-approved starts the run; the quote is one report line" || { bad "approved run rc=$RC"; tail -3 "$T/out.txt"; }
opus "$RA" reviewer-opus48; verdict "$RA" PASS
run 1 PLAN_G.md; RC=$?
[ $RC -eq 0 ] && ok "a PASS resets the count" || { bad "after PASS rc=$RC"; tail -2 "$T/out.txt"; }

echo "== what counts"
verdict "$S1" FAIL --cause EXECUTOR; verdict "$S1" FAIL --cause EXECUTOR
run 2 PLAN_G.md; verdict "$(rid)" FAIL --cause PLAN_GAP
run 2 PLAN_G.md; verdict "$(rid)" FAIL --cause EXECUTOR
mkdir -p "$RUNS/20000101-000000-junk-p2" "$RUNS/20000101-000001-junk-p2"
printf '[]' > "$RUNS/20000101-000000-junk-p2/meta.json"
printf '{"run_id": "20000101-000001-junk-p2", "plan": "PLAN_G.md", "phase": 2, "verdict": "FA' > "$RUNS/20000101-000001-junk-p2/meta.json"
run 2 PLAN_G.md; RC=$?
[ $RC -eq 0 ] && ! has "Traceback" \
  && ok "two counted fails: other causes, a second verdict on one run and broken meta.json files do not count" \
  || { bad "count rc=$RC"; tail -2 "$T/out.txt"; }
rm -rf "$RUNS"/20000101-*

echo "== review tier"
run 3 PLAN_G.md; M=$(rid); flash "$M"
verdict "$M" PASS; RC=$?
[ $RC -eq 9 ] && [ "$(meta "$M" verdict)" = "None" ] && grep -q "^REFUSED:" "$T/out.txt" && has "reviewer-opus55" && has "--user-approved" \
  && ok "medium + flash only: --verdict PASS refused (exit 9)" || { bad "medium/flash rc=$RC"; tail -2 "$T/out.txt"; }
$DP --close-round "$M" --verdict-result PASS --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 9 ] && [ "$(meta "$M" verdict)" = "None" ] && ok "medium + flash only: --close-round PASS refused (exit 9)" || bad "close-round rc=$RC"
opus "$M" "Reviewer Opus48"; verdict "$M" PASS; RC=$?
[ $RC -eq 0 ] && [ "$(meta "$M" verdict)" = "PASS" ] && ok "medium + 'Reviewer Opus48' accepted (names matched like the rest of the dispatcher)" \
  || { bad "medium/opus48 rc=$RC"; tail -2 "$T/out.txt"; }
verdict "$M" PASS --user-approved "fine" --note n0
[ "$(meta "$M" verdict_note)" = "n0" ] && ok "--user-approved on an on-tier PASS changes nothing" || bad "note: $(meta "$M" verdict_note)"
run 4 PLAN_G.md; H=$(rid); opus "$H" reviewer-opus48
verdict "$H" PASS; RC=$?
[ $RC -eq 9 ] && has "reviewer-opus55" && ok "high + reviewer-opus48 refused" || bad "high/opus48 rc=$RC"
verdict "$H" PASS --user-approved "ok by me" --note n1; RC=$?
[ $RC -eq 0 ] && [ "$(meta "$H" verdict_note)" = "tier waived (user: ok by me); n1" ] && ok "a waived PASS records the quote in the note" \
  || { bad "waiver rc=$RC note=$(meta "$H" verdict_note)"; tail -2 "$T/out.txt"; }
opus "$H" reviewer-opus55; verdict "$H" PASS; RC=$?
[ $RC -eq 0 ] && ok "high + reviewer-opus55 accepted" || bad "high/opus55 rc=$RC"
run 5 PLAN_G.md; L=$(rid)
verdict "$L" FAIL --cause FLAKY; RC=$?
[ $RC -eq 0 ] && ok "FAIL needs no review" || bad "FAIL rc=$RC"
verdict "$L" PASS; RC=$?
[ $RC -eq 9 ] && ok "low + no review refused" || bad "low/none rc=$RC"
FA='echo no json here' flash "$L"
[ "$(python3 -I -c 'import json,sys; print([r.get("verdict") for r in json.load(open(sys.argv[1])).get("reviews", [])])' "$RUNS/$L/meta.json")" = "['UNPARSED']" ] \
  || { echo "setup failed: no UNPARSED review"; exit 1; }
verdict "$L" PASS; RC=$?
[ $RC -eq 9 ] && ok "low + only an UNPARSED review refused" || bad "low/unparsed rc=$RC"
run 3 PLAN_G.md; X=$(rid); flash "$X"
python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); m["risk"]=["high"]; json.dump(m, open(sys.argv[1], "w"))' "$RUNS/$X/meta.json"
verdict "$X" PASS; RC=$?
[ $RC -eq 9 ] && ! has "Traceback" && has "reviewer-opus55" && ok "a risk that is not a string counts as medium" \
  || { bad "list risk rc=$RC"; tail -2 "$T/out.txt"; }
flash "$L"; verdict "$L" PASS; RC=$?
[ $RC -eq 0 ] && ok "low + flash accepted" || { bad "low/flash rc=$RC"; tail -2 "$T/out.txt"; }
run 6 PLAN_G.md; K=$(rid); flash "$K"; verdict "$K" PASS; RC=$?
[ $RC -eq 0 ] && ok "Baseline: skip phase (Risk high) + flash accepted" || { bad "skip/flash rc=$RC"; tail -2 "$T/out.txt"; }
FA='echo "# r" >> a.py; echo "# t" >> t.py' run 7 PLAN_G.md; F=$(rid); flash "$F"
[ "$(meta "$F" acceptance_files_changed)" = "['t.py']" ] || { echo "setup failed: acceptance file not changed"; exit 1; }
verdict "$F" PASS --force; RC=$?
[ $RC -eq 9 ] && ok "--force does not waive the tier" || bad "forced rc=$RC"
verdict "$F" PASS --force --user-approved "go" --note n2; RC=$?
[ $RC -eq 0 ] && [ "$(meta "$F" verdict_note)" = "forced: acceptance files changed; tier waived (user: go); n2" ] \
  && ok "forced + waived PASS: both prefixes, in order" || bad "forced+waived rc=$RC note=$(meta "$F" verdict_note)"

echo "== plugin names (agents are concord:<name> inside the Claude Code plugin)"
run 3 PLAN_G.md; P=$(rid)
$DP --review "$P" --packet --repo "$R" > "$T/out.txt" 2>&1
has "subagent_type concord:reviewer-opus55 with prompt" && ok "the packet hint names the plugin agent" || bad "packet hint"
verdict "$P" PASS; RC=$?
[ $RC -eq 9 ] && has "needs concord:reviewer-opus55" && ok "the tier refusal names concord:reviewer-opus55" || bad "tier refusal name rc=$RC"
opus "$P" concord:reviewer-opus48; verdict "$P" PASS; RC=$?
[ $RC -eq 0 ] && [ "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["reviews"][-1]["reviewer"])' "$RUNS/$P/meta.json")" = reviewer-opus48 ] \
  && ok "concord:reviewer-opus48 meets the medium tier and is stored as reviewer-opus48" || { bad "plugin reviewer rc=$RC"; tail -2 "$T/out.txt"; }
$DP --begin 5 --label Concord:Implementer --plan PLAN_G.md --repo "$R" > "$T/out.txt" 2>&1; RC=$?
B=$(sed -n 's/.*concord.py --end \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
[ $RC -eq 0 ] && [ -n "$B" ] && ok "--begin --label Concord:Implementer is accepted as implementer" || { bad "plugin label rc=$RC"; tail -2 "$T/out.txt"; }
[ -z "$B" ] || $DP --abort "$B" --repo "$R" > /dev/null 2>&1

echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
