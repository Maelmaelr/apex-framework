#!/usr/bin/env bash
# SessionEnd hook + manual entry point.
# Spec: apex-core.md Conventions / Failure handling / "session-end-hook.sh".
#
# Wraps cleanup-session.sh + removes {session}-hypothesis.json (belt-and-suspenders fallback
# when consumer p1.6 / p2.7 fails).
#
# Invocation modes:
#   1. SessionEnd (no positional arg):
#      - Read session_id from hook stdin event JSON
#      - Match against active manifests' cc_session_id / p2_cc_session_id
#      - Derive apex {session} token, then run cleanup
#   2. Manual (positional arg = apex {session} token):
#      - Used by:
#        - cleanup-stale-and-proceed at step 2 (per-stale-manifest invocation)
#        - mid-/apex abort cleanup at step 6.a / 6.b / p1.0 / p2.0 / verify exit-1 / teammate-failure / p2.0c rejection
#      - Skips manifest matching, targets the supplied token directly
#
# Runs on success completion AND on abort / crash. Idempotent.
#
# Exit code: 0 (always; treat as pass for SessionEnd hook contract).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APEX_ACTIVE=".claude-tmp/apex-active"

derive_session_from_stdin() {
  # Read hook event JSON from stdin, extract session_id, match against active
  # manifests' cc_session_id / p2_cc_session_id, echo apex {session} token.
  #
  # Match priority + Path-2-transition guard:
  #   - p2_cc_session_id == session_id  -> post-context-clear CC session ending; cleanup OK.
  #   - cc_session_id == session_id     -> entry-flow CC session ending. SKIP cleanup if
  #     (a) p2_cc_session_id is also set (p2 session owns lifecycle), OR
  #     (b) {session}-plan-candidate.json exists on disk - the canonical "Path 2
  #         mid-transition" marker (written at p2.0b before context clear, removed
  #         by cleanup-session.sh). The post-clear p2.md session inherits the
  #         manifest + scopes; SessionEnd for the post-clear CC session (matched
  #         via p2_cc_session_id) cleans up after p2.6 / p2.7.
  #   - neither field matches           -> non-/apex CC session; nothing to clean.
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
    # Same positive 8-hex regex create-session.sh + apex-state-context-hook.sh use;
    # excludes -hypothesis.json, -baseline.json, -*-scope.json, etc. by shape.
    [[ "$(basename "$manifest")" =~ ^[0-9a-f]{8}\.json$ ]] || continue
    local matched
    matched=$(python3 -c "
import json, os, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    sys.exit(0)
sid = sys.argv[2]
sess = d.get('session', '')
cc = d.get('cc_session_id')
p2cc = d.get('p2_cc_session_id')
if p2cc == sid:
    print(sess)
elif cc == sid:
    if not p2cc and sess:
        active_dir = os.path.dirname(sys.argv[1])
        plan_candidate = os.path.join(active_dir, sess + '-plan-candidate.json')
        if not os.path.exists(plan_candidate):
            print(sess)
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
  [[ -z "$session" ]] && return 0
  # Wrap cleanup-session.sh (idempotent; fail-silent).
  if [[ -x "$SCRIPT_DIR/cleanup-session.sh" ]]; then
    "$SCRIPT_DIR/cleanup-session.sh" --session "$session" 2>/dev/null || true
  fi
  # Belt-and-suspenders: remove hypothesis.json if consumer failed to clean up.
  rm -f "$APEX_ACTIVE/$session-hypothesis.json" 2>/dev/null || true
}

if [[ $# -gt 0 && -n "${1:-}" ]]; then
  # Manual mode: positional arg is the apex {session} token.
  run_cleanup "$1"
else
  # SessionEnd hook mode: derive token from stdin manifest match.
  if SESSION=$(derive_session_from_stdin); then
    run_cleanup "$SESSION"
  fi
  # No matching manifest -> non-/apex Claude Code session, nothing to clean.
fi

exit 0
