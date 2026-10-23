#!/bin/bash
# concord.py (PLAN_kit-opencode-sandbox): the OpenCode launch is wrapped in macOS sandbox-exec with a minimal
# Seatbelt profile. W = wiring (the dry-run command carries sandbox-exec, and the off-switches remove it);
# P = the generated profile text (open network, write-confinement, credential deny-reads); F = the profile
# actually blocks (functional — needs a real sandbox-exec, so SKIPped when nested Seatbelt refuses apply, as it
# does inside the Claude Code sandbox). No network, no real OpenCode binary.
# Run: bash ~/.claude/concord/tests/sandbox_test.sh [WPF]   (exit 0 = every selected check passed).
set -u
SEL="${1:-WPSF}"
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/sandbox-test.XXXXXX")" && pwd -P)"; export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/concord" "$T/home/.claude" "$T/octmp"
cp -p "$SRC"/concord.py "$SRC"/wt.py "$SRC"/*.md "$SRC"/*.conf "$T/concord/" && cp -Rp "$SRC/repo-notes" "$T/concord/"
cp -p "$SRC"/*.sb "$T/concord/" 2>/dev/null || true   # profile template; absent until Phase 2 (red run)
# A fake opencode binary so build_command resolves a path in --dry-run (never executed here).
printf '#!/bin/sh\necho fake-opencode\n' > "$T/bin/opencode"; chmod +x "$T/bin/opencode"
XDEV="$(xcode-select -p 2>/dev/null)"; [ -n "$XDEV" ] && [ -x "$XDEV/usr/bin/git" ] && [ -x "$XDEV/usr/bin/python3" ] && export PATH="$XDEV/usr/bin:$PATH"
export PATH="$T/bin:$PATH" HOME="$T/home"
# Keep OpenCode's temp allowance narrow and OUTSIDE the suite's own tmp, so the "write outside" target ($HOME)
# is not transitively allowed by a broad $TMPDIR write rule.
export TMPDIR="$T/octmp"
DP="python3 $T/concord/concord.py"
R="$T/repo"
pass=0; fail=0; skip=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
skp(){ skip=$((skip+1)); echo "  SKIP $1"; }
sel(){ case "$SEL" in *$1*) return 0;; esac; return 1; }
# Parse the JSON argv printed on the `cmd: ` line of a --dry-run.
cmdjson(){ sed -n 's/^cmd: //p' "$T/out.txt" | tail -1; }
pyarr(){ cmdjson | python3 -I -c "import json,sys$1" 2>/dev/null; }
has_sbx(){ pyarr "
a=json.load(sys.stdin)
print('Y' if any(x.endswith('sandbox-exec') for x in a) else 'N')"; }
sbprofile(){ pyarr "
a=json.load(sys.stdin)
print(a[a.index('-f')+1] if '-f' in a else '')"; }

mkdir -p "$R" && ( cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'x = 1\n' > a.py; printf '.claude/\n' > .gitignore
  cat > PLAN_OC.md <<'P'
# Plan
## Phase 1 - oc
Executor: opencode
Files: a.py
Acceptance:
- `grep -q x a.py`
P
  git add -A && git commit -qm init ) || { echo "setup failed"; exit 1; }

dry(){ $DP 1 --plan PLAN_OC.md --via opencode --model opencode/flash --dry-run --no-baseline --repo "$R" "$@" > "$T/out.txt" 2>&1; }

# The wrapper (and every check that needs it active) only applies where sandbox-exec can apply: not under a nested
# Seatbelt, as inside the Claude Code sandbox. When inactive, sandbox_cmd falls back to the bare command by design,
# so the wrapper-dependent checks SKIP (run the suite outside the sandbox to exercise them).
SBX_ACTIVE=0
if command -v sandbox-exec >/dev/null 2>&1 && sandbox-exec -p '(version 1)(allow default)' /usr/bin/true >/dev/null 2>&1; then SBX_ACTIVE=1; fi

if sel W; then echo "== W. dry-run command carries sandbox-exec; off-switches remove it"
dry; RC=$?
if [ "$SBX_ACTIVE" = 1 ]; then
  [ $RC -eq 0 ] && [ "$(has_sbx)" = Y ] && ok "W.1 default run: argv is wrapped in sandbox-exec" || { bad "W.1 not wrapped (rc=$RC)"; cmdjson; }
  SB="$(sbprofile)"
  [ -n "$SB" ] && case "$SB" in *.sb) true;; *) false;; esac && ok "W.2 wrapper passes -f <profile>.sb" || bad "W.2 no -f <.sb> in argv: '${SB:-none}'"
else
  skp "W.1/W.2 wrapper inactive here (nested Seatbelt or no sandbox-exec); run outside the Claude Code sandbox"
fi
dry --no-sandbox
[ "$(has_sbx)" = N ] && ok "W.3 --no-sandbox: argv is the bare OpenCode command" || { bad "W.3 --no-sandbox still wrapped"; cmdjson; }
CONCORD_NO_SANDBOX=1 $DP 1 --plan PLAN_OC.md --via opencode --model opencode/flash --dry-run --no-baseline --repo "$R" > "$T/out.txt" 2>&1
[ "$(has_sbx)" = N ] && ok "W.4 CONCORD_NO_SANDBOX=1: not wrapped" || { bad "W.4 env off-switch ignored"; cmdjson; }
# executors.conf opencode.sandbox = no
sed -i.bak 's/^opencode.model =.*/&\nopencode.sandbox = no/' "$T/concord/executors.conf" 2>/dev/null || \
  printf '\nopencode.sandbox = no\n' >> "$T/concord/executors.conf"
