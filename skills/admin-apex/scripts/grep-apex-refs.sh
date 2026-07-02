#!/usr/bin/env bash
# Purpose: Print every textual reference to <path|name> across apex docs and code.
# Spec: skills/admin-apex/SKILL.md task 6 (evolve apply: rewrite refs)
#
# Search roots (in order):
#   skills/
#   agents/
#   apex-core.md
#   apex-core-overview.md
#   README.md
#   settings.json
#   CLAUDE.md  (if present at repo root)
#
# Output format (stdout, one match per line):
#   <repo-relative-path>:<line>:<matched-line>
#
# Args:
#   <path-or-name>   required, e.g. "skills/apex/scripts/worktree-fence-hook.sh"
#                    or "worktree-fence-hook.sh" (basename also works).
#
# Exit codes:
#   0 - search ran (matches OR no matches)
#   1 - bad args

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: grep-apex-refs.sh <path-or-name>" >&2
  exit 1
fi

NEEDLE="$1"
# admin-apex always operates on the apex framework at ~/.claude.
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$HOME/.claude}"
cd "$REPO_ROOT"

ROOTS=()
[[ -d "skills" ]] && ROOTS+=("skills")
[[ -d "agents" ]] && ROOTS+=("agents")
for f in apex-core.md apex-core-overview.md README.md settings.json CLAUDE.md; do
  [[ -f "$f" ]] && ROOTS+=("$f")
done

if [[ ${#ROOTS[@]} -eq 0 ]]; then
  exit 0
fi

# Fixed-string match -- callers pass literal paths or basenames; regex
# metacharacters (dots in filenames) must NOT be treated as regex.
# -n: line numbers. -H: filename. -r: recursive (no-op on plain files).
# Suppress "no matches" exit-1 from grep so admin-apex orchestrators see
# exit 0 == "search ran successfully".
grep -rnHF -- "$NEEDLE" "${ROOTS[@]}" 2>/dev/null || true

exit 0
