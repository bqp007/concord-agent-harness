#!/bin/bash
# concord.py guards: the plan-verifier gate (the verifier's read, the hash its approval binds to, who may lift it), an
# open --begin run holding its files, the plugin agent names (concord:<name>) in the packet hint, --review-record
# --reviewer and --begin --label, the drift brakes, the drift hook and a reported plan. No network: fake qwen executor.
# Run: bash ~/.claude/concord/tests/guards_test.sh   (exit 0 = all passed).
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/guards-test.XXXXXX")" && pwd -P)"; export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/concord" "$T/home/.claude"
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
cp -p "$SRC"/drift_hook.sh "$T/concord/" 2>/dev/null || true       # a missing hook script fails its own check
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
R="$T/repo"; RUNS="$R/.git/concord"
. "$(dirname "$0")/lib.sh"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
has(){ grep -F -- "$1" "$T/out.txt" > /dev/null; }
calls(){ [ -f "$T/qwen_calls" ] && wc -l < "$T/qwen_calls" | tr -d ' ' || echo 0; }
rid(){ sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1; }
bid(){ sed -n 's/.*concord.py --end \([^ ]*\).*/\1/p' "$T/out.txt" | head -1; }
# run PHASE PLAN [args]: one fake executor run that appends to a.py; output in out.txt
run(){ local ph=$1 pl=$2; shift 2
  FAKE_ACTIONS="echo '# r' >> a.py" $DP "$ph" --plan "$pl" --via qwen --model fake/m --no-baseline --repo "$R" "$@" > "$T/out.txt" 2>&1; }
printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n' > "$T/clean.txt"
phase(){ printf '## Phase %s - p%s\nExecutor: deepseek-flash\n%bFiles: %s\nAcceptance:\n- `%s`\n' "$1" "$1" "$2" "${4:-a.py}" "$3"; }
mkdir -p "$R" && ( cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > a.py; printf '.claude/\n' > .gitignore; git add -A && git commit -qm init
  { echo '# Plan'; phase 1 '' 'grep -q 2 a.py'; phase 2 '' 'grep -q 2 a.py'; phase 3 'Risk: medium\n' 'grep -q 2 a.py'
    phase 5 'Risk: low\n' 'grep -q 2 a.py'; } > PLAN_G.md ) || { echo "setup failed"; exit 1; }
approve PLAN_G.md "$R" || exit 1

# mkv NAME TEXT: repo $T/NAME (V) holding PLAN_V.md: a Tier: plan, an Open questions section, TEXT, then phase 1
mkv(){ V="$T/$1"; mkdir -p "$V" && ( cd "$V" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > a.py; printf 'y = 1\n' > b.py; git add -A && git commit -qm init
  { printf '# Plan\nTier: M\nSize: ~4 lines\nETA: 10 min\n\n## Open questions\n- Q1 none\n%b\n' "${2:-}"; phase 1 '' 'grep -q 2 a.py'; } > PLAN_V.md ) \
  || { echo "setup failed: $1"; exit 1; }; }
P2='\n### Phase 2 - second\nExecutor: deepseek-flash\nFiles: b.py\nAcceptance:\n- `grep -q 2 b.py`\n'
vrun(){ FAKE_ACTIONS=true $DP "${1:-1}" --plan PLAN_V.md --via qwen --model fake/m --no-baseline --repo "$V" > "$T/out.txt" 2>&1; }
vbegin(){ local ph=$1; shift; $DP --begin "$ph" --label implementer --plan PLAN_V.md "$@" --repo "$V" > "$T/out.txt" 2>&1; }
vabort(){ $DP --abort last --repo "$V" > /dev/null 2>&1; }
vverdict(){ printf 'VERDICT: APPROVE\nPLAN-HASH: %s\n' "$1" > "$T/v.txt"; $DP --plan-verdict "$T/v.txt" --plan PLAN_V.md --repo "$V" > "$T/out.txt" 2>&1; }

echo "== the plan-verifier's read, and the text its approval binds to"
mkv v1; $DP --lint 1 --plan PLAN_V.md --repo "$V" > "$T/out.txt" 2>&1
PRD=$(sed -n 's/^PLAN-READ: //p' "$T/out.txt" | head -1)
[ -n "$PRD" ] && [ -f "$PRD" ] && [ "$(basename "$PRD")" = "$(vhash "$V/PLAN_V.md").md" ] && [ "$(dirname "$(dirname "$PRD")")" = "$V/.git/concord" ] \
  && ok "--lint writes the plan read <runs root>/plan-reads/<hash>.md and prints PLAN-READ: <path>" || bad "--lint printed no usable PLAN-READ line: ${PRD:-none}"
