#!/bin/bash
# Review reuse by content (Phase 13 + 13b): a recorded clean review stores a `covered` blob map and a tier rank.
# A later review request of any tier (flash --review, an Opus --packet, a PR review) skips the files a prior
# review of an equal-or-higher tier already saw at the same content, records a reused entry (so the tier gate
# still passes) and writes no packet / calls no model; a lower tier never covers a higher one. Partial coverage
# reviews only the uncovered files. --review-pr reuses PR and phase coverage alike and records a suppression at
# the head so --pr-status reports the gate met. --force-review bypasses reuse. --lint on a phase whose Executor
# is a Claude model prints LINT SKIPPED and only the zero-token ACCEPTANCE LINT lines. No network: a fake qwen
# is the executor and the flash reviewer, a fake gh answers `gh pr view`.
# Run: bash ~/.claude/concord/tests/reuse_test.sh   (exit 0 = all passed).
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/reuse-test.XXXXXX")" && pwd -P)"; export T
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
# Prefer the developer dir's real git/python3 over the /usr/bin xcrun shims (cache errors in the sandbox).
XDEV="$(xcode-select -p 2>/dev/null)"; [ -n "$XDEV" ] && [ -x "$XDEV/usr/bin/git" ] && [ -x "$XDEV/usr/bin/python3" ] && export PATH="$XDEV/usr/bin:$PATH"
export PATH="$T/bin:$PATH" HOME="$T/home"
DP="python3 $T/concord/concord.py"
R="$T/repo"; RUNS="$R/.git/concord"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
has(){ grep -F -- "$1" "$T/out.txt" > /dev/null; }
calls(){ [ -f "$T/qwen_calls" ] && wc -l < "$T/qwen_calls" | tr -d ' ' || echo 0; }
rid(){ sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1; }
rvid(){ sed -n 's/^REVIEW \([^ ]*\) of .*/\1/p' "$T/out.txt" | head -1; }
pk(){ sed -n 's/^PACKET \([^ ]*\).*/\1/p' "$T/out.txt" | head -1; }
meta(){ python3 -I -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))" "$RUNS/$1/meta.json" "$2"; }
lastrev(){ python3 -I -c "import json,sys; r=json.load(open(sys.argv[1]))['reviews'][-1]; print(r.get(sys.argv[2]))" "$RUNS/$1/meta.json" "$2"; }
run(){ FAKE_ACTIONS="$2" $DP "$1" --plan PLAN_R.md --via qwen --model fake/m --no-baseline --repo "$R" > "$T/out.txt" 2>&1; }
flash(){ $DP --review "$1" --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1; }
packet(){ $DP --review "$1" --packet --repo "$R" > "$T/out.txt" 2>&1; }
opus(){ $DP --review-record "$1" --reviewer "$2" --file "$T/clean.txt" --repo "$R" > /dev/null 2>&1; }
printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n' > "$T/clean.txt"

mkdir -p "$R" && ( cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'a = 1\n' > a.py; printf 'b = 1\n' > b.py; printf 'c = 1\n' > c.py; printf '.claude/\n' > .gitignore
  git add -A && git commit -qm init
  { printf '# Plan\n'
    printf '## Phase 1 - medium\nExecutor: deepseek-flash\nRisk: medium\nFiles: a.py, b.py\nAcceptance:\n- `true`\n'
    printf '## Phase 2 - high\nExecutor: deepseek-flash\nRisk: high\nFiles: a.py, b.py\nAcceptance:\n- `true`\n'
    printf '## Phase 3 - impl\nExecutor: concord:implementer-opus48\nRisk: medium\nFiles: a.py\nAcceptance:\n- `grep -c x f | grep -qx 0`\n'
  } > PLAN_R.md ) || { echo "setup failed"; exit 1; }

echo "== full reuse (a clean opus review covers a later Opus packet of the same tier)"
run 1 "echo '# r' >> a.py; echo '# r' >> b.py"; F=$(rid); [ -n "$F" ] || { echo "setup failed: run 1"; cat "$T/out.txt"; exit 1; }
opus "$F" reviewer-opus48
C0=$(calls); packet "$F"; RC=$?
[ $RC -eq 0 ] && [ "$(calls)" = "$C0" ] && [ -z "$(pk)" ] \
  && has "COVERED: 2 files already reviewed by reviewer-opus48 (medium) at the same content; no review run" \
  && [ "$(lastrev "$F" reused)" = True ] && [ "$(lastrev "$F" reviewer)" = reviewer-opus48 ] \
  && ok "all files already reviewed at the phase tier: COVERED, no packet, reused entry recorded" \
  || { bad "full reuse rc=$RC calls $C0->$(calls) pk='$(pk)'"; tail -3 "$T/out.txt"; }
