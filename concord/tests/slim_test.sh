#!/bin/bash
# concord.py slim regression (2026-10-19; lean revision 2026-10-23): no segmented reviews: --segment is refused by
# argparse, and a phase review over the cap is refused with the file groups before any model call.
# No network: fake qwen executor/reviewer.
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
printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n'
Q
chmod +x "$T/bin/qwen"
# The /usr/bin git and python3 are xcrun shims; inside the macOS sandbox xcrun cannot write its cache and prints
# "couldn't create cache file" on stderr, which pollutes captured output. Prefer the developer dir's real binaries.
XDEV="$(xcode-select -p 2>/dev/null)"; [ -n "$XDEV" ] && [ -x "$XDEV/usr/bin/git" ] && [ -x "$XDEV/usr/bin/python3" ] && export PATH="$XDEV/usr/bin:$PATH"
export PATH="$T/bin:$PATH" HOME="$T/home"
DP="python3 $T/concord/concord.py"
R="$T/repo"
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

echo "== no segmented reviews"
$DP --review "$RID" --segment --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 2 ] && has "unrecognized arguments: --segment" && ok "--segment is gone (argparse refuses it)" || { bad "--segment rc=$RC"; tail -2 "$T/out.txt"; }
FAKE_ACTIONS="python3 -c \"open('big.py','w').write(''.join('v_%04d = %r\\\\n' % (i, 'x' * 30) for i in range(8000)))\"; printf 'x = 2\\n' > a.py" \
  $DP 1 --plan PLAN_S.md --via qwen --model fake/m --no-baseline --repo "$R" > "$T/out.txt" 2>&1
BIG=$(sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
C0=$(calls)
$DP --review "$BIG" --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 2 ] && [ "$(calls)" = "$C0" ] && has "over the 300,000 cap" && has "big.py" && has "split the change, or use --packet for an Opus reviewer" \
  && ok "phase review over the cap: exit 2, file groups, no model call" || { bad "over-cap phase review rc=$RC calls $C0->$(calls)"; tail -4 "$T/out.txt"; }

echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
