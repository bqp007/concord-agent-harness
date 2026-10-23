#!/bin/bash
# concord.py guards (2026-10-20, PLAN_kit-guards; lean revision 2026-10-23): the 4th start of a phase after three
# EXECUTOR failures is refused (exit 8) and --user-approved records the user's go-ahead; what counts as an attempt;
# the plugin agent names (concord:<name>) in the packet hint, --review-record --reviewer and --begin --label.
# No network: fake qwen executor.
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
sh -c "${FAKE_ACTIONS:-true}"; exit 0
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
# run PHASE PLAN [args]: one fake executor run that appends to a.py; output in out.txt
run(){ local ph=$1 pl=$2; shift 2
  FAKE_ACTIONS="echo '# r' >> a.py" $DP "$ph" --plan "$pl" --via qwen --model fake/m --no-baseline --repo "$R" "$@" > "$T/out.txt" 2>&1; }
verdict(){ $DP --verdict "$@" --repo "$R" > "$T/out.txt" 2>&1; }
printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n' > "$T/clean.txt"
phase(){ printf '## Phase %s - p%s\nExecutor: deepseek-flash\n%bFiles: a.py\nAcceptance:\n- `%s`\n' "$1" "$1" "$2" "$3"; }
mkdir -p "$R" && ( cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > a.py; printf '.claude/\n' > .gitignore; git add -A && git commit -qm init
  { echo '# Plan'; phase 1 '' 'grep -q 2 a.py'; phase 2 '' 'grep -q 2 a.py'; phase 3 'Risk: medium\n' 'grep -q 2 a.py'
    phase 5 'Risk: low\n' 'grep -q 2 a.py'; } > PLAN_G.md
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
verdict "$RA" PASS
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

echo "== plugin names (agents are concord:<name> inside the Claude Code plugin)"
run 3 PLAN_G.md; P=$(rid)
$DP --review "$P" --packet --repo "$R" > "$T/out.txt" 2>&1
has "subagent_type concord:reviewer-opus55 with prompt" && ok "the packet hint names the plugin agent" || bad "packet hint"
$DP --review-record "$P" --reviewer concord:reviewer-opus48 --file "$T/clean.txt" --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && [ "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["reviews"][-1]["reviewer"])' "$RUNS/$P/meta.json")" = reviewer-opus48 ] \
  && ok "--review-record --reviewer concord:reviewer-opus48 is stored as reviewer-opus48" || { bad "plugin reviewer rc=$RC"; tail -2 "$T/out.txt"; }
$DP --begin 5 --label Concord:Implementer --plan PLAN_G.md --repo "$R" > "$T/out.txt" 2>&1; RC=$?
B=$(sed -n 's/.*concord.py --end \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
[ $RC -eq 0 ] && [ -n "$B" ] && ok "--begin --label Concord:Implementer is accepted as implementer" || { bad "plugin label rc=$RC"; tail -2 "$T/out.txt"; }
[ -z "$B" ] || $DP --abort "$B" --repo "$R" > /dev/null 2>&1

echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
