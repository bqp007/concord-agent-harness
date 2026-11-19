#!/bin/bash
# Concord simplification (PLAN_concord-slim, 2026-11-19): the review prompt comes from REVIEW.md (B); `After:` takes
# only the leading phase numbers (D); the PR gate holds only on BLOCKER and HIGH and --report takes each PR finding's
# outcome from the gate (E); acceptance files come from the Test plan's Home column and the repository's Cases file
# (F). No network: fake qwen executor/reviewer, fake gh and a local bare repository as the remote.
# Run: bash ~/.claude/concord/tests/simplify_test.sh [B D E F]   (exit 0 = every selected check passed)
set -u
SEL=""
for arg in "$@"; do SEL="$SEL$arg"; done
[ -n "$SEL" ] || SEL=ABCDEFG
sel(){ case "$SEL" in *"$1"*) return 0 ;; esac; return 1; }
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/simplify-test.XXXXXX")" && pwd -P)"; export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/concord" "$T/home/.claude"
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
cat > "$T/bin/qwen" <<'Q'
#!/bin/sh
echo ran >> "$T/qwen_calls"
if [ -n "${FAKE_ACTIONS:-}" ]; then sh -c "$FAKE_ACTIONS"; exit 0; fi
if [ -n "${FAKE_JSON:-}" ]; then cat "$FAKE_JSON"; exit 0; fi
if [ -n "${FAKE_CLEAN:-}" ]; then printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n'; exit 0; fi
printf 'REVIEW-JSON\n{"findings": [{"severity": "%s", "path": "%s", "line": 1, "problem": "wrong constant", "fix": "use 2", "repro": {"input": "x", "expected": "2", "actual": "1"}}], "clauses": [], "tests": [], "verdict": "FIX"}\nEND-REVIEW-JSON\n' "${FAKE_SEV:-HIGH}" "${FAKE_PATH:-a.py}"
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
R="$T/repo"; O="$T/origin.git"; P="$T/pr"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
has(){ grep -F -- "$1" "$T/out.txt" > /dev/null; }
line(){ grep "^$1" "$T/out.txt" | grep -F -- "$2" > /dev/null; }
rid(){ sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1; }
pk(){ sed -n 's/^PACKET \([^ ]*\).*/\1/p' "$T/out.txt" | head -1; }
sec(){ sed -n "/^## $1/,/^## /p" "$2"; }
tokens(){ tr ' ,():|' '\n' | grep -qxF -- "$1"; }
newrepo(){ rm -rf "$R"; mkdir -p "$R/tests"; (
  cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > a.py; printf 'y = 2\n' > b.py; printf 'assert True\n' > tests/test_a.py
  printf 'assert True\n' > tests/test_b.py; printf 'case 1\n' > cases.md
  printf '.claude/\n' > .gitignore
  git add -A && git commit -qm init ); }
