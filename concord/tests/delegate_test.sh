#!/bin/bash
# concord.py regression (36 checks, ~15 s, no network, fake qwen executor): report lines for in-scope, out-of-scope,
# deleted, staged, plan-modified and git-internal changes; red-run refusal (exit 6); --restore; billing guard (exit 5);
# the run watchdog (memory cap, free-disk floor; the memory check needs ps, which Claude Code's own sandbox denies);
# OpenCode permission set (Code Mode, subagents, web search denied; version and project config pinned);
# OUTSIDE CHECKOUT CHANGED for home config, dispatcher files, the main checkout's rule files and linked folders;
# an executor name wins over a model alias; --estimate lanes, critical path and ETA relation (no pinned minutes).
# Run: bash ~/.claude/concord/tests/delegate_test.sh   (exit 0 = all passed). Tests the dispatcher this file belongs to,
# copied into a temp dir with HOME pointing at a temp home, so runs.jsonl and the real config stay untouched.
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/dl-test.XXXXXX")" && pwd -P)"; export T
mkdir -p "$T/bin" "$T/concord" "$T/home/.claude"
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
printf '#!/bin/sh\nsh -c "${FAKE_ACTIONS:-true}"\n' > "$T/bin/qwen"; chmod +x "$T/bin/qwen"
# The /usr/bin git and python3 are xcrun shims; inside the macOS sandbox xcrun cannot write its cache and prints
# "couldn't create cache file" on stderr, which pollutes captured output. Prefer the developer dir's real binaries.
XDEV="$(xcode-select -p 2>/dev/null)"; [ -n "$XDEV" ] && [ -x "$XDEV/usr/bin/git" ] && [ -x "$XDEV/usr/bin/python3" ] && export PATH="$XDEV/usr/bin:$PATH"
export PATH="$T/bin:$PATH" HOME="$T/home"
DP="python3 $T/concord/concord.py"; WT="python3 $T/concord/wt.py"
R="$T/repo"; export R
. "$(dirname "$0")/lib.sh"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
newrepo(){ rm -rf "$R"; mkdir -p "$R"; (
  cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > a.py; printf 'y = 2\n' > b.py; printf 'z = 3\n' > c.py; printf '.claude/\n' > .gitignore
  git add -A && git commit -qm init
  printf '# Plan\n## Phase 1 - change a\nExecutor: deepseek-flash\nFiles: a.py\nAcceptance:\n- `grep -q y a.py`\n' > PLAN_T.md
); approve PLAN_T.md "$R" || exit 1; }
run(){ FAKE_ACTIONS="$1" $DP 1 --plan PLAN_T.md --via qwen --model fake/m --no-baseline --repo "${2:-$R}" > "$T/out.txt" 2>&1; }
has(){ grep -F -- "$1" "$T/out.txt" > /dev/null; }               # literal substring anywhere in the last output
line(){ grep "^$1" "$T/out.txt" | grep -F -- "$2" > /dev/null; }  # literal substring on the line starting with $1

echo "== report lines"
newrepo; run 'echo y >> a.py'; RC=$?
[ $RC -eq 0 ] && line "changed in scope:" "a.py" && line "OUT OF SCOPE (source):" "none" \
  && ok "in-scope edit reported, nothing out of scope" || { bad "in-scope run rc=$RC"; tail -8 "$T/out.txt"; }
! has "OUTSIDE CHECKOUT CHANGED" && ok "clean run has no OUTSIDE CHECKOUT CHANGED line" || bad "false outside flag: $(grep OUTSIDE "$T/out.txt")"
RID=$(sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)
$DP --restore "$RID" --repo "$R" > "$T/rs.txt" 2>&1
[ "$(cat "$R/a.py")" = "x = 1" ] && ok "--restore puts the backed-up a.py back" || { bad "restore ($RID)"; cat "$T/rs.txt"; }
newrepo; run 'echo y >> a.py; echo w >> b.py; rm c.py; git add a.py; echo "# edited" >> PLAN_T.md; echo hook > .git/hooks/pre-commit'
line "OUT OF SCOPE (source):" "b.py" && ok "out-of-scope edit reported" || { bad "out of scope"; grep -i "scope" "$T/out.txt"; }
line "DELETED:" "c.py" && ok "deletion reported" || bad "deleted: $(grep '^DELETED' "$T/out.txt")"
line "STAGED BY EXECUTOR:" "a.py" && ok "staged edit reported" || bad "staged: $(grep -i staged "$T/out.txt")"
has "PLAN FILE MODIFIED" && ok "plan edit reported" || bad "plan modified not reported"
line "GIT INTERNALS CHANGED:" ".git/hooks/pre-commit (new)" && ok "new git hook reported" || bad "internals: $(grep -i internals "$T/out.txt")"

