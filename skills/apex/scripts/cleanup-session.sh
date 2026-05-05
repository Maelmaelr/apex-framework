#!/usr/bin/env bash
# Step 14: idempotent session cleanup.
# Spec: apex-core.md step 14 + Failure handling / "cleanup-session.sh".
#
# Cleans (idempotent; exit 0 on partial cleanup with warnings to stderr):
#   - .claude-tmp/apex-active/{session}-main-scope.json
#   - .claude-tmp/apex-active/{session}-scopes/                (all scope-pointer files)
#   - .claude-tmp/apex-active/{session}-screened.json
#   - .claude-tmp/apex-active/{session}-lesson-screened.json
#   - .claude-tmp/apex-active/{session}-tier.json
#   - .claude-tmp/apex-active/{session}-traces/
#   - .claude-tmp/apex-active/{session}.json                   (manifest)
#   - .claude-tmp/apex-active/{session}-fix-attempts.json
#   - .claude-tmp/apex-active/{session}-baseline.json
#   - .claude-tmp/apex-active/{session}-verify-errors.txt
#
# Intentionally NOT cleaned (consumed by step 15):
#   - .claude-tmp/apex-active/{session}-hypothesis.json
#     session-end-hook.sh removes it as belt-and-suspenders fallback when consumer fails.
#
# Args:
#   --session <token>  (required; 8-char lowercase hex per Conventions / Session token format)
#   --post-success     (optional; bypasses the live-PID guard. Reserved for callers
#                       with authoritative knowledge that cleanup is safe -- step
#                       14 success path, mid-/apex abort paths, SessionEnd of the
#                       OWN session. Without this flag the guard fires when
#                       manifest.pid is alive AND comm=claude, and refuses cleanup
#                       as defense against sibling cleanup-stale-and-proceed
#                       misclassification.)
#
# Exit code: always 0 (idempotent contract; warnings to stderr).

# Intentionally NOT using `set -e`: cleanup is best-effort. A single rm failure
# (permission, race, etc.) must not abort remaining cleanup steps.
set -uo pipefail

APEX_ACTIVE=".claude-tmp/apex-active"

SESSION=""
POST_SUCCESS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)
      SESSION="${2:-}"
      shift 2
      ;;
    --post-success)
      POST_SUCCESS=1
      shift
      ;;
    *)
      echo "cleanup-session.sh: unknown arg: $1" >&2
      exit 0
      ;;
  esac
done

if [[ -z "$SESSION" ]]; then
  echo "cleanup-session.sh: --session is required" >&2
  exit 0
fi

# Token-shape guard: 8-char lowercase hex (per Conventions / Session token format).
if [[ ! "$SESSION" =~ ^[0-9a-f]{8}$ ]]; then
  echo "cleanup-session.sh: invalid session token shape: $SESSION (expected 8-char lowercase hex)" >&2
  exit 0
fi

warn() {
  echo "cleanup-session.sh: $*" >&2
}

# Live-session guard. Refuse cleanup if the manifest still exists AND its PID
# is alive AND `ps -o comm` matches "claude" - the same active classification
# create-session.sh uses. Defends against sibling cleanup-stale-and-proceed
# misclassification. --post-success bypasses this guard for trusted own-session
# callers (step 14, mid-flow abort, SessionEnd of own session); without it the
# guard would block legit own-cleanup since manifest.pid is the live caller's
# claude pid (resolved via find-claude-pid.sh at create-session.sh time).
if (( POST_SUCCESS == 0 )); then
  MF="$APEX_ACTIVE/${SESSION}.json"
  if [[ -f "$MF" ]]; then
    manifest_pid=$(python3 -c "
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding='utf-8')).get('pid', ''))
except Exception:
    pass
" "$MF" 2>/dev/null || true)
    if [[ -n "$manifest_pid" && "$manifest_pid" =~ ^[0-9]+$ ]] && kill -0 "$manifest_pid" 2>/dev/null; then
      comm_base="$(basename "$(ps -o comm= -p "$manifest_pid" 2>/dev/null || true)" 2>/dev/null || true)"
      if [[ "$comm_base" == "claude" ]]; then
        warn "refusing cleanup: session $SESSION pid=$manifest_pid is live (comm=claude); manifest preserved"
        exit 0
      fi
    fi
  fi
fi

rm_target() {
  local target="$1"
  rm -rf -- "$target" 2>/dev/null || warn "failed to remove: $target"
}

# Per-session cleanup. Each target removed independently so a single failure
# does not shadow others.
rm_target "$APEX_ACTIVE/${SESSION}-main-scope.json"
rm_target "$APEX_ACTIVE/${SESSION}-scopes"
rm_target "$APEX_ACTIVE/${SESSION}-screened.json"
rm_target "$APEX_ACTIVE/${SESSION}-lesson-screened.json"
rm_target "$APEX_ACTIVE/${SESSION}-tier.json"
rm_target "$APEX_ACTIVE/${SESSION}-traces"
rm_target "$APEX_ACTIVE/${SESSION}.json"
rm_target "$APEX_ACTIVE/${SESSION}-fix-attempts.json"
rm_target "$APEX_ACTIVE/${SESSION}-baseline.json"
rm_target "$APEX_ACTIVE/${SESSION}-verify-errors.txt"

exit 0
