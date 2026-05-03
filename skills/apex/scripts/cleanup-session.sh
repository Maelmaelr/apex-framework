#!/usr/bin/env bash
# p1.5 / p2.6: idempotent session cleanup.
# Spec: apex-core.md p1.5 / p2.6 + Failure handling / "cleanup-session.sh".
#
# Cleans (idempotent; exit 0 on partial cleanup with warnings to stderr):
#   - .claude-tmp/scout/*{session}*                            (all session-keyed scout artifacts)
#   - .claude-tmp/apex-active/{session}-*-scope.json           (main + teammate scopes)
#   - .claude-tmp/apex-active/{session}-scopes/                (all scope-pointer files)
#   - .claude-tmp/apex-active/{session}-plan-candidate.json    (planner draft consumed by validate-disjoint-scopes.py)
#   - .claude-tmp/apex-active/{session}-*-task.md              (per-teammate task descriptions)
#   - .claude-tmp/apex-active/{session}-traces/
#   - .claude-tmp/apex-active/{session}.json                   (manifest)
#   - .claude-tmp/apex-active/{session}-fix-attempts-*.json    (all contexts)
#   - .claude-tmp/apex-active/{session}-verify-rerun.json
#   - .claude-tmp/apex-active/{session}-baseline.json
#   - .claude-tmp/apex-active/{session}-verify-errors.txt
#   - /tmp/{session}-*                                         (reflector snapshots etc.)
#
# Intentionally NOT cleaned (consumed downstream by p1.6 / p2.7):
#   - .claude-tmp/apex-active/{session}-hypothesis.json
#     session-end-hook.sh removes it as belt-and-suspenders fallback when consumer fails.
#
# Args:
#   --session <token>  (required; 8-char lowercase hex per Conventions / Session token format)
#
# Exit code: always 0 (idempotent contract; warnings to stderr).

# Intentionally NOT using `set -e`: cleanup is best-effort. A single rm failure
# (permission, race, etc.) must not abort remaining cleanup steps. Per-target
# failures surface to stderr via warn() while the script continues.
set -uo pipefail

APEX_ACTIVE=".claude-tmp/apex-active"
SCOUT_DIR=".claude-tmp/scout"

SESSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)
      SESSION="${2:-}"
      shift 2
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

# Token-shape guard: 8-char lowercase hex. The tight match is what makes the
# *{session}* substring glob in $SCOUT_DIR safe (per Conventions / Session token
# format - "tight enough that cleanup glob *{session}* cannot substring-match
# unrelated files"). Reject anything else and exit cleanly to honour the
# idempotent contract.
if [[ ! "$SESSION" =~ ^[0-9a-f]{8}$ ]]; then
  echo "cleanup-session.sh: invalid session token shape: $SESSION (expected 8-char lowercase hex)" >&2
  exit 0
fi

warn() {
  echo "cleanup-session.sh: $*" >&2
}

# Live-session guard. Refuse cleanup if the manifest still exists AND its PID
# is alive AND `ps -o comm` matches "claude" - the same active-classification
# create-session.sh uses. Defends against any caller path (manual mode,
# stdin-derived SessionEnd, cleanup-stale-and-proceed misclassification) that
# would wipe a mid-run session's manifest/scope/baseline. Mirrors the in-flight
# mtime guard in admin-apex/scripts/cleanup-run.sh.
APEX_ACTIVE_MANIFEST="$APEX_ACTIVE/${SESSION}.json"
if [[ -f "$APEX_ACTIVE_MANIFEST" ]]; then
  manifest_pid=$(python3 -c "
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding='utf-8')).get('pid', ''))
except Exception:
    pass
" "$APEX_ACTIVE_MANIFEST" 2>/dev/null || true)
  if [[ -n "$manifest_pid" && "$manifest_pid" =~ ^[0-9]+$ ]] && kill -0 "$manifest_pid" 2>/dev/null; then
    comm_base="$(basename "$(ps -o comm= -p "$manifest_pid" 2>/dev/null || true)" 2>/dev/null || true)"
    if [[ "$comm_base" == "claude" ]]; then
      warn "refusing cleanup: session $SESSION pid=$manifest_pid is live (comm=claude); manifest preserved"
      exit 0
    fi
  fi
