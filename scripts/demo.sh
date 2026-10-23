#!/bin/bash
# Usage: bash scripts/demo.sh [--keep]
# The governed loop with no model, no network and no account: a scripted executor first edits outside its
# scope (the phase fails, cause EXECUTOR), then fixes the bug inside it (red run, evidence, review, PASS).
# --keep keeps the temporary folder (success or failure) and prints its path. Exit: 0 ok, 2 bad input or
# python3/git unusable, otherwise the failing dispatcher step's exit code.
set -u
USAGE='Usage: bash scripts/demo.sh [--keep]'
KEEP=; W=; KEPT=
die() { echo "demo: $*" >&2; exit 2; }
fail() { local c=${2:-1}; [ "$c" = 0 ] && c=1; echo "demo: $1" >&2; exit "$c"; }
cleanup() {
  [ -n "$W" ] || return 0
  if [ -n "$KEEP" ]; then [ -n "$KEPT" ] || echo "kept: $W"; else rm -rf "$W"; fi
}
trap cleanup EXIT
case "${1:-}" in
  "") ;;
  --keep) KEEP=1 ;;
  -h|--help) printf '%s\n' "$USAGE"; exit 0 ;;
  *) printf '%s\n' "$USAGE" >&2; exit 2 ;;
esac
[ $# -le 1 ] || { printf '%s\n' "$USAGE" >&2; exit 2; }
python3 -c pass >/dev/null 2>&1 || die "python3 is not usable"
git --version >/dev/null 2>&1 || die "git is not usable"
SRC=$(cd "$(dirname "$0")/.." && pwd -P) || die "cannot locate the checkout from $0"
[ -f "$SRC/concord/concord.py" ] || die "concord/concord.py not found in $SRC"
[ -f "$SRC/examples/PLAN_example.md" ] || die "examples/PLAN_example.md not found in $SRC"
W=$(mktemp -d "${TMPDIR:-/tmp}/concord-demo.XXXXXX") || die "cannot create a temporary folder in ${TMPDIR:-/tmp}"
W=$(cd "$W" && pwd -P)

# 1. A scratch copy of Concord: the dispatcher, a scripted qwen on PATH, an empty fake HOME.
echo "1. Concord: copy the dispatcher, put a scripted executor on PATH and a throwaway HOME around it."
mkdir -p "$W/concord" "$W/bin" "$W/home/.claude" || die "cannot set up $W"
cp -p "$SRC/concord/concord.py" "$SRC/concord/wt.py" "$SRC"/concord/*.md "$SRC"/concord/*.conf "$W/concord/" ||
  die "cannot copy the dispatcher into $W"
cp -Rp "$SRC/concord/repo-notes" "$W/concord/" || die "cannot copy repo-notes into $W"
cat > "$W/bin/qwen" <<'Q'
#!/bin/sh
if [ -n "${FAKE_ACTIONS:-}" ]; then sh -c "$FAKE_ACTIONS"; exit 0; fi
printf 'REVIEW-JSON\n{"findings": [], "clauses": [], "tests": [], "verdict": "CLEAN"}\nEND-REVIEW-JSON\n'
Q
chmod +x "$W/bin/qwen" || die "cannot install the scripted executor"
export PATH="$W/bin:$PATH" HOME="$W/home"

# 2. The shop: a small repository with the bug and the failing test that grades the phase.
echo "2. Shop: create a git repository whose cart ignores qty; its test fails while the bug is there."
S="$W/shop"
mkdir -p "$S/tests" || die "cannot create $S"
cat > "$S/cart.py" <<'PY'
def total(items):
    return sum(item["price"] for item in items)
PY
cat > "$S/README.md" <<'MD'
# Shop

A tiny shop for the Concord demo.
MD
cat > "$S/tests/check_cart.py" <<'PY'
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import cart

items = [{"price": 3, "qty": 2}, {"price": 5, "qty": 1}]
got = cart.total(items)
if got != 11:
    print(f"cart total: {got}, expected 11")
    sys.exit(1)
print("cart total ok")
PY
cat > "$W/fixed_cart.py" <<'PY'
def total(items):
    return sum(item["price"] * item["qty"] for item in items)
PY
g() { git -C "$S" "$@"; }
g init -q -b main && g add -A &&
  g -c user.name=demo -c user.email=demo@example.invalid -c commit.gpgsign=false commit -qm init ||
  die "cannot create the demo repository in $S"
cp "$SRC/examples/PLAN_example.md" "$S/PLAN_demo.md" || die "cannot copy examples/PLAN_example.md"
printf '/PLAN_demo.md\n' >> "$S/.git/info/exclude" || die "cannot exclude $S/PLAN_demo.md"

D() { python3 "$W/concord/concord.py" "$@" --plan "$S/PLAN_demo.md" --repo "$S"; }
rid() { printf '%s\n' "$1" | sed -n 's/^DELEGATE RESULT \([^ ]*\).*/\1/p' | head -1; }
need() { local rc=$?; [ "$rc" = 0 ] || fail "$1 failed (exit $rc)" "$rc"; }

# 3. Lint: a zero-token dry run of what a cheap model would be asked before any code changes.
echo "3. Lint: dry-run the phase pre-flight so the questions are visible before spending a token."
out=$(D --lint 2 --dry-run --via qwen --model fake/m 2>&1); need "the lint"
printf '%s\n' "$out"

# 4. Attempt 1: the executor fixes cart.py but also edits README.md, which Files: does not allow.
echo "4. Attempt 1: the executor fixes cart.py and edits README.md, outside Files:."
export FIXED="$W/fixed_cart.py"
export FAKE_ACTIONS='cp "$FIXED" cart.py && echo '"'"'Edited by the executor.'"'"' >> README.md'
out=$(D 2 --via qwen --model fake/m 2>&1); rc=$?
printf '%s\n' "$out"
RUN1=$(rid "$out")
[ -n "$RUN1" ] || fail "attempt 1 printed no report (exit $rc)" "$rc"
printf '%s\n' "$out" | grep -q '^OUT OF SCOPE (source): README.md' ||
  fail "attempt 1 did not report README.md out of scope"

# 5. Verdict: scope is part of the contract, so out-of-scope work is an executor failure.
echo "5. Verdict: record FAIL with cause EXECUTOR, because the change left the declared scope."
out=$(D --verdict "$RUN1" FAIL --cause EXECUTOR --note "edited README.md outside Files" 2>&1); need "the FAIL verdict"
printf '%s\n' "$out"

# 6. Restore: the dispatcher backs up in-scope files only; the out-of-scope file goes back with git.
echo "6. Restore: revert cart.py from the run's backup and README.md with git."
out=$(D --restore "$RUN1" 2>&1); need "the restore"
printf '%s\n' "$out"
git -C "$W/shop" checkout -- README.md || fail "cannot revert README.md"

# 7. Attempt 2: the same executor edits only cart.py; the red run turns green.
echo "7. Attempt 2: the executor edits only cart.py, so the failing test should now pass."
export FAKE_ACTIONS='cp "$FIXED" cart.py'
out=$(D 2 --via qwen --model fake/m 2>&1); need "attempt 2"
printf '%s\n' "$out"
RUN2=$(rid "$out")
[ -n "$RUN2" ] || fail "attempt 2 printed no report"
printf '%s\n' "$out" | grep -q 'acceptance after run: 1/1 pass' || fail "attempt 2 did not make the test pass"

# 8. Review: a second, cheap model reads the diff; with no instructions it answers CLEAN.
echo "8. Review: a cheap model reads the diff and returns a CLEAN REVIEW-JSON answer."
unset FAKE_ACTIONS
out=$(D --review "$RUN2" --via qwen --model fake/m 2>&1); need "the review"
printf '%s\n' "$out"

# 9. Verdict: the acceptance passed and the review is on file, so the phase passes.
echo "9. Verdict: record PASS with the review on file."
out=$(D --verdict "$RUN2" PASS --note "demo" 2>&1); need "the PASS verdict"
printf '%s\n' "$out"

[ -n "$KEEP" ] && { echo "kept: $W"; KEPT=1; }
echo "Summary:"
echo "- Attempt 1 changed README.md outside Files: FAIL, cause EXECUTOR."
echo "- Restore reverted cart.py and README.md."
echo "- Attempt 2 changed cart.py only: the baseline failed and the acceptance after the run passed."
echo "- Review: CLEAN. Verdict: PASS."
exit 0
