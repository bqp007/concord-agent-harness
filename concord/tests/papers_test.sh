#!/bin/bash
# concord.py regression for the 2026-10-18 nine-paper changes, lean revision 2026-10-23 (no network, fake qwen
# executor, ~30 s): webfetch denied by default + tool-call parsing; acceptance files hashed (report line, PASS refused
# with exit 7, --force, session runs exempt, an executor that rewrites its run state); post-run acceptance pass and
# what PASS needs of it (a result per command, the expected one, a note for an expected-red command); NO CHANGES flag;
# review file lists without generated files and the diff base of a committed run; --review-record keeps every finding.
# Run: bash ~/.claude/concord/tests/papers_test.sh   (exit 0 = all passed). Copies Concord into a temp dir with
# HOME pointing at a temp home, so runs.jsonl and the real config stay untouched.
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pp-test.XXXXXX")" && pwd -P)"; export T
mkdir -p "$T/bin" "$T/concord" "$T/home/.claude"
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
printf '#!/bin/sh\nsh -c "${FAKE_ACTIONS:-true}"\n' > "$T/bin/qwen"; chmod +x "$T/bin/qwen"
# The /usr/bin git and python3 are xcrun shims; inside the macOS sandbox xcrun cannot write its cache and prints
# "couldn't create cache file" on stderr, which pollutes captured output. Prefer the developer dir's real binaries.
XDEV="$(xcode-select -p 2>/dev/null)"; [ -n "$XDEV" ] && [ -x "$XDEV/usr/bin/git" ] && [ -x "$XDEV/usr/bin/python3" ] && export PATH="$XDEV/usr/bin:$PATH"
export PATH="$T/bin:$PATH" HOME="$T/home"
DP="python3 $T/concord/concord.py"
R="$T/repo"; export R
. "$(dirname "$0")/lib.sh"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
# newrepo ACCEPTANCE: repo with a.py, b.py, tests/test_a.py, tests/test_b.py and PLAN_T.md phase 1 (Files: a.py)
newrepo(){ rm -rf "$R"; mkdir -p "$R/tests"; (
  cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > a.py; printf 'y = 2\n' > b.py; printf 'assert True\n' > tests/test_a.py
  printf 'assert True\n' > tests/test_b.py; printf '.claude/\n' > .gitignore
  git add -A && git commit -qm init
  printf '# Plan\n## Test plan\n| Behavior | Existing tests | Action | Home |\n|---|---|---|---|\n| a | test_a | KEEP | tests/test_a.py |\n## Phase 1 - change a\nExecutor: deepseek-flash\nFiles: a.py\nAcceptance:\n- `%s`\n' "$1" > PLAN_T.md
); approve PLAN_T.md "$R" || exit 1; }
# run ACTIONS: one fake executor run of PLAN_T.md phase 1; a refused run is a broken fixture
run(){ FAKE_ACTIONS="$1" $DP 1 --plan PLAN_T.md --via qwen --model fake/m --no-baseline --repo "$R" > "$T/out.txt" 2>&1
  grep -q '^DELEGATE RESULT' "$T/out.txt" || { echo "setup failed: the run did not start"; cat "$T/out.txt"; exit 1; }; }
has(){ grep -F -- "$1" "$T/out.txt" > /dev/null; }
line(){ grep "^$1" "$T/out.txt" | grep -F -- "$2" > /dev/null; }
rid(){ sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1; }
meta(){ python3 -I -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))" "$R/.git/concord/$1/meta.json" "$2"; }
pyblock(){ python3 -I - "$T/concord/concord.py" "$T" "$@"; [ $? -eq 0 ] && pass=$((pass+1)) || fail=$((fail+1)); }