dry
[ "$(has_sbx)" = N ] && ok "W.5 executors.conf opencode.sandbox=no: not wrapped" || { bad "W.5 conf off-switch ignored"; cmdjson; }
# restore conf
sed -i.bak '/^opencode.sandbox = no/d' "$T/concord/executors.conf" 2>/dev/null
fi

if sel P; then echo "== P. generated profile text"
dry; SB="$(sbprofile)"
if [ "$SBX_ACTIVE" != 1 ]; then skp "P.* wrapper inactive here (nested Seatbelt); run outside the Claude Code sandbox";
elif [ -z "$SB" ] || [ ! -f "$SB" ]; then bad "P.0 no generated profile file to inspect (SB='${SB:-none}')";
else
  grep -qF '(allow network*)' "$SB" && ok "P.1 network left open (Seatbelt cannot filter by host; Q1=A)" || { bad "P.1 no open-network stanza"; grep -i network "$SB" | head; }
  grep -qF "$R" "$SB" && grep -q 'file-write\*' "$SB" && ok "P.2 writes confined: worktree is a write-allow subpath" || bad "P.2 no worktree write-allow"
  grep -q "$HOME/.local/share/opencode" "$SB" && ok "P.3 OpenCode data dir (db) is writable" || { bad "P.3 data dir not write-allowed"; grep -i opencode "$SB" | head; }
  grep -q 'file-read\*' "$SB" && grep -q "$HOME/.ssh" "$SB" && ok "P.4 ~/.ssh is a read-deny" || { bad "P.4 ssh not denied"; grep -i ssh "$SB" | head; }
  grep -q "$HOME/.aws" "$SB" && ok "P.5 ~/.aws is a read-deny" || bad "P.5 aws not denied"
  # Finding 1: foreign stores + the sensitive data under ~/.claude must be read-denied.
  miss=""; for p in "$HOME/.cache/huggingface/token" "$HOME/.kube" "$HOME/Library/Keychains" \
      "$HOME/.claude.json" "$HOME/.claude/projects"; do grep -qF "$p" "$SB" || miss="$miss $p"; done
  [ -z "$miss" ] && ok "P.6 HF token, ~/.kube, Keychains, ~/.claude.json, ~/.claude/projects read-denied" || bad "P.6 missing read-deny:$miss"
  # OpenCode's OWN creds must stay readable (it needs them to auth to Go/Zen; denying breaks every run).
  ! grep -qF "$HOME/.config/opencode/service.json" "$SB" && ! grep -qF "concord-keys" "$SB" \
    && ok "P.8 OpenCode's own creds (service.json, concord-keys) are NOT denied (readable; accepted limit)" \
    || bad "P.8 an OpenCode-own credential is read-denied, which breaks inference"
  # ~/.claude must NOT be blanket-denied: OpenCode reads a benign part of it, so a whole-dir deny breaks every run.
  grep -qE "\"$HOME/\.claude\"\)" "$SB" && bad "P.9 ~/.claude is blanket read-denied (breaks OpenCode)" \
    || ok "P.9 ~/.claude is not blanket-denied (only its sensitive data is)"
  # Finding 2: the OpenCode config dir must NOT be in the write allow-list (planted plugins = persistent escape).
  awk '/\(allow file-write\*/{w=1} w&&/opencode/&&!/local\/share|\.cache/{print} /^\)|\)\)$/{if(w)w=0}' "$SB" \
    | grep -q "$HOME/.config/opencode" && bad "P.7 OpenCode config dir is WRITABLE (plugin escape)" \
    || ok "P.7 OpenCode config dir is not in the write allow-list"
