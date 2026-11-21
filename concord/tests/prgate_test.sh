#!/bin/bash
# The PR gate counts only real reviews of the PR's own diff. (1) A provider refusal is no review: --review-pr and --review
# print PROVIDER LIMIT, exit 9, call the model once and record nothing. (2) A model review is named by the model that ran
# and kept per reviewer and file set. (3) A head is REVIEWED only when every file is covered at its needed tier by a
# review whose reviewer ranks that high, or waived by name by the owner; --pr-status exits 0 only for REVIEWED. (4) A
# BLOCKER, HIGH or clause FAIL stays open until a review of a later head resolves it; a second answer at the same head
# closes nothing. (5) The needed tier of a file comes from the Concord runs that produced it. (6) A phase review does not
# count at the PR gate. (7) A retarget that moves the merge base leaves earlier reviews uncredited. (8) A full review of a
# 4th head of a PR is refused (exit 8) unless --user-approved. (9) Reviews recorded at the same time lose no finding.
# (10) A finding belongs to the PR: a fix on a sibling branch closes nothing, a force-push or a moved merge base keeps it
# open (carried), a finding whose file left the diff is resolved by a review of the other files, and a clause FAIL of one
# file group is neither listed nor resolved by a review of another group.
# No network: fake gh, fake qwen reviewer and executor, a local bare repository as the remote.
# Run: bash ~/.claude/concord/tests/prgate_test.sh   (exit 0 = every check passed)
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/prgate-test.XXXXXX")" && pwd -P)"; export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/concord" "$T/home/.claude"
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
REFUSAL='Error: Free usage limit reached. Subscribe to OpenCode Go to keep going: https://opencode.ai/go'; export REFUSAL
cat > "$T/bin/qwen" <<'Q'
#!/bin/sh
echo ran >> "$T/qwen_calls"
if [ -n "${FAKE_REFUSE:-}" ]; then printf '> build . fake\n%s\n' "$REFUSAL"; exit 1; fi
if [ -n "${FAKE_ACTIONS:-}" ]; then sh -c "$FAKE_ACTIONS"; exit 0; fi
cat "${FAKE_JSON:-$T/clean.txt}"
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
O="$T/origin.git"; C="$T/clone"; RUNS="$C/.git/concord"; NOTES="$T/concord/repo-notes/clone.md"
. "$(dirname "$0")/lib.sh"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
has(){ grep -F -- "$1" "$T/out.txt" > /dev/null; }
calls(){ [ -f "$T/qwen_calls" ] && wc -l < "$T/qwen_calls" | tr -d ' ' || echo 0; }
printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n' > "$T/clean.txt"
finding(){ printf 'REVIEW-JSON\n{"findings": [{"severity": "%s", "path": "%s", "line": 1, "problem": "wrong constant", "fix": "use 2", "repro": {"input": "x", "expected": "2", "actual": "1"}}], "clauses": [], "tests": [], "verdict": "FIX"}\nEND-REVIEW-JSON\n' "$1" "$2" > "$3"; }
finding HIGH a.py "$T/high_a.txt"; finding BLOCKER a.py "$T/block_a.txt"
printf 'REVIEW-JSON\n{"findings": [], "clauses": [{"clause": "Purpose", "status": "FAIL", "note": "does not do what it says"}], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n' > "$T/clause_fail.txt"
printf 'REVIEW-JSON\n{"findings": [{"severity": "MEDIUM", "path": "m.py", "line": 1, "problem": "style", "fix": "rename", "repro": {"input": "x", "expected": "2", "actual": "1"}}], "clauses": [], "tests": [], "verdict": "FIX"}\nEND-REVIEW-JSON\n' > "$T/medium.txt"

git init -q --bare -b main "$O" && git clone -q "$O" "$C" 2> /dev/null || { echo "setup failed: repos"; exit 1; }
( set -e; cd "$C"; git config user.email t@t; git config user.name t
  printf 'readme\n' > README; printf 'c = 1\n' > core.py; printf 'o = 1\n' > old.py; printf 'd = 1\n' > docs.txt; printf 'x = 1\n' > m.py
  printf '.claude/\n' > .gitignore; git add -A; git commit -qm init; git push -q origin main ) \
  || { echo "setup failed: main"; exit 1; }
