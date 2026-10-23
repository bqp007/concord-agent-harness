#!/bin/bash
# Install the Concord dispatcher into $CLAUDE_HOME (default ~/.claude); Claude Code's commands and agents come from the concord plugin.
# Re-runnable: code is refreshed, suites the source dropped are removed, user configs are kept, replaced files are backed up first.
# Never writes $DEST/CLAUDE.md or $DEST/settings.json; backups are never pruned.
# Usage: install.sh [--dry-run] [--no-tests] [--repo DIR]
set -euo pipefail
shopt -s nullglob

DRY=0; TESTS=1; REPO=""
usage() { echo "usage: install.sh [--dry-run] [--no-tests] [--repo DIR]" >&2; exit 2; }
err() { echo "error: $*" >&2; exit 2; }

[ -n "${CLAUDE_HOME:-}" ] || [ -n "${HOME:-}" ] || err "HOME and CLAUDE_HOME are both unset"
DEST="${CLAUDE_HOME:-$HOME/.claude}"
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) DRY=1 ;;
    --no-tests) TESTS=0 ;;
    --repo) if [ $# -ge 2 ] && [ -n "$2" ]; then REPO=$2; shift; else usage; fi ;;
    *) usage ;;
  esac
  shift
done

SRC="$(cd "$(dirname "$0")" && pwd -P)"
[ -f "$SRC/concord/concord.py" ] || err "concord/concord.py not found in $SRC; run install.sh from the Concord checkout"
[ -z "$REPO" ] || [ -d "$REPO" ] || err "--repo $REPO is not an existing directory"
command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' >/dev/null 2>&1 \
  || err "python3 >= 3.9 required"
command -v git >/dev/null 2>&1 || err "git required"
command -v opencode >/dev/null 2>&1 \
  || echo "warning: opencode not on PATH; OpenCode executors will not run until it is installed" >&2

put() { # put SRC_FILE DEST_FILE [keep]
  if [ "${3:-}" = keep ] && [ -e "$2" ]; then
    if [ "$DRY" = 1 ]; then echo "would keep $2"; else echo "keep $2"; fi
    return 0
  fi
  if [ "$DRY" = 1 ]; then echo "would copy $2"; return 0; fi
  mkdir -p "$(dirname "$2")"
  cp -p "$1" "$2"
  echo "copy $2"
}

# Back up everything this install would overwrite (never backup/ itself or runs.jsonl).
del=()
if [ -e "$DEST/concord/concord.py" ]; then
  del+=("$DEST"/concord/*.py "$DEST"/concord/*.md "$DEST"/concord/*.conf)
  if [ -d "$DEST/concord/tests" ]; then del+=("$DEST/concord/tests"); fi
  if [ -d "$DEST/concord/repo-notes" ]; then del+=("$DEST/concord/repo-notes"); fi
fi
if [ ${#del[@]} -gt 0 ]; then
  BK="$DEST/concord/backup/$(date +%Y%m%d-%H%M%S)-pre-install"
  if [ -e "$BK" ]; then BK="$BK.$$"; fi
  if [ "$DRY" = 1 ]; then
    echo "would backup $BK"
  else
    mkdir -p "$BK"
    for f in ${del[@]+"${del[@]}"}; do cp -Rp "$f" "$BK/"; done
    echo "backup $BK"
  fi
fi

for f in "$SRC"/concord/*.py "$SRC"/concord/*.md; do put "$f" "$DEST/concord/$(basename "$f")"; done
for f in "$SRC"/concord/tests/*.sh; do put "$f" "$DEST/concord/tests/$(basename "$f")"; done
if [ -n "${BK:-}" ]; then  # suites this source no longer ships; the backup above keeps them
  for f in "$DEST"/concord/tests/*_test.sh; do
    if [ ! -e "$SRC/concord/tests/$(basename "$f")" ]; then
      if [ "$DRY" = 1 ]; then echo "would remove $f"; else rm "$f"; echo "remove $f"; fi
    fi
  done
fi
for f in "$SRC"/concord/models.conf "$SRC"/concord/executors.conf "$SRC"/concord/worktrees.conf "$SRC"/concord/repo-notes/README.md; do
  put "$f" "$DEST/concord/${f#"$SRC"/concord/}" keep
done
for f in "$SRC"/adapters/claude-code/commands/*.md "$SRC"/adapters/claude-code/agents/*.md; do
  o="$DEST/$(basename "$(dirname "$f")")/$(basename "$f")"
  if [ -e "$o" ]; then echo "note: $o is from an earlier install; remove it once the concord plugin is installed"; fi
done
echo "note: merge adapters/claude-code/CLAUDE.md into $DEST/CLAUDE.md and adapters/claude-code/settings.snippet.json into $DEST/settings.json by hand"
echo "next: in Claude Code run /plugin marketplace add bqp007/concord-agent-harness (or the path of this clone) and then /plugin install concord@concord"

if [ -n "$REPO" ]; then
  for f in "$SRC"/adapters/claude-code/hookify/*.md; do
    put "$f" "$REPO/.claude/hookify.$(basename "$f" .md).local.md" keep
  done
  echo "note: add .claude/hookify.*.local.md to $REPO/.git/info/exclude unless it is already ignored"
fi

if [ "$DRY" = 0 ] && [ "$TESTS" = 1 ]; then
  bash "$DEST/concord/tests/run_all.sh"
fi
