#!/usr/bin/env bash
# apex-conflict-check.sh -- detect concurrent-apex scope overlap.
# Spec: apex-core.md p1.0 main-mode (Step 2b) + p2.0 (Step 2).
#
# Computes pre-dirty union (tracked-modified UNION untracked-non-ignored), scans
# every other active apex *-main-scope.json (excluding our own {session}) for
# overlap. Exits 1 with overlap list on stdout; 0 if clean. The orchestrator
# (model) reads stdout, drives AskUserQuestion (abort | proceed-anyway), and on
# abort runs scripts/session-end-hook.sh inline.
#
# Args (positional):
#   $1  -- {session} 8-hex token (required)
#
# Stdout (on overlap):
#   <file> -> <scope-basename>   (one per line)
#
# Exit codes:
#   0  -- no overlap
#   1  -- overlap detected (list on stdout)
#   2  -- bad args, git missing, or jq missing

set -euo pipefail

SESSION="${1:-}"

if [[ -z "$SESSION" ]]; then
  echo "apex-conflict-check.sh: {session} positional arg is required" >&2
  exit 2
fi

if ! [[ "$SESSION" =~ ^[0-9a-f]{8}$ ]]; then
  echo "apex-conflict-check.sh: session token '$SESSION' is not 8-hex" >&2
  exit 2
fi

if ! command -v git >/dev/null 2>&1; then
  echo "apex-conflict-check.sh: git not found" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "apex-conflict-check.sh: jq not found" >&2
  exit 2
fi

APEX_ACTIVE=".claude-tmp/apex-active"

pre_dirty=$( (git diff --name-only HEAD; git ls-files --others --exclude-standard) | sort -u )

overlap_count=0
shopt -s nullglob
for scope in "$APEX_ACTIVE"/*-main-scope.json; do
  [[ -f "$scope" ]] || continue
  [[ "$scope" == *"$SESSION-main-scope.json" ]] && continue
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if jq -e --arg f "$f" '.allowed_files | index($f)' "$scope" >/dev/null 2>&1; then
      printf '%s -> %s\n' "$f" "$(basename "$scope")"
      overlap_count=$((overlap_count + 1))
    fi
  done <<< "$pre_dirty"
done
shopt -u nullglob

if [[ "$overlap_count" -gt 0 ]]; then
  exit 1
fi

exit 0
