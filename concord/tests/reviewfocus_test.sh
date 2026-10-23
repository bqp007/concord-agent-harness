#!/bin/bash
# Repo notes in every review prompt and the repo-notes risk floor (2026-10-21, PLAN_kit-review): reviewers get the
# repo's binding notes (flash prompt, phase packet, PR packet); a `Risk floor <tier>: <globs>` line raises the review
# tier of a phase or PR whose change touches a matching non-test file. No network: fake qwen and gh.
# Run: bash ~/.claude/concord/tests/reviewfocus_test.sh   (exit 0 = all passed).
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/reviewfocus-test.XXXXXX")" && pwd -P)"; export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/concord" "$T/home/.claude"
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
cat > "$T/bin/qwen" <<'Q'
#!/bin/sh
if [ -n "${FAKE_ACTIONS:-}" ]; then sh -c "$FAKE_ACTIONS"; exit 0; fi
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
O="$T/origin.git"; R="$T/clone"; RUNS="$R/.git/concord"; NOTES="$T/concord/repo-notes/clone.md"
MARK="FAILURE-MARKER-7f3a"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
has(){ grep -F -- "$1" "$T/out.txt" > /dev/null; }
rid(){ sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1; }
pk(){ sed -n 's/^PACKET \([^ ]*\).*/\1/p' "$T/out.txt" | head -1; }
meta(){ python3 -I -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))" "$1/meta.json" "$2"; }
# run PHASE ACTIONS: one fake executor run of PLAN_F.md; ACTIONS is the shell the fake executor runs in the repo
run(){ FAKE_ACTIONS="$2" $DP "$1" --plan PLAN_F.md --via qwen --model fake/m --no-baseline --repo "$R" > "$T/out.txt" 2>&1; }
verdict(){ $DP --verdict "$@" --repo "$R" > "$T/out.txt" 2>&1; }
flash(){ $DP --review "$1" --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1; }
opus(){ $DP --review-record "$1" --reviewer "$2" --file "$T/clean.txt" --repo "$R" > /dev/null 2>&1; }
packet(){ $DP --review "$1" --packet --repo "$R" > "$T/out.txt" 2>&1; }
prpacket(){ $DP --review-pr "$@" --packet --repo "$R" > "$T/out.txt" 2>&1; }
# before FILE A B: the first line containing A comes before the first line containing B (both present)
before(){ awk -v a="$2" -v b="$3" 'index($0,a)&&!x{x=NR} index($0,b)&&!y{y=NR} END{exit !(x&&y&&x<y)}' "$1"; }
printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n' > "$T/clean.txt"
phase(){ printf '## Phase %s - p%s\nExecutor: deepseek-flash\nRisk: %s\nFiles: %s\nAcceptance:\n- `true`\n' "$1" "$1" "$2" "$3"; }
notes(){ printf '# clone: binding facts\n- %s\n- Risk floor high: sec/*, *.lock\n- Risk floor medium: docs/*\n- Risk floor extreme: a.py\n- Risk floor high:\n' "$MARK" > "$NOTES"; }
notes
git init -q --bare -b main "$O" && git clone -q "$O" "$R" 2> /dev/null || { echo "setup failed: repos"; exit 1; }
( set -e; cd "$R" && git config user.email t@t && git config user.name t && git config diff.renames true
  mkdir sec docs big; printf 'x = 1\n' > a.py; printf 'k = 1\n' > sec/key.py; printf 'o = 1\n' > sec/old.py
  printf 't = 1\n' > sec/key_test.py; printf 'doc\n' > docs/x.md; printf 'b = 1\n' > big/f.py; printf '.claude/\n' > .gitignore
  { echo '# Plan'; phase 1 medium sec/key.py; phase 2 medium a.py; phase 3 low docs/x.md; phase 4 high docs/x.md
    phase 5 low sec/key_test.py; phase 6 medium sec/old.py; phase 7 medium big/f.py; } > PLAN_F.md
  git add -A && git commit -qm init && git push -q origin main
  git checkout -qb pr7; printf 'x = 2\n' > a.py; git commit -qam pr7; git push -q origin HEAD:refs/pull/7/head
  git checkout -q main; git checkout -qb pr9; printf 'x = 3\n' > a.py; printf 'k = 9\n' > sec/key.py
  git commit -qam pr9; git push -q origin HEAD:refs/pull/9/head
  git checkout -q main; git checkout -qb pr11; mkdir moved; git mv sec/key.py moved/key.py
  git commit -qm pr11; git push -q origin HEAD:refs/pull/11/head
  git checkout -q main; git branch -qD pr7 pr9 pr11 ) || { echo "setup failed: history"; exit 1; }
