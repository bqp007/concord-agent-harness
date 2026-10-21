#!/bin/bash
# concord.py slim regression (2026-10-19): no segmented reviews (over the cap = refusal with the
# file groups), --close-round (adjudicate any reviewer's ids + verdict in one call), accumulating adjudication flags,
# the short --stats view. No network: fake qwen executor/reviewer.
# Run: bash ~/.claude/concord/tests/slim_test.sh   (exit 0 = all passed).
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/slim-test.XXXXXX")" && pwd -P)"; export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/concord" "$T/home/.claude"
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
cat > "$T/bin/qwen" <<'Q'
#!/bin/sh
echo ran >> "$T/qwen_calls"
if [ -n "${FAKE_ACTIONS:-}" ]; then sh -c "$FAKE_ACTIONS"; exit 0; fi
printf 'REVIEW-JSON\n{"findings": [{"severity": "HIGH", "path": "a.py", "line": 1, "problem": "wrong constant", "fix": "use 3", "repro": {"input": "x", "expected": "3", "actual": "2"}}, {"severity": "MEDIUM", "path": "a.py", "line": 1, "problem": "odd name", "fix": "rename x", "repro": {"input": "x", "expected": "y", "actual": "x"}}], "clauses": [], "tests": [], "verdict": "FIX"}\nEND-REVIEW-JSON\n'
Q
chmod +x "$T/bin/qwen"
# The /usr/bin git and python3 are xcrun shims; inside the macOS sandbox xcrun cannot write its cache and prints
# "couldn't create cache file" on stderr, which pollutes captured output. Prefer the developer dir's real binaries.
XDEV="$(xcode-select -p 2>/dev/null)"; [ -n "$XDEV" ] && [ -x "$XDEV/usr/bin/git" ] && [ -x "$XDEV/usr/bin/python3" ] && export PATH="$XDEV/usr/bin:$PATH"
export PATH="$T/bin:$PATH" HOME="$T/home"
DP="python3 $T/concord/concord.py"
R="$T/repo"; RUNS="$R/.git/concord"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
has(){ grep -F -- "$1" "$T/out.txt" > /dev/null; }
calls(){ [ -f "$T/qwen_calls" ] && wc -l < "$T/qwen_calls" | tr -d ' ' || echo 0; }
mkdir -p "$R" && ( cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > a.py; printf '.claude/\n' > .gitignore; git add -A && git commit -qm init
  printf '# Plan\n## Phase 1 - change a\nExecutor: deepseek-flash\nFiles: a.py, big.py\nAcceptance:\n- `grep -q 2 a.py`\n' > PLAN_S.md ) \
  || { echo "setup failed"; exit 1; }

echo "== setup run"
FAKE_ACTIONS='printf "x = 2\n" > a.py' $DP 1 --plan PLAN_S.md --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1
RID=$(sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
[ -n "$RID" ] || { echo "setup failed: run"; cat "$T/out.txt"; exit 1; }
echo "== --close-round"
$DP --review "$RID" --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1
L="$RUNS/ledger/PLAN_S.json"
IDS=$(python3 -I -c 'import json,sys; print(",".join(f["id"] for f in json.load(open(sys.argv[1]))["findings"]))' "$L" 2>/dev/null)
[ "$IDS" = "F1,F2" ] || { echo "setup failed: ledger ids '$IDS'"; exit 1; }
cat > "$T/o.txt" <<'J'
REVIEW-JSON
{"findings": [{"severity": "HIGH", "path": "a.py", "line": 1, "problem": "missing bound", "fix": "clamp x", "repro": {"input": "x=9", "expected": "<=3", "actual": "9"}}], "clauses": [], "tests": [], "verdict": "FIX"}
END-REVIEW-JSON
J
$DP --review-record "$RID" --reviewer reviewer-opus48 --file "$T/o.txt" --repo "$R" > /dev/null 2>&1
$DP --close-round "$RID" --adopt F1,F3 --wrong "F9=no such finding" --verdict-result PASS --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 2 ] && has "F9" && [ "$(python3 -I -c 'import json,sys; print([f["status"] for f in json.load(open(sys.argv[1]))["findings"]])' "$L")" = "['open', 'open', 'open']" ] \
  && ok "--close-round with an unknown id: exit 2, nothing written" || { bad "unknown id rc=$RC"; cat "$T/out.txt"; }
$DP --close-round "$RID" --adopt F1 --verdict-result FAIL --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 2 ] && [ "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["findings"][0]["status"])' "$L")" = "open" ] \
  && ok "--close-round FAIL without --cause: exit 2, nothing written" || { bad "fail without cause rc=$RC"; cat "$T/out.txt"; }
$DP --close-round "$RID" --adopt F1 --adopt F3 --wrong "F2=naming is fine" --verdict-result PASS --note "round closed" --repo "$R" > "$T/out.txt" 2>&1; RC=$?
ST=$(python3 -I -c 'import json,sys; print([f["status"] for f in json.load(open(sys.argv[1]))["findings"]])' "$L")
[ $RC -eq 0 ] && [ "$ST" = "['adopted', 'incorrect', 'adopted']" ] && has "deepseek-flash" && has "reviewer-opus48" && has "verdict PASS" \
  && ok "--close-round: ids of two reviewers adjudicated (repeated --adopt accumulates) + verdict, one call" || { bad "close-round rc=$RC $ST"; cat "$T/out.txt"; }
[ "$(python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m.get("verdict"), m.get("verdict_note"))' "$RUNS/$RID/meta.json")" = "PASS round closed" ] \
  && ok "--close-round recorded the verdict in the verdict log" || bad "verdict not recorded"

echo "== short --stats"
$DP --stats --repo "$R" > "$T/out.txt" 2>&1; RC=$?
HDR=$(grep -m1 "^executor / model" "$T/out.txt")
[ $RC -eq 0 ] && echo "$HDR" | grep -q "mean min" && ! echo "$HDR" | grep -q "scope!\|exec tok\|n/a\|t/o" \
  && ok "--stats executor table: the short column set" || { bad "stats header: $HDR"; head -5 "$T/out.txt"; }
has "rounds per phase: mean" && grep -q "^reviewer .*adopted %.*wrong %" "$T/out.txt" && ! has "behaviours:" \
  && ok "--stats: rounds-per-phase line, reviewer table with adopted/wrong %, no empty behaviours line" || { bad "stats body"; cat "$T/out.txt"; }
[ "$(grep -c "^1st-pass = " "$T/out.txt")" = 1 ] && ok "--stats: one legend line" || bad "legend lines: $(grep -c '^1st-pass' "$T/out.txt")"

echo "== no segmented reviews"
$DP --review "$RID" --segment --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 2 ] && has "unrecognized arguments: --segment" && ok "--segment is gone (argparse refuses it)" || { bad "--segment rc=$RC"; tail -2 "$T/out.txt"; }
FAKE_ACTIONS="python3 -c \"open('big.py','w').write(''.join('v_%04d = %r\\\\n' % (i, 'x' * 30) for i in range(2000)))\"; printf 'x = 2\\n' > a.py" \
  $DP 1 --plan PLAN_S.md --via qwen --model fake/m --no-baseline --repo "$R" > "$T/out.txt" 2>&1
BIG=$(sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
C0=$(calls)
$DP --review "$BIG" --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 2 ] && [ "$(calls)" = "$C0" ] && has "over the 60,000 cap" && has "big.py" && has "split the change, or use --packet for an Opus reviewer" \
  && ok "phase review over the cap: exit 2, file groups, no model call" || { bad "over-cap phase review rc=$RC calls $C0->$(calls)"; tail -4 "$T/out.txt"; }

echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
