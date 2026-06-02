#!/usr/bin/env bash
# R3-a perf bench for step-read-gate-hook.sh (Workstream B item 3, residual R3-a).
# Spec: apex-context-rot-optimization plan, "Item 3 design ... R3-a (perf)".
#
# The gate hook runs on the hottest tools (Bash/Task/Edit...). This measures its
# per-call latency in the three regimes that matter:
#   A. non-apex fast-path - no .claude-tmp/apex-active -> exits at the first test,
#      no python (the cost every Bash in every NON-apex session pays).
#   B. armed + allow      - apex session, step active, contract already read
#      (the happy path during a real /apex run: python spawn + small JSON read).
#   C. armed + deny       - apex session, step active, contract unread (gate fires).
# B/C are the real-standard-run cost; A is the global tax on all other sessions.
#
# Usage: bench-step-gate.sh [iterations]   (default 100)
# Output: mean ms/call per regime. Re-run after any hook change to re-confirm R3-a.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/step-read-gate-hook.sh"
N="${1:-100}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/nonapex"
SESS="deadbeef"; CC="11111111-1111-1111-1111-111111111111"
AA="$TMP/apex/.claude-tmp/apex-active"
mkdir -p "$AA/${SESS}-scopes"
printf '%s\n' "$TMP/apex" > "$AA/${SESS}-scopes/${CC}.txt"
STATE="$AA/${SESS}-step-progress.json"
EVENT=$(printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"echo hi"}}' "$CC")

write_state() {  # active_since_offset read_offset|none
  python3 - "$STATE" "$1" "$2" <<'PY'
import json, sys, time
path, since_off, read_off = sys.argv[1], float(sys.argv[2]), sys.argv[3]
now = time.time()
st = {"active_step": "8", "active_since": now - since_off, "read_steps": {}}
if read_off != "none":
    st["read_steps"]["8"] = now - float(read_off)
json.dump(st, open(path, "w"))
PY
}

bench() {  # label dir
  python3 - "$HOOK" "$2" "$EVENT" "$N" "$1" <<'PY'
import subprocess, sys, time
hook, d, ev, N, label = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
t0 = time.time()
for _ in range(N):
    subprocess.run(["bash", hook], input=ev.encode(), cwd=d,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print("%-42s %6.2f ms/call (N=%d)" % (label, (time.time() - t0) / N * 1000, N))
PY
}

bench "A non-apex fast-path (no python)" "$TMP/nonapex"
write_state 5 2;     bench "B armed allow (read-before-work)" "$TMP/apex"
write_state 1 none;  bench "C armed deny (contract unread)" "$TMP/apex"
