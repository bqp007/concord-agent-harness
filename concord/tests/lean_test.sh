#!/bin/bash
# The lean revision (2026-10-23, kit-lean). (1) --pr-status credits a review only up to its reviewer's rank (flash =
# low, reviewer-opus48 = medium, reviewer-opus55 = high) unless the user's go-ahead is recorded with --user-approved;
# wt.py refuses a branch name that is not UTF-8 text; the dry run names the repository's notes from a worktree; a
# provider refusal is read only from a failed run's log tail. (2) The removed commands (--map, --card, --stats,
# --close-round, --review-decide, --review-adjudicate) are unrecognized, their code and report text are gone, and
# --verdict PASS no longer checks the review tier (no exit 9). (3) --mutate samples 10 mutants by default;
# OUTSIDE CHECKOUT ignores settings.local.json and other repositories' notes but still reports this repository's.
# No network: fake gh, fake qwen executor and reviewer, a local bare repository as the remote.
# Run: bash ~/.claude/concord/tests/lean_test.sh [SECTION ...]   (default all; exit 0 = every selected check passed)
set -u
SEL=" ${*:-all} "
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/lean-test.XXXXXX")" && pwd -P)"; export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/concord" "$T/home/.claude"
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
cat > "$T/bin/qwen" <<'Q'
#!/bin/sh
echo ran >> "$T/qwen_calls"
if [ -n "${FAKE_ACTIONS:-}" ]; then sh -c "$FAKE_ACTIONS"; exit "${FAKE_RC:-0}"; fi
printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n'
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
WT="python3 $T/concord/wt.py"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
has(){ grep -F -- "$1" "$T/out.txt" > /dev/null; }
sel(){ case "$SEL" in *" all "*|*" $1 "*) return 0;; esac; return 1; }
calls(){ [ -f "$T/qwen_calls" ] && wc -l < "$T/qwen_calls" | tr -d ' ' || echo 0; }
gitrepo(){ mkdir -p "$1" && ( cd "$1" && git init -q -b main && git config user.email t@t && git config user.name t ); }
JCLEAN='REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n'

if sel 1; then
echo "== 1 --pr-status credits the reviewer, not the declared tier"
O="$T/origin.git"; C="$T/clone"
git init -q --bare -b main "$O" && git clone -q "$O" "$C" 2> /dev/null || { echo "setup failed: repos"; exit 1; }
( set -e; cd "$C"; git config user.email t@t; git config user.name t
  printf 'x = 1\n' > a.py; printf '.claude/\n' > .gitignore; git add -A; git commit -qm init; git push -q origin main ) \
  || { echo "setup failed: main"; exit 1; }
prjson(){ printf '{"baseRefName": "main", "headRefOid": "%s", "title": "t", "body": "b"}\n' "$(hd "$1")" > "$T/pr$1.json"; }
hd(){ git -C "$O" rev-parse "refs/pull/$1/head"; }
# newpr N FILE TEXT: PR N adds FILE holding TEXT on top of main; pushpr N FILE TEXT: a fix commit on PR N's head
newpr(){ ( set -e; cd "$C"; git checkout -q main; git checkout -qb "pr$1"; printf '%s\n' "$3" > "$2"; git add -A
  git commit -qm "pr$1"; git push -qf origin "HEAD:refs/pull/$1/head"; git checkout -q main; git branch -qD "pr$1" ) \
  || { echo "setup failed: pr$1"; exit 1; }; prjson "$1"; }
pushpr(){ ( set -e; cd "$C"; git fetch -q origin "refs/pull/$1/head"; git checkout -q FETCH_HEAD; printf '%s\n' "$3" > "$2"
  git add -A; git commit -qm fix; git push -q origin "HEAD:refs/pull/$1/head"; git checkout -q main ) \
  || { echo "setup failed: push $1"; exit 1; }; prjson "$1"; }
