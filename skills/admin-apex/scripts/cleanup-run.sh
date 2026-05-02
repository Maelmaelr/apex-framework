#!/usr/bin/env bash
# Per-run cleanup for admin-apex / apex-improve runs.
# Spec: skills/admin-apex/SKILL.md (task 9 no-commit branch + SessionEnd) +
#       skills/apex-improve/SKILL.md (cross-skill shared workspace).
#
# Cleans (idempotent; exit 0 on partial cleanup with warnings to stderr):
#   - .claude-tmp/admin-apex-active/{run}-* EXCEPT {run}-deferred-findings.json
#     ({run}-deferred-findings.json is apex-improve's session-spanning artifact
#     per skills/apex-improve/SKILL.md "Output of Phase 1" - kept for a future
#     run.)
#   - .claude-tmp/admin-apex-active/{run}.json (the manifest itself)
#   - /tmp/{run}-* (apex-improve hygiene rename target; forward-compat)
#
# Args:
#   --run <token>  (required; 8-char lowercase hex - matches openssl rand -hex 4
#                  per SKILL.md task 1)
#
# Callers:
#   - session-end-hook.sh (manifest cc_session_id match -> per-run cleanup)
#   - admin-apex-finalize.sh (no-commit branch when nothing staged)
#   - evolve.md mid-flight rollback (after git restore)
#
# Exit code: always 0 (idempotent contract; warnings to stderr).

# Intentionally NOT using `set -e`: cleanup is best-effort. A single rm failure
# (permission, race, etc.) must not abort remaining cleanup steps. Per-target
# failures surface to stderr via warn() while the script continues.
set -uo pipefail

ADMIN_ACTIVE=".claude-tmp/admin-apex-active"

RUN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      RUN="${2:-}"
      shift 2
      ;;
    *)
      echo "cleanup-run.sh: unknown arg: $1" >&2
      exit 0
      ;;
  esac
done

if [[ -z "$RUN" ]]; then
  echo "cleanup-run.sh: --run is required" >&2
  exit 0
fi

# Token-shape guard: 8-char lowercase hex (openssl rand -hex 4). Tight match is
# what makes the {run}-* prefix glob safe - mirrors apex/scripts/cleanup-session.sh.
# Reject anything else and exit cleanly to honour the idempotent contract.
if [[ ! "$RUN" =~ ^[0-9a-f]{8}$ ]]; then
  echo "cleanup-run.sh: invalid run token shape: $RUN (expected 8-char lowercase hex)" >&2
  exit 0
fi

warn() {
  echo "cleanup-run.sh: $*" >&2
}

rm_target() {
  local target="$1"
  rm -rf -- "$target" 2>/dev/null || warn "failed to remove: $target"
}

# Glob-expansion remover with deferred-findings exclusion. Enables nullglob
# locally so "no matches" yields an empty array (rather than passing the literal
# pattern to rm). Each match is removed independently via rm_target so a single
# failure doesn't shadow others. Skips {run}-deferred-findings.json
# (apex-improve's session-spanning artifact - kept for a future run).
rm_run_glob() {
  local pattern="$1"
  shopt -s nullglob
  # shellcheck disable=SC2206  # pattern is a controlled literal; intentional split+glob.
  local matches=( $pattern )
  shopt -u nullglob
  # macOS bash 3.2: ${matches[@]} on empty array is unbound under set -u.
  (( ${#matches[@]} == 0 )) && return 0
  local m
  for m in "${matches[@]}"; do
    case "$(basename "$m")" in
      "${RUN}-deferred-findings.json") continue ;;
    esac
    rm_target "$m"
  done
}

# In-flight guard (defense-in-depth against sibling SessionEnd misfire OR eager
# cleanup mid-write). Refuse cleanup when (a) manifest is missing (already
# swept; honour idempotent contract), or (b) the latest mtime among manifest +
# {run}-* artifacts is < 60s old (run actively writing or just-finished).
# Long apply phases keep refreshing artifact mtimes so the guard stays armed;
# legitimate post-completion cleanup at SessionEnd typically sees stale mtimes
# and proceeds. Edge-case crashed runs with recent mtimes are picked up by
# sweep-stale-runs.sh on a later pass once mtime ages out.
MANIFEST="$ADMIN_ACTIVE/${RUN}.json"
if [[ ! -f "$MANIFEST" ]]; then
  exit 0
fi
NOW=$(date +%s)
LATEST=0
shopt -s nullglob
for f in "$MANIFEST" "$ADMIN_ACTIVE/${RUN}"-*; do
  [[ -e "$f" ]] || continue
  # `stat -f %m` (BSD/macOS) -> falls back to `stat -c %Y` (GNU/Linux).
  m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
  (( m > LATEST )) && LATEST=$m
done
shopt -u nullglob
if (( LATEST != 0 && NOW - LATEST < 60 )); then
  warn "refusing cleanup: latest run artifact mtime $((NOW - LATEST))s ago < 60s (run mid-flight)"
  exit 0
fi

# Per-run admin-apex-active artifacts (excluding deferred-findings).
rm_run_glob "$ADMIN_ACTIVE/${RUN}-*"

# Manifest itself (separate target - filename {run}.json, not {run}-*).
rm_target "$ADMIN_ACTIVE/${RUN}.json"

# /tmp/{run}-* prefix sweep (forward-compat for apex-improve's
# /tmp/apex-improve-{run}.txt rename and any other run-keyed /tmp scratch).
rm_run_glob "/tmp/${RUN}-*"

exit 0
