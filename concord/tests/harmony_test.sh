#!/bin/bash
# One mechanism per concern (2026-10-23, PLAN_kit-harmony; from the workflow review after kit-cpptools): every entry
# point fails closed on hostile input (exit 2, never a traceback), run ids name a run folder and nothing else, plans
# must be UTF-8 (1); the Zen free tier has
# aliases, its own billing label and a PROVIDER LIMIT line (4); --check compares the installed plugin and dispatcher
# with their marketplace source (5); wt.py new cuts from the remote default branch, writes no .git/config, leaves
# nothing behind on failure and git-excludes plan files (6); one Opus reviewer above the low tier (7); --restore never
# overwrites later work and stays in the checkout its run belongs to (8).
# Section 3 (the Interfaces: signature check) went with that check in the lean revision (2026-10-23, kit-lean).
# No network: fake qwen executor and reviewer, a local bare repository as the remote.
# Run: bash ~/.claude/concord/tests/harmony_test.sh [SECTION ...]   (default all; exit 0 = every selected check passed)
set -u
SEL=" ${*:-all} "
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/harmony-test.XXXXXX")" && pwd -P)"; export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/gitbin" "$T/concord" "$T/home/.claude"
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
cat > "$T/bin/qwen" <<'Q'
#!/bin/sh
echo ran >> "$T/qwen_calls"
if [ -n "${FAKE_ACTIONS:-}" ]; then sh -c "$FAKE_ACTIONS"; exit 0; fi
printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n'
Q
chmod +x "$T/bin/qwen"
# Prefer the developer dir's real git/python3 over the /usr/bin xcrun shims (they print cache errors in the sandbox).
XDEV="$(xcode-select -p 2>/dev/null)"; [ -n "$XDEV" ] && [ -x "$XDEV/usr/bin/git" ] && [ -x "$XDEV/usr/bin/python3" ] && export PATH="$XDEV/usr/bin:$PATH"
REALGIT="$(command -v git)"; export REALGIT
# A git that fails `worktree add` after creating the branch and the folder, as a sandboxed config write did (6);
# FAKE_WT_FAIL=2 also leaves a file in the folder. FAKE_RACE=<folder>: right after wt.py's branch-existence check,
# another run cuts the same branch from FAKE_RACE_BASE into <folder>. FAKE_HOLD=<folder> FAKE_HOLD_BRANCH=<branch>: just
# before wt.py's `worktree add`, another run checks out that branch, when it exists, into <folder>.
cat > "$T/gitbin/git" <<'G'
#!/bin/sh
if [ -n "${FAKE_WT_FAIL:-}" ]; then
  case " $* " in *" worktree add "*)
    b=""; prev=""; wtp=""; last=""
    for a in "$@"; do [ "$prev" = "-b" ] && b="$a"; wtp="$last"; last="$a"; prev="$a"; done
    [ -n "$b" ] && "$REALGIT" -C "$2" branch "$b" "$last"
    mkdir -p "$wtp"; [ "$FAKE_WT_FAIL" = 2 ] && echo kept > "$wtp/kept"
    echo "fatal: simulated failure after the branch was made" >&2; exit 128;;
  esac
fi
if [ -n "${FAKE_RACE:-}" ]; then
  case " $* " in *" show-ref --verify --quiet refs/heads/"*)
    "$REALGIT" "$@"; rc=$?; eval "ref=\${$#}"
    "$REALGIT" -C "$2" worktree add -q --no-track -b "${ref#refs/heads/}" "$FAKE_RACE" "$FAKE_RACE_BASE" > /dev/null 2>&1
    exit $rc;;
  esac
fi
if [ -n "${FAKE_HOLD:-}" ]; then
  case " $* " in *" worktree add "*)
    "$REALGIT" -C "$2" show-ref --verify --quiet "refs/heads/$FAKE_HOLD_BRANCH" \
      && "$REALGIT" -C "$2" worktree add -q "$FAKE_HOLD" "$FAKE_HOLD_BRANCH" > /dev/null 2>&1;;
  esac
