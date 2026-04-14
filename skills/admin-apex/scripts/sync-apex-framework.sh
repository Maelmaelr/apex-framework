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

# CLAUDE.md -- extract content between <!-- APEX:BEGIN --> and <!-- APEX:END -->
# markers into templates/apex-rules.md so the public installer gets a sanitized
# block (no personal sections like Chrome MCP). If markers are absent, fall back
# to copying the whole file (legacy behavior).
if [[ -f "$SRC_HOME/CLAUDE.md" ]]; then
  mkdir -p "$DST/templates"
  if grep -q '<!-- APEX:BEGIN -->' "$SRC_HOME/CLAUDE.md" && \
     grep -q '<!-- APEX:END -->' "$SRC_HOME/CLAUDE.md"; then
    awk '
      /<!-- APEX:BEGIN -->/ { inside=1; next }
      /<!-- APEX:END -->/   { inside=0; next }
      inside
    ' "$SRC_HOME/CLAUDE.md" > "$DST/templates/apex-rules.md"
  else
    echo "WARNING: APEX:BEGIN/END markers not found in CLAUDE.md; copying full file" >&2
    rsync -a "$SRC_HOME/CLAUDE.md" "$DST/templates/apex-rules.md"
  fi
  # Keep CLAUDE.md at repo root for backwards-compat readers
  rsync -a "$SRC_HOME/CLAUDE.md" "$DST/CLAUDE.md"
fi

# Global audit-criteria catalogs -- bundle into apex-framework so create-apex
# ships starter catalogs (skill-quality.md, etc.) into ~/.claude/audit-criteria/.
if [[ -d "$SRC_HOME/audit-criteria" ]]; then
  mkdir -p "$DST/audit-criteria"
  rsync -a --delete "$SRC_HOME/audit-criteria/" "$DST/audit-criteria/"
fi

# hooks.json template (templates/hooks.json) is hand-maintained in apex-framework
# as the canonical hook entries consumed by the create-apex installer. Not synced
# from ~/.claude/settings.json (which mixes personal entries); edit it there.

# Purge Python cache dirs (they regenerate and don't belong in the mirror)
find "$DST/skills" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$DST/skills" -type f -name "*.pyc" -delete 2>/dev/null || true

echo "Sync complete -> $DST"
