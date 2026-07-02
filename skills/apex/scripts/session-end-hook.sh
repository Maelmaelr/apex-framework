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
#        - Then sweep stale sibling worktrees (manifest-less crash orphans +
#          dead-owner fully-merged leftovers) via sweep_stale_worktrees
#   2. Manual mode (positional arg = apex {session} token):
#        - Trusted own-session caller (mid-/apex abort: step 6
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

# True iff PID is a live process whose comm basename is "claude" (recycled-PID
# safe). Mirrors sweep-stale-runs.sh owner classification.
pid_is_live_claude() {
  local pid="$1"
  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  local comm_base
  comm_base="$(basename "$(ps -o comm= -p "$pid" 2>/dev/null || true)" 2>/dev/null || true)"
  [[ "$comm_base" == "claude" ]]
}

# Read the manifest's recorded owner pid (empty on parse failure / absent key).
manifest_pid() {
  python3 -c "
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding='utf-8')).get('pid', ''))
except Exception:
    pass
" "$1" 2>/dev/null || true
}

sweep_stale_worktrees() {
  # Sweep two classes of leftover .apex-worktrees/<token>/ dirs at SessionEnd:
  #   (a) manifest-LESS dirs - the crash-orphan case (manifest already wiped or
  #       never written, but the worktree directory survived). Removed inline;
  #       cleanup-session.sh would no-op without a manifest. Without this,
  #       crash-orphan worktree dirs accumulate under .apex-worktrees/.
  #   (b) manifest-PRESENT dirs whose owning session is no longer live (recorded
  #       pid dead OR recycled to a non-claude process). Re-run the
  #       cleanup-session.sh keep/remove decision so a fully-merged worktree
  #       (clean + no commits past base) that no other codepath reaps gets
  #       collected - cleanup-session.sh runs only ONCE, at the owning session's
  #       own step-13/14, so a branch integrated outside /apex-merge (or whose
  #       /apex-merge step-5 cleanup was interrupted) otherwise lingers forever
  #       with its manifest intact, invisible to the (a) orphan branch. The
  #       decision stays in cleanup-session.sh: merged-clean -> remove; unmerged
  #       (commits past base) / dirty -> keep + warn. A live claude owner = an
  #       active sibling /apex session; leave it untouched.
  local wt_root="$MAIN_ROOT/.apex-worktrees"
  [[ -d "$wt_root" ]] || return 0
  local wt token manifest owner_pid
  shopt -s nullglob
  for wt in "$wt_root"/*/; do
    token=$(basename "$wt")
    # 8-hex token guard: refuse to touch non-apex dirs that may have leaked in.
    [[ "$token" =~ ^[0-9a-f]{8}$ ]] || continue
    manifest="${wt}.claude-tmp/apex-active/${token}.json"
    if [[ -f "$manifest" ]]; then
      owner_pid="$(manifest_pid "$manifest")"
      pid_is_live_claude "$owner_pid" && continue
      run_cleanup "$token" "${wt}.claude-tmp/apex-active"
      continue
    fi
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
  # mid-flow abort, e.g., step 6/8/10 cascade) can capture and `cd` out
  # of the (possibly removed) worktree. SessionEnd-hook callers (CC harness)
  # do not consume stdout - the inherited CC session is ending anyway - but
  # forwarding is harmless and keeps the hook contract symmetric with manual
  # mode.
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
  # Either branch above: also sweep stale worktrees - manifest-less crash
  # orphans AND manifest-present dirs whose owning session is dead and whose
  # branch is fully merged (clean + no commits past base). Cheap + idempotent;
  # runs every SessionEnd.
  sweep_stale_worktrees
  # Defense-in-depth orphan-artifact reap. Per-worktree isolation keeps the MAIN
  # worktree's apex-active empty by construction, so the hot path historically ran
  # no orphan sweep. But a partial cleanup-session.sh worktree-remove (lock / race)
  # or a stray main-anchored {session}-* write can still strand artifacts whose
  # manifest is already gone. sweep-orphan-artifacts.sh only reaps manifest-absent
  # {token}-* siblings older than --age-hours, so a live session (manifest present)
  # and an in-flight writer (<24h) are never touched; deferred-findings are exempt.
  if [[ -x "$SCRIPT_DIR/sweep-orphan-artifacts.sh" ]]; then
    "$SCRIPT_DIR/sweep-orphan-artifacts.sh" \
      --dir "$MAIN_ROOT/.claude-tmp/apex-active" --age-hours 24 2>/dev/null || true
  fi
fi

exit 0
