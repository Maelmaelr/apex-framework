#!/usr/bin/env bash
# APEX scope-check hook (PreToolUse, matcher: Edit|Write|MultiEdit|NotebookEdit).
# Spec: apex-core.md "Conventions" / scope-check hook.
#
# Resolution mechanism (on-disk pointer, NOT mtime):
#   1. Extract session_id from hook stdin event JSON.
#   2. Glob .claude-tmp/apex-active/*-scopes/{session_id}.txt (any apex {session}
#      matches; in practice exactly one matches the calling session_id).
#   3. The pointer file is single-line: absolute path to the active scope JSON.
#   4. Read scope.allowed_files; deny if target path not in list and not a
#      standard safety path.
#
# Pointer miss is a tri-state, not a binary:
#   1. Pointer hits -> orchestrator path: enforce that scope.
#   2. Pointer misses AND no active main-scope.json in this worktree's
#      apex-active -> entry-flow / non-/apex session: pass through.
#   3. Pointer misses AND the single active main-scope.json exists -> subagent
#      leak from this worktree's apex orchestrator. Per-worktree isolation
#      guarantees exactly one orchestrator (and so exactly one main-scope) per
#      apex-active dir; enforce it directly.
#
# Standard safety paths (closed set, always allowed):
#   - .claude-tmp/
#   - ~/.claude/tmp/
#   - /tmp/{session}-*  (any session token; the directory is shared)
#   - project docs/**
#   - any README* file at any depth
#   - any VERSION file at any depth (consumed by /apex-merge step 6's batched
#     VERSION bump on the final integration commit, and by orchestrator
#     post-agent inline bumps in non-/apex contexts; step 12 of /apex no longer
#     bumps VERSION - it persists `bump_hint` into the manifest; reflector
#     00bac875 surfaced the gate denial)
#
# Never includes .env* or .git/ regardless of scope contents (those are gated
# by separate hooks / settings deny rules).
#
# Hook protocol: always exit 0. Block via JSON permissionDecision=deny on stdout.

set -euo pipefail

ALLOW='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
deny() { echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"$1\"}}"; }

