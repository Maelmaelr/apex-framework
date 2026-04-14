#!/usr/bin/env bash
# update-hit.sh -- Bump [last-hit] dates to today for specified lines in a lessons.md file.
# Usage: bash update-hit.sh <lessons-file> <line1> [line2] ...
# Output: HIT UPDATE: {N} line(s) updated in {file}
# Exit: 0 = success (at least one line updated), 1 = no updates made
# Version: v1.0 -- 2026-03-28

set -euo pipefail

if [[ $# -eq 0 ]] || [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
update-hit.sh -- Bump [last-hit] dates to today for specified lines in a lessons.md file.

Usage:
  bash update-hit.sh <lessons-file> <line1> [line2] ...

Arguments:
  lessons-file   Path to the lessons.md file to update (modified in place)
  line1 ...      Line numbers to update

Transformations applied to each specified line:
  [last-hit: YYYY-MM-DD]                      -> [last-hit: {today}]
  []                                           -> [last-hit: {today}]
  [verified]                                   -> [verified, last-hit: {today}]
  [verified, last-hit: YYYY-MM-DD]             -> [verified, last-hit: {today}]
  [unverified, last-hit: YYYY-MM-DD]           -> [last-hit: {today}]  (promoted)
  [anti-pattern, unverified, last-hit: YYYY-MM-DD] -> [anti-pattern, last-hit: {today}]  (promoted)
  [anti-pattern, last-hit: YYYY-MM-DD]         -> [anti-pattern, last-hit: {today}]

Exit codes:
  0 = at least one line was updated
  1 = no updates made (no matching patterns found at specified lines)

Example:
  bash update-hit.sh .claude/lessons.md 42 57 103
EOF
  exit 0
fi

LESSONS_FILE="${1:-}"
shift

if [[ -z "$LESSONS_FILE" ]]; then
  echo "ERROR: lessons file path required" >&2
  exit 1
fi

if [[ ! -f "$LESSONS_FILE" ]]; then
  echo "ERROR: file not found: $LESSONS_FILE" >&2
  exit 1
fi

if [[ $# -eq 0 ]]; then
  echo "ERROR: at least one line number required" >&2
  exit 1
fi

TODAY=$(date +%Y-%m-%d)
UPDATED=0

# Detect sed flavor: BSD (macOS) requires -i '' ; GNU requires -i ''  or -i ''
# Both accept -i '' so use that form; pass empty string as separate arg.
SED_INPLACE=(-i "")

for LINE_NUM in "$@"; do
  # Validate line number is a positive integer
  if ! [[ "$LINE_NUM" =~ ^[0-9]+$ ]] || [[ "$LINE_NUM" -eq 0 ]]; then
    echo "WARNING: skipping invalid line number: $LINE_NUM" >&2
    continue
  fi

  # Read the current content of the target line
  CURRENT_LINE=$(sed -n "${LINE_NUM}p" "$LESSONS_FILE")

  # Determine which transformation applies
  # Order matters: check most-specific patterns first

  if echo "$CURRENT_LINE" | grep -qF "last-hit: ${TODAY}"; then
    # Already has today's date (any bracket form) -- idempotent no-op
    continue

  elif echo "$CURRENT_LINE" | grep -qE '\[anti-pattern, unverified, last-hit: [0-9]{4}-[0-9]{2}-[0-9]{2}\]'; then
    # [anti-pattern, unverified, last-hit: YYYY-MM-DD] -> [anti-pattern, last-hit: {today}]  (promoted)
    sed "${SED_INPLACE[@]}" \
      "${LINE_NUM}s/\[anti-pattern, unverified, last-hit: [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\]/[anti-pattern, last-hit: ${TODAY}]/g" \
      "$LESSONS_FILE"
    UPDATED=$((UPDATED + 1))

  elif echo "$CURRENT_LINE" | grep -qE '\[anti-pattern, last-hit: [0-9]{4}-[0-9]{2}-[0-9]{2}\]'; then
    # [anti-pattern, last-hit: YYYY-MM-DD] -> [anti-pattern, last-hit: {today}]
    sed "${SED_INPLACE[@]}" \
      "${LINE_NUM}s/\[anti-pattern, last-hit: [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\]/[anti-pattern, last-hit: ${TODAY}]/g" \
      "$LESSONS_FILE"
    UPDATED=$((UPDATED + 1))

  elif echo "$CURRENT_LINE" | grep -qE '\[unverified, last-hit: [0-9]{4}-[0-9]{2}-[0-9]{2}\]'; then
    # [unverified, last-hit: YYYY-MM-DD] -> [last-hit: {today}]  (promoted -- second session confirmed)
    sed "${SED_INPLACE[@]}" \
      "${LINE_NUM}s/\[unverified, last-hit: [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\]/[last-hit: ${TODAY}]/g" \
      "$LESSONS_FILE"
    UPDATED=$((UPDATED + 1))

  elif echo "$CURRENT_LINE" | grep -qE '\[verified, last-hit: [0-9]{4}-[0-9]{2}-[0-9]{2}\]'; then
    # [verified, last-hit: YYYY-MM-DD] -> [verified, last-hit: {today}]
    sed "${SED_INPLACE[@]}" \
      "${LINE_NUM}s/\[verified, last-hit: [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\]/[verified, last-hit: ${TODAY}]/g" \
      "$LESSONS_FILE"
    UPDATED=$((UPDATED + 1))

  elif echo "$CURRENT_LINE" | grep -qF "[verified]"; then
    # [verified] -> [verified, last-hit: {today}]
    sed "${SED_INPLACE[@]}" \
      "${LINE_NUM}s/\[verified\]/[verified, last-hit: ${TODAY}]/g" \
      "$LESSONS_FILE"
    UPDATED=$((UPDATED + 1))

  elif echo "$CURRENT_LINE" | grep -qE '\[last-hit: [0-9]{4}-[0-9]{2}-[0-9]{2}\]'; then
    # [last-hit: YYYY-MM-DD] -> [last-hit: {today}]
    sed "${SED_INPLACE[@]}" \
      "${LINE_NUM}s/\[last-hit: [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\]/[last-hit: ${TODAY}]/g" \
      "$LESSONS_FILE"
    UPDATED=$((UPDATED + 1))

  elif echo "$CURRENT_LINE" | grep -qF "[]"; then
    # [] -> [last-hit: {today}]
    sed "${SED_INPLACE[@]}" \
      "${LINE_NUM}s/\[\]/[last-hit: ${TODAY}]/g" \
      "$LESSONS_FILE"
    UPDATED=$((UPDATED + 1))

  fi
  # No matching pattern on this line -- skip silently
done

echo "HIT UPDATE: ${UPDATED} line(s) updated in ${LESSONS_FILE}"

if [[ $UPDATED -eq 0 ]]; then
  exit 1
fi

exit 0
