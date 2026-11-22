#!/bin/bash
# Install the Concord dispatcher into $CLAUDE_HOME (default ~/.claude). Re-runnable: code refreshed, dropped
# suites removed, user configs and hand-edited files kept, replaced files backed up first (never pruned).
# --link (default): dispatcher in concord/, commands, agents and skills symlinked in, the rules merged into CLAUDE.md
#   between <!-- concord:begin --> and <!-- concord:end -->, the settings keys merged into settings.json.
# --plugin: remove those links, print the marketplace commands; the CLAUDE.md block names agents and skills concord:<name>.
# Usage: install.sh [--link|--plugin] [--dry-run] [--no-tests] [--repo DIR]
set -euo pipefail
shopt -s nullglob

MODE=link; DRY=0; TESTS=1; REPO=""
usage() { echo "usage: install.sh [--link|--plugin] [--dry-run] [--no-tests] [--repo DIR]" >&2; exit 2; }
err() { echo "error: $*" >&2; exit 2; }

[ -n "${CLAUDE_HOME:-}" ] || [ -n "${HOME:-}" ] || err "HOME and CLAUDE_HOME are both unset"
DEST="${CLAUDE_HOME:-$HOME/.claude}"
case "$DEST" in /*) ;; *) DEST="$PWD/${DEST#./}" ;; esac   # a relative CLAUDE_HOME resolves from here, before any use
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
SKILLS=""; for d in "$A"/skills/*/; do [ -f "${d}SKILL.md" ] && SKILLS="$SKILLS $(basename "$d")"; done   # every shipped skill directory

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

# Nothing is written before the merged settings.json is computed and the CLAUDE.md markers pair: a refusal leaves the
# installation as it was. The merge below is the one install_settings writes out: a settings file it cannot merge (not a
# JSON object, or `hooks` or another merged key of another shape than the merge reads) stops the install here.
MERGED="$(mktemp "${TMPDIR:-/tmp}/concord-settings.XXXXXX")" || err "cannot create a temporary file"
trap 'rm -f "$MERGED"' EXIT
python3 -B -I - "$DEST/settings.json" "$DEST/CLAUDE.md" "$A/settings.snippet.json" "$DEST" "$MERGED" <<'PY' || exit 2
import json, os, re, sys
settings, md, snippet, dest, merged = sys.argv[1:6]
def refuse(msg):
    sys.exit(f"error: {settings} {msg}; fix or move it, then run install.sh again (nothing written)")
base = {}
if os.path.exists(settings):
    try:
        with open(settings) as f:
            base = json.load(f)
    except (OSError, ValueError) as exc:
        refuse(f"does not parse ({exc})")
    if not isinstance(base, dict):
        refuse(f"is not a JSON object (it holds a {type(base).__name__})")
