#!/usr/bin/env bash
# Step 14 / 13 session cleanup (worktree-only).
# Spec: apex-core.md step 14 / Failure handling; tmp/worktree-migration-spec.md
#       Phase 4b "SessionEnd changes".
#
# Post-Phase-4 every apex session lives in its own git worktree at
# <main>/.apex-worktrees/<session>/ on branch apex/<session>. The cleanup
# decision is at branch level (read the manifest, fork on worktree state):
#   - clean working tree + no commits past base_branch
#     -> git worktree remove --force + git branch -D
#        (empty session: no integration work to preserve)
#   - clean + commits past base
#     -> keep everything, warn (awaiting /apex-merge integration)
#   - dirty working tree
#     -> keep everything, warn (user owns the dirty state)
#
# Worktree-removal sweeps all inner artifacts atomically: manifest, traces,
# hypothesis, dispatch-summary, AND the executor side-effects log at
# <worktree>/.claude-tmp/apex-active/<session>-side-effects.jsonl (logged by
# step 8 state-mutating commands; replayed by apex-merge step 4.5 BEFORE the
# branch's worktree is removed at apex-merge step 5). No separate cleanup
# rule needed for side-effects.jsonl - the worktree-remove path covers it
# (reflector 742e1387).
#
# Args:
#   --session <token>       required, 8-char lowercase hex
#   --apex-active-dir <abs> optional, absolute path to .claude-tmp/apex-active/
#                           (override; otherwise APEX_ACTIVE_DIR env >
#                           $CLAUDE_PROJECT_DIR/.claude-tmp/apex-active >
#                           $PWD/.claude-tmp/apex-active).
#
# Exit code: always 0 (idempotent contract; warnings to stderr).
#
# Stdout: on every branch where worktree_path resolves (worktree-remove +
#         dirty-keep + commits-keep), prints the absolute path of the main
#         worktree on the last line. Callers (apex orchestrator step 13/14,
#         session-end-hook.sh manual mode) capture this and `cd` there so the
#         shell leaves the (possibly removed) worktree subdirectory and is
#         back on the main worktree / base branch (user-driven 35679220).
#         Derived from manifest's worktree_path via dirname-twice (no git
#         dependency - works even when the worktree subtree is already gone).
#         Early-exit branches (manifest missing, malformed token, worktree_path
#         missing) print nothing - caller falls back to its own MAIN resolution.

# Best-effort cleanup: do not `set -e`, a single failure must not abort the rest.
set -uo pipefail

SESSION=""
APEX_ACTIVE_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)            SESSION="${2:-}"; shift 2 ;;
    --apex-active-dir)    APEX_ACTIVE_OVERRIDE="${2:-}"; shift 2 ;;
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
if [[ ! "$SESSION" =~ ^[0-9a-f]{8}$ ]]; then
  echo "cleanup-session.sh: invalid session token shape: $SESSION (expected 8-char lowercase hex)" >&2
  exit 0
fi

if [[ -n "$APEX_ACTIVE_OVERRIDE" ]]; then
  APEX_ACTIVE="$APEX_ACTIVE_OVERRIDE"
elif [[ -n "${APEX_ACTIVE_DIR:-}" ]]; then
  APEX_ACTIVE="$APEX_ACTIVE_DIR"
elif [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
  APEX_ACTIVE="$CLAUDE_PROJECT_DIR/.claude-tmp/apex-active"
else
  APEX_ACTIVE="$PWD/.claude-tmp/apex-active"
fi

warn() { echo "cleanup-session.sh: $*" >&2; }

MF="$APEX_ACTIVE/${SESSION}.json"
if [[ ! -f "$MF" ]]; then
  warn "no manifest at ${MF}; nothing to clean"
  exit 0
fi

WT_FIELDS=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    sys.exit(0)
print(d.get('worktree_path', ''))
print(d.get('branch', ''))
print(d.get('base_branch', 'main'))
" "$MF" 2>/dev/null || true)
WT_PATH=$(echo "$WT_FIELDS" | sed -n '1p')
WT_BRANCH=$(echo "$WT_FIELDS" | sed -n '2p')
WT_BASE=$(echo "$WT_FIELDS" | sed -n '3p')
[[ -z "$WT_BASE" ]] && WT_BASE="main"

if [[ -z "$WT_PATH" || ! -d "$WT_PATH" ]]; then
  warn "session $SESSION: manifest lacks worktree_path or path is gone ($WT_PATH); manifest preserved for inspection"
  exit 0
fi

# Resolve main worktree from manifest's worktree_path (dirname twice):
# WT_PATH = <MAIN>/.apex-worktrees/<session>, so MAIN = dirname(dirname(WT_PATH)).
# Derived from the manifest, NOT git, so it survives a removed-worktree subtree
# below. Printed to stdout on every success exit so apex orchestrator step 13/14
# (and session-end-hook.sh manual mode) can cd out of the (possibly removed)
# worktree subdirectory. Falls back to git common-dir resolution when dirname
# parents fail (e.g., manifest worktree_path is a non-standard layout).
MAIN_FROM_MANIFEST="$(cd "$(dirname "$(dirname "$WT_PATH")")" 2>/dev/null && pwd -P || echo "")"

DIRTY="$(cd "$WT_PATH" && git status --porcelain 2>/dev/null || true)"
COMMITS_PAST_BASE="$(cd "$WT_PATH" && git log "${WT_BASE}..${WT_BRANCH}" --oneline 2>/dev/null || true)"

if [[ -n "$DIRTY" ]]; then
  warn "session $SESSION: worktree $WT_PATH has uncommitted changes; resolve manually"
  [[ -n "$MAIN_FROM_MANIFEST" ]] && echo "$MAIN_FROM_MANIFEST"
  exit 0
fi
if [[ -n "$COMMITS_PAST_BASE" ]]; then
  n_commits="$(echo "$COMMITS_PAST_BASE" | grep -c . || true)"
  warn "session $SESSION: branch $WT_BRANCH has $n_commits commits past $WT_BASE in $WT_PATH; run /apex-merge to integrate"
  [[ -n "$MAIN_FROM_MANIFEST" ]] && echo "$MAIN_FROM_MANIFEST"
  exit 0
fi

MAIN_TOP="$(cd "$WT_PATH" && git rev-parse --git-common-dir 2>/dev/null | sed 's,/\.git$,,' || echo "")"
MAIN_TOP_RES="$(cd "$MAIN_TOP" 2>/dev/null && pwd -P || echo "$MAIN_TOP")"
# Prefer git-resolved when present (handles non-standard worktree layouts);
# fall back to manifest-derived. At least one must be non-empty for the cd-back.
[[ -z "$MAIN_TOP_RES" ]] && MAIN_TOP_RES="$MAIN_FROM_MANIFEST"
if [[ -z "$MAIN_TOP_RES" ]]; then
  warn "session $SESSION: could not resolve main worktree from $WT_PATH; skipping worktree remove"
  exit 0
fi
(cd "$MAIN_TOP_RES" && git worktree remove "$WT_PATH" --force 2>/dev/null) || warn "git worktree remove failed for $WT_PATH"
(cd "$MAIN_TOP_RES" && git branch -D "$WT_BRANCH" 2>/dev/null)            || warn "git branch -D failed for $WT_BRANCH"
echo "$MAIN_TOP_RES"
exit 0