mkv v2; vverdict 0123456789abcdef; RC=$?; vrun; RC2=$?
[ $RC -ne 0 ] && [ $RC2 -eq 11 ] && ok "an APPROVE quoting a hash with no plan read is refused and opens nothing (a run exits 11)" || bad "unread hash: verdict rc=$RC, then run rc=$RC2"
mkv v3; $DP --lint 1 --plan PLAN_V.md --repo "$V" > "$T/out.txt" 2>&1; PRD=$(sed -n 's/^PLAN-READ: //p' "$T/out.txt" | head -1)
if [ -f "$PRD" ]; then printf '\nsneaked in after the read\n' >> "$PRD"; vverdict "$(basename "$PRD" .md)"; RC=$?; vrun; RC2=$?
  [ $RC -ne 0 ] && [ $RC2 -eq 11 ] && ok "a plan read whose content no longer hashes to its name is refused and opens nothing" || bad "altered read: verdict rc=$RC, then run rc=$RC2"
else bad "altered read: --lint wrote no plan read to alter"; fi
mkv v4; $DP --lint 1 --plan PLAN_V.md --repo "$V" > /dev/null 2>&1; H1=$(vhash "$V/PLAN_V.md")
perl -pi -e 's/grep -q 2 a.py/grep -q 3 a.py/' "$V/PLAN_V.md"; vverdict "$H1"; vbegin 1; RC=$?
[ $RC -eq 11 ] && ok "a plan edited after the verifier's read: the approval of the read text opens nothing for the new text (--begin exits 11)" \
  || { bad "edit after the read: --begin rc=$RC"; [ $RC -eq 0 ] && vabort; }
mkv v5 "\n## Handoff\nnotes for the executor\n$P2"
approve PLAN_V.md "$V" || exit 1; vbegin 2; RC=$?; [ $RC -eq 0 ] && vabort
perl -pi -e 's/grep -q 2 b.py/grep -q 7 b.py/' "$V/PLAN_V.md"; vbegin 2; RC2=$?; [ $RC2 -eq 0 ] && vabort
[ $RC -eq 0 ] && [ $RC2 -eq 11 ] && ok "a ### phase under ## Handoff is part of the approved text (edited: --begin exits 11)" || bad "phase under Handoff: rc=$RC then $RC2"
mkv v6 "$P2"
approve PLAN_V.md "$V" || exit 1; vbegin 2; RC=$?; [ $RC -eq 0 ] && vabort
perl -pi -e 's/grep -q 2 b.py/grep -q 7 b.py/' "$V/PLAN_V.md"; vbegin 2; RC2=$?; [ $RC2 -eq 0 ] && vabort
[ $RC -eq 0 ] && [ $RC2 -eq 11 ] && ok "a ### phase inside ## Open questions is part of the approved text (edited: --begin exits 11)" || bad "phase under Open questions: rc=$RC then $RC2"
# S41: only the exact headings Open questions, Handoff and Passes are skipped; a longer heading is approved text
mkv v10 "\n## Handoff contract\nthe executor returns exit code 2 on refusal\n"
approve PLAN_V.md "$V" || exit 1; vbegin 1; RC=$?; [ $RC -eq 0 ] && vabort
perl -pi -e 's/exit code 2/exit code 3/' "$V/PLAN_V.md"; vbegin 1; RC2=$?; [ $RC2 -eq 0 ] && vabort
[ $RC -eq 0 ] && [ $RC2 -eq 11 ] && ok "a line under ## Handoff contract is approved text (edited after the APPROVE: --begin exits 11)" || bad "edit under Handoff contract: rc=$RC then $RC2"
mkv v11 "\n## Handoff\nnotes for the executor: marker\n"
approve PLAN_V.md "$V" || exit 1; vbegin 1; RC=$?; [ $RC -eq 0 ] && vabort
perl -pi -e 's/marker/other words/' "$V/PLAN_V.md"; vbegin 1; RC2=$?; [ $RC2 -eq 0 ] && vabort
[ $RC -eq 0 ] && [ $RC2 -eq 0 ] && ok "the prose under ## Handoff can still be edited after the APPROVE (--begin still opens)" || bad "edit under Handoff: rc=$RC then $RC2"
# a skipped section ends at the next ATX heading of level 1 or 2 (up to three leading spaces), not only at a line that starts with `## `
mkv v13 "\n## Handoff\nnotes for the executor\n# Interfaces\nthe executor returns exit code 2 on refusal\n"
mkv v14 "\n## Handoff\nnotes for the executor\n   ## Interfaces\nthe executor returns exit code 2 on refusal\n"
for NAME in v13 v14; do V="$T/$NAME"
  approve PLAN_V.md "$V" || exit 1; vbegin 1; RC=$?; [ $RC -eq 0 ] && vabort
  perl -pi -e 's/exit code 2/exit code 3/' "$V/PLAN_V.md"; vbegin 1; RC2=$?; [ $RC2 -eq 0 ] && vabort
  [ $RC -eq 0 ] && [ $RC2 -eq 11 ] && ok "a line under a heading that follows ## Handoff ($NAME: $([ $NAME = v13 ] && echo '# Interfaces' || echo '   ## Interfaces')) is approved text (edited after the APPROVE: --begin exits 11)" \
    || bad "edit under the heading after Handoff ($NAME): rc=$RC then $RC2"
