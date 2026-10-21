#!/bin/bash
# Run every *_test.sh of Concord in parallel (each suite already uses its own temp dir and fake HOME).
# Prints one summary line per suite, then each failing suite's FAIL lines. Exit 0 only when every suite passed.
# Run: bash ~/.claude/concord/tests/run_all.sh
set -u
DIR="$(cd "$(dirname "$0")" && pwd -P)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/run-all.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
start=$(date +%s)
for t in "$DIR"/*_test.sh; do
  n=$(basename "$t" .sh)
  ( bash "$t" > "$OUT/$n.log" 2>&1; echo $? > "$OUT/$n.rc" ) &
done
wait
rc_all=0
for t in "$DIR"/*_test.sh; do
  n=$(basename "$t" .sh); rc=$(cat "$OUT/$n.rc")
  summary=$(grep -E '^passed [0-9]+, failed [0-9]+' "$OUT/$n.log" | tail -1)
  [ "$rc" = 0 ] || rc_all=1
  printf '%-22s %s%s\n' "$n" "${summary:-no summary line}" "$([ "$rc" = 0 ] || echo "  (exit $rc)")"
done
for t in "$DIR"/*_test.sh; do
  n=$(basename "$t" .sh)
  [ "$(cat "$OUT/$n.rc")" = 0 ] || { echo "== $n failures"; grep -E '^  FAIL' "$OUT/$n.log" | head -20; }
done
echo "all suites: $([ $rc_all = 0 ] && echo PASS || echo FAIL) in $(( $(date +%s) - start ))s"
exit $rc_all
