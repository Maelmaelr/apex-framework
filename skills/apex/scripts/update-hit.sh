#!/usr/bin/env bash
# Step 4: lesson hit-tracking. Bumps `[last-hit: YYYY-MM-DD]` to today on the
# specified lines of a curated lessons.md file (in-place).
# Spec: apex-core.md step 4.
#
# Args:
#   <lessons-file>           required (path to .claude/lessons.md)
#   <line1> [<line2> ...]    >=1 absolute line number returned by
#                            grep-lessons.sh inside `--- LINES s-e ---` markers
#
# Transformations (idempotent; today's date is a no-op):
#   [last-hit: YYYY-MM-DD]                              -> [last-hit: <today>]
#   []                                                  -> [last-hit: <today>]
#   [verified]                                          -> [verified, last-hit: <today>]
#   [verified, last-hit: YYYY-MM-DD]                    -> [verified, last-hit: <today>]
#   [unverified, last-hit: YYYY-MM-DD]                  -> [last-hit: <today>]                    (promoted)
#   [anti-pattern, unverified, last-hit: YYYY-MM-DD]    -> [anti-pattern, last-hit: <today>]      (promoted)
#   [anti-pattern, last-hit: YYYY-MM-DD]                -> [anti-pattern, last-hit: <today>]
#
# Output: HIT UPDATE: <N> line(s) updated in <file>
#
# Exit codes:
#   0 - at least one line was updated (or all targets already at today's date)
#   1 - bad args / file missing / no updates AND no idempotent matches

set -euo pipefail

if [[ $# -eq 0 ]] || [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: update-hit.sh <lessons-file> <line1> [<line2> ...]

Bumps `[last-hit: YYYY-MM-DD]` to today on the specified lines (in place).
Designed to consume the absolute line numbers emitted by grep-lessons.sh
inside `--- LINES start-end ---` markers.
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
IDEMPOTENT=0

# BSD sed (macOS) and GNU sed (Linux) both accept `-i ''` (empty backup
# extension passed as a separate arg). Single source for both.
SED_INPLACE=(-i "")

for LINE_NUM in "$@"; do
  if ! [[ "$LINE_NUM" =~ ^[0-9]+$ ]] || [[ "$LINE_NUM" -eq 0 ]]; then
    echo "WARNING: skipping invalid line number: $LINE_NUM" >&2
    continue
  fi

  CURRENT_LINE=$(sed -n "${LINE_NUM}p" "$LESSONS_FILE")

  # Order matters: check most-specific patterns first.

  if echo "$CURRENT_LINE" | grep -qF "last-hit: ${TODAY}"; then
    # Already at today's date in any bracket form -- idempotent no-op.
    IDEMPOTENT=$((IDEMPOTENT + 1))
    continue

  elif echo "$CURRENT_LINE" | grep -qE '\[anti-pattern, unverified, last-hit: [0-9]{4}-[0-9]{2}-[0-9]{2}\]'; then
    sed "${SED_INPLACE[@]}" \
      "${LINE_NUM}s/\[anti-pattern, unverified, last-hit: [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\]/[anti-pattern, last-hit: ${TODAY}]/g" \
      "$LESSONS_FILE"
    UPDATED=$((UPDATED + 1))

  elif echo "$CURRENT_LINE" | grep -qE '\[anti-pattern, last-hit: [0-9]{4}-[0-9]{2}-[0-9]{2}\]'; then
    sed "${SED_INPLACE[@]}" \
      "${LINE_NUM}s/\[anti-pattern, last-hit: [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\]/[anti-pattern, last-hit: ${TODAY}]/g" \
      "$LESSONS_FILE"
    UPDATED=$((UPDATED + 1))

  elif echo "$CURRENT_LINE" | grep -qE '\[unverified, last-hit: [0-9]{4}-[0-9]{2}-[0-9]{2}\]'; then
    # Second hit promotes unverified -> verified default.
    sed "${SED_INPLACE[@]}" \
      "${LINE_NUM}s/\[unverified, last-hit: [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\]/[last-hit: ${TODAY}]/g" \
      "$LESSONS_FILE"
    UPDATED=$((UPDATED + 1))

  elif echo "$CURRENT_LINE" | grep -qE '\[verified, last-hit: [0-9]{4}-[0-9]{2}-[0-9]{2}\]'; then
    sed "${SED_INPLACE[@]}" \
      "${LINE_NUM}s/\[verified, last-hit: [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\]/[verified, last-hit: ${TODAY}]/g" \
      "$LESSONS_FILE"
    UPDATED=$((UPDATED + 1))

  elif echo "$CURRENT_LINE" | grep -qF "[verified]"; then
    sed "${SED_INPLACE[@]}" \
      "${LINE_NUM}s/\[verified\]/[verified, last-hit: ${TODAY}]/g" \
      "$LESSONS_FILE"
    UPDATED=$((UPDATED + 1))

  elif echo "$CURRENT_LINE" | grep -qE '\[last-hit: [0-9]{4}-[0-9]{2}-[0-9]{2}\]'; then
    sed "${SED_INPLACE[@]}" \
      "${LINE_NUM}s/\[last-hit: [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\]/[last-hit: ${TODAY}]/g" \
      "$LESSONS_FILE"
    UPDATED=$((UPDATED + 1))

  elif echo "$CURRENT_LINE" | grep -qF "[]"; then
    sed "${SED_INPLACE[@]}" \
      "${LINE_NUM}s/\[\]/[last-hit: ${TODAY}]/g" \
      "$LESSONS_FILE"
    UPDATED=$((UPDATED + 1))

  fi
  # No matching pattern -- skip silently (line had no hit-trackable annotation).
done

echo "HIT UPDATE: ${UPDATED} line(s) updated in ${LESSONS_FILE}"

# Idempotent re-runs (all targets already today) still exit 0 so callers don't
# treat them as failures.
if [[ $UPDATED -eq 0 ]] && [[ $IDEMPOTENT -eq 0 ]]; then
  exit 1
fi

exit 0