if os.path.exists(snippet):
    with open(snippet) as f: snip = json.load(f)
    # The token sits inside single quotes in an sh command: a single quote in the path is closed, escaped and reopened.
    # The substitution runs on the parsed strings, so json.dump escapes the path for the JSON file.
    home = dest.replace("'", "'\\''")
    def fill(v):
        if isinstance(v, str): return v.replace("@CONCORD_HOME@", home)
        if isinstance(v, list): return [fill(x) for x in v]
        if isinstance(v, dict): return {k: fill(x) for k, x in v.items()}
        return v
    snip = fill(snip)
    def merge(b, a, path):
        for k, v in a.items():
            if k not in b: b[k] = v
            elif isinstance(v, dict):
                if not isinstance(b[k], dict):
                    refuse(f"holds {path}{k} as a {type(b[k]).__name__}; the merge reads an object there")
                merge(b[k], v, f"{path}{k}.")
    hooks = snip.pop("hooks", {})
    have_hooks = base.get("hooks", {})
    if not isinstance(have_hooks, dict):
        refuse(f"holds hooks as a {type(have_hooks).__name__}; the merge reads an object of event lists")
    for event, entries in have_hooks.items():
        if not isinstance(entries, list) or not all(isinstance(e, dict) and isinstance(e.get("hooks", []), list)
                                                     and all(isinstance(h, dict) for h in e.get("hooks", []))
                                                     for e in entries):
            refuse(f"holds hooks.{event} in another shape than a list of {{\"hooks\": [{{...}}]}} entries")
    for event, entries in have_hooks.items():
        for e in entries:
            for h in e.get("hooks", []):
                if "command" in h and not isinstance(h["command"], str):
                    refuse(f"holds a hook in hooks.{event} whose command is a {type(h['command']).__name__}, not a string "
                           f"(entry {json.dumps(h)})")
    merge(base, snip, "")
    # A hook is replaced only when its whole command equals one this installer ships or shipped before:
    # `python3 "$HOME/.claude/concord/concord.py" --drift-hook 2>/dev/null || true` (or --lessons-hook), or
    # `sh '<home>/concord/drift_hook.sh' 2>/dev/null || true` (double quotes before; the quoted path holds no quote, so a
    # user's command before the shipped one is no part of it), or the exact command this run writes, whatever its home
    # path holds. A user's own hook stays, and so does a shipped command with anything added; the installer names each
    # such kept hook.
    TAIL = r" 2>/dev/null \|\| true"
    SHIPPED = re.compile(r'^(python3 "\$HOME/\.claude/concord/concord\.py" --(drift|lessons)-hook|'
                         r'sh (["\'])[^"\']*/concord/drift_hook\.sh\3)' + TAIL + "$")
    CONTAINS = re.compile(r'python3 "\$HOME/\.claude/concord/concord\.py" --(drift|lessons)-hook\b|/concord/drift_hook\.sh')
    OWN = {h.get("command") for entries in hooks.values() for e in entries for h in e.get("hooks", [])}
    def shipped(h): return h.get("command") in OWN or bool(SHIPPED.match(h.get("command", "")))
    # Each snippet hook joins its event's existing list once, replacing the shipped hooks that stand there.
    for event, entries in hooks.items():
        have = base.setdefault("hooks", {}).setdefault(event, [])
        for e in have:
            e["hooks"] = [h for h in e.get("hooks", []) if not shipped(h)]
        base["hooks"][event] = [e for e in have if e.get("hooks")] + entries
    for event, entries in list(base.get("hooks", {}).items()):      # a retired hook of an event the snippet no longer names
        for e in entries:
            e["hooks"] = [h for h in e.get("hooks", []) if not (shipped(h) and event not in hooks)]
        base["hooks"][event] = [e for e in entries if e["hooks"]]
    kept = [h["command"] for entries in base.get("hooks", {}).values() for e in entries for h in e["hooks"]
            if isinstance(h.get("command"), str) and CONTAINS.search(h["command"]) and not shipped(h)]
    for c in kept:
        print(f"keep hook {c} (a shipped Concord command with additions; left as it is)")
    with open(merged, "w") as f: json.dump(base, f, indent=2); f.write("\n")
if os.path.exists(md):
    B, E = "<!-- concord:begin -->", "<!-- concord:end -->"
    old = open(md).read().split("\n")
    nb, ne = old.count(B), old.count(E)
    heading = any(l.startswith("# Default workflow: plan, then delegate") for l in old)
    if (nb, ne) == (0, 0) and heading:
        sys.exit(f"error: {md} holds a Concord block with no markers; install.sh cannot tell where it ends. Wrap it between "
                 f"{B} and {E} by hand (or delete it), then run install.sh again (nothing written)")
    if (nb, ne) != (0, 0) and not ((nb, ne) == (1, 1) and old.index(B) < old.index(E)):
        sys.exit(f"error: {md} has {nb} begin and {ne} end Concord markers; fix them by hand, then run install.sh again "
                 "(nothing written)")
PY

# Back up every concord file this install would overwrite (never backup/ itself or runs.jsonl).
if [ -d "$DEST/concord" ]; then
  for f in "$DEST"/concord/*.py "$DEST"/concord/*.md "$DEST"/concord/*.conf "$DEST"/concord/*.sb "$DEST"/concord/*.sh; do backup_into "$f" "$(basename "$f")"; done
  [ -d "$DEST/concord/tests" ] && backup_into "$DEST/concord/tests" tests
  [ -d "$DEST/concord/repo-notes" ] && backup_into "$DEST/concord/repo-notes" repo-notes
fi
for f in "$SRC"/concord/*.py "$SRC"/concord/*.md "$SRC"/concord/*.sb "$SRC"/concord/*.sh; do [ -e "$f" ] && put "$f" "$DEST/concord/$(basename "$f")"; done
for f in "$SRC"/concord/tests/*.sh; do put "$f" "$DEST/concord/tests/$(basename "$f")"; done
RETIRED_SUITES="card lessons map reuse slim"   # suites Concord shipped and retired; any other suite in tests/ is the user's
if [ -n "${BK:-}" ] && [ -d "$DEST/concord/tests" ]; then   # the backup above keeps them
  for n in $RETIRED_SUITES; do f="$DEST/concord/tests/${n}_test.sh"; [ -e "$f" ] || continue
    if [ "$DRY" = 1 ]; then echo "would remove $f"; else rm "$f"; echo "remove $f"; fi
  done
fi
for f in "$SRC"/concord/models.conf "$SRC"/concord/executors.conf "$SRC"/concord/worktrees.conf \
    "$SRC"/concord/style.conf "$SRC"/concord/repo-notes/README.md; do
  [ -e "$f" ] && put "$f" "$DEST/concord/${f#"$SRC"/concord/}" keep
done

# commands, agents and skills: symlink into the checkout in --link (edits are live; an existing non-link file is kept and
# reported), remove the links in --plugin that point into this checkout (any other link of the name is kept and reported).
# One ownership rule for both: a link is Concord's when it points to this checkout's source for that name, or to the same
# path inside another checkout of this kit (a moved checkout); any other link is kept and reported.
ours() { local t rel="${2#"$SRC"/}"; t="$(readlink "$1")"; [ "$t" = "$2" ] || case "$t" in */"$rel") true;; *) false;; esac; }
keep_note() { echo "keep $1 (a link to $(readlink "$1"), not made by Concord; left as is)"; }
link_one() { if [ -e "$2" ] && [ ! -L "$2" ]; then echo "keep $2 (not a link; left as is)"; return 0; fi
  if [ -L "$2" ] && ! ours "$2" "$1"; then keep_note "$2"; return 0; fi
  if [ "$DRY" = 1 ]; then echo "would link $2"; return 0; fi
  mkdir -p "$(dirname "$2")"; ln -sfn "$1" "$2"; echo "link $2"; }