echo "== network"
pyblock <<'EOF'
import importlib.util, json, sys
from pathlib import Path
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("d", sys.argv[1]); d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
problems = []
for mode in ("full", "edit", "readonly"):
    _, env, _ = d.build_command("opencode", "/bin/true", "task", "contract", "opencode-go/x", mode, "30m",
                                Path(sys.argv[2]), {}, allow_edit=["a.py"])
    perm = json.loads(env["OPENCODE_CONFIG_CONTENT"])["permission"]
    if perm.get("webfetch") != "deny":
        problems.append(f"{mode}: webfetch={perm.get('webfetch')!r}")
fetch = lambda url: {"type": "tool", "tool": "webfetch", "state": {"input": {"url": url}}}
rows = [{"content": [fetch("https://zz.example/a"), fetch("https://pypi.org/x"), {"type": "reasoning", "text": "hm"}]},
        {"content": [fetch("http://pypi.org/y"), {"type": "tool", "tool": "shell", "state": {"input": {"command": "ls"}}}]},
        {"content": []}]
try:
    got = d.tool_calls_from_messages(rows)
except AttributeError:
    got = "missing tool_calls_from_messages"
if got != {"tool_calls": 4, "webfetch_attempts": ["pypi.org", "zz.example"]}:
    problems.append(f"tool_calls_from_messages -> {got!r}")
hostile = [{"content": [{"type": "tool", "tool": "webfetch", "state": "x"},
                        {"type": "tool", "tool": "webfetch", "state": {"input": {"url": 5}}},
                        fetch("http://[::1"), fetch("http://a\x1bb.example/"), fetch("https://ok.example/")]},
           {"content": 5}, {"content": [5, "s", None]}, "row", None]
try:
    got2 = d.tool_calls_from_messages(hostile)
    if got2.get("webfetch_attempts") != ["ok.example"]:
        problems.append(f"hostile rows -> {got2!r}")
except Exception as exc:
    problems.append(f"hostile rows raise {exc!r}")
print("  ok   webfetch denied in full, edit and readonly; tool calls and webfetch hosts parsed" if not problems
      else "  FAIL network: " + "; ".join(problems))
sys.exit(1 if problems else 0)
EOF

echo "== acceptance files"
newrepo 'python3 tests/test_a.py'
run 'echo y >> a.py; echo "# t" >> tests/test_a.py'; RID=$(rid)
line "ACCEPTANCE FILES CHANGED:" "tests/test_a.py (modified)" && ok "edit of an acceptance file reported" \
  || { bad "acceptance file edit not reported"; grep -i accept "$T/out.txt" | head -5; }
$DP --verdict "$RID" PASS --repo "$R" > "$T/v.txt" 2>&1; RC=$?
[ $RC -eq 7 ] && grep -qi "acceptance files changed" "$T/v.txt" && [ "$(meta "$RID" verdict)" = "None" ] \
  && ok "PASS refused (exit 7), verdict not recorded" || { bad "PASS not refused rc=$RC verdict=$(meta "$RID" verdict)"; cat "$T/v.txt"; }
$DP --verdict "$RID" PASS --force --repo "$R" > "$T/v.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && [ "$(meta "$RID" verdict)" = "PASS" ] && grep -qF "PASS (forced)" "$T/v.txt" \
  && ok "--force over a changed acceptance file records PASS, and the verdict line reads PASS (forced)" || { bad "--force rc=$RC"; cat "$T/v.txt"; }
newrepo 'python3 tests/test_a.py'; run 'echo y >> a.py'; RID=$(rid)
! has "ACCEPTANCE FILES CHANGED" && $DP --verdict "$RID" PASS --repo "$R" > "$T/v.txt" 2>&1 \
  && ok "untouched acceptance files: no line, PASS accepted" || { bad "clean run flagged or refused"; cat "$T/v.txt"; grep ACCEPT "$T/out.txt"; }
