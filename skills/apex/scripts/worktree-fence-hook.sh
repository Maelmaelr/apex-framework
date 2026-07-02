#!/usr/bin/env bash
# /apex worktree-boundary fence (PreToolUse: Edit|Write|MultiEdit|NotebookEdit).
#
# The ONLY scope rail for /apex. A session's edits must land inside its own git
# worktree - the worktree IS the scope, so there is no file-level allowed_files
# list, no discovery-computed scope, and no scope-pointer. Stateless: activation
# keys off $PWD == */.apex-worktrees/*.
#
# Activation (fail-open everywhere an apex worktree is not the cwd):
#   - PWD not inside .apex-worktrees/<token>/  -> ALLOW (normal / non-apex session)
#   - PWD inside a worktree                    -> enforce boundary
#
# Boundary (only absolute targets can escape; relative ones resolve under cwd):
#   - relative target               -> ALLOW (resolves under cwd = worktree)
#   - absolute under worktree root  -> ALLOW
#   - framework scratch (~/.claude/tmp, /tmp) -> ALLOW
#   - anything else (main tree, ~/.claude src, a sibling worktree) -> DENY
#
# Does not override protect-env / block-destructive (separate hooks, .env + .git).
#
# Hook protocol: always exit 0; block via JSON permissionDecision=deny on stdout.

set -euo pipefail

ALLOW='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
deny() {
  local head='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"'
  printf '%s,"permissionDecisionReason":"%s"}}\n' "$head" "$1"
}

# Activation gate: only enforce inside an apex worktree.
case "$PWD" in
  */.apex-worktrees/*) : ;;
  *) echo "$ALLOW"; exit 0 ;;
esac

# Worktree root = path up to and including .apex-worktrees/<token> (PWD may be a
# subdir of the worktree; strip everything from the token's next slash onward).
OWN="${PWD##*/.apex-worktrees/}"
OWN="${OWN%%/*}"
WT_ROOT="${PWD%%/.apex-worktrees/*}/.apex-worktrees/${OWN}"

INPUT=$(cat)
TARGET=$(printf '%s' "$INPUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ti = d.get('tool_input', {}) or {}
t = d.get('tool_name', '')
print(ti.get('notebook_path', '') if t == 'NotebookEdit' else ti.get('file_path', ''))
" 2>/dev/null || echo "")

# Unparsable / empty target -> nothing to enforce.
[[ -n "$TARGET" ]] || { echo "$ALLOW"; exit 0; }

# Relative targets resolve under cwd (inside the worktree) -> always safe.
case "$TARGET" in
  /*) : ;;
  *) echo "$ALLOW"; exit 0 ;;
esac

# Absolute target: resolve (~ + ..) and require it under the worktree root.
TARGET_ABS=$(python3 -c \
  "import os, sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))" \
  "$TARGET" 2>/dev/null || echo "$TARGET")

# Trailing-slash on both sides so /a/bar does not match root /a/ba.
case "$TARGET_ABS/" in
  "$WT_ROOT"/*) echo "$ALLOW"; exit 0 ;;
esac

# Framework-scratch escapes (lessons, error logs, shared tmp).
case "$TARGET_ABS" in
  "$HOME/.claude/tmp/"*) echo "$ALLOW"; exit 0 ;;
  /tmp/*) echo "$ALLOW"; exit 0 ;;
esac

msg="Worktree fence: $TARGET_ABS is outside this apex session's worktree "
msg+="($WT_ROOT). /apex edits must stay inside the worktree; integration "
msg+="happens via /apex-merge."
deny "$msg"
exit 0
