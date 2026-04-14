#!/usr/bin/env bash
# scan-budget-hook.sh -- APEX scan budget hook (PostToolUse, matcher: Grep|Glob|Read)
# Usage: Invoked as PostToolUse hook (reads JSON from stdin). Not called directly.
# Tracks grep/glob count (max 5) and doc-read count (max 3) in
# .claude-tmp/apex-active/{session}-budget.json.
# If no active session, exits 0 (allow). If count exceeds max, blocks.
set -euo pipefail

# Read hook input from stdin
INPUT=$(cat)

# Extract tool_name from hook input
TOOL_NAME=$(echo "$INPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('tool_name', ''))
" 2>/dev/null || echo "")

# Find active budget file
BUDGET_DIR=".claude-tmp/apex-active"
if [[ ! -d "$BUDGET_DIR" ]]; then
  exit 0
fi

# Match *-budget.json with session ID validation
BUDGET_FILE=""
for f in "$BUDGET_DIR"/*-budget.json; do
  [[ -f "$f" ]] || continue
  BASENAME=$(basename "$f")
  # Validate session ID format: apex-[a-z0-9]{8}
  if [[ "$BASENAME" =~ ^apex-[a-z0-9]{8}-budget\.json$ ]]; then
    BUDGET_FILE="$f"
    break
  fi
done

# No valid budget file means no active APEX session
if [[ -z "$BUDGET_FILE" ]]; then
  exit 0
fi

# Determine which counter to increment based on tool_name
if [[ "$TOOL_NAME" == "Read" ]]; then
  # Extract file_path to classify: only count doc reads (.md, docs/)
  FILE_PATH=$(echo "$INPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('tool_input', {}).get('file_path', ''))
" 2>/dev/null || echo "")
  # Source files and session artifacts are exempt (Exception b: bug investigation)
  if [[ -n "$FILE_PATH" && ! "$FILE_PATH" =~ \.md$ && ! "$FILE_PATH" =~ /docs/ ]]; then
    exit 0
  fi
  COUNT_KEY="doc_read_count"
  MAX_KEY="doc_read_max"
  DEFAULT_MAX=3
  LABEL="doc-read"
else
  COUNT_KEY="grep_glob_count"
  MAX_KEY="max"
  DEFAULT_MAX=5
  LABEL="search"
fi

# Read current count and max, increment, write back, check limit
RESULT=$(python3 -c "
import json, sys
path = sys.argv[1]
count_key = sys.argv[2]
max_key = sys.argv[3]
default_max = int(sys.argv[4])
with open(path) as f:
    data = json.load(f)
count = data.get(count_key, 0) + 1
max_budget = data.get(max_key, default_max)
data[count_key] = count
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
if count > max_budget:
    print(f'EXCEEDED:{count}/{max_budget}')
else:
    print('OK')
" "$BUDGET_FILE" "$COUNT_KEY" "$MAX_KEY" "$DEFAULT_MAX" 2>/dev/null || echo "OK")

if [[ "$RESULT" == OK ]]; then
  exit 0
fi

# Extract count/max from EXCEEDED:count/max
COUNT_MAX="${RESULT#EXCEEDED:}"
echo "{\"decision\":\"block\",\"reason\":\"APEX scan budget exceeded: $COUNT_MAX $LABEL calls\"}"
exit 0
