#!/usr/bin/env bash
# SessionEnd hook + manual entry point.
# Spec: apex-core.md Conventions / Failure handling / "session-end-hook.sh".
#
# Wraps cleanup-session.sh + removes {session}-hypothesis.json (belt-and-suspenders fallback
# when consumer step 15 fails).
#
# Invocation modes:
#   1. SessionEnd (no positional arg):
#      - Read session_id from hook stdin event JSON
#      - Match against active manifests' cc_session_id
#      - Derive apex {session} token, then run cleanup with --post-success
#        (own-session ending; cleanup is safe).
#   2. Manual mode (positional arg = apex {session} token):
#      - Default: trusted own-session caller (mid-/apex abort: step 1 / 2 / 6
#        cascade-empty / 8 conflict-check / 10 verify cap-3 / unexpected error).
#        Pass --post-success internally.
#      - With --foreign flag: foreign caller (cleanup-stale-and-proceed at step 2
#        per-stale-manifest invocation). Do NOT pass --post-success;
#        cleanup-session.sh's live-PID guard fires as defense against sibling
#        classifier bugs (manifest pid alive AND comm=claude means the live
#        session would be wrongly wiped).
#      - Skips manifest matching, targets the supplied token directly.
#
# Runs on success completion AND on abort / crash. Idempotent.
#
# Exit code: 0 (always; treat as pass for SessionEnd hook contract).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve APEX_ACTIVE absolutely. CC sets CLAUDE_PROJECT_DIR for hooks; manual
# callers (mid-/apex abort) inherit project root via $PWD. Bare relative path
# was the prior behaviour and silently failed when the hook's CWD diverged
# from project root (orphaned artifacts in a project's .claude-tmp/apex-active
# until the next manual /apex run swept them).
if [[ -n "${APEX_ACTIVE_DIR:-}" ]]; then
  APEX_ACTIVE="$APEX_ACTIVE_DIR"
elif [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
  APEX_ACTIVE="$CLAUDE_PROJECT_DIR/.claude-tmp/apex-active"
else
  APEX_ACTIVE="$PWD/.claude-tmp/apex-active"
fi

derive_session_from_stdin() {
  # Read hook event JSON from stdin, extract session_id, match against active
  # manifests' cc_session_id, echo apex {session} token. Non-/apex CC session
  # (no manifest matches) -> nothing to clean, return non-zero so caller skips.
  local stdin_json session_id
  stdin_json=$(cat 2>/dev/null || true)
  [[ -z "$stdin_json" ]] && return 1
  session_id=$(printf '%s' "$stdin_json" | python3 -c "
import json, sys
try:
    print(json.load(sys.stdin).get('session_id', ''))
except Exception:
    pass
" 2>/dev/null || true)
  [[ -z "$session_id" ]] && return 1

  [[ -d "$APEX_ACTIVE" ]] || return 1
  shopt -s nullglob
  for manifest in "$APEX_ACTIVE"/*.json; do
    # 8-hex.json filename guard: excludes -hypothesis.json, -baseline.json,
    # -*-scope.json, etc. by shape.
    [[ "$(basename "$manifest")" =~ ^[0-9a-f]{8}\.json$ ]] || continue
    local matched
    matched=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    sys.exit(0)
sid = sys.argv[2]
if d.get('cc_session_id') == sid:
    print(d.get('session', ''))
" "$manifest" "$session_id" 2>/dev/null || true)
    if [[ -n "$matched" ]]; then
      printf '%s' "$matched"
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

run_cleanup() {
  local session="$1"
  local foreign="${2:-0}"
  [[ -z "$session" ]] && return 0
  # Wrap cleanup-session.sh (idempotent; fail-silent). Trusted callers
  # (own-session: SessionEnd hook + manual-mid-abort) pass --post-success.
  # Foreign caller (cleanup-stale-and-proceed) omits the flag so the guard
  # fires defensively if the classifier got it wrong.
  # Forward the resolved APEX_ACTIVE so cleanup-session.sh agrees on the
  # target directory regardless of its own resolution chain (env / CWD).
  if [[ -x "$SCRIPT_DIR/cleanup-session.sh" ]]; then
    if (( foreign == 1 )); then
      "$SCRIPT_DIR/cleanup-session.sh" --session "$session" --apex-active-dir "$APEX_ACTIVE" 2>/dev/null || true
    else
      "$SCRIPT_DIR/cleanup-session.sh" --session "$session" --post-success --apex-active-dir "$APEX_ACTIVE" 2>/dev/null || true
    fi
  fi
  # Belt-and-suspenders: remove hypothesis.json if consumer step 15 failed to clean up.
  # Skip on foreign cleanups when the guard refused (manifest still present) so a
  # misclassified live session keeps its hypothesis intact.
  if (( foreign == 1 )) && [[ -f "$APEX_ACTIVE/$session.json" ]]; then
    return 0
  fi
  rm -f "$APEX_ACTIVE/$session-hypothesis.json" 2>/dev/null || true
}

# Parse args: positional = manual mode session token; --foreign = foreign caller.
SESSION_ARG=""
FOREIGN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --foreign)
      FOREIGN=1
      shift
      ;;
    --)
      shift
      ;;
    *)
      if [[ -z "$SESSION_ARG" ]]; then
        SESSION_ARG="$1"
      fi
      shift
      ;;
  esac
done

if [[ -n "$SESSION_ARG" ]]; then
  # Manual mode: positional arg is the apex {session} token.
  run_cleanup "$SESSION_ARG" "$FOREIGN"
else
  # SessionEnd hook mode: derive token from stdin manifest match.
  if SESSION=$(derive_session_from_stdin); then
    run_cleanup "$SESSION" 0
  fi
  # No matching manifest -> non-/apex CC session; nothing to clean.
fi

exit 0