newrepo 'python3 tests/test_a.py'
$DP --begin 1 --label planner --plan PLAN_T.md --repo "$R" > "$T/b.txt" 2>&1
BID=$(sed -n 's/.*concord.py --end \([^ ]*\).*/\1/p' "$T/b.txt" | tail -1)
echo "# planner edit" >> "$R/tests/test_a.py"
$DP --end "$BID" --repo "$R" > "$T/out.txt" 2>&1
$DP --verdict "$BID" PASS --repo "$R" > "$T/v.txt" 2>&1 && ok "planner session run may edit acceptance files (PASS accepted)" \
  || { bad "planner run refused ($BID)"; cat "$T/v.txt"; }
newrepo 'python3 tests/test_a.py'
$DP --begin 1 --label implementer --plan PLAN_T.md --repo "$R" > "$T/b.txt" 2>&1
BID=$(sed -n 's/.*concord.py --end \([^ ]*\).*/\1/p' "$T/b.txt" | tail -1)
echo y >> "$R/a.py"; echo "# impl edit" >> "$R/tests/test_a.py"
$DP --end "$BID" --repo "$R" > "$T/out.txt" 2>&1
$DP --verdict "$BID" PASS --repo "$R" > "$T/v.txt" 2>&1
[ $? -eq 7 ] && ok "implementer session run editing acceptance files -> PASS refused (only planner exempt)" \
  || { bad "implementer session not refused ($BID)"; cat "$T/v.txt"; }
newrepo 'grep -q y a.py'
# the characterization command rewrites a grading file (a Test plan home) only while a.py has no y, so only the red run before the change does
printf '# Plan\n## Test plan\n| Behavior | Existing tests | Action | Home |\n|---|---|---|---|\n| b | test_b | KEEP | tests/test_b.py |\n\n## Phase 1 - change a\nExecutor: deepseek-flash\nFiles: a.py\nAcceptance:\n- `grep -q y a.py`\n- `python3 tests/test_a.py && { grep -q y a.py || date +%%N > tests/test_b.py; }` (characterization)\n' > "$R/PLAN_T.md"
approve PLAN_T.md "$R" || exit 1
FAKE_ACTIONS='echo y >> a.py' $DP 1 --plan PLAN_T.md --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1; RID=$(rid)
[ -n "$RID" ] && [ -n "$(git -C "$R" status --porcelain -- tests/test_b.py)" ] && [ "$(meta "$RID" acceptance_after_rc)" = "[0, 0]" ] \
  || { echo "setup failed: a run whose red run rewrote tests/test_b.py and whose acceptance then passed twice"; cat "$T/out.txt"; exit 1; }
$DP --verdict "$RID" PASS --repo "$R" > "$T/v.txt" 2>&1; RC=$?
line "changed in scope:" "a.py" && ! has "ACCEPTANCE FILES CHANGED" && ! has "ACCEPTANCE COMMAND CHANGED GRADING FILE" && [ $RC -eq 0 ] && [ "$(meta "$RID" verdict)" = "PASS" ] \
  && ok "a grading file rewritten only by the red run before the change is blamed on nobody: no ACCEPTANCE line, PASS accepted" \
  || { bad "red-run artifact blamed rc=$RC"; grep -e ACCEPT -e '^status' "$T/out.txt"; cat "$T/v.txt"; }
$DP --help 2>&1 | tr -s ' \n' ' ' | grep -q -- "--force.*acceptance files" && ok "--force help mentions the acceptance-file refusal" || bad "--force help text"
cat > "$T/rig.py" <<'PY'
import glob, hashlib, json, os, sys
for f in glob.glob(os.environ["R"] + "/.git/concord/*/state.json"):    # the executor rewrites the hashes that grade it
    st = json.load(open(f)); st["acceptance_hashes"] = {p: hashlib.sha256(open(os.environ["R"] + "/" + p, "rb").read()).hexdigest()
                                                         for p in st["acceptance_hashes"]}
    json.dump(st, open(f, "w"))