hd(){ git -C "$O" rev-parse "refs/pull/$1/head"; }
prjson(){ printf '{"baseRefName": "%s", "headRefName": "pr%s", "headRefOid": "%s", "title": "t", "body": "b"}\n' "${2:-main}" "$1" "$(hd "$1")" > "$T/pr$1.json"; }
# newpr N FILE TEXT [FILE TEXT ...]: PR N adds each FILE holding TEXT on top of main (contents unique per PR); pushpr N FILE TEXT: a fix commit on it
newpr(){ local n=$1; shift; ( set -e; cd "$C"; git checkout -q main; git checkout -qb "pr$n"
  while [ $# -ge 2 ]; do printf '%s\n' "$2" > "$1"; shift 2; done
  git add -A; git commit -qm "pr$n"; git push -qf origin "HEAD:refs/pull/$n/head"; git checkout -q main; git branch -qD "pr$n" ) \
  || { echo "setup failed: pr$n"; exit 1; }
  prjson "$n"; }
pushpr(){ ( set -e; cd "$C"; git fetch -q origin "refs/pull/$1/head"; git checkout -q FETCH_HEAD; printf '%s\n' "$3" > "$2"
  git add -A; git commit -qm fix; git push -q origin "HEAD:refs/pull/$1/head"; git checkout -q main ) || { echo "setup failed: push $1"; exit 1; }
  prjson "$1"; }
# runpr N RISK FILES ACTIONS [BRANCH]: a Concord run (fake executor, Risk RISK, plan marker PLAN-MARK-N) of FILES on a branch of the clone,
# committed and pushed as PR N's head; BRANCH (default prN) is the branch the run is recorded on
runpr(){ local n=$1 risk=$2 files=$3 actions=$4 br=${5:-pr$1}
  mkdir -p "$C/.claude"; printf '# Plan\n## Phase 1 - run %s\nExecutor: deepseek-flash\nRisk: %s\nPurpose: PLAN-MARK-%s\nFiles: %s\nAcceptance:\n- `true`\n' "$n" "$risk" "$n" "$files" > "$C/.claude/PLAN_$n.md"
  ( set -e; cd "$C"; git checkout -q main; git checkout -qb "$br" ) || { echo "setup failed: branch $br"; exit 1; }
  approve ".claude/PLAN_$n.md" "$C" || exit 1
  FAKE_ACTIONS="$actions" $DP 1 --plan ".claude/PLAN_$n.md" --via qwen --model fake/m --no-baseline --repo "$C" > "$T/out.txt" 2>&1
  RUNID=$(sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1); [ -n "$RUNID" ] || { echo "setup failed: run for PR $n"; cat "$T/out.txt"; exit 1; }
  ( set -e; cd "$C"; git add -A; git commit -qm "run $n"; git push -qf origin "HEAD:refs/pull/$n/head"; git checkout -q main; git branch -qD "$br" ) || { echo "setup failed: commit $n"; exit 1; }
  prjson "$n"; }
# flash N MODEL [ARGS]: a fake-model PR review
flash(){ local n=$1 m=$2; shift 2; $DP --review-pr "$n" --via qwen --model "$m" "$@" --repo "$C" > "$T/out.txt" 2>&1; }
# opus N TIER NAME ANSWER [ARGS]: an Opus packet at TIER (ARGS: --files, --exclude, --user-approved, --delta), answered with ANSWER, recorded as NAME
opus(){ local n=$1 t=$2 name=$3 ans=$4; shift 4
  $DP --review-pr "$n" --packet --tier "$t" "$@" --repo "$C" > "$T/out.txt" 2>&1
  PK=$(sed -n 's/^PACKET \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
  [ -n "$PK" ] || { echo "    (no packet for PR $n: $(tail -1 "$T/out.txt"))"; return 1; }
  cp "$ans" "$T/ans.txt"; sign "$T/ans.txt" "$PK"
  $DP --review-record "$(basename "$(dirname "$PK")")" --reviewer "$name" --file "$T/ans.txt" --repo "$C" > "$T/rec.txt" 2>&1; }
st(){ $DP --pr-status "$1" --repo "$C" > "$T/out.txt" 2>&1; RC=$?; }

echo "== 1 a provider refusal is no review"
newpr 51 a.py 'a = 51'
C0=$(calls); FAKE_REFUSE=1 flash 51 fake/m --tier medium; RC1=$?; cp "$T/out.txt" "$T/r51.txt"; st 51
[ $RC1 -eq 9 ] && grep -qF "PROVIDER LIMIT" "$T/r51.txt" && [ "$(calls)" = "$((C0+1))" ] && has "0 review(s) recorded" && has "UNREVIEWED" && [ $RC -eq 1 ] \
  && ok "1 --review-pr refused (Free usage limit reached): exit 9, PROVIDER LIMIT, one call, nothing recorded; the head is UNREVIEWED (exit 1)" \
  || { bad "1 refused --review-pr rc=$RC1 status rc=$RC calls=$(( $(calls) - C0 ))"; tail -3 "$T/r51.txt"; tail -2 "$T/out.txt"; }
R="$T/repo"; mkdir -p "$R"
( set -e; cd "$R"; git init -q -b main; git config user.email t@t; git config user.name t
  printf 'x = 1\n' > a.py; printf '.claude/\n' > .gitignore; git add -A; git commit -qm init
  printf '# Plan\n## Phase 1 - x\nExecutor: deepseek-flash\nRisk: low\nFiles: a.py\nAcceptance:\n- `grep -q y a.py`\n' > PLAN_T.md ) \
  || { echo "setup failed: repo"; exit 1; }
approve PLAN_T.md "$R" || exit 1
FAKE_ACTIONS='echo y >> a.py' $DP 1 --plan PLAN_T.md --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1
RID=$(sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
C0=$(calls); FAKE_REFUSE=1 $DP --review "${RID:-none}" --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1; RC=$?
MJ=$(python3 -c "import json,sys; m=json.load(open(sys.argv[1])); print(bool(m.get('review')), len(m.get('reviews') or []))" \
  "$R/.git/concord/${RID:-none}/meta.json" 2>&1)
[ -n "$RID" ] && [ $RC -eq 9 ] && has "PROVIDER LIMIT" && [ "$(calls)" = "$((C0+1))" ] && [ "$MJ" = "False 0" ] \
  && ok "1 --review of a phase run refused: exit 9, PROVIDER LIMIT, one call, no review on the run" \
  || { bad "1 refused --review rc=$RC meta='$MJ' run=$RID"; tail -3 "$T/out.txt"; }
printf 'REVIEW-JSON\n{"findings": [{"severity": "HIGH", "problem": "the needle usage limit exceeded is matched anywhere"\n' > "$T/quote.txt"
newpr 60 a.py 'a = 60'; C0=$(calls); FAKE_JSON="$T/quote.txt" flash 60 fake/m --tier medium; RC=$?
[ $RC -ne 9 ] && ! has "PROVIDER LIMIT" && [ "$(calls)" = "$((C0+2))" ] \
  && ok "1 a malformed answer quoting a refusal phrase is a parse failure (one retry), not a refusal" \
  || { bad "1 quoted refusal rc=$RC calls=$(( $(calls) - C0 ))"; tail -3 "$T/out.txt"; }

echo "== 2 a review is named by its model and kept per reviewer and file set"
newpr 53 a.py 'a = 53'
FAKE_JSON="$T/high_a.txt" flash 53 fake/one --tier medium; FAKE_JSON="$T/clean.txt" flash 53 fake/two --tier medium; st 53
has "FINDINGS OPEN" && [ $RC -eq 1 ] && ok "2 two models at one head, the first with a HIGH: FINDINGS OPEN (not replaced by the second answer, exit 1)" \
  || { bad "2 two models rc=$RC"; tail -3 "$T/out.txt"; }
newpr 54 a.py 'a = 54' b.py 'b = 54'
FAKE_JSON="$T/high_a.txt" flash 54 fake/m --tier medium --files a.py; FAKE_JSON="$T/clean.txt" flash 54 fake/m --tier medium --files b.py; st 54
has "FINDINGS OPEN" && [ $RC -eq 1 ] && ok "2 two --files groups of one model, the first with a HIGH: FINDINGS OPEN" || { bad "2 two groups rc=$RC"; tail -3 "$T/out.txt"; }

echo "== 3 REVIEWED only when every file is covered at its needed tier; exit 0 only then"
newpr 55 a.py 'a = 55' b.py 'b = 55'
opus 55 medium concord:reviewer-opus55 "$T/clean.txt" --files a.py; st 55
has "UNREVIEWED" && has "b.py" && ! has ": REVIEWED" && [ $RC -eq 1 ] && ok "3 a review of a.py alone: UNREVIEWED naming b.py (exit 1)" || { bad "3 half the PR rc=$RC"; tail -3 "$T/out.txt"; }
newpr 57 a.py 'a = 57' b.py 'b = 57'
opus 57 high concord:reviewer-opus55 "$T/clean.txt" --files a.py; flash 57 fake/m --tier high --files b.py; st 57; S1=$(cat "$T/out.txt"); RC1=$RC
opus 57 high concord:reviewer-opus55 "$T/clean.txt" --files b.py; st 57
case "$S1" in *"UNREVIEWED"*"b.py"*) [ $RC1 -eq 1 ] && has "REVIEWED at" && [ $RC -eq 0 ] \
  && ok "3 opus55 on a.py and a flash review of b.py: UNREVIEWED (b.py, exit 1); REVIEWED (exit 0) once opus55 covers b.py" \
  || { bad "3 tier per group, after the second opus55 review rc=$RC1/$RC"; tail -3 "$T/out.txt"; };;
  *) bad "3 tier per group: $(printf '%s' "$S1" | tail -1)";; esac
newpr 63 m.py 'm = 63'
opus 63 medium concord:reviewer-opus55 "$T/clean.txt"; st 63
has "REVIEWED at" && ! has "UNREVIEWED" && [ $RC -eq 0 ] && ok "3 a clean opus55 review of every file: REVIEWED (exit 0)" || { bad "3 reviewed rc=$RC"; tail -3 "$T/out.txt"; }
opus 63 medium concord:reviewer-opus55 "$T/high_a.txt"; st 63
has "FINDINGS OPEN" && [ $RC -eq 1 ] && ok "3 a later answer of the same head with a HIGH: FINDINGS OPEN (exit 1)" || { bad "3 open rc=$RC"; tail -3 "$T/out.txt"; }

echo "== 4 a low-tier PR reaches REVIEWED at low; owner/repo#N uses the remote that names it"
runpr 61 low docs.txt "echo 'd = 61' > docs.txt"
FAKE_JSON="$T/medium.txt" flash 61 fake/m --tier low; RC1=$?; st 61
[ $RC1 -eq 0 ] && has "REVIEWED at low" && [ $RC -eq 0 ] && ok "4 a PR whose run was Risk: low, a flash review at low with only a MEDIUM: REVIEWED at low (the MEDIUM does not hold the gate)" \
  || { bad "4 low PR rc=$RC1/$RC"; tail -3 "$T/out.txt"; }
newpr 64 r.py 'r = 64'
git -C "$C" remote set-url origin https://github.com/other/repo.git && git -C "$C" remote add harness https://github.com/me/kit.git \
  && git -C "$C" config "url.$O.insteadOf" https://github.com/me/kit.git || { echo "setup failed: remotes"; exit 1; }
$DP --review-pr me/kit#64 --via qwen --model fake/m --tier medium --repo "$C" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "PR REVIEW" && ok "4 owner/repo#N fetches from the remote that names it, not origin" || { bad "4 any remote rc=$RC"; tail -3 "$T/out.txt"; }
git -C "$C" remote set-url origin "$O"; git -C "$C" config --unset "url.$O.insteadOf"; git -C "$C" remote remove harness

echo "== 5 a clause marked FAIL is an open finding until a review of a later head resolves it"
newpr 71 a.py 'a = 71'
opus 71 medium concord:reviewer-opus55 "$T/clause_fail.txt"; st 71
has "FINDINGS OPEN" && has "F1" && [ $RC -eq 1 ] && ok "5 a clause FAIL with no finding: FINDINGS OPEN naming F1 (exit 1)" || { bad "5 clause FAIL rc=$RC"; tail -3 "$T/out.txt"; }
opus 71 medium concord:reviewer-opus55 "$T/clean.txt"; st 71
has "FINDINGS OPEN" && [ $RC -eq 1 ] && ok "5 a clean answer at the same head does not close it" || { bad "5 same head rc=$RC"; tail -3 "$T/out.txt"; }
pushpr 71 a.py 'a = 72'
cat > "$T/resolve_f1.txt" <<'EOF'
REVIEW-JSON
{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN", "resolutions": [{"finding": "F1", "fixed": "yes", "evidence": "a.py:1 the constant is 72 now"}]}
END-REVIEW-JSON
EOF
opus 71 medium concord:reviewer-opus55 "$T/resolve_f1.txt"; st 71
has "REVIEWED at" && ! has "FINDINGS OPEN" && [ $RC -eq 0 ] && ok "5 a clean review of the next head that resolves F1 with evidence: REVIEWED (exit 0)" || { bad "5 resolved rc=$RC"; tail -3 "$T/out.txt"; }

echo "== 6 a CLEAN recorded after a BLOCK at the same head leaves the finding open"
newpr 72 a.py 'a = 721'
opus 72 medium concord:reviewer-opus55 "$T/block_a.txt"; st 72
has "FINDINGS OPEN" || { bad "6 setup: the BLOCK is not open"; cat "$T/out.txt"; }
opus 72 medium concord:reviewer-opus55 "$T/clean.txt"; st 72
has "FINDINGS OPEN" && has "F1" && [ $RC -eq 1 ] && ok "6 the same reviewer's CLEAN at the same head: F1 stays open (exit 1)" || { bad "6 clean after block rc=$RC"; tail -3 "$T/out.txt"; }

echo "== 7 --exclude is a waiver only when the owner's words name each excluded file"
printf '# clone: binding facts\n- Risk floor high: release.py\n' > "$NOTES"
newpr 73 parser.py 'p = 73' release.py 'r = 73'
opus 73 high concord:reviewer-opus55 "$T/clean.txt" --exclude parser.py; st 73
has "UNREVIEWED" && has "parser.py" && ! has "WAIVER" && [ $RC -eq 1 ] && ok "7 --exclude parser.py without the owner's words: UNREVIEWED naming parser.py (exit 1)" || { bad "7 exclude rc=$RC"; tail -3 "$T/out.txt"; }
opus 73 high concord:reviewer-opus55 "$T/clean.txt" --exclude parser.py --user-approved "go ahead"; st 73
has "UNREVIEWED" && has "parser.py" && ! has "WITH OWNER WAIVER" && [ $RC -eq 1 ] && ok "7 words that do not name parser.py waive nothing" || { bad "7 vague words rc=$RC"; tail -3 "$T/out.txt"; }
opus 73 high concord:reviewer-opus55 "$T/clean.txt" --exclude parser.py --user-approved "skip parser.py, the owner said so"; st 73
has "WITH OWNER WAIVER: parser.py excluded" && has "REVIEWED at" && [ $RC -eq 0 ] && ok "7 words naming parser.py: REVIEWED ... WITH OWNER WAIVER: parser.py excluded (exit 0)" || { bad "7 waiver rc=$RC"; tail -3 "$T/out.txt"; }
newpr 74 parser.py 'p = 74' release.py 'r = 74'
opus 74 high concord:reviewer-opus55 "$T/clean.txt" --files parser.py; FAKE_JSON="$T/clean.txt" flash 74 fake/m --tier high --files release.py --user-approved "release.py is fine"; st 74
has "UNREVIEWED" && has "release.py" && ! has "WITH OWNER WAIVER" && [ $RC -eq 1 ] \
  && ok "7 a flash review of release.py in a PR that needs high there, with the owner's words: not credited above its rank" || { bad "7 cheap review rc=$RC"; tail -3 "$T/out.txt"; }
newpr 75 a.py 'a = 75' b.py 'b = 75'
opus 75 medium concord:reviewer-opus55 "$T/clean.txt" --exclude a.py --user-approved "skip data.py"; st 75
has "UNREVIEWED" && has "a.py" && ! has "WAIVER" && [ $RC -eq 1 ] \
  && ok "7 words that only contain a.py inside another name (skip data.py) waive nothing: UNREVIEWED naming a.py" || { bad "7 substring waiver rc=$RC"; tail -4 "$T/out.txt"; }
rm -f "$NOTES"

echo "== 8 needed tiers come from the Concord runs that produced the PR"
runpr 90 high 'core.py, new.py, old.py' "echo 'c = 2' > core.py; echo 'n = 1' > new.py; rm old.py"; RUN90=$RUNID
for f in core.py new.py old.py; do
  $DP --review-pr 90 --packet --tier medium --files "$f" --repo "$C" > "$T/out.txt" 2>&1; RC=$?
  [ $RC -ne 0 ] && ! grep -q '^PACKET' "$T/out.txt" && ok "8 --tier medium for $f (a path a Risk: high run changed, created or deleted) is refused" || { bad "8 medium tier for $f rc=$RC"; tail -2 "$T/out.txt"; }
done
$DP --review-pr 90 --packet --repo "$C" > "$T/out.txt" 2>&1; PK=$(sed -n 's/^PACKET \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
[ -f "$PK" ] && grep -qF "PLAN-MARK-90" "$PK" && ! grep -qF "No Concord run produced this PR" "$PK" \
  && ok "8 without --tier a review runs at the highest needed tier; the packet holds the run's plan snapshot" || { bad "8 packet with a run '$PK'"; tail -2 "$T/out.txt"; }
# the base branch moves and is merged into the PR (GitHub's Update branch): the merge base passes the run's start
( set -e; cd "$C"; git checkout -q main; printf 'readme 2\n' > README; git commit -qam "main moves"; git push -q origin main
  git fetch -q origin refs/pull/90/head; git checkout -q FETCH_HEAD; git merge -q --no-edit main; git push -q origin HEAD:refs/pull/90/head
  git checkout -q main ) || { echo "setup failed: base merge into PR 90"; exit 1; }
prjson 90
$DP --review-pr 90 --packet --tier medium --files core.py --repo "$C" > "$T/out.txt" 2>&1; RC=$?
[ $RC -ne 0 ] && ! grep -q '^PACKET' "$T/out.txt" && ok "8 after the base branch is merged into the PR, core.py still needs high: --tier medium is refused" || { bad "8 a base merge dropped the Risk: high run rc=$RC"; tail -2 "$T/out.txt"; }
runpr 93 high core.py "echo 'c = 93' > core.py" side93
$DP --review-pr 93 --packet --tier low --repo "$C" > "$T/out.txt" 2>&1; RC=$?
[ $RC -ne 0 ] && ! grep -q '^PACKET' "$T/out.txt" && ok "8 a run recorded on another branch is not attributed: the PR needs medium, --tier low is refused" || { bad "8 other-branch run rc=$RC"; tail -2 "$T/out.txt"; }
$DP --review-pr 93 --packet --tier medium --repo "$C" > "$T/out.txt" 2>&1; PK=$(sed -n 's/^PACKET \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
[ -f "$PK" ] && grep -qF "No Concord run produced this PR; no plan clauses apply" "$PK" && ! grep -qF "PLAN-MARK-93" "$PK" \
  && ok "8 a PR with no attributable run: --tier medium runs and its packet says no Concord run produced it" || { bad "8 no-run packet '$PK'"; tail -2 "$T/out.txt"; }

# a run made in a fork of the PR's worktree is the PR's run: it records the fork's origin branch and HEAD
WT="python3 $T/concord/wt.py"
$WT new T94 --no-fetch --branch pr94 --repo "$C" > "$T/new94.txt" 2>&1 || { echo "setup failed: wt new"; cat "$T/new94.txt"; exit 1; }
W94="$C/.claude/worktrees/T94"
printf '# Plan\n## Phase 1 - run 94\nExecutor: deepseek-flash\nRisk: high\nPurpose: PLAN-MARK-94\nFiles: core.py\nAcceptance:\n- `true`\n' > "$W94/PLAN_T94.md"
approve PLAN_T94.md "$W94" || exit 1
$WT fork T94 1 --repo "$W94" > "$T/fork94.txt" 2>&1 || { echo "setup failed: wt fork"; cat "$T/fork94.txt"; exit 1; }
FAKE_ACTIONS="echo 'c = 94' > core.py" $DP 1 --plan PLAN_T94.md --via qwen --model fake/m --no-baseline --repo "$C/.claude/worktrees/T94-p1" > "$T/out.txt" 2>&1
RUN94=$(sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1); [ -n "$RUN94" ] || { echo "setup failed: fork run"; cat "$T/out.txt"; exit 1; }
$WT join T94 1 --repo "$W94" > "$T/join94.txt" 2>&1 || { echo "setup failed: wt join"; cat "$T/join94.txt"; exit 1; }
( set -e; cd "$W94"; git add core.py; git commit -qm "phase 1"; git push -q origin "HEAD:refs/pull/94/head" ) || { echo "setup failed: push 94"; exit 1; }
prjson 94
$DP --review-pr 94 --packet --tier medium --repo "$W94" > "$T/out.txt" 2>&1; RC=$?
[ $RC -ne 0 ] && ! grep -q '^PACKET' "$T/out.txt" && ok "8 a Risk: high run made in a fork counts: --tier medium for its file is refused (needs high)" || { bad "8 fork run not attributed rc=$RC"; tail -2 "$T/out.txt"; }
$DP --review-pr 94 --packet --repo "$W94" > "$T/out.txt" 2>&1; PK=$(sed -n 's/^PACKET \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
[ -f "$PK" ] && grep -qF "PLAN-MARK-94" "$PK" && ! grep -qF "No Concord run produced this PR" "$PK" \
  && ok "8 the fork run's plan snapshot is in the PR packet" || { bad "8 fork run packet '$PK'"; tail -2 "$T/out.txt"; }

newpr 95 p95.py "p = 95"
$DP --review-pr 94 --packet --user-approved "owner words for PR 94" --repo "$W94" > "$T/out.txt" 2>&1
$DP --review-pr 95 --packet --tier medium --user-approved "owner words for PR 95" --repo "$C" > "$T/out.txt" 2>&1
$DP --verdict "$RUN94" PASS --repo "$W94" > "$T/v94.txt" 2>&1 || { echo "setup failed: --verdict $RUN94 (a run with no verdict blocks --report)"; cat "$T/v94.txt"; exit 1; }
$DP --report --plan PLAN_T94.md --repo "$W94" > "$T/rep94.txt" 2>&1; REP94=$(sed -n 's/^report: //p' "$T/rep94.txt" | head -1); [ -f "$REP94" ] || REP94="$T/none"
OV94=$(sed -n '/^## Overrides/,/^## Phases/p' "$REP94" 2>/dev/null)
case "$OV94" in *"owner words for PR 94"*) IN=1;; *) IN=0;; esac; case "$OV94" in *"owner words for PR 95"*) OUT=1;; *) OUT=0;; esac
[ $IN -eq 1 ] && [ $OUT -eq 0 ] && ok "8 the report's Overrides lists the approved PR review of a PR the plan's run produced, and not one of an unrelated PR" || { bad "8 report overrides: PR 94 listed=$IN PR 95 listed=$OUT"; printf '%s\n' "$OV94"; }

echo "== 9 a phase review does not count at the PR gate"
runpr 97 medium m.py "echo 'm = 97' > m.py"; RUN97=$RUNID
git -C "$C" fetch -q origin refs/pull/97/head && git -C "$C" checkout -q FETCH_HEAD     # a phase review stores the blobs of the working tree it is recorded in
record "$RUN97" concord:reviewer-opus55 "$T/clean.txt" "$C" > "$T/out.txt" 2>&1 || { echo "setup failed: phase review"; cat "$T/out.txt"; exit 1; }
git -C "$C" checkout -q main
C0=$(calls); flash 97 fake/m --tier medium; FL=$(cat "$T/out.txt"); st 97
case "$FL" in *COVERED*) bad "9 the phase review's coverage was reused: $(printf '%s' "$FL" | grep COVERED | head -1)";;
  *) [ "$(calls)" = "$((C0+1))" ] && has "UNREVIEWED" && [ $RC -eq 1 ] \
     && ok "9 a clean phase review of the run that made the PR covers nothing: the PR review runs the model, the head is UNREVIEWED (exit 1)" \
     || bad "9 phase review alone rc=$RC calls $C0 -> $(calls)";; esac