for n in 7 9 11; do printf '{"baseRefName": "main", "headRefOid": "%s", "title": "pr%s", "body": "b"}\n' \
  "$(git -C "$O" rev-parse "refs/pull/$n/head")" "$n" > "$T/pr$n.json"; done

echo "== notes reach reviewers"
run 2 "echo '# r' >> a.py"; A=$(rid); [ -n "$A" ] || { echo "setup failed: run p2"; cat "$T/out.txt"; exit 1; }
flash "$A"; RV=$(sed -n 's/^REVIEW \([^ ]*\) of .*/\1/p' "$T/out.txt" | head -1)
[ -n "$RV" ] && [ -f "$RUNS/$RV/prompt.txt" ] && before "$RUNS/$RV/prompt.txt" "Files changed:" "$MARK" \
  && before "$RUNS/$RV/prompt.txt" "$MARK" "The phase that was implemented" \
  && ok "flash review prompt carries the repo notes right after Files changed" || { bad "flash review prompt has no repo notes ('$RV')"; tail -2 "$T/out.txt"; }
packet "$A"; P=$(pk)
[ -n "$P" ] && before "$P" "Files changed:" "$MARK" && before "$P" "$MARK" "The phase that was implemented" \
  && before "$P" "$MARK" "Checklists (" && ok "phase packet: repo notes right after Files changed, before the phase text and the checklists" \
  || { bad "phase packet '$P'"; tail -2 "$T/out.txt"; }
prpacket 7; P=$(pk)
[ -n "$P" ] && before "$P" "<<<END-PR-TEXT-" "$MARK" && before "$P" "$MARK" "Checklists (" \
  && ok "PR packet: repo notes after the PR-text block, before the checklists" || { bad "PR packet '$P'"; tail -2 "$T/out.txt"; }
mv "$NOTES" "$T/notes.off"
packet "$A"; P1=$(pk); prpacket 7; P2=$(pk)
# --force-review: A's content is unchanged since its flash review above, so re-review it to inspect the prompt
$DP --review "$A" --force-review --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1
RV2=$(sed -n 's/^REVIEW \([^ ]*\) of .*/\1/p' "$T/out.txt" | head -1); P3="$RUNS/$RV2/prompt.txt"
[ -n "$P1" ] && [ -n "$P2" ] && [ -n "$RV2" ] && [ -f "$P3" ] && ! grep -q "Repository notes" "$P1" "$P2" "$P3" \
  && ok "no notes file: no notes block in the packets or the flash prompt" || bad "notes block without a notes file ('$P1' '$P2' '$P3')"
mv "$T/notes.off" "$NOTES"

echo "== phase floor"
run 1 "echo '# r' >> sec/key.py"; S=$(rid)
packet "$S"
has "risk floor high" && has "sec/key.py matches sec/*" && has "reviewer-opus55" \
  && ok "--packet names the floor, the matched path and the reviewer the phase needs" \
  || { bad "--packet printed no floor note"; tail -3 "$T/out.txt"; }
flash "$S"
has "risk floor high" && has "sec/key.py matches sec/*" && has "reviewer-opus55" \
  && ok "--review (flash) names the floor, the matched path and the reviewer the phase needs" \
  || { bad "--review printed no floor note"; tail -3 "$T/out.txt"; }
