#!/usr/bin/env bash
# apex-p2-init.sh -- post-context-clear initialisation for Path 2.
# Spec: apex-core.md p2.0 (Steps 3 + 4) + p2.md.
#
# Two side effects, executed in order:
#   1. Append p2_cc_session_id to .claude-tmp/apex-active/{session}.json (manifest).
#      cc_session_id and pid are NEVER overwritten. Producer-validates the
#      appended manifest against schemas/manifest.schema.json.
#   2. Write the post-context-clear scope-check pointer at
#      .claude-tmp/apex-active/{session}-scopes/$CC_SESSION_ID.txt pointing at
#      .claude-tmp/apex-active/{session}-main-scope.json.
#
# Args (positional):
#   $1  -- {session} 8-hex token (required)
#
# Env (required):
#   CC_SESSION_ID -- post-context-clear Claude Code session id. Optional: if
#                    unset, falls back to get-cc-session-id.sh (canonical
#                    resolver per shared-guardrails.md "cc_session_id resolution").
#                    Claude Code does NOT export this var by default.
#
# Exit codes:
#   0  -- both side effects succeeded
#   1  -- bad args, missing env, missing manifest, jq missing, or producer-validate failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SESSION="${1:-}"

if [[ -z "$SESSION" ]]; then
  echo "apex-p2-init.sh: {session} positional arg is required" >&2
  exit 1
fi

if ! [[ "$SESSION" =~ ^[0-9a-f]{8}$ ]]; then
  echo "apex-p2-init.sh: session token '$SESSION' is not 8-hex" >&2
  exit 1
fi

if [[ -z "${CC_SESSION_ID:-}" ]]; then
  CC_SESSION_ID="$(bash "$SCRIPT_DIR/get-cc-session-id.sh" 2>/dev/null || true)"
fi

if [[ -z "$CC_SESSION_ID" ]]; then
  echo "apex-p2-init.sh: CC_SESSION_ID unresolvable (env unset and get-cc-session-id.sh failed)" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "apex-p2-init.sh: jq not found" >&2
  exit 1
fi

APEX_ACTIVE=".claude-tmp/apex-active"
MANIFEST="$APEX_ACTIVE/$SESSION.json"
MAIN_SCOPE="$APEX_ACTIVE/$SESSION-main-scope.json"

if [[ ! -f "$MANIFEST" ]]; then
  echo "apex-p2-init.sh: manifest missing at $MANIFEST" >&2
  exit 1
fi

# Step 1: append p2_cc_session_id (preserves cc_session_id + pid).
TMP=$(mktemp)
jq --arg id "$CC_SESSION_ID" '. + {p2_cc_session_id: $id}' "$MANIFEST" > "$TMP"
mv "$TMP" "$MANIFEST"

PYTHONPATH="$HOME/.claude/skills/apex/scripts" python3 - "$MANIFEST" <<'PY'
import sys, json
from _validate import producer_validate, ValidationError

manifest_path = sys.argv[1]
with open(manifest_path, encoding="utf-8") as f:
    data = json.load(f)
try:
    producer_validate(data, "manifest")
except ValidationError as e:
    print(f"manifest producer-validate failed after p2 append: {e}", file=sys.stderr)
    sys.exit(1)
PY

# Step 2: write scope-check pointer for the post-context-clear session.
mkdir -p "$APEX_ACTIVE/$SESSION-scopes"
printf '%s\n' "$(realpath "$MAIN_SCOPE")" \
  > "$APEX_ACTIVE/$SESSION-scopes/$CC_SESSION_ID.txt"

exit 0