done
# a code fence never hides a heading from the approval (a fence opened under ## Handoff and closed by a later block's
# closing line still lets ## Design end the skip), and a heading inside a closed fence never starts a skipped section
mkv v15 '\n## Handoff\n```\nnotes\n## Design\nthe executor returns exit code 2 on refusal\n```text\ndiagram\n```\n'
approve PLAN_V.md "$V" || exit 1; vbegin 1; RC=$?; [ $RC -eq 0 ] && vabort
perl -pi -e 's/exit code 2/exit code 3/' "$V/PLAN_V.md"; vbegin 1; RC2=$?; [ $RC2 -eq 0 ] && vabort
[ $RC -eq 0 ] && [ $RC2 -eq 11 ] && ok "a fence opened under ## Handoff hides no later heading (an edit under ## Design: --begin exits 11)" \
  || bad "fence under Handoff hid ## Design: rc=$RC then $RC2"
mkv v16 '\n### Phase 2 - second\nExecutor: deepseek-flash\nSteps:\n```md\n## Handoff\n```\nFiles: b.py\nAcceptance:\n- `grep -q 2 b.py`\n'
approve PLAN_V.md "$V" || exit 1; vbegin 1; RC=$?; [ $RC -eq 0 ] && vabort
perl -pi -e 's/grep -q 2 b.py/grep -q 3 b.py/' "$V/PLAN_V.md"; vbegin 1; RC2=$?; [ $RC2 -eq 0 ] && vabort
[ $RC -eq 0 ] && [ $RC2 -eq 11 ] && ok "a fenced ## Handoff line inside a phase hides none of the phase (an edited acceptance command: --begin exits 11)" \
  || bad "fenced Handoff inside a phase: rc=$RC then $RC2"
# once a phase starts, a skip heading inside it hides nothing: the phase's lines, as the dispatcher cuts the phase, stay
# approved text (v17: ## Handoff inside a level-1 phase; v18: an indented ## Handoff, which does not end a ### phase)
mkv v17 '\n# Phase 2 - second\nExecutor: deepseek-flash\nFiles: b.py\n## Handoff\nnotes for the executor\nAcceptance:\n- `grep -q 2 b.py`\n'
mkv v18 '\n### Phase 2 - second\nExecutor: deepseek-flash\nFiles: b.py\n   ## Handoff\nnotes for the executor\nAcceptance:\n- `grep -q 2 b.py`\n'
for NAME in v17 v18; do V="$T/$NAME"
  approve PLAN_V.md "$V" || exit 1; vbegin 1; RC=$?; [ $RC -eq 0 ] && vabort
  perl -pi -e 's/grep -q 2 b.py/grep -q 3 b.py/' "$V/PLAN_V.md"; vbegin 1; RC2=$?; [ $RC2 -eq 0 ] && vabort
  [ $RC -eq 0 ] && [ $RC2 -eq 11 ] && ok "a ## Handoff inside a phase hides none of the phase ($NAME: an edited acceptance command below it: --begin exits 11)" \
    || bad "Handoff inside a phase ($NAME) hid its acceptance: rc=$RC then $RC2"
done
mkv v7; { printf '# Plan\nSize: ~4 lines\n\n'; phase 1 '' 'grep -q 2 a.py'; } > "$V/PLAN_V.md"
vbegin 1; RC=$?; [ $RC -eq 0 ] && vabort
approve PLAN_V.md "$V" || exit 1; vbegin 1; RC2=$?; [ $RC2 -eq 0 ] && vabort
[ $RC -eq 11 ] && [ $RC2 -eq 0 ] && ok "a plan with no Tier: line needs an APPROVE (exit 11, then 0 once approved)" || bad "plan without Tier:: rc=$RC then $RC2"
mkv v8; vbegin 1 --user-approved "go on after the drift"; RC=$?; [ $RC -eq 0 ] && vabort
[ $RC -eq 11 ] && ok "no owner words open the verifier gate: --begin --user-approved on an unverified plan exits 11" || bad "--user-approved on an unverified plan: rc=$RC"
mkv v9; approve PLAN_V.md "$V" || exit 1; vrun; RC=$?; [ $RC -eq 0 ] && [ -n "$(rid)" ] || { echo "setup failed: first run of v9"; cat "$T/out.txt"; exit 1; }
perl -pi -e 's/grep -q 2 a.py/grep -q 5 a.py/' "$V/PLAN_V.md"; vrun; RC=$?
[ $RC -eq 11 ] && ok "editing Phase 1's acceptance after the APPROVE is refused (exit 11)" || bad "acceptance edit after APPROVE: rc=$RC"