fi
exec "$REALGIT" "$@"
G
chmod +x "$T/gitbin/git"
export PATH="$T/bin:$PATH" HOME="$T/home"
DP="python3 $T/concord/concord.py"
WT="python3 $T/concord/wt.py"
R="$T/repo"
. "$(dirname "$0")/lib.sh"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
has(){ grep -F -- "$1" "$T/out.txt" > /dev/null; }
sel(){ case "$SEL" in *" all "*|*" $1 "*) return 0;; esac; return 1; }
rid(){ sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$T/out.txt" | head -1; }
calls(){ [ -f "$T/qwen_calls" ] && wc -l < "$T/qwen_calls" | tr -d ' ' || echo 0; }
sha(){ shasum -a 256 "$1" | cut -d' ' -f1; }
gitrepo(){ mkdir -p "$1" && ( cd "$1" && git init -q -b main && git config user.email t@t && git config user.name t ); }
# mkrepo PHASE_TEXT: a.py, a .gitignore and PLAN_T.md holding "# Plan" and PHASE_TEXT (printf %s, so no escapes)
mkrepo(){ rm -rf "$R"; gitrepo "$R"; ( cd "$R" && printf 'x = 1\n' > a.py && printf '.claude/\n' > .gitignore &&
  git add -A && git commit -qm init && printf '# Plan\n%s\n' "$1" > PLAN_T.md ); approve PLAN_T.md "$R" || exit 1; }
run(){ FAKE_ACTIONS="$1" $DP 1 --plan PLAN_T.md --via qwen --model fake/m --no-baseline --repo "$R" > "$T/out.txt" 2>&1; }
# fc ARGS: concord.py on $R; true when it exits 2 without a Python traceback
fc(){ $DP "$@" --repo "$R" > "$T/out.txt" 2>&1; RC=$?; [ $RC -eq 2 ] && ! has "Traceback (most recent call last)"; }
LONG=$(printf 'a%.0s' $(seq 300))
BASIC='## Phase 1 - change a (P1 <- S1)
Executor: deepseek-flash
Risk: low
Files: a.py
Acceptance:
- `grep -q y a.py`'

if sel 1; then
echo "== 1 hostile input: run ids name a run folder and nothing else; plans are UTF-8 files; exit 2, no traceback"
mkrepo "$BASIC"
mkdir -p "$T/outside" && printf '{"phase": "1", "repo": "x"}\n' > "$T/outside/meta.json" && printf '{}\n' > "$T/outside/state.json" \
  && printf 'r\n' > "$T/outside/report.md" && printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n' > "$T/clean.txt"
tree_sha(){ ( cd "$1" && find . -type f | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 ); }
OUT_SHA=$(tree_sha "$T/outside")
# runid NAME ARGS: ARGS with @ replaced by each hostile run id; each must exit 2 with "no such run"
runid(){ local name=$1 v a n=0; shift
  for v in "$LONG" .. . a/b "$T/outside"; do
    local args=(); for a in "$@"; do if [ "$a" = @ ]; then args+=("$v"); else args+=("$a"); fi; done
    fc "${args[@]}" && has "no such run" || { n=$((n+1)); echo "    $name '${v:0:24}': rc=$RC $(tail -1 "$T/out.txt" | cut -c1-100)"; }
  done
  [ $n -eq 0 ] && ok "1 $name: an over-long name, '..', '.', 'a/b' and an outside folder exit 2 'no such run'" || bad "1 $name ($n of 5 values)"; }
runid --show --show @
runid --restore --restore @
runid --mutate --mutate @
runid --end --end @
runid --abort --abort @
runid --verdict --verdict @ PASS
runid --review-record --review-record @ --reviewer x --file "$T/clean.txt"
runid "--review --packet" --review @ --packet
# On a case-insensitive filesystem (the macOS default) LEDGER and Ledger name the review ledger folder.
mkdir -p "$R/.git/concord/ledger"; n=0
for args in "--show Ledger" "--restore LEDGER" "--mutate LEDGER" "--end LEDGER" "--abort LEDGER" \
  "--verdict LEDGER PASS" "--review-record LEDGER --reviewer x --file $T/clean.txt" "--review Ledger --packet"; do
  fc $args && { has "no such run" || has "ledger is not a run"; } || { n=$((n+1)); echo "    $args: rc=$RC $(tail -1 "$T/out.txt" | cut -c1-100)"; }
done
[ $n -eq 0 ] && ok "1 a case variant of the ledger name (LEDGER, Ledger) exits 2 on every run-id flag" || bad "1 ledger case variants ($n of 8)"
fc --verdict "" PASS && has "no such run" && ok "1 --verdict with an empty run id: exit 2 'no such run'" \
  || bad "1 --verdict '': rc=$RC $(tail -1 "$T/out.txt" | cut -c1-100)"
[ "$(tree_sha "$T/outside")" = "$OUT_SHA" ] && ok "1 a folder outside the runs root is never written through a run id" \
  || { bad "1 the outside folder was changed"; ls -la "$T/outside"; }
printf '# P\n## Phase 1 - x (P1 <- S1)\nExecutor: qwen\nFiles: a.py\n\377\376\n' > "$R/PLAN_bad.md"
printf '# P\n' > "$R/PLAN_locked.md"; chmod 000 "$R/PLAN_locked.md"
# plan NAME ARGS: ARGS with @ replaced by an over-long plan name, a plan that is not UTF-8 and an unreadable plan
plan(){ local name=$1 a n=0 v want; shift
  for v in "$LONG" PLAN_bad.md PLAN_locked.md; do
    case "$v" in PLAN_bad.md) want="plan is not UTF-8 text";; PLAN_locked.md) want="plan not readable";; *) want="plan not found";; esac
    local args=(); for a in "$@"; do if [ "$a" = @ ]; then args+=("$v"); else args+=("$a"); fi; done
    fc "${args[@]}" && has "$want" || { n=$((n+1)); echo "    $name '${v:0:24}': rc=$RC $(tail -1 "$T/out.txt" | cut -c1-100)"; }
  done
  [ $n -eq 0 ] && ok "1 $name: an over-long plan name, a non-UTF-8 plan and an unreadable plan exit 2 with the reason" \
    || bad "1 $name ($n of 3 values)"; }