opus "$S" reviewer-opus48; $DP --close-round "$S" --verdict-result PASS --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 9 ] && grep -q "^REFUSED:" "$T/out.txt" && has "reviewer-opus55" && has "sec/key.py matches sec/*" \
  && [ "$(meta "$RUNS/$S" verdict)" = None ] \
  && ok "medium phase on a high-floor path + reviewer-opus48: --close-round PASS refused (exit 9), names path and reviewer" \
  || { bad "high floor rc=$RC"; tail -2 "$T/out.txt"; }
verdict "$S" PASS --user-approved "ok" --note n1; RC=$?
[ $RC -eq 0 ] && [ "$(meta "$RUNS/$S" verdict_note)" = "tier waived (user: ok); n1" ] && ok "--user-approved waives a floor refusal" \
  || { bad "waiver rc=$RC note=$(meta "$RUNS/$S" verdict_note)"; tail -2 "$T/out.txt"; }
run 1 "echo '# s' >> sec/key.py"; S2=$(rid); opus "$S2" reviewer-opus55; verdict "$S2" PASS; RC=$?
[ $RC -eq 0 ] && ok "high floor + reviewer-opus55: PASS" || { bad "high floor + opus55 rc=$RC"; tail -2 "$T/out.txt"; }
opus "$A" reviewer-opus48; verdict "$A" PASS; RC=$?
[ $RC -eq 0 ] && ok "medium phase on a.py + reviewer-opus48: PASS (unknown-tier and empty floor lines ignored)" \
  || { bad "a.py rc=$RC"; tail -2 "$T/out.txt"; }
run 3 "echo '# r' >> docs/x.md"; L=$(rid); flash "$L"; verdict "$L" PASS; RC=$?
[ $RC -eq 9 ] && has "reviewer-opus55" && has "docs/x.md" && ok "low phase on a medium-floor path + flash: refused, needs reviewer-opus55" \
  || { bad "medium floor rc=$RC"; tail -2 "$T/out.txt"; }
opus "$L" reviewer-opus48; verdict "$L" PASS; RC=$?
[ $RC -eq 0 ] && ok "low phase on a medium-floor path + reviewer-opus48: PASS" || { bad "medium floor + opus48 rc=$RC"; tail -2 "$T/out.txt"; }
run 2 "echo '# m' >> docs/x.md"; Q=$(rid); packet "$Q"
[ -n "$(pk)" ] && ! has "risk floor" && ok "medium phase on a medium-floor path: no floor note (the floor must rank above the tier)" \
  || { bad "floor note at an equal tier"; tail -3 "$T/out.txt"; }
run 4 "echo '# s' >> docs/x.md"; H=$(rid); opus "$H" reviewer-opus48; verdict "$H" PASS; RC=$?
[ $RC -eq 9 ] && has "reviewer-opus55" && ok "high phase on a medium-floor path + reviewer-opus48: refused (a floor never lowers the tier)" \
  || { bad "floor lowered the tier rc=$RC"; tail -2 "$T/out.txt"; }
run 5 "echo '# r' >> sec/key_test.py"; K=$(rid); flash "$K"; verdict "$K" PASS; RC=$?
[ $RC -eq 0 ] && ok "low phase changing only sec/key_test.py + flash: PASS (test files never trigger a floor)" \
  || { bad "test file triggered the floor rc=$RC"; tail -2 "$T/out.txt"; }
run 2 "echo '# g' >> a.py; mkdir -p sec/__pycache__; printf c > sec/__pycache__/k.pyc"; G=$(rid)
opus "$G" reviewer-opus48; verdict "$G" PASS; RC=$?
case "$(meta "$RUNS/$G" generated)" in *"sec/__pycache__/k.pyc"*) GEN=1 ;; *) GEN=0 ;; esac
[ $GEN -eq 1 ] && [ $RC -eq 0 ] && ok "medium phase on a.py leaving sec/__pycache__/k.pyc + reviewer-opus48: PASS (generated files never trigger a floor)" \
  || { bad "generated file gen=$GEN rc=$RC"; tail -2 "$T/out.txt"; }