echo "== an open --begin run holds its files"
$DP --begin 1 --label implementer --plan PLAN_G.md --repo "$R" > "$T/out.txt" 2>&1; RC=$?; B1=$(bid)
[ $RC -eq 0 ] && [ -n "$B1" ] || { echo "setup failed: --begin"; cat "$T/out.txt"; exit 1; }
C0=$(calls); run 1 PLAN_G.md; RC=$?
[ $RC -eq 2 ] && [ "$(calls)" = "$C0" ] && has "$B1" && ok "an executor run on the files of an open --begin run is refused (exit 2), no executor call, the open run named" \
  || { bad "run beside an open --begin rc=$RC"; tail -2 "$T/out.txt"; }
$DP --begin 2 --label implementer --plan PLAN_G.md --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 2 ] && has "$B1" && ok "a second --begin on the same files is refused (exit 2), the open run named" || { bad "second --begin rc=$RC"; tail -2 "$T/out.txt"; }
$DP --abort "$B1" --repo "$R" > /dev/null 2>&1; run 1 PLAN_G.md; RC=$?
[ $RC -eq 0 ] && [ -n "$(rid)" ] && ok "once the --begin run is aborted the same files are free" || { bad "after --abort rc=$RC"; tail -2 "$T/out.txt"; }

echo "== plugin names (agents are concord:<name> inside the Claude Code plugin)"
run 3 PLAN_G.md; P=$(rid); [ -n "$P" ] || { echo "setup failed: run 3"; cat "$T/out.txt"; exit 1; }
$DP --review "$P" --packet --repo "$R" > "$T/out.txt" 2>&1
has "subagent_type concord:reviewer-opus55 with prompt" && ok "the packet hint names the plugin agent" || bad "packet hint"
record "$P" concord:reviewer-opus55 "$T/clean.txt" "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && [ "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["reviews"][-1]["reviewer"])' "$RUNS/$P/meta.json")" = reviewer-opus55 ] \
  && ok "--review-record --reviewer concord:reviewer-opus55 is stored as reviewer-opus55" || { bad "plugin reviewer rc=$RC"; tail -2 "$T/out.txt"; }
$DP --begin 5 --label Concord:Implementer --plan PLAN_G.md --repo "$R" > "$T/out.txt" 2>&1; RC=$?
B=$(bid)
[ $RC -eq 0 ] && [ -n "$B" ] && ok "--begin --label Concord:Implementer is accepted as implementer" || { bad "plugin label rc=$RC"; tail -2 "$T/out.txt"; }
[ -z "$B" ] || $DP --abort "$B" --repo "$R" > /dev/null 2>&1

echo "== drift brakes (2026-10-25)"
D="$T/d"; mkdir -p "$D" && ( cd "$D" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > a.py; git add -A && git commit -qm init
  { printf '# Plan\nTier: M\nSize: ~4 lines\nETA: 10 min\n\n## Open questions\n- Q1 none\n\n'; phase 1 '' 'grep -q 2 a.py'; } > PLAN_D.md ) \
  || { echo "setup failed"; exit 1; }
