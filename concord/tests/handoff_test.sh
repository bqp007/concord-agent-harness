#!/bin/bash
# Knowledge handoff from the planner to executors (2026-10-23, concord-diffusion). (1) A phase's Notes: pointers
# (path:function, path:a-b) are resolved at dispatch and the current code is inlined into the executor's task; a
# pointer that resolves to nothing is marked. (2) FOUND: lines of an executor's report land once in the plan's notes
# file, and later executor and --review tasks of that plan include it. (3) Retry feedback is not called verifier
# feedback. No network: fake qwen executor.
# Run: bash ~/.claude/concord/tests/handoff_test.sh   (exit 0 = every check passed)
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/handoff-test.XXXXXX")" && pwd -P)"; export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/concord" "$T/home/.claude"
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
printf '#!/bin/sh\nsh -c "${FAKE_ACTIONS:-true}"\n' > "$T/bin/qwen"; chmod +x "$T/bin/qwen"
# Prefer the developer dir's real git/python3 over the /usr/bin xcrun shims (they print cache errors in the sandbox).
XDEV="$(xcode-select -p 2>/dev/null)"; [ -n "$XDEV" ] && [ -x "$XDEV/usr/bin/git" ] && [ -x "$XDEV/usr/bin/python3" ] && export PATH="$XDEV/usr/bin:$PATH"
export PATH="$T/bin:$PATH" HOME="$T/home"
DP="python3 $T/concord/concord.py"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
R="$T/repo"; RUNS="$R/.git/concord"; mkdir -p "$R"
( set -e; cd "$R"; git init -q -b main; git config user.email t@t; git config user.name t
  cat > a.py <<'PY'
def keep():
    return 'helper-line-two'


def total(items):
    s = 0
    for it in items:
        s += it["price"]  # marker-inside-total
    return s


def after():
    return 'marker-after-total'
PY
  printf 'const out = helper(2);\nfunction main(x) {\n  return helper(x);\n}\n\nfunction helper(x) {\n  return x * 2; // marker-js-def\n}\n' > h.js
  printf 'fn main() {\n    let v = helper(2);\n}\npub(crate) fn helper(x: i32) -> i32 {\n    x // marker-rs-def\n}\n' > h.rs
  printf '.claude/\n' > .gitignore; git add -A; git commit -qm init
  cat > PLAN_T.md <<'P'
# Plan
## Phase 1 - count quantities
Executor: deepseek-flash
Risk: low
Files: a.py
Notes:
- a.py:total - sums prices, ignores qty
- a.py:1-2 - the helper above it
- a.py:no_such_fn - gone
- h.js:helper - the JS helper
- h.rs:helper - the Rust helper
Acceptance:
- `grep -q qty a.py`
P
) || { echo "setup failed: repo"; exit 1; }
dry(){ $DP 1 --plan PLAN_T.md --via qwen --model fake/m --dry-run "$@" --repo "$R" > "$T/out.txt" 2>&1
  local id; id=$(sed -n 's/^DRY RUN \([^ ]*\)$/\1/p' "$T/out.txt" | head -1); cat "$RUNS/${id:-none}/prompt.txt" 2>/dev/null; }

echo "== 1 Notes: pointers are inlined at dispatch"
dry > "$T/p1.txt"
grep -qF 'marker-inside-total' "$T/p1.txt" && ! grep -qF 'marker-after-total' "$T/p1.txt" \
  && ok "1 a.py:total inlines that function and stops at its end" || { bad "1 function pointer"; tail -3 "$T/out.txt"; }
grep -qF 'helper-line-two' "$T/p1.txt" && ok "1 a.py:1-2 inlines the line range" || bad "1 range pointer"
grep -qF '(not found: a.py:no_such_fn)' "$T/p1.txt" && ok "1 a pointer that resolves to nothing is marked" || bad "1 missing pointer"
grep -qF 'marker-js-def' "$T/p1.txt" && ok "1 h.js:helper inlines the definition, not an earlier call line" || bad "1 JS pointer"
grep -qF 'marker-rs-def' "$T/p1.txt" && ok "1 h.rs:helper resolves a pub(crate) fn" || bad "1 Rust pointer"

echo "== 2 FOUND: lines flow to later tasks of the plan"
FAKE_ACTIONS='echo "# qty" >> a.py; printf "STATUS: DONE\nFOUND: a.py:8 marker-found-fact\n"' \
  $DP 1 --plan PLAN_T.md --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1
RID=$(sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
NF="$RUNS/notes/PLAN_T.md"
[ -n "$RID" ] && [ "$(grep -c 'marker-found-fact' "$NF" 2>/dev/null)" = 1 ] \
  && ok "2 the executor's FOUND: line lands once in the plan's notes file" || { bad "2 notes file (run $RID)"; tail -3 "$T/out.txt"; }
dry > "$T/p2.txt"
grep -qF 'marker-found-fact' "$T/p2.txt" && ok "2 the next executor task of the plan includes it" || bad "2 next task"
$DP --review "${RID:-none}" --via qwen --model fake/m --dry-run --repo "$R" > "$T/out.txt" 2>&1
RV=$(sed -n 's/^DRY RUN REVIEW \([^ ]*\) of.*/\1/p' "$T/out.txt" | head -1)
grep -qF 'marker-found-fact' "$RUNS/${RV:-none}/prompt.txt" 2>/dev/null && ok "2 a --review task of the plan includes it" \
  || { bad "2 review task (review run $RV)"; tail -3 "$T/out.txt"; }

echo "== 3 retry feedback"
dry --extra "EVIDENCE: marker-feedback" > "$T/p3.txt"
grep -qF 'marker-feedback' "$T/p3.txt" && ! grep -qi 'verifier feedback' "$T/p3.txt" \
  && ok "3 --extra reaches the task as feedback from the previous attempt, not verifier feedback" \
  || { bad "3 feedback wording"; grep -i -m2 'feedback' "$T/p3.txt"; }

echo; echo "passed $pass, failed $fail"; [ $fail -eq 0 ]
