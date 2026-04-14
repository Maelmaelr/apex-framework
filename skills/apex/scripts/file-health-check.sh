#!/usr/bin/env bash
# file-health-check.sh -- Check file line counts against a threshold, report violations.
# Version: v1.0 -- 2026-03-28
# Usage: bash file-health-check.sh <threshold> file1 [file2 ...]
# Output: For each file exceeding threshold:
#   FILE HEALTH: {path} ({lines}L) -- {blocked|split-first}
#   blocked    = >500 lines (caller splits first unless trivial edit <=10 new lines)
#   split-first = >threshold AND <=500 lines (split before adding code)
# Exit: 0 = success (check output for violations), 2 = bad arguments
# Handles bracket paths safely (Next.js [locale], [id], etc.) via wc -l on each file.

set -euo pipefail

BLOCKED_THRESHOLD=500

usage() {
  cat <<'EOF'
Usage: bash file-health-check.sh <threshold> file1 [file2 ...]

Arguments:
  threshold   Line count threshold above which a file needs attention
              (>500 = blocked unless trivial, >threshold AND <=500 = split-first)
  file1 ...   One or more file paths to check

Exit codes:
  0  Success (check output for violations)
  2  Bad arguments (missing or invalid threshold)

Output (only for violations):
  FILE HEALTH: path/to/file.ts (523L) -- blocked
  FILE HEALTH: path/to/file.ts (445L) -- split-first

Examples:
  bash file-health-check.sh 400 apps/web/lib/auth.ts apps/api/app/services/foo.ts
  bash file-health-check.sh 400 "apps/web/app/[locale]/page.tsx"
EOF
}

if [[ $# -eq 0 ]] || [[ "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

THRESHOLD="$1"
shift

# No files provided -- nothing to check
if [[ $# -eq 0 ]]; then
  exit 0
fi

# Validate threshold is a positive integer
if ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]] || [[ "$THRESHOLD" -eq 0 ]]; then
  echo "error: threshold must be a positive integer, got: $THRESHOLD" >&2
  exit 2
fi

for filepath in "$@"; do
  # Skip missing files silently (caller may pass a list that includes deleted files)
  if [[ ! -f "$filepath" ]]; then
    continue
  fi

  # Use wc -l with input redirect -- safe for paths with brackets and spaces.
  # tr -d strips the leading whitespace macOS wc -l adds (e.g., "     445").
  lines=$(wc -l < "$filepath" 2>/dev/null | tr -d ' ' || echo 0)

  if [[ "$lines" -gt "$BLOCKED_THRESHOLD" ]]; then
    echo "FILE HEALTH: ${filepath} (${lines}L) -- blocked"
  elif [[ "$lines" -gt "$THRESHOLD" ]]; then
    echo "FILE HEALTH: ${filepath} (${lines}L) -- split-first"
  fi
done

exit 0
