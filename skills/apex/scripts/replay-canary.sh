#!/usr/bin/env bash
# Replay the read-before-work canary (transcript-step-read-check.py) against a
# captured /apex session transcript using the canonical step-gates.json spec.
# Spec: apex-context-rot-optimization plan, Workstream B item-5 (acceptance harness).
#
# Usage:
#   replay-canary.sh [--transcript <jsonl>] [--json]
#
# With no --transcript it replays the committed acceptance fixture
# (fixtures/apex-step-read-fixture.jsonl) when present - the durable post-B
# read-before-work regression that test-apex-scripts.sh asserts. Pass
# --transcript to lint a fresh live run (e.g. the newest session JSONL under
# ~/.claude/projects/<cwd>/). The fixture is a real captured /apex run trimmed to
# orchestrator tool_use events with home paths normalized to /repo (the canary
# matches steps/NN-*.md by regex, so the prefix is immaterial).
#
# Exit: 0 no violation / 1 >=1 gate FAIL / 2 usage or missing inputs.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHK="$SCRIPT_DIR/transcript-step-read-check.py"
GATES="$SCRIPT_DIR/step-gates.json"
FIXTURE="$SCRIPT_DIR/fixtures/apex-step-read-fixture.jsonl"
TRANSCRIPT=""
JSON=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --transcript) TRANSCRIPT="${2:-}"; shift 2 ;;
    --json) JSON="--json"; shift ;;
    *) echo "replay-canary.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -z "$TRANSCRIPT" ]] && TRANSCRIPT="$FIXTURE"
if [[ ! -f "$TRANSCRIPT" ]]; then
  echo "replay-canary.sh: no transcript ($TRANSCRIPT); pass --transcript <jsonl>" >&2
  exit 2
fi
[[ -f "$CHK" ]] || { echo "replay-canary.sh: checker missing: $CHK" >&2; exit 2; }
[[ -f "$GATES" ]] || { echo "replay-canary.sh: gates spec missing: $GATES" >&2; exit 2; }
exec python3 "$CHK" --transcript "$TRANSCRIPT" --gates "$GATES" $JSON
