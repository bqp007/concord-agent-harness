#!/bin/bash
# The PR gate counts only real reviews (2026-10-23, concord-diffusion). (1) A provider refusal is no review:
# --review-pr and --review print PROVIDER LIMIT, exit 9, call the model once and record nothing; an UNPARSED entry
# recorded before the fix with a refusal in its run's log is not counted. (2) A model review is named by the model
# that ran and kept per reviewer and file set, so two models or two --files groups at one head both count. (3) A
# head is REVIEWED at tier T only when reviews crediting at least T cover every PR file (--exclude'd files listed).
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
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
has(){ grep -F -- "$1" "$T/out.txt" > /dev/null; }
calls(){ [ -f "$T/qwen_calls" ] && wc -l < "$T/qwen_calls" | tr -d ' ' || echo 0; }
printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n' > "$T/clean.txt"
printf 'REVIEW-JSON\n{"findings": [{"severity": "HIGH", "path": "a.py", "line": 1, "problem": "wrong constant", "fix": "use 2", "repro": {"input": "x", "expected": "2", "actual": "1"}}], "clauses": [], "tests": [], "verdict": "FIX"}\nEND-REVIEW-JSON\n' > "$T/high_a.txt"

O="$T/origin.git"; C="$T/clone"; RUNS="$C/.git/concord"
git init -q --bare -b main "$O" && git clone -q "$O" "$C" 2> /dev/null || { echo "setup failed: repos"; exit 1; }
( set -e; cd "$C"; git config user.email t@t; git config user.name t
  printf 'readme\n' > README; printf '.claude/\n' > .gitignore; git add -A; git commit -qm init; git push -q origin main ) \
  || { echo "setup failed: main"; exit 1; }