plan --lint --lint 1 --plan @ --dry-run --via qwen --model fake/m
plan --begin --begin 1 --plan @
plan "a run" 1 --plan @ --via qwen --model fake/m --dry-run
run "echo y >> a.py"; G=$(rid)
$DP --show "$G" --repo "$R" > "$T/out.txt" 2>&1; RC1=$?; $DP --show last --repo "$R" > "$T/out.txt" 2>&1; RC2=$?
[ -n "$G" ] && [ $RC1 -eq 0 ] && [ $RC2 -eq 0 ] && ok "1 a real run id and 'last' still resolve (characterization)" \
  || bad "1 real run id rc=$RC1/$RC2 id='$G'"
fi

if sel 4; then
echo "== 4 Zen free tier: aliases, billing label, PROVIDER LIMIT"
res(){ $DP --resolve "$1" 2>&1 | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d["model"] + "|" + d["billing"])' 2>&1; }
[ "$(res free-deepseek-flash)" = "opencode/deepseek-v4.1-flash-free#high|OpenCode Zen free tier (no credits)" ] \
  && ok "4 free-deepseek-flash -> opencode/deepseek-v4.1-flash-free#high, free tier" || bad "4 free-deepseek-flash: $(res free-deepseek-flash | tail -1)"
[ "$(res free-glm-flash)" = "opencode/glm-5.3-flash-free|OpenCode Zen free tier (no credits)" ] \
  && ok "4 free-glm-flash -> opencode/glm-5.3-flash-free, free tier" || bad "4 free-glm-flash: $(res free-glm-flash | tail -1)"
[ "$(res zen-glm)" = "opencode/glm-5.3|OpenCode Zen credits" ] && [ "$(res deepseek-flash)" = "opencode-go/deepseek-v4.1-flash#high|OpenCode Go subscription allowance" ] \
  && ok "4 zen-glm stays Zen credits, deepseek-flash stays Go (characterization)" || bad "4 labels: $(res zen-glm) / $(res deepseek-flash)"
mkrepo "$BASIC"
run "echo 'Error: Free usage limit reached. Add credits to continue.'"
has "PROVIDER LIMIT: the Zen free tier's daily limit is used up" && ok "4 'Free usage limit reached' is a PROVIDER LIMIT, not an executor failure" \
  || { bad "4 free limit"; grep -E 'PROVIDER|limit' "$T/out.txt" | head -3; }
mkrepo "$BASIC"
run "echo 'Error: usage limit exceeded'"
has "PROVIDER LIMIT: the subscription allowance is used up" && ok "4 'usage limit exceeded' keeps its line (characterization)" \
  || { bad "4 go limit"; grep -E 'PROVIDER|limit' "$T/out.txt" | head -3; }
fi

if sel 5; then
echo "== 5 --check: the installed plugin and dispatcher against their marketplace source"
P="$T/home/.claude/plugins"; M="$T/market"; S="$M/adapters/claude-code"; C="$P/cache/concord/concord/1.0.0"
setup5(){ rm -rf "$P" "$M"; mkdir -p "$S/commands" "$S/agents" "$C" "$M/.claude-plugin" "$M/concord"
  printf 'a\n' > "$S/commands/delegate.md"; printf 'b\n' > "$S/agents/x.md"; cp -Rp "$S/." "$C/"
  cp -p "$T/concord/concord.py" "$M/concord/concord.py"
  printf '{"plugins": [{"name": "concord", "source": "./adapters/claude-code", "version": "1.0.0"}]}\n' > "$M/.claude-plugin/marketplace.json"
  printf '{"version": 2, "plugins": {"concord@concord": [{"scope": "user", "installPath": "%s", "version": "1.0.0"}]}}\n' "$C" > "$P/installed_plugins.json"
  printf '{"concord": {"source": {"source": "directory", "path": "%s"}, "installLocation": "%s"}}\n' "$M" "$M" > "$P/known_marketplaces.json"; }
chk(){ PATH="$T/bin:${XDEV:+$XDEV/usr/bin:}/usr/bin:/bin" $DP --check > "$T/out.txt" 2>&1; RC=$?; }   # no real harness binaries
setup5; chk
[ $RC -eq 0 ] && has "release   plugin concord@concord 1.0.0: in sync with $S" && has "release   dispatcher: same as $M/concord/concord.py" \
  && ok "5 in sync: one line for the plugin, one for the dispatcher" || { bad "5 in sync rc=$RC"; grep release "$T/out.txt"; }
