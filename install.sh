#!/bin/bash
# Install the Concord dispatcher into $CLAUDE_HOME (default ~/.claude). Re-runnable: code refreshed, dropped
# suites removed, user configs and hand-edited files kept, replaced files backed up first (never pruned).
# --link (default): dispatcher in concord/, commands/agents symlinked in, the rules merged into CLAUDE.md
#   between <!-- concord:begin --> and <!-- concord:end -->, the settings keys merged into settings.json.
# --plugin: remove those links, print the marketplace commands; the CLAUDE.md block names agents concord:<name>.
# Usage: install.sh [--link|--plugin] [--dry-run] [--no-tests] [--repo DIR]
set -euo pipefail
shopt -s nullglob

MODE=link; DRY=0; TESTS=1; REPO=""
usage() { echo "usage: install.sh [--link|--plugin] [--dry-run] [--no-tests] [--repo DIR]" >&2; exit 2; }
err() { echo "error: $*" >&2; exit 2; }

[ -n "${CLAUDE_HOME:-}" ] || [ -n "${HOME:-}" ] || err "HOME and CLAUDE_HOME are both unset"
DEST="${CLAUDE_HOME:-$HOME/.claude}"
while [ $# -gt 0 ]; do
  case $1 in
    --link) MODE=link ;;
    --plugin) MODE=plugin ;;
    --dry-run) DRY=1 ;;
    --no-tests) TESTS=0 ;;
    --repo) if [ $# -ge 2 ] && [ -n "$2" ]; then REPO=$2; shift; else usage; fi ;;
    *) usage ;;
  esac
  shift
done

SRC="$(cd "$(dirname "$0")" && pwd -P)"; A="$SRC/adapters/claude-code";
[ -f "$SRC/concord/concord.py" ] || err "concord/concord.py not found in $SRC; run install.sh from the Concord checkout"
[ -z "$REPO" ] || [ -d "$REPO" ] || err "--repo $REPO is not an existing directory"
command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' >/dev/null 2>&1 \
  || err "python3 >= 3.9 required"
command -v git >/dev/null 2>&1 || err "git required"
command -v opencode >/dev/null 2>&1 \
  || echo "warning: opencode not on PATH; OpenCode executors will not run until it is installed" >&2
AGENTS="implementer implementer-opus48 reviewer-opus55 reviewer-delta plan-verifier"

BK=""   # one timestamped backup dir per run, created the first time something is backed up
ensure_bk() { [ -n "$BK" ] && return 0
  BK="$DEST/concord/backup/$(date +%Y%m%d-%H%M%S)-pre-install"; [ -e "$BK" ] && BK="$BK.$$"
  if [ "$DRY" = 1 ]; then echo "would backup $BK"; return 0; fi
  mkdir -p "$BK"; echo "backup $BK"; }
backup_into() { [ -e "$1" ] || return 0; ensure_bk; [ "$DRY" = 1 ] && return 0
  mkdir -p "$(dirname "$BK/$2")"
  if [ -L "$1" ] && [ -f "$1" ]; then cp -pL "$1" "$BK/$2"; else cp -Rp "$1" "$BK/$2"; fi; }  # a symlinked file: back up its content
put() { if [ "${3:-}" = keep ] && [ -e "$2" ]; then
    if [ "$DRY" = 1 ]; then echo "would keep $2"; else echo "keep $2"; fi; return 0; fi
  if [ "$DRY" = 1 ]; then echo "would copy $2"; return 0; fi
  mkdir -p "$(dirname "$2")"; cp -p "$1" "$2"; echo "copy $2"; }

