#!/usr/bin/env bash
# APEX scope constraint hook (PreToolUse, matcher: Edit|Write)
# Reads allowed file list from .claude-tmp/apex-active/{session}-scope.json.
# If no active session, exits 0 (allow). If file_path in allowed list or
# in .claude-tmp/, exits 0. Otherwise blocks with JSON reason.
# Exit 0 = always (hook protocol: blocks via JSON output, not exit code).
set -euo pipefail

ALLOW='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
deny() { echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"$1\"}}"; }

# Read hook input from stdin
INPUT=$(cat)

# Extract file_path from tool_input
FILE_PATH=$(echo "$INPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
ti = data.get('tool_input', {})
print(ti.get('file_path', ''))
" 2>/dev/null || echo "")

# No file_path means nothing to check -- allow
if [[ -z "$FILE_PATH" ]]; then
  echo "$ALLOW"
  exit 0
fi

# Find active scope file
SCOPE_DIR=".claude-tmp/apex-active"
if [[ ! -d "$SCOPE_DIR" ]]; then
  echo "$ALLOW"
  exit 0
fi

# Match *-scope.json with session ID validation, select newest by mtime
SCOPE_FILE=""
NEWEST_MTIME=0
for f in "$SCOPE_DIR"/*-scope.json; do
  [[ -f "$f" ]] || continue
  BASENAME=$(basename "$f")
  # Validate format: apex-[a-z0-9]{6,8} (8-char session IDs + 6-char team names)
  if [[ "$BASENAME" =~ ^apex-[a-z0-9]{6,8}-scope\.json$ ]]; then
    MTIME=$(stat -f %m "$f" 2>/dev/null || echo "0")
    if [[ "$MTIME" -gt "$NEWEST_MTIME" ]]; then
      NEWEST_MTIME="$MTIME"
      SCOPE_FILE="$f"
    fi
  fi
done

# No valid scope file means no active APEX session -- allow
if [[ -z "$SCOPE_FILE" ]]; then
  echo "$ALLOW"
  exit 0
fi

# Always allow .claude-tmp/ paths (session artifacts)
if [[ "$FILE_PATH" == *".claude-tmp/"* ]]; then
  echo "$ALLOW"
  exit 0
fi

# Always allow .claude/plans/ paths (system-generated plan files)
if [[ "$FILE_PATH" == *".claude/plans/"* ]]; then
  echo "$ALLOW"
  exit 0
fi

# Always allow .claude/ project infrastructure paths (audit criteria, verdicts,
# scout findings, lessons). Security-sensitive files handled by protect-env hook.
if [[ "$FILE_PATH" == *".claude/audit-criteria/"* ]] ||
   [[ "$FILE_PATH" == *".claude/audit-verdicts/"* ]] ||
   [[ "$FILE_PATH" == *".claude/scout-findings/"* ]] ||
   [[ "$FILE_PATH" == *".claude/lessons"* ]]; then
  echo "$ALLOW"
  exit 0
fi

# Always allow $HOME/.claude/ home skill edits (skills, agents, CLAUDE.md,
# audit-criteria). Covers improve sessions and admin-apex edits regardless of
# the active project-scope session.
if [[ "$FILE_PATH" == "$HOME/.claude/"* ]]; then
  echo "$ALLOW"
  exit 0
fi

# Check if file_path is in the allowed list (pass SCOPE_FILE via argv, not interpolation)
# Supports both explicit paths and glob patterns (entries containing * or ?)
# Output format: "yes:N" or "no:N" where N is allowed_count (0 if scope unreadable).
PY_STDERR=$(mktemp 2>/dev/null || echo "/tmp/apex-scope-check-$$.err")
ALLOWED=$(python3 -c "
import fnmatch, json, os, sys
scope_file = sys.argv[1]
target = sys.argv[2]
with open(scope_file, encoding='utf-8') as f:
    data = json.load(f)
files = data.get('files', [])
count = len(files)
for allowed in files:
    if target == allowed or target.endswith('/' + allowed) or allowed.endswith('/' + target):
        print('yes:' + str(count))
        sys.exit(0)
    expanded_allowed = os.path.expanduser(allowed)
    expanded_target = os.path.expanduser(target)
    if expanded_target == expanded_allowed:
        print('yes:' + str(count))
        sys.exit(0)
    if '*' in allowed or '?' in allowed:
        candidates = [allowed]
        if '/**/' in allowed:
            candidates.append(allowed.replace('/**/', '/'))
        for cand in candidates:
            if fnmatch.fnmatch(target, cand) or fnmatch.fnmatch(target, '**/' + cand):
                print('yes:' + str(count))
                sys.exit(0)
            expanded_cand = os.path.expanduser(cand)
            if fnmatch.fnmatch(expanded_target, expanded_cand) or fnmatch.fnmatch(expanded_target, '**/' + expanded_cand):
                print('yes:' + str(count))
                sys.exit(0)
print('no:' + str(count))
" "$SCOPE_FILE" "$FILE_PATH" 2>"$PY_STDERR" || echo "no:0")
PY_ERR=$(tr '\n' ' ' < "$PY_STDERR" 2>/dev/null | head -c 120)
rm -f "$PY_STDERR"

if [[ "$ALLOWED" == yes:* ]]; then
  echo "$ALLOW"
  exit 0
fi

# Block: file not in allowed scope. Include scope_file basename, allowed_count,
# and captured python stderr so the assistant can distinguish genuine misses
# from transient scope-read failures without manual hook-invocation.
ALLOWED_COUNT="${ALLOWED#no:}"
SCOPE_BASENAME=$(basename "$SCOPE_FILE")
DENY_MSG="Scope violation: $FILE_PATH not in APEX allowed files (scope_file=$SCOPE_BASENAME, allowed_count=$ALLOWED_COUNT). Pre-extend scope JSON before Write (see SKILL.md Step 5A Scope extension)."
if [[ "$ALLOWED_COUNT" == "0" ]]; then
  DENY_MSG="$DENY_MSG Hint: scope unreadable -- retry once."
fi
if [[ -n "$PY_ERR" ]]; then
  # Escape backslashes and double quotes for JSON embedding
  PY_ERR_ESC=${PY_ERR//\\/\\\\}
  PY_ERR_ESC=${PY_ERR_ESC//\"/\\\"}
  DENY_MSG="$DENY_MSG stderr=$PY_ERR_ESC"
fi
deny "$DENY_MSG"
exit 0