echo "== guards"
newrepo; echo y >> "$R/a.py"; git -C "$R" commit -qam "a already has y"
FAKE_ACTIONS='touch ran.txt' $DP 1 --plan PLAN_T.md --via qwen --model fake/m --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 6 ] && [ ! -e "$R/ran.txt" ] && has "NOT RUN" && ok "red run: acceptance already passes -> exit 6, executor never started" \
  || { bad "red run rc=$RC"; tail -4 "$T/out.txt"; }
newrepo; FAKE_ACTIONS='touch ran.txt' $DP 1 --plan PLAN_T.md --via qwen --model anthropic/claude-sonnet-5 --no-baseline --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 5 ] && [ ! -e "$R/ran.txt" ] && ok "billing guard: Claude model on a harness -> exit 5" || { bad "billing guard rc=$RC"; tail -3 "$T/out.txt"; }
newrepo; FAKE_MARK=zzmark9 $DP qwen 1 --plan PLAN_T.md --model fake/m --dry-run --no-baseline --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && grep -q '^executor: qwen -> qwen ' "$T/out.txt" && sed -n 's/^cmd: //p' "$T/out.txt" | python3 -I -c 'import json,sys; a=json.load(sys.stdin); sys.exit(0 if a[0].endswith("/qwen") else 1)' \
  && ok "an executor name wins over a model alias: concord.py qwen 1 runs the qwen harness, not the qwen model alias" || { bad "qwen word rc=$RC"; grep -e '^executor' -e '^cmd' "$T/out.txt" | cut -c1-200; }
grep -E '^environment names passed to the executor: .*\bPATH\b' "$T/out.txt" | grep -q 'FAKE_MARK' && ! grep -q 'zzmark9' "$T/out.txt" \
  && ok "a dry run prints the environment names passed to the executor, names only, never values" || { bad "dry run environment names"; grep -i 'environment' "$T/out.txt"; }
python3 -I - "$T/concord/concord.py" "$T" <<'EOF'
import importlib.util, json, sys
from pathlib import Path
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("d", sys.argv[1]); d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
problems = []
for mode in ("readonly", "full"):
    cmd, env, _ = d.build_command("opencode", "/bin/true", "task", "contract", "opencode-go/x", mode, "30m",
                                  Path(sys.argv[2]), {}, allow_edit=["a.py"])
    perm = json.loads(env["OPENCODE_CONFIG_CONTENT"])["permission"]
    problems += [f"{mode}: {k}={perm.get(k)!r}" for k in ("execute", "task", "websearch") if perm.get(k) != "deny"]
    problems += [f"{mode}: env {k}={env.get(k)!r}" for k in ("OPENCODE_DISABLE_AUTOUPDATE", "OPENCODE_DISABLE_PROJECT_CONFIG")
                 if env.get(k) != "1"]
    if mode == "readonly":
        problems += [f"readonly: {k}={perm.get(k)!r}" for k in ("edit", "bash", "webfetch") if perm.get(k) != "deny"]
    else:
        edit = perm.get("edit") if isinstance(perm.get("edit"), dict) else {}
        if edit.get("*") != "deny" or edit.get("a.py") != "allow":
            problems.append(f"{mode}: edit scope lost ({perm.get('edit')!r})")
    if mode == "full" and (not isinstance(perm.get("bash"), dict) or perm["bash"].get("git push*") != "deny"
                           or perm["bash"].get("*") != "allow"):
        problems.append(f"full: bash deny rules lost ({perm.get('bash')!r})")
    if mode == "full" and perm.get("webfetch") != "deny":
        problems.append(f"{mode}: webfetch not denied by default")
    if perm.get("external_directory") != "deny":
        problems.append(f"{mode}: external_directory not denied")
