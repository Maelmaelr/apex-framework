#!/usr/bin/env bash
# scout-context-truncate-hook.sh -- APEX scout context advisory hook (PostToolUse, matcher: Read)
# Usage: Invoked as PostToolUse hook (reads JSON from stdin). Not called directly.
# If a Read tool result exceeds 300 lines AND an active APEX session manifest exists,
# appends additionalContext suggesting offset/limit for targeted reads.
# Does NOT block -- advisory only (additionalContext field in hook response JSON).
set -euo pipefail

# Read hook input from stdin
INPUT=$(cat)

# Extract tool_name -- only act on Read calls
TOOL_NAME=$(echo "$INPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('tool_name', ''))
" 2>/dev/null || echo "")

if [[ "$TOOL_NAME" != "Read" ]]; then
  exit 0
fi

# Find active APEX session manifest (any *-manifest.json in apex-active dir)
MANIFEST_DIR=".claude-tmp/apex-active"
if [[ ! -d "$MANIFEST_DIR" ]]; then
  exit 0
fi

MANIFEST_FILE=""
for f in "$MANIFEST_DIR"/*-manifest.json; do
  [[ -f "$f" ]] || continue
  BASENAME=$(basename "$f")
  # Validate session ID format: apex-[a-z0-9]{8}
  if [[ "$BASENAME" =~ ^apex-[a-z0-9]{8}-manifest\.json$ ]]; then
    MANIFEST_FILE="$f"
    break
  fi
done

# No valid manifest means no active APEX session -- skip advisory
if [[ -z "$MANIFEST_FILE" ]]; then
  exit 0
fi

# Count lines in the tool result output
LINE_COUNT=$(echo "$INPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
output = data.get('tool_response', {})
# tool_response may be a string or dict with 'output' key
if isinstance(output, dict):
    text = output.get('output', '') or ''
elif isinstance(output, str):
    text = output
else:
    text = str(output)
print(len(text.splitlines()))
" 2>/dev/null || echo "0")

THRESHOLD=300

if [[ "$LINE_COUNT" -le "$THRESHOLD" ]]; then
  exit 0
fi

# Emit advisory context -- do not block
echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"Large file read ($LINE_COUNT lines). Consider using offset/limit for targeted reads to reduce context pressure.\"}}"
exit 0
