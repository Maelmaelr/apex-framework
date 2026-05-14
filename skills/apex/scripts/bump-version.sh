#!/usr/bin/env bash
# Step 12: VERSION bump.
# Spec: apex-core.md step 12.
#
# Reads <project-root>/VERSION (vX.Y.Z; tolerates missing-`v` and trailing
# newlines), increments per --kind, writes back. Missing file = silent skip
# (exit 0 with stdout "skipped"). Never bumps major; major is user-set only.
#
# Args:
#   --kind {minor|patch}   required; the orchestrator-judged classification.
#                          minor: new feature / new public symbol / additive
#                                 OR breaking API change.
#                          patch: bug fix, refactor, internal-only tweak.
#                          Anything else -> exit 1.
#
# Output:
#   On bump:    "vX.Y.Z -> vX.Y.Z" on stdout (the rewritten string)
#   On missing: "skipped: VERSION not found" on stdout
#   On error:   stderr message + non-zero exit
#
# Exit codes:
#   0 - bumped or silently skipped
#   1 - bad args / parse failure / write failure

set -euo pipefail

KIND=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kind)
      KIND="${2:-}"
      shift 2
      ;;
    *)
      echo "bump-version.sh: unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$KIND" ]]; then
  echo "bump-version.sh: --kind {minor|patch} is required" >&2
  exit 1
fi

if [[ "$KIND" != "minor" && "$KIND" != "patch" ]]; then
  echo "bump-version.sh: --kind must be 'minor' or 'patch' (got '$KIND')" >&2
  exit 1
fi

if [[ ! -f VERSION ]]; then
  echo "skipped: VERSION not found"
  exit 0
fi

# Read + normalize. Strip leading 'v' (tolerated) and trailing whitespace.
raw="$(tr -d '[:space:]' < VERSION)"
v="${raw#v}"

if ! [[ "$v" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "bump-version.sh: VERSION format unexpected: '$raw' (expected vX.Y.Z)" >&2
  exit 1
fi

major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"

case "$KIND" in
  minor)
    minor=$((minor + 1))
    patch=0
    ;;
  patch)
    patch=$((patch + 1))
    ;;
esac

new="v${major}.${minor}.${patch}"
old="v${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"

printf '%s\n' "$new" > VERSION

# Post-write verify: re-read file and confirm the bump landed. Reflector
# 5c32d3e2 surfaced a commit subject claiming v2.205.6 while VERSION file
# content was unchanged - silent no-op poisons the commit message. Fail loud.
written="$(tr -d '[:space:]' < VERSION)"
if [[ "$written" != "$new" ]]; then
  echo "bump-version.sh: post-write verify failed (expected '$new', file has '$written')" >&2
  exit 1
fi

echo "$old -> $new"
exit 0