drun(){ FAKE_ACTIONS=true $DP 1 --plan PLAN_D.md --via qwen --model fake/m --no-baseline --repo "$D" "$@" > "$T/out.txt" 2>&1; }
drift(){ $DP --drift --plan PLAN_D.md --repo "$D" > "$T/out.txt" 2>&1; }
hook(){ printf '{"cwd": "%s"}' "$D" | $DP --drift-hook > "$T/out.txt" 2>&1; }
clock(){ python3 -I -c 'import json,sys,time; p,r=sys.argv[1:3]; d=json.load(open(p)); d[r].update(elapsed=float(sys.argv[3]), last=time.time()-float(sys.argv[4])); json.dump(d,open(p,"w"))' "${3:-$D}/.git/concord/drift.json" "${3:-$D}" "$1" "$2"; }
$DP --lint 1 --plan PLAN_D.md --repo "$D" > /dev/null 2>&1
printf 'VERDICT: REVISE\nPLAN-HASH: %s\n' "$(vhash "$D/PLAN_D.md")" > "$T/v.txt"; $DP --plan-verdict "$T/v.txt" --plan PLAN_D.md --repo "$D" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 1 ] && has "nothing recorded" && ok "--plan-verdict REVISE records nothing" || bad "REVISE rc=$RC"
printf '**VERDICT:** APPROVE\nPLAN-HASH: %s\n' "$(vhash "$D/PLAN_D.md")" > "$T/v.txt"; $DP --plan-verdict "$T/v.txt" --plan PLAN_D.md --repo "$D" > /dev/null 2>&1
perl -pi -e 's/Q1 none/Q1 settled by the owner/' "$D/PLAN_D.md"; drun; RC=$?
[ $RC -eq 0 ] && [ -n "$(rid)" ] && ok "APPROVE recorded; an Open questions edit keeps it" || { bad "approved run rc=$RC"; tail -2 "$T/out.txt"; }
drift; RC=$?; [ $RC -eq 0 ] && has "DRIFT OK" && ok "--drift: OK after the first run" || { bad "drift OK rc=$RC"; tail -2 "$T/out.txt"; }
clock 780 3600; drift
has "time 13/10 min (1.30x)" && has "DRIFT WARN" && ok "time warns at 1.2x; an idle gap of 10 minutes or more does not count" || { bad "time warn"; tail -2 "$T/out.txt"; }
clock 0 0; drift; printf '# 1\n# 2\n# 3\n# 4\n# 5\n' >> "$D/a.py"; hook
has '"hookEventName": "PostToolUse"' && has "DRIFT WARN" && has "size 5/4 lines" && ok "the hook prints a level change (size 1.25x)" || { bad "hook warn"; cat "$T/out.txt"; }
hook; [ ! -s "$T/out.txt" ] && ok "the hook is silent while the level stays" || bad "hook repeat"
printf '# 6\n# 7\n' >> "$D/a.py"; drun; RC=$?
[ $RC -eq 10 ] && has "DRIFT BLOCK" && ok "size at 1.5x blocks the next run (exit 10)" || { bad "size block rc=$RC"; tail -2 "$T/out.txt"; }
drun --user-approved "go on"; RC=$?; drift
[ $RC -eq 0 ] && has "DRIFT WARN" && ok "--user-approved lifts the block until the measure grows 50% more" || { bad "approved rc=$RC"; tail -2 "$T/out.txt"; }
grep -rqs "user approved: go on" "$D/.git/concord" && ok "the run records the owner's words that passed a gate" || bad "approval note"
printf 'y = 1\n' > "$D/b.py"; drun; RC=$?
[ $RC -eq 10 ] && has "changed outside Files: b.py" && ok "a changed file outside Files blocks (exit 10)" || { bad "scope rc=$RC"; tail -2 "$T/out.txt"; }
git -C "$D" worktree add -q "$T/df" > /dev/null 2>&1; cp "$D/PLAN_D.md" "$T/df/"
FAKE_ACTIONS=true $DP 1 --plan PLAN_D.md --via qwen --model fake/m --no-baseline --repo "$T/df" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 10 ] && has "DRIFT BLOCK" && ok "a run in a fork (another worktree) is gated by the ticket checkout's drift (exit 10)" \
  || { bad "fork rc=$RC"; tail -2 "$T/out.txt"; }
python3 -I - "$D/.git/concord" "$D" "$T/held" <<'EOF' &
import fcntl, json, sys, time
root, key, flag = sys.argv[1:4]
with open(root + "/drift.lock", "a") as lock:      # another writer (an approval) holds the lock for 1.5 s
    fcntl.flock(lock, fcntl.LOCK_EX); open(flag, "w").close(); time.sleep(1.5)
    d = json.load(open(root + "/drift.json")); d[key]["ok"] = {"time": 99.0, "files": ["held.py"]}
    json.dump(d, open(root + "/drift.json", "w"))
EOF
HP=$!; for i in $(seq 100); do [ -e "$T/held" ] && break; sleep 0.05; done; hook; wait $HP
python3 -I -c 'import json,sys; sys.exit(json.load(open(sys.argv[1]))[sys.argv[2]].get("ok", {}).get("files") != ["held.py"])' "$D/.git/concord/drift.json" "$D" \
  && ok "a hook tick during another writer's drift.lock keeps that writer's approval" || { bad "approval lost to a hook tick"; cat "$T/out.txt"; }
$DP --lint 1 --via qwen --model fake/m --plan PLAN_G.md --repo "$R" > "$T/out.txt" 2>&1
has 'PLAN LINT: no `Size:` line' && has 'PLAN LINT: no `ETA:` line' && ok "--lint flags a plan with no Size: or ETA:" || { bad "lint"; tail -3 "$T/out.txt"; }

E="$T/e"; mkdir -p "$E" && ( cd "$E" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > café.py; git add -A && git commit -qm init
  printf '# Plan\nTier: L\nSize: ~1,200 lines\nETA: 10 min\n\n### Phase 1 - p\nExecutor: deepseek-flash\nFiles: café.py\nAcceptance:\n- `true`\n' > PLAN_E.md ) \
  || { echo "setup failed"; exit 1; }