print("  ok   OpenCode: Code Mode, subagents, web search denied in every mode; autoupdate + project config off"
      if not problems else "  FAIL OpenCode permission set: " + "; ".join(problems))
sys.exit(1 if problems else 0)
EOF
[ $? -eq 0 ] && pass=$((pass+1)) || fail=$((fail+1))

echo "== OUTSIDE CHECKOUT CHANGED"
newrepo; printf 'rules\n' > "$HOME/.claude/CLAUDE.md"
run 'echo y >> a.py; echo hacked >> "$HOME/.claude/CLAUDE.md"; echo "# x" >> "$T/concord/CONTRACT.md"; mkdir -p "$HOME/.claude/agents" && echo x > "$HOME/.claude/agents/evil.md"'
line "OUTSIDE CHECKOUT CHANGED:" "~/.claude/CLAUDE.md (modified)" && ok "edit of a home config file reported" \
  || { bad "home config edit not reported"; grep -i outside "$T/out.txt"; }
line "OUTSIDE CHECKOUT CHANGED:" "$T/concord/CONTRACT.md (modified)" && ok "edit of a dispatcher file reported" || bad "dispatcher edit not reported"
line "OUTSIDE CHECKOUT CHANGED:" "~/.claude/agents/evil.md (new)" && ok "new agent file reported" || bad "new agent file not reported"
cp -p "$SRC/CONTRACT.md" "$T/concord/CONTRACT.md"
newrepo; mkdir -p "$R/data" "$R/.claude" && printf 'd\n' > "$R/data/old.csv" && echo "data/" >> "$R/.git/info/exclude"
printf -- '---\nname: t\nenabled: true\nevent: bash\npattern: never-matches-xyz\n---\nx\n' > "$R/.claude/hookify.t.local.md"
$WT new T1 --repo "$R" --no-fetch --base main --link data > "$T/n.txt" 2>&1 || { bad "wt.py new failed"; cat "$T/n.txt"; }
W="$R/.claude/worktrees/T1"; cp "$R/PLAN_T.md" "$W/"; approve PLAN_T.md "$W" || exit 1       # a worktree is its own ticket
run 'echo y >> a.py' "$W"
! has "OUTSIDE CHECKOUT CHANGED" && line "changed in scope:" "a.py" && ok "clean worktree run has no OUTSIDE CHECKOUT CHANGED line" \
  || { bad "worktree clean run: $(grep -e '^OUTSIDE' -e '^status' "$T/out.txt")"; }
run 'echo y >> a.py; echo z > data/new.csv; mkdir -p data/__pycache__ && echo c > data/__pycache__/m.pyc; echo x >> "$R/.claude/hookify.t.local.md"' "$W"
line "OUTSIDE CHECKOUT CHANGED:" "data/new.csv (linked folder)" && ok "write through a linked folder into the main checkout reported" \
  || { bad "linked-folder write not reported"; grep -i -e outside -e status "$T/out.txt"; }
! grep "^OUTSIDE CHECKOUT CHANGED:" "$T/out.txt" | grep -q "__pycache__" && ok "cache output inside linked folders not reported" \
  || bad "cache output reported: $(grep '^OUTSIDE' "$T/out.txt")"
line "OUTSIDE CHECKOUT CHANGED:" "$R/.claude/hookify.t.local.md (modified)" && ok "edit of the main checkout's rule file from a worktree run reported" \
  || bad "main rule file edit not reported"

echo "== run begun by an older version (state without stored hashes)"
newrepo
$DP --begin 1 --label planner --plan PLAN_T.md --repo "$R" > "$T/b.txt" 2>&1
BID=$(sed -n 's/.*concord.py --end \([^ ]*\).*/\1/p' "$T/b.txt" | tail -1)
python3 -I - "$R/.git/concord/$BID/state.json" <<'EOF'
import json, sys
st = json.load(open(sys.argv[1])); st.pop("outside", None); json.dump(st, open(sys.argv[1], "w"))
EOF
echo y >> "$R/a.py"
$DP --end "$BID" --repo "$R" > "$T/out.txt" 2>&1
line "changed in scope:" "a.py" && ! has "OUTSIDE CHECKOUT CHANGED" && ok "no stored hashes -> no OUTSIDE line (no flood of '(new)' entries)" \
  || { bad "old-state run ($BID): $(grep -o '(new)' "$T/out.txt" | wc -l | tr -d ' ') '(new)' entries"; grep '^OUTSIDE' "$T/out.txt" | cut -c1-160; }