is_safety_path() {
  local target="$1"
  # Same-session self-allow (reflector 42f24a1c): when CWD is inside an apex
  # worktree (.../.apex-worktrees/<OWN>/...), an absolute-path Write into THAT
  # same worktree's .claude-tmp/ is the caller's own session - allow it. The
  # cross-worktree guard below still blocks paths reaching into OTHER sessions'
  # worktrees. Without this, any step building a path string from PROJECT_ROOT
  # (instead of relying on the relative .claude-tmp/ pass-through below) was
  # denied a write into its own apex-active dir.
  local own_token=""
  if [[ "$PWD" == *"/.apex-worktrees/"* ]]; then
    own_token="${PWD##*/.apex-worktrees/}"
    own_token="${own_token%%/*}"
  fi
  if [[ -n "$own_token" ]]; then
    [[ "$target" == *"/.apex-worktrees/${own_token}/.claude-tmp/"* ]] && return 0
    [[ "$target" == ".apex-worktrees/${own_token}/.claude-tmp/"* ]] && return 0
  fi
  # Cross-worktree leak guard (worktree migration): a target containing
  # .apex-worktrees/<X>/.claude-tmp/ belongs to session <X>'s linked worktree,
  # not the caller's own worktree-relative .claude-tmp/. Without this guard,
  # a subagent in worktree A could pass-through and write into worktree B's
  # apex-active/ via the generic .claude-tmp/ rule below. Force such paths
  # through the allowed_files check instead of the safety fast-path; the
  # caller's main-scope will not list another worktree's apex-active, so the
  # leak is denied. Legit writes to the caller's own worktree use the plain
  # relative .claude-tmp/... path and never trigger this branch.
  [[ "$target" == *"/.apex-worktrees/"*"/.claude-tmp/"* ]] && return 1
  [[ "$target" == ".apex-worktrees/"*"/.claude-tmp/"* ]] && return 1
  [[ "$target" == *".claude-tmp/"* ]] && return 0
  [[ "$target" == ".claude-tmp/"* ]] && return 0
  [[ "$target" == "$HOME/.claude/tmp/"* ]] && return 0
  [[ "$target" == "~/.claude/tmp/"* ]] && return 0
  [[ "$target" == /tmp/*-* ]] && return 0
  [[ "$target" == "docs/"* ]] && return 0
  [[ "$target" == */docs/* ]] && return 0
  local base
  base=$(basename "$target")
  [[ "$base" == README* ]] && return 0
  [[ "$base" == "VERSION" ]] && return 0
  return 1
}

# Fast-path: skip the python parse on every Edit/Write outside an apex session.
# When .claude-tmp/apex-active/ does not exist, no scope pointer can match;
# pass-through immediately. Cheaper than the existing pointer check at line ~80.
[[ -d ".claude-tmp/apex-active" ]] || { echo "$ALLOW"; exit 0; }

INPUT=$(cat)

# Extract session_id and tool-specific file paths in one Python pass.
# - Edit/Write: tool_input.file_path
# - MultiEdit:  tool_input.file_path (single target file; edits[] are within it)
# - NotebookEdit: tool_input.notebook_path
# Outputs (one per line): SESSION_ID, then each target path.
PARSED=$(echo "$INPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
session_id = data.get('session_id', '')
tool = data.get('tool_name', '')
ti = data.get('tool_input', {}) or {}
print(session_id)
if tool == 'NotebookEdit':
    p = ti.get('notebook_path', '')
    if p:
        print(p)
elif tool in ('Edit', 'Write', 'MultiEdit'):
    p = ti.get('file_path', '')
    if p:
        print(p)
" 2>/dev/null || echo "")

if [[ -z "$PARSED" ]]; then
  echo "$ALLOW"
  exit 0
fi

SESSION_ID=$(printf '%s\n' "$PARSED" | sed -n '1p')
TARGETS=()
while IFS= read -r line; do
  [[ -z "$line" ]] || TARGETS+=("$line")
done < <(printf '%s\n' "$PARSED" | sed -n '2,$p')

# No session_id or no target paths: nothing to check.
if [[ -z "$SESSION_ID" || ${#TARGETS[@]} -eq 0 ]]; then
  echo "$ALLOW"
  exit 0
fi

# Resolve scope via on-disk pointer.
# .claude-tmp/apex-active/*-scopes/{session_id}.txt - the {session} prefix is any
# apex session; exactly one should match the calling session_id (or zero, in
# which case pass-through).
APEX_ACTIVE=".claude-tmp/apex-active"
POINTER=""
if [[ -d "$APEX_ACTIVE" ]]; then
  for p in "$APEX_ACTIVE"/*-scopes/"$SESSION_ID".txt; do
    [[ -f "$p" ]] || continue
    POINTER="$p"
    break
  done
fi

# Pointer miss with active main-scope: subagent leak from this worktree's
# orchestrator. Per-worktree isolation guarantees exactly one main-scope file
# in this apex-active dir; resolve it directly.
if [[ -z "$POINTER" ]]; then
  shopt -s nullglob
  ACTIVE_SCOPES=("$APEX_ACTIVE"/*-main-scope.json)
  shopt -u nullglob
  if [[ ${#ACTIVE_SCOPES[@]} -eq 0 ]]; then
    echo "$ALLOW"
    exit 0
  fi
  ACTIVE_SCOPE="${ACTIVE_SCOPES[0]}"

  for TARGET in "${TARGETS[@]}"; do
    is_safety_path "$TARGET" && continue
    ALLOWED=$(python3 -c "
import json, os, sys, fnmatch
target = sys.argv[1]
target_abs = os.path.abspath(target)
try:
    files = json.load(open(sys.argv[2], encoding='utf-8')).get('allowed_files', [])
except Exception:
    print('error'); sys.exit(0)
for allowed in files:
    allowed_abs = os.path.abspath(os.path.expanduser(allowed))
    if target == allowed or target_abs == allowed_abs:
        print('yes'); sys.exit(0)
    if '*' in allowed or '?' in allowed:
        if fnmatch.fnmatch(target, allowed) or fnmatch.fnmatch(target_abs, allowed_abs):
            print('yes'); sys.exit(0)
print('no')
" "$TARGET" "$ACTIVE_SCOPE" 2>/dev/null || echo "error")
    [[ "$ALLOWED" == "yes" ]] && continue
    if [[ "$ALLOWED" == "error" ]]; then
      deny "Scope check (subagent fallback): could not read main-scope file $ACTIVE_SCOPE. Investigate apex session state."
      exit 0
    fi
    deny "Scope violation (subagent fallback): $TARGET not in apex main-scope allowed_files. Spawned subagent must respect parent session scope."
    exit 0
  done
  echo "$ALLOW"
  exit 0
fi

# Pointer file: single-line absolute path to scope JSON.
SCOPE_FILE=$(head -n 1 "$POINTER" | tr -d '[:space:]')
if [[ -z "$SCOPE_FILE" || ! -f "$SCOPE_FILE" ]]; then
  # Pointer points at missing scope: hard fail (state corruption).
  deny "Scope pointer at $POINTER references missing scope file ($SCOPE_FILE). Investigate apex session state."
  exit 0
fi

# Check each target path against safety paths + scope.allowed_files.
for TARGET in "${TARGETS[@]}"; do
  if is_safety_path "$TARGET"; then
    continue
  fi

  ALLOWED=$(python3 -c "
import json, os, sys, fnmatch
scope_file = sys.argv[1]
target = sys.argv[2]
try:
    with open(scope_file, encoding='utf-8') as f:
        data = json.load(f)
except Exception:
    print('error')
    sys.exit(0)
files = data.get('allowed_files', [])
target_abs = os.path.abspath(target)
for allowed in files:
    allowed_abs = os.path.abspath(os.path.expanduser(allowed))
    if target == allowed or target_abs == allowed_abs:
        print('yes')
        sys.exit(0)
    # Glob support for entries with * or ?
    if '*' in allowed or '?' in allowed:
        if fnmatch.fnmatch(target, allowed) or fnmatch.fnmatch(target_abs, allowed_abs):
            print('yes')
            sys.exit(0)
print('no')
" "$SCOPE_FILE" "$TARGET" 2>/dev/null || echo "error")

  if [[ "$ALLOWED" == "yes" ]]; then
    continue
  fi

  SCOPE_BASENAME=$(basename "$SCOPE_FILE")
  if [[ "$ALLOWED" == "error" ]]; then
    deny "Scope check failed: could not read $SCOPE_BASENAME for $TARGET. Investigate apex session state."
    exit 0
  fi
  deny "Scope violation: $TARGET not in apex allowed_files (scope=$SCOPE_BASENAME). Extend the scope before writing."
  exit 0
done

echo "$ALLOW"
exit 0
