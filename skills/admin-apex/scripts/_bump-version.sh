#!/usr/bin/env bash
# Purpose: Increment VERSION semver in place (patch, minor, or major).
# Spec: skills/admin-apex/SKILL.md task 9 (VERSION bump rules)
#
# Reads repo-root VERSION (semver: MAJOR.MINOR.PATCH), increments per arg, writes back.
# Echoes new version to stdout.
#
# Args:
#   patch   0.2.1 -> 0.2.2  (tweaks: edit ops within existing files)
#   minor   0.2.1 -> 0.3.0  (new features: create / schema-add / hook-add; resets patch to 0)
#   major   0.2.1 -> 1.0.0  (major evolution: rename / split / merge / retire /
#                            schema-remove / hook-remove; resets minor and patch to 0)
#
# Exit codes:
#   0 - VERSION updated, new version on stdout
#   1 - bad args / VERSION missing / VERSION malformed

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: _bump-version.sh patch|minor|major" >&2
  exit 1
fi

KIND="$1"
case "$KIND" in
  patch|minor|major) ;;
  *)
    echo "_bump-version.sh: invalid kind '$KIND' (expected patch|minor|major)" >&2
    exit 1
    ;;
esac

# admin-apex always operates on the apex framework at ~/.claude; pwd fallback
# would walk an unrelated project tree if invoked from outside the framework root.
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$HOME/.claude}"
VFILE="$REPO_ROOT/VERSION"

if [[ ! -f "$VFILE" ]]; then
  echo "_bump-version.sh: VERSION not found at $VFILE" >&2
  exit 1
fi

CURRENT=$(tr -d '[:space:]' < "$VFILE")
if [[ ! "$CURRENT" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "_bump-version.sh: VERSION malformed (expected MAJOR.MINOR.PATCH): '$CURRENT'" >&2
  exit 1
fi
MAJOR="${BASH_REMATCH[1]}"
MINOR="${BASH_REMATCH[2]}"
PATCH="${BASH_REMATCH[3]}"

case "$KIND" in
  patch) PATCH=$((PATCH + 1)) ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
esac

NEW="$MAJOR.$MINOR.$PATCH"
printf '%s\n' "$NEW" > "$VFILE"
echo "$NEW"
exit 0