setup5; printf 'changed\n' > "$C/commands/delegate.md"; printf 'n\n' > "$S/agents/new.md"; chk
[ $RC -eq 0 ] && has "release   plugin concord@concord 1.0.0: differs from $S in 2 file(s): agents/new.md, commands/delegate.md; update: claude plugin marketplace update concord && claude plugin update concord@concord" \
  && ok "5 a changed and a missing file: both named, with the update commands" || { bad "5 plugin drift rc=$RC"; grep release "$T/out.txt"; }
setup5; printf '# other\n' >> "$M/concord/concord.py"; chk
[ $RC -eq 0 ] && has "release   dispatcher: differs from $M/concord/concord.py; install both from one checkout (bash $M/install.sh, then update the plugin)" \
  && ok "5 the dispatcher differs from the plugin's source checkout" || { bad "5 dispatcher drift rc=$RC"; grep release "$T/out.txt"; }
setup5; rm "$P/installed_plugins.json"; chk
[ $RC -eq 0 ] && has "release   not checked: no concord@concord in $P/installed_plugins.json" && [ "$(grep -c '^release' "$T/out.txt")" = 1 ] \
  && ok "5 no plugin installed: one 'not checked' line, exit 0" || { bad "5 no install rc=$RC"; grep release "$T/out.txt"; }
setup5; printf '{' > "$P/installed_plugins.json"; chk
[ $RC -eq 0 ] && has "release   not checked: no concord@concord in $P/installed_plugins.json" && ! has "Traceback" \
  && ok "5 malformed installed_plugins.json: 'not checked', no traceback" || { bad "5 bad json rc=$RC"; grep -E 'release|Error' "$T/out.txt"; }
setup5; printf '{}\n' > "$P/known_marketplaces.json"; chk
[ $RC -eq 0 ] && has "release   not checked: no concord marketplace in $P/known_marketplaces.json" && [ "$(grep -c '^release' "$T/out.txt")" = 1 ] \
  && ok "5 no marketplace entry: one 'not checked' line" || { bad "5 no marketplace rc=$RC"; grep release "$T/out.txt"; }
setup5; printf 'z\n' > "$C/agents/only.md"; chk
[ $RC -eq 0 ] && has "release   plugin concord@concord 1.0.0: differs from $S in 1 file(s): agents/only.md;" \
  && ok "5 a file only in the installed copy is named by its relative path" || { bad "5 installed-only rc=$RC"; grep release "$T/out.txt"; }
setup5; rm "$M/.claude-plugin/marketplace.json"; chk
[ $RC -eq 0 ] && has "release   not checked: no concord plugin in $M/.claude-plugin/marketplace.json" && [ "$(grep -c '^release' "$T/out.txt")" = 1 ] \
  && ok "5 no marketplace.json: one 'not checked' line" || { bad "5 no marketplace.json rc=$RC"; grep release "$T/out.txt"; }
setup5; rm "$M/concord/concord.py"; chk
[ $RC -eq 0 ] && has "release   not checked: no dispatcher source at $M/concord/concord.py" && has "release   plugin concord@concord 1.0.0: in sync with $S" \
  && ok "5 no dispatcher source: 'not checked' for it, the plugin line still printed" || { bad "5 no dispatcher rc=$RC"; grep release "$T/out.txt"; }
fi

if sel 6; then
echo "== 6 wt.py new: base, no .git/config write, nothing left behind, plan files git-excluded"
M2="$T/main"; U="$T/up.git"; rm -rf "$M2" "$U"; git init -q --bare "$U"; gitrepo "$M2"
( cd "$M2" && printf 'x\n' > a && git add a && git commit -qm one && git remote add harness "$U" && git push -q harness main \
  && git remote set-head harness main && printf 'y\n' >> a && git commit -qam two ) > /dev/null 2>&1
HS=$(git -C "$M2" rev-parse --short=7 harness/main); LS=$(git -C "$M2" rev-parse --short=7 HEAD)
CFG=$(sha "$M2/.git/config")
$WT new T0 --repo "$M2" --no-fetch --base harness/main > "$T/out.txt" 2>&1; RC0=$?
$WT new T1 --repo "$M2" --no-fetch > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "branch feature/T1 (new from harness/main at $HS)" && [ "$(git -C "$M2/.claude/worktrees/T1" rev-parse --short=7 HEAD)" = "$HS" ] \
  && ok "6 no origin/HEAD: cut from the only remote default branch (harness/main), not the local HEAD" || { bad "6 base rc=$RC"; cat "$T/out.txt"; }
has "linked: none" && has "copied: none" && ok "6 nothing linked or copied: 'linked: none', 'copied: none' (characterization)" \
  || { bad "6 none lines"; grep -E '^(linked|copied):' "$T/out.txt"; }
