#!/usr/bin/env bash
# grep-lessons.sh - Extract matching lesson blocks from lessons-index.md + lessons.md
# Usage: grep-lessons.sh <project-root> <term1> [term2] ...
# Output: Matched lesson blocks from lessons.md, prefixed with line numbers for hit-tracking.
# Exits cleanly with no output if lessons-index.md does not exist or no terms match.
# Exit 0 = success or no matches (normal). Exit 1 = missing/invalid arguments.
# Missing files (lessons-index.md, lessons.md) exit 0 with no output (expected condition).

set -euo pipefail

PROJECT_ROOT="${1:-}"
shift || true

if [[ -z "$PROJECT_ROOT" ]] || [[ $# -eq 0 ]]; then
  echo "Usage: grep-lessons.sh <project-root> <term1> [term2] ..." >&2
  exit 1
fi

INDEX_FILE="$PROJECT_ROOT/.claude/lessons-index.md"
LESSONS_FILE="$PROJECT_ROOT/.claude/lessons.md"

if [[ ! -f "$INDEX_FILE" ]] || [[ ! -f "$LESSONS_FILE" ]]; then
  exit 0
fi

# Build grep args for fixed-string matching (case-insensitive OR)
GREP_ARGS=()
for term in "$@"; do
  GREP_ARGS+=(-e "$term")
done

# Grep index for matching lines, extract section headers (text after ->)
MATCHED_SECTIONS=()
while IFS= read -r line; do
  # Extract section name after " -> "
  section="${line##* -> }"
  section="$(echo "$section" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ -n "$section" ]]; then
    # Deduplicate
    already=false
    for existing in "${MATCHED_SECTIONS[@]+"${MATCHED_SECTIONS[@]}"}"; do
      if [[ "$existing" == "$section" ]]; then
        already=true
        break
      fi
    done
    if [[ "$already" == false ]]; then
      MATCHED_SECTIONS+=("$section")
    fi
  fi
done < <(grep -iF "${GREP_ARGS[@]}" "$INDEX_FILE" 2>/dev/null || true)

if [[ ${#MATCHED_SECTIONS[@]} -eq 0 ]]; then
  exit 0
fi

# Output size cap -- defense-in-depth against exceeding Read tool limits
MAX_OUTPUT_LINES=150
OUTPUT_LINES=0

# For each matched section, extract the block from lessons.md
# A block starts at "## Section Name" and ends before the next "## " line
TOTAL_LINES=$(wc -l < "$LESSONS_FILE")

for section in "${MATCHED_SECTIONS[@]}"; do
  # Find the line number of the section header (fixed-string match to avoid regex chars in section names)
  HEADER_LINE=$(grep -nF "## ${section}" "$LESSONS_FILE" 2>/dev/null | while IFS=: read -r num line; do
    # Verify exact match: line must be exactly "## ${section}" (no prefix/suffix)
    if [[ "$line" == "## ${section}" ]]; then
      echo "$num"
      break
    fi
  done)
  HEADER_LINE="${HEADER_LINE:-}"
  if [[ -z "$HEADER_LINE" ]]; then
    continue
  fi

  # Find the next same-level header after this one
  END_LINE=""
  END_LINE=$(tail -n +"$((HEADER_LINE + 1))" "$LESSONS_FILE" | grep -n "^## " | head -1 | cut -d: -f1 || true)

  if [[ -n "$END_LINE" ]]; then
    # END_LINE is relative to HEADER_LINE+1, convert to absolute
    ABS_END=$((HEADER_LINE + END_LINE))
    BLOCK_LENGTH=$((ABS_END - HEADER_LINE))
  else
    # No next header -- read to end of file
    BLOCK_LENGTH=$((TOTAL_LINES - HEADER_LINE + 1))
    ABS_END=$((TOTAL_LINES + 1))
  fi

  # Pre-emit cap check (marker + block + blank = BLOCK_LENGTH + 2 lines)
  NEW_TOTAL=$((OUTPUT_LINES + BLOCK_LENGTH + 2))
  if [[ $NEW_TOTAL -gt $MAX_OUTPUT_LINES ]]; then
    BUDGET=$((MAX_OUTPUT_LINES - OUTPUT_LINES - 2))
    if [[ $BUDGET -le 0 ]]; then
      echo "--- TRUNCATED at ${OUTPUT_LINES} lines. Re-run with fewer/more specific terms. ---"
      exit 0
    fi
    echo "--- LINES ${HEADER_LINE}-$((HEADER_LINE + BUDGET - 1)) ---"
    sed -n "${HEADER_LINE},$((HEADER_LINE + BUDGET - 1))p" "$LESSONS_FILE"
    echo ""
    echo "--- TRUNCATED at ${MAX_OUTPUT_LINES} lines. Re-run with fewer/more specific terms. ---"
    exit 0
  fi

  echo "--- LINES ${HEADER_LINE}-$((ABS_END - 1)) ---"
  sed -n "${HEADER_LINE},$((ABS_END - 1))p" "$LESSONS_FILE"
  echo ""
  OUTPUT_LINES=$NEW_TOTAL
done