opus 97 medium concord:reviewer-opus55 "$T/clean.txt"; st 97
has "REVIEWED at" && ! has "UNREVIEWED" && [ $RC -eq 0 ] && ok "9 a qualified PR review then covers it: REVIEWED (exit 0)" || { bad "9 pr review rc=$RC"; tail -3 "$T/out.txt"; }

echo "== 10 a retarget that moves the merge base leaves earlier reviews uncredited"
( set -e; cd "$C"; git checkout -q main; git checkout -qb pr98; printf 's = 1\n' > s98.py; git add -A; git commit -qm c1; git push -q origin HEAD:refs/heads/feat98
  printf 't = 1\n' > t98.py; git add -A; git commit -qm c2; git push -qf origin HEAD:refs/pull/98/head; git checkout -q main; git branch -qD pr98 ) || { echo "setup failed: pr98"; exit 1; }
prjson 98 main
opus 98 medium concord:reviewer-opus55 "$T/clean.txt"; st 98
has "REVIEWED at" && ! has "UNREVIEWED" && [ $RC -eq 0 ] || { bad "10 setup: PR 98 not reviewed rc=$RC"; cat "$T/out.txt"; }
prjson 98 feat98; st 98
has "UNREVIEWED" && [ $RC -eq 1 ] && ok "10 the same head retargeted to feat98 (a new merge base): the earlier review is uncredited, UNREVIEWED (exit 1)" || { bad "10 retarget rc=$RC"; tail -3 "$T/out.txt"; }

