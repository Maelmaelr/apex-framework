#!/usr/bin/env bash
# Step 7 finalize: compute effective_blast, compose preflight-{session}.json, validate.
# Spec: apex-core.md step 7 | scout2.md.
#
# Caller (orchestrator following scout2.md) generates --missed (JSON-string of the
# missed_regions array via LLM judgment); this script does the deterministic rest:
# reads screened + screen-plan, computes effective_blast, composes preflight,
# producer-validates. Single tool-call surface for the LLM-driven step.
#
# Args:
#   --session <token>      (required, 8-char lowercase hex)
#   --missed <json-string> (required, JSON array; pass '[]' for no missed regions)
#
# Output: preflight-{session}.json written; selected `mode` echoed to stdout.
#
# Exit codes:
#   0  preflight written + validated
#   1  bad args, missing inputs, or validation failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SESSION=""
MISSED=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session) SESSION="${2:-}"; shift 2 ;;
    --missed)  MISSED="${2:-}";  shift 2 ;;
    *) echo "scout2-finalize.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ "$SESSION" =~ ^[0-9a-f]{8}$ ]] || { echo "scout2-finalize.sh: --session must be 8-char lowercase hex" >&2; exit 1; }
[[ -n "$MISSED" ]] || { echo "scout2-finalize.sh: --missed required (pass '[]' if no missed regions)" >&2; exit 1; }

SCREENED=".claude-tmp/scout/screened-$SESSION.json"
SCREEN_PLAN=".claude-tmp/scout/screen-plan-$SESSION.json"
PREFLIGHT=".claude-tmp/scout/preflight-$SESSION.json"

[[ -f "$SCREENED"    ]] || { echo "scout2-finalize.sh: missing $SCREENED" >&2; exit 1; }
[[ -f "$SCREEN_PLAN" ]] || { echo "scout2-finalize.sh: missing $SCREEN_PLAN" >&2; exit 1; }

kept_count=$(jq '.kept | length' "$SCREENED")
findings_count=$(jq '._meta.findings_count // 0' "$SCREEN_PLAN")
missed_count=$(printf '%s' "$MISSED" | jq 'length')

# small = tight scope: <=15 files survived screening AND the underlying findings
# set fit comfortably below the ranker's top-K cap (default 30). Wider enumerations
# that screening culled to <=15 still route to large/Path 2 because the breadth
# of the original scout signal indicates non-trivial blast radius.
if [[ "$kept_count" -le 15 && "$findings_count" -le 30 ]]; then
  blast=small
else
  blast=large
fi

if [[ "$missed_count" -eq 0 && "$blast" == "small" ]]; then
  mode=medium
else
  mode=complex
fi

jq -n \
  --arg mode "$mode" \
  --arg blast "$blast" \
  --argjson missed "$MISSED" \
  '{missed_regions: $missed, effective_blast: $blast, mode: $mode}' \
  > "$PREFLIGHT"

bash "$SCRIPT_DIR/validate-json.sh" preflight.schema.json "$PREFLIGHT"

printf '%s\n' "$mode"