fi
fi

if sel S; then echo "== S. the run reports whether the sandbox is on"
dry
grep -q '^sandbox: ' "$T/out.txt" && ok "S.1 dry-run reports the sandbox state" || { bad "S.1 no 'sandbox:' line"; grep -i sandbox "$T/out.txt" | head; }
dry --no-sandbox
grep -qE '^sandbox: off \(.*no-sandbox' "$T/out.txt" && ok "S.2 --no-sandbox is reported as off, with the reason" || { bad "S.2 off-state not reported"; grep -i sandbox "$T/out.txt" | head; }
fi

if sel F; then echo "== F. the profile actually blocks (functional)"
if [ "$SBX_ACTIVE" != 1 ]; then skp "F.* sandbox-exec absent or nested Seatbelt refuses apply (run outside the Claude Code sandbox)"
else
  dry; SB="$(sbprofile)"
  if [ -z "$SB" ] || [ ! -f "$SB" ]; then bad "F.0 no generated profile file";
  else
    mkdir -p "$HOME/.ssh"; printf 'SECRET\n' > "$HOME/.ssh/id_rsa"
    sandbox-exec -f "$SB" /bin/sh -c "echo hi > '$R/inside.txt'" >/dev/null 2>&1 && ok "F.1 write inside the worktree: allowed" || bad "F.1 worktree write blocked"
    sandbox-exec -f "$SB" /bin/sh -c "echo hi > '$HOME/evil.txt'" >/dev/null 2>&1 && bad "F.2 write outside the worktree was ALLOWED" || ok "F.2 write outside the worktree: blocked"
    sandbox-exec -f "$SB" /bin/sh -c "cat '$HOME/.ssh/id_rsa'" >/dev/null 2>&1 && bad "F.3 ~/.ssh read was ALLOWED" || ok "F.3 ~/.ssh read: blocked"
    sandbox-exec -f "$SB" /bin/sh -c "cat '$R/a.py'" >/dev/null 2>&1 && ok "F.4 read inside the worktree: allowed" || bad "F.4 worktree read blocked"
    mkdir -p "$HOME/.config/opencode/plugins"
    sandbox-exec -f "$SB" /bin/sh -c "echo x > '$HOME/.config/opencode/plugins/evil.js'" >/dev/null 2>&1 && bad "F.5 write into OpenCode plugins was ALLOWED (persistent escape)" || ok "F.5 write into OpenCode config/plugins: blocked"
    printf 'tok\n' > "$HOME/.cache/huggingface/token" 2>/dev/null || { mkdir -p "$HOME/.cache/huggingface"; printf 'tok\n' > "$HOME/.cache/huggingface/token"; }
    sandbox-exec -f "$SB" /bin/sh -c "cat '$HOME/.cache/huggingface/token'" >/dev/null 2>&1 && bad "F.6 HF token read was ALLOWED" || ok "F.6 HF token read: blocked"
    printf '{}' > "$HOME/.claude.json"
    sandbox-exec -f "$SB" /bin/sh -c "cat '$HOME/.claude.json'" >/dev/null 2>&1 && bad "F.7 ~/.claude.json read was ALLOWED" || ok "F.7 ~/.claude.json read: blocked"
  fi
fi
fi

echo "passed $pass, failed $fail, skipped $skip"
[ $fail -eq 0 ]
