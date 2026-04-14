#!/usr/bin/env bash
# Guardrail hook: blocks access to .env* and credential files.
# PreToolUse matcher: Read|Edit|Write
# Allows .env.example, .env.sample, .env.template (safe reference files).
# Exit 0 always -- blocks via JSON output per hook protocol.
set -euo pipefail

ALLOW='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
deny() { echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"$1\"}}"; }

INPUT=$(cat)

FILE_PATH=$(echo "$INPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
ti = data.get('tool_input', {})
print(ti.get('file_path', ''))
" 2>/dev/null || echo "")

# No file_path means nothing to check
if [[ -z "$FILE_PATH" ]]; then
  echo "$ALLOW"
  exit 0
fi

BASENAME=$(basename "$FILE_PATH")

# Block .env* files (allow .env.example, .env.sample, .env.template)
if [[ "$BASENAME" == .env* ]]; then
  for safe in ".example" ".sample" ".template"; do
    if [[ "$BASENAME" == *"$safe" ]]; then
      echo "$ALLOW"
      exit 0
    fi
  done
  deny "GUARDRAIL: Cannot access '$BASENAME' -- .env files contain secrets. Use .env.example instead."
  exit 0
fi

# Block known credential file patterns
BLOCKED_FILES=(
  "credentials.json" "credentials.yaml" "credentials.yml"
  "secrets.json" "secrets.yaml" "secrets.yml"
  "service-account.json" "service-account-key.json"
  "gcloud-key.json" "keyfile.json"
  ".npmrc" ".pypirc"
)
for blocked in "${BLOCKED_FILES[@]}"; do
  if [[ "$BASENAME" == "$blocked" ]]; then
    deny "GUARDRAIL: Cannot access '$BASENAME' -- potential credential file."
    exit 0
  fi
done

echo "$ALLOW"
exit 0