tplan(){ cat > "$R/PLAN_T.md" <<P
# Plan
## Test plan
| Behavior | Existing tests | Action | Home |
|---|---|---|---|
| ${2:-a} | test_a | KEEP | tests/test_a.py |

## Phase 1 - change a
Executor: deepseek-flash
Files: $1
Acceptance:
- \`python3 tests/test_a.py\`
- \`python3 tests/test_b.py\`
P
}
run(){ FAKE_ACTIONS="$1" $DP 1 --plan PLAN_T.md --via qwen --model fake/m --no-baseline --repo "$R" > "$T/out.txt" 2>&1; }
prjson(){ printf '{"baseRefName": "main", "headRefOid": "%s", "title": "pr%s", "body": "b"}\n' "$2" "$1" > "$T/pr$1.json"; }
headn(){ git -C "$O" rev-parse "refs/pull/$1/head"; }
newpr(){ # newpr N 'shell': a PR N branch off main with the given change, pushed as its head
  ( set -e; cd "$P"; git checkout -q main; git checkout -qb "pr$1"; sh -c "$2"; git add -A; git commit -qm "pr$1"
    git push -qf origin "HEAD:refs/pull/$1/head"; git checkout -q main ) || { echo "setup failed: newpr $1"; exit 1; }
  prjson "$1" "$(headn "$1")"; }
push7(){ # push7 'shell': a commit on the PR 7 branch, pushed as its new head
  ( set -e; cd "$P"; git checkout -q pr7; sh -c "$1"; git add -A; git commit -qm fix
    git push -qf origin HEAD:refs/pull/7/head; git checkout -q main ) || { echo "setup failed: push7"; exit 1; }
  prjson 7 "$(headn 7)"; }
stn(){ $DP --pr-status "$1" --repo "$P" > "$T/out.txt" 2>&1; }
git init -q --bare -b main "$O" && git clone -q "$O" "$P" 2> /dev/null || { echo "setup failed: repos"; exit 1; }
( set -e; cd "$P"; git config user.email t@t; git config user.name t
  printf 'x = 1\n' > a.py; printf 'z = 1\n' > z.py; printf '.claude/\n' > .gitignore
  git add -A; git commit -qm init; git push -q origin main ) || { echo "setup failed: pr repo"; exit 1; }
newpr 5 'printf "p = 5\n" > p.py'
printf 'REVIEW-JSON\n{"findings": [{"severity": "MEDIUM", "path": "m.py", "line": 1, "problem": "style", "fix": "rename", "repro": {"input": "x", "expected": "2", "actual": "1"}}], "clauses": [], "tests": [], "verdict": "FIX"}\nEND-REVIEW-JSON\n' > "$T/medium.txt"

if sel B; then echo "== B. the review prompt comes from REVIEW.md"
newrepo; tplan a.py
run 'echo "# r" >> a.py'; RID=$(rid)
MARK_B="CHECKLIST-MARKER-9c1e"
printf '\n%s\n' "$MARK_B" >> "$T/concord/REVIEW.md"
$DP --review "$RID" --packet --repo "$R" > "$T/out.txt" 2>&1; PK=$(pk)
[ -n "$PK" ] && [ -f "$PK" ] && grep -qF "$MARK_B" "$PK" && ! grep -qF "Checklists (" "$PK" \
  && ok "B.1 the phase packet carries the REVIEW.md prompt and no checklist list" \
  || bad "B.1 packet '$PK' marker=$(grep -cF "$MARK_B" "$PK" 2> /dev/null)"
$DP --review-pr 5 --packet --repo "$P" > "$T/out.txt" 2>&1; PK=$(pk)
[ -n "$PK" ] && [ -f "$PK" ] && grep -qF "$MARK_B" "$PK" && ! grep -qF "Checklists (" "$PK" \
  && ok "B.2 the PR packet carries the REVIEW.md prompt and no checklist list" \
  || bad "B.2 packet '$PK' marker=$(grep -cF "$MARK_B" "$PK" 2> /dev/null)"
fi

if sel D; then echo "== D. After: takes the leading phase numbers"
python3 -I -B - "$T/concord" > "$T/d.txt" 2>&1 <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import concord as d

def phase(after):
    return f"## Phase 1 - p\nExecutor: deepseek-flash\nFiles: a.py\nAfter: {after}\n"

problems = []
waits, lint = d.est_after(phase("1 waits for 2 files"))
if [n for n, _ in waits] != [1] or lint:
    problems.append(f"digits in a bare reason are waits: waits={waits!r} lint={lint!r}")
elif not waits[0][1].startswith("waits for"):
    problems.append(f"reason lost: waits={waits!r}")
waits, lint = d.est_after(phase("2 (shares a.py), 3"))
if [n for n, _ in waits] != [2, 3] or lint or waits[0][1] != "shares a.py":
    problems.append(f"parenthesized reason, comma item: waits={waits!r} lint={lint!r}")
waits, lint = d.est_after(phase("Phase 1 and 2 (needs both)"))
if [n for n, _ in waits] != [1, 2] or lint:
    problems.append(f"Phase keyword and and-list: waits={waits!r} lint={lint!r}")
waits, lint = d.est_after(phase("none"))
if waits or lint:
    problems.append(f"none: waits={waits!r} lint={lint!r}")
waits, lint = d.est_after(phase("2 (needs the parser"))
if not lint:
    problems.append(f"an unclosed reason is not linted: waits={waits!r} lint={lint!r}")
print("; ".join(problems))
sys.exit(1 if problems else 0)
PY
[ $? -eq 0 ] && ok "D.1 est_after keeps only the leading phase numbers and lints an unclosed reason" \
  || { bad "D.1 est_after: $(cat "$T/d.txt")"; }
fi

if sel E; then echo "== E. the gate holds on BLOCKER and HIGH; the report takes each finding's outcome from it"
newpr 9 'printf "m = 9\n" > m.py'; H9=$(headn 9)
FAKE_JSON="$T/medium.txt" $DP --review-pr 9 --via qwen --model fake/m --user-approved "test go-ahead" --tier high \
  --repo "$P" > "$T/out.txt" 2>&1; RC=$?
stn 9
[ $RC -eq 0 ] && has "CURRENT HEAD ${H9:0:8}: REVIEWED at high" && ! has "FINDINGS OPEN" \
  && ok "E.1 a high-tier full review holding only a MEDIUM leaves the head REVIEWED at high" \
  || { bad "E.1 MEDIUM held the gate (rc=$RC)"; tail -2 "$T/out.txt"; }
cat > "$P/PLAN_E.md" <<'P'
# Plan: raise x
Tier: M
Size: ~60 lines
ETA: 90 min

## Test plan
| Behavior | Existing tests | Action | Home |
|---|---|---|---|
| x | test_x | ADD | - |

## Phase 1 - raise x
Executor: deepseek-flash
Files: a.py
Acceptance:
- `grep -q 2 a.py`
P
( cd "$P" && git add PLAN_E.md && git commit -qm plan ) > /dev/null 2>&1 || { echo "setup failed: plan commit"; exit 1; }
printf 'VERDICT: APPROVE\n' > "$T/verdict.txt"
$DP --plan-verdict "$T/verdict.txt" --plan PLAN_E.md --repo "$P" > "$T/out.txt" 2>&1
FAKE_ACTIONS='printf "x = 2\n" > a.py' $DP 1 --plan PLAN_E.md --via qwen --model fake/m --repo "$P" > "$T/run.txt" 2>&1
RIDE=$(sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/run.txt" | head -1)
printf 'REVIEW-JSON\n{"findings": [{"severity": "HIGH", "path": "a.py", "line": 1, "problem": "plan-high-marker", "fix": "use 3", "repro": {"input": "x", "expected": "3", "actual": "2"}}], "clauses": [], "tests": [], "verdict": "FIX"}\nEND-REVIEW-JSON\n' > "$T/planhigh.txt"
FAKE_JSON="$T/planhigh.txt" $DP --review "$RIDE" --via qwen --model fake/m --repo "$P" > "$T/rev.txt" 2>&1
PHIGH=$(python3 -I -c 'import json,sys
d = json.load(open(sys.argv[1]))
print(next((f["id"] for f in d["findings"] if f.get("severity") == "HIGH"), ""))' \
  "$P/.git/concord/ledger/PLAN_E.json" 2> /dev/null)
( cd "$P" && git checkout -qb pr7 && git commit -qam "head 1" && git push -qf origin HEAD:refs/pull/7/head \
  && git checkout -q main ) > /dev/null 2>&1 || { echo "setup failed: PR 7 head 1"; exit 1; }
prjson 7 "$(headn 7)"; H1=$(headn 7)
$DP --review-pr 7 --via qwen --model fake/m --user-approved "test go-ahead" --tier high --repo "$P" > "$T/out.txt" 2>&1
HIGH=$(python3 -I -c 'import json,sys
d = json.load(open(sys.argv[1]))
print(next((f["id"] for f in d["findings"] if f.get("severity") == "HIGH"), ""))' \
  "$P/.git/concord/ledger/pr7.json" 2> /dev/null)
push7 'printf "x = 3\n" > a.py'; H2=$(headn 7)
FAKE_CLEAN=1 $DP --review-pr 7 --delta --via qwen --model fake/m --user-approved "test go-ahead" --tier high \
  --repo "$P" > "$T/out.txt" 2>&1; RC=$?
stn 7
[ $RC -eq 0 ] && [ -n "$HIGH" ] && has "CURRENT HEAD ${H2:0:8}: REVIEWED at high" \
  && ok "E.2 a HIGH at head 1, a fix commit and a clean delta leave head 2 REVIEWED at high" \
  || { bad "E.2 delta flow rc=$RC high='$HIGH'"; tail -3 "$T/out.txt"; }
( cd "$P" && git checkout -q main && git merge -q --ff-only pr7 ) > /dev/null 2>&1 || { echo "setup failed: merge"; exit 1; }
python3 -I - "$P/.git/concord/ledger/pr7.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data.setdefault("findings", []).append(
    {"id": "F900", "severity": "MEDIUM", "path": "a.py", "line": 2, "line_end": 2,
     "problem": "medium-marker-pr7", "fix": "tighten it",
     "repro": {"input": "x", "expected": "2", "actual": "1"},
     "reviewer": "reviewer-opus55", "run": "pr7-medium", "status": "open"})
data["findings"].append(
    {"id": "F901", "severity": "HIGH", "path": "a.py", "line": 3, "line_end": 3,
     "problem": "declined-high-marker", "fix": "use 4",
     "repro": {"input": "x", "expected": "4", "actual": "3"},
     "reviewer": "reviewer-opus55", "run": "pr7-declined", "status": "declined"})
data["findings"].append(dict(data["findings"][-1], id="F902", problem="adopted-high-marker", status="adopted"))
json.dump(data, open(path, "w"))
PY
$DP --report --plan PLAN_E.md --repo "$P" > "$T/rep.txt" 2>&1; RC=$?
REP=$(sed -n 's/^report: //p' "$T/rep.txt" | head -1)
[ $RC -eq 0 ] && [ -f "$REP" ] || { REP="$T/none"; bad "E.3 --report rc=$RC"; tail -3 "$T/rep.txt"; }
OPEN="$(sec "Open items for the DAT" "$REP")"
grep -E "^Fixed \(PR 7 " "$REP" | tokens "$HIGH" && ! printf '%s\n' "$OPEN" | grep -qF "wrong constant" \
  && ok "E.3 the report moves the REVIEWED PR's HIGH to a Fixed line and keeps it out of the open items" \
  || { bad "E.3 Fixed='$(grep -E "^Fixed" "$REP" | head -2)' HIGH='$HIGH'"; printf '%s\n' "$OPEN" | head -5; }
printf '%s\n' "$OPEN" | grep -F "medium-marker-pr7" | grep -qF "(status open)" \
  && ok "E.4 a MEDIUM of the same PR with status open stays in the open items" \
  || { bad "E.4 open items: $(printf '%s\n' "$OPEN" | head -3)"; }
grep -q "Never adjudicated" "$REP" && bad "E.5 the report still prints Never adjudicated" \
  || ok "E.5 the report prints no Never adjudicated line"
[ -n "$PHIGH" ] && grep -E "^Fixed \(every PR REVIEWED\)" "$REP" | tokens "$PHIGH" \
  && ! printf '%s\n' "$OPEN" | grep -qF "plan-high-marker" \
  && ok "E.6 with every PR REVIEWED the plan ledger's HIGH moves to a Fixed line" \
  || { bad "E.6 plan HIGH='$PHIGH' Fixed='$(grep -E "^Fixed" "$REP" | head -2)'"; }
! grep -E "^Fixed" "$REP" | tokens F901 && grep -E "^Fixed \(PR 7 " "$REP" | tokens F902 \
  && ok "E.7 a declined HIGH lands on no Fixed line and an adopted one does" \
  || bad "E.7 Fixed='$(grep -E "^Fixed" "$REP" | head -2)'"
fi

if sel F; then echo "== F. acceptance files come from the Test plan and the repo's Cases file"
printf '# repo: binding facts\nCases: cases.md\n' > "$T/concord/repo-notes/repo.md"
newrepo; tplan a.py
run 'echo "# r" >> a.py; echo "# t" >> tests/test_a.py'; RID=$(rid)
line "ACCEPTANCE FILES CHANGED:" "tests/test_a.py (modified)" \
  && ok "F.1 an edit of a Test plan Home file is reported" || { bad "F.1 no acceptance line"; grep -i accept "$T/out.txt" | head -3; }
$DP --verdict "$RID" PASS --repo "$R" > "$T/v.txt" 2>&1; RC=$?
[ -n "$RID" ] && [ $RC -eq 7 ] && ok "F.2 --verdict PASS on changed acceptance files exits 7" || bad "F.2 rc=$RC run=$RID"
newrepo; tplan a.py
run 'echo "# r" >> a.py; echo "# t" >> tests/test_b.py'
! has "ACCEPTANCE FILES CHANGED" \
  && ok "F.3 a test an acceptance command names but the Test plan does not list is no acceptance file" \
  || bad "F.3: $(grep -F "ACCEPTANCE FILES CHANGED" "$T/out.txt" | head -2)"
newrepo; tplan 'a.py, tests/test_a.py'
run 'echo "# t" >> tests/test_a.py'
! has "ACCEPTANCE FILES CHANGED" && ok "F.4 a Home file that the phase's Files: lists is no acceptance file" \
  || bad "F.4: $(grep -F "ACCEPTANCE FILES CHANGED" "$T/out.txt" | head -2)"
newrepo; tplan 'a.py, cases.md'
run 'echo "case 2" >> cases.md'
line "ACCEPTANCE FILES CHANGED:" "cases.md (modified)" \
  && ok "F.5 the repository's Cases file stays an acceptance file when Files: lists it" \
  || { bad "F.5 no acceptance line"; grep -i accept "$T/out.txt" | head -3; }
newrepo; tplan a.py 'mode full\|edit'
run 'echo "# r" >> a.py; echo "# t" >> tests/test_a.py'
line "ACCEPTANCE FILES CHANGED:" "tests/test_a.py (modified)" \
  && ok "F.6 an escaped pipe in a Test plan cell leaves the Home column in place" \
  || { bad "F.6 no acceptance line"; grep -i accept "$T/out.txt" | head -3; }
fi

echo; echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