flash(){ local n=$1; shift; $DP --review-pr "$n" --via qwen --model fake/m "$@" --repo "$C" > "$T/out.txt" 2>&1; }
# opus N TIER NAME [--delta]: an Opus packet at TIER, answered CLEAN and recorded under reviewer NAME
opus(){ $DP --review-pr "$1" --packet --tier "$2" ${4:-} --repo "$C" > "$T/out.txt" 2>&1
  local pk; pk=$(sed -n 's/^PACKET \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
  [ -n "$pk" ] || { echo "    (no packet for PR $1: $(tail -1 "$T/out.txt"))"; return 1; }
  printf '%b' "$JCLEAN" > "$T/rev.txt"
  $DP --review-record "$(basename "$(dirname "$pk")")" --reviewer "$3" --file "$T/rev.txt" --repo "$C" > /dev/null 2>&1; }
st(){ $DP --pr-status "$1" --repo "$C" > "$T/out.txt" 2>&1; }

newpr 37 b.py 'b = 1'; H37=$(hd 37)
flash 37 --tier high; flash 37 --tier high; st 37
has "CURRENT HEAD ${H37:0:8}: UNREVIEWED at high: the best review counts at low" && has "needs concord:reviewer-opus55" \
  && ! has ": REVIEWED" && ok "1 two flash reviews declared high (PR 37's case): UNREVIEWED at high, names reviewer-opus55" \
  || { bad "1 flash at high"; tail -3 "$T/out.txt"; }
opus 37 high concord:reviewer-opus55; st 37
has "CURRENT HEAD ${H37:0:8}: REVIEWED at high" && ok "1 a concord:reviewer-opus55 review at high: REVIEWED at high" \
  || { bad "1 opus55 at high"; tail -3 "$T/out.txt"; }
flash 37 --tier high --force-review; st 37
has "CURRENT HEAD ${H37:0:8}: REVIEWED at high" && ok "1 a newer flash review beside it changes nothing (order-independent)" \
  || { bad "1 order"; tail -3 "$T/out.txt"; }
newpr 38 c.py 'c = 1'; H38=$(hd 38)
flash 38 --tier low; st 38
has "CURRENT HEAD ${H38:0:8}: REVIEWED at low" && ok "1 a flash review at low: REVIEWED at low" || { bad "1 flash at low"; tail -3 "$T/out.txt"; }
newpr 39 d.py 'd = 1'; H39=$(hd 39)
flash 39 --tier high --user-approved "ship  it"; st 39
has "CURRENT HEAD ${H39:0:8}: REVIEWED at high (owner override: \"ship it\")" \
  && ok "1 --user-approved on a flash review at high: REVIEWED at high, the override shown" || { bad "1 override"; tail -3 "$T/out.txt"; }
newpr 40 e.py 'e = 1'; H40=$(hd 40)
opus 40 high reviewer-opus48; st 40
has "CURRENT HEAD ${H40:0:8}: UNREVIEWED at high: the best review counts at medium (reviewer-opus48)" \
  && ok "1 reviewer-opus48 counts at medium only" || { bad "1 opus48 at high"; tail -3 "$T/out.txt"; }
newpr 44 g.py 'g = 1'; H44=$(hd 44)
opus 44 high reviewer-opus48 "--user-approved go-ahead"; st 44
has "CURRENT HEAD ${H44:0:8}: REVIEWED at high (owner override: \"go-ahead\")" \
  && ok "1 --user-approved on a packet review (reviewer-opus48 at high): REVIEWED at high, the override shown" \
  || { bad "1 packet override"; tail -3 "$T/out.txt"; }
newpr 41 b.py 'b = 1'; H41=$(hd 41)
C0=$(calls); flash 41 --tier high; R41=$(cat "$T/out.txt"); st 41
case "$R41" in *"COVERED: 1 files already reviewed by reviewer-opus55 (high)"*) [ "$(calls)" = "$C0" ] \
  && has "CURRENT HEAD ${H41:0:8}: REVIEWED at high" && ok "1 content an Opus 5.5 review cleared: COVERED, REVIEWED at high" \
  || { bad "1 opus cover status"; tail -2 "$T/out.txt"; };; *) bad "1 opus cover: $(printf '%s' "$R41" | tail -2)";; esac
newpr 42 c.py 'c = 1'; H42=$(hd 42)
C0=$(calls); flash 42 --tier high; st 42
[ "$(calls)" = "$((C0+1))" ] && has "CURRENT HEAD ${H42:0:8}: UNREVIEWED at high" \
  && ok "1 content only a flash review cleared is not covered at high" || { bad "1 flash cover"; tail -2 "$T/out.txt"; }
pushpr 37 b.py 'b = 2'; H37B=$(hd 37)
flash 37 --delta --tier high; st 37
has "CURRENT HEAD ${H37B:0:8}: UNREVIEWED at high" && ! has ": REVIEWED" \
  && ok "1 a flash delta at high on a code fix: UNREVIEWED at high" || { bad "1 flash delta"; tail -3 "$T/out.txt"; }
