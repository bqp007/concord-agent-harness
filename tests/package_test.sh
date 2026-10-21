#!/bin/bash
# Repository contract checks. Run from anywhere: bash tests/package_test.sh [SECTION [TREE ...]]
# Sections: scrub layout budgets agents python install docs (none = all); blog runs only when named.
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
AGENTS="implementer implementer-opus48 reviewer-opus48 reviewer-opus55 verifier"
COMMANDS="plan-then-delegate delegate rules-review"
HOOKS="block-destructive-git block-rm-outside-scratch block-plan-md block-rm-home-paths"
SUITES="acclint delegate delta guards papers pr_review protocol slim testquality worktree"

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
    $K/worktrees.conf $K/repo-notes/README.md $K/tests/run_all.sh $A/CLAUDE.md $A/settings.snippet.json
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

s_budgets() { local spec f
  for spec in README.md:220 install.sh:90 $A/CLAUDE.md:25 $A/commands/delegate.md:60 \
      $A/commands/plan-then-delegate.md:25 docs/WORKFLOW.md:400 tests/package_test.sh:200 tests/demo_test.sh:120 \
      $A/settings.snippet.json:12 $K/repo-notes/README.md:15; do
    local f=${spec%%:*} n=${spec##*:} name; name=$(basename "$f"); [ "$f" = $K/repo-notes/README.md ] && name=repo-notes-README.md
    check "budgets/$name" "[ -f '$f' ] && [ \$(wc -l < '$f') -le $n ] || { wc -l '$f'; false; }"
  done
  for spec in scripts/demo.sh:220 examples/PLAN_example.md:60; do f=${spec%%:*}   # once they exist
    [ -f "$f" ] && check "budgets/$(basename "$f")" "[ \$(wc -l < '$f') -le ${spec##*:} ] || { wc -l '$f'; false; }"; done
  check budgets/concord.py "[ \$(wc -l < $K/concord.py) = 5639 ] || { wc -l $K/concord.py; false; }"
  check budgets/wt.py "[ \$(wc -l < $K/wt.py) = 441 ] || { wc -l $K/wt.py; false; }"
  check budgets/models.conf "[ \$(grep -c '=' $K/models.conf) = 30 ] || { grep -c '=' $K/models.conf; false; }"
  check budgets/executors.conf "[ \$(grep -cE '^[a-z_.]+ *=' $K/executors.conf) = 16 ]"
  check budgets/static_checks "grep -q '^static_checks = yes' $K/executors.conf"
  check budgets/track_ignored "grep -q '^track_ignored = yes' $K/executors.conf"; }

s_agents() { local a
  for a in $AGENTS; do check "agents/$a.md" "grep -q '^name: $a\$' $A/agents/$a.md"; done
  for a in implementer implementer-opus48; do check "agents/contract-$a.md" "grep -q '~/.claude/concord/CONTRACT.md' $A/agents/$a.md"; done
  check agents/model-reviewer-opus48.md "grep -q '^model: claude-opus-4-8\$' $A/agents/reviewer-opus48.md"
  check agents/model-reviewer-opus55.md "grep -q '^model: claude-opus-5-5\$' $A/agents/reviewer-opus55.md"
  for a in agents/implementer-opus48 agents/reviewer-opus48 agents/reviewer-opus55 commands/plan-then-delegate commands/delegate commands/rules-review; do
    check "agents/terse-$(basename $a).md" "grep -q terse $A/$a.md"; done
  check agents/concord.py "grep -qF 'Write all prose tersely: exact, no hedging, no praise.' $K/concord.py"
  check agents/CONTRACT.md "grep -qF 'terse (fragments, abbreviations, no filler)' $K/CONTRACT.md"; }

s_python() {
  check python/help "python3 -B -I $K/concord.py --help >/dev/null"
  check python/resolve-flash "python3 -B -I $K/concord.py --resolve deepseek-flash | grep -q opencode-go/deepseek-v4.1-flash"
  check python/resolve-glm "python3 -B -I $K/concord.py --resolve glm >/dev/null"
  check python/resolve-kimi "python3 -B -I $K/concord.py --resolve kimi-k3 >/dev/null"
  check python/wt-help "python3 -B -I $K/wt.py --help >/dev/null"
  check python/plugin-names "python3 -B -I $K/concord.py --help | grep -q 'concord:reviewer-opus48'"
  check python/plugin-hints "[ \$(grep -c 'subagent_type concord:reviewer-opus48 (medium) or concord:reviewer-opus55 (high)' $K/concord.py) = 2 ]"
  check python/settings "python3 -B -I -c \"import json; d=json.load(open('$A/settings.snippet.json')); m=d['modelSettings']; assert m['claude-opus-5-5']=={'autoCompactWindow':400000} and m['claude-fable-5-1']=={'autoCompactWindow':400000}; assert 'git push *' in d['sandbox']['excludedCommands']\""; }

inst() { env -u CLAUDE_HOME HOME=$H bash install.sh "$@"; }   # every case: fresh H, CLAUDE_HOME unset
inst_a() { local D; D=$(tmpd); inst --dry-run --repo "$D" > "$H/out" && grep -q '^would copy' "$H/out" &&
  ! grep -qE '^(copy|keep|backup) ' "$H/out" && [ ! -e "$H/.claude" ] && [ ! -e "$D/.claude" ]; }
inst_b() { inst --no-tests > "$H/out" || return 1; local f; for f in concord/concord.py concord/CONTRACT.md concord/models.conf \
    concord/tests/run_all.sh concord/repo-notes/README.md; do [ -f "$H/.claude/$f" ] || { echo "missing $f"; return 1; }; done
  [ ! -e "$H/.claude/CLAUDE.md" ] && [ ! -e "$H/.claude/settings.json" ] && [ ! -e "$H/.claude/commands" ] && [ ! -e "$H/.claude/agents" ] &&
  grep -qF '/plugin marketplace add' "$H/out" && grep -qF '/plugin install concord@concord' "$H/out"; }
inst_c() { inst --no-tests >/dev/null && echo mine > "$H/.claude/concord/models.conf" && printf x > "$H/.claude/CLAUDE.md" &&
  printf '{}' > "$H/.claude/settings.json" && mkdir -p "$H/.claude/agents" "$H/.claude/commands" && echo old > "$H/.claude/agents/implementer.md" &&
  echo old > "$H/.claude/commands/delegate.md" && inst --no-tests > "$H/out" &&
  [ "$(cat "$H/.claude/concord/models.conf")" = mine ] && [ "$(cat "$H/.claude/CLAUDE.md")" = x ] && [ "$(cat "$H/.claude/settings.json")" = '{}' ] &&
  cmp -s $K/concord.py "$H/.claude/concord/concord.py" && [ "$(cat "$H/.claude/agents/implementer.md")" = old ] &&
  [ "$(cat "$H/.claude/commands/delegate.md")" = old ] && grep -qF "$H/.claude/agents/implementer.md is from an earlier install" "$H/out" &&
  grep -qF "$H/.claude/commands/delegate.md is from an earlier install" "$H/out" &&
  [ "$(ls "$H"/.claude/concord/backup/*-pre-install*/concord.py | wc -l)" -eq 1 ]; }
inst_d() { local D n; D=$(tmpd); git -C "$D" init -q && inst --no-tests --repo "$D" >/dev/null &&
  for n in $HOOKS; do [ -f "$D/.claude/hookify.$n.local.md" ] || { echo "missing $n"; return 1; }; done &&
  echo custom > "$D/.claude/hookify.block-plan-md.local.md" && inst --no-tests --repo "$D" >/dev/null && [ "$(cat "$D/.claude/hookify.block-plan-md.local.md")" = custom ]; }
inst_e() { inst --bogus 2>/dev/null; [ $? = 2 ] && { inst --repo 2>/dev/null; [ $? = 2 ]; } && { inst --repo /nonexistent 2>/dev/null; [ $? = 2 ]; } && [ ! -e "$H/.claude" ]; }
inst_f() { mkdir "$H/bin" && printf '#!/bin/sh\nexit 1\n' > "$H/bin/python3" && chmod +x "$H/bin/python3"
  PATH="$H/bin:$PATH" inst --no-tests >/dev/null 2>"$H/err"; [ $? = 2 ] && grep -q python3 "$H/err"; }
inst_g() { env HOME=$H CLAUDE_HOME=$H/x bash install.sh --no-tests >/dev/null && [ -f "$H/x/concord/concord.py" ] && [ ! -e "$H/.claude" ]; }
s_install() { local c; for c in a b c d e f g; do H=$(tmpd); check "install/$c" "inst_$c"; done; }

s_docs() { local h f
  for h in Contents 'How it works' Install 'Try it without credentials' 'Run a ticket' Components Safety Results Citation Contributing License; do
    check "docs/readme-$(echo "$h" | tr 'A-Z ' 'a-z-')" "grep -qiE '^#{1,3} +$h' README.md"; done
  check docs/readme-words "[ \$(wc -w < README.md) -le 1800 ] || { wc -w README.md; false; }"
  check docs/workflow-words "[ \$(wc -w < docs/WORKFLOW.md) -le 3000 ] || { wc -w docs/WORKFLOW.md; false; }"
  for f in CONTRIBUTING.md docs/SETUP.md docs/COMPARISON.md assets/concord-wordmark.svg; do check "docs/exists-$f" "[ -f '$f' ]"; done
  check docs/setup-words "[ \$(wc -w < docs/SETUP.md) -le 1200 ] || { wc -w docs/SETUP.md; false; }"
  check docs/readme-links "grep -q 'docs/SETUP.md' README.md && grep -q 'docs/WORKFLOW.md' README.md && grep -q install.sh README.md"
  check docs/setup-harnesses "grep -q Codex docs/SETUP.md && grep -q OpenCode docs/SETUP.md"
  check docs/links "links_ok README.md CONTRIBUTING.md docs/*.md"
  for f in docs/figures/*.svg; do check "docs/figure-$(basename "$f")" "grep -qF '$(basename "$f")' README.md docs/*.md"; done
  check docs/no-todo "! grep -lE 'TODO|TBD|XXX' README.md docs/*.md $A/CLAUDE.md install.sh CONTRIBUTING.md"
  check docs/claude-md "grep -q '~/.claude/concord/concord.py' $A/CLAUDE.md && grep -q deepseek-flash $A/CLAUDE.md"
  check docs/plugin-install "grep -qF '/plugin install concord@concord' README.md && grep -qF '/plugin marketplace add' docs/SETUP.md && grep -qF '/concord:plan-then-delegate' README.md"
  # Commands and agents come from the concord plugin, so docs name them concord:<name> (agent file names and name: lines excepted).
  local scope="README.md docs CONTRIBUTING.md $A $K/PLAN_TEMPLATE.md $K/repo-notes/README.md"
  check docs/plugin-commands "! git grep -n -I --untracked -E '(^|[^:a-z])/(plan-then-delegate|delegate|rules-review)([^/a-z.-]|\$)' -- $scope"
  check docs/plugin-agents "! git grep -n -I --untracked -E '(^|[^:a-z0-9/-])(implementer-opus48|reviewer-opus48|reviewer-opus55)([^.a-z0-9-]|\$)|\`implementer\`' -- $scope | grep -v ':name: '"; }

s_blog() {
  check blog/exists "[ -f docs/BLOG.md ]"
  check blog/words "w=\$(wc -w < docs/BLOG.md); [ \$w -ge 2400 ] && [ \$w -le 3200 ] || { echo \"\$w words\"; false; }"
  check blog/references "[ \$(grep -cE '^\[[0-9]+\]' docs/BLOG.md) -le 10 ]"
  check blog/links "links_ok docs/BLOG.md"; }

SECTIONS="scrub layout budgets agents python install docs"
if [ $# = 0 ]; then for s in $SECTIONS; do "s_$s"; done
else sec=$1; shift; case " $SECTIONS blog " in *" $sec "*) "s_$sec" "$@";; *) echo "unknown section: $sec" >&2; exit 2;; esac; fi
echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