$DP --verdict "$F" PASS --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && [ "$(meta "$F" verdict)" = PASS ] && ok "the reused opus entry passes the medium tier gate (exit 9 avoided)" \
  || { bad "tier gate after reuse rc=$RC"; tail -2 "$T/out.txt"; }

echo "== a flash --review after an opus review is suppressed (Phase 13b: tier 1 is reused like the rest)"
C0=$(calls); flash "$F"; RC=$?
[ $RC -eq 0 ] && [ "$(calls)" = "$C0" ] && [ -z "$(rvid)" ] \
  && has "COVERED: 2 files already reviewed by reviewer-opus48 (medium) at the same content; no review run" \
  && [ "$(lastrev "$F" reused)" = True ] \
  && ok "flash --review on fully covered content: COVERED, no model call, reused entry recorded" \
  || { bad "flash not suppressed rc=$RC calls $C0->$(calls)"; tail -3 "$T/out.txt"; }

echo "== --force-review bypasses reuse"
packet "$F"; [ -z "$(pk)" ] || { echo "setup failed: F not covered"; exit 1; }   # confirm it is covered
$DP --review "$F" --packet --force-review --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && [ -n "$(pk)" ] && ! has "COVERED" \
  && ok "--force-review writes the packet anyway (no COVERED line)" || { bad "force-review rc=$RC pk='$(pk)'"; tail -3 "$T/out.txt"; }

echo "== partial reuse (one file changed since the covering review)"
run 1 "echo '# s' >> a.py; echo '# s' >> b.py"; P=$(rid)
opus "$P" reviewer-opus48
echo '# later' >> "$R/b.py"                       # b.py content now differs from what the opus review saw
packet "$P"; RC=$?; PK="$(pk)"
[ $RC -eq 0 ] && [ -n "$PK" ] && has "reused 1 file(s) already reviewed by reviewer-opus48 (medium): a.py; reviewing b.py" \
  && grep -q '^+# later' "$PK" && ! grep -q '^diff --git a/a.py' "$PK" \
  && ok "only the changed file goes in the packet; the unchanged file is reported as reused" \
  || { bad "partial reuse rc=$RC pk='$PK'"; tail -3 "$T/out.txt"; }

echo "== changed content is not reused"
run 1 "echo '# t' >> a.py; echo '# t' >> b.py"; G=$(rid)
opus "$G" reviewer-opus48
echo '# x' >> "$R/a.py"; echo '# x' >> "$R/b.py"  # both files now differ from the covered content
packet "$G"; RC=$?; PK="$(pk)"
[ $RC -eq 0 ] && [ -n "$PK" ] && ! has "COVERED" && ! has "reused " \
  && grep -q '^diff --git a/a.py' "$PK" && grep -q '^diff --git a/b.py' "$PK" \
  && ok "no covered file matches the current blob: the full packet is written, nothing reused" \
  || { bad "changed content rc=$RC pk='$PK'"; tail -3 "$T/out.txt"; }

echo "== a lower tier never covers a higher one"
run 2 "echo '# r' >> a.py; echo '# r' >> b.py"; H=$(rid)
opus "$H" reviewer-opus48                          # rank 2 (medium)
packet "$H"; RC=$?
[ $RC -eq 0 ] && [ -n "$(pk)" ] && ! has "COVERED" \
  && ok "a high phase + an opus48 (medium) review: the packet is written, the medium review does not cover it" \
  || { bad "medium does not cover high rc=$RC pk='$(pk)'"; tail -3 "$T/out.txt"; }
opus "$H" reviewer-opus55                           # rank 3 (high)
packet "$H"; RC=$?
[ $RC -eq 0 ] && [ -z "$(pk)" ] && has "COVERED: 2 files already reviewed by reviewer-opus55 (high) at the same content; no review run" \
  && ok "the same phase once an opus55 (high) review exists: COVERED, no packet" \
  || { bad "high covers high rc=$RC pk='$(pk)'"; tail -3 "$T/out.txt"; }

echo "== --lint skips a Claude-model phase but still lints acceptance"
C0=$(calls); $DP --lint 3 --plan PLAN_R.md --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && [ "$(calls)" = "$C0" ] && has "LINT SKIPPED: executor concord:implementer-opus48 is a Claude model" \
  && has "ACCEPTANCE LINT: vacuous on empty input: grep -c x f | grep -qx 0" && ! has "DRY RUN LINT" && ! has "QUESTIONS:" \
  && ok "Claude-model phase: LINT SKIPPED, zero-token ACCEPTANCE LINT lines kept, no model call" \
  || { bad "lint skip rc=$RC calls $C0->$(calls)"; tail -4 "$T/out.txt"; }