[ $RC0 -eq 0 ] && [ "$(sha "$M2/.git/config")" = "$CFG" ] && ok "6 new from a remote branch writes nothing to .git/config (no upstream tracking)" \
  || { bad "6 config written rc=$RC0"; git -C "$M2" config --get-regexp '^branch\.'; }
: > "$M2/.claude/worktrees/T1/PLAN_T1.md"
grep -qxF '/PLAN_*.md' "$M2/.git/info/exclude" && [ -z "$(git -C "$M2/.claude/worktrees/T1" status --porcelain)" ] \
  && ok "6 /PLAN_*.md is in info/exclude: a plan file at the worktree root is invisible to git status" || { bad "6 exclude"; grep -v '^#' "$M2/.git/info/exclude"; }
$WT done T1 --repo "$M2" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && [ -f "$M2/.git/concord/plans/T1/PLAN_T1.md" ] && [ ! -e "$M2/.claude/worktrees/T1" ] \
  && ok "6 done still archives the (now ignored) plan (characterization)" || { bad "6 done rc=$RC"; tail -3 "$T/out.txt"; }
FAKE_WT_FAIL=1 PATH="$T/gitbin:$PATH" $WT new T2 --repo "$M2" --no-fetch > "$T/out.txt" 2>&1; RC=$?
[ $RC -ne 0 ] && ! git -C "$M2" show-ref --verify --quiet refs/heads/feature/T2 && [ ! -e "$M2/.claude/worktrees/T2" ] \
  && ok "6 a failed new removes the branch it made and the empty worktree folder" || { bad "6 rollback rc=$RC"; git -C "$M2" branch; ls "$M2/.claude/worktrees"; }
[ $RC -eq 2 ] && has "wt: git worktree add " && has "failed: fatal: simulated failure after the branch was made" \
  && ! has "Traceback" && ok "6 a failed add exits 2 with git's own message" || { bad "6 add message rc=$RC"; tail -3 "$T/out.txt"; }
$WT new T2 --repo "$M2" --no-fetch > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "branch feature/T2 (new from harness/main at $HS)" && ok "6 a retry after a failed new starts clean" || { bad "6 retry rc=$RC"; cat "$T/out.txt"; }
$WT new T4 --repo "$M2" --no-fetch --base HEAD > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "branch feature/T4 (new from HEAD at $LS)" && ok "6 --base is used as given (HEAD, not the remote default)" || { bad "6 --base rc=$RC"; cat "$T/out.txt"; }
$WT new T9 --repo "$M2" --no-fetch --branch bad..name > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 2 ] && has "fatal: 'bad..name' is not a valid branch name" && ! has "update-ref" && [ ! -e "$M2/.claude/worktrees/T9" ] \
  && ok "6 an invalid branch name: exit 2 with git's reason, no folder left" || { bad "6 invalid branch rc=$RC"; tail -3 "$T/out.txt"; }
# Its own repository, whose previous checkout was a detached HEAD, so a renamed branch cannot spill into later checks.
M4="$T/main4"; rm -rf "$M4"; gitrepo "$M4"
( cd "$M4" && printf 'x\n' > a && git add a && git commit -qm one && git checkout -q --detach && git checkout -q main ) > /dev/null 2>&1
NB=$(git -C "$M4" for-each-ref refs/heads | wc -l | tr -d ' '); n=0
for v in -m -f '@{-1}'; do
  $WT new T13 --repo "$M4" --no-fetch "--branch=$v" > "$T/out.txt" 2>&1; RC=$?
  [ $RC -eq 2 ] && [ "$(git -C "$M4" symbolic-ref --short HEAD)" = main ] && [ "$(git -C "$M4" for-each-ref refs/heads | wc -l | tr -d ' ')" = "$NB" ] \
    && [ ! -e "$M4/.claude/worktrees/T13" ] || { n=$((n+1)); echo "    --branch=$v: rc=$RC $(tail -1 "$T/out.txt" | cut -c1-100)"; }
done
[ $n -eq 0 ] && ok "6 a --branch git reads as an option or as another commit (-m, -f, @{-1}): exit 2, no branch renamed or made" \
  || bad "6 option-like --branch ($n of 3)"
FAKE_RACE="$M2/.claude/worktrees/T12" FAKE_RACE_BASE=harness/main PATH="$T/gitbin:$PATH" $WT new T12 --repo "$M2" --no-fetch > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 2 ] && [ "$(git -C "$M2" rev-parse -q --verify --short=7 refs/heads/feature/T12)" = "$HS" ] \
  && [ "$(git -C "$M2/.claude/worktrees/T12" symbolic-ref --short HEAD 2>/dev/null)" = feature/T12 ] \
  && ok "6 a branch another run made after the existence check is left alone (this run exits 2)" \
  || { bad "6 race rc=$RC"; git -C "$M2" worktree list; tail -2 "$T/out.txt"; }
