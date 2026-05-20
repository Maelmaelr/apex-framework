#!/usr/bin/env bash
# Step 14: idempotent session cleanup.
# Spec: apex-core.md step 14 + Failure handling / "cleanup-session.sh".
#
# Cleans (idempotent; exit 0 on partial cleanup with warnings to stderr):
#   - .claude-tmp/apex-active/{session}.json     (manifest)
#   - .claude-tmp/apex-active/{session}-*        (every sibling artifact: main-scope.json,
#                                                 scopes/, screened.json, lesson-screened.json,
#                                                 tier.json, traces/, fix-attempts.json,
#                                                 baseline.json, verify-errors.txt, tasks.json
#                                                 -- the {session}-tasks.json plan written by
#                                                 the orchestrator at step 8.2 as input to
#                                                 validate-disjoint-scopes.py is intentionally
#                                                 covered by the glob -- and any future suffix)
#
# Intentionally NOT cleaned (consumed by step 15):
#   - .claude-tmp/apex-active/{session}-hypothesis.json
#     session-end-hook.sh removes it as belt-and-suspenders fallback when consumer fails.
#
# Glob-based sweep (vs. a static suffix list) ensures new {session}-* artifact
# kinds added by future apex evolution are auto-covered without re-editing this
# script. Reflector e953029f: ee81f7b0-tasks.json lingered until the 24h orphan
# sweep because the static list omitted it.
#
# Args:
#   --session <token>       (required; 8-char lowercase hex per Conventions / Session token format)
#   --post-success          (optional; bypasses the live-PID guard. Reserved for callers
#                            with authoritative knowledge that cleanup is safe -- step
#                            14 success path, mid-/apex abort paths, SessionEnd of the
#                            OWN session. Without this flag the guard fires when
#                            manifest.pid is alive AND comm=claude, and refuses cleanup
#                            as defense against sibling cleanup-stale-and-proceed
#                            misclassification.)
#   --apex-active-dir <abs> (optional; absolute path to the .claude-tmp/apex-active
#                            directory. Highest-priority APEX_ACTIVE resolution; below
#                            it: APEX_ACTIVE_DIR env, CLAUDE_PROJECT_DIR (CC hooks set
#                            this), $PWD fallback. Background-reflector subagents and
#                            SessionEnd hooks may not inherit project CWD, in which case
#                            a bare ".claude-tmp/apex-active" silently no-ops (rm -rf on
#                            a missing path returns 0). Reflector e0f5b897: session
#                            0cdd8999 left manifest + 4 siblings under
#                            /Users/mael/Dev/flowctory/.claude-tmp/apex-active because the
#                            reflector ran cleanup from a CWD without that subtree.)
#   --caller-cc-session <id> (optional; the invoking CC session's cc_session_id,
#                            from get-cc-session-id.sh. When provided and the
#                            target manifest carries a cc_session_id that DIFFERS,
#                            cleanup is refused -- even under --post-success --
#                            because a cross-CC-session cleanup is never the
#                            trusted own-session path. This is the cc_session_id
#                            sibling-wipe guard: reflector e0259412 saw a
#                            sibling-session SessionEnd delete a live session's
#                            manifest/baseline/scope/hypothesis/tier mid-run
#                            because the PID guard is bypassed by --post-success.
#                            Absent flag, or manifest with no cc_session_id ->
#                            prior behaviour (PID guard remains the protection;
#                            truly-dead orphans still drained by sweep-stale-runs).)
#
# Exit code: always 0 (idempotent contract; warnings to stderr).

# Intentionally NOT using `set -e`: cleanup is best-effort. A single rm failure
# (permission, race, etc.) must not abort remaining cleanup steps.
set -uo pipefail

SESSION=""
POST_SUCCESS=0
APEX_ACTIVE_OVERRIDE=""
CALLER_CC_SESSION=""
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
    --apex-active-dir)
      APEX_ACTIVE_OVERRIDE="${2:-}"
      shift 2
      ;;
    --caller-cc-session)
      CALLER_CC_SESSION="${2:-}"
      shift 2
      ;;
    *)
      echo "cleanup-session.sh: unknown arg: $1" >&2
      exit 0
      ;;
  esac
done