hd(){ git -C "$O" rev-parse "refs/pull/$1/head"; }
# newpr N FILE TEXT [FILE TEXT ...]: PR N adds each FILE holding TEXT on top of main (contents unique per PR, so no
# review of another PR covers them)
newpr(){ local n=$1; shift; ( set -e; cd "$C"; git checkout -q main; git checkout -qb "pr$n"
  while [ $# -ge 2 ]; do printf '%s\n' "$2" > "$1"; shift 2; done
  git add -A; git commit -qm "pr$n"; git push -qf origin "HEAD:refs/pull/$n/head"; git checkout -q main; git branch -qD "pr$n" ) \
  || { echo "setup failed: pr$n"; exit 1; }
  printf '{"baseRefName": "main", "headRefOid": "%s", "title": "t", "body": "b"}\n' "$(hd "$n")" > "$T/pr$n.json"; }
# flash N MODEL [ARGS]: a fake-model PR review; opus N TIER NAME [ARGS]: an Opus packet answered CLEAN, recorded as NAME
flash(){ local n=$1 m=$2; shift 2; $DP --review-pr "$n" --via qwen --model "$m" "$@" --repo "$C" > "$T/out.txt" 2>&1; }
opus(){ $DP --review-pr "$1" --packet --tier "$2" ${4:-} --repo "$C" > "$T/out.txt" 2>&1
  local pk; pk=$(sed -n 's/^PACKET \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
  [ -n "$pk" ] || { echo "    (no packet for PR $1: $(tail -1 "$T/out.txt"))"; return 1; }
  $DP --review-record "$(basename "$(dirname "$pk")")" --reviewer "$3" --file "$T/clean.txt" --repo "$C" > /dev/null 2>&1; }
st(){ $DP --pr-status "$1" --repo "$C" > "$T/out.txt" 2>&1; }

echo "== 1 a provider refusal is no review"
newpr 51 a.py 'a = 51'; H51=$(hd 51)
C0=$(calls); FAKE_REFUSE=1 flash 51 fake/m --tier low; RC=$?; cp "$T/out.txt" "$T/r51.txt"; st 51
[ $RC -eq 9 ] && grep -qF "PROVIDER LIMIT" "$T/r51.txt" && [ "$(calls)" = "$((C0+1))" ] && has "0 review(s) recorded" \
  && has "CURRENT HEAD ${H51:0:8}: UNREVIEWED (no review)" \
  && ok "1 --review-pr refused (Free usage limit reached): exit 9, PROVIDER LIMIT, one call, nothing recorded" \
  || { bad "1 refused --review-pr rc=$RC calls=$(( $(calls) - C0 ))"; tail -3 "$T/r51.txt"; tail -2 "$T/out.txt"; }

R="$T/repo"; mkdir -p "$R"
( set -e; cd "$R"; git init -q -b main; git config user.email t@t; git config user.name t
  printf 'x = 1\n' > a.py; printf '.claude/\n' > .gitignore; git add -A; git commit -qm init
  printf '# Plan\n## Phase 1 - x\nExecutor: deepseek-flash\nRisk: low\nFiles: a.py\nAcceptance:\n- `grep -q y a.py`\n' > PLAN_T.md ) \
  || { echo "setup failed: repo"; exit 1; }
FAKE_ACTIONS='echo y >> a.py' $DP 1 --plan PLAN_T.md --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1
RID=$(sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
C0=$(calls); FAKE_REFUSE=1 $DP --review "${RID:-none}" --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1; RC=$?
MJ=$(python3 -c "import json,sys; m=json.load(open(sys.argv[1])); print(bool(m.get('review')), len(m.get('reviews') or []))" \
  "$R/.git/concord/${RID:-none}/meta.json" 2>&1)
[ -n "$RID" ] && [ $RC -eq 9 ] && has "PROVIDER LIMIT" && [ "$(calls)" = "$((C0+1))" ] && [ "$MJ" = "False 0" ] \
  && ok "1 --review of a phase run refused: exit 9, PROVIDER LIMIT, one call, no review on the run" \
  || { bad "1 refused --review rc=$RC meta='$MJ' run=$RID"; tail -3 "$T/out.txt"; }

newpr 52 a.py 'a = 52'; H52=$(hd 52)
D="$RUNS/pr52-${H52:0:8}-opencodeglm53flashfree-1"; mkdir -p "$D"
printf '> build . glm-5.3-flash-free\n%s\n' "$REFUSAL" > "$D/output.log"; cp "$D/output.log" "$D/output-retry.log"
printf 'UNPARSED: no REVIEW-JSON block found\n' > "$D/report.md"
python3 - "$D" "$H52" <<'PY' || { echo "setup failed: legacy meta"; exit 1; }
import json, sys
d, h = sys.argv[1], sys.argv[2]
rev = {"reviewer": "deepseek-flash", "model": "opencode/glm-5.3-flash-free", "verdict": "UNPARSED", "blockers": 0,
       "highs": 0, "mediums": 0, "report": d + "/report.md", "retried": True, "head": h, "tier": "high",
       "at": "2026-10-23T07:03:34.155703+00:00"}
json.dump({"kind": "pr-review", "pr": 52, "slug": "", "base": "main", "head": h, "files": ["a.py"], "excluded": [],
           "checklists": ["any"], "tier": "high", "run_id": d.rsplit("/", 1)[1], "reviews": [rev]}, open(d + "/meta.json", "w"))
PY
opus 52 high concord:reviewer-opus55; st 52
has "CURRENT HEAD ${H52:0:8}: REVIEWED at high" && has "(provider refusal: not counted)" \
  && ok "1 a refused UNPARSED entry recorded before the fix (PR 37's case) is not counted: REVIEWED at high" \
  || { bad "1 legacy refusal"; tail -3 "$T/out.txt"; }
printf 'REVIEW-JSON\n{"findings": [{"severity": "HIGH", "problem": "the needle usage limit exceeded is matched anywhere"\n' > "$T/quote.txt"
newpr 60 a.py 'a = 60'; C0=$(calls); FAKE_JSON="$T/quote.txt" flash 60 fake/m --tier low; RC=$?
[ $RC -ne 9 ] && ! has "PROVIDER LIMIT" && [ "$(calls)" = "$((C0+2))" ] \
  && ok "1 a malformed answer quoting a refusal phrase is a parse failure (one retry), not a refusal" \
  || { bad "1 quoted refusal rc=$RC calls=$(( $(calls) - C0 ))"; tail -3 "$T/out.txt"; }

echo "== 2 a review is named by its model and kept per reviewer and file set"
newpr 53 a.py 'a = 53'; H53=$(hd 53)
FAKE_JSON="$T/high_a.txt" flash 53 fake/one --tier low; FAKE_JSON="$T/clean.txt" flash 53 fake/two --tier low --force-review; st 53
has "CURRENT HEAD ${H53:0:8}: FINDINGS OPEN (fake/one: FIX" \
  && ok "2 two models at one head, the first with a HIGH: FINDINGS OPEN under fake/one (not overwritten)" \
  || { bad "2 two models"; tail -3 "$T/out.txt"; }
newpr 54 a.py 'a = 54' b.py 'b = 54'; H54=$(hd 54)
FAKE_JSON="$T/high_a.txt" flash 54 fake/m --tier low --files a.py; FAKE_JSON="$T/clean.txt" flash 54 fake/m --tier low --files b.py; st 54
has "CURRENT HEAD ${H54:0:8}: FINDINGS OPEN (fake/m: FIX" \
  && ok "2 two --files groups of one model, the first with a HIGH: FINDINGS OPEN" || { bad "2 two groups"; tail -3 "$T/out.txt"; }

echo "== 3 REVIEWED only when reviews crediting the tier cover every PR file"
newpr 55 a.py 'a = 55' b.py 'b = 55'; H55=$(hd 55)
flash 55 fake/m --tier low --files a.py; st 55
has "CURRENT HEAD ${H55:0:8}: UNREVIEWED (not reviewed: b.py)" && ! has ": REVIEWED" \
  && ok "3 a review of a.py alone: UNREVIEWED, b.py named" || { bad "3 half the PR"; tail -3 "$T/out.txt"; }
newpr 56 a.py 'a = 56' b.py 'b = 56'; H56=$(hd 56)
flash 56 fake/m --tier low --exclude b.py; st 56
has "CURRENT HEAD ${H56:0:8}: REVIEWED at low (excluded: b.py)" \
  && ok "3 --exclude b.py: REVIEWED, b.py listed as excluded" || { bad "3 exclude"; tail -3 "$T/out.txt"; }
newpr 57 a.py 'a = 57' b.py 'b = 57'; H57=$(hd 57)
opus 57 high concord:reviewer-opus55 "--files a.py"; flash 57 fake/m --tier high --files b.py; st 57; S1=$(cat "$T/out.txt")
opus 57 high concord:reviewer-opus55 "--files b.py"; st 57
case "$S1" in *"CURRENT HEAD ${H57:0:8}: UNREVIEWED at high"*"not reviewed at high: b.py"*)
  has "CURRENT HEAD ${H57:0:8}: REVIEWED at high" \
  && ok "3 opus55 on a.py and flash on b.py at high: UNREVIEWED at high (b.py), REVIEWED once opus55 covers b.py" \
  || { bad "3 tier per group, after the second opus55 review"; tail -3 "$T/out.txt"; };;
  *) bad "3 tier per group: $(printf '%s' "$S1" | tail -1)";; esac
newpr 58 a.py 'a = 58'; flash 58 fake/m --tier low
newpr 59 a.py 'a = 58' b.py 'b = 59'; H59=$(hd 59)
flash 59 fake/m --tier low; R59=$(cat "$T/out.txt"); st 59
case "$R59" in *"reused 1 file(s)"*) has "CURRENT HEAD ${H59:0:8}: REVIEWED at low" \
  && ok "3 a narrowed review (a.py reused, b.py reviewed): REVIEWED at low (characterization)" \
  || { bad "3 narrow reuse status"; tail -3 "$T/out.txt"; };;
  *) bad "3 narrow reuse: $(printf '%s' "$R59" | tail -2)";; esac

echo; echo "passed $pass, failed $fail"; [ $fail -eq 0 ]