FAKE_HOLD="$M2/.claude/worktrees/T15" FAKE_HOLD_BRANCH=feature/T15 PATH="$T/gitbin:$PATH" $WT new T15 --repo "$M2" --no-fetch > "$T/out.txt" 2>&1; RC=$?
[ "$(git -C "$M2" rev-parse -q --verify --short=7 refs/heads/feature/T15)" = "$HS" ] \
  && [ "$(git -C "$M2/.claude/worktrees/T15" symbolic-ref --short HEAD 2>/dev/null)" = feature/T15 ] \
  && ok "6 a branch another run checks out before this run's worktree add keeps that run's worktree on it" \
  || { bad "6 held branch rc=$RC"; git -C "$M2" worktree list; tail -2 "$T/out.txt"; }
FAKE_WT_FAIL=2 PATH="$T/gitbin:$PATH" $WT new T8 --repo "$M2" --no-fetch > "$T/out.txt" 2>&1; RC=$?
[ $RC -ne 0 ] && ! git -C "$M2" show-ref --verify --quiet refs/heads/feature/T8 && [ -f "$M2/.claude/worktrees/T8/kept" ] \
  && ok "6 a failed new never deletes a folder with content (the branch it made still goes)" || { bad "6 non-empty folder rc=$RC"; ls -a "$M2/.claude/worktrees/T8"; }
git -C "$M2" branch feature/T3 HEAD
FAKE_WT_FAIL=1 PATH="$T/gitbin:$PATH" $WT new T3 --repo "$M2" --no-fetch > "$T/out.txt" 2>&1; RC=$?
[ $RC -ne 0 ] && [ "$(git -C "$M2" rev-parse --short=7 feature/T3)" = "$LS" ] \
  && ok "6 a failed new never deletes a branch that existed before (characterization)" || bad "6 existing branch rc=$RC"
[ ! -e "$M2/.claude/worktrees/T3" ] && ok "6 a failed new on an existing branch removes the empty folder it left" \
  || { bad "6 existing-branch folder left"; rm -rf "$M2/.claude/worktrees/T3"; }
$WT new T3 --repo "$M2" --no-fetch > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "branch feature/T3 (existing at $LS)" && ok "6 an existing branch: 'existing at <sha>'" || { bad "6 existing rc=$RC"; cat "$T/out.txt"; }
git -C "$M2" branch feature/T11 HEAD && git -C "$M2" tag feature/T11 harness/main
$WT new T11 --repo "$M2" --no-fetch > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "branch feature/T11 (existing at $LS)" && [ "$(git -C "$M2/.claude/worktrees/T11" rev-parse --short=7 HEAD)" = "$LS" ] \
  && ok "6 a tag named like the existing branch: the branch's sha is printed" || { bad "6 tag shadow rc=$RC"; cat "$T/out.txt"; }
M3="$T/main3"; rm -rf "$M3"; gitrepo "$M3"
( cd "$M3" && printf 'x\n' > a && git add a && git commit -qm one ) > /dev/null 2>&1
L3=$(git -C "$M3" rev-parse --short=7 HEAD)
$WT new T7 --repo "$M3" --no-fetch > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "branch feature/T7 (new from HEAD at $L3)" && ok "6 no remote: HEAD, named with its sha" || { bad "6 no remote rc=$RC"; cat "$T/out.txt"; }
( cd "$M3" && for r in harness other; do git remote add $r "$U"; done && git fetch -q harness && git fetch -q other \
  && git remote set-head harness main && git remote set-head other main ) > /dev/null 2>&1
$WT new T5 --repo "$M3" --no-fetch > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "branch feature/T5 (new from HEAD at $L3)" && ok "6 two remote default branches and no origin/HEAD: HEAD, named with its sha" \
  || { bad "6 ambiguous rc=$RC"; cat "$T/out.txt"; }
( cd "$M3" && git remote add origin "$U" && git fetch -q origin && git remote set-head origin main ) > /dev/null 2>&1
OS=$(git -C "$M3" rev-parse --short=7 origin/main)
$WT new T6 --repo "$M3" --no-fetch > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "branch feature/T6 (new from origin/main at $OS)" && ok "6 origin/HEAD present: origin/main wins" || { bad "6 origin rc=$RC"; cat "$T/out.txt"; }
printf 'main3.base = HEAD\n' >> "$T/concord/worktrees.conf"
$WT new T10 --repo "$M3" --no-fetch > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "branch feature/T10 (new from HEAD at $L3)" && ok "6 a <repo>.base line in worktrees.conf beats origin/HEAD (characterization)" \
  || { bad "6 conf base rc=$RC"; cat "$T/out.txt"; }
fi

