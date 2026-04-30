#!/usr/bin/env bash
# zero-layer-extract.sh -- step 6.a zero-layer "proceed-with-prompt-paths" branch.
# Spec: apex-core.md step 6.a + scout1.md "Zero-layer proceed (6.a exit code 10)".
#
# Reads original_prompt from {session}-hypothesis.json, regex-extracts paths
# (project-tree-shaped tokens + quoted/backticked relative paths), validates
# each on disk, writes {session}-main-scope.json + the post-extract scope
# pointer at {session}-scopes/$CC_SESSION_ID.txt.
#
# Caller (orchestrator) invokes this only AFTER the AskUserQuestion at 6.a
# resolves to "proceed-with-prompt-paths". On exit 10 (zero validated paths),
# the orchestrator runs the verify-exit-1 abort surface.
#
# Args (positional):
#   $1  -- {session} 8-hex token (required)
#
# Env (required):
#   CC_SESSION_ID -- current Claude Code session id (used for scope pointer name).
#
# Exit codes:
#   0   -- scope written + pointer written
#   1   -- bad args, missing env, missing hypothesis, jq missing
#   10  -- zero validated paths (orchestrator runs verify-exit-1 abort)

set -euo pipefail

SESSION="${1:-}"

if [[ -z "$SESSION" ]]; then
  echo "zero-layer-extract.sh: {session} positional arg is required" >&2
  exit 1
fi

if ! [[ "$SESSION" =~ ^[0-9a-f]{8}$ ]]; then
  echo "zero-layer-extract.sh: session token '$SESSION' is not 8-hex" >&2
  exit 1
fi

if [[ -z "${CC_SESSION_ID:-}" ]]; then
  echo "zero-layer-extract.sh: CC_SESSION_ID env var is required" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "zero-layer-extract.sh: jq not found" >&2
  exit 1
fi

APEX_ACTIVE=".claude-tmp/apex-active"
HYPOTHESIS="$APEX_ACTIVE/$SESSION-hypothesis.json"
MAIN_SCOPE="$APEX_ACTIVE/$SESSION-main-scope.json"

if [[ ! -f "$HYPOTHESIS" ]]; then
  echo "zero-layer-extract.sh: hypothesis missing at $HYPOTHESIS" >&2
  exit 1
fi

prompt=$(jq -r '.original_prompt' "$HYPOTHESIS")

# Two extraction patterns: (1) quoted/backticked tokens, (2) project-tree-shaped
# paths with extensions. Strip quote/backtick wrappers from results.
candidates=$(printf '%s' "$prompt" \
  | { grep -oE '(`[^`]+`|"[^"]+"|[a-zA-Z0-9_./-]+\.[a-zA-Z0-9]+)' || true; } \
  | tr -d '`"')

validated=()
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  [[ -f "$p" ]] && validated+=("$p")
done <<< "$candidates"

if [[ ${#validated[@]} -eq 0 ]]; then
  exit 10
fi

# Write {session}-main-scope.json (allowed_files = validated paths + safety paths).
jq -n --argjson files "$(printf '%s\n' "${validated[@]}" | jq -R . | jq -s .)" \
  --arg session "$SESSION" \
  '{session: $session, produced_by: "step6a_zero_layer", allowed_files: ($files + [".claude-tmp/", "~/.claude/tmp/", "docs/"])}' \
  > "$MAIN_SCOPE"

# Write the scope pointer for the calling Claude Code session.
mkdir -p "$APEX_ACTIVE/$SESSION-scopes"
printf '%s\n' "$(realpath "$MAIN_SCOPE")" \
  > "$APEX_ACTIVE/$SESSION-scopes/$CC_SESSION_ID.txt"

exit 0