unlink_one() { [ -L "$1" ] || return 0
  ours "$1" "$2" || { keep_note "$1"; return 0; }
  if [ "$DRY" = 1 ]; then echo "would remove link $1"; else rm -f "$1"; echo "remove link $1"; fi; }
if [ "$MODE" = link ]; then
  link_one "$A/commands" "$DEST/commands/concord"; for n in $AGENTS; do link_one "$A/agents/$n.md" "$DEST/agents/$n.md"; done
  for n in $SKILLS; do link_one "$A/skills/$n" "$DEST/skills/$n"; done
else
  unlink_one "$DEST/commands/concord" "$A/commands"; for n in $AGENTS; do unlink_one "$DEST/agents/$n.md" "$A/agents/$n.md"; done
  for n in $SKILLS; do unlink_one "$DEST/skills/$n" "$A/skills/$n"; done
fi

# CLAUDE.md: keep the Concord rules between the markers and replace that block where it stands; a file with
# unpaired markers, or a Concord block without markers, is refused untouched; a symlinked CLAUDE.md is written through; the file is backed up first.
# --link names the agents and skills <name>; --plugin names them concord:<name>.
install_claude_md() { local md="$DEST/CLAUDE.md"
  if [ "$DRY" = 1 ]; then echo "would update $md"; return 0; fi
  mkdir -p "$DEST"; [ -e "$md" ] && backup_into "$md" CLAUDE.md
  python3 -B -I - "$A/CLAUDE.md" "$md" "$MODE" $SKILLS <<'PY' || exit 2
import os, re, sys
src, md, mode = sys.argv[1:4]
skills = sys.argv[4:]
B, E = "<!-- concord:begin -->", "<!-- concord:end -->"
block = open(src).read().rstrip("\n").split("\n")
if mode == "plugin":
    block = [re.sub(r"`(reviewer-opus55|reviewer-delta|plan-verifier|implementer-opus48|implementer)`", r"`concord:\1`", l) for l in block]
    for name in skills:
        block = [l.replace(f"`{name}`", f"`concord:{name}`") for l in block]
    block = ["- Agent names: the concord plugin provides the agents above as `concord:reviewer-opus55`, "
             "`concord:reviewer-delta`, `concord:plan-verifier`, `concord:implementer-opus48` and `concord:implementer`." if l.startswith("- Agent names:") else l for l in block]
old = open(md).read().split("\n") if os.path.exists(md) else []
if old and old[-1] == "":
    old.pop()
nb, ne = old.count(B), old.count(E)
heads = [i for i, l in enumerate(old) if l.startswith("# Default workflow: plan, then delegate")]
if (nb, ne) == (0, 0) and heads:   # the preflight refuses this before anything is written
    sys.exit(f"error: {md} holds a Concord block with no markers; wrap it in the markers by hand (left untouched)")
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

# settings.json: write the merge the preflight computed (the snippet's missing keys added, every existing value kept,
# the hooks this installer shipped replaced); back the file up first.
install_settings() { local s="$DEST/settings.json" snip="$A/settings.snippet.json"
  [ -f "$snip" ] || return 0
  if [ "$DRY" = 1 ]; then echo "would update $s"; return 0; fi
  mkdir -p "$DEST"; [ -e "$s" ] && backup_into "$s" settings.json
  cat "$MERGED" > "$s"     # writes through a symlinked settings.json and keeps its mode
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
