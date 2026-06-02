#!/usr/bin/env bash
# Purpose: Workstream-B item-5 ACCEPTANCE regression - replay the read-before-work
#          canary (transcript-step-read-check.py via replay-canary.sh) over the
#          committed real-/apex fixture and assert no gate violation.
# Spec: apex-context-rot-optimization plan, Workstream B item 5 (step-6 acceptance).
#
# The fixture (skills/apex/scripts/fixtures/apex-step-read-fixture.jsonl) is a real
# captured standard-tier /apex run trimmed to orchestrator tool_use events with home
# paths normalized to /repo. It proves, on REAL data, that each step's
# steps/NN-*.md Read preceded that step's first work tool - the post-B invariant
# the live step-read gate enforces and this lint asserts after the fact.
#
# Kept separate from test-apex-scripts.sh (already at the 400-line file-health cap),
# matching the sibling test-*.sh idiom; that harness invokes this and folds the result.
# Gated on the fixture existing: a checkout without it SKIPs (exit 0) rather than fails.
#
# Exit: 0 fixture absent (skip) OR canary clean; 1 canary reported a violation.
set -uo pipefail
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$HOME/.claude}"
REPLAY="$REPO_ROOT/skills/apex/scripts/replay-canary.sh"
FIXTURE="$REPO_ROOT/skills/apex/scripts/fixtures/apex-step-read-fixture.jsonl"

if [[ ! -f "$FIXTURE" ]]; then
  echo "test-replay-acceptance.sh: SKIP (no acceptance fixture at $FIXTURE)"
  exit 0
fi

echo "test-replay-acceptance.sh: replaying read-before-work canary over real fixture"
if bash "$REPLAY"; then
  echo "test-replay-acceptance.sh: PASS (no read-before-work violation on real transcript)"
  exit 0
else
  echo "test-replay-acceptance.sh: FAIL (canary reported a violation)" >&2
  exit 1
fi