run 6 "rm sec/old.py"; D=$(rid); opus "$D" reviewer-opus48; verdict "$D" PASS; RC=$?
[ $RC -eq 9 ] && has "sec/old.py" && ok "deleting a high-floor file + reviewer-opus48: refused (deletions count)" \
  || { bad "deletion rc=$RC"; tail -2 "$T/out.txt"; }
run 1 "echo '# t' >> sec/key.py"; F=$(rid); verdict "$F" FAIL --cause FLAKY; RC=$?
[ $RC -eq 0 ] && ok "FAIL on a floored phase needs no review" || { bad "FAIL rc=$RC"; tail -2 "$T/out.txt"; }
{ printf '# clone: binding facts\n'; python3 -I -c "print('- filler ' + 'x' * 4200)"; printf -- '- Risk floor high: big/*\n'; } > "$NOTES"
run 7 "echo '# r' >> big/f.py"; B=$(rid); opus "$B" reviewer-opus48; verdict "$B" PASS; RC=$?
[ $RC -eq 9 ] && has "big/f.py" && ok "a floor line past the 4000-character notes cap still counts" || { bad "capped floor rc=$RC"; tail -2 "$T/out.txt"; }
notes
mv "$NOTES" "$T/notes.off"
run 1 "echo '# u' >> sec/key.py"; U=$(rid); opus "$U" reviewer-opus48; verdict "$U" PASS; RC=$?
[ $RC -eq 0 ] && ok "no notes file: medium phase on sec/key.py + reviewer-opus48: PASS (today's behaviour)" \
  || { bad "no notes file rc=$RC"; tail -2 "$T/out.txt"; }
mv "$T/notes.off" "$NOTES"
run 1 "echo '# v' >> sec/key.py; echo '# v' >> a.py"; X=$(rid)
$DP --review "$X" --packet --files a.py --repo "$R" > "$T/out.txt" 2>&1
has "risk floor high" && has "sec/key.py matches sec/*" && ok "--review --packet --files a.py still names the run's floor (--files never narrows it)" \
  || { bad "phase --files narrowed the floor"; tail -3 "$T/out.txt"; }
printf 'stray \377 byte\n' >> "$NOTES"
run 1 "echo '# w' >> sec/key.py"; W=$(rid); opus "$W" reviewer-opus48; verdict "$W" PASS; RC=$?
[ $RC -eq 9 ] && grep -q "^REFUSED:" "$T/out.txt" && ! has "Traceback" && ok "notes with a stray non-UTF-8 byte: floor still refuses, no traceback" \
  || { bad "stray byte rc=$RC"; tail -3 "$T/out.txt"; }
# --force-review: W is already covered by its opus48 review above; re-review it to inspect the flash prompt
$DP --review "$W" --force-review --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1
RV3=$(sed -n 's/^REVIEW \([^ ]*\) of .*/\1/p' "$T/out.txt" | head -1)
[ -n "$RV3" ] && grep -qF "$MARK" "$RUNS/$RV3/prompt.txt" && ! has "Traceback" && ok "notes with a stray non-UTF-8 byte: flash prompt still carries the notes" \
  || { bad "stray byte broke the flash prompt ('$RV3')"; tail -3 "$T/out.txt"; }
notes

echo "== PR floor"
prpacket 9; P=$(pk)
[ -n "$P" ] && has "tier raised to high" && [ "$(meta "$(dirname "$P")" tier)" = high ] \
  && ok "PR touching sec/key.py: tier raised to high and recorded" || { bad "PR floor '$P'"; tail -3 "$T/out.txt"; }
prpacket 9 --files a.py; P=$(pk)
[ -n "$P" ] && has "tier raised to high" && [ "$(meta "$(dirname "$P")" tier)" = high ] \
  && ok "--files a.py cannot dodge the PR floor" || { bad "PR floor with --files '$P'"; tail -3 "$T/out.txt"; }
