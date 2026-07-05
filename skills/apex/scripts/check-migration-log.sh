#!/usr/bin/env bash
# check-migration-log.sh - pre-handoff backstop for the /apex orchestrator.
#
# The failure it catches: an executor commits a migration FILE but never logs
# its apply command to the session side-effects log. The git merge carries the
# file onto the base branch, but /apex-merge step 4.5 replays ONLY the log - so
# the base DB never runs the migration and silently drifts from the schema the
# committed code expects (executor.md step 4: "a created-but-unlogged migration
# silently never reaches main's DB").
#
# One logged apply command is enough: the canonical apply verbs (`migration:run`,
# `migrate`, `migrate deploy`, `db:migrate`, `alembic upgrade`) apply ALL pending
# migrations, so this checks presence of an apply command, not one-line-per-file.
#
# Run from the worktree root at hand-off, before telling the user to /apex-merge:
#   bash ~/.claude/skills/apex/scripts/check-migration-log.sh
#
# Exit 0: pass (no migrations added vs base, OR an apply command is logged, OR
#         the diff-vs-base could not be computed - best-effort, never blocks on
#         its own inability to check).
# Exit 3: FAIL - migration file(s) committed on this branch with no apply
#         command in the side-effects log. Fix, then re-run.
set -uo pipefail

SESSION=""
BASE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session) SESSION="${2:-}"; shift 2 ;;
    --base)    BASE="${2:-}"; shift 2 ;;
    *) echo "check-migration-log: unknown arg '$1'" >&2; exit 0 ;;
  esac
done

TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "check-migration-log: not in a git worktree - skipping" >&2; exit 0; }
[[ -n "$SESSION" ]] || SESSION="$(basename "$TOP")"
MANIFEST="$TOP/.claude-tmp/apex-active/$SESSION.json"
LOG="$TOP/.claude-tmp/apex-active/$SESSION-side-effects.jsonl"

if [[ -z "$BASE" ]]; then
  if [[ -f "$MANIFEST" ]] && command -v jq >/dev/null 2>&1; then
    BASE="$(jq -r '.base_branch // "main"' "$MANIFEST" 2>/dev/null)"
  fi
  [[ -n "$BASE" && "$BASE" != "null" ]] || BASE="main"
fi

# Files added on this branch vs its merge-base with BASE. If BASE is unknown
# locally, fall back to a direct endpoint diff; if that also fails, skip (exit 0).
MB="$(git merge-base "$BASE" HEAD 2>/dev/null)"
if [[ -n "$MB" ]]; then
  ADDED="$(git diff --name-only --diff-filter=A "$MB" HEAD 2>/dev/null)"
else
  ADDED="$(git diff --name-only --diff-filter=A "$BASE" HEAD 2>/dev/null)" || {
    echo "check-migration-log: cannot diff vs '$BASE' - skipping" >&2; exit 0; }
fi

# Migration-shaped added paths: a `migrations/`, `migration/`, or `migrate/`
# path segment (covers AdonisJS/Knex/Rails/Prisma/Django/TypeORM/Alembic layouts).
MIGRATIONS="$(printf '%s\n' "$ADDED" | grep -E '(^|/)(migrations?|migrate)/' || true)"
if [[ -z "$MIGRATIONS" ]]; then
  echo "check-migration-log: PASS - no migration files added vs $BASE"
  exit 0
fi

# Apply-command presence in the side-effects log.
APPLY=""
if [[ -s "$LOG" ]]; then
  APPLY="$(grep -iE '(migrat|upgrade )' "$LOG" || true)"
fi
if [[ -n "$APPLY" ]]; then
  echo "check-migration-log: PASS - migration(s) added and apply command logged"
  exit 0
fi

echo "check-migration-log: FAIL - migration file(s) committed with no apply command in the side-effects log." >&2
echo "  base: $BASE   session: $SESSION" >&2
echo "  migration files added on this branch:" >&2
printf '    %s\n' $MIGRATIONS >&2
if [[ -s "$LOG" ]]; then
  echo "  side-effects log ($LOG) has no migration-apply line; current contents:" >&2
  sed 's/^/    /' "$LOG" >&2
else
  echo "  side-effects log absent or empty: $LOG" >&2
fi
echo "  Fix: append the verbatim apply command to the log, e.g." >&2
echo "    {\"cmd\":\"cd apps/api && node ace migration:run\",\"ts\":\"<iso8601>\"}" >&2
echo "  (or dispatch an executor to apply+log it), then re-run this check." >&2
exit 3
