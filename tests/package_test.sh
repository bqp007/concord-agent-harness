#!/bin/bash
# Repository contract checks. Run from anywhere: bash tests/package_test.sh [SECTION [TREE ...]]
# Sections: scrub layout agents python install style hygiene docs (none = all); blog runs only when named.
# `scrub` takes trees to scope it and reads its patterns from ${CONCORD_SCRUB_FILE:-~/.config/concord/scrub.txt}
# (one extended regular expression per line, kept outside the repository; no file = section skipped).
# Output: one "check <section>/<name>: ok|FAIL <detail>" per check, then "passed N, failed M"; exit 0 iff M = 0.
set -u
cd "$(dirname "$0")/.." || exit 2
ROOT=$PWD
SCRUB_FILE=${CONCORD_SCRUB_FILE:-$HOME/.config/concord/scrub.txt}
K=concord; A=adapters/claude-code
pass=0; fail=0
tmpd() { mktemp -d "${TMPDIR:-/tmp}/pkgtest.XXXXXX"; }
check() { local name=$1; shift; local out
  if out=$(cd "$ROOT" && eval "$*" 2>&1); then echo "check $name: ok"; pass=$((pass+1))
  else echo "check $name: FAIL $(echo "$out" | tail -1 | cut -c1-120)"; fail=$((fail+1)); fi; }
AGENTS="implementer implementer-opus48 reviewer-opus55 reviewer-delta plan-verifier"
COMMANDS="run plan-then-delegate delegate rules-review"
HOOKS="block-destructive-git block-rm-outside-scratch block-plan-md block-rm-home-paths"
SUITES="acclint delegate delta guards papers pr_review protocol simplify testquality worktree"

# Every relative link, reference link and image in the given markdown files names a file that would be
# published: present, and tracked or untracked-but-not-ignored (a link into an ignored folder breaks on GitHub).
LINK_RE=$'\\]\\([^)#[:space:]]+|^\\[[^]]+\\]: *[^#[:space:]]+|src=["\'][^"\'#]+'
links_ok() { local f l p bad=0
  for f in "$@"; do [ -f "$f" ] || continue
    for l in $(grep -oE "$LINK_RE" "$f" | sed -E 's/^\]\(//; s/^\[[^]]*\]: *//; s/^src=.//'); do
      case "$l" in http://*|https://*|mailto:*) continue;; esac
      p="$(dirname "$f")/$l"
      { [ -e "$p" ] && [ -n "$(git ls-files -co --exclude-standard -- "$p")" ]; } || { echo "$f -> $l"; bad=1; }
    done
  done; [ $bad = 0 ]; }

# A count the docs write as a word matches the code. num_word N spells 0-99 the way the docs do (seventeen,
# twenty-one); counts_ok N NOUN FILE... passes when every "<number word> [regression |test ]NOUN" in each FILE
# spells N and each FILE has at least one.
NUM_WORDS="zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen"
NUM_TENS="twenty thirty forty fifty sixty seventy eighty ninety"
num_word() { local u=($NUM_WORDS) t=($NUM_TENS)
  if [ "$1" -lt 20 ]; then echo "${u[$1]}"; else echo "${t[$(($1 / 10 - 2))]}$([ $(($1 % 10)) = 0 ] || echo "-${u[$(($1 % 10))]}")"; fi; }
counts_ok() { local want noun=$2 f got bad=0 re
  want=$(num_word "$1"); shift 2
  re="(^|[^a-z-])((${NUM_TENS// /|})(-(${NUM_WORDS// /|}))?|${NUM_WORDS// /|})( regression| test)? $noun([^a-z]|\$)"
  for f in "$@"; do
    got=$(grep -oiE "$re" "$f" | sed -E 's/^[^a-zA-Z]+//' | awk '{print tolower($1)}' | sort -u | tr '\n' ' ')
    [ -n "$got" ] || { echo "$f: no count of $noun"; bad=1; continue; }
    [ "$got" = "$want " ] || { echo "$f says ${got% } where the code has $want"; bad=1; }
  done; [ $bad = 0 ]; }