prpacket 7; P=$(pk)
[ -n "$P" ] && ! has "tier raised" && [ "$(meta "$(dirname "$P")" tier)" = medium ] && ok "PR without floor files keeps tier medium" \
  || { bad "PR 7 tier '$P'"; tail -3 "$T/out.txt"; }
prpacket 11; P=$(pk)
[ -n "$P" ] && has "tier raised to high" && [ "$(meta "$(dirname "$P")" tier)" = high ] \
  && ok "PR renaming sec/key.py out of the floor path: tier still raised (rename source counts)" || { bad "PR rename dodged the floor '$P'"; tail -3 "$T/out.txt"; }
python3 -I -B -c "import sys; sys.path.insert(0, sys.argv[1]); import concord as d; sys.exit(0 if d.parse_risk_floors('\ufeff- Risk floor high: sec/*\n') == [('high', ['sec/*'])] else 1)" "$T/concord" 2> /dev/null \
  && ok "a floor line right after a UTF-8 byte-order mark still parses" || bad "a byte-order mark hid the first floor line"

echo "== property tests (seed 7, 400 cases)"
python3 -I -B - "$T/concord" > "$T/prop.txt" 2>&1 <<'PY'
import random, sys
sys.path.insert(0, sys.argv[1])
import concord as d
rng = random.Random(7)
TIERS = ["low", "medium", "high"]
PATS = ["sec/*", "*.lock", "docs/*", "a.py", "*allowlist*", "include/*", "x/y/*", "*_dto.cpp"]
FILES = ["sec/key.py", "sec/key_test.py", "docs/x.md", "a.py", "b.lock", "tests/t.py", "lib/allowlist.csv",
         "include/api.hpp", "x/y/z.py", "README.md", "SEC/Upper.py", "test_sec.py", "src/user_dto.cpp", "spec/a.py"]
JUNK = ["Risk floor extreme: a.py", "Risk floor high:", "Risk floors high: a.py", "# Risk floor high: a.py",
        "Risk-floor high: a.py", "plain text", "", "- risk  floor: high a.py", "Risk floor high a.py"]


def rank(tier):
    return d.TIER_RANK[tier] if tier else 0


def oracle(floors, files):
    best = (None, None, None)
    for f in files:
        if d.TEST_PATH.search(f):
            continue
        for tier, pats in floors:
            for p in pats:
                if d.path_matches(f, [p]) and rank(tier) > rank(best[0]):
                    best = (tier, f, p)
    return best


bad = 0
for case in range(400):
    lines, want = [], []
    for _ in range(rng.randint(0, 5)):
        if rng.random() < 0.3:
            lines.append(rng.choice(JUNK))
            continue
        tier, pats = rng.choice(TIERS), rng.sample(PATS, rng.randint(1, 3))
        word = rng.choice([tier, tier.upper(), tier.capitalize()])
        sep = rng.choice([", ", ",", " ", " , "])
        lines.append(rng.choice(["", "- ", "* ", "  - "]) + f"Risk floor {word}: " + sep.join(pats))
        want.append((tier, pats))
    got = d.parse_risk_floors("\n".join(lines))
    if [(t, list(p)) for t, p in got] != want:
        bad += 1
        print("PARSE", case, lines, got, want)
        continue
    files = rng.sample(FILES, rng.randint(0, 6))
    expected, result = oracle(want, files), tuple(d.pick_floor(want, files))
    if result != expected:
        bad += 1
        print("PICK", case, want, files, result, expected)
        continue
    if rank(d.pick_floor(want, files + [rng.choice(FILES)])[0]) < rank(result[0]):
        bad += 1
        print("MONOTONE", case, want, files)
print("property failures:", bad)
sys.exit(1 if bad else 0)
PY
RC=$?
[ $RC -eq 0 ] && ok "parse_risk_floors and pick_floor match the oracle; adding a file never lowers the floor" \
  || { bad "property tests rc=$RC"; tail -5 "$T/prop.txt"; }

echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