echo "== 11 at most three full review rounds (heads) per PR"
for v in 1 2 3; do newpr 62 a.py "a = 62$v"; opus 62 medium concord:reviewer-opus55 "$T/clean.txt" || { bad "11 round $v"; break; }; done
newpr 62 a.py 'a = 624'
$DP --review-pr 62 --packet --tier medium --repo "$C" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 8 ] && has "REFUSED: PR 62 already had 3 full review rounds" && ! grep -q "^PACKET" "$T/out.txt" \
  && ok "11 a 4th head's full review is refused (exit 8), no packet" || { bad "11 cap rc=$RC"; tail -3 "$T/out.txt"; }
$DP --review-pr 62 --packet --tier medium --user-approved "  " --repo "$C" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 8 ] && ! grep -q "^PACKET" "$T/out.txt" && ok "11 a whitespace-only --user-approved does not lift the cap (exit 8)" || { bad "11 blank approval rc=$RC"; tail -3 "$T/out.txt"; }
$DP --review-pr 62 --packet --tier medium --user-approved "one more" --repo "$C" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && grep -q "^PACKET" "$T/out.txt" && ok "11 --user-approved lifts the cap" || { bad "11 approved rc=$RC"; tail -3 "$T/out.txt"; }

# mfinding SEV PATH MARK OUT: an answer with one finding of SEV on PATH whose problem text and reproduction hold MARK
mfinding(){ printf 'REVIEW-JSON\n{"findings": [{"severity": "%s", "path": "%s", "line": 1, "problem": "%s-problem", "fix": "use 2", "repro": {"input": "%s-in", "expected": "%s-exp", "actual": "%s-act"}}], "clauses": [], "tests": [], "verdict": "FIX"}\nEND-REVIEW-JSON\n' "$1" "$2" "$3" "$3" "$3" "$3" > "$4"; }
# resolves FINDING EVIDENCE OUT: a CLEAN answer that resolves FINDING (yes) with EVIDENCE
resolves(){ printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN", "resolutions": [{"finding": "%s", "fixed": "yes", "evidence": "%s"}]}\nEND-REVIEW-JSON\n' "$1" "$2" > "$3"; }
# forkpr N SHA FILE TEXT: a new commit on top of SHA (a commit of the clone), pushed as PR N's head in place of the old head
forkpr(){ ( set -e; cd "$C"; git checkout -q --detach "$2"; printf '%s\n' "$4" > "$3"; git add -A; git commit -qm "fork $1"
  git push -qf origin "HEAD:refs/pull/$1/head"; git checkout -q main ) || { echo "setup failed: forkpr $1"; exit 1; }
  prjson "$1"; }

echo "== 12 reviews of one PR head recorded at the same time lose no finding"
for N in 110 111 112; do
  ARGS=(); for i in 1 2 3 4 5 6 7 8; do ARGS+=("s$N$i.py" "s = $N$i"); done
  newpr "$N" "${ARGS[@]}"
  SETUP=1
  for i in 1 2 3 4 5 6 7 8; do
    $DP --review-pr "$N" --packet --tier medium --files "s$N$i.py" --repo "$C" > "$T/pk$i.txt" 2>&1
    PKI=$(sed -n 's/^PACKET \([^ ]*\).*/\1/p' "$T/pk$i.txt" | head -1); [ -n "$PKI" ] || { SETUP=0; break; }
    if [ $((i % 2)) -eq 1 ]; then finding HIGH "s$N$i.py" "$T/par$i.txt"; else cp "$T/clean.txt" "$T/par$i.txt"; fi
    sign "$T/par$i.txt" "$PKI"; eval "RUN$i=$(basename "$(dirname "$PKI")")"; rm -f "$T/parrc$i"
  done
  [ $SETUP -eq 1 ] || { bad "12 setup: a packet of PR $N was not written"; tail -2 "$T/pk$i.txt"; continue; }
  for i in 1 2 3 4 5 6 7 8; do eval "RID=\$RUN$i"
    ( $DP --review-record "$RID" --reviewer concord:reviewer-opus55 --file "$T/par$i.txt" --repo "$C" > "$T/parrec$i.txt" 2>&1; echo $? > "$T/parrc$i" ) &
  done
  wait
  RECS=0; for i in 1 2 3 4 5 6 7 8; do [ "$(cat "$T/parrc$i" 2>/dev/null)" = 0 ] && RECS=$((RECS+1)); done
  st "$N"
  HI=$(grep -c '\[HIGH\]' "$T/out.txt"); IDS=$(grep -o '^  F[0-9]* \[HIGH\]' "$T/out.txt" | sort -u | wc -l | tr -d ' ')
  PATHS=0; for i in 1 3 5 7; do grep -qF "s$N$i.py:L1" "$T/out.txt" && PATHS=$((PATHS+1)); done
  [ $RECS -eq 8 ] || { bad "12 setup: $RECS of 8 records of PR $N succeeded"; tail -2 "$T/parrec1.txt"; continue; }
  has "8 review(s) recorded" && has "FINDINGS OPEN" && [ $RC -eq 1 ] && [ "$HI" = 4 ] && [ "$IDS" = 4 ] && [ $PATHS -eq 4 ] \
    && ok "12 eight --files groups of PR $N recorded at once (four with a HIGH, four CLEAN): every HIGH is open under its own id and all 8 reviews are listed" \
    || { bad "12 lost update in PR $N: HIGH lines $HI, distinct ids $IDS, HIGH files named $PATHS of 4, status rc=$RC"; head -3 "$T/out.txt"; }
done

echo "== 12 (phase run) reviews of one phase run recorded at the same time keep every entry; a verdict recorded while a review is in flight survives it"
runpr 120 medium "core.py" "echo 'c = 2' > core.py"; PRUN=$RUNID
PSETUP=1
for i in 1 2 3 4; do
  $DP --review "$PRUN" --packet --repo "$C" > "$T/ppk$i.txt" 2>&1
  PKI=$(sed -n 's/^PACKET \([^ ]*\).*/\1/p' "$T/ppk$i.txt" | head -1); [ -n "$PKI" ] || { PSETUP=0; break; }
  finding HIGH core.py "$T/pans$i.txt"; sed -i.bak "s/wrong constant/phase finding $i/" "$T/pans$i.txt"; sign "$T/pans$i.txt" "$PKI"; rm -f "$T/pans$i.txt.bak" "$T/pprc$i"
done
if [ $PSETUP -eq 1 ]; then
  for i in 1 2 3 4; do
    ( $DP --review-record "$PRUN" --reviewer "rev$i" --file "$T/pans$i.txt" --repo "$C" > "$T/prec$i.txt" 2>&1; echo $? > "$T/pprc$i" ) &
  done
  wait
  PRECS=0; for i in 1 2 3 4; do [ "$(cat "$T/pprc$i" 2>/dev/null)" = 0 ] && PRECS=$((PRECS+1)); done
  PMETA=$(python3 -I -B -c 'import json,sys; m=json.load(open(sys.argv[1])); print(len(m.get("reviews") or []), len({r["reviewer"] for r in m.get("reviews") or []}))' "$RUNS/$PRUN/meta.json")
  PLED=$(python3 -I -B -c 'import json,glob,sys; print(sum(len(json.load(open(f))["findings"]) for f in glob.glob(sys.argv[1]+"/ledger/PLAN_120*.json")))' "$RUNS")
  [ $PRECS -eq 4 ] || bad "12 phase setup: $PRECS of 4 records succeeded ($(tail -1 "$T/prec1.txt"))"
  [ $PRECS -eq 4 ] && { [ "$PMETA" = "4 4" ] && [ "$PLED" = 4 ] \
    && ok "12 four --review-record calls of one phase run at once: all 4 review entries are in meta.json and all 4 findings in the ledger" \
    || bad "12 phase lost update: meta.json holds '$PMETA' (entries, reviewers) of 4 4, ledger findings $PLED of 4"; }
else bad "12 phase setup: a packet of the phase run was not written ($(tail -1 "$T/ppk$i.txt"))"; fi
# a cheap --review is in flight while the planner records an Opus answer and the verdict of the same run
runpr 121 medium "core.py" "echo 'c = 3' > core.py"; VRUN=$RUNID
$DP --review "$VRUN" --packet --repo "$C" > "$T/vpk.txt" 2>&1; VPK=$(sed -n 's/^PACKET \([^ ]*\).*/\1/p' "$T/vpk.txt" | head -1)
if [ -n "$VPK" ]; then
  finding HIGH core.py "$T/vans.txt"; sign "$T/vans.txt" "$VPK"
  ( FAKE_ACTIONS="sleep 5; cat $T/clean.txt" $DP --review "$VRUN" --via qwen --model fake/m --repo "$C" > "$T/vcheap.txt" 2>&1; echo $? > "$T/vcheaprc" ) &
  sleep 2
  $DP --review-record "$VRUN" --reviewer concord:reviewer-opus55 --file "$T/vans.txt" --repo "$C" > "$T/vrec.txt" 2>&1; VREC=$?
  $DP --verdict "$VRUN" FAIL --cause EXECUTOR --note "opus found a HIGH" --repo "$C" > "$T/vver.txt" 2>&1; VVER=$?
  wait
  VMETA=$(python3 -I -B -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m.get("verdict"), m.get("cause"), len(m.get("reviews") or []))' "$RUNS/$VRUN/meta.json")
  [ $VREC -eq 0 ] && [ $VVER -eq 0 ] && [ "$(cat "$T/vcheaprc" 2>/dev/null)" = 0 ] || bad "12 verdict setup: record rc $VREC, verdict rc $VVER, cheap review rc $(cat "$T/vcheaprc" 2>/dev/null)"
  [ $VREC -eq 0 ] && [ $VVER -eq 0 ] && { [ "$VMETA" = "FAIL EXECUTOR 2" ] \
    && ok "12 a verdict and an Opus record made while a cheap review of the run is in flight survive its end (FAIL, EXECUTOR, both reviews)" \
    || bad "12 the cheap review's late write erased what was recorded during it: verdict/cause/reviews '$VMETA' of 'FAIL EXECUTOR 2'"; }
else bad "12 verdict setup: no packet ($(tail -1 "$T/vpk.txt"))"; fi

echo "== 13 a fix on a sibling branch closes nothing"
newpr 113 a.py 'a = 1131'; A113=$(hd 113)
opus 113 medium concord:reviewer-opus55 "$T/high_a.txt"; st 113
has "FINDINGS OPEN" && has "F1" || { bad "13 setup: the HIGH is not open at the first head"; cat "$T/out.txt"; }
pushpr 113 a.py 'a = 1132'; B113=$(hd 113)
resolves F1 "a.py:1 the constant is 1132 now" "$T/resolve13.txt"
opus 113 medium concord:reviewer-opus55 "$T/resolve13.txt"; st 113
has "REVIEWED at" && [ $RC -eq 0 ] || { bad "13 setup: the child head B did not resolve F1 (rc=$RC)"; cat "$T/out.txt"; }
forkpr 113 "$A113" c.py 'c = 1133'; st 113
has "FINDINGS OPEN" && has "F1" && [ $RC -eq 1 ] \
  && ok "13 F1 opened at A and resolved by a review of its child B: at a sibling head C (child of A, without B) F1 is open (exit 1)" \
  || { bad "13 sibling head C: F1 not open, rc=$RC"; head -3 "$T/out.txt"; }
# the report of the ticket judges F1 at the PR's current head C too, the way the status does (F1 was resolved at B, a sibling of C)
mkdir -p "$C/.claude"; printf '# Plan\nTier: S\n## Phase 1 - x\nExecutor: planner\nFiles: core.py\nAcceptance:\n- `true`\n' > "$C/.claude/PLAN_R13.md"
approve .claude/PLAN_R13.md "$C" || exit 1
$DP --begin 1 --label planner --plan .claude/PLAN_R13.md --repo "$C" > "$T/b13.txt" 2>&1; BID13=$(sed -n 's/^BEGIN \(.*\)$/\1/p' "$T/b13.txt")
{ [ -n "$BID13" ] && $DP --end "$BID13" --repo "$C" > /dev/null 2>&1 && $DP --verdict "$BID13" PASS --repo "$C" > /dev/null 2>&1; } || { echo "setup failed: a closed planner run for the report"; cat "$T/b13.txt"; exit 1; }
git -C "$C" checkout -q --detach "$(hd 113)" && $DP --report --plan .claude/PLAN_R13.md --repo "$C" > "$T/rep13.txt" 2>&1; REP13=$(sed -n 's/^report: //p' "$T/rep13.txt" | head -1); git -C "$C" checkout -q main
[ -f "$REP13" ] || { echo "setup failed: --report wrote no file"; cat "$T/rep13.txt"; exit 1; }
OUT13=$(sed -n '/^## Finding outcomes/,/^## Time/p' "$REP13")
case "$OUT13" in *"PR 113 F1"*"still open"*) ROPEN=1;; *) ROPEN=0;; esac; case "$OUT13" in *"PR 113 F1"*"closed in"*) RCLOSED=1;; *) RCLOSED=0;; esac
[ $ROPEN -eq 1 ] && [ $RCLOSED -eq 0 ] && grep -q "F1 HIGH" "$REP13" \
  && ok "13 the report judges F1 at the PR's current head C like the status: still open, listed under the open items (not closed by the review of B)" \
  || { bad "13 report disagrees with the status at C: outcome says open=$ROPEN closed=$RCLOSED"; printf '%s\n' "$OUT13"; }