echo "== pi adapter (kit-pi): key file, offline, own agent folder, session in the run, :thinking suffix, cost"
mkdir -p "$HOME/.config/concord-keys" "$HOME/.pi/agent"; printf 'test-key-\n   123 \n' > "$HOME/.config/concord-keys/opencode.key"    # a wrapped paste
for f in models.json models-store.json settings.json; do printf '{}\n' > "$HOME/.pi/agent/$f"; done
cat > "$T/bin/pi" <<'PI'
#!/bin/sh
d=""; prev=""; for a in "$@"; do [ "$prev" = "--session-dir" ] && d="$a"; prev="$a"; done
mkdir -p "$d" && printf '%s\n' "$@" > "$d/argv.txt"
{ [ "$OPENCODE_API_KEY" = test-key-123 ] && echo key-ok; echo "offline=$PI_OFFLINE"; [ -f "$PI_CODING_AGENT_DIR/models.json" ] && [ -f "$PI_CODING_AGENT_DIR/models-store.json" ] && [ -f "$PI_CODING_AGENT_DIR/settings.json" ] && echo agent-ok; } > "$d/env.txt"
printf '{"type":"message","message":{"role":"assistant","usage":{"input":100,"output":20,"cacheRead":5,"cacheWrite":0,"totalTokens":125,"cost":{"input":0.01,"output":0.0023,"cacheRead":0,"cacheWrite":0,"total":0.0123}}}}\n' > "$d/s.jsonl"
sh -c "${FAKE_ACTIONS:-true}"
PI
chmod +x "$T/bin/pi"
newrepo; FAKE_ACTIONS="echo 'y = 9' >> a.py" $DP 1 --plan PLAN_T.md --via pi --model opencode-go/x#high --no-baseline --repo "$R" > "$T/out.txt" 2>&1; RC=$?
X="$R/.git/concord/$(sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1)"; S="$X/pi"
grep -qxF "opencode-go/x:high" "$S/argv.txt" 2>/dev/null && grep -qxF -- "$S" "$S/argv.txt" && ! grep -qx -- "--no-session" "$S/argv.txt" \
  && ok "pi gets --model provider/id:high and --session-dir <run>/pi" || { bad "pi argv rc=$RC"; cat "$S/argv.txt" 2>/dev/null | head -20; tail -3 "$T/out.txt"; }
[ "$(tr '\n' ' ' < "$S/env.txt" 2>/dev/null)" = "key-ok offline=1 agent-ok " ] && ! grep -rqF test-key-123 "$X" \
  && ok "pi gets the key file's key, PI_OFFLINE=1 and its own agent folder with models.json; the run folder never holds the key" \
  || { bad "pi env: $(tr '\n' ' ' < "$S/env.txt" 2>/dev/null)"; grep -rlF test-key-123 "$X"; }
grep -qF '$0.0123' "$X/report.md" "$T/out.txt" 2>/dev/null && ok "the report shows the pi session's cost" || { bad "pi cost"; grep -iE 'cost|token' "$X/report.md" | head -3; }
python3 -I - "$T/concord/concord.py" <<'EOF' && ok "a failed pi run's bare lines are errors, a passed pi run's answer never is; OpenCode counts only Error: lines; pi billing labels" || bad "pi error lines or billing"
import importlib.util, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("d", sys.argv[1]); d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
limit = "Free usage limit reached. Free models work in OpenCode"
assert d.review_refusals(limit, "pi", 1) and d.transport_error("fetch failed", "pi", 1), "bare lines of a failed pi run"
assert not d.review_refusals(f"429: {limit}\nError: {limit}", "pi", 0) and not d.transport_error("Error: fetch failed", "pi", 0), "pi answer"
assert d.review_refusals("Error: " + limit) and not d.review_refusals("429: " + limit), "OpenCode: only Error: lines"
assert d.billing("pi", "github-copilot/gpt-5") == "pi's own login/key", d.billing("pi", "github-copilot/gpt-5")
assert d.billing("pi", "opencode-go/x") == "OpenCode Go subscription allowance"
EOF
FAKE_ACTIONS="echo 'Free usage limit reached. Free models work in OpenCode' >&2; exit 1" \
  $DP --review "$(basename "$X")" --via pi --model opencode-go/x --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 9 ] && has "PROVIDER LIMIT" && ok "a pi review that fails with a bare provider limit is a refusal (exit 9, nothing recorded)" \
  || { bad "pi review refusal rc=$RC"; tail -4 "$T/out.txt"; }