if sel 7; then
echo "== 7 one Opus reviewer above the low tier"
mkrepo '## Phase 1 - medium (P1 <- S1)
Executor: deepseek-flash
Risk: medium
Files: a.py
Acceptance:
- `grep -q y a.py`'
run "echo y >> a.py"; G=$(rid)
$DP --review "$G" --packet --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ $RC -eq 0 ] && has "next: Agent subagent_type concord:reviewer-opus55 with prompt" && ! has "reviewer-opus48" \
  && ok "7 the packet hint names concord:reviewer-opus55 only" || { bad "7 hint rc=$RC"; grep next: "$T/out.txt"; }
fi

if sel 8; then
echo "== 8 --restore puts back only what the run left, in the checkout the run belongs to"
mkrepo "$BASIC"; run "echo y >> a.py"; G=$(rid); [ -n "$G" ] || { echo "setup failed: run"; cat "$T/out.txt"; exit 1; }
echo "z = 9" >> "$R/a.py"; EDITED=$(cat "$R/a.py")
$DP --restore "$G" --repo "$R" > "$T/out.txt" 2>&1; RC=$?
[ "$(cat "$R/a.py")" = "$EDITED" ] && has "not restored" && has "a.py" \
  && ok "8 a hand edit made after the run: --restore leaves a.py as it is and lists it as not restored" || { bad "8 later edit overwritten rc=$RC: $(tr '\n' '|' < "$R/a.py")"; cat "$T/out.txt"; }
mkrepo "$BASIC"; run "echo y >> a.py"; G=$(rid)
$DP --restore "$G" --repo "$R" > "$T/out.txt" 2>&1; RC1=$?; A1=$(cat "$R/a.py")
echo "later = 1" >> "$R/a.py"; A2=$(cat "$R/a.py")
$DP --restore "$G" --repo "$R" > "$T/out.txt" 2>&1
[ $RC1 -eq 0 ] && [ "$A1" = "x = 1" ] && [ "$(cat "$R/a.py")" = "$A2" ] \
  && ok "8 an untouched run restores a.py; a second --restore after a new edit changes nothing" || { bad "8 second restore: first rc=$RC1 a.py='$A1' then '$(cat "$R/a.py" | tr '\n' '|')'"; cat "$T/out.txt"; }
mkrepo "$BASIC"; run "echo y >> a.py"; G=$(rid)
git -C "$R" worktree add -q "$T/wt8" -b wt8 > /dev/null 2>&1; W8A=$(cat "$T/wt8/a.py")
$DP --restore "$G" --repo "$T/wt8" > "$T/out.txt" 2>&1; RC=$?
[ $RC -ne 0 ] && [ "$(cat "$T/wt8/a.py")" = "$W8A" ] && ok "8 a run id of another checkout (the main checkout's run, asked in a worktree): refused (nonzero exit), the worktree untouched" \
  || { bad "8 foreign run restored rc=$RC"; cat "$T/out.txt"; }
mkrepo "$BASIC"; run "echo y >> a.py"; G=$(rid)
# ../escape.txt gets a.py's recorded end state and start hash, and copies that match them, so only its path stops the restore
cp "$R/a.py" "$T/escape.txt"; cp "$R/.git/concord/$G/backup/a.py" "$R/.git/concord/$G/escape.txt"; ESC=$(cat "$T/escape.txt")
python3 -I -c 'import json,sys; p=sys.argv[1]; m=json.load(open(p))
for k in ("end_hashes", "backup_hashes", "end_kinds", "end_exec"): m[k]["../escape.txt"] = m[k]["a.py"]
m["backed_up"] = m.get("backed_up", []) + ["../escape.txt"]; json.dump(m, open(p, "w"))' "$R/.git/concord/$G/meta.json"
$DP --restore "$G" --repo "$R" > "$T/out.txt" 2>&1
[ "$(cat "$T/escape.txt")" = "$ESC" ] && has "../escape.txt: not restored (its path resolves outside the repository)" && ! has "Traceback" \
  && ok "8 a backup path that resolves outside the repository is not restored, though its end state and start hash match" || { bad "8 backup path outside the repository was written or not named"; cat "$T/out.txt"; }
rm -f "$T/escape.txt"
mkrepo "$BASIC"; run "echo y >> a.py"; G=$(rid); AY=$(cat "$R/a.py")
{ [ -n "$G" ] && grep -q '^y$' "$R/a.py" && [ ! -x "$R/a.py" ]; } || { echo "setup failed: run that appended y to a non-executable a.py"; exit 1; }
chmod +x "$R/a.py"
$DP --restore "$G" --repo "$R" > "$T/out.txt" 2>&1; RCX=$?
[ "$(cat "$R/a.py")" = "$AY" ] && [ -x "$R/a.py" ] && has "a.py: not restored" \
  && ok "8 a chmod +x after the run (bytes unchanged): --restore leaves a.py as it is, executable, and lists it as not restored" \
  || { bad "8 later chmod overwritten rc=$RCX: x=$([ -x "$R/a.py" ] && echo yes || echo no) a.py='$(tr '\n' '|' < "$R/a.py")'"; cat "$T/out.txt"; }
