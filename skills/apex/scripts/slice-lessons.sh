#!/usr/bin/env bash
# Step 5: post-screen lesson slicer -- materialize verbatim section bodies for
# the line ranges the lesson-screener kept, OFF the Haiku critical path.
# Spec: apex-core.md step 5 + agents/lesson-screener.md.
#
# The screener (Haiku, agents/lesson-screener.md) emits kept[] as
# {line_range, section_title, screener_reason} only -- it never re-emits
# section bodies (verbatim content re-emission in a cold Haiku context was
# ~81% of step-5 wall). The orchestrator runs THIS script
# over kept[].line_range after the screen to recover the bodies
# deterministically (plain sed), then back-fills kept[].content for the
# downstream-spawn role (steps 6/8/9/10/11 subagents do not inherit working
# memory; they receive lessons via spawn prompt).
#
# Output is byte-identical in shape to grep-lessons.sh so any downstream
# parser / update-hit.sh consumer treats both sources uniformly:
#       --- LINES <start>-<end> ---
#       <verbatim lessons.md body for that range>
#       <blank line>
#
# Args:
#   <lessons-file>          required (<project-root>/.claude/lessons.md)
#   <range1> [<range2> ...]  >=1 range token `START-END` (absolute lines in
#                            lessons.md; same tokens as kept[].line_range and
#                            grep-lessons.sh `--- LINES s-e ---` markers)
#
# Exit codes:
#   0 - success, OR lessons file absent (best-effort, mirrors grep-lessons.sh)
#   1 - bad args (missing lessons file arg / zero ranges / malformed range)

set -euo pipefail

LESSONS_FILE="${1:-}"
shift || true

if [[ -z "$LESSONS_FILE" ]] || [[ $# -eq 0 ]]; then
  echo "Usage: slice-lessons.sh <lessons-file> <START-END> [START-END] ..." >&2
  exit 1
fi

# Lessons file absent -> best-effort no-output success (the orchestrator only
# calls this when the screener kept ranges, but stay symmetric with
# grep-lessons.sh which exits 0 when project lessons are absent).
[[ -f "$LESSONS_FILE" ]] || exit 0

TOTAL_LINES=$(wc -l < "$LESSONS_FILE")

for range in "$@"; do
  if [[ ! "$range" =~ ^[0-9]+-[0-9]+$ ]]; then
    echo "slice-lessons.sh: malformed range token '$range' (want START-END)" >&2
    exit 1
  fi
  START="${range%-*}"
  END="${range#*-}"
  if [[ "$START" -gt "$END" ]]; then
    echo "slice-lessons.sh: inverted range '$range' (START > END)" >&2
    exit 1
  fi
  # Clamp END to file length; skip a range that starts past EOF (stale token).
  [[ "$START" -gt "$TOTAL_LINES" ]] && continue
  [[ "$END" -gt "$TOTAL_LINES" ]] && END="$TOTAL_LINES"

  echo "--- LINES ${START}-${END} ---"
  sed -n "${START},${END}p" "$LESSONS_FILE"
  echo ""
done

exit 0