PY
newrepo 'python3 tests/test_a.py'
run 'echo y >> a.py; echo "# rigged" >> tests/test_a.py; python3 '"$T"'/rig.py'; RID=$(rid)
$DP --verdict "$RID" PASS --repo "$R" > "$T/v.txt" 2>&1; RC=$?
line "ACCEPTANCE FILES CHANGED:" "tests/test_a.py (modified)" && [ $RC -eq 7 ] && [ "$(meta "$RID" verdict)" = "None" ] \
  && ok "an executor that rewrites its run state and a grading test: ACCEPTANCE FILES CHANGED, PASS refused (exit 7)" \
  || { bad "rigged run: PASS rc=$RC"; grep -i accept "$T/out.txt" | head -3; }
# S42: the grading file is rewritten by a post-run acceptance command (a snapshot test that refreshes its golden file)
newrepo 'python3 tests/test_a.py && echo "# refreshed golden" >> tests/test_a.py'
run 'echo y >> a.py'; RID=$(rid)
if [ "$(meta "$RID" acceptance_after_rc)" = "[0]" ] && [ "$(tail -1 "$R/tests/test_a.py")" = "# refreshed golden" ]; then
  $DP --verdict "$RID" PASS --repo "$R" > "$T/v.txt" 2>&1; RC=$?
  [ $RC -eq 7 ] && [ "$(meta "$RID" verdict)" = "None" ] && grep -qF "tests/test_a.py" "$T/v.txt" \
    && ok "a post-run acceptance command that rewrites a grading file and exits 0: PASS refused (exit 7), the file named" \
    || { bad "grading file rewritten by an acceptance command: PASS rc=$RC verdict=$(meta "$RID" verdict)"; cat "$T/v.txt"; }
  $DP --verdict "$RID" PASS --force --note "owner accepts the refreshed golden file" --repo "$R" > "$T/v.txt" 2>&1
  $DP --report --plan PLAN_T.md --repo "$R" > "$T/rep.txt" 2>&1; REP=$(sed -n 's/^report: //p' "$T/rep.txt" | head -1); [ -f "$REP" ] || REP="$T/none"
  sed -n '/^## Overrides/,/^## [^O]/p' "$REP" | grep -qF "tests/test_a.py" \
    && ok "the report's Overrides names the grading file that an acceptance command rewrote" \
    || { bad "report does not name the rewritten grading file"; sed -n '/^## Overrides/,/^## [^O]/p' "$REP"; }
else bad "S42 setup: the acceptance command did not rewrite tests/test_a.py (after rc $(meta "$RID" acceptance_after_rc))"; fi

echo "== acceptance after run"
newrepo 'grep -q y a.py'; run 'echo y >> a.py'; RID=$(rid)
line "acceptance after run:" "1/1 pass" && [ "$(meta "$RID" acceptance_after_rc)" = "[0]" ] \
  && ok "post-run acceptance: 1/1 pass, rc stored" || { bad "post-run acceptance: $(grep -i 'after run' "$T/out.txt") rc=$(meta "$RID" acceptance_after_rc)"; }
$DP --verdict "$RID" FAIL --repo "$R" > "$T/v.txt" 2>&1
grep -q "all acceptance commands passed" "$T/v.txt" && grep -q "TEST_DEFECT" "$T/v.txt" \
  && ok "FAIL without cause after green acceptance hints TEST_DEFECT" || { bad "no TEST_DEFECT hint"; cat "$T/v.txt"; }
newrepo 'grep -q y a.py'; run 'echo z >> a.py'
line "ACCEPTANCE AFTER RUN:" "0/1 pass" && ok "post-run acceptance failing -> upper-case line" || bad "failing post-run line: $(grep -i 'after run' "$T/out.txt")"
printf '\nacceptance_after = no\n' >> "$T/concord/executors.conf"
newrepo 'grep -q y a.py'; run 'echo y >> a.py'
! grep -qi "acceptance after run" "$T/out.txt" && ok "acceptance_after = no turns the pass off" || bad "conf flag ignored"
cp -p "$SRC/executors.conf" "$T/concord/executors.conf"; fake_env