# Back up every concord file this install would overwrite (never backup/ itself or runs.jsonl).
if [ -e "$DEST/concord/concord.py" ]; then
  for f in "$DEST"/concord/*.py "$DEST"/concord/*.md "$DEST"/concord/*.conf "$DEST"/concord/*.sb; do backup_into "$f" "$(basename "$f")"; done
  [ -d "$DEST/concord/tests" ] && backup_into "$DEST/concord/tests" tests
  [ -d "$DEST/concord/repo-notes" ] && backup_into "$DEST/concord/repo-notes" repo-notes
fi
for f in "$SRC"/concord/*.py "$SRC"/concord/*.md "$SRC"/concord/*.sb; do [ -e "$f" ] && put "$f" "$DEST/concord/$(basename "$f")"; done
for f in "$SRC"/concord/tests/*.sh; do put "$f" "$DEST/concord/tests/$(basename "$f")"; done
if [ -n "${BK:-}" ] && [ -d "$DEST/concord/tests" ]; then   # suites this source no longer ships; the backup above keeps them
  for f in "$DEST"/concord/tests/*_test.sh; do [ -e "$SRC/concord/tests/$(basename "$f")" ] && continue
    if [ "$DRY" = 1 ]; then echo "would remove $f"; else rm "$f"; echo "remove $f"; fi
  done
fi
for f in "$SRC"/concord/models.conf "$SRC"/concord/executors.conf "$SRC"/concord/worktrees.conf \
    "$SRC"/concord/style.conf "$SRC"/concord/repo-notes/README.md; do
  [ -e "$f" ] && put "$f" "$DEST/concord/${f#"$SRC"/concord/}" keep
done

# commands/agents: symlink into the checkout in --link (edits are live; an existing non-link file is kept and
# reported), remove the links in --plugin.
link_one() { if [ -e "$2" ] && [ ! -L "$2" ]; then echo "keep $2 (not a link; left as is)"; return 0; fi
  if [ "$DRY" = 1 ]; then echo "would link $2"; return 0; fi
  mkdir -p "$(dirname "$2")"; ln -sfn "$1" "$2"; echo "link $2"; }
unlink_one() { [ -L "$1" ] || return 0
  if [ "$DRY" = 1 ]; then echo "would remove link $1"; else rm -f "$1"; echo "remove link $1"; fi; }
if [ "$MODE" = link ]; then
  link_one "$A/commands" "$DEST/commands/concord"; for n in $AGENTS; do link_one "$A/agents/$n.md" "$DEST/agents/$n.md"; done
else
  unlink_one "$DEST/commands/concord"; for n in $AGENTS; do unlink_one "$DEST/agents/$n.md"; done
fi

# CLAUDE.md: keep the Concord rules between the markers and replace that block where it stands; a file with
# unpaired markers is refused untouched; a symlinked CLAUDE.md is written through; the file is backed up first.
# --link names the agents <name>; --plugin names them concord:<name>.
install_claude_md() { local md="$DEST/CLAUDE.md"
  if [ "$DRY" = 1 ]; then echo "would update $md"; return 0; fi
  mkdir -p "$DEST"; [ -e "$md" ] && backup_into "$md" CLAUDE.md
  python3 -B -I - "$A/CLAUDE.md" "$md" "$MODE" <<'PY' || exit 2
import os, re, sys
src, md, mode = sys.argv[1:4]
B, E = "<!-- concord:begin -->", "<!-- concord:end -->"
block = open(src).read().rstrip("\n").split("\n")
if mode == "plugin":
    block = [re.sub(r"`(reviewer-opus55|reviewer-delta|plan-verifier|implementer-opus48|implementer)`", r"`concord:\1`", l) for l in block]
    block = ["- Agent names: the concord plugin provides the agents above as `concord:reviewer-opus55`, "
             "`concord:reviewer-delta`, `concord:plan-verifier`, `concord:implementer-opus48` and `concord:implementer`." if l.startswith("- Agent names:") else l for l in block]
old = open(md).read().split("\n") if os.path.exists(md) else []
if old and old[-1] == "":
    old.pop()
nb, ne = old.count(B), old.count(E)
heads = [i for i, l in enumerate(old) if l.startswith("# Default workflow: plan, then delegate")]
if (nb, ne) == (0, 0) and heads:   # a block merged by hand before 2.1: replace it, from its heading to its "- Tokens:" rule
    ends = [i for i, l in enumerate(old) if i > heads[0] and l.startswith("- Tokens:")]
    if len(heads) != 1 or not ends:
        sys.exit(f"error: {md} holds an unmarked Concord block install.sh cannot delimit; wrap it in the markers by hand (left untouched)")
    new = old[:heads[0]] + block + old[ends[0] + 1:]
elif (nb, ne) == (0, 0):
    new = old + block
elif (nb, ne) == (1, 1) and old.index(B) < old.index(E):
    new = old[:old.index(B)] + block + old[old.index(E) + 1:]
else:
    sys.exit(f"error: {md} has {nb} begin and {ne} end Concord markers; fix them by hand (left untouched)")
with open(md, "w") as f:  # writes through a symlink and keeps the file's mode
    f.write("\n".join(new) + "\n")
PY
  echo "update $md"; }
install_claude_md

# settings.json: add the snippet's missing keys, keep every existing value and remove the retired concord.py
# hooks; back the file up first.
install_settings() { local s="$DEST/settings.json" snip="$A/settings.snippet.json"
  [ -f "$snip" ] || return 0
  if [ "$DRY" = 1 ]; then echo "would update $s"; return 0; fi
  mkdir -p "$DEST"; [ -e "$s" ] && backup_into "$s" settings.json
  python3 -B -I - "$snip" "$s" <<'PY'
import json, os, sys
with open(sys.argv[1]) as f: snip = json.load(f)
base = {}
if os.path.exists(sys.argv[2]):
    with open(sys.argv[2]) as f: base = json.load(f)
def merge(b, a):
    for k, v in a.items():
        if k not in b: b[k] = v
        elif isinstance(b[k], dict) and isinstance(v, dict): merge(b[k], v)
merge(base, snip)
# Each snippet hook joins its event's existing list once, matched by its --*-hook flag (a plain missing-key merge
# would skip it).
for event, entries in snip.get("hooks", {}).items():
    have = base.setdefault("hooks", {}).setdefault(event, [])
    known = " ".join(h.get("command", "") for e in have for h in e.get("hooks", []))
    have.extend(e for e in entries
                if not all(w in known for h in e.get("hooks", []) for w in h["command"].split() if w.endswith("-hook")))
# A hook that calls concord.py with a --*-hook flag this snippet no longer ships is retired (an old --lessons-hook,
# say). The other hooks of its entry stay; an entry left with no hooks goes.
flags = {w for v in snip.get("hooks", {}).values() for e in v for h in e.get("hooks", []) for w in h["command"].split()}
def retired(h): return "concord.py" in h.get("command", "") and any(w.endswith("-hook") and w not in flags for w in h["command"].split())
for event, entries in base.get("hooks", {}).items():
    for e in entries:
        e["hooks"] = [h for h in e["hooks"] if not retired(h)]
    base["hooks"][event] = [e for e in entries if e["hooks"]]
with open(sys.argv[2], "w") as f: json.dump(base, f, indent=2); f.write("\n")
PY
  echo "update $s"; }
install_settings

if [ "$MODE" = plugin ]; then
  echo "next: in Claude Code run /plugin marketplace add bqp007/concord-agent-harness (or the path of this clone)"
  echo "next: then run /plugin install concord@concord"
fi
if [ -n "$REPO" ]; then
  for f in "$SRC"/adapters/claude-code/hookify/*.md; do put "$f" "$REPO/.claude/hookify.$(basename "$f" .md).local.md" keep; done
  echo "note: add .claude/hookify.*.local.md to $REPO/.git/info/exclude unless it is already ignored"
fi
if [ "$DRY" = 0 ] && [ "$TESTS" = 1 ]; then bash "$DEST/concord/tests/run_all.sh"; fi
