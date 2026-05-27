#!/usr/bin/env bash
# Step 4: load lessons -- grep curated project lessons by hypothesis keywords.
# Spec: apex-core.md step 4 + Conventions / Project lessons paths.
#
# Reads:
#   <project-root>/.claude/lessons-index.md  (curated index)
#   <project-root>/.claude/lessons.md        (curated body)
# Index format: free-form lines containing "keyword/phrase -> Section Name".
# Body format: H2 sections (`## Section Name`) followed by lesson lines.
#
# Args:
#   <project-root>            required (orchestrator passes its CWD)
#   <term1> [<term2> ...]     >=1 keyword from the hypothesis (case-insensitive
#                             fixed-string match against the index)
#
# Output (stdout):
#   For each matched section, an absolute-line marker followed by the section
#   body, separated by blank lines:
#       --- LINES <start>-<end> ---
#       ## Section Name
#       <lesson lines>
#
#       --- LINES ...
#
#   Line numbers are absolute in lessons.md and feed update-hit.sh directly
#   (range tokens like `522-573` are accepted by update-hit.sh as of reflector
#   00bac875).
#   Total output capped at MAX_OUTPUT_LINES (240) with a TRUNCATED footer
#   when the cap fires; orchestrator should re-run with fewer / more specific
#   terms. Cap walked 120 -> 180 -> 240: 120 silently dropped subsections of
#   10-section grep outputs (reflector cluster 88c1d75f / b512525e / 093978c0);
#   180 still tripped truncation + rescreen on moderate-section spans with
#   narrow keyword sets (reflectors 5e81663b / e3acb457 on 330+ line
#   lessons.md). 240 covers the common case without paying the rescreen
#   round-trip.
#
# Exit codes:
#   0 - success OR no matches OR project lessons absent (no-output success)
#   1 - bad args (missing project-root or zero terms)

set -euo pipefail

PROJECT_ROOT="${1:-}"
shift || true

if [[ -z "$PROJECT_ROOT" ]] || [[ $# -eq 0 ]]; then
  echo "Usage: grep-lessons.sh <project-root> <term1> [term2] ..." >&2
  exit 1
fi

INDEX_FILE="$PROJECT_ROOT/.claude/lessons-index.md"
LESSONS_FILE="$PROJECT_ROOT/.claude/lessons.md"

# Project hasn't curated lessons yet -- step 4 is best-effort, exit cleanly.
if [[ ! -f "$INDEX_FILE" ]] || [[ ! -f "$LESSONS_FILE" ]]; then
  exit 0
fi

# Build grep args for case-insensitive fixed-string OR.
GREP_ARGS=()
for term in "$@"; do
  GREP_ARGS+=(-e "$term")
done

# Resolve matched index lines -> section names (text after " -> "), dedup.
MATCHED_SECTIONS=()
while IFS= read -r line; do
  section="${line##* -> }"
  section="$(echo "$section" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "$section" ]] && continue
  already=false
  for existing in "${MATCHED_SECTIONS[@]+"${MATCHED_SECTIONS[@]}"}"; do
    [[ "$existing" == "$section" ]] && { already=true; break; }
  done
  [[ "$already" == false ]] && MATCHED_SECTIONS+=("$section")
done < <(grep -iF "${GREP_ARGS[@]}" "$INDEX_FILE" 2>/dev/null || true)

[[ ${#MATCHED_SECTIONS[@]} -eq 0 ]] && exit 0

# Output cap: defense-in-depth against exceeding Read tool / context limits.
# Walked 120 -> 180 -> 240. 120 silently dropped subsections of 10-section
# outputs (reflector cluster 88c1d75f / b512525e / 093978c0). 180 still tripped
# truncation + rescreen with narrow keyword sets on moderate-section spans
# (reflectors 5e81663b / e3acb457 on 330+ line lessons.md). 240 covers the
# common case without paying the rescreen round-trip; widening further returns
# marginal coverage.
MAX_OUTPUT_LINES=240
OUTPUT_LINES=0
TOTAL_LINES=$(wc -l < "$LESSONS_FILE")

for section in "${MATCHED_SECTIONS[@]}"; do
  # Locate "## ${section}" header (exact-line fixed-string match -- no regex
  # collisions with section names that contain regex metacharacters).
  HEADER_LINE=$(grep -nF "## ${section}" "$LESSONS_FILE" 2>/dev/null | while IFS=: read -r num line; do
    if [[ "$line" == "## ${section}" ]]; then
      echo "$num"
      break
    fi
  done)
  HEADER_LINE="${HEADER_LINE:-}"
  [[ -z "$HEADER_LINE" ]] && continue

  # Find next H2 (relative to header+1, convert to absolute).
  END_LINE=$(tail -n +"$((HEADER_LINE + 1))" "$LESSONS_FILE" | grep -n "^## " | head -1 | cut -d: -f1 || true)
  if [[ -n "$END_LINE" ]]; then
    ABS_END=$((HEADER_LINE + END_LINE))
    BLOCK_LENGTH=$((ABS_END - HEADER_LINE))
  else
    BLOCK_LENGTH=$((TOTAL_LINES - HEADER_LINE + 1))
    ABS_END=$((TOTAL_LINES + 1))
  fi

  # Pre-emit cap check (marker + block + blank = BLOCK_LENGTH + 2 lines).
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

exit 0