echo "== what PASS needs of the acceptance results"
verdict_of(){ meta "$1" verdict; }
newrepo 'grep -q y a.py'; run 'true'; RID=$(rid)
$DP --verdict "$RID" PASS --repo "$R" > "$T/v.txt" 2>&1; RC=$?
[ "$(meta "$RID" acceptance_after_rc)" = "[1]" ] && [ $RC -eq 7 ] && [ "$(verdict_of "$RID")" = "None" ] \
  && ok "PASS refused (exit 7) when a command's result after the run is not the expected green" || { bad "wrong result: rc=$RC verdict=$(verdict_of "$RID") after=$(meta "$RID" acceptance_after_rc)"; cat "$T/v.txt"; }
$DP --verdict "$RID" PASS --force --note "owner accepts" --repo "$R" > "$T/v.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && [ "$(verdict_of "$RID")" = "PASS" ] && grep -qF "PASS (forced)" "$T/v.txt" \
  && ok "--force records it, and the verdict line reads PASS (forced)" || { bad "forced PASS rc=$RC"; cat "$T/v.txt"; }
printf '\nacceptance_after = no\n' >> "$T/concord/executors.conf"
newrepo 'grep -q y a.py'; run 'echo y >> a.py'; RID=$(rid)
cp -p "$SRC/executors.conf" "$T/concord/executors.conf"; fake_env
$DP --verdict "$RID" PASS --repo "$R" > "$T/v.txt" 2>&1; RC=$?
[ -z "$(grep -i 'acceptance after run' "$T/out.txt")" ] && [ $RC -eq 7 ] && [ "$(verdict_of "$RID")" = "None" ] \
  && ok "PASS refused (exit 7) when a command has no result from after the run (post-run acceptance off)" || { bad "missing result: rc=$RC verdict=$(verdict_of "$RID")"; cat "$T/v.txt"; }
newrepo 'grep -q y a.py'; run 'echo y >> a.py'; RID=$(rid)
$DP --verdict "$RID" PASS --repo "$R" > "$T/v.txt" 2>&1; RC=$?
[ "$(meta "$RID" acceptance_after_rc)" = "[0]" ] && [ $RC -eq 0 ] && [ "$(verdict_of "$RID")" = "PASS" ] && ! grep -qF "(forced)" "$T/v.txt" \
  && ok "every result from after the run is the expected one: PASS recorded, not forced" || { bad "green run: rc=$RC"; cat "$T/v.txt"; }
# acceptance passed at the run's end, then the file is edited so it would fail: the old exit 0 is stale evidence
newrepo 'grep -q y a.py'; run 'echo y >> a.py'; RID=$(rid)
printf 'z = 3\n' > "$R/a.py"
$DP --verdict "$RID" PASS --repo "$R" > "$T/v.txt" 2>&1; RC=$?
[ "$(meta "$RID" acceptance_after_rc)" = "[0]" ] && [ $RC -eq 7 ] && [ "$(verdict_of "$RID")" = "None" ] && grep -qF "a.py" "$T/v.txt" \
  && ok "a file edited after the run's acceptance: PASS refused (exit 7), the file named, nothing recorded" || { bad "stale PASS: rc=$RC verdict=$(verdict_of "$RID")"; cat "$T/v.txt"; }
$DP --review "$RID" --packet --repo "$R" > "$T/out.txt" 2>&1
PK=$(sed -n 's/^PACKET \(.*\)$/\1/p' "$T/out.txt" | head -1)
[ -f "$PK" ] && grep -F "STALE" "$PK" | grep -qF "a.py" \
  && ok "the review packet marks the acceptance results stale and names the file" || bad "packet '$PK' has no stale mark"
