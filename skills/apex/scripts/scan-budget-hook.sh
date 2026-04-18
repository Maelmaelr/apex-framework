#!/usr/bin/env bash
# scan-budget-hook.sh -- APEX scan budget hook (PostToolUse, matcher: Grep|Glob|Read)
# Usage: Invoked as PostToolUse hook (reads JSON from stdin). Not called directly.
# Tracks three counters in .claude-tmp/apex-active/{session}-budget.json:
#   grep_glob_count   (default warn 5, block 8)   -- Grep|Glob calls
#   doc_read_count    (default warn 3, block 5)   -- .md or /docs/ Read calls
#   source_read_count (default warn 3, block 3)   -- non-md/docs Read calls
# Two-tier: past warn emits additionalContext advisory; past max emits decision=block.
# Set {counter}_max to -1 in the budget JSON to disable enforcement for that counter
# (Exception b bug investigation typically sets source_read_max=-1).
# If no active session or budget file, exits 0 (allow).
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

# Exempt doc-reads when an improve session is active (improve Phase 2 reads skill .md files for editing,
# not for scanning -- counters must not block mid-implementation reads)
if [[ "$TOOL_NAME" == "Read" ]]; then
  IMPROVE_ACTIVE=""
  for m in "$BUDGET_DIR"/improve-*.json; do
    [[ -f "$m" ]] && IMPROVE_ACTIVE=1 && break
  done
  [[ -n "$IMPROVE_ACTIVE" ]] && exit 0
fi

# Determine which counter + thresholds to use based on tool_name (and file path for Read)
if [[ "$TOOL_NAME" == "Read" ]]; then
  FILE_PATH=$(echo "$INPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('tool_input', {}).get('file_path', ''))
" 2>/dev/null || echo "")
  if [[ -n "$FILE_PATH" && ! "$FILE_PATH" =~ \.md$ && ! "$FILE_PATH" =~ /docs/ ]]; then
    COUNT_KEY="source_read_count"
    WARN_KEY="source_read_warn"
    MAX_KEY="source_read_max"
    DEFAULT_WARN=3
    DEFAULT_MAX=3
    LABEL="source-read"
  else
    COUNT_KEY="doc_read_count"
    WARN_KEY="doc_read_warn"
    MAX_KEY="doc_read_max"
    DEFAULT_WARN=3
    DEFAULT_MAX=5
    LABEL="doc-read"
  fi
else
  COUNT_KEY="grep_glob_count"
  WARN_KEY="warn_threshold"
  MAX_KEY="max"
  DEFAULT_WARN=5
  DEFAULT_MAX=8
  LABEL="search"
fi

# Read current count + thresholds, increment, write back, classify
RESULT=$(python3 -c "
import json, sys
path = sys.argv[1]
count_key = sys.argv[2]
warn_key = sys.argv[3]
max_key = sys.argv[4]
default_warn = int(sys.argv[5])
default_max = int(sys.argv[6])
with open(path) as f:
    data = json.load(f)
max_budget = data.get(max_key, default_max)
# Opt-out: max == -1 disables enforcement AND counting for this counter
if max_budget == -1:
    print('OK')
    sys.exit(0)
warn_threshold = data.get(warn_key, default_warn)
count = data.get(count_key, 0) + 1
data[count_key] = count
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
if count > max_budget:
    print(f'BLOCK:{count}/{max_budget}')
elif count > warn_threshold:
    print(f'WARN:{count}/{max_budget}')
else:
    print('OK')
" "$BUDGET_FILE" "$COUNT_KEY" "$WARN_KEY" "$MAX_KEY" "$DEFAULT_WARN" "$DEFAULT_MAX" 2>/dev/null || echo "OK")

case "$RESULT" in
  OK)
    exit 0
    ;;
  WARN:*)
    COUNT_MAX="${RESULT#WARN:}"
    echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"APEX scan budget warning: $COUNT_MAX $LABEL calls. You are past the routing threshold -- if still scanning, proceed to Path 2 (scouts).\"}}"
    exit 0
    ;;
  BLOCK:*)
    COUNT_MAX="${RESULT#BLOCK:}"
    echo "{\"decision\":\"block\",\"reason\":\"APEX scan budget exceeded: $COUNT_MAX $LABEL calls\"}"
    exit 0
    ;;
esac
