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
# Args:
#   --session <token>       required, 8-char lowercase hex
#   --apex-active-dir <abs> optional, absolute path to .claude-tmp/apex-active/
#                           (override; otherwise APEX_ACTIVE_DIR env >
#                           $CLAUDE_PROJECT_DIR/.claude-tmp/apex-active >
#                           $PWD/.claude-tmp/apex-active).
#   --post-success | --caller-cc-session <id>
#                           accepted but ignored (no-ops in worktree-only mode -
#                           the worktree IS the isolation; the legacy PID guard
#                           + cc_session_id sibling-wipe guard from the shared-
#                           apex-active era no longer apply).
#
# Exit code: always 0 (idempotent contract; warnings to stderr).

# Best-effort cleanup: do not `set -e`, a single failure must not abort the rest.
set -uo pipefail

SESSION=""
APEX_ACTIVE_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)            SESSION="${2:-}"; shift 2 ;;
    --apex-active-dir)    APEX_ACTIVE_OVERRIDE="${2:-}"; shift 2 ;;
    --post-success)       shift ;;
    --caller-cc-session)  shift 2 ;;
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

DIRTY="$(cd "$WT_PATH" && git status --porcelain 2>/dev/null || true)"
COMMITS_PAST_BASE="$(cd "$WT_PATH" && git log "${WT_BASE}..${WT_BRANCH}" --oneline 2>/dev/null || true)"

if [[ -n "$DIRTY" ]]; then
  warn "session $SESSION: worktree $WT_PATH has uncommitted changes; resolve manually"
  exit 0
fi
if [[ -n "$COMMITS_PAST_BASE" ]]; then
  n_commits="$(echo "$COMMITS_PAST_BASE" | grep -c . || true)"
  warn "session $SESSION: branch $WT_BRANCH has $n_commits commits past $WT_BASE in $WT_PATH; run /apex-merge to integrate"
  exit 0
fi

MAIN_TOP="$(cd "$WT_PATH" && git rev-parse --git-common-dir 2>/dev/null | sed 's,/\.git$,,' || echo "")"
MAIN_TOP_RES="$(cd "$MAIN_TOP" 2>/dev/null && pwd -P || echo "$MAIN_TOP")"
if [[ -z "$MAIN_TOP_RES" ]]; then
  warn "session $SESSION: could not resolve main worktree from $WT_PATH; skipping worktree remove"
  exit 0
fi
(cd "$MAIN_TOP_RES" && git worktree remove "$WT_PATH" --force 2>/dev/null) || warn "git worktree remove failed for $WT_PATH"
(cd "$MAIN_TOP_RES" && git branch -D "$WT_BRANCH" 2>/dev/null)            || warn "git branch -D failed for $WT_BRANCH"
exit 0
