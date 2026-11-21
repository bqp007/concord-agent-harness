#!/bin/bash
# (1) --pr-status credits a review only up to its reviewer's rank (flash = low, reviewer-opus55 = high); wt.py refuses a
# branch name that is not UTF-8 text; the dry run names the repository's notes from a worktree; a provider refusal is
# read only from a failed run's log tail. (2) --verdict PASS does not check the review tier (no exit 9). (3) --mutate
# samples 10 mutants by default; OUTSIDE CHECKOUT ignores settings.local.json and other repositories' notes but still
# reports this repository's.
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
. "$(dirname "$0")/lib.sh"
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
prjson(){ printf '{"baseRefName": "main", "headRefName": "pr%s", "headRefOid": "%s", "title": "t", "body": "b"}\n' "$1" "$(hd "$1")" > "$T/pr$1.json"; }
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
  printf '%b' "$JCLEAN" > "$T/rev.txt"; sign "$T/rev.txt" "$pk"
  $DP --review-record "$(basename "$(dirname "$pk")")" --reviewer "$3" --file "$T/rev.txt" --repo "$C" > /dev/null 2>&1; }
st(){ $DP --pr-status "$1" --repo "$C" > "$T/out.txt" 2>&1; }

newpr 37 b.py 'b = 1'
flash 37 --tier high; flash 37 --tier high; st 37
has "UNREVIEWED" && ! has ": REVIEWED" && ok "1 two flash reviews declared high: UNREVIEWED, a flash review counts at low only" \
  || { bad "1 flash at high"; tail -3 "$T/out.txt"; }
opus 37 high concord:reviewer-opus55; st 37
has "REVIEWED at" && ! has "UNREVIEWED" && ok "1 a concord:reviewer-opus55 review at high: REVIEWED" || { bad "1 opus55 at high"; tail -3 "$T/out.txt"; }
flash 37 --tier high; st 37
has "REVIEWED at" && ! has "UNREVIEWED" && ok "1 a newer flash review beside it changes nothing (order-independent)" || { bad "1 order"; tail -3 "$T/out.txt"; }
newpr 42 c.py 'c = 1'
C0=$(calls); flash 42 --tier high; st 42
[ "$(calls)" = "$((C0+1))" ] && has "UNREVIEWED" && ok "1 content only a flash review cleared is not covered at high" || { bad "1 flash cover"; tail -2 "$T/out.txt"; }
pushpr 37 b.py 'b = 2'
flash 37 --delta --tier high; st 37
has "UNREVIEWED" && ! has ": REVIEWED" && ok "1 a flash delta on a code fix does not carry the Opus review" || { bad "1 flash delta"; tail -3 "$T/out.txt"; }

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
approve PLAN_T.md "$T/elsewhere" || exit 1
$DP 1 --plan PLAN_T.md --via qwen --model fake/m --dry-run --repo "$T/elsewhere" > "$T/out.txt" 2>&1
has "repo notes: yes ($T/concord/repo-notes/main.md)" && ok "1 the dry run's repo notes line names main.md, not the worktree folder" \
  || { bad "1 notes line"; grep "repo notes" "$T/out.txt"; }

echo "== 1 provider refusals come from a failed run's log tail"
R="$T/repo"; gitrepo "$R"; ( cd "$R" && printf 'x = 1\n' > a.py && printf '.claude/\n' > .gitignore && git add -A && git commit -qm init \
  && printf '# Plan\n## Phase 1 - x\nExecutor: deepseek-flash\nRisk: low\nFiles: a.py\nAcceptance:\n- `grep -q y a.py`\n' > PLAN_T.md ) \
  || { echo "setup failed: repo"; exit 1; }
approve PLAN_T.md "$R" || exit 1
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
echo "== 2 --verdict PASS does not check the review tier"
R="$T/repo2"; gitrepo "$R"; ( cd "$R" && printf 'x = 1\n' > a.py && printf '.claude/\n' > .gitignore && git add -A && git commit -qm init \
  && printf '# Plan\n## Phase 1 - x\nExecutor: deepseek-flash\nRisk: high\nFiles: a.py\nAcceptance:\n- `grep -q y a.py`\n' > PLAN_T.md ) \
  || { echo "setup failed: repo2"; exit 1; }
approve PLAN_T.md "$R" || exit 1
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
approve PLAN_T.md "$R" || exit 1
FAKE_ACTIONS='i=0; while [ $i -lt 12 ]; do echo "v$i = $i + 1" >> m.py; i=$((i+1)); done' \
  $DP 1 --plan PLAN_T.md --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1
$DP --mutate last --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && grep -qE "^MUTATION [^ ]+: 10 mutants \(sampled from [0-9]+" "$T/out.txt" && ok "3 --mutate without --max samples 10 mutants" \
  || { bad "3 default max rc=$RC"; grep MUTATION "$T/out.txt"; }
echo "== 3 OUTSIDE CHECKOUT watches what could loosen the rules, not other sessions' files"
R="$T/repo4"; gitrepo "$R"; ( cd "$R" && printf 'x = 1\n' > a.py && printf '.claude/\n' > .gitignore && git add -A && git commit -qm init \
  && printf '# Plan\n## Phase 1 - x\nExecutor: deepseek-flash\nRisk: low\nFiles: a.py\nAcceptance:\n- `grep -q y a.py`\n' > PLAN_T.md ) \
  || { echo "setup failed: repo4"; exit 1; }
approve PLAN_T.md "$R" || exit 1
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
