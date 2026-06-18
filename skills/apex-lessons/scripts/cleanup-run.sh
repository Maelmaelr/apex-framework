#!/usr/bin/env bash
# Per-run cleanup for /apex-lessons (extract or analyze phase).
# Spec: skills/apex-lessons/extract.md "Step 6: Reflect + Cleanup" /
#       skills/apex-lessons/reflect.md (analyze Reflect + Cleanup phase).
#
# Cleans (idempotent; exit 0 always):
#   - .claude-tmp/lessons-<phase>-active/{run}-*
#   - .claude-tmp/lessons-<phase>-active/{run}.json (manifest)
#   - /tmp/{run}-* (any run-scoped temp files)
#
# Args:
#   --phase extract|analyze   (required)
#   --run <token>             (required; 8-char lowercase hex - mints in init-run.sh)
#   --post-success            (optional; bypasses 60s in-flight mtime guard. Use
#                             only when caller has authoritative knowledge that
#                             the run is complete - e.g. SKILL.md after reflector
#                             returns. Without it, the just-written {run}-summary.md
#                             keeps the guard armed and cleanup is deferred.)
#
# Mirrors skills/admin-apex/scripts/cleanup-run.sh contract for consistency
# with the reflector's snapshot lifetime and the run-state model.

set -uo pipefail

PHASE=""
RUN=""
POST_SUCCESS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)        PHASE="${2:-}"; shift 2 ;;
    --run)          RUN="${2:-}"; shift 2 ;;
    --post-success) POST_SUCCESS=1; shift ;;
    *) echo "cleanup-run.sh: unknown arg: $1" >&2; exit 0 ;;
  esac
done

case "$PHASE" in
  extract|analyze) ;;
  *) echo "cleanup-run.sh: --phase must be 'extract' or 'analyze' (got: ${PHASE:-<empty>})" >&2; exit 0 ;;
esac

[[ -z "$RUN" ]] && { echo "cleanup-run.sh: --run is required" >&2; exit 0; }
[[ "$RUN" =~ ^[0-9a-f]{8}$ ]] || { echo "cleanup-run.sh: invalid run token: $RUN" >&2; exit 0; }

ACTIVE=".claude-tmp/lessons-${PHASE}-active"

warn() { echo "cleanup-run.sh: $*" >&2; }
rm_target() { rm -rf -- "$1" 2>/dev/null || warn "failed: $1"; }

rm_run_glob() {
  local pattern="$1"
  shopt -s nullglob
  # shellcheck disable=SC2206  # pattern is a controlled literal; intentional split+glob.
  local matches=( $pattern )
  shopt -u nullglob
  (( ${#matches[@]} == 0 )) && return 0
  local m
  for m in "${matches[@]}"; do
    rm_target "$m"
  done
}

MANIFEST="$ACTIVE/${RUN}.json"
[[ ! -f "$MANIFEST" ]] && exit 0

if (( POST_SUCCESS == 0 )); then
  NOW=$(date +%s)
  LATEST=0
  shopt -s nullglob
  for f in "$MANIFEST" "$ACTIVE/${RUN}"-*; do
    [[ -e "$f" ]] || continue
    m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
    (( m > LATEST )) && LATEST=$m
  done
  shopt -u nullglob
  if (( LATEST != 0 && NOW - LATEST < 60 )); then
    warn "refusing cleanup: latest mtime $((NOW - LATEST))s ago < 60s (mid-flight)"
    exit 0
  fi
fi

rm_run_glob "$ACTIVE/${RUN}-*"
rm_target "$ACTIVE/${RUN}.json"
rm_run_glob "/tmp/${RUN}-*"

exit 0
