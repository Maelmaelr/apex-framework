#!/usr/bin/env bash
# Purpose: Increment VERSION semver in place (patch or minor).
# Spec: skills/admin-apex/SKILL.md task 9 (VERSION bump rules)
#
# Reads repo-root VERSION (semver: MAJOR.MINOR.PATCH), increments per arg, writes back.
# Echoes new version to stdout.
#
# Args:
#   patch   0.2.1 -> 0.2.2
#   minor   0.2.1 -> 0.3.0  (resets patch to 0)
#
# Major bumps are intentionally out of scope (per SKILL.md "Out of scope").
#
# Exit codes:
#   0 - VERSION updated, new version on stdout
#   1 - bad args / VERSION missing / VERSION malformed

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: _bump-version.sh patch|minor" >&2
  exit 1
fi

KIND="$1"
case "$KIND" in
  patch|minor) ;;
  *)
    echo "_bump-version.sh: invalid kind '$KIND' (expected patch|minor)" >&2
    exit 1
    ;;
esac

REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
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
esac

NEW="$MAJOR.$MINOR.$PATCH"
printf '%s\n' "$NEW" > "$VFILE"
echo "$NEW"
exit 0
