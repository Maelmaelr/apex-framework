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

# Pre-dirty contamination check: when a sibling /apex session committed recently
# (within 5 minutes) and its files appear in our pre_dirty, the orchestrator's
# downstream "git diff --stat" / "git diff --name-only" reads can over-report
# scope. Surface a one-line stderr warning so the orchestrator can flag it in
# step 15 (reflector cluster c62fe7ba / 94000169 / 16910ccc).
MAIN_SCOPE="$APEX_ACTIVE/$SESSION-main-scope.json"
if [[ -n "$PRE_DIRTY" && -f "$MAIN_SCOPE" ]]; then
  OUTSIDE_SCOPE=$(PRE_DIRTY="$PRE_DIRTY" MAIN_SCOPE="$MAIN_SCOPE" python3 - <<'PY'
import json, os
pre = [p for p in os.environ.get("PRE_DIRTY", "").splitlines() if p]
try:
    with open(os.environ["MAIN_SCOPE"], encoding="utf-8") as f:
        allowed = set(json.load(f).get("allowed_files", []))
except (OSError, json.JSONDecodeError):
    allowed = set()
print("\n".join(p for p in pre if p not in allowed))
PY
)
  if [[ -n "$OUTSIDE_SCOPE" ]]; then
    COUNT=$(printf '%s\n' "$OUTSIDE_SCOPE" | wc -l | tr -d ' ')
    echo "apex-baseline.sh: $COUNT pre_dirty file(s) outside session allowed_files (sibling-session contamination likely); orchestrator should surface as step-15 warning" >&2
  fi
fi

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