echo "== free-model routing: Zen free models answer pi with 429, so they stay on OpenCode; beam runs on pi"
R2=$(while read -r m e; do $DP --resolve "$m" 2>/dev/null | grep -qF "\"executor\": \"$e\"" || printf ' %s' "$m"; done <<'EOF'
free-deepseek-flash opencode
free-glm-flash opencode
opencode/deepseek-v4.1-flash-free#high opencode
opencode/beam-free opencode
beam pi
opencode-go/beam-free pi
opencode/glm-5.3 pi
EOF
)
[ -z "$R2" ] && ok "Zen free names and raw opencode/...-free IDs resolve to OpenCode; beam and the other Go and Zen IDs to pi" \
  || bad "routing:$R2"
python3 -I - "$T/concord/concord.py" <<'EOF' && ok "--models --verify checks OpenCode and pi lines, ignores an #effort suffix and marks no line of a catalog it cannot reach" || bad "models verify"
import contextlib, importlib.util, io, json, sys, urllib.request
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("d", sys.argv[1]); d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
cat = json.dumps({"data": [{"id": "deepseek-v4.1-flash-free"}, {"id": "beam-free"}]}).encode()
def models(go_up):
    def urlopen(req, timeout=0):
        if not go_up and "/go/" in req.full_url:
            raise OSError("offline")
        return io.BytesIO(cat)
    urllib.request.urlopen, out = urlopen, io.StringIO()
    with contextlib.redirect_stdout(out): d.cmd_models(True, None)
    return {l.split()[0]: l for l in out.getvalue().splitlines() if l.strip()}
names = ("free-deepseek-flash", "beam")      # a Zen free line on OpenCode, a Go line on pi
up, down = models(True), models(False)
assert all(up[n].endswith("[available]") for n in names), [up[n] for n in names]
assert down["free-deepseek-flash"].endswith("[available]") and "[" not in down["beam"], down["beam"]
EOF

# Watchdog: memory above mem_cap_mib stops the run's whole process tree, including a child in a process group of its
# own (OpenCode and pi start shell commands that way); free disk below disk_floor_gib refuses the start or stops the run.
cp -p "$T/concord/executors.conf" "$T/conf.bak"
cat > "$T/hog.py" <<'EOF'
import subprocess, sys, time
if sys.argv[1:] == ["child"]:
    held = b"x" * (300 << 20)
    time.sleep(10)
else:
    subprocess.run([sys.executable, __file__, "child"], start_new_session=True)
EOF
if ps -A -o pid= > /dev/null 2>&1; then
  newrepo; printf 'mem_cap_mib = 100\n' >> "$T/concord/executors.conf"; s=$SECONDS
  run "python3 $T/hog.py"; e=$((SECONDS - s)); sleep 1
  has "status: RESOURCE" && has "RESOURCE LIMIT: memory" && [ $e -lt 8 ] && ! pgrep -f "$T/hog.py child" > /dev/null \
    && ok "W.1 memory above the cap stops the run and its detached child (${e}s)" \
    || { bad "W.1 memory watchdog (${e}s)"; head -5 "$T/out.txt"; }
  cp -p "$T/conf.bak" "$T/concord/executors.conf"
else
  echo "  skip W.1 (ps cannot list processes here)"
fi
newrepo; printf 'disk_floor_gib = 1000000\n' >> "$T/concord/executors.conf"; run 'touch ran.txt'
has "status: RESOURCE" && has "RESOURCE LIMIT: free disk" && has "did not start" && [ ! -e "$R/ran.txt" ] \
  && ok "W.2 free disk below the floor: the run does not start" || { bad "W.2 disk floor at start"; head -5 "$T/out.txt"; }
