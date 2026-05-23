#!/usr/bin/env bash
# SessionEnd hook + manual entry point (worktree-only).
# Spec: apex-core.md Failure handling / "session-end-hook.sh";
#       tmp/worktree-migration-spec.md Phase 4b "SessionEnd changes".
#
# Wraps cleanup-session.sh. Hypothesis is preserved or atomically swept by
# cleanup-session.sh's worktree-remove (worktree-resident artifact); the legacy
# belt-and-suspenders `rm {session}-hypothesis.json` is gone with the shared
# .claude-tmp/apex-active/ era.
#
# Invocation modes:
#   1. SessionEnd (no positional arg):
#        - Read session_id from hook stdin event JSON
#        - Match against worktree-resident manifests under
#          <main>/.apex-worktrees/*/.claude-tmp/apex-active/*.json
#        - Derive apex {session} token, run cleanup-session.sh against the
#          worktree-resident apex-active directory
#   2. Manual mode (positional arg = apex {session} token):
#        - Trusted own-session caller (mid-/apex abort: step 1 / 6
#          cascade-empty / 10 verify cap-3 / unexpected error). Target the
#          supplied token directly.
#
# Runs on success completion AND on abort / crash. Idempotent.
# Exit code: 0 always (treat as pass for SessionEnd hook contract).
# Stdout: forwards cleanup-session.sh stdout verbatim - the main-worktree path
#         on every branch where it resolves. Manual-mode callers (apex mid-flow
#         abort) capture this and `cd` there to leave the (possibly removed)
#         worktree subdirectory. SessionEnd hook mode ignores stdout (CC session
#         is ending). See cleanup-session.sh header for the contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Main-worktree resolution. CC sets CLAUDE_PROJECT_DIR for hooks; manual
# callers inherit project root via $PWD. The worktree-resident scan looks at
# <main>/.apex-worktrees/*/.claude-tmp/apex-active/.
MAIN_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"

derive_session_from_stdin() {
  # Read hook event JSON from stdin, extract session_id, match against
  # worktree-resident manifests, echo "<apex-session-token>\t<apex-active-dir>".
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

  local wt_root="$MAIN_ROOT/.apex-worktrees"
  [[ -d "$wt_root" ]] || return 1

  local wt dir
  shopt -s nullglob
  for wt in "$wt_root"/*/; do
    dir="${wt}.claude-tmp/apex-active"
    [[ -d "$dir" ]] || continue
    for manifest in "$dir"/*.json; do
      # 8-hex.json filename guard: excludes -hypothesis.json, -*-scope.json,
      # etc. by shape.
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
        printf '%s\t%s' "$matched" "$dir"
        shopt -u nullglob
        return 0
      fi
    done
  done
  shopt -u nullglob
  return 1
}

sweep_orphan_worktrees() {
  # Sweep .apex-worktrees/<token>/ dirs missing their matching
  # .claude-tmp/apex-active/<token>.json manifest - the crash-orphan case
  # (manifest already wiped or never written, but worktree directory survived).
  # Without this, the next /apex create-session re-encounters the orphan and
  # blocks on user interaction; with the sweep, SessionEnd cleans it for free
  # on any subsequent CC session end (reflector b623b673: orphan worktree
  # 41eac60c required manual cleanup at step-2 create-session.sh).
  local wt_root="$MAIN_ROOT/.apex-worktrees"
  [[ -d "$wt_root" ]] || return 0
  local wt token manifest
  shopt -s nullglob
  for wt in "$wt_root"/*/; do
    token=$(basename "$wt")
    # 8-hex token guard: refuse to touch non-apex dirs that may have leaked in.
    [[ "$token" =~ ^[0-9a-f]{8}$ ]] || continue
    manifest="${wt}.claude-tmp/apex-active/${token}.json"
    [[ -f "$manifest" ]] && continue
    # Orphan: cleanup-session.sh would skip without a manifest. Remove inline.
    git -C "$MAIN_ROOT" worktree remove --force "$wt" 2>/dev/null || true
    git -C "$MAIN_ROOT" worktree prune 2>/dev/null || true
    git -C "$MAIN_ROOT" branch -D "apex/$token" 2>/dev/null || true
  done
  shopt -u nullglob
}

run_cleanup() {
  # Forwards cleanup-session.sh's stdout (the main-worktree path on every
  # branch where it resolves) to our own stdout so manual-mode callers (apex
  # mid-flow abort, e.g., step 1/2/6/8/10 cascade) can capture and `cd` out
  # of the (possibly removed) worktree. SessionEnd-hook callers (CC harness)
  # do not consume stdout - the inherited CC session is ending anyway - but
  # forwarding is harmless and keeps the hook contract symmetric with manual
  # mode (user-driven 35679220).
  local session="$1"
  local target_active="${2:-}"
  [[ -z "$session" ]] && return 0
  if [[ ! -x "$SCRIPT_DIR/cleanup-session.sh" ]]; then
    return 0
  fi
  if [[ -n "$target_active" ]]; then
    "$SCRIPT_DIR/cleanup-session.sh" --session "$session" --apex-active-dir "$target_active" 2>/dev/null || true
  else
    "$SCRIPT_DIR/cleanup-session.sh" --session "$session" 2>/dev/null || true
  fi
}

# Parse args. Positional = manual mode session token.
SESSION_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --)        shift ;;
    *)
      if [[ -z "$SESSION_ARG" ]]; then
        SESSION_ARG="$1"
      fi
      shift
      ;;
  esac
done

if [[ -n "$SESSION_ARG" ]]; then
  # Manual mode: the caller (own-session mid-abort) has already cd'd into the
  # worktree; cleanup-session.sh resolves apex-active via $PWD when no dir is
  # forwarded.
  run_cleanup "$SESSION_ARG" ""
else
  # SessionEnd hook mode: locate worktree-resident manifest by cc_session_id.
  if MATCHED=$(derive_session_from_stdin); then
    SESSION="${MATCHED%%	*}"
    TARGET_ACTIVE="${MATCHED#*	}"
    run_cleanup "$SESSION" "$TARGET_ACTIVE"
  fi
  # Either branch above: also sweep orphan worktrees (manifest-less dirs from
  # crashed /apex sessions). Cheap + idempotent; runs every SessionEnd.
  sweep_orphan_worktrees
fi

exit 0