$DP --verdict "$RID" PASS --force --note "owner accepts" --repo "$R" > "$T/v.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && [ "$(verdict_of "$RID")" = "PASS" ] && grep -qF "PASS (forced)" "$T/v.txt" \
  && ok "--force still records the stale PASS, marked forced" || { bad "forced stale PASS rc=$RC"; cat "$T/v.txt"; }
newrepo 'grep -q y a.py'; run 'echo y >> a.py'; RID=$(rid)
$DP --review "$RID" --packet --repo "$R" > "$T/out.txt" 2>&1
PK=$(sed -n 's/^PACKET \(.*\)$/\1/p' "$T/out.txt" | head -1)
[ -f "$PK" ] && ! grep -qF "STALE" "$PK" && ok "an unedited run's packet carries no stale mark" || bad "false stale mark in '$PK'"
newrepo 'true'
printf '# Plan\n## Phase 1 - tests first\nExecutor: deepseek-flash\nFiles: a.py\nAcceptance:\n- `python3 tests/red.py` (fails until phase 2)\n' > "$R/PLAN_T.md"
printf 'import sys\nsys.exit(1)\n' > "$R/tests/red.py"; approve PLAN_T.md "$R" || exit 1
run 'echo y >> a.py'; RID=$(rid)
$DP --verdict "$RID" PASS --repo "$R" > "$T/v.txt" 2>&1; RC=$?
[ "$(meta "$RID" acceptance_after_rc)" = "[1]" ] && [ $RC -ne 0 ] && [ "$(verdict_of "$RID")" = "None" ] \
  && ok "an expected-red command that fails: PASS without --note is refused, nothing recorded" || { bad "expected-red, no note: rc=$RC verdict=$(verdict_of "$RID")"; cat "$T/v.txt"; }
$DP --verdict "$RID" PASS --note "tests/red.py fails: the feature lands in phase 2" --repo "$R" > "$T/v.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && [ "$(verdict_of "$RID")" = "PASS" ] && ok "with a --note naming the failing test and why, the PASS is recorded" || { bad "expected-red, note: rc=$RC"; cat "$T/v.txt"; }
printf '# Plan\n## Phase 1 - tests first\nExecutor: deepseek-flash\nFiles: a.py\nAcceptance:\n- `no-such-command-zq7` (fails until phase 2)\n' > "$R/PLAN_T.md"; approve PLAN_T.md "$R" || exit 1
run 'echo z >> a.py'; RID=$(rid)
$DP --verdict "$RID" PASS --note "no-such-command-zq7 fails: not written yet" --repo "$R" > "$T/v.txt" 2>&1; RC=$?
[ "$(meta "$RID" acceptance_after_rc)" = "[127]" ] && [ $RC -ne 0 ] && [ "$(verdict_of "$RID")" = "None" ] \
  && ok "an expected-red command that exits 127 (not runnable) is not red: PASS refused even with a --note" || { bad "exit 127: rc=$RC verdict=$(verdict_of "$RID") after=$(meta "$RID" acceptance_after_rc)"; cat "$T/v.txt"; }

echo "== no changes"
newrepo 'grep -q y a.py'; run 'true'
line "NO CHANGES:" "without changing any file" && ok "exit 0 without changes -> NO CHANGES line" || { bad "no NO CHANGES line"; head -12 "$T/out.txt"; }
newrepo 'grep -q y a.py'; run 'echo y >> a.py'
! has "NO CHANGES" && ok "run with changes has no NO CHANGES line" || bad "false NO CHANGES"

echo "== review skips generated files"
newrepo 'true'
run 'echo "x = 2" > a.py; mkdir -p __pycache__ .pytest_cache/v; printf "\000\001" > __pycache__/a.cpython-313.pyc; echo "[]" > .pytest_cache/v/nodeids'
RID=$(rid)
$DP --review "$RID" --via qwen --model fake/m --dry-run --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "files ['a.py']" && ! has "__pycache__" && ! has ".pytest_cache" \
  && ok "review file list leaves out cache files the run created (generated)" || { bad "review files rc=$RC: $(grep -o "files \[[^]]*\]" "$T/out.txt")"; }
