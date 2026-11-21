#!/bin/bash
# Concord simplification: the review prompt comes from REVIEW.md (B); `After:` takes only the leading phase numbers (D);
# the PR gate holds only on BLOCKER and HIGH, and a HIGH closes by a resolution of a later head (E); acceptance files
# come from the Test plan's Home column and the repository's Cases file (F). No network: fake qwen executor/reviewer,
# fake gh and a local bare repository as the remote.
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
. "$(dirname "$0")/lib.sh"
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
  approve PLAN_T.md "$R" || exit 1
}
run(){ FAKE_ACTIONS="$1" $DP 1 --plan PLAN_T.md --via qwen --model fake/m --no-baseline --repo "$R" > "$T/out.txt" 2>&1
  grep -q '^DELEGATE RESULT' "$T/out.txt" || { echo "setup failed: the run did not start"; cat "$T/out.txt"; exit 1; }; }
prjson(){ printf '{"baseRefName": "main", "headRefName": "pr%s", "headRefOid": "%s", "title": "pr%s", "body": "b"}\n' "$1" "$2" "$1" > "$T/pr$1.json"; }
headn(){ git -C "$O" rev-parse "refs/pull/$1/head"; }
newpr(){ # newpr N 'shell': a PR N branch off main with the given change, pushed as its head
  ( set -e; cd "$P"; git checkout -q main; git checkout -qb "pr$1"; sh -c "$2"; git add -A; git commit -qm "pr$1"
    git push -qf origin "HEAD:refs/pull/$1/head"; git checkout -q main ) || { echo "setup failed: newpr $1"; exit 1; }
  prjson "$1" "$(headn "$1")"; }
push7(){ # push7 'shell': a commit on the PR 7 branch, pushed as its new head
  ( set -e; cd "$P"; git fetch -q origin refs/pull/7/head; git checkout -q FETCH_HEAD; sh -c "$1"; git add -A; git commit -qm fix
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
[ -n "$PK" ] && [ -f "$PK" ] && grep -qF "$MARK_B" "$PK" \
  && ok "B.1 the phase packet carries the REVIEW.md prompt" \
  || bad "B.1 packet '$PK' marker=$(grep -cF "$MARK_B" "$PK" 2> /dev/null)"
$DP --review-pr 5 --packet --repo "$P" > "$T/out.txt" 2>&1; PK=$(pk)
[ -n "$PK" ] && [ -f "$PK" ] && grep -qF "$MARK_B" "$PK" \
  && ok "B.2 the PR packet carries the REVIEW.md prompt" \
  || bad "B.2 packet '$PK' marker=$(grep -cF "$MARK_B" "$PK" 2> /dev/null)"
newrepo; tplan a.py   # a fork run: it starts at a snapshot commit that holds earlier uncommitted work
( cd "$R" && echo '# earlier' >> a.py && git commit -qam snapshot ) || { echo "setup failed: snapshot"; exit 1; }
run 'echo "# r" >> a.py'; RID=$(rid)
( cd "$R" && git reset -q --soft HEAD~1 ) || { echo "setup failed: reset"; exit 1; }
$DP --review "$RID" --packet --repo "$R" > "$T/out.txt" 2>&1; PK=$(pk)
[ -n "$PK" ] && grep -qF '+# r' "$PK" && ! grep -qF '# earlier' "$PK" \
  && ok "B.3 a run whose start commit is no ancestor of HEAD shows only its own change" \
  || bad "B.3 packet '$PK' earlier=$(grep -cF '# earlier' "$PK" 2> /dev/null)"
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

if sel E; then echo "== E. the gate holds on BLOCKER and HIGH, not on a MEDIUM; a HIGH closes by a resolution of a later head"
# opus N TIER ANSWER-FILE [ARGS]: an Opus packet of PR N answered with the file's text (signed) and recorded as reviewer-opus55
opus(){ local n=$1 t=$2 ans=$3; shift 3; $DP --review-pr "$n" --packet --tier "$t" "$@" --repo "$P" > "$T/out.txt" 2>&1
  local pk; pk=$(sed -n 's/^PACKET \([^ ]*\).*/\1/p' "$T/out.txt" | head -1); [ -n "$pk" ] || { echo "setup failed: no packet for PR $n"; cat "$T/out.txt"; exit 1; }
  cp "$ans" "$T/ans.txt"; sign "$T/ans.txt" "$pk"
  $DP --review-record "$(basename "$(dirname "$pk")")" --reviewer concord:reviewer-opus55 --file "$T/ans.txt" --repo "$P" > "$T/rec.txt" 2>&1; }
newpr 9 'printf "m = 9\n" > m.py'; H9=$(headn 9)
cp "$T/medium.txt" "$T/e1.txt"; opus 9 medium "$T/e1.txt"; RC=$?; stn 9
[ $RC -eq 0 ] && has "REVIEWED at" && ! has "UNREVIEWED" && ! has "FINDINGS OPEN" \
  && ok "E.1 a full review holding only a MEDIUM leaves the head REVIEWED" \
  || { bad "E.1 MEDIUM held the gate (rc=$RC)"; tail -2 "$T/out.txt"; }
newpr 7 'printf "x = 2\n" > a.py'
printf 'REVIEW-JSON\n{"findings": [{"severity": "HIGH", "path": "a.py", "line": 1, "problem": "wrong constant", "fix": "use 3", "repro": {"input": "x", "expected": "3", "actual": "2"}}], "clauses": [], "tests": [], "verdict": "FIX"}\nEND-REVIEW-JSON\n' > "$T/e2a.txt"
opus 7 medium "$T/e2a.txt"; stn 7; has "FINDINGS OPEN" || { bad "E.2 setup: the HIGH is not open"; cat "$T/out.txt"; }
push7 'printf "x = 3\n" > a.py'; H2=$(headn 7)
printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN", "resolutions": [{"finding": "F1", "fixed": "yes", "evidence": "a.py:1 it is 3 now"}], "hunks": [{"hunk": "H1", "explained_by": "F1"}]}\nEND-REVIEW-JSON\n' > "$T/e2b.txt"
opus 7 medium "$T/e2b.txt" --delta; stn 7
has "REVIEWED at" && ! has "UNREVIEWED" && ! has "FINDINGS OPEN" \
  && ok "E.2 a HIGH at head 1, a fix commit and a delta that resolves it and explains its hunk leave head 2 REVIEWED" \
  || { bad "E.2 delta flow"; tail -3 "$T/out.txt"; }
fi

if sel F; then echo "== F. acceptance files come from the Test plan and the repo's Cases file"
printf '# repo: binding facts\nCases: cases.md\n' > "$T/concord/repo-notes/repo.md"
newrepo; tplan a.py
run 'echo "# r" >> a.py; echo "# t" >> tests/test_a.py'; RID=$(rid)
line "ACCEPTANCE FILES CHANGED:" "tests/test_a.py (modified)" \
  && ok "F.1 an edit of a Test plan Home file is reported" || { bad "F.1 no acceptance line"; grep -i accept "$T/out.txt" | head -3; }
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