cp -p "$T/conf.bak" "$T/concord/executors.conf"
python3 -I - "$T/concord/concord.py" "$T" <<'EOF' && ok "W.3 free disk falling below the floor stops a running run" || bad "W.3 disk floor mid-run"
import collections, importlib.util, os, pathlib, shutil, sys, time
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("d", sys.argv[1]); d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
calls = []
def disk_usage(path):                  # 100 GiB free for the start check and the first poll, then 1 GiB
    calls.append(path)
    return collections.namedtuple("Usage", "total used free")(1 << 40, 0, (100 if len(calls) < 3 else 1) << 30)
shutil.disk_usage = disk_usage
log = pathlib.Path(sys.argv[2]) / "w3.log"
t = time.time(); rc, _ = d.run_process(["sleep", "8"], dict(os.environ), sys.argv[2], log, 60)
assert rc == d.RESOURCE_RC and time.time() - t < 5 and "RESOURCE LIMIT: free disk 1.0 GiB" in log.read_text(), \
    (rc, time.time() - t, log.read_text())
EOF

echo "== --estimate: lanes, critical path, ETA relation, lint (no pinned minutes)"
newrepo
python3 -I -c 'import json, sys
r = [dict(run_id=f"f{i}", name="deepseek-flash", verdict="PASS", seconds=300 + 50 * i, diff_lines=180) for i in range(6)]
r += [dict(run_id=f"p{i}", name="planner", verdict="PASS", seconds=60 * (i + 1)) for i in range(6)]
r += [dict(run_id="x", name="deepseek-flash", verdict="FAIL", seconds=9000), dict(run_id="y", name="deepseek-flash", seconds=9000)]
open(sys.argv[1], "w").write("".join(json.dumps(x) + "\n" for x in r))' "$T/concord/runs.jsonl"
ph(){ printf '\n## Phase %s - p%s\nExecutor: %s\n%b\n' "$1" "$1" "$2" "$3"; }
{ printf '# Plan\nTier: M\nSize: ~1500 lines\nETA: 100 min\n'; ph 1 planner 'Size: ~90 lines\nFiles: t.sh'
  ph 2 deepseek-flash 'Risk: high\nSize: ~360 lines\nAfter: 1 (needs its tests)\nFiles: a.py'
  ph 3 deepseek-flash 'Size: ~180 lines\nAfter: 1\nFiles: a.py, b.py'; ph 4 deepseek-flash 'Size: ~40 lines\nAfter: 2 (shares a.py)\nFiles: c.py'
  ph 5 deepseek-flash 'Size: ~600 lines\nAfter: 3 (shares b.py)\nFiles: b.py'; ph 6 deepseek-flash 'Files: d.py'
  ph 7 glm-flash 'Size: ~180 lines\nFiles: e.py'; } > "$R/PLAN_E.md"
$DP --estimate --plan PLAN_E.md --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && line "ESTIMATE" "PLAN_E.md" && python3 -I -c 'import json,sys; v=[t for t in json.load(open(sys.argv[1]))["tickets"].values() if t["plan"] == "PLAN_E.md"][0]["estimate"]; assert isinstance(v, int) and v > 0' \
  "$R/.git/concord/drift.json" 2>/dev/null && ok "E.1 --estimate exits 0, names the plan and stores an integer ETA for the drift gate" || { bad "E.1 rc=$RC"; tail -5 "$T/out.txt"; }
grep -Eqx "Phase 1 planner [0-9]+ min ──> Phase 2 deepseek-flash [0-9]+ min ──> Phase 4 deepseek-flash [0-9]+ min" "$T/out.txt" \
  && grep -Eqx "Phase 3 deepseek-flash [0-9]+ min ──> Phase 5 deepseek-flash [0-9]+ min" "$T/out.txt" \
  && grep -Eqx "Phase 6 deepseek-flash [0-9]+ min" "$T/out.txt" \
  && ok "E.4 PASSES: one lane per line; a phase continues the lane of its latest-finishing wait once" || { bad "E.4 lanes"; sed -n '/^PASSES/,/^CRITICAL/p' "$T/out.txt"; }