forkpr 113 "$B113" d.py 'd = 1134'; st 113; NOPEN=$(grep -c 'FINDINGS OPEN' "$T/out.txt")
opus 113 medium concord:reviewer-opus55 "$T/clean.txt"; st 113
[ "$NOPEN" = 0 ] && has "REVIEWED at" && ! has "FINDINGS OPEN" && [ $RC -eq 0 ] \
  && ok "13 at a descendant D of B F1 is resolved: not open before a review, REVIEWED (exit 0) after a clean review of D" \
  || { bad "13 descendant of B: open lines before review $NOPEN, rc=$RC"; head -3 "$T/out.txt"; }

echo "== 14 a finding belongs to the PR: it survives a force-push, a moved merge base and a file leaving the diff"
newpr 114 a.py 'a = 1141'; A114=$(hd 114); MB114=$(git -C "$C" merge-base main "$A114")
mfinding HIGH a.py M114 "$T/high114.txt"
opus 114 medium concord:reviewer-opus55 "$T/high114.txt"; st 114
has "FINDINGS OPEN" && has "F1" || { bad "14 setup: the HIGH is not open at the first head"; cat "$T/out.txt"; }
forkpr 114 main a.py 'a = 1142'                    # a head that does not descend from A114: a force-push
git -C "$C" merge-base --is-ancestor "$A114" "$(hd 114)" && { echo "setup failed: the force-pushed head descends from A"; exit 1; }
st 114
has "FINDINGS OPEN" && has "F1" && grep -qi "carried" "$T/out.txt" && [ $RC -eq 1 ] \
  && ok "14 after a force-push F1 stays open and the status names it as carried (exit 1)" \
  || { bad "14 force-push: F1 not open and carried, rc=$RC"; head -3 "$T/out.txt"; }