$DP --review "$RID" --packet --repo "$R" > "$T/out.txt" 2>&1
PK=$(sed -n 's/^PACKET \(.*\)$/\1/p' "$T/out.txt" | head -1)
[ -f "$PK" ] && ! grep -q "__pycache__\|pytest_cache" "$PK" && grep -q "a.py" "$PK" \
  && ok "Opus packet leaves out generated cache files" || bad "packet '$PK' lists cache files"

echo "== review of a committed run (diff base = the run's start commit)"
newrepo 'true'; run 'echo "x = 2" > a.py; echo "n = 1" > new.py'; RID=$(rid)
( cd "$R" && git add a.py new.py && git commit -qm "commit the run" ) || { echo "setup failed: commit"; exit 1; }
$DP --review "$RID" --packet --repo "$R" > "$T/out.txt" 2>&1
PK=$(sed -n 's/^PACKET \(.*\)$/\1/p' "$T/out.txt" | head -1)
[ -f "$PK" ] && grep -q '^+x = 2$' "$PK" && grep -q '^+n = 1$' "$PK" \
  && ok "committed run: the review packet still holds the run's changes (tracked + created file)" || bad "committed run reviewed against an empty diff"
( cd "$R" && git commit -q --amend -m "init rewritten" --allow-empty && git checkout -q --orphan other && git commit -qm orphan ) \
  || { echo "setup failed: orphan"; exit 1; }
$DP --review "$RID" --packet --repo "$R" > "$T/out.txt" 2>&1
PK=$(sed -n 's/^PACKET \(.*\)$/\1/p' "$T/out.txt" | head -1)
[ -f "$PK" ] && grep -q "note: the run's start commit [0-9a-f]\{8\} is not an ancestor of HEAD; each file shows its change since the run's start copy" "$PK" \
  && ok "start commit not an ancestor of HEAD: the start-copy diff is stated in the review task" || bad "no fallback note in the packet"
pyblock <<'PYB'
import importlib.util, subprocess, sys
from pathlib import Path
sys.dont_write_bytecode = True
sp = importlib.util.spec_from_file_location("d", sys.argv[1]); d = importlib.util.module_from_spec(sp); sp.loader.exec_module(d)
repo = Path(sys.argv[2]) / "rb"
g = lambda *a: subprocess.run(["git", "-C", str(repo), *a], capture_output=True, text=True, check=True).stdout.strip()
repo.mkdir()
g("init", "-q", "-b", "main"); g("config", "user.email", "t@t"); g("config", "user.name", "t")
(repo / "f").write_text("1\n"); g("add", "f"); g("commit", "-qm", "c1"); c1 = g("rev-parse", "HEAD")
(repo / "f").write_text("2\n"); g("commit", "-qam", "c2")
g("checkout", "-q", "--orphan", "o"); g("commit", "-qm", "orphan"); orphan = g("rev-parse", "HEAD"); g("checkout", "-q", "main")
cases = [({"head_before": c1}, c1),                      # ancestor of HEAD -> the run's start commit
         ({"head_before": g("rev-parse", "HEAD")}, g("rev-parse", "HEAD")),   # not committed yet: HEAD's own sha
         ({}, "HEAD"), ({"head_before": ""}, "HEAD"), ({"head_before": 5}, "HEAD"),
         ({"head_before": "de" * 20}, "HEAD"),           # missing object
         ({"head_before": orphan}, "HEAD")]              # exists, not an ancestor
bad = [(m, want, d.run_diff_base(repo, m)) for m, want in cases if d.run_diff_base(repo, m) != want]
print("  ok   run_diff_base: ancestor / missing / empty / non-str / not-ancestor cases" if not bad else f"  FAIL run_diff_base {bad}")
sys.exit(1 if bad else 0)
PYB

