#!/usr/bin/env bash
# context-health-check.sh -- Check CLAUDE.md and skill file sizes against char budgets.
# Version: v1.0 -- 2026-04-12
# Usage: bash context-health-check.sh [--project-root <path>]
# Output: For each file exceeding thresholds:
#   CONTEXT HEALTH: {path} ({chars}c) -- {warn|block} (limit: {limit}c)
# Exit: 0 = no violations, 1 = warnings only, 2 = blocks found, 3 = bad arguments
#
# Thresholds (chars):
#   Project CLAUDE.md:  warn 30000, block 40000
#   Global CLAUDE.md:   warn 8000,  block 12000
#   Skill SKILL.md:     warn 35000, block 45000
#   Skill sub-files:    warn 30000, block 40000
#   Rule files:         warn 6000,  block 10000
#   MEMORY.md:          warn 4000,  block 8000

set -euo pipefail

PROJECT_ROOT=""

usage() {
  cat <<'EOF'
Usage: bash context-health-check.sh [--project-root <path>]

Options:
  --project-root <path>  Project root to check for project CLAUDE.md and rules
  --help                 Show this help

Checks context file sizes against char budgets. Reports warnings and blocks.

Exit codes:
  0  All files within budget
  1  Warnings found (approaching limits)
  2  Blocks found (over limits)
  3  Bad arguments
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root)
      PROJECT_ROOT="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 3
      ;;
  esac
done

WARN_COUNT=0
BLOCK_COUNT=0

check_file() {
  local filepath="$1"
  local warn_limit="$2"
  local block_limit="$3"
  local label="$4"

  if [[ ! -f "$filepath" ]]; then
    return
  fi

  local chars
  chars=$(wc -c < "$filepath" 2>/dev/null | tr -d ' ' || echo 0)

  if [[ "$chars" -gt "$block_limit" ]]; then
    echo "CONTEXT HEALTH: ${filepath} (${chars}c) -- block (limit: ${block_limit}c) [${label}]"
    BLOCK_COUNT=$((BLOCK_COUNT + 1))
  elif [[ "$chars" -gt "$warn_limit" ]]; then
    echo "CONTEXT HEALTH: ${filepath} (${chars}c) -- warn (limit: ${block_limit}c) [${label}]"
    WARN_COUNT=$((WARN_COUNT + 1))
  fi
}

# Global CLAUDE.md
check_file "$HOME/.claude/CLAUDE.md" 8000 12000 "global-claude-md"

# Project CLAUDE.md
if [[ -n "$PROJECT_ROOT" ]] && [[ -f "$PROJECT_ROOT/CLAUDE.md" ]]; then
  check_file "$PROJECT_ROOT/CLAUDE.md" 30000 40000 "project-claude-md"
fi

# Project rule files
if [[ -n "$PROJECT_ROOT" ]] && [[ -d "$PROJECT_ROOT/.claude/rules" ]]; then
  for f in "$PROJECT_ROOT/.claude/rules"/*.md; do
    [[ -f "$f" ]] || continue
    check_file "$f" 6000 10000 "project-rule"
  done
fi

# Skill SKILL.md files (entry points)
SKILLS_DIR="$HOME/.claude/skills"
if [[ -d "$SKILLS_DIR" ]]; then
  while IFS= read -r skillfile; do
    check_file "$skillfile" 35000 45000 "skill-entry"
  done < <(find "$SKILLS_DIR" -maxdepth 2 -name 'SKILL.md' 2>/dev/null)
fi

# Skill sub-files (non-SKILL.md .md files, excluding scripts/)
if [[ -d "$SKILLS_DIR" ]]; then
  while IFS= read -r subfile; do
    # Skip SKILL.md (handled above), README, and files in scripts/
    basename_f=$(basename "$subfile")
    [[ "$basename_f" == "SKILL.md" ]] && continue
    [[ "$basename_f" == "README.md" ]] && continue
    [[ "$subfile" == */scripts/* ]] && continue
    check_file "$subfile" 30000 40000 "skill-sub"
  done < <(find "$SKILLS_DIR" -name '*.md' 2>/dev/null)
fi

# MEMORY.md
if [[ -n "$PROJECT_ROOT" ]]; then
  # Derive memory path from project root
  SANITIZED=$(echo "$PROJECT_ROOT" | tr '/' '-')
  MEMORY_DIR="$HOME/.claude/projects/$SANITIZED/memory"
  if [[ -f "$MEMORY_DIR/MEMORY.md" ]]; then
    check_file "$MEMORY_DIR/MEMORY.md" 4000 8000 "memory-index"
  fi
fi

# Summary
TOTAL=$((WARN_COUNT + BLOCK_COUNT))
echo "CONTEXT HEALTH SUMMARY: ${TOTAL} issues (${BLOCK_COUNT} blocks, ${WARN_COUNT} warnings)"

if [[ "$BLOCK_COUNT" -gt 0 ]]; then
  exit 2
elif [[ "$WARN_COUNT" -gt 0 ]]; then
  exit 1
else
  exit 0
fi