eta_rel(){ python3 -I - "$T/out.txt" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
m = re.search(r"^CRITICAL PATH: .*= (\d+) min; session lane (\d+) min; final revision (\d+) min$", t, re.M); e = re.search(r"^ETA: (\d+) min, lands at [0-2]\d:[0-5]\d local$", t, re.M)
sys.exit(0 if m and e and int(e.group(1)) == max(int(m.group(1)), int(m.group(2))) + int(m.group(3)) else 1)
PY
}
grep -Eq "^CRITICAL PATH: 1 → 3 → 5 = [0-9]+ min;" "$T/out.txt" && eta_rel \
  && ok "E.3 critical path from After: waits (1 -> 3 -> 5); ETA = max(critical path, session lane) + final revision" || { bad "E.3 path/ETA"; grep -E "^(CRITICAL|ETA)" "$T/out.txt"; }
miss=""
for want in "Phase 3 waits for Phase 1 with no reason" "Phases 2 and 3 can run at once and both list a.py" \
            "Phase 4 (~40 lines) is tier S" "Phase 5 (~600 lines) is over 3x" "Phase 6 has no Size: line" \
            "no ledger reference for glm-flash" "the plan says ETA 100 min; computed "; do
  grep "^ESTIMATE LINT: " "$T/out.txt" | grep -qF -- "$want" || miss="$miss [$want]"
done
[ -z "$miss" ] && ! grep "^ESTIMATE LINT: " "$T/out.txt" | grep -qE "Phases (2 and 4|3 and 5|1 and)" \
  && ok "E.5 seven estimate lint lines; no overlap line for phases ordered by After: or with disjoint Files" \
  || { bad "E.5 lint missing:$miss"; grep "^ESTIMATE LINT" "$T/out.txt"; }
{ printf '# Plan\nTier: S\n'; ph 1 planner 'Size: ~1800 lines\nFiles: t.sh'; ph 2 deepseek-flash 'Size: ~180 lines\nFiles: a.py'; } > "$R/PLAN_S.md"
$DP --estimate --plan PLAN_S.md --repo "$R" > "$T/out.txt" 2>&1
LANE=$(sed -nE 's/^CRITICAL PATH: .*= ([0-9]+) min; session lane ([0-9]+) min;.*/\1 \2/p' "$T/out.txt")
eta_rel && [ -n "$LANE" ] && [ "${LANE#* }" -gt "${LANE% *}" ] \
  && ok "E.6 ETA = max(critical path, session lane) + final revision on a plan whose session lane is the longer" || { bad "E.6 session lane"; grep -E "^(CRITICAL|ETA)" "$T/out.txt"; }
{ printf '# Plan\nTier: S\n'; ph 1 planner 'Size: ~180 lines\nFiles: t.sh'; ph 2 deepseek-flash 'Size: ~180 lines\nFiles: a.py'
  ph 3 deepseek-flash 'Size: ~180 lines\nAfter: Phase 1 and 2 (needs both), tests\nFiles: b.py'
  ph 4 deepseek-flash 'Size: ~180 lines\nFiles: src/a*.py'; ph 5 deepseek-flash 'Size: ~180 lines\nFiles: src/*b.py'
  ph 6 deepseek-flash 'Size: ~180 lines\nAfter:\n- 3\n- 4 (shares src/ab.py) and 5 (shares src/ab.py)\nFiles: src/ab.py'; } > "$R/PLAN_A.md"
$DP --estimate --plan PLAN_A.md --repo "$R" > "$T/out.txt" 2>&1
grep -Eq "^CRITICAL PATH: 2 → 3 → 6 = [0-9]+ min;" "$T/out.txt" \
  && grep -qF "ESTIMATE LINT: Phase 3 After: 'tests' names no phase" "$T/out.txt" && [ "$(grep -c "with no reason" "$T/out.txt")" = 1 ] \
  && grep -qF "ESTIMATE LINT: Phase 6 waits for Phase 3 with no reason" "$T/out.txt" && ! grep -qE "Phases [345] and 6 " "$T/out.txt" \
  && grep -qF "ESTIMATE LINT: Phases 4 and 5 can run at once and both list src/*b.py, src/a*.py" "$T/out.txt" \
  && ok "E.7 After: takes Phase, 'and', bullet lines and one reason per phase; an item naming no phase is linted; two globs that can share a file overlap" \
  || { bad "E.7 After forms"; grep -E "^(CRITICAL|ESTIMATE LINT)" "$T/out.txt"; }

echo; echo "passed $pass, failed $fail"; rm -rf "$T"; [ $fail -eq 0 ]
