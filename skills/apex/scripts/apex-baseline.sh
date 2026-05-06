#!/usr/bin/env bash
# apex-baseline.sh -- capture working-tree baseline for an apex session.
# Spec: apex-core.md step 8.0 (init).
#
# Single producer per session at step 8.0. Writes head_sha + pre_dirty for use
# by step 9 (polish), step 11 (tail diff), step 12 (git stage filter), and
# step 13 (reflector diff context).
#
# Args (positional):
#   $1  -- {session} 8-hex token (required)
#
# Side effects:
#   - mkdir -p .claude-tmp/apex-active
#   - write .claude-tmp/apex-active/{session}-baseline.json containing head_sha + pre_dirty
#
# Exit codes:
#   0  -- baseline written
#   1  -- bad args, git missing, or producer-validate failure

set -euo pipefail

SESSION="${1:-}"

if [[ -z "$SESSION" ]]; then
  echo "apex-baseline.sh: {session} positional arg is required" >&2
  exit 1
fi

if ! [[ "$SESSION" =~ ^[0-9a-f]{8}$ ]]; then
  echo "apex-baseline.sh: session token '$SESSION' is not 8-hex" >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "apex-baseline.sh: git not found" >&2
  exit 1
fi

GIT_HEAD=$(git rev-parse HEAD)
PRE_DIRTY=$( (git diff --name-only HEAD; git ls-files --others --exclude-standard) | sort -u )

APEX_ACTIVE=".claude-tmp/apex-active"
mkdir -p "$APEX_ACTIVE"
BASELINE="$APEX_ACTIVE/$SESSION-baseline.json"

PRE_DIRTY="$PRE_DIRTY" PYTHONPATH="$HOME/.claude/skills/apex/scripts" python3 - "$BASELINE" "$GIT_HEAD" <<'PY'
import sys, os, json
from _validate import producer_validate, ValidationError

baseline_path, git_head = sys.argv[1:3]
pre_dirty = [p for p in os.environ.get("PRE_DIRTY", "").splitlines() if p]
data = {"head_sha": git_head, "pre_dirty": pre_dirty}
try:
    producer_validate(data, "baseline")
except ValidationError as e:
    print(f"baseline producer-validate failed: {e}", file=sys.stderr)
    sys.exit(1)
with open(baseline_path, "w", encoding="utf-8") as f:
    json.dump(data, f)
PY

exit 0