fi

# Best-effort remove of a single literal path. Silences rm's own stderr (the
# warn message we emit on failure is enough) and converts any non-zero exit
# into a stderr warning so the script keeps going.
rm_target() {
  local target="$1"
  rm -rf -- "$target" 2>/dev/null || warn "failed to remove: $target"
}

# Glob-expansion remover. Enables nullglob locally so "no matches" yields an
# empty array (rather than passing the literal pattern to rm). Each match is
# removed independently via rm_target so a single failure doesn't shadow others.
rm_glob() {
  local pattern="$1"
  shopt -s nullglob
  # shellcheck disable=SC2206  # pattern is a controlled literal; intentional split+glob.
  local matches=( $pattern )
  shopt -u nullglob
  # macOS ships bash 3.2 where ${matches[@]} on an empty array is "unbound" under
  # `set -u`. Explicit length guard keeps idempotent re-runs (zero matches) at exit 0.
  (( ${#matches[@]} == 0 )) && return 0
  local m
  for m in "${matches[@]}"; do
    rm_target "$m"
  done
}

# --- Cleanup (declaration order matches the apex-core.md p1.5 / p2.6 lists) ---

# Scout artifacts: substring-match glob covers prefix-then-session filenames
# (findings-{session}.json, screen-plan-{session}.json, screened/preflight/
# rescout/claim-review[-resolved]-{session}.json).
rm_glob "$SCOUT_DIR/*${SESSION}*"

# Scope files: catches {session}-main-scope.json and every {session}-{teammate-id}-scope.json.
# Hypothesis ({session}-hypothesis.json) does not match this glob (no -scope.json suffix).
# IMPORTANT: keep `*` INSIDE the double quotes so it stays literal in the function arg
# - call-site glob expansion would split matches across positional args and rm_glob only reads $1.
rm_glob "$APEX_ACTIVE/${SESSION}-*-scope.json"

# Scope-pointer dir wholesale: covers main, p2 (post-context-clear), and every
# teammate pointer file written under {session}-scopes/.
rm_target "$APEX_ACTIVE/${SESSION}-scopes"

# Planner draft: written at p2.0b before ExitPlanMode, consumed by
# validate-disjoint-scopes.py. Never mentioned in scope-glob (no -scope.json
# suffix) so it needs an explicit single-rm target.
rm_target "$APEX_ACTIVE/${SESSION}-plan-candidate.json"

# Per-teammate task descriptions. No-op in path-1 sessions (none written);
# included for parity with the shared script per spec.
rm_glob "$APEX_ACTIVE/${SESSION}-*-task.md"

# Trace tree wholesale: entryflow/, p1/, p2/ subtrees and any future phase dir.
rm_target "$APEX_ACTIVE/${SESSION}-traces"

# Session manifest itself. Removing this last-ish keeps stale concurrency
# detection coherent if a sibling /apex scans mid-cleanup (the manifest is the
# concurrency anchor; pre-removed scope/trace files do not affect the check).
rm_target "$APEX_ACTIVE/${SESSION}.json"

# Fix-attempt counters: covers -fix-attempts-main.json (Path 1 p1.2) and
# -fix-attempts-p2.json (central Path 2 p2.3). Wildcard suffix is forward-compat.
rm_glob "$APEX_ACTIVE/${SESSION}-fix-attempts-*.json"

rm_target "$APEX_ACTIVE/${SESSION}-verify-rerun.json"
rm_target "$APEX_ACTIVE/${SESSION}-baseline.json"
rm_target "$APEX_ACTIVE/${SESSION}-verify-errors.txt"

# /tmp reflector snapshots ({session}-entryflow-snapshot.txt, {session}-p1-snapshot.txt,
# {session}-p2-snapshot.txt) plus any other session-keyed /tmp artifact. Prefix match
# (not substring) - the 8-hex token is unique enough that prefix is safe and tighter.
rm_glob "/tmp/${SESSION}-*"

exit 0