# Resolve APEX_ACTIVE absolutely. Priority chain (first non-empty wins):
#   1. --apex-active-dir <abs> flag
#   2. APEX_ACTIVE_DIR env
#   3. $CLAUDE_PROJECT_DIR/.claude-tmp/apex-active  (CC hooks always have this)
#   4. $PWD/.claude-tmp/apex-active                  (orchestrator inline calls)
# A bare relative path was the prior behaviour and silently failed when caller
# CWD diverged from project root. The fallbacks preserve back-compat for
# callers that DID run from project root.
if [[ -n "$APEX_ACTIVE_OVERRIDE" ]]; then
  APEX_ACTIVE="$APEX_ACTIVE_OVERRIDE"
elif [[ -n "${APEX_ACTIVE_DIR:-}" ]]; then
  APEX_ACTIVE="$APEX_ACTIVE_DIR"
elif [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
  APEX_ACTIVE="$CLAUDE_PROJECT_DIR/.claude-tmp/apex-active"
else
  APEX_ACTIVE="$PWD/.claude-tmp/apex-active"
fi

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

# cc_session_id sibling-wipe guard. Applies even under --post-success: a
# cleanup whose caller cc_session_id differs from the target manifest's
# cc_session_id is, by definition, one CC session reaping another's apex
# session. The PID guard does not catch this (--post-success bypasses it,
# and SessionEnd legitimately uses --post-success for its OWN session).
# Refuse + warn; the truly-dead-orphan path is sweep-stale-runs.sh, which
# is PID-based and does not pass --caller-cc-session. When --caller-cc-session
# is absent, the script best-effort auto-resolves the caller's cc_session_id
# via get-cc-session-id.sh (env-then-jsonl resolver) so every cleanup call is
# protected by default. Reflector 0208a2d7: concurrent-sibling cleanup-session
# deleted this session's full artifact set (manifest+hypothesis+traces+
# dispatch-summary) before step 13/15 consumers ran; the cc_session_id guard
# closes that race without forcing every callsite to thread --caller-cc-session.
if [[ -z "$CALLER_CC_SESSION" ]]; then
  if [[ -x "$HOME/.claude/skills/apex/scripts/get-cc-session-id.sh" ]]; then
    CALLER_CC_SESSION=$(bash "$HOME/.claude/skills/apex/scripts/get-cc-session-id.sh" 2>/dev/null || true)
  fi
fi
if [[ -n "$CALLER_CC_SESSION" ]]; then
  MF_CC="$APEX_ACTIVE/${SESSION}.json"
  if [[ -f "$MF_CC" ]]; then
    manifest_cc=$(python3 -c "
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding='utf-8')).get('cc_session_id', ''))
except Exception:
    pass
" "$MF_CC" 2>/dev/null || true)
    if [[ -n "$manifest_cc" && "$manifest_cc" != "$CALLER_CC_SESSION" ]]; then
      warn "refusing cleanup: session $SESSION belongs to cc_session_id=$manifest_cc, caller is cc_session_id=$CALLER_CC_SESSION (sibling-wipe guard); manifest preserved"
      exit 0
    fi
  fi
fi

rm_target() {
  local target="$1"
  rm -rf -- "$target" 2>/dev/null || warn "failed to remove: $target"
}

# Pre-sweep diagnostic: silent no-op (rm -rf on a missing path returns 0) is
# the most common failure mode when APEX_ACTIVE resolution lands on the wrong
# directory. Warn on stderr when neither manifest nor any {session}-* sibling
# exists at the resolved location, so reflector-errors.log / hook stderr
# captures the symptom instead of silently leaving artifacts behind.
shopt -s nullglob
_siblings=("$APEX_ACTIVE/${SESSION}-"*)
shopt -u nullglob
if [[ ! -f "$APEX_ACTIVE/${SESSION}.json" && ${#_siblings[@]} -eq 0 ]]; then
  warn "no artifacts under ${APEX_ACTIVE} for session ${SESSION} (cwd=${PWD}); APEX_ACTIVE may be misresolved"
fi

# Per-session cleanup. Each target removed independently so a single failure
# does not shadow others. Sweeps the manifest plus every {session}-* sibling,
# excluding {session}-hypothesis.json (consumed by step 15; session-end-hook.sh
# removes it as belt-and-suspenders fallback). Glob, not enumeration, so future
# {session}-* artifact kinds (e.g., {session}-tasks.json) are auto-covered.
rm_target "$APEX_ACTIVE/${SESSION}.json"
shopt -s nullglob
for sibling in "$APEX_ACTIVE/${SESSION}-"*; do
  [[ "$sibling" == "$APEX_ACTIVE/${SESSION}-hypothesis.json" ]] && continue
  rm_target "$sibling"
done
shopt -u nullglob

exit 0