fmode(){ python3 -c 'import os, sys; print("%o" % (os.stat(sys.argv[1]).st_mode & 0o7777))' "$1"; }   # BSD and GNU stat disagree on flags
mkrepo "$BASIC"; run "echo y >> a.py"; G=$(rid); AY=$(cat "$R/a.py")
{ [ -n "$G" ] && grep -q '^y$' "$R/a.py" && chmod 600 "$R/a.py" && [ "$(fmode "$R/a.py")" = 600 ]; } || { echo "setup failed: run, then chmod 600 a.py"; exit 1; }
$DP --restore "$G" --repo "$R" > "$T/out.txt" 2>&1; RCM=$?
MODE=$(fmode "$R/a.py")
[ "$(cat "$R/a.py")" = "$AY" ] && [ "$MODE" = 600 ] && has "a.py: not restored" \
  && ok "8 a chmod 600 after the run (bytes unchanged): --restore keeps the bytes and the 0600 mode and lists a.py as not restored" \
  || { bad "8 later chmod 600 undone rc=$RCM: mode=$MODE a.py='$(tr '\n' '|' < "$R/a.py")'"; cat "$T/out.txt"; }
mkrepo "$BASIC"; run "echo y >> a.py"; G=$(rid); AY=$(cat "$R/a.py")
printf '%s\n' "$AY" > "$R/same-bytes.py"   # inside the repository: a link out of it is refused by the path rule, not tested here
{ [ -n "$G" ] && grep -q '^y$' "$R/a.py" && rm "$R/a.py" && ln -s same-bytes.py "$R/a.py" && [ "$(cat "$R/a.py")" = "$AY" ]; } || { echo "setup failed: a.py replaced by a link to the same bytes"; exit 1; }
$DP --restore "$G" --repo "$R" > "$T/out.txt" 2>&1; RCL=$?
[ -L "$R/a.py" ] && [ "$(readlink "$R/a.py")" = same-bytes.py ] && [ "$(cat "$R/same-bytes.py")" = "$AY" ] && has "a.py: not restored" && ! has "resolves outside" \
  && ok "8 a.py replaced by a symlink to a file with the same bytes: --restore leaves the link and its target unchanged and lists a.py" \
  || { bad "8 symlink to identical bytes written through rc=$RCL: link=$([ -L "$R/a.py" ] && echo yes || echo no) target='$(tr '\n' '|' < "$R/same-bytes.py")'"; cat "$T/out.txt"; }
mkrepo "$BASIC"; run "echo y >> a.py"; G=$(rid); A0=$(cat "$R/a.py")
python3 -I -c 'import json,sys; p=sys.argv[1]; m=json.load(open(p)); m.pop("end_hashes", None); json.dump(m,open(p,"w"))' "$R/.git/concord/$G/meta.json"
$DP --restore "$G" --repo "$R" > "$T/out.txt" 2>&1
[ "$(cat "$R/a.py")" = "$A0" ] && has "a.py: not restored (the run's end state is not recorded (the run did not finish, or a version before 3.0 ran it))" \
  && ok "8 a run with no recorded end state: a.py is left alone, and the message says the run did not finish or ran before 3.0" || { bad "8 no end state message"; cat "$T/out.txt"; }
mkrepo "${BASIC/Files: a.py/Files: a.py, b.py, local.cfg}"
( cd "$R" && printf 'keep = 1\n' > b.py && printf 'local.cfg\n' >> .gitignore && printf 'secret = 1\n' > local.cfg && git add b.py .gitignore && git commit -qm more ) \
  || { echo "setup failed: tracked b.py and ignored local.cfg"; exit 1; }
run "echo y >> a.py; rm b.py local.cfg"; G=$(rid)
{ [ -n "$G" ] && [ ! -e "$R/b.py" ] && [ ! -e "$R/local.cfg" ]; } || { echo "setup failed: a run that deleted b.py and local.cfg"; cat "$T/out.txt"; exit 1; }
$DP --restore "$G" --repo "$R" > "$T/out.txt" 2>&1; RCD=$?
[ $RCD -eq 0 ] && [ "$(cat "$R/b.py" 2>/dev/null)" = "keep = 1" ] && [ "$(cat "$R/local.cfg" 2>/dev/null)" = "secret = 1" ] && has "restored b.py" && has "restored local.cfg" \
  && ok "8 a tracked file and an ignored in-scope file the run deleted and nobody recreated: --restore brings both back from the backup" \
  || { bad "8 deleted files not restored rc=$RCD: b.py=$([ -e "$R/b.py" ] && echo present || echo absent) local.cfg=$([ -e "$R/local.cfg" ] && echo present || echo absent)"; cat "$T/out.txt"; }
fi

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
