#!/usr/bin/env bash
# APEX scope-check hook (PreToolUse, matcher: Edit|Write|MultiEdit|NotebookEdit).
# Spec: apex-core.md "Conventions" / scope-check hook + shared-guardrails.md.
#
# Resolution mechanism (on-disk pointer, NOT mtime):
#   1. Extract session_id from hook stdin event JSON.
#   2. Glob .claude-tmp/apex-active/*-scopes/{session_id}.txt (any apex {session}
#      matches; in practice exactly one matches the calling session_id).
#   3. The pointer file is single-line: absolute path to the active scope JSON.
#   4. Read scope.allowed_files; deny if target path not in list and not a
#      standard safety path.
#
# Pass-through (allow) when no pointer matches the calling session_id (entry-flow
# phase before any pointer is written, or non-/apex Claude Code session).
#
# Standard safety paths (closed set, always allowed):
#   - .claude-tmp/
#   - ~/.claude/tmp/
#   - /tmp/{session}-*  (any session token; the directory is shared)
#   - project docs/**
#   - any README* file at any depth
#
# Never includes .env* or .git/ regardless of scope contents (those are gated
# by separate hooks / settings deny rules).
#
# Hook protocol: always exit 0. Block via JSON permissionDecision=deny on stdout.

set -euo pipefail

ALLOW='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
deny() { echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"$1\"}}"; }

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

# No pointer for this session_id: pass-through (entry-flow before scope written,
# or non-/apex session entirely).
if [[ -z "$POINTER" ]]; then
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

is_safety_path() {
  local target="$1"
  # .claude-tmp/ anywhere in path
  [[ "$target" == *".claude-tmp/"* ]] && return 0
  [[ "$target" == ".claude-tmp/"* ]] && return 0
  # ~/.claude/tmp/ - both literal $HOME and tilde-prefixed forms
  [[ "$target" == "$HOME/.claude/tmp/"* ]] && return 0
  [[ "$target" == "~/.claude/tmp/"* ]] && return 0
  # /tmp/{session}-* - any session token; /tmp is shared
  [[ "$target" == /tmp/*-* ]] && return 0
  # project docs/**
  [[ "$target" == "docs/"* ]] && return 0
  [[ "$target" == */docs/* ]] && return 0
  # any README* at any depth
  local base
  base=$(basename "$target")
  [[ "$base" == README* ]] && return 0
  return 1
}

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
  deny "Scope violation: $TARGET not in apex allowed_files (scope=$SCOPE_BASENAME). Extend scope before writing, or route via shared_files at p2.4."
  exit 0
done

echo "$ALLOW"
exit 0
