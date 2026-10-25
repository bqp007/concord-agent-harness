#!/bin/bash
# concord.py regression (19 checks, ~20 s, no network, fake qwen executor): report lines for in-scope, out-of-scope,
# deleted, staged, plan-modified and git-internal changes; red-run refusal (exit 6); --restore; billing guard (exit 5);
# OpenCode permission set (Code Mode, subagents, web search denied; version and project config pinned);
# OUTSIDE CHECKOUT CHANGED for home config, dispatcher files, the main checkout's rule files and linked folders.
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
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
newrepo(){ rm -rf "$R"; mkdir -p "$R"; (
  cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > a.py; printf 'y = 2\n' > b.py; printf 'z = 3\n' > c.py; printf '.claude/\n' > .gitignore
  git add -A && git commit -qm init
  printf '# Plan\n## Phase 1 - change a\nExecutor: deepseek-flash\nFiles: a.py\nAcceptance:\n- `grep -q y a.py`\n' > PLAN_T.md
); }
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
python3 -I - "$T/concord/concord.py" "$T" <<'EOF'
import importlib.util, json, sys
from pathlib import Path
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("d", sys.argv[1]); d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
problems = []
for mode in ("readonly", "edit", "full"):
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
    if mode == "edit" and perm.get("bash") != "deny":
        problems.append(f"edit: bash={perm.get('bash')!r}")
    if mode == "full" and (not isinstance(perm.get("bash"), dict) or perm["bash"].get("git push*") != "deny"
                           or perm["bash"].get("*") != "allow"):
        problems.append(f"full: bash deny rules lost ({perm.get('bash')!r})")
    if mode in ("full", "edit") and perm.get("webfetch") != "deny":
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
W="$R/.claude/worktrees/T1"; cp "$R/PLAN_T.md" "$W/"
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
assert not d.review_refusals("429: " + limit, "pi", 0) and not d.transport_error("503: fetch failed", "pi", 0), "pi answer"
assert d.review_refusals("Error: " + limit) and not d.review_refusals("429: " + limit), "OpenCode: only Error: lines"
assert d.billing("pi", "github-copilot/gpt-5") == "pi's own login/key", d.billing("pi", "github-copilot/gpt-5")
assert d.billing("pi", "opencode-go/x") == "OpenCode Go subscription allowance"
EOF
FAKE_ACTIONS="echo 'Free usage limit reached. Free models work in OpenCode' >&2; exit 1" \
  $DP --review "$(basename "$X")" --via pi --model opencode-go/x --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 9 ] && has "PROVIDER LIMIT" && ok "a pi review that fails with a bare provider limit is a refusal (exit 9, nothing recorded)" \
  || { bad "pi review refusal rc=$RC"; tail -4 "$T/out.txt"; }

echo; echo "passed $pass, failed $fail"; rm -rf "$T"; [ $fail -eq 0 ]
