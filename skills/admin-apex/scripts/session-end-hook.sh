#!/usr/bin/env bash
# SessionEnd hook for admin-apex / apex-improve / apex-merge runs.
# Spec: skills/admin-apex/SKILL.md (per-run lifecycle bound to cc_session_id) +
#       skills/apex-improve/SKILL.md "Step 1: Mint run + manifest" +
#       skills/apex-merge/SKILL.md step 7 (Self-reflect cleanup fallback).
#
# Reads SessionEnd hook event JSON from stdin, extracts session_id, iterates
# .claude-tmp/admin-apex-active/*.json manifests, invokes cleanup-run.sh for
# each manifest whose cc_session_id matches the ending session. Then iterates
# .claude-tmp/apex-merge-active/*.json manifests for the same session_id and
# rm-sweeps the matching run's artifacts inline (apex-merge owns one ACTIVE
# dir; no cleanup-run.sh analog needed).
#
# Manifests not produced by admin-apex / apex-improve / apex-merge (no
# cc_session_id field, or unparseable JSON) are skipped silently - the hook is
# forgiving so that a malformed sibling artifact never blocks cleanup of valid
# runs.
#
# Runs at SessionEnd ONLY (no manual mode - per-run cleanup callers should use
# cleanup-run.sh directly).
#
# Exit code: 0 (always; SessionEnd hook contract).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Anchored at framework root regardless of caller cwd. SessionEnd hooks fire with
# whatever cwd Claude Code happens to have; a relative path would scan the user's
# current project (or anywhere they cd'd to last) instead of the framework root.
# APEX_ADMIN_ACTIVE_DIR override is reserved for test fixtures (test-apex-scripts.sh
# sets it to a temp dir to sandbox cleanup); production callers must NOT set it.
ADMIN_ACTIVE="${APEX_ADMIN_ACTIVE_DIR:-$HOME/.claude/.claude-tmp/admin-apex-active}"
APEX_MERGE_ACTIVE="${APEX_MERGE_ACTIVE_DIR:-$HOME/.claude/.claude-tmp/apex-merge-active}"

# Read hook event JSON from stdin and echo session_id (empty on parse failure).
read_session_id_from_stdin() {
  local stdin_json
  stdin_json=$(cat 2>/dev/null || true)
  [[ -z "$stdin_json" ]] && return 1
  printf '%s' "$stdin_json" | python3 -c "
import json, sys
try:
    print(json.load(sys.stdin).get('session_id', ''))
except Exception:
    pass
" 2>/dev/null || true
}

cleanup_matching_runs() {
  local session_id="$1"
  [[ -z "$session_id" ]] && return 0
  [[ -d "$ADMIN_ACTIVE" ]] || return 0

  shopt -s nullglob
  local manifests=( "$ADMIN_ACTIVE"/*.json )
  shopt -u nullglob
  (( ${#manifests[@]} == 0 )) && return 0

  local manifest run
  for manifest in "${manifests[@]}"; do
    [[ -f "$manifest" ]] || continue
    # Skip non-manifest artifacts (deferred-findings, evolve-plan, applied-ops,
    # findings, drift-report, inventory). Manifests are {run}.json - any name
    # containing a hyphen is a sibling artifact and is left for cleanup-run.sh
    # to sweep based on its own manifest match.
    case "$(basename "$manifest")" in
      *-*) continue ;;
    esac
    # Parse manifest, match cc_session_id, echo run on hit.
    run=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    sys.exit(0)
if d.get('cc_session_id') == sys.argv[2]:
    print(d.get('run', ''))
" "$manifest" "$session_id" 2>/dev/null || true)
    if [[ -n "$run" ]]; then
      if [[ -x "$SCRIPT_DIR/cleanup-run.sh" ]]; then
        "$SCRIPT_DIR/cleanup-run.sh" --run "$run" 2>/dev/null || true
      fi
    fi
  done
}

# Sweep .claude-tmp/apex-merge-active/{run}.json manifests matching the ending
# CC session. apex-merge has no cleanup-run.sh analog (single ACTIVE dir, no
# deferred artifacts to preserve) - inline rm of {run}* is sufficient.
cleanup_matching_apex_merge_runs() {
  local session_id="$1"
  [[ -z "$session_id" ]] && return 0
  [[ -d "$APEX_MERGE_ACTIVE" ]] || return 0

  shopt -s nullglob
  local manifests=( "$APEX_MERGE_ACTIVE"/*.json )
  shopt -u nullglob
  (( ${#manifests[@]} == 0 )) && return 0

  local manifest run
  for manifest in "${manifests[@]}"; do
    [[ -f "$manifest" ]] || continue
    case "$(basename "$manifest")" in
      *-*) continue ;;
    esac
    run=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    sys.exit(0)
if d.get('cc_session_id') == sys.argv[2]:
    print(d.get('run', ''))
" "$manifest" "$session_id" 2>/dev/null || true)
    if [[ -n "$run" ]]; then
      rm -f "$APEX_MERGE_ACTIVE/${run}"* 2>/dev/null || true
    fi
  done
}

if SESSION_ID=$(read_session_id_from_stdin); then
  cleanup_matching_runs "$SESSION_ID"
  cleanup_matching_apex_merge_runs "$SESSION_ID"
fi
# No matching manifest -> non-/admin-apex / non-/apex-merge CC session, nothing to clean.

exit 0