s_scrub() { local trees="$*" t pat
  [ -f "$SCRUB_FILE" ] || { echo "skip scrub (no pattern file)"; return 0; }
  pat=$(tmpd)/patterns; grep -vE '^[[:space:]]*(#|$)' "$SCRUB_FILE" > "$pat"
  [ -s "$pat" ] || { check scrub/pattern-file "echo no patterns in $SCRUB_FILE; false"; return; }
  [ -n "$trees" ] || trees="$K adapters install.sh README.md docs LICENSE SECURITY.md CONTRIBUTING.md CITATION.cff scripts examples tests assets .github .gitignore .claude-plugin"
  for t in $trees; do [ -e "$t" ] || { [ $# = 0 ] && continue; check "scrub/$t" "echo no such tree; false"; continue; }
    check "scrub/$t" "n=\$(grep -rnIE -f '$pat' '$t' | wc -l | tr -d ' '); [ \"\$n\" = 0 ] || { echo \"\$n matches\"; false; }"
  done
  case " $trees " in *" $K "*)
    check scrub/worktrees-template "! grep -qE '^[^#].*\.(links|base) *=' $K/worktrees.conf"
    check scrub/repo-notes "[ \"\$(ls -A $K/repo-notes)\" = README.md ]";; esac
  [ $# = 0 ] && check scrub/source-blog "[ ! -e docs/figures/_source-blog-2026-10-18.md ]"; }

s_layout() { local p old
  local paths="README.md LICENSE SECURITY.md install.sh CITATION.cff .github/workflows/ci.yml .gitignore .claude-plugin/marketplace.json
    $A/.claude-plugin/plugin.json
    $K/concord.py $K/wt.py $K/CONTRACT.md $K/PLAN_TEMPLATE.md $K/REVIEW.md $K/models.conf $K/executors.conf
    $K/worktrees.conf $K/repo-notes/README.md $K/tests/run_all.sh $K/tests/lib.sh $K/drift_hook.sh $A/CLAUDE.md $A/settings.snippet.json
    docs/WORKFLOW.md docs/figures/fig2-loop.svg"
  for p in $SUITES; do paths="$paths $K/tests/${p}_test.sh"; done
  for p in $COMMANDS; do paths="$paths $A/commands/$p.md"; done
  for p in $AGENTS; do paths="$paths $A/agents/$p.md"; done
  for p in $HOOKS; do paths="$paths $A/hookify/$p.md"; done
  for p in $paths; do check "layout/$p" "[ -e '$p' ]"; done
  for p in kit claude-code docs/WORKFLOW.pdf; do check "layout/no-$p" "[ ! -e '$p' ]"; done
  check layout/install.sh-executable "[ -x install.sh ]"
  check layout/no-pdf "[ -z \"\$(git ls-files -co --exclude-standard '*.pdf')\" ]"
  check layout/gitignore-paper "grep -qx '/paper/' .gitignore"
  check layout/marketplace "python3 -B -I -c \"import json; d=json.load(open('.claude-plugin/marketplace.json')); p=d['plugins']; assert d['name']=='concord' and len(p)==1 and p[0]['name']=='concord' and p[0]['source']=='./$A'\""
  check layout/plugin "python3 -B -I -c \"import json,re; d=json.load(open('$A/.claude-plugin/plugin.json')); m=json.load(open('.claude-plugin/marketplace.json'))['plugins'][0]; assert d['name']=='concord' and re.fullmatch(r'[0-9]+[.][0-9]+[.][0-9]+', d['version']) and m['version']==d['version']\""
  old="agent-workflow"; old="$old-kit"   # assembled, so this file does not match itself
  # scope = what would be published (tracked, or untracked and not ignored); grep status 1 = no match, else FAIL
  check layout/old-name "git grep -n -I -F --untracked -e '$old' -- .; [ \$? = 1 ]"; }

s_agents() { local a
  for a in $AGENTS; do check "agents/$a.md" "grep -q '^name: $a\$' $A/agents/$a.md"; done
  :; }

s_python() {
  check python/help "python3 -B -I $K/concord.py --help >/dev/null"
  check python/resolve-flash "python3 -B -I $K/concord.py --resolve deepseek-flash | grep -q opencode-go/deepseek-v4.1-flash"
  check python/resolve-glm "python3 -B -I $K/concord.py --resolve glm >/dev/null"
  check python/resolve-kimi "python3 -B -I $K/concord.py --resolve kimi-k3 >/dev/null"
  check python/wt-help "python3 -B -I $K/wt.py --help >/dev/null"
  check python/plugin-names "python3 -B -I $K/concord.py --help | grep -q 'concord:reviewer-opus55'"
  check python/settings "python3 -B -I -c \"import json; d=json.load(open('$A/settings.snippet.json')); m=d['modelSettings']; assert m['claude-opus-5-5']=={'autoCompactWindow':400000} and m['claude-fable-5-1']=={'autoCompactWindow':400000}; assert 'git push *' in d['sandbox']['excludedCommands']\""; }

inst() { env -u CLAUDE_HOME HOME=$H bash install.sh "$@"; }   # every case: fresh H, CLAUDE_HOME unset
inst_a() { local D; D=$(tmpd); inst --dry-run --repo "$D" > "$H/out" && grep -q '^would copy' "$H/out" &&
  ! grep -qE '^(copy|keep|backup) ' "$H/out" && [ ! -e "$H/.claude" ] && [ ! -e "$D/.claude" ]; }
inst_b() { inst --no-tests > "$H/out" || return 1; local f; for f in concord/concord.py concord/CONTRACT.md concord/models.conf \
    concord/tests/run_all.sh concord/repo-notes/README.md; do [ -f "$H/.claude/$f" ] || { echo "missing $f"; return 1; }; done; }
inst_c() { inst --no-tests >/dev/null && echo mine > "$H/.claude/concord/models.conf" &&
  rm -f "$H/.claude/agents/implementer.md" && echo old > "$H/.claude/agents/implementer.md" && inst --no-tests > "$H/out" &&
  [ "$(cat "$H/.claude/concord/models.conf")" = mine ] && cmp -s $K/concord.py "$H/.claude/concord/concord.py" &&
  [ ! -L "$H/.claude/agents/implementer.md" ] && [ "$(cat "$H/.claude/agents/implementer.md")" = old ] &&
  grep -qF "$H/.claude/agents/implementer.md" "$H/out" &&
  [ "$(ls "$H"/.claude/concord/backup/*-pre-install*/concord.py | wc -l)" -eq 1 ]; }
inst_d() { local D n; D=$(tmpd); git -C "$D" init -q && inst --no-tests --repo "$D" >/dev/null &&
  for n in $HOOKS; do [ -f "$D/.claude/hookify.$n.local.md" ] || { echo "missing $n"; return 1; }; done &&
  echo custom > "$D/.claude/hookify.block-plan-md.local.md" && inst --no-tests --repo "$D" >/dev/null && [ "$(cat "$D/.claude/hookify.block-plan-md.local.md")" = custom ]; }
inst_e() { inst --bogus 2>/dev/null; [ $? = 2 ] && { inst --repo 2>/dev/null; [ $? = 2 ]; } && { inst --repo /nonexistent 2>/dev/null; [ $? = 2 ]; } && [ ! -e "$H/.claude" ]; }
inst_f() { mkdir "$H/bin" && printf '#!/bin/sh\nexit 1\n' > "$H/bin/python3" && chmod +x "$H/bin/python3"
  PATH="$H/bin:$PATH" inst --no-tests >/dev/null 2>"$H/err"; [ $? = 2 ] && grep -q python3 "$H/err"; }
inst_g() { env HOME=$H CLAUDE_HOME=$H/x bash install.sh --no-tests >/dev/null && [ -f "$H/x/concord/concord.py" ] && [ ! -e "$H/.claude" ]; }
inst_h() { local g="$H/.claude/concord/tests/slim_test.sh" m="$H/.claude/concord/tests/team_test.sh"   # a suite Concord retired: removed, kept in the backup; a team's own suite: kept
  inst --no-tests >/dev/null && echo old > "$g" && echo team > "$m" && inst --dry-run > "$H/out" && grep -qF "would remove $g" "$H/out" && [ -f "$g" ] &&
  ! grep -qF "remove $m" "$H/out" && inst --no-tests > "$H/out" && [ ! -e "$g" ] && grep -qF "remove $g" "$H/out" &&
  [ "$(cat "$m")" = team ] && ! grep -qF "remove $m" "$H/out" &&
  [ "$(cat "$H"/.claude/concord/backup/*-pre-install*/tests/slim_test.sh)" = old ] && [ -f "$H/.claude/concord/tests/run_all.sh" ]; }
# link mode: $DEST/commands/concord -> the repo commands dir, $DEST/agents/<name>.md -> each repo agent file (symlinks)
links_made() { local n
  { [ -L "$H/.claude/commands/concord" ] && [ "$(cd "$H/.claude/commands/concord" 2>/dev/null && pwd -P)" = "$(cd "$ROOT/$A/commands" && pwd -P)" ]; } || return 1
  for n in $AGENTS; do { [ -L "$H/.claude/agents/$n.md" ] && cmp -s "$H/.claude/agents/$n.md" "$ROOT/$A/agents/$n.md"; } || return 1; done; }
inst_i() { inst --link --no-tests >/dev/null && links_made; }
inst_j() { inst --no-tests > "$H/out" || return 1    # default mode is --link
  links_made && grep -qF '<!-- concord:begin -->' "$H/.claude/CLAUDE.md" && grep -qF '<!-- concord:end -->' "$H/.claude/CLAUDE.md" &&
  grep -qF 'reviewer-opus55' "$H/.claude/CLAUDE.md" && ! grep -qF 'concord:reviewer-opus55' "$H/.claude/CLAUDE.md" &&
  grep -qF '/concord:run execute' "$H/.claude/CLAUDE.md" && grep -qF '/concord:run delegate' "$H/.claude/CLAUDE.md" &&
  [ -f "$H/.claude/settings.json" ] && inst --no-tests >/dev/null && links_made &&
  [ "$(grep -cF '<!-- concord:begin -->' "$H/.claude/CLAUDE.md")" -eq 1 ]; }
inst_k() { mkdir -p "$H/.claude" && printf 'TOP SENTINEL\n' > "$H/.claude/CLAUDE.md" && inst --no-tests >/dev/null &&
  printf 'BELOW SENTINEL\n' >> "$H/.claude/CLAUDE.md" && inst --no-tests >/dev/null &&
  [ "$(tail -1 "$H/.claude/CLAUDE.md")" = 'BELOW SENTINEL' ] && [ "$(head -1 "$H/.claude/CLAUDE.md")" = 'TOP SENTINEL' ] &&
  grep -qxF 'TOP SENTINEL' "$H/.claude/CLAUDE.md" && grep -qF '<!-- concord:begin -->' "$H/.claude/CLAUDE.md" &&
  grep -qF '<!-- concord:end -->' "$H/.claude/CLAUDE.md" &&
  [ "$(grep -rslxF 'TOP SENTINEL' "$H/.claude" | wc -l | tr -d ' ')" -ge 2 ] &&
  inst --no-tests >/dev/null && grep -qxF 'TOP SENTINEL' "$H/.claude/CLAUDE.md" &&
  [ "$(grep -cF '<!-- concord:begin -->' "$H/.claude/CLAUDE.md")" -eq 1 ]; }
inst_l() { mkdir -p "$H/.claude" && printf '%s' '{"myKey":"keep","modelSettings":{"claude-opus-5-5":{"autoCompactWindow":123}}}' > "$H/.claude/settings.json" &&
  inst --no-tests >/dev/null &&
  python3 -B -I -c "import json; d=json.load(open('$H/.claude/settings.json')); assert d['myKey']=='keep'; assert d['modelSettings']['claude-opus-5-5']['autoCompactWindow']==123; assert d['modelSettings']['claude-fable-5-1']=={'autoCompactWindow':400000}; assert 'git push *' in d['sandbox']['excludedCommands']; assert sum('drift_hook.sh' in h['command'] for e in d['hooks']['PostToolUse'] for h in e['hooks'])==1; assert not any('--lessons-hook' in h['command'] for v in d['hooks'].values() for e in v for h in e['hooks'])" &&
  printf '%s' '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"other"},{"type":"command","command":"python3 \"$HOME/.claude/concord/concord.py\" --lessons-hook 2>/dev/null || true","timeout":5}]},{"hooks":[{"type":"command","command":"python3 \"$HOME/.claude/concord/concord.py\" --lessons-hook 2>/dev/null || true","timeout":5}]}]}}' > "$H/.claude/settings.json" &&
  inst --no-tests >/dev/null && inst --no-tests >/dev/null &&
  python3 -B -I -c "import json; d=json.load(open('$H/.claude/settings.json'))['hooks']; c=[h['command'] for v in d.values() for e in v for h in e['hooks']]; assert 'other' in c and not any('--lessons-hook' in x for x in c) and sum('drift_hook.sh' in x for x in c)==1 and all(e['hooks'] for v in d.values() for e in v), c"; }
# --plugin removes only the links this checkout made: a link of the same name to the user's own skill stays, and is named
inst_ee() { inst --no-tests >/dev/null && local own="$H/mine/concord-design-review" l="$H/.claude/skills/concord:design-review" &&
  mkdir -p "$own" && echo mine > "$own/SKILL.md" && ln -sfn "$own" "$l" && inst --plugin --no-tests > "$H/out" &&
  [ -L "$l" ] && [ "$(readlink "$l")" = "$own" ] && [ -f "$own/SKILL.md" ] && grep -qF "keep $l" "$H/out"; }
inst_ff() { local n c=0; inst --no-tests >/dev/null && [ -L "$H/.claude/skills/concord:design-review" ] && inst --plugin --no-tests > "$H/out" &&
  [ ! -L "$H/.claude/agents/implementer.md" ] || return 1
  for n in $(shipped_skills); do c=$((c+1)); [ ! -e "$H/.claude/skills/concord:$n" ] && [ ! -L "$H/.claude/skills/concord:$n" ] || return 1; done; [ "$c" -ge 1 ]; }
inst_m() { inst --no-tests >/dev/null && links_made && inst --plugin --no-tests > "$H/out" &&
  grep -qF '/plugin marketplace add' "$H/out" && grep -qF '/plugin install concord@concord' "$H/out" &&
  [ ! -e "$H/.claude/commands/concord" ] && [ ! -L "$H/.claude/agents/implementer.md" ] &&
  grep -qF 'concord:reviewer-opus55' "$H/.claude/CLAUDE.md" && ! grep -qF '`reviewer-opus55`' "$H/.claude/CLAUDE.md" &&
  ! grep -qF 'symlinks in' "$H/.claude/CLAUDE.md"; }
inst_n() { mkdir -p "$H/.claude" && printf 'MINE\n<!-- concord:begin -->\nold\nMINE BELOW\n' > "$H/.claude/CLAUDE.md" &&
  ! inst --no-tests > "$H/out" 2>&1 && grep -qxF 'MINE BELOW' "$H/.claude/CLAUDE.md" && grep -qi 'marker' "$H/out"; }
inst_o() { mkdir -p "$H/.claude" "$H/dot" && printf 'DOTFILES\n' > "$H/dot/CLAUDE.md" && ln -s "$H/dot/CLAUDE.md" "$H/.claude/CLAUDE.md" &&
  inst --no-tests >/dev/null && [ -L "$H/.claude/CLAUDE.md" ] && grep -qF "<!-- concord:begin -->" "$H/dot/CLAUDE.md" && grep -qxF DOTFILES "$H/dot/CLAUDE.md" &&
  b=$(ls "$H"/.claude/concord/backup/*/CLAUDE.md | head -1) && [ ! -L "$b" ] && [ "$(cat "$b")" = DOTFILES ]; }
inst_p() { mkdir -p "$H/.claude" && { echo MINE; cat "$K/../tests/fixtures/CLAUDE-2.0.md"; echo AFTER; } > "$H/.claude/CLAUDE.md" &&   # the 2.0 block, merged by hand, no markers
  cp "$H/.claude/CLAUDE.md" "$H/before" && ! inst --no-tests > "$H/out" 2>&1 && cmp -s "$H/before" "$H/.claude/CLAUDE.md" &&
  grep -qi 'marker' "$H/out" && [ ! -e "$H/.claude/concord" ] && [ ! -e "$H/.claude/settings.json" ]; }
# a heading of the user's own that only starts like Concord's is no Concord block: the dry run and the install go on;
# the block Concord ships now, without its markers, is refused like the 2.0 block
inst_pp() { local md="$H/.claude/CLAUDE.md" own='# Default workflow: plan, then pair program'
  mkdir -p "$H/.claude" && printf '%s\nMINE\n' "$own" > "$md" && inst --dry-run --no-tests > "$H/out" 2>&1 &&
  inst --no-tests > "$H/out" 2>&1 && grep -qxF "$own" "$md" && grep -qxF '<!-- concord:begin -->' "$md" &&
  grep -vF '<!-- concord:' "$ROOT/$A/CLAUDE.md" > "$md" && cp "$md" "$H/before" && ! inst --no-tests > "$H/out" 2>&1 &&
  cmp -s "$H/before" "$md" && grep -qi marker "$H/out"; }
inst_q() { mkdir -p "$H/.claude/concord/tests" && echo mine > "$H/.claude/concord/tests/mine_test.sh" &&
  inst --no-tests >/dev/null && { [ -f "$H/.claude/concord/tests/mine_test.sh" ] || ls "$H"/.claude/concord/backup/*/tests/mine_test.sh >/dev/null 2>&1; }; }
# the concord folder exists without concord.py: the files this install overwrites are backed up first
inst_r() { mkdir -p "$H/.claude/concord" && echo mine > "$H/.claude/concord/CONTRACT.md" && inst --no-tests > "$H/out" &&
  [ "$(cat "$H"/.claude/concord/backup/*-pre-install*/CONTRACT.md)" = mine ] && cmp -s "$K/CONTRACT.md" "$H/.claude/concord/CONTRACT.md"; }
# a settings.json that does not parse stops the install before anything is written
inst_s() { mkdir -p "$H/.claude" && printf '{"myKey": ' > "$H/.claude/settings.json" && ! inst --no-tests > "$H/out" 2>&1 &&
  [ "$(cat "$H/.claude/settings.json")" = '{"myKey": ' ] && [ ! -e "$H/.claude/concord" ] && [ ! -e "$H/.claude/CLAUDE.md" ]; }
# a user's own hook that calls a concord.py of theirs stays; the hooks this installer shipped before are replaced
inst_u() { mkdir -p "$H/.claude" && printf '%s' '{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"python3 /home/me/tools/concord.py --my-hook"}]}]}}' > "$H/.claude/settings.json" &&
  inst --no-tests >/dev/null && inst --no-tests >/dev/null &&
  python3 -B -I -c "import json; d=json.load(open('$H/.claude/settings.json'))['hooks']; c=[h['command'] for v in d.values() for e in v for h in e['hooks']]; assert any('/home/me/tools/concord.py --my-hook' in x for x in c), c; assert sum('drift_hook.sh' in x for x in c)==1, c"; }
# the hook is written with the path under the CLAUDE_HOME the installer installs to
inst_v() { env HOME=$H CLAUDE_HOME=$H/x bash install.sh --no-tests >/dev/null && [ -f "$H/x/concord/drift_hook.sh" ] &&
  python3 -B -I -c "import json; d=json.load(open('$H/x/settings.json'))['hooks']; c=[h['command'] for v in d.values() for e in v for h in e['hooks']]; assert any('$H/x/concord/drift_hook.sh' in x for x in c), c" &&
  ! grep -qF '.claude/concord' "$H/x/settings.json"; }
# a CLAUDE_HOME whose name holds a space, a single and a double quote: settings.json stays valid JSON and the hook command, split as sh splits it, names the script
inst_w() { local d="$H/it's a \"odd\" home"; env HOME=$H CLAUDE_HOME="$d" bash install.sh --no-tests >/dev/null &&
  env HOME=$H CLAUDE_HOME="$d" bash install.sh --no-tests > "$H/out" 2>&1 && ! grep -q 'keep hook' "$H/out" &&
  python3 -B -I -c "
import json, shlex, sys, os
d = sys.argv[1]
c = [h['command'] for v in json.load(open(d + '/settings.json'))['hooks'].values() for e in v for h in e['hooks']]
words = shlex.split(c[0])
assert len(c) == 1 and words[:2] == ['sh', d + '/concord/drift_hook.sh'] and os.path.isfile(words[1]), c
" "$d"; }
# a settings.json that parses but is not an object, or whose "hooks" is not an object: the install stops with exit 2 naming the
# file, and nothing is written (no dispatcher copied, no CLAUDE.md)
inst_refuses_settings() { mkdir -p "$H/.claude" && printf '%s' "$1" > "$H/.claude/settings.json" &&
  { inst --no-tests > "$H/out" 2>&1; [ $? = 2 ]; } && grep -q 'settings.json' "$H/out" &&
  [ "$(cat "$H/.claude/settings.json")" = "$1" ] && [ ! -e "$H/.claude/concord" ] && [ ! -e "$H/.claude/CLAUDE.md" ]; }
inst_x() { inst_refuses_settings '[]'; }
inst_y() { inst_refuses_settings '{"hooks": []}'; }
# the drift hook command the installer shipped in 2.x, character for character; settings_with_hooks writes the given commands as PostToolUse entries
OLD_DRIFT='python3 "$HOME/.claude/concord/concord.py" --drift-hook 2>/dev/null || true'
settings_with_hooks() { mkdir -p "$H/.claude" && python3 -B -I -c '
import json, sys
json.dump({"hooks": {"PostToolUse": [{"hooks": [{"type": "command", "command": c}]} for c in sys.argv[2:]]}}, open(sys.argv[1], "w"))' "$H/.claude/settings.json" "$@"; }
hook_commands() { python3 -B -I -c "import json; d=json.load(open('$H/.claude/settings.json'))['hooks']; print('\n'.join(h['command'] for v in d.values() for e in v for h in e['hooks']))"; }
# a hook command that is a shipped command with more before or after it is the user's own: it stays, and the installer names it; the
# shipped hook is added once (the quoted path of a shipped form holds no quote, so a user's command before it is no part of it)
inst_z() { local u
  settings_with_hooks "$OLD_DRIFT; my-metrics" && inst --no-tests > "$H/out" 2>&1 && hook_commands > "$H/cmds" &&
  grep -qxF "$OLD_DRIFT; my-metrics" "$H/cmds" && [ "$(grep -c 'drift_hook.sh' "$H/cmds")" = 1 ] && grep -q 'my-metrics' "$H/out" || return 1
  for u in "sh '/opt/team/pre-check.sh' 2>/dev/null || true; sh '/Users/x/.claude/concord/drift_hook.sh' 2>/dev/null || true" \
           "sh '/opt/team/notify.sh' 'concord'; sh '/Users/x/.claude/concord/drift_hook.sh' 2>/dev/null || true"; do
    settings_with_hooks "$u" && inst --no-tests > "$H/out" 2>&1 && hook_commands > "$H/cmds" &&
    grep -qxF "$u" "$H/cmds" && [ "$(grep -c 'drift_hook.sh' "$H/cmds")" = 2 ] && grep -qF "keep hook $u" "$H/out" || return 1
  done; }
# the exact old shipped command is replaced by the current one, once
inst_aa() { settings_with_hooks "$OLD_DRIFT" && inst --no-tests > "$H/out" 2>&1 && hook_commands > "$H/cmds" &&
  ! grep -qxF "$OLD_DRIFT" "$H/cmds" && [ "$(grep -c 'drift_hook.sh' "$H/cmds")" = 1 ] && [ "$(wc -l < "$H/cmds")" -eq 1 ]; }
# Skills: --link links each skill directory $A/skills/<n> as $DEST/skills/concord:<n>; --plugin removes those links. Claude
# Code names a linked skill after its folder and a plugin skill <plugin>:<folder>, so each is concord:<n> in both modes; its
# `name:` says the same, and every concord:<name> that the shipped instructions use names a shipped skill, agent or command
# (Claude Code skips an unknown preloaded skill without a warning).
shipped_skills() { local d; for d in "$ROOT/$A"/skills/*/; do [ -f "${d}SKILL.md" ] && basename "$d"; done; }
inst_bb() { local n c=0; inst --link --no-tests >/dev/null || return 1
  for n in $(shipped_skills); do c=$((c+1))
    { [ -L "$H/.claude/skills/concord:$n" ] && [ "$(cd "$H/.claude/skills/concord:$n" 2>/dev/null && pwd -P)" = "$(cd "$ROOT/$A/skills/$n" && pwd -P)" ] \
      && [ -f "$H/.claude/skills/concord:$n/SKILL.md" ]; } || return 1
  done; [ "$c" -ge 1 ]; }
inst_dd() { python3 -B -I - "$ROOT/$A" <<'PY'
import glob, os, re, sys
a = sys.argv[1]
names = set()
for f in glob.glob(os.path.join(a, "skills", "*", "SKILL.md")):
    m = re.search(r"^name:\s*(\S+)\s*$", open(f).read(), re.M)
    assert m, f"{f}: no name: line"
    assert m.group(1) == "concord:" + os.path.basename(os.path.dirname(f)), f"{f}: name {m.group(1)} is not concord:<its directory>"
    names.add(m.group(1))
used = 0
for f in glob.glob(os.path.join(a, "agents", "*.md")):
    head = open(f).read().split("\n---", 2)[0] + "\n"
    m = re.search(r"^skills:\s*\n((?:\s+-\s+\S+\s*\n)+)", head, re.M)
    for n in re.findall(r"-\s+(\S+)", m.group(1) if m else ""):
        used += 1
        assert n in names, f"{f}: skills: {n} names no shipped skill ({sorted(names)})"
assert used >= 1, "no agent preloads a skill"
known = names | {"concord:" + os.path.basename(f)[:-3] for d in ("agents", "commands") for f in glob.glob(os.path.join(a, d, "*.md"))}
for f in [os.path.join(a, "CLAUDE.md"), os.path.join(a, ".claude-plugin", "plugin.json")] + glob.glob(os.path.join(a, "*", "**", "*.md"), recursive=True):
    for n in set(re.findall(r"concord:[a-z][a-z0-9-]*", open(f).read())) - {"concord:begin", "concord:end"}:
        assert n in known, f"{f}: {n} names no shipped skill, agent or command"
PY
}
# --link keeps a link of the user's own (any name Concord installs) and says so
inst_gg() { local own="$H/mine/concord-design-review" l="$H/.claude/skills/concord:design-review"
  mkdir -p "$own" "$H/.claude/skills" && ln -s "$own" "$l" && inst --no-tests > "$H/out" 2>&1 &&
  [ "$(readlink "$l")" = "$own" ] && grep -qF "keep $l" "$H/out" && [ -L "$H/.claude/agents/implementer.md" ]; }
# a skills/concord-design-review link made before 3.0.5 (no manifest line) stays when its folder is in no Concord
# checkout, and is retired in both modes when it points into one
inst_hh() { local l="$H/.claude/skills/concord-design-review" k="$H/oldkit/adapters/claude-code/skills/concord-design-review"
  local n="$H/notkit/adapters/claude-code/skills/concord-design-review"
  mkdir -p "$H/.claude/skills" "$H/oldkit/concord" "$n" && : > "$H/oldkit/install.sh" && : > "$H/oldkit/concord/concord.py" &&
  ln -s "$n" "$l" && inst --no-tests > "$H/out" 2>&1 && [ "$(readlink "$l")" = "$n" ] && ! grep -qF "$l" "$H/out" &&
  ln -sfn "$k" "$l" && inst --no-tests > "$H/out" 2>&1 && [ ! -L "$l" ] && grep -qF "remove link $l" "$H/out" &&
  [ "$(cd "$H/.claude/skills/concord:design-review" && pwd -P)" = "$(cd "$ROOT/$A/skills/design-review" && pwd -P)" ] &&
  rm -f "$H/.claude/concord/links.tsv" && ln -s "$k" "$l" && inst --plugin --no-tests >/dev/null && [ ! -L "$l" ]; }
# a 3.1 linked install upgrades in place: --dry-run only names the skills/concord-design-review link its manifest
# records; the install removes it, links skills/concord:design-review and drops the old line from the manifest
inst_nn() { local l="$H/.claude/skills/concord-design-review" old; old="$(cd "$ROOT" && pwd -P)/$A/skills/concord-design-review"
  mkdir -p "$H/.claude/skills" "$H/.claude/concord" && ln -s "$old" "$l" && printf '%s\t%s\n' "$l" "$old" > "$H/.claude/concord/links.tsv" &&
  inst --dry-run --no-tests > "$H/out" 2>&1 && grep -qF "would remove link $l" "$H/out" && [ -L "$l" ] &&
  inst --no-tests > "$H/out" 2>&1 && [ ! -L "$l" ] && grep -qF "remove link $l" "$H/out" &&
  [ "$(cd "$H/.claude/skills/concord:design-review" && pwd -P)" = "$(cd "$ROOT/$A/skills/design-review" && pwd -P)" ] &&
  [ -z "$(cut -f1 "$H/.claude/concord/links.tsv" | grep -xF "$l")" ]; }
# a personal link that ends in the same adapter-relative path, into a folder that is no Concord checkout, is not Concord's:
# the default install keeps it and names it, and --plugin keeps it
inst_kk() { local own="$H/mine/adapters/claude-code/skills/design-review" l="$H/.claude/skills/concord:design-review"
  mkdir -p "$own" "$H/.claude/skills" && ln -s "$own" "$l" && inst --no-tests > "$H/out" 2>&1 &&
  [ "$(readlink "$l")" = "$own" ] && grep -qF "keep $l" "$H/out" &&
  inst --plugin --no-tests > "$H/out" 2>&1 && [ "$(readlink "$l")" = "$own" ] && grep -qF "keep $l" "$H/out"; }
# a link the manifest records stays Concord's after its clone is moved or deleted: the next install from a new clone updates it
inst_ll() { local d="$H/x" r f
  for r in kit1 kit2; do mkdir "$H/$r" && for f in install.sh concord adapters; do cp -R "$f" "$H/$r/"; done; done
  env HOME=$H CLAUDE_HOME=$d bash "$H/kit1/install.sh" --no-tests >/dev/null &&
  rm -rf "$H/kit1" && env HOME=$H CLAUDE_HOME=$d bash "$H/kit2/install.sh" --no-tests >/dev/null &&
  [ "$(readlink "$d/skills/concord:design-review")" = "$(cd "$H/kit2" && pwd -P)/$A/skills/design-review" ]; }
# an install acts only on the home it installs to: an install into a copy of the home (whose manifest names the
# original), and a second install that spells the home differently, leave every link of the original in place
links_in() { local n; [ -L "$1/commands/concord" ] && [ -e "$1/commands/concord" ] || return 1
  for n in $AGENTS; do [ -L "$1/agents/$n.md" ] && [ -e "$1/agents/$n.md" ] || return 1; done
  for n in $(shipped_skills); do [ -L "$1/skills/concord:$n" ] && [ -e "$1/skills/concord:$n" ] || return 1; done; }
inst_oo() { local d="$H/x" c="$H/copy"
  env HOME=$H CLAUDE_HOME="$d" bash install.sh --no-tests >/dev/null && cp -R "$d" "$c" &&
  env HOME=$H CLAUDE_HOME="$c" bash install.sh --no-tests >/dev/null && links_in "$d" &&
  env HOME=$H CLAUDE_HOME="$d/" bash install.sh --no-tests >/dev/null && links_in "$d"; }
# settings.json edited between the preflight and the write keeps that edit: a python3 shim edits it right after the preflight ran
inst_mm() { local d="$H/x" real; real=$(command -v python3); mkdir -p "$H/shim" "$d" && printf '{"a": 1}\n' > "$d/settings.json" &&
  cat > "$H/shim/python3" <<SHIM
#!/bin/bash
"$real" "\$@"; rc=\$?
case " \$* " in *settings.json*) [ -e "$H/shim/done" ] || { : > "$H/shim/done"; printf '{"a": 1, "mine": 2}\n' > "$d/settings.json"; };; esac
exit \$rc
SHIM
  chmod +x "$H/shim/python3" && PATH="$H/shim:$PATH" env HOME=$H CLAUDE_HOME=$d bash install.sh --no-tests >/dev/null &&
  [ -e "$H/shim/done" ] && python3 -B -I -c "
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get('mine') == 2 and 'hooks' in d, d
" "$d/settings.json"; }
# a relative CLAUDE_HOME: the hook names an absolute script that exists
inst_ii() { mkdir -p "$H/proj" && (cd "$H/proj" && env HOME=$H CLAUDE_HOME=rel/home bash "$ROOT/install.sh" --no-tests >/dev/null) &&
  python3 -B -I -c "
import json, shlex, sys, os
c = [h['command'] for v in json.load(open(sys.argv[1]))['hooks'].values() for e in v for h in e['hooks']]
w = shlex.split(c[0])[1]
assert os.path.isabs(w) and os.path.isfile(w), c
" "$H/proj/rel/home/settings.json"; }
# a hook whose command is not a string: exit 2 naming the event, no traceback, nothing written
inst_jj() { mkdir -p "$H/.claude" && printf '%s' '{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":null}]}]}}' > "$H/.claude/settings.json" &&
  { inst --no-tests > "$H/out" 2>&1; [ $? = 2 ]; } && grep -qF 'PostToolUse' "$H/out" && ! grep -q Traceback "$H/out" &&
  [ ! -e "$H/.claude/concord" ] && [ ! -e "$H/.claude/CLAUDE.md" ]; }
s_install() { local c; for c in a b c d e f g h i j k l m n o p q r s u v w x y z aa bb dd ee ff gg hh ii jj kk ll mm nn oo pp; do H=$(tmpd); check "install/$c" "inst_$c"; done; }

# Style: concord.py reads concord/style.conf (prose = terse, the default, or a sentence of your own). The
# executor task (a dry-run prompt) and the review prompt then carry that sentence.
style_prompts() {  # $1 = prose value ("" = no style.conf, default); writes $SD/exec.txt and $SD/review.txt
  local pr=$1 D H R DP RUNS p rid
  D="$SD/concord"; mkdir -p "$D"
  cp -p $K/concord.py $K/wt.py $K/*.md $K/*.conf "$D/" 2>/dev/null
  cp -Rp $K/repo-notes "$D/"
  if [ -n "$pr" ]; then printf 'prose = %s\n' "$pr" > "$D/style.conf"; else rm -f "$D/style.conf"; fi
  printf 'qwen.env = FAKE_*\n' >> "$D/executors.conf"
  H="$SD/home"; mkdir -p "$H/bin"
  cat > "$H/bin/qwen" <<'Q'
#!/bin/sh
if [ -n "${FAKE_ACTIONS:-}" ]; then sh -c "$FAKE_ACTIONS"; fi
printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n'
Q
  chmod +x "$H/bin/qwen"
  R="$SD/repo"; mkdir -p "$R"; RUNS="$R/.git/concord"
  ( cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t &&
    printf 'x = 1\n' > a.py &&
    printf '# Plan\n## Phase 1 - p1\nExecutor: deepseek-flash\nFiles: a.py\nAcceptance:\n- `grep -q 2 a.py`\n' > PLAN_S.md &&
    git add -A && git commit -qm init ) >/dev/null 2>&1
  DP="python3 $D/concord.py"
  : > "$SD/exec.txt"; : > "$SD/review.txt"
  # the plan needs a plan-verifier APPROVE of the plan read --lint writes (no model here: a scripted answer quotes it)
  rd=$(env -u CLAUDE_HOME PATH="$H/bin:$PATH" HOME="$H" $DP --lint 1 --plan PLAN_S.md --repo "$R" 2>/dev/null | sed -n 's/^PLAN-READ: //p' | head -1)
  printf 'VERDICT: APPROVE\nPLAN-HASH: %s\n' "$(basename "$rd" .md)" > "$SD/verdict.txt"
  env -u CLAUDE_HOME PATH="$H/bin:$PATH" HOME="$H" $DP --plan-verdict "$SD/verdict.txt" --plan PLAN_S.md --repo "$R" > /dev/null 2>&1
  env -u CLAUDE_HOME PATH="$H/bin:$PATH" HOME="$H" $DP 1 --plan PLAN_S.md --dry-run --via qwen --model fake/m --no-baseline --repo "$R" > "$SD/d.out" 2>&1
  p=$(sed -n 's/^prompt: //p' "$SD/d.out"); [ -f "$p" ] && cp "$p" "$SD/exec.txt"
  env -u CLAUDE_HOME PATH="$H/bin:$PATH" HOME="$H" FAKE_ACTIONS="echo '# r' >> a.py" $DP 1 --plan PLAN_S.md --via qwen --model fake/m --no-baseline --repo "$R" > "$SD/r.out" 2>&1
  rid=$(sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' "$SD/r.out" | head -1)
  env -u CLAUDE_HOME PATH="$H/bin:$PATH" HOME="$H" $DP --review "$rid" --via qwen --model fake/m --repo "$R" > "$SD/rev.out" 2>&1
  p="$(ls -td "$RUNS"/*-review-* 2>/dev/null | head -1)/prompt.txt"; [ -f "$p" ] && cp "$p" "$SD/review.txt"
}
s_style() {
  SD=$(tmpd); style_prompts "Write all prose as ZZSTYLE fragments."
  check style/task-custom "grep -q ZZSTYLE '$SD/exec.txt'"
  check style/review-custom "grep -q ZZSTYLE '$SD/review.txt'"
  SD=$(tmpd); style_prompts ""
  check style/task-lean "grep -q 'lean STE' '$SD/exec.txt'"
  check style/review-lean "grep -q 'lean STE' '$SD/review.txt'"; }

# Release hygiene: the two manifest versions are equal; no PLAN_*.md (bar the two templates) or __pycache__ is tracked.
s_hygiene() {
  check hygiene/versions "python3 -B -I -c \"import json; m=json.load(open('.claude-plugin/marketplace.json'))['plugins'][0]['version']; p=json.load(open('$A/.claude-plugin/plugin.json'))['version']; assert m==p, (m,p)\""
  check hygiene/no-plan-md "[ -z \"\$(git ls-files | grep -E '(^|/)PLAN_[^/]*\.md\$' | grep -vE '(^|/)(PLAN_TEMPLATE|PLAN_example)\.md\$')\" ]"
  check hygiene/no-pycache "[ -z \"\$(git ls-files | grep -E '__pycache__|\.pyc\$')\" ]"; }

s_docs() { local h f
  for h in Contents 'How it works' Install 'Try it without credentials' 'Run a ticket' Components Safety Results Citation Contributing License; do
    check "docs/readme-$(echo "$h" | tr 'A-Z ' 'a-z-')" "grep -qiE '^#{1,3} +$h' README.md"; done
  for f in CONTRIBUTING.md docs/SETUP.md docs/COMPARISON.md assets/concord-wordmark.svg; do check "docs/exists-$f" "[ -f '$f' ]"; done
  check docs/readme-links "grep -q 'docs/SETUP.md' README.md && grep -q 'docs/WORKFLOW.md' README.md && grep -q install.sh README.md"
  check docs/setup-harnesses "grep -q Codex docs/SETUP.md && grep -q OpenCode docs/SETUP.md"
  check docs/links "links_ok README.md CONTRIBUTING.md docs/*.md"
  check docs/lint-count "counts_ok \$(sed -n '/^def acceptance_lint(/,/^def /p' $K/concord.py | grep -c 'out\.append(') defects docs/WORKFLOW.md"
  for f in docs/figures/*.svg; do check "docs/figure-$(basename "$f")" "grep -qF '$(basename "$f")' README.md docs/*.md"; done
  check docs/no-todo "! grep -lwE 'TODO|TBD|XXX' README.md docs/*.md $A/CLAUDE.md install.sh CONTRIBUTING.md"
  check docs/claude-md "grep -qF '<!-- concord:begin -->' $A/CLAUDE.md && grep -qF '<!-- concord:end -->' $A/CLAUDE.md"
  # Commands and agents come from the concord plugin, so docs name them concord:<name> (agent file names and name: lines excepted).
  local scope="README.md docs CONTRIBUTING.md $A $K/PLAN_TEMPLATE.md $K/repo-notes/README.md"
  check docs/plugin-commands "! git grep -n -I --untracked -E '(^|[^:a-z])/(run|plan-then-delegate|delegate|rules-review)([^/a-z.-]|\$)' -- $scope"
  # the docs name each agent by its role; the installed CLAUDE.md block gives the name to spawn it by (concord:<name> in
  # the plugin), so only the setup table spells the plugin names
  check docs/agent-names "! git grep -n -I --untracked -E 'concord:(implementer|reviewer-|plan-verifier)' -- $scope | grep -v '^docs/SETUP.md:[0-9]*:| Agents |'"; }

s_blog() {
  check blog/exists "[ -f docs/BLOG.md ]"
  check blog/words "w=\$(wc -w < docs/BLOG.md); [ \$w -ge 2400 ] && [ \$w -le 3200 ] || { echo \"\$w words\"; false; }"
  check blog/references "[ \$(grep -cE '^\[[0-9]+\]' docs/BLOG.md) -le 10 ]"
  check blog/links "links_ok docs/BLOG.md"; }

SECTIONS="scrub layout agents python install style hygiene docs"
if [ $# = 0 ]; then for s in $SECTIONS; do "s_$s"; done
else sec=$1; shift; case " $SECTIONS blog " in *" $sec "*) "s_$sec" "$@";; *) echo "unknown section: $sec" >&2; exit 2;; esac; fi
echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