approve PLAN_E.md "$E" || exit 1
FAKE_ACTIONS=true $DP 1 --plan PLAN_E.md --via qwen --model fake/m --no-baseline --repo "$E" > "$T/out.txt" 2>&1; [ -n "$(rid)" ] || { echo "setup failed: run of PLAN_E"; cat "$T/out.txt"; exit 1; }
printf 'y = 2\n' >> "$E/café.py"; $DP --drift --plan PLAN_E.md --repo "$E" > "$T/out.txt" 2>&1
has "DRIFT OK" && has "size 1/1200 lines" && has "every changed file is in Files" \
  && ok "### Phase heads, a non-ASCII path and Size: ~1,200 are read right" || { bad "heads, path, size"; tail -2 "$T/out.txt"; }
( cd "$E" && git commit -qam ticket && git checkout -qb up HEAD~1 && printf 'z = 1\n' > c.py && git add c.py \
  && git commit -qm upstream && git checkout -q main && git merge -q --no-edit up ) > /dev/null 2>&1
$DP --drift --plan PLAN_E.md --repo "$E" > "$T/out.txt" 2>&1
has "size 1/1200 lines" && has "every changed file is in Files" \
  && ok "a merge of upstream work moves the drift base: its files and lines do not count" || { bad "upstream merge"; tail -2 "$T/out.txt"; }
mkdir -p "$E/.git/concord/run-x"; clock 0 1500 "$E"
python3 -I -c 'import json,sys,time; d=sys.argv[1]; json.dump({"plan": "PLAN_E.md", "started": time.time() - 1500, "mode": "edit", "pid": int(sys.argv[2])}, open(d + "/state.json", "w")); json.dump({"seconds": 1500}, open(d + "/meta.json", "w"))' "$E/.git/concord/run-x" $$
$DP --drift --plan PLAN_E.md --repo "$E" > "$T/out.txt" 2>&1
has "time 25/10 min" && ok "a long gap counts where a run of the plan covered it" || { bad "run time"; tail -2 "$T/out.txt"; }
rm "$E/.git/concord/run-x/meta.json"; clock 0 1200 "$E"; $DP --drift --plan PLAN_E.md --repo "$E" > "$T/out.txt" 2>&1
has "time 20/10 min" && ok "a run still in progress covers the gap up to now" || { bad "running time"; tail -2 "$T/out.txt"; }
sh -c 'exit 0' & DEAD=$!; wait $DEAD
python3 -I -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["pid"]=int(sys.argv[2]); json.dump(s,open(p,"w"))' "$E/.git/concord/run-x/state.json" "$DEAD"
clock 0 1200 "$E"; $DP --drift --plan PLAN_E.md --repo "$E" > "$T/out.txt" 2>&1
has "time 0/10 min" && ok "a killed run (no report, its process gone) covers no gap" || { bad "killed run"; tail -2 "$T/out.txt"; }
printf 'NOT RUN\n' > "$E/.git/concord/run-x/report.md"; clock 0 1200 "$E"; $DP --drift --plan PLAN_E.md --repo "$E" > "$T/out.txt" 2>&1
has "time 0/10 min" && ok "a refused run (a report, no meta.json) covers no gap" || { bad "refused run"; tail -2 "$T/out.txt"; }

F="$T/f"; mkdir -p "$F" && ( cd "$F" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > a.py; git add -A && git commit -qm init
  { printf '# Plan\nTier: M\nSize: ~40 lines\nETA: 10 min\n\n'; phase 1 '' 'true'; } > PLAN_F.md ) || { echo "setup failed"; exit 1; }
approve PLAN_F.md "$F" || exit 1
git -C "$F" worktree add -q "$T/ff" > /dev/null 2>&1; cp "$F/PLAN_F.md" "$T/ff/"
FAKE_ACTIONS=true $DP 1 --plan PLAN_F.md --via qwen --model fake/m --no-baseline --repo "$T/ff" > "$T/out.txt" 2>&1; [ -n "$(rid)" ] || { echo "setup failed: run in the fork"; cat "$T/out.txt"; exit 1; }
printf 'y = 2\n' >> "$F/a.py"; git -C "$F" worktree remove --force "$T/ff"      # wt.py join: patch applied, fork removed
$DP --drift --plan PLAN_F.md --repo "$F" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "DRIFT OK" && has "size 1/40 lines" \
  && python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(sys.argv[2] not in d or sys.argv[3] in d)' "$F/.git/concord/drift.json" "$F" "$T/ff" \
  && ok "after a fork is joined and removed, the ticket checkout takes over the fork's drift entry" || { bad "joined fork rc=$RC"; tail -2 "$T/out.txt"; }