$DP --lint 1 --dry-run --via qwen --model fake/m --plan PLAN_R.md --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "DRY RUN LINT" && ! has "LINT SKIPPED" \
  && ok "a non-Claude (deepseek-flash) phase is not skipped" || { bad "non-claude lint rc=$RC"; tail -3 "$T/out.txt"; }

echo "== PR review reuse (Phase 13b): fully covered, higher tier still runs, partial"
cat > "$T/bin/gh" <<'G'
#!/bin/sh
[ "$1" = pr ] && [ "$2" = view ] || exit 1
n=$(printf '%s' "$3" | sed -E 's|.*/pull/||; s|.*#||')
[ -f "$T/pr$n.json" ] && cat "$T/pr$n.json" && exit 0
echo "no pull requests found for $3" >&2; exit 1
G
chmod +x "$T/bin/gh"
O="$T/origin.git"; PR="$T/clone"; PRUNS="$PR/.git/concord"
prjson(){ printf '{"baseRefName": "main", "headRefOid": "%s", "title": "t", "body": "b"}\n' "$2" > "$T/pr$1.json"; }
prvp(){ $DP --review-pr "$1" --via qwen --model fake/m --tier "$2" --repo "$PR" > "$T/out.txt" 2>&1; }
git init -q --bare -b main "$O" && git clone -q "$O" "$PR" 2> /dev/null || { echo "setup failed: PR repos"; exit 1; }
( set -e; cd "$PR" && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > x.py; printf 'y = 1\n' > y.py; printf '.claude/\n' > .gitignore
  git add -A && git commit -qm init && git push -q origin main
  git checkout -qb pr20; printf 'x = 2\n' > x.py; printf 'y = 2\n' > y.py; git commit -qam pr20
  git push -q origin HEAD:refs/pull/20/head; git checkout -q main; git branch -qD pr20 ) || { echo "setup failed: PR history"; exit 1; }
prjson 20 "$(git -C "$O" rev-parse refs/pull/20/head)"

C0=$(calls); prvp 20 medium; RC=$?
[ $RC -eq 0 ] && [ "$(calls)" = "$((C0+1))" ] && ! has COVERED && ok "PR 20 first review at medium runs the model (clean, stores coverage)" \
  || { bad "PR first review rc=$RC calls $C0->$(calls)"; tail -3 "$T/out.txt"; }
( set -e; cd "$PR"; git fetch -q origin refs/pull/20/head; git checkout -q FETCH_HEAD
  git commit -q --allow-empty -m nop; git push -q origin HEAD:refs/pull/20/head; git checkout -q main ) || { echo "setup failed: empty commit"; exit 1; }
H20B=$(git -C "$O" rev-parse refs/pull/20/head); prjson 20 "$H20B"
C0=$(calls); prvp 20 medium; RC=$?
[ $RC -eq 0 ] && [ "$(calls)" = "$C0" ] && has "COVERED: 2 files already reviewed" && has "at the same content; no review run" \
  && ok "PR fully covered at a new head (all blobs unchanged): COVERED, no model call" \
  || { bad "PR full reuse rc=$RC calls $C0->$(calls)"; tail -3 "$T/out.txt"; }
$DP --pr-status 20 --repo "$PR" > "$T/out.txt" 2>&1
has "CURRENT HEAD ${H20B:0:8}: REVIEWED at medium" \
  && ok "--pr-status: the recorded suppression reports the gate met at the new head" || { bad "PR reuse status"; cat "$T/out.txt"; }
C0=$(calls); prvp 20 high; RC=$?
[ $RC -eq 0 ] && [ "$(calls)" = "$((C0+1))" ] && ! has COVERED \
  && ok "PR review at high is not covered by the medium review: the model runs" \
  || { bad "PR higher tier rc=$RC calls $C0->$(calls)"; tail -3 "$T/out.txt"; }
( set -e; cd "$PR"; git fetch -q origin refs/pull/20/head; git checkout -q FETCH_HEAD
  printf 'x = 3\n' > x.py; git commit -qam "x only"; git push -q origin HEAD:refs/pull/20/head; git checkout -q main ) || { echo "setup failed: x change"; exit 1; }
prjson 20 "$(git -C "$O" rev-parse refs/pull/20/head)"
C0=$(calls); prvp 20 medium; RC=$?
[ $RC -eq 0 ] && [ "$(calls)" = "$((C0+1))" ] && has "reused 1 file(s)" && has "y.py; reviewing x.py" && ! has COVERED \
  && ok "PR partially covered: only the changed x.py is reviewed, the unchanged y.py is reused" \
  || { bad "PR partial rc=$RC calls $C0->$(calls)"; tail -3 "$T/out.txt"; }

echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
