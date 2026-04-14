#!/usr/bin/env bash
# cleanup-session.sh -- Remove .claude-tmp/ artifacts for a completed APEX session.
# Usage: bash cleanup-session.sh <session-id> [project-root]
# Called by: SKILL.md Step 6A, apex-apex.md Step 2.6/2.6a, apex-plan-template.md Phase 4
# Version: v1.1 -- 2026-03-28
# Arguments:
#   session-id    APEX session ID to clean (e.g., "apex-33of2yzf")
#   project-root  Optional path to project root (default: current directory)
# Exit codes:
#   0  Cleanup done (even if nothing was removed)
#   1  Missing required arguments

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash cleanup-session.sh <session-id> [project-root]

Arguments:
  session-id    APEX session ID to clean (e.g., "apex-33of2yzf")
  project-root  Path to project root (default: current directory)

Artifacts removed (all under {project-root}/.claude-tmp/):
  apex-active/{session-id}.json
  apex-active/{session-id}-scope.json
  apex-active/{session-id}-budget.json
  scout/  (scout-findings-*.md and audit-checklist-*.md)
  git-diff/  (git-diff-*.md)
  apex-context/  (apex-context-*.md)
  apex-baseline-*.txt  (team scope baselines)
  pre-agent-diff.stat  (subagent delegation baseline)

Exit codes:
  0  Cleanup done (even if nothing was removed)
  1  Missing required arguments

Notes:
  - Idempotent: safe to re-run after partial cleanup
  - Does NOT remove party/brainstorm archives
  - Does NOT remove persistent files (lessons.md, lessons-index.md, audit/PRD docs)
  - Does NOT remove test-gaps.md (managed by apex-tail.md conditional cleanup)

Examples:
  bash cleanup-session.sh apex-33of2yzf
  bash cleanup-session.sh apex-33of2yzf /path/to/project
EOF
}

if [[ "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -eq 0 ]]; then
  echo "error: session-id is required" >&2
  usage >&2
  exit 1
fi

if [[ ! "$1" =~ ^apex-[a-z0-9]{8}$ ]]; then
  echo "error: invalid session-id format (expected: apex-XXXXXXXX)" >&2
  exit 1
fi

SESSION_ID="${1}"
PROJECT_ROOT="${2:-.}"

TMP_DIR="${PROJECT_ROOT}/.claude-tmp"
removed_count=0

# Helper: remove a single file and report
remove_file() {
  local label="$1"
  local path="$2"
  if [[ -f "$path" ]]; then
    rm -f "$path"
    echo "CLEANUP: Removed ${label}"
    removed_count=$((removed_count + 1))
  else
    echo "CLEANUP: No ${label} found for ${SESSION_ID}"
  fi
}

# Helper: remove a directory and report
remove_dir() {
  local label="$1"
  local path="$2"
  if [[ -d "$path" ]]; then
    rm -rf "$path"
    echo "CLEANUP: Removed ${label}"
    removed_count=$((removed_count + 1))
  else
    echo "CLEANUP: No ${label} found for ${SESSION_ID}"
  fi
}

# 1. Session manifest and state files
remove_file "apex-active/${SESSION_ID}.json" "${TMP_DIR}/apex-active/${SESSION_ID}.json"
remove_file "apex-active/${SESSION_ID}-scope.json" "${TMP_DIR}/apex-active/${SESSION_ID}-scope.json"
remove_file "apex-active/${SESSION_ID}-budget.json" "${TMP_DIR}/apex-active/${SESSION_ID}-budget.json"

# 1b. Stale manifest cleanup (>2h old, from other sessions)
if [[ -d "${TMP_DIR}/apex-active" ]]; then
  now=$(date +%s)
  while IFS= read -r -d '' f; do
    [[ "$(basename "$f")" == "${SESSION_ID}"* ]] && continue
    file_age=$(( now - $(stat -f %m "$f" 2>/dev/null || echo "$now") ))
    if (( file_age > 7200 )); then
      rm -f "$f"
      echo "CLEANUP: Removed stale $(basename "$f") (age: $(( file_age / 3600 ))h)"
      removed_count=$((removed_count + 1))
    fi
  done < <(find "${TMP_DIR}/apex-active" -maxdepth 1 -name "*.json" -print0 2>/dev/null)
fi

# 2. Scout findings and audit checklists (scout-findings-*.md, audit-checklist-*.md)
#    These use independent UIDs, not session-id. Clean all since sessions are serialized
#    (SKILL.md Step 0 warns on concurrency).
scout_found=false
if [[ -d "${TMP_DIR}/scout" ]]; then
  while IFS= read -r -d '' f; do
    rm -f "$f"
    echo "CLEANUP: Removed scout/$(basename "$f")"
    removed_count=$((removed_count + 1))
    scout_found=true
  done < <(find "${TMP_DIR}/scout" -maxdepth 1 -name "*.md" -print0 2>/dev/null)
fi
if [[ "$scout_found" == false ]]; then
  echo "CLEANUP: No scout artifacts found"
fi

# 3. Diff summaries (git-diff-*.md -- independent UIDs)
diff_found=false
if [[ -d "${TMP_DIR}/git-diff" ]]; then
  while IFS= read -r -d '' f; do
    rm -f "$f"
    echo "CLEANUP: Removed git-diff/$(basename "$f")"
    removed_count=$((removed_count + 1))
    diff_found=true
  done < <(find "${TMP_DIR}/git-diff" -maxdepth 1 -name "*.md" -print0 2>/dev/null)
fi
if [[ "$diff_found" == false ]]; then
  echo "CLEANUP: No diff summaries found"
fi

# 4. Teammate context files (apex-context-*.md -- independent UIDs)
context_found=false
if [[ -d "${TMP_DIR}/apex-context" ]]; then
  while IFS= read -r -d '' f; do
    rm -f "$f"
    echo "CLEANUP: Removed apex-context/$(basename "$f")"
    removed_count=$((removed_count + 1))
    context_found=true
  done < <(find "${TMP_DIR}/apex-context" -maxdepth 1 -name "*.md" -print0 2>/dev/null)
fi
if [[ "$context_found" == false ]]; then
  echo "CLEANUP: No context files found"
fi

# 5. Team baseline files (apex-baseline-*.txt -- keyed by team-name, not session-id)
#    Created by apex-team.md Step 1 for scope verification. Safe to remove after session.
baseline_found=false
while IFS= read -r -d '' f; do
  rm -f "$f"
  echo "CLEANUP: Removed $(basename "$f")"
  removed_count=$((removed_count + 1))
  baseline_found=true
done < <(find "${TMP_DIR}" -maxdepth 1 -name "apex-baseline-*.txt" -print0 2>/dev/null)
if [[ "$baseline_found" == false ]]; then
  echo "CLEANUP: No baseline files found"
fi

# 6. Pre-agent diff stat (pre-agent-diff.stat -- from subagent-delegation.md)
#    Normally self-cleaned by delegation protocol, but clean here as safety net.
if [[ -f "${TMP_DIR}/pre-agent-diff.stat" ]]; then
  rm -f "${TMP_DIR}/pre-agent-diff.stat"
  echo "CLEANUP: Removed pre-agent-diff.stat"
  removed_count=$((removed_count + 1))
fi

# 7. test-gaps.md -- NOT removed here. test-gaps.md persists across sessions
#    and is only removed by apex-tail.md when the session that consumed it completes.
#    cleanup-session.sh cannot distinguish "consumed source" from "newly written by verify."

echo ""
echo "SESSION CLEANUP: ${removed_count} artifacts removed for ${SESSION_ID}"