python3 -I -c 'import json,sys; p,f=sys.argv[1:3]; d=json.load(open(p)); d[f+"_gone"]=dict(d[f], elapsed=300.0); d[f]["plan"]="PLAN_A.md"; json.dump(d,open(p,"w"))' "$F/.git/concord/drift.json" "$F"
$DP --drift --plan PLAN_F.md --repo "$F" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "DRIFT: silent" \
  && python3 -I -c 'import json,sys; sys.exit(json.load(open(sys.argv[1]))[sys.argv[2]]["plan"] != "PLAN_A.md")' "$F/.git/concord/drift.json" "$F" \
  && ok "a removed fork's entry never replaces the checkout's own entry for another plan" || { bad "own entry kept rc=$RC"; tail -2 "$T/out.txt"; }
FAKE_ACTIONS=true $DP 1 --plan PLAN_F.md --via qwen --model fake/m --no-baseline --repo "$F" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && python3 -I -c 'import json,sys; e=json.load(open(sys.argv[1]))[sys.argv[2]]; sys.exit(e["plan"] != "PLAN_F.md" or e["elapsed"] < 300)' "$F/.git/concord/drift.json" "$F" \
  && ok "a gated run of the fork's plan takes over the removed fork's entry (its time carries over)" || { bad "gated takeover rc=$RC"; tail -2 "$T/out.txt"; }

echo "== drift against the stored --estimate ETA; ## Passes edits keep the APPROVE; --report closes the plan"
K="$T/k"; mkdir -p "$K" && ( cd "$K" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > a.py; git add -A && git commit -qm init
  { printf '# Plan\nTier: M\nSize: ~400 lines\nETA: 600 min\n\n'; phase 1 '' 'true'; printf '\n## Passes\nPhase 1 deepseek-flash\n'; } > PLAN_K.md ) \
  || { echo "setup failed"; exit 1; }
approve PLAN_K.md "$K" || exit 1
krun(){ FAKE_ACTIONS=true $DP 1 --plan PLAN_K.md --via qwen --model fake/m --no-baseline --repo "$K" > "$T/out.txt" 2>&1; }
printf 'Phase 1 deepseek-flash 9 min\nETA: 29 min\n' >> "$K/PLAN_K.md"; krun; RC=$?
[ $RC -eq 0 ] && [ -n "$(rid)" ] && ok "an edit of ## Passes (filled by --estimate) keeps the APPROVE" || { bad "passes edit rc=$RC"; tail -2 "$T/out.txt"; }
KR=$(rid); $DP --verdict "$KR" PASS --repo "$K" > "$T/v.txt" 2>&1 || { echo "setup failed: PASS of the run of PLAN_K (a plan with a run that has no verdict cannot be reported)"; cat "$T/v.txt"; exit 1; }
python3 -I -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["estimates"]={"PLAN_K.md": 10}; json.dump(d,open(p,"w"))' "$K/.git/concord/drift.json"
clock 960 0 "$K"; $DP --drift --plan PLAN_K.md --repo "$K" > /dev/null 2>&1; $DP --drift --plan PLAN_K.md --repo "$K" > "$T/out.txt" 2>&1
has "time 16/10 min" && has "DRIFT BLOCK" && ok "drift measures time against the stored estimate, not the plan's ETA: line; the estimate survives a save" \
  || { bad "estimate drift"; tail -2 "$T/out.txt"; }
el(){ python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]]["elapsed"])' "$K/.git/concord/drift.json" "$K"; }
$DP --report --plan PLAN_K.md --repo "$K" > "$T/rep.txt" 2>&1 || { echo "setup failed: --report"; cat "$T/rep.txt"; exit 1; }
E0=$(el); krun; RC=$?; vb(){ $DP --begin 1 --label implementer --plan PLAN_K.md --repo "$K" > "$T/out.txt" 2>&1; }; vb; RCB=$?
$DP --drift --plan PLAN_K.md --repo "$K" > "$T/d.txt" 2>&1; E1=$(el)
[ $RC -eq 10 ] && [ $RCB -eq 10 ] && grep -q "DRIFT OFF" "$T/d.txt" && [ "$E0" = "$E1" ] && ok "after --report the plan refuses new runs and --begin (exit 10); its drift clock stays stopped" \
  || { bad "reported plan: run rc=$RC, --begin rc=$RCB, elapsed $E0 -> $E1"; cat "$T/d.txt"; [ $RCB -eq 0 ] && $DP --abort last --repo "$K" > /dev/null 2>&1; }

echo "== --report waits for the plan's runs; an edited reported plan is closed (exit 10, not 11)"
mkv v12; approve PLAN_V.md "$V" || exit 1
vbegin 1; RC=$?; B=$(bid)
[ $RC -eq 0 ] && [ -n "$B" ] || { echo "setup failed: --begin of the plan to be reported"; cat "$T/out.txt"; exit 1; }
printf 'x = 2\n' > "$V/a.py"
REPV="$V/.git/concord/reports/REPORT_V.md"
$DP --report --plan PLAN_V.md --repo "$V" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 2 ] && has "$B" && [ ! -e "$REPV" ] && ok "--report while a run of the plan is open is refused (exit 2), names the run and writes no report" \
  || bad "report beside an open run: rc=$RC, report written=$([ -e "$REPV" ] && echo yes || echo no): $(tail -2 "$T/out.txt")"
