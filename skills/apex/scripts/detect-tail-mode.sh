#!/usr/bin/env bash
# detect-tail-mode.sh -- Determine economy vs full tail mode from file change scope.
# Called by: apex-apex.md Phase 4, SKILL.md Step 6A sub-step 1c
# Usage: bash detect-tail-mode.sh file1 file2 ...
# Output: TAIL MODE: {economy|full} -- {N} files, {M} lines (threshold: <=5 files AND <=80 lines)
# Exit: 0 = economy, 1 = full

set -euo pipefail

files=("$@")
if [ ${#files[@]} -eq 0 ]; then
  echo "TAIL MODE: economy -- 0 files, 0 lines (threshold: <=5 files AND <=80 lines)"
  exit 0
fi

total_files=0
total_lines=0

# Measure tracked file changes via git diff --stat
diff_output=$(git diff --stat -- "${files[@]}" 2>/dev/null || true)
if [ -n "$diff_output" ]; then
  summary=$(echo "$diff_output" | tail -1)
  file_count=$(echo "$summary" | grep -oE '[0-9]+ files? changed' | grep -oE '[0-9]+' || echo 0)
  insertions=$(echo "$summary" | grep -oE '[0-9]+ insertions?' | grep -oE '[0-9]+' || echo 0)
  deletions=$(echo "$summary" | grep -oE '[0-9]+ deletions?' | grep -oE '[0-9]+' || echo 0)
  total_files=$((file_count))
  total_lines=$((insertions + deletions))
fi

# Add untracked files from the provided list
untracked=$(git ls-files --others --exclude-standard 2>/dev/null || true)
for f in "${files[@]}"; do
  if echo "$untracked" | grep -qxF "$f" 2>/dev/null; then
    if [ -f "$f" ]; then
      lines=$(wc -l < "$f" 2>/dev/null || echo 0)
      total_files=$((total_files + 1))
      total_lines=$((total_lines + lines))
    fi
  fi
done

# Apply threshold
if [ "$total_files" -le 5 ] && [ "$total_lines" -le 80 ]; then
  echo "TAIL MODE: economy -- ${total_files} files, ${total_lines} lines (threshold: <=5 files AND <=80 lines)"
  exit 0
else
  echo "TAIL MODE: full -- ${total_files} files, ${total_lines} lines (threshold: <=5 files AND <=80 lines)"
  exit 1
fi