newpr 43 f.py 'f = 1'; opus 43 high reviewer-opus55
pushpr 43 NOTES.md 'notes'; H43B=$(hd 43)
flash 43 --delta; st 43
has "CURRENT HEAD ${H43B:0:8}: REVIEWED at high (via delta from" && has "light fix at low" \
  && ok "1 a light (docs-only) delta keeps the reviewed tier (characterization)" || { bad "1 light delta"; tail -3 "$T/out.txt"; }

echo "== 1 wt.py: a branch name that is not UTF-8"
M="$T/main"; gitrepo "$M"; ( cd "$M" && printf 'x\n' > x && git add x && git commit -qm init ) || { echo "setup failed: main"; exit 1; }
$WT new T1 --branch $'\xff' --no-fetch --repo "$M" > "$T/out.txt" 2>&1; RC=$?
[ $RC -ne 0 ] && has "branch name is not UTF-8 text" && ! has "Traceback" && [ ! -e "$M/.claude/worktrees/T1" ] \
  && [ "$(git -C "$M" for-each-ref refs/heads | wc -l | tr -d ' ')" = 1 ] \
  && ok "1 wt.py new --branch \$'\\xff': clean refusal, nothing created" || { bad "1 wt utf-8 rc=$RC"; tail -3 "$T/out.txt"; }

echo "== 1 dry run from a worktree names the repository's notes"
printf -- '- a binding note\n' > "$T/concord/repo-notes/main.md"
( cd "$M" && printf '.claude/\n' > .gitignore && git add .gitignore && git commit -qm ignore \
  && git worktree add -q -b feature/wt "$T/elsewhere" ) || { echo "setup failed: worktree"; exit 1; }
printf '# Plan\n## Phase 1 - x\nExecutor: deepseek-flash\nRisk: low\nFiles: x\nAcceptance:\n- `grep -q y x`\n' > "$T/elsewhere/PLAN_T.md"
$DP 1 --plan PLAN_T.md --via qwen --model fake/m --dry-run --repo "$T/elsewhere" > "$T/out.txt" 2>&1
has "repo notes: yes ($T/concord/repo-notes/main.md)" && ok "1 the dry run's repo notes line names main.md, not the worktree folder" \
  || { bad "1 notes line"; grep "repo notes" "$T/out.txt"; }

echo "== 1 provider refusals come from a failed run's log tail"
R="$T/repo"; gitrepo "$R"; ( cd "$R" && printf 'x = 1\n' > a.py && printf '.claude/\n' > .gitignore && git add -A && git commit -qm init \
  && printf '# Plan\n## Phase 1 - x\nExecutor: deepseek-flash\nRisk: low\nFiles: a.py\nAcceptance:\n- `grep -q y a.py`\n' > PLAN_T.md ) \
  || { echo "setup failed: repo"; exit 1; }
run(){ FAKE_ACTIONS="$1" $DP 1 --plan PLAN_T.md --via qwen --model fake/m --no-baseline --repo "$R" > "$T/out.txt" 2>&1; }
run "echo 'PROVIDER_REFUSALS = (\"usage limit exceeded\", ...)'; printf 'y = 1\n' > a.py"
! has "PROVIDER LIMIT" && ok "1 a green run that printed refusal text from source: no PROVIDER LIMIT line" \
  || { bad "1 green run"; grep PROVIDER "$T/out.txt"; }
( cd "$R" && git checkout -q -- a.py )
run "echo 'Error: usage limit exceeded'; i=0; while [ \$i -lt 70 ]; do echo line \$i; i=\$((i+1)); done"
! has "PROVIDER LIMIT" && ok "1 a failed run whose refusal text is not in the last 60 lines: no PROVIDER LIMIT line" \
  || { bad "1 early text"; grep PROVIDER "$T/out.txt"; }
fi

if sel 2; then
echo "== 2 removed commands and report text"
for f in "--map PLAN_T.md" "--card last" "--stats" "--close-round last" "--review-decide last" "--review-adjudicate last"; do
  $DP $f --repo "$T" > "$T/out.txt" 2>&1; RC=$?
  [ $RC -eq 2 ] && has "unrecognized arguments" && ok "2 $f: unrecognized, exit 2" || { bad "2 $f rc=$RC"; tail -2 "$T/out.txt"; }
