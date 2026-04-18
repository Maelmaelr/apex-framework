#!/usr/bin/env bash
# detect-tail-mode.sh -- Determine economy vs full tail mode from file change scope.
# Called by: apex-apex.md Phase 4, SKILL.md Step 6A sub-step 1c
# Usage: bash detect-tail-mode.sh file1 file2 ...
# Output: TAIL MODE: {economy|full} -- {N} files, {M} lines (threshold: <=5 files AND <=80 lines)
# Exit: 0 = economy, 1 = full

set -euo pipefail

# Self-anchor to git toplevel so `git diff --numstat` resolves file args regardless of caller CWD (shared-guardrails #16).
cd "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || true

files=("$@")
if [ ${#files[@]} -eq 0 ]; then
  echo "TAIL MODE: economy -- 0 files, 0 lines (threshold: <=5 files AND <=80 lines)"
  exit 0
fi

total_files=0
total_lines=0

# Measure tracked file changes via git diff --numstat
# Per-file lines (added + deleted); robust to large arg lists (no trailing summary line).
while IFS=$'\t' read -r ins del _path; do
  [ -z "${ins:-}" ] && continue
  # --numstat emits "-" for binary files; treat as 0 lines
  [ "$ins" = "-" ] && ins=0
  [ "$del" = "-" ] && del=0
  total_files=$((total_files + 1))
  total_lines=$((total_lines + ins + del))
done < <(git diff --numstat -- "${files[@]}" 2>/dev/null || true)

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
