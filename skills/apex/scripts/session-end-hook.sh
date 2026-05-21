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
  # manifests' cc_session_id, echo "<apex-session-token>\t<apex-active-dir>\t<cc-session-id>".
  # Two scan locations (Phase 2 worktree support):
  #   1. $APEX_ACTIVE                              (legacy / pre-migration sessions)
  #   2. <main>/.apex-worktrees/*/.claude-tmp/apex-active/*.json
  #      (worktree-mode sessions; manifest lives inside the worktree)
  # The tab-separated apex-active-dir lets the caller forward --apex-active-dir
  # to cleanup-session.sh so the worktree-resident manifest is reached.
  # The cc_session_id (third field) is the matched stdin session_id, threaded
  # through to cleanup-session.sh as --caller-cc-session so the sibling-wipe
  # guard recognizes the own-session caller without auto-resolve fallback.
  # Non-/apex CC session (no manifest matches) -> nothing to clean, return
  # non-zero so caller skips.
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

  scan_one_dir() {
    local dir="$1"
    [[ -d "$dir" ]] || return 1
    shopt -s nullglob
    for manifest in "$dir"/*.json; do
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
        printf '%s\t%s\t%s' "$matched" "$dir" "$session_id"
        shopt -u nullglob
        return 0
      fi
    done
    shopt -u nullglob
    return 1
  }

  # Scan 1: legacy main APEX_ACTIVE.
  if scan_one_dir "$APEX_ACTIVE"; then
    return 0
  fi

  # Scan 2: worktree-mode subtree. Locate the main worktree's
  # .apex-worktrees dir via the CC project root (CLAUDE_PROJECT_DIR is the
  # main worktree for SessionEnd hooks).
  local main_root="${CLAUDE_PROJECT_DIR:-$PWD}"
  local wt_root="$main_root/.apex-worktrees"
  if [[ -d "$wt_root" ]]; then
    local wt
    shopt -s nullglob
    for wt in "$wt_root"/*/; do
      if scan_one_dir "${wt}.claude-tmp/apex-active"; then
        shopt -u nullglob
        return 0
      fi
    done
    shopt -u nullglob
  fi

  return 1
}

run_cleanup() {
  local session="$1"
  local foreign="${2:-0}"
  local target_active="${3:-$APEX_ACTIVE}"
  local caller_cc="${4:-}"
  [[ -z "$session" ]] && return 0
  # Wrap cleanup-session.sh (idempotent; fail-silent). Trusted callers
  # (own-session: SessionEnd hook + manual-mid-abort) pass --post-success.
  # Foreign caller (cleanup-stale-and-proceed) omits the flag so the guard
  # fires defensively if the classifier got it wrong.
  # Forward the resolved target apex-active dir so cleanup-session.sh agrees
  # on the target directory regardless of its own resolution chain. The
  # third arg lets the SessionEnd path target a worktree-resident apex-active
  # (Phase 2 worktree mode) without rebinding the script-wide APEX_ACTIVE.
  # The fourth arg (caller_cc) is the own-session cc_session_id derived from
  # the SessionEnd stdin event JSON; threading it as --caller-cc-session lets
  # cleanup-session.sh's sibling-wipe guard pass on the own-session path
  # without relying on get-cc-session-id.sh auto-resolution (which can lag
  # the ending CC session and refuse legitimate own-cleanup).
  if [[ -x "$SCRIPT_DIR/cleanup-session.sh" ]]; then
    # Build cc_args inline; bash 3.2 (macOS default) errors on "${arr[@]}"
    # expansion of an empty array under set -u, so guard via the +alt form.
    local cc_flag="" cc_val=""
    if [[ -n "$caller_cc" ]]; then
      cc_flag="--caller-cc-session"
      cc_val="$caller_cc"
    fi
    if (( foreign == 1 )); then
      if [[ -n "$cc_flag" ]]; then
        "$SCRIPT_DIR/cleanup-session.sh" --session "$session" --apex-active-dir "$target_active" "$cc_flag" "$cc_val" 2>/dev/null || true
      else
        "$SCRIPT_DIR/cleanup-session.sh" --session "$session" --apex-active-dir "$target_active" 2>/dev/null || true
      fi
    else
      if [[ -n "$cc_flag" ]]; then
        "$SCRIPT_DIR/cleanup-session.sh" --session "$session" --post-success --apex-active-dir "$target_active" "$cc_flag" "$cc_val" 2>/dev/null || true
      else
        "$SCRIPT_DIR/cleanup-session.sh" --session "$session" --post-success --apex-active-dir "$target_active" 2>/dev/null || true
      fi
    fi
  fi
  # Belt-and-suspenders: remove hypothesis.json if consumer step 15 failed to clean up.
  # Skip on foreign cleanups when the guard refused (manifest still present) so a
  # misclassified live session keeps its hypothesis intact. Phase 2 worktree mode:
  # cleanup-session.sh's worktree-aware branch removes the entire worktree subtree
  # (including hypothesis) atomically when the session was clean + no commits past
  # base; on the keep-worktree branches (commits-past-base OR dirty) the manifest
  # AND hypothesis MUST be preserved for /apex-merge. Either way, when the manifest
  # carried worktree_path, the belt-and-suspenders rm is wrong (no-op in the swept
  # case, harmful in the kept case) - skip it.
  if (( foreign == 1 )) && [[ -f "$target_active/$session.json" ]]; then
    return 0
  fi
  if [[ -f "$target_active/$session.json" ]]; then
    # Manifest still present -> either the live-PID guard refused OR worktree-mode
    # opted to keep everything (commits-past-base / dirty). Check for worktree_path
    # to disambiguate; preserve hypothesis in worktree mode.
    local wt_path
    wt_path=$(python3 -c "
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding='utf-8')).get('worktree_path', ''))
except Exception:
    pass
" "$target_active/$session.json" 2>/dev/null || true)
    if [[ -n "$wt_path" ]]; then
      return 0
    fi
  fi
  rm -f "$target_active/$session-hypothesis.json" 2>/dev/null || true
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
  # Manual mode: positional arg is the apex {session} token. The caller's
  # APEX_ACTIVE resolution applies (manual callers are own-session mid-abort
  # paths that already cd'd into the worktree under APEX_WORKTREE=1). No
  # cc_session_id passed: manual callers either have the live CC (own-session
  # mid-abort -> cleanup-session auto-resolves under --post-success) or are
  # the --foreign cleanup-stale path (which intentionally skips the cc guard).
  run_cleanup "$SESSION_ARG" "$FOREIGN" "$APEX_ACTIVE" ""
else
  # SessionEnd hook mode: derive (session, apex-active-dir, cc_session_id)
  # from stdin manifest match. The dir distinguishes legacy (= $APEX_ACTIVE)
  # from worktree-mode (= <main>/.apex-worktrees/<sess>/.claude-tmp/apex-active);
  # cc_session_id threads to cleanup-session.sh's sibling-wipe guard as the
  # own-session signal (the ending CC session's id).
  if MATCHED=$(derive_session_from_stdin); then
    SESSION="${MATCHED%%	*}"
    REST="${MATCHED#*	}"
    TARGET_ACTIVE="${REST%%	*}"
    CALLER_CC="${REST#*	}"
    [[ -z "$TARGET_ACTIVE" ]] && TARGET_ACTIVE="$APEX_ACTIVE"
    run_cleanup "$SESSION" 0 "$TARGET_ACTIVE" "$CALLER_CC"
  fi
  # No matching manifest -> non-/apex CC session; nothing to clean.
fi

exit 0