opus 114 medium concord:reviewer-opus55 "$T/clean.txt"; PK114=$PK
{ grep -qF "M114-problem" "$PK114" && grep -qF "M114-in" "$PK114" && grep -qF "M114-act" "$PK114" && grep -qF "${A114:0:8}" "$PK114" && grep -qF "${MB114:0:8}" "$PK114"; } \
  && ok "14 the next packet shows the carried finding with its reproduction, its head and its merge base" \
  || { bad "14 packet of the new head does not show the carried F1 (problem, reproduction, head, merge base)"; grep -c . "$PK114"; }
st 114
has "FINDINGS OPEN" && has "F1" && [ $RC -eq 1 ] \
  && ok "14 a clean review of the new head that does not resolve F1 leaves it open" || { bad "14 clean review of the new head closed F1, rc=$RC"; head -3 "$T/out.txt"; }
resolves F1 "a.py:1 the constant is 1142 now" "$T/resolve14.txt"
opus 114 medium concord:reviewer-opus55 "$T/resolve14.txt"; st 114
has "REVIEWED at" && ! has "FINDINGS OPEN" && [ $RC -eq 0 ] \
  && ok "14 a review of the new head that resolves F1 with evidence: REVIEWED (exit 0)" || { bad "14 resolved at the new head rc=$RC"; head -3 "$T/out.txt"; }

