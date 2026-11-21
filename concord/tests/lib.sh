#!/bin/bash
# Shared fixture helpers for the suites. Source it after DP (the dispatcher command in the temp copy) and T are set:
#   . "$(dirname "$0")/lib.sh"
# Every helper works on the dispatcher as shipped and on a dispatcher that needs a bound plan approval and signed
# review answers: nothing here depends on how the dispatcher stores either.

# vhash FILE: the plan-verifier hash of a plan file, computed by the dispatcher under test
vhash(){ python3 -I -B - "$T/concord/concord.py" "$1" <<'PY'
import importlib.util, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("d", sys.argv[1]); d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
print(d.verified_hash(open(sys.argv[2], errors="replace").read()))
PY
}

# approve PLAN [REPO] [PHASE]: record a plan-verifier APPROVE for the plan text as it stands now. Run it after the last
# edit of the plan: the approval binds to the text the verifier read. REPO defaults to $R, PHASE to 1.
approve(){ local plan=$1 repo=${2:-${R:-}} ph=${3:-1}
  $DP --lint "$ph" --plan "$plan" --repo "$repo" > "$T/approve.lint" 2>&1 \
    || { echo "setup failed: --lint $plan"; cat "$T/approve.lint"; return 1; }
  printf 'VERDICT: APPROVE\nPLAN-HASH: %s\n' "$(vhash "$repo/$plan")" > "$T/approve.txt"
  $DP --plan-verdict "$T/approve.txt" --plan "$plan" --repo "$repo" > "$T/approve.out" 2>&1 \
    || { echo "setup failed: --plan-verdict $plan"; cat "$T/approve.out"; return 1; }
}

# pksha PACKET: SHA-256 of the packet's bytes after its first line (of the whole file when the first line is not a
# PACKET-SHA line)
pksha(){ python3 -I -B -c '
import hashlib, sys
raw = open(sys.argv[1], "rb").read()
first, _, rest = raw.partition(b"\n")
print(hashlib.sha256(rest if first.startswith(b"PACKET-SHA:") else raw).hexdigest())' "$1"; }

# setsha ANSWER SHA: put "packet_sha": SHA into the REVIEW-JSON block of ANSWER. Free text and truncated JSON stay as
# they are.
setsha(){ python3 -I -B - "$1" "$2" <<'PY'
import json, re, sys
ans, sha = sys.argv[1:3]
txt = open(ans).read()
m = re.search(r"REVIEW-JSON\n(.*?)\nEND-REVIEW-JSON", txt, re.S)
if m:
    try:
        obj = json.loads(m.group(1))
    except ValueError:
        sys.exit(0)
    obj["packet_sha"] = sha
    open(ans, "w").write(txt[:m.start(1)] + json.dumps(obj) + txt[m.end(1):])
PY
}

# sign ANSWER PACKET: quote the packet's hash in ANSWER
sign(){ setsha "$1" "$(pksha "$2")"; }

# lastpacket RUN [REPO]: path of the newest review packet of a run ("" when it has none)
lastpacket(){ python3 -I -B -c '
import glob, re, sys
fs = sorted(glob.glob(sys.argv[1] + "/review-packet-*.md"), key=lambda p: int(re.search(r"-(\d+)\.md$", p).group(1)))
print(fs[-1] if fs else "")' "${2:-${R:-}}/.git/concord/$1"; }

# record RUN REVIEWER ANSWER [REPO] [ARGS...]: --review-record with the answer signed against the run's newest
# packet (one is written first when the run has none and is a phase run)
record(){ local run=$1 rev=$2 ans=$3 repo=${4:-${R:-}} pk; [ $# -ge 4 ] && shift 4 || shift 3
  pk=$(lastpacket "$run" "$repo")
  [ -n "$pk" ] || { $DP --review "$run" --packet --repo "$repo" > "$T/record.pk" 2>&1
    pk=$(sed -n 's/^PACKET \(.*\)$/\1/p' "$T/record.pk" | head -1); }
  [ -z "$pk" ] || sign "$ans" "$pk"
  $DP --review-record "$run" --reviewer "$rev" --file "$ans" --repo "$repo" "$@"
}

# The suites' fake executors read FAKE_* variables and $T; an executor only inherits allow-listed names, so list them.
# Call it again after a suite copies a fresh executors.conf.
fake_env(){ local h; for h in opencode qwen pi dsh kimi; do printf '%s.env = FAKE_* T R REFUSAL\n' "$h" >> "$T/concord/executors.conf"; done; }
[ -f "$T/concord/executors.conf" ] && fake_env
