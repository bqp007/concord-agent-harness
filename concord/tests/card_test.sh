#!/bin/bash
# Verdict card and fresh verifier (2026-10-21, PLAN Phase 14): `concord.py --card` prints a one-screen card
# (<=25 lines, zero model tokens) and writes a verify packet for the concord:verifier subagent; `frontier_tokens_since`
# also sums the session's subagent transcripts into `frontier_subagent_tokens`. No network: fake qwen, fake HOME.
# Run: bash ~/.claude/concord/tests/card_test.sh   (exit 0 = all passed).
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/card-test.XXXXXX")" && pwd -P)"; export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/concord" "$T/home/.claude"
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
O="$T/origin.git"; R="$T/clone"; RUNS="$R/.git/concord"; NOTES="$T/concord/repo-notes/clone.md"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
has(){ grep -F -- "$1" "$T/card.txt" > /dev/null; }
rid(){ sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1; }
meta(){ python3 -I -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))" "$1/meta.json" "$2"; }
# run PHASE ACTIONS: one fake executor run of PLAN_F.md; ACTIONS is the shell the fake executor runs in the repo
run(){ FAKE_ACTIONS="$2" $DP "$1" --plan PLAN_F.md --via qwen --model fake/m --no-baseline --repo "$R" > "$T/out.txt" 2>&1; }
phase(){ printf '## Phase %s - p%s\nExecutor: deepseek-flash\nRisk: %s\nFiles: %s\nAcceptance:\n- `%s`\n' "$1" "$1" "$2" "$3" "$4"; }
printf '# clone: binding facts\n- Risk floor high: sec/*\n' > "$NOTES"

git init -q --bare -b main "$O" && git clone -q "$O" "$R" 2> /dev/null || { echo "setup failed: repos"; exit 1; }
( set -e; cd "$R" && git config user.email t@t && git config user.name t && git config diff.renames true
  mkdir sec tests; printf 'x = 1\n' > a.py; printf 'k = 1\n' > sec/key.py; printf 'doc\n' > README.md
  printf 'import sys\nsys.exit(0)\n' > tests/check.py; printf '.claude/\n' > .gitignore
  { echo '# Plan'; phase 2 medium a.py "python3 tests/check.py"; } > PLAN_F.md
  git add -A && git commit -qm init && git push -q origin main ) || { echo "setup failed: history"; exit 1; }

echo "== card: cap, scope, diff stat, flags"
# edit in scope (a.py), out of scope (README.md), a floored path (sec/key.py), an acceptance+test file (tests/check.py)
run 2 "echo '# edit' >> a.py; echo '# oos' >> README.md; echo '# floor' >> sec/key.py; echo '# acc' >> tests/check.py"
A=$(rid); [ -n "$A" ] || { echo "setup failed: run p2"; cat "$T/out.txt"; exit 1; }
$DP --card "$A" --repo "$R" > "$T/full.txt" 2>&1 || { bad "--card exit $?"; cat "$T/full.txt"; }
awk '/^VERIFY-PACKET /{exit} {print}' "$T/full.txt" > "$T/card.txt"
CL=$(wc -l < "$T/card.txt")
[ "$CL" -le 25 ] && [ "$CL" -ge 1 ] && ok "card is $CL lines (<=25)" || { bad "card is $CL lines"; cat "$T/card.txt"; }
has "CARD $A" && has "phase 2" && has "risk medium" && ok "card names the run, phase and risk tier" \
  || { bad "card header"; cat "$T/card.txt"; }
has "floor high" && has "sec/key.py matches sec/*" && ok "card names the risk floor and the floored path" \
  || { bad "card floor"; cat "$T/card.txt"; }
has "acceptance after run:" && ok "card shows the recorded acceptance result" || { bad "card acceptance"; cat "$T/card.txt"; }
has "scope:" && has "out of scope" && ok "card has the scope line" || { bad "card scope"; cat "$T/card.txt"; }
has "diff --stat:" && grep -E 'a\.py +\+[0-9]' "$T/card.txt" > /dev/null \
  && ok "card shows git diff --stat per file (a.py)" || { bad "card diff stat"; cat "$T/card.txt"; }
has "reviews: none" && ok "card shows no reviews recorded yet" || { bad "card reviews"; cat "$T/card.txt"; }