( set -e; cd "$C"; git checkout -q main; git checkout -qb pr115; printf 's = 1\n' > s115.py; git add -A; git commit -qm c1; git push -q origin HEAD:refs/heads/feat115
  printf 't = 1\n' > t115.py; git add -A; git commit -qm c2; git push -qf origin HEAD:refs/pull/115/head; git checkout -q main; git branch -qD pr115 ) || { echo "setup failed: pr115"; exit 1; }
prjson 115 main; mfinding HIGH t115.py M115 "$T/high115.txt"
opus 115 medium concord:reviewer-opus55 "$T/high115.txt"; st 115
has "FINDINGS OPEN" && has "F1" || { bad "14 setup: the HIGH of PR 115 is not open"; cat "$T/out.txt"; }
prjson 115 feat115; st 115
has "FINDINGS OPEN" && has "F1" && has "t115.py: needs medium" && [ $RC -eq 1 ] \
  && ok "14 the same head retargeted to feat115 (a new merge base): coverage resets (t115.py needs medium) and the unresolved F1 stays open (exit 1)" \
  || { bad "14 retarget: F1 not open with coverage reset, rc=$RC"; head -4 "$T/out.txt"; }

newpr 116 a.py 'a = 1161' b.py 'b = 1161'
mfinding HIGH a.py M116 "$T/high116.txt"
opus 116 medium concord:reviewer-opus55 "$T/high116.txt" --files a.py; st 116
has "FINDINGS OPEN" && has "F1" || { bad "14 setup: the HIGH of PR 116 is not open"; cat "$T/out.txt"; }
( set -e; cd "$C"; git fetch -q origin refs/pull/116/head; git checkout -q FETCH_HEAD; git rm -q a.py; git commit -qm "drop a.py"
  git push -q origin HEAD:refs/pull/116/head; git checkout -q main ) || { echo "setup failed: drop a.py"; exit 1; }
