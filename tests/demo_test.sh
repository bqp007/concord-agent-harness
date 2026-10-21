#!/bin/bash
# Checks scripts/demo.sh: one offline run of the governed loop with a scripted executor (no model, no account),
# the caller's HOME and the repository left untouched, clean exits on bad input. Run: bash tests/demo_test.sh
# Output: one "check demo/<name>: ok|FAIL <detail>" per check, then "passed N, failed M"; exit 0 iff M = 0.
set -u
cd "$(dirname "$0")/.." || exit 2
ROOT=$PWD; pass=0; fail=0
ok() { echo "check demo/$1: ok"; pass=$((pass+1)); }
no() { echo "check demo/$1: FAIL ${2:-}"; fail=$((fail+1)); }
T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/demotest.XXXXXX")" && pwd -P) || exit 2
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/stub" "$T/badpy"
for b in opencode claude codex; do   # a real model CLI must never start: these stubs record any call
  printf '#!/bin/sh\ntouch "%s/model-called"\nexit 97\n' "$T" > "$T/stub/$b"; chmod +x "$T/stub/$b"; done
printf '#!/bin/sh\nexit 1\n' > "$T/badpy/python3"; chmod +x "$T/badpy/python3"
before=$(git -C "$ROOT" status --porcelain)
P="$T/stub:$PATH"
demo() { local dir=$1 path=$2; shift 2; (cd "$dir" && env -i PATH="$path" HOME="$T/home" ${TMPDIR:+TMPDIR="$TMPDIR"} bash "$@"); }

# (a) from the repository root, keeping the work folder for inspection
start=$SECONDS; out=$(demo "$ROOT" "$P" scripts/demo.sh --keep 2>&1); rc=$?; secs=$((SECONDS - start))
[ "$rc" = 0 ] && ok a-exit || no a-exit "rc=$rc: $(echo "$out" | tail -1)"
[ "$secs" -le 60 ] && ok a-time || no a-time "${secs}s"
for pat in '^OUT OF SCOPE \(source\): README\.md' 'baseline: .*fail(ed)? before the change' 'verdict FAIL \[EXECUTOR\]' \
    'acceptance after run: 1/1 pass' 'verdict PASS' 'fake/m +2 +1 +1 '; do
  echo "$out" | grep -qE "$pat" && ok "a-output $pat" || no a-output "missing: $pat"; done
K=$(echo "$out" | sed -n 's/^kept: //p' | tail -1)
if [ -n "$K" ] && [ -d "$K" ]; then ok a-kept
  n=$(grep -cE '"verdict": "(PASS|FAIL)"' "$K/concord/runs.jsonl" 2>/dev/null)
  [ "${n:-0}" -ge 2 ] && ok a-ledger || no a-ledger "verdicts in the demo ledger: ${n:-0}"
  (cd "$K/shop" && python3 tests/check_cart.py >/dev/null 2>&1) && ok a-fixed || no a-fixed "the shop's test still fails"
  case "$K" in */concord-demo.*) rm -rf "$K";; esac
else no a-kept "no 'kept: <path>' line"; fi

# (b) a copy of the checkout whose path holds a space, called from another folder, TMPDIR unset
C="$T/copy with space"; mkdir -p "$C" && cp -R "$ROOT/scripts" "$ROOT/examples" "$ROOT/concord" "$C/" 2>/dev/null
out=$(cd "$T" && env -i PATH="$P" HOME="$T/home" bash "$C/scripts/demo.sh" 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q 'verdict PASS' && ok b-space-elsewhere || no b-space-elsewhere "rc=$rc: $(echo "$out" | tail -1)"

# (c) python3 present but unusable: exit 2, and stderr names python3
err=$(demo "$ROOT" "$T/badpy:$P" scripts/demo.sh 2>&1 >/dev/null); rc=$?
[ "$rc" = 2 ] && echo "$err" | grep -q python3 && ok c-no-python || no c-no-python "rc=$rc: $(echo "$err" | tail -1)"

# (d) an unknown argument: exit 2
demo "$ROOT" "$P" scripts/demo.sh --bogus >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok d-bad-arg || no d-bad-arg "rc=$rc"

[ -z "$(ls -A "$T/home")" ] && ok home-untouched || no home-untouched "$(ls -A "$T/home" | head -3 | tr '\n' ' ')"
[ ! -e "$T/model-called" ] && ok no-model-cli || no no-model-cli "a model CLI was started"
[ "$(git -C "$ROOT" status --porcelain)" = "$before" ] && ok repo-untouched || no repo-untouched "git status changed"
echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