done
python3 -I - "$T/concord/concord.py" <<'PY' && ok "2 the removed functions and their report text are gone" || bad "2 leftovers"
import ast, sys
src = open(sys.argv[1]).read()
names = {n.name for n in ast.walk(ast.parse(src)) if isinstance(n, ast.FunctionDef)}
gone = {"cmd_map", "cmd_card", "cmd_stats", "cmd_close_round", "cmd_review_decide", "cmd_review_adjudicate",
        "review_tier_refusal", "parse_budget", "check_interfaces", "repo_gaps", "map_lint", "context_lint"}
left = sorted(names & gone) + [t for t in ("SPEC_GAP", "OVER BUDGET", "INTERFACE MISMATCH", "MAP LINT", "CONTEXT LINT",
                                           "PROMOTE", "no Inputs field", ".gaps.md") if t in src]
if left:
    print("  leftovers:", left)
sys.exit(1 if left else 0)
PY
R="$T/repo2"; gitrepo "$R"; ( cd "$R" && printf 'x = 1\n' > a.py && printf '.claude/\n' > .gitignore && git add -A && git commit -qm init \
  && printf '# Plan\n## Phase 1 - x\nExecutor: deepseek-flash\nRisk: high\nFiles: a.py\nAcceptance:\n- `grep -q y a.py`\n' > PLAN_T.md ) \
  || { echo "setup failed: repo2"; exit 1; }
FAKE_ACTIONS="echo y >> a.py" $DP 1 --plan PLAN_T.md --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1
$DP --verdict last PASS --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "verdict PASS" && ok "2 --verdict PASS on an unreviewed Risk: high run is recorded (no exit 9)" \
  || { bad "2 verdict rc=$RC"; tail -2 "$T/out.txt"; }
fi

if sel 3; then
echo "== 3 --mutate samples 10 by default"
R="$T/repo3"; gitrepo "$R"; ( cd "$R" && printf '.claude/\n' > .gitignore && git add -A && git commit -qm init \
  && printf '# Plan\n## Phase 1 - x\nExecutor: deepseek-flash\nRisk: low\nFiles: m.py\nAcceptance:\n- `python3 -c "import m"`\n' > PLAN_T.md ) \
  || { echo "setup failed: repo3"; exit 1; }
FAKE_ACTIONS='i=0; while [ $i -lt 12 ]; do echo "v$i = $i + 1" >> m.py; i=$((i+1)); done' \
  $DP 1 --plan PLAN_T.md --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1
$DP --mutate last --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && grep -qE "^MUTATION [^ ]+: 10 mutants \(sampled from [0-9]+" "$T/out.txt" && ok "3 --mutate without --max samples 10 mutants" \
  || { bad "3 default max rc=$RC"; grep MUTATION "$T/out.txt"; }
echo "== 3 OUTSIDE CHECKOUT watches what could loosen the rules, not other sessions' files"
R="$T/repo4"; gitrepo "$R"; ( cd "$R" && printf 'x = 1\n' > a.py && printf '.claude/\n' > .gitignore && git add -A && git commit -qm init \
  && printf '# Plan\n## Phase 1 - x\nExecutor: deepseek-flash\nRisk: low\nFiles: a.py\nAcceptance:\n- `grep -q y a.py`\n' > PLAN_T.md ) \
  || { echo "setup failed: repo4"; exit 1; }
printf '{}\n' > "$HOME/.claude/settings.local.json"; printf 'n\n' > "$T/concord/repo-notes/other.md"; printf 'n\n' > "$T/concord/repo-notes/repo4.md"
FAKE_ACTIONS="echo y >> a.py; echo 1 >> \"$HOME/.claude/settings.local.json\"; echo 1 >> \"$T/concord/repo-notes/other.md\"" \
  $DP 1 --plan PLAN_T.md --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1
has "changed in scope: a.py" && ! has "OUTSIDE CHECKOUT CHANGED" && ok "3 settings.local.json and another repository's notes: not reported" \
  || { bad "3 narrowed watch"; grep -e OUTSIDE -e status "$T/out.txt"; }
git -C "$R" checkout -q -- a.py
FAKE_ACTIONS="echo y >> a.py; echo 1 >> \"$T/concord/repo-notes/repo4.md\"" \
  $DP 1 --plan PLAN_T.md --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1
grep "^OUTSIDE CHECKOUT CHANGED:" "$T/out.txt" | grep -qF "repo-notes/repo4.md (modified)" && ok "3 this repository's notes: reported" \
  || { bad "3 own notes"; grep -e OUTSIDE -e status "$T/out.txt"; }
fi

echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
