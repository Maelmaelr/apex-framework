#!/usr/bin/env bash
# Sync APEX skills + agents + CLAUDE.md from ~/.claude into ~/dev/apex-framework.
# One-way mirror: ~/.claude is source of truth. Safe to re-run.

set -euo pipefail

SRC_HOME="${HOME}/.claude"
DST="${HOME}/dev/apex-framework"

if [[ ! -d "$DST" ]]; then
  echo "apex-framework directory not found at $DST" >&2
  exit 1
fi

APEX_SKILLS=(
  apex
  apex-audit-matrix
  apex-brainstorm
  apex-eod
  apex-file-health
  apex-fix
  apex-git
  apex-init
  apex-lessons-analyze
  apex-lessons-extract
  apex-party
  admin-apex
)

AGENTS=(scout.md verifier.md evaluator.md)

mkdir -p "$DST/skills" "$DST/agents"

# Purge stale skills (anything in dst/skills not in APEX_SKILLS)
for existing in "$DST/skills"/*/; do
  [[ -d "$existing" ]] || continue
  name="$(basename "$existing")"
  keep=0
  for s in "${APEX_SKILLS[@]}"; do
    if [[ "$name" == "$s" ]]; then keep=1; break; fi
  done
  if [[ $keep -eq 0 ]]; then
    echo "Removing stale skill: $name"
    rm -rf "$existing"
  fi
done

# Sync each apex skill (rsync with --delete keeps mirror exact)
for skill in "${APEX_SKILLS[@]}"; do
  src="$SRC_HOME/skills/$skill"
  if [[ ! -d "$src" ]]; then
    echo "Source skill missing: $src" >&2
    continue
  fi
  rsync -a --delete "$src/" "$DST/skills/$skill/"
done

# Sync agents
for agent in "${AGENTS[@]}"; do
  src="$SRC_HOME/agents/$agent"
  if [[ -f "$src" ]]; then
    rsync -a "$src" "$DST/agents/$agent"
  fi
done

# CLAUDE.md
if [[ -f "$SRC_HOME/CLAUDE.md" ]]; then
  rsync -a "$SRC_HOME/CLAUDE.md" "$DST/CLAUDE.md"
fi

echo "Sync complete -> $DST"