echo "== diff hunk parsing (post-filter anchors)"
pyblock <<'EOF'
import importlib.util, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("d", sys.argv[1]); d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
problems = []
body_hdr = "--- a/a.py\n+++ b/a.py\n@@ -1,2 +1,2 @@\n x\n--- x\n+++ y\n@@ -5,1 +5,1 @@\n-p\n+q\n"
if d.diff_hunks(body_hdr) != {"a.py": [(1, 2), (5, 5)]}:
    problems.append(f"content lines parsed as headers: {d.diff_hunks(body_hdr)!r}")
q = 'diff --git "a/caf\\303\\251.py" "b/caf\\303\\251.py"\n--- "a/caf\\303\\251.py"\n+++ "b/caf\\303\\251.py"\n@@ -1,1 +1,2 @@\n x\n+y\n'
if d.diff_hunks(q) != {"café.py": [(1, 2)]}:
    problems.append(f"quoted non-ASCII path: {d.diff_hunks(q)!r}")
for gone in ("filter_findings", "parse_review", "merge_findings", "merge_finding_dicts", "segment_files",
             "run_segmented_review", "latest_reviewed_ancestor"):
    if hasattr(d, gone):
        problems.append(f"{gone} still defined")
print("  ok   diff_hunks: header-like content lines, quoted non-ASCII paths; removed review helpers are gone"
      if not problems else "  FAIL diff hunks / removals: " + "; ".join(problems))
sys.exit(1 if problems else 0)
EOF
newrepo 'grep -q y a.py'; run 'echo y >> a.py'; RID=$(rid)
cat > "$T/rev.txt" <<'EOF'
REVIEW-JSON
{"findings": [
 {"severity": "HIGH", "path": "a.py", "line": 2, "problem": "off by one", "fix": "Use <=", "repro": {"input": "i", "expected": "e", "actual": "a"}},
 {"severity": "HIGH", "path": "a.py", "line": 40, "problem": "unchecked index", "fix": "Guard it", "repro": {"input": "i", "expected": "e", "actual": "a"}},
 {"severity": "BLOCKER", "path": "a.py", "line": 2, "problem": "missing guard", "fix": "Add a TODO to handle it later", "repro": {"input": "i", "expected": "e", "actual": "a"}},
 {"severity": "HIGH", "path": "a.py", "line": 2, "problem": "dead branch", "fix": "Remove lines 2-3", "repro": {"input": "i", "expected": "e", "actual": "a"}},
 {"severity": "HIGH", "path": "other.py", "line": 1, "problem": "wrong file", "fix": "Fix it", "repro": {"input": "i", "expected": "e", "actual": "a"}}
 ], "clauses": [], "tests": [], "verdict": "BLOCK"}
END-REVIEW-JSON
EOF
record "$RID" reviewer-opus55 "$T/rev.txt" "$R" > /dev/null 2>&1
N1=$(python3 -I -c "import json,sys; print(len(json.load(open(sys.argv[1]))['reviews']))" "$R/.git/concord/$RID/meta.json")
rm "$R/a.py"; record "$RID" reviewer-opus55 "$T/rev.txt" "$R" > "$T/rr.txt" 2>&1; RR=$?
python3 -I -c "import json,sys; rs=json.load(open(sys.argv[1]))['reviews']; r=rs[-1]; sys.exit(0 if len(rs)==int(sys.argv[2])+1 and r.get('highs')==4 and r.get('blockers')==1 else 1)" "$R/.git/concord/$RID/meta.json" "$N1" && [ $RR -eq 0 ] \
  && ok "review record on a run whose files are gone is recorded (exit 0) and keeps findings as written" || { bad "no-files record rc=$RR"; cat "$T/rr.txt"; }

echo; echo "passed $pass, failed $fail"; rm -rf "$T"; [ $fail -eq 0 ]
