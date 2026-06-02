#!/usr/bin/env bash
# Purpose: fixtures for skills/apex/scripts/step-read-gate-hook.sh (Workstream B
#          item 3 / B/R3 - the stateful step-read gate). Covers plan validation
#          (a)-(d) plus branch-1/branch-2 state mutation and stale-read correlation.
# Spec: apex-context-rot-optimization plan, "Item 3 design - B/R3 stateful step-read gate".
#
# Kept separate from test-apex-scripts.sh (near the 400-line file-health cap),
# which invokes this one and folds the result. Also runnable standalone.
#
# Each case builds a synthetic apex-active dir (scope pointer + step-progress
# state) under a temp CWD, pipes one hook event JSON to the hook, and asserts the
# decision (deny on stdout / allow == empty) or the resulting on-disk state.
# Synthetic + deterministic, matching the test-transcript-step-read.sh idiom.
#
# Exit codes: 0 all fixtures pass; 1 one or more failed.

set -uo pipefail
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$HOME/.claude}"
HOOK="$REPO_ROOT/skills/apex/scripts/step-read-gate-hook.sh"
pass=0
failed=0

ok() {  # label rc(0=pass)
  if [[ "$2" == 0 ]]; then echo "PASS $1"; pass=$((pass + 1));
  else echo "FAIL $1" >&2; failed=$((failed + 1)); fi
}

SID="cc-sid-1"
SESS="s0001"

# Build a synthetic apex-active under $1 (temp dir). $2 = step-progress JSON body
# (empty -> omit the sentinel file entirely, exercising the dormant fast-path).
setup() {
  local root="$1" body="$2"
  mkdir -p "$root/.claude-tmp/apex-active/$SESS-scopes"
  printf '%s\n' "$root/.claude-tmp/apex-active/$SESS-main-scope.json" \
    > "$root/.claude-tmp/apex-active/$SESS-scopes/$SID.txt"
  [[ -n "$body" ]] && printf '%s' "$body" > "$root/.claude-tmp/apex-active/$SESS-step-progress.json"
  return 0
}

# Pipe an event to the hook from inside $1 (cwd), echo the hook's stdout.
fire() {  # cwd event-json
  ( cd "$1" && printf '%s' "$2" | bash "$HOOK" 2>/dev/null )
}

state_get() {  # cwd python-expr-over-d
  python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print($2)" \
    "$1/.claude-tmp/apex-active/$SESS-step-progress.json"
}

WORK_EV='{"session_id":"'"$SID"'","tool_name":"Bash","tool_input":{"command":"echo hi"}}'

# (a) active_step set + contract unread -> DENY.
t=$(mktemp -d); setup "$t" '{"active_step":"8","active_since":1000.0,"read_steps":{}}'
out=$(fire "$t" "$WORK_EV"); [[ "$out" == *'"deny"'* ]]; ok "a unread-work denies" $?
rm -rf "$t"

# (b) active_step set + contract read after active_since -> ALLOW.
t=$(mktemp -d); setup "$t" '{"active_step":"8","active_since":1000.0,"read_steps":{"8":2000.0}}'
out=$(fire "$t" "$WORK_EV"); [[ -z "$out" ]]; ok "b read-before-work allows" $?
rm -rf "$t"

# (c) active_step unset -> fail-open ALLOW.
t=$(mktemp -d); setup "$t" '{"active_step":null,"active_since":null,"read_steps":{}}'
out=$(fire "$t" "$WORK_EV"); [[ -z "$out" ]]; ok "c no-active-step allows (fail-open)" $?
rm -rf "$t"

# (d) subagent path: session_id with no scope pointer -> ALLOW (never gate subagents).
t=$(mktemp -d); setup "$t" '{"active_step":"8","active_since":1000.0,"read_steps":{}}'
ev='{"session_id":"OTHER-SID","tool_name":"Bash","tool_input":{"command":"x"}}'
out=$(fire "$t" "$ev"); [[ -z "$out" ]]; ok "d subagent (pointer miss) allows" $?
rm -rf "$t"

# (e) stale read: read_steps[8] BEFORE active_since -> DENY.
t=$(mktemp -d); setup "$t" '{"active_step":"8","active_since":1000.0,"read_steps":{"8":500.0}}'
out=$(fire "$t" "$WORK_EV"); [[ "$out" == *'"deny"'* ]]; ok "e stale-read denies" $?
rm -rf "$t"

# (f) dormant: no step-progress sentinel -> fast-path ALLOW.
t=$(mktemp -d); setup "$t" ''
out=$(fire "$t" "$WORK_EV"); [[ -z "$out" ]]; ok "f no-sentinel dormant allows" $?
rm -rf "$t"

# (g) branch 1: TaskUpdate(in_progress, metadata.step=8) stamps active_step; a
#     subsequent unread work tool then DENIES (proves the step-start wiring).
t=$(mktemp -d); setup "$t" '{"active_step":null,"active_since":null,"read_steps":{}}'
tu='{"session_id":"'"$SID"'","tool_name":"TaskUpdate","tool_input":{"status":"in_progress","metadata":{"step":8}}}'
fire "$t" "$tu" >/dev/null
[[ "$(state_get "$t" "d['active_step']")" == "8" ]]; ok "g TaskUpdate stamps active_step" $?
out=$(fire "$t" "$WORK_EV"); [[ "$out" == *'"deny"'* ]]; ok "g post-TaskUpdate unread denies" $?
rm -rf "$t"

# (h) branch 2: Read of steps/08-*.md stamps read_steps[8], then work ALLOWS.
t=$(mktemp -d); setup "$t" '{"active_step":"8","active_since":1000.0,"read_steps":{}}'
rd='{"session_id":"'"$SID"'","tool_name":"Read","tool_input":{"file_path":"'"$t"'/skills/apex/steps/08-execute.md"}}'
fire "$t" "$rd" >/dev/null
[[ "$(state_get "$t" "'8' in d.get('read_steps',{})")" == "True" ]]; ok "h Read stamps read_steps[8]" $?
out=$(fire "$t" "$WORK_EV"); [[ -z "$out" ]]; ok "h post-Read work allows" $?
rm -rf "$t"

# (i) no apex-active dir at all -> fast-path ALLOW (non-/apex session).
t=$(mktemp -d)
out=$(fire "$t" "$WORK_EV"); [[ -z "$out" ]]; ok "i no-apex-active allows" $?
rm -rf "$t"

echo ""
echo "test-step-gate.sh: pass=$pass fail=$failed"
[[ $failed -eq 0 ]] || exit 1
exit 0