echo "== card: FLAGS name the files a checker must open"
grep '^FLAGS:' "$T/card.txt" > "$T/flags.txt" || bad "no FLAGS line"
grep -F 'sec/key.py (floored)' "$T/flags.txt" > /dev/null && ok "FLAGS: floored path" || { bad "FLAGS floored"; cat "$T/flags.txt"; }
grep -F 'README.md (out of scope)' "$T/flags.txt" > /dev/null && ok "FLAGS: out of scope file" || { bad "FLAGS oos"; cat "$T/flags.txt"; }
grep -F 'tests/check.py (test file changed)' "$T/flags.txt" > /dev/null && ok "FLAGS: test file changed" || { bad "FLAGS test"; cat "$T/flags.txt"; }
grep -F 'tests/check.py (acceptance file changed)' "$T/flags.txt" > /dev/null && ok "FLAGS: acceptance file changed" || { bad "FLAGS acceptance"; cat "$T/flags.txt"; }

echo "== verify packet written"
PK=$(sed -n 's/^VERIFY-PACKET //p' "$T/full.txt" | head -1)
[ -n "$PK" ] && [ -f "$PK" ] && ok "--card prints and writes the verify packet path" || { bad "no verify packet ('$PK')"; cat "$T/full.txt"; }
grep -q "Verdict card:" "$PK" && grep -q "CARD $A" "$PK" && ok "packet holds the verdict card" || bad "packet has no card"
grep -q "The phase that was implemented:" "$PK" && grep -q "Files: a.py" "$PK" && ok "packet holds the phase text" || bad "packet has no phase text"
grep -q "Acceptance commands and their recorded output:" "$PK" && grep -q "python3 tests/check.py" "$PK" \
  && ok "packet holds the acceptance commands and their recorded output" || bad "packet has no acceptance block"
grep -q "^Diff:" "$PK" && grep -q "VERIFY-JSON" "$PK" && ok "packet holds the diff and the VERIFY-JSON instruction" || bad "packet has no diff/VERIFY-JSON"
$DP --card "$A" --repo "$R" > /dev/null 2>&1
[ -f "$RUNS/$A/verify-packet-2.md" ] && ok "a second --card writes verify-packet-2.md (never overwrites)" \
  || { bad "no verify-packet-2.md"; ls "$RUNS/$A"; }

echo "== card: last resolves to the newest run"
$DP --card last --repo "$R" > "$T/last.txt" 2>&1 && grep -q "CARD $A" "$T/last.txt" \
  && ok "--card last resolves to the newest reported run" || { bad "--card last"; cat "$T/last.txt"; }

echo "== frontier_subagent_tokens sums the session's subagent transcripts"
SID="sess-card-7"
PROJ="$HOME/.claude/projects/proj"
mkdir -p "$PROJ/$SID/subagents"
rec(){ printf '{"timestamp":"2099-01-01T00:00:00.000Z","message":{"usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":%s}}}\n' "$1" "$2" "$3" "$4"; }
rec 1000 0 50 500 > "$PROJ/$SID.jsonl"
{ rec 100 10 0 5; rec 200 0 7 20; } > "$PROJ/$SID/subagents/a.jsonl"   # fresh = (100+10+5)+(200+0+20) = 335
CLAUDE_CODE_SESSION_ID="$SID" $DP --verdict "$A" FAIL --cause FLAKY --tokens auto --repo "$R" > "$T/out.txt" 2>&1
ST=$(meta "$RUNS/$A" frontier_subagent_tokens)
[ "$ST" = 335 ] && ok "frontier_subagent_tokens = 335 (subagent transcripts summed)" || { bad "frontier_subagent_tokens=$ST"; tail -3 "$T/out.txt"; }
MT=$(meta "$RUNS/$A" frontier_tokens)
[ "$MT" = 1500 ] && ok "frontier_tokens stays the session's own fresh total (1500), unchanged by subagents" \
  || { bad "frontier_tokens=$MT"; tail -3 "$T/out.txt"; }

echo "== --card on an unknown run fails cleanly"
$DP --card no-such-run --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -ne 0 ] && grep -q "no such run" "$T/out.txt" && ok "--card on an unknown run exits non-zero, names it" \
  || { bad "unknown run rc=$RC"; tail -2 "$T/out.txt"; }

echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
