#!/usr/bin/env bash
# Purpose: fixtures for scripts/transcript-step-read-check.py (the Workstream B
#          item-5 read-before-work transcript canary).
# Spec: apex-context-rot-optimization plan, Workstream B item 5.
#
# Kept separate from test-apex-scripts.sh (which is already near the 400-line
# file-health cap) - that harness invokes this one and folds the result.
# Also runnable standalone.
#
# Each case emits a synthetic session JSONL (orchestrator tool_use events) plus a
# gates spec, runs the checker, and asserts the exit code (0 clean / 1 violation /
# 2 usage). Synthetic fixtures keep this deterministic and CI-able, matching the
# sibling test-audit-detectors.sh / test-sweep.sh idiom. JSON event args are
# wrapped across physical lines (json.loads accepts newlines) to stay <= 120 cols.
#
# Exit codes: 0 all fixtures pass; 1 one or more failed.

set -uo pipefail
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$HOME/.claude}"
CHK="$REPO_ROOT/skills/apex/scripts/transcript-step-read-check.py"
pass=0
failed=0

check() {  # label expected-exit got-exit
  if [[ "$3" == "$2" ]]; then
    echo "PASS $1 (exit=$3)"; pass=$((pass + 1))
  else
    echo "FAIL $1 (expected $2, got $3)" >&2; failed=$((failed + 1))
  fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Emitter: argv[1]=out JSONL path, argv[2]=JSON list of [name, input, sidechain?].
# Writes one assistant line per event with a direct caller (orchestrator).
EMIT="$tmp/emit.py"
cat > "$EMIT" <<'PY'
import json, sys
out, spec = sys.argv[1], json.loads(sys.argv[2])
with open(out, "w") as f:
    for ev in spec:
        name, inp = ev[0], ev[1]
        side = ev[2] if len(ev) > 2 else False
        rec = {"type": "assistant", "isSidechain": side, "message": {"content": [
            {"type": "tool_use", "name": name, "input": inp, "caller": {"type": "direct"}}]}}
        f.write(json.dumps(rec) + "\n")
PY

run() {  # label expected events-json gates-json
  local label="$1" exp="$2" evs="$3" gates="$4"
  local t="$tmp/t.jsonl" g="$tmp/g.json"
  python3 "$EMIT" "$t" "$evs"
  printf '%s' "$gates" > "$g"
  python3 "$CHK" --transcript "$t" --gates "$g" >/dev/null 2>&1
  check "$label" "$exp" $?
}

G3='{"gates":[{"id":"3","contract":"steps/03-.*\\.md$"}]}'

# 0. Usage: missing --gates -> argparse error, exit 2.
python3 "$CHK" --transcript /dev/null >/dev/null 2>&1
check "usage missing-gates exit2" 2 $?

# 1. Read steps/03 after boundary, before Edit -> PASS (exit 0).
run "read-before-work pass" 0 \
  '[["TaskUpdate",{"taskId":"3","status":"in_progress"}],
    ["Read",{"file_path":"/r/skills/apex/steps/03-analyze.md"}],
    ["Edit",{"file_path":"/r/foo"}]]' \
  "$G3"

# 2. Work with no contract read in the window -> FAIL (exit 1).
run "no-read violation" 1 \
  '[["TaskUpdate",{"taskId":"3","status":"in_progress"}],
    ["Edit",{"file_path":"/r/foo"}]]' \
  "$G3"

# 3. Contract read happens BEFORE the boundary (stale) -> outside window -> FAIL.
run "stale-read violation" 1 \
  '[["Read",{"file_path":"/r/skills/apex/steps/03-analyze.md"}],
    ["TaskUpdate",{"taskId":"3","status":"in_progress"}],
    ["Edit",{"file_path":"/r/foo"}]]' \
  "$G3"

# 4. Gate for a step that never became active -> NOT-RUN -> no violation (exit 0).
run "not-run no-fail" 0 \
  '[["TaskUpdate",{"taskId":"3","status":"in_progress"}],
    ["Read",{"file_path":"/r/steps/03-x.md"}],["Edit",{}]]' \
  '{"gates":[{"id":"9","contract":"steps/09-.*\\.md$"}]}'

# 5. The only work tool is on a SIDECHAIN (subagent) line -> not gated -> exit 0.
run "subagent-work ignored" 0 \
  '[["TaskUpdate",{"taskId":"3","status":"in_progress"}],
    ["Edit",{"file_path":"/r/foo"},true]]' \
  "$G3"

# 6. metadata.step boundary (post-B item-3 shape) + Task work, read present -> PASS.
run "metadata.step boundary pass" 0 \
  '[["TaskUpdate",{"taskId":"x","status":"in_progress","metadata":{"step":"8"}}],
    ["Read",{"file_path":"/r/skills/apex/steps/08-execute.md"}],
    ["Task",{"description":"spawn"}]]' \
  '{"boundary_id_key":"metadata.step","gates":[{"id":"8","contract":"steps/08-.*\\.md$"}]}'

# 7. Two windows: step 3 reads+works (PASS), step 4 works unread (FAIL) -> exit 1.
#    Proves windowing attributes the violation to step 4, not step 3.
run "window isolation fail" 1 \
  '[["TaskUpdate",{"taskId":"3","status":"in_progress"}],
    ["Read",{"file_path":"/r/steps/03-a.md"}],["Edit",{}],
    ["TaskUpdate",{"taskId":"4","status":"in_progress"}],["Edit",{}]]' \
  '{"gates":[{"id":"3","contract":"steps/03-.*\\.md$"},
             {"id":"4","contract":"steps/04-.*\\.md$"}]}'

echo ""
echo "test-transcript-step-read.sh: pass=$pass fail=$failed"
[[ $failed -eq 0 ]] || exit 1
exit 0