prjson 116; st 116
has "FINDINGS OPEN" && has "F1" && ! has "a.py: " || { bad "14 setup: a.py is still in the PR diff or F1 is not open"; cat "$T/out.txt"; }
resolves F1 "a.py is no longer changed by the PR" "$T/resolve16.txt"
opus 116 medium concord:reviewer-opus55 "$T/resolve16.txt" --files b.py; PK116=$PK
[ -n "$PK116" ] && grep -qF "M116-problem" "$PK116" \
  && ok "14 F1 of a.py, which left the diff, is listed in the packet of the b.py group" || { bad "14 packet of b.py does not list the finding whose file left the diff"; }
st 116
has "REVIEWED at" && ! has "FINDINGS OPEN" && [ $RC -eq 0 ] \
  && ok "14 the b.py review's yes resolves F1: REVIEWED (exit 0)" || { bad "14 yes from the b.py review did not resolve F1, rc=$RC"; head -3 "$T/out.txt"; }

echo "== 15 a clause FAIL belongs to the files of the review that recorded it"
newpr 117 parser.py 'p = 1171' guide.md 'g = 1171'
printf 'REVIEW-JSON\n{"findings": [], "clauses": [{"clause": "Purpose", "status": "FAIL", "note": "CLAUSE-MARK-40"}], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n' > "$T/clause40.txt"
opus 117 medium concord:reviewer-opus55 "$T/clause40.txt" --files parser.py; st 117
has "FINDINGS OPEN" && has "F1" || { bad "15 setup: the clause FAIL of the parser.py review is not open"; cat "$T/out.txt"; }
pushpr 117 parser.py 'p = 1172'
resolves F1 "parser.py:1 the purpose holds now" "$T/resolve40.txt"
opus 117 medium concord:reviewer-opus55 "$T/resolve40.txt" --files guide.md; PKG=$PK
[ -n "$PKG" ] && ! grep -qF "CLAUSE-MARK-40" "$PKG" \
  && ok "15 a clause FAIL recorded by the parser.py review is not listed in the guide.md packet" || { bad "15 the guide.md packet lists the parser.py clause FAIL"; }
st 117
has "FINDINGS OPEN" && has "F1" && [ $RC -eq 1 ] \
  && ok "15 a yes for it from the guide.md review records nothing: F1 stays open (exit 1)" || { bad "15 the guide.md review's yes closed the parser.py clause FAIL, rc=$RC"; head -3 "$T/out.txt"; }
newpr 118 parser.py 'p = 1181'
opus 118 medium concord:reviewer-opus55 "$T/clause40.txt" --files parser.py; st 118
has "FINDINGS OPEN" && has "F1" || { bad "15 setup: the clause FAIL of PR 118 is not open"; cat "$T/out.txt"; }
pushpr 118 parser.py 'p = 1182'
opus 118 medium concord:reviewer-opus55 "$T/resolve40.txt" --files parser.py; PKP=$PK
st 118
[ -n "$PKP" ] && grep -qF "CLAUSE-MARK-40" "$PKP" && has "REVIEWED at" && ! has "FINDINGS OPEN" && [ $RC -eq 0 ] \
  && ok "15 a later review whose files hold parser.py lists the clause FAIL and its yes resolves it: REVIEWED (exit 0)" || { bad "15 the parser.py group did not list and resolve the clause FAIL, rc=$RC"; head -3 "$T/out.txt"; }

echo; echo "passed $pass, failed $fail"; [ $fail -eq 0 ]