$DP --end "$B" --repo "$V" > "$T/out.txt" 2>&1 || { echo "setup failed: --end"; cat "$T/out.txt"; exit 1; }
rm -f "$REPV"
$DP --report --plan PLAN_V.md --repo "$V" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 2 ] && has "$B" && [ ! -e "$REPV" ] && ok "--report for a run that ended with no verdict is refused (exit 2) and names the run" \
  || bad "report of a run with no verdict: rc=$RC, report written=$([ -e "$REPV" ] && echo yes || echo no): $(tail -2 "$T/out.txt")"
$DP --verdict "$B" PASS --repo "$V" > "$T/out.txt" 2>&1 || { echo "setup failed: PASS of the ended run"; cat "$T/out.txt"; exit 1; }
rm -f "$REPV"; $DP --report --plan PLAN_V.md --repo "$V" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && [ -f "$REPV" ] && grep -Eq '^\| 1 \| [^|]+ \| 1 \| PASS \| 1/1 pass \|' "$REPV" \
  && ok "after --end and a verdict --report writes the report with that run's verdict and acceptance result" \
  || bad "report after the verdict: rc=$RC: $(tail -2 "$T/out.txt")"
perl -pi -e 's/grep -q 2 a.py/grep -q 3 a.py/' "$V/PLAN_V.md"; vbegin 1; RC=$?; [ $RC -eq 0 ] && vabort
[ $RC -eq 10 ] && ok "editing the reported plan, then --begin: refused with exit 10 (the plan is closed), not 11" || bad "edited reported plan: --begin rc=$RC"

echo "== the drift hook starts Python only in a repository that has a drift.json"
mkdir -p "$T/pybin"
cat > "$T/pybin/python3" <<'P'
#!/bin/sh
echo "$*" >> "$T/py_calls"; cat >> "$T/py_in"
P
chmod +x "$T/pybin/python3"
hk(){ rm -f "$T/py_calls" "$T/py_in"; printf '{"session_id": "s1", "cwd": "%s", "hook_event_name": "PostToolUse"}' "$1" | PATH="$T/pybin:$PATH" sh "$T/concord/drift_hook.sh" > "$T/out.txt" 2>&1; RC=$?; }
NODRIFT="$T/nodrift"; mkdir -p "$NODRIFT" && ( cd "$NODRIFT" && git init -q -b main && git config user.email t@t && git config user.name t && printf 'x\n' > a.py && git add -A && git commit -qm init )
if [ -f "$T/concord/drift_hook.sh" ]; then
  hk "$D"; RC1=$RC; P1=$(cat "$T/py_calls" 2>/dev/null); IN1=$(cat "$T/py_in" 2>/dev/null)
  hk "$NODRIFT"; RC2=$RC; P2=$(cat "$T/py_calls" 2>/dev/null)
  hk "$T"; RC3=$RC; P3=$(cat "$T/py_calls" 2>/dev/null)
  [ $RC1 -eq 0 ] && case "$P1" in *concord.py*--drift-hook*) true;; *) false;; esac && case "$IN1" in *"$D"*) true;; *) false;; esac \
    && ok "in a repository with a drift.json the hook runs concord.py --drift-hook with the hook input" || bad "hook with drift.json: rc=$RC1 calls='$P1' input='$IN1'"
  [ $RC2 -eq 0 ] && [ $RC3 -eq 0 ] && [ -z "$P2" ] && [ -z "$P3" ] && ok "in a repository without a drift.json, and outside a repository, the hook starts no Python" \
    || bad "hook without drift.json: rc=$RC2/$RC3 calls='$P2' / '$P3'"
  rm -f "$T/py_calls" "$T/py_in"; printf '{"session_id": "s1", "cwd": "%s", "tool_input": {"cwd": "%s"}, "hook_event_name": "PostToolUse"}' "$D" "$NODRIFT" | PATH="$T/pybin:$PATH" sh "$T/concord/drift_hook.sh" > "$T/out.txt" 2>&1; RC4=$?
  case "$(cat "$T/py_calls" 2>/dev/null)" in *concord.py*--drift-hook*) PY4=1;; *) PY4=0;; esac
  [ $RC4 -eq 0 ] && [ $PY4 -eq 1 ] && ok "the hook takes the first cwd key, not a cwd nested in tool_input" || bad "nested tool_input.cwd: rc=$RC4 python started=$PY4"
else bad "concord/drift_hook.sh does not exist"; bad "concord/drift_hook.sh does not exist (no-drift.json case)"; fi

echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
