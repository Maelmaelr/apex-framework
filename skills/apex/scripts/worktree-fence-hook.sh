#!/usr/bin/env bash
# /apex worktree-boundary fence (PreToolUse: Edit|Write|MultiEdit|NotebookEdit).
#
# The ONLY scope rail for /apex. A session's edits must land inside its own git
# worktree - the worktree IS the scope, so there is no file-level allowed_files
# list, no discovery-computed scope, and no scope-pointer.
#
# Two arming modes (first match wins):
#   1. cwd-armed: the session cwd - hook process $PWD first, event JSON "cwd"
#      as fallback (belt and suspenders across harness versions) - is inside
#      .apex-worktrees/<token>/. Relative targets resolve under the cwd and
#      pass; absolute targets are classified against the boundary.
#   2. record-armed: cwd is NOT inside a worktree but this CC session minted
#      one - mint-worktree.sh wrote the worktree root to
#      $APEX_FENCE_DIR/<cc_session_id> AND $APEX_FENCE_DIR/pid-<claude-pid>
#      (default dir ~/.claude/tmp/apex-fence/; the pid key survives /clear
#      session-id rotation and is shared with in-process subagents).
#      Catches unanchored subagents and post-teardown cwd resets whose writes
#      would otherwise land in the MAIN tree. Relative targets resolve under
#      the event cwd (else $PWD) and are classified like absolute ones.
#      A record whose worktree no longer exists is stale: removed, fail-open
#      (/apex-merge teardown disarms automatically; /apex-merge precheck and
#      the apex SessionEnd hook also disarm eagerly).
#   Neither armed -> ALLOW (normal / non-apex session).
#
# Boundary (armed): target under the worktree root -> ALLOW; framework scratch
# (~/.claude/tmp, /tmp, /private/tmp, /var/folders, /private/var/folders - the
# harness scratchpad lives under /private/tmp on macOS) -> ALLOW; anything
# else (main tree, ~/.claude src, a sibling worktree) -> DENY.
#
# Does not override protect-env / block-destructive (separate hooks). Bash
# file writes are covered (tripwire-grade) by block-destructive-hook.sh's
# fence checks, which share this arming model.
#
# Hook protocol: always exit 0; block via JSON permissionDecision=deny on stdout.

set -euo pipefail

ALLOW='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
deny() {
  local head='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"'
  printf '%s,"permissionDecisionReason":"%s"}}\n' "$head" "$1"
}

INPUT=$(cat)

# One parse: line 1 = event cwd, line 2 = edit target (tool-appropriate
# field), line 3 = CC session id (record-armed key).
PARSED=$(printf '%s' "$INPUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ti = d.get('tool_input', {}) or {}
t = d.get('tool_name', '')
print(d.get('cwd', ''))
print(ti.get('notebook_path', '') if t == 'NotebookEdit' else ti.get('file_path', ''))
print(d.get('session_id', ''))
" 2>/dev/null || printf '\n\n\n')
EVENT_CWD=$(printf '%s\n' "$PARSED" | head -n 1)
TARGET=$(printf '%s\n' "$PARSED" | head -n 2 | tail -n 1)
EVENT_SID=$(printf '%s\n' "$PARSED" | head -n 3 | tail -n 1)

# cwd arming: enforce when EITHER cwd source is inside an apex worktree
# ($PWD preferred for the root derivation; the event cwd catches harness
# versions where the hook process cwd does not track the session shell).
SESSION_CWD=""
case "$PWD" in
  */.apex-worktrees/*) SESSION_CWD="$PWD" ;;
esac
if [[ -z "$SESSION_CWD" ]]; then
  case "$EVENT_CWD" in
    */.apex-worktrees/*) SESSION_CWD="$EVENT_CWD" ;;
  esac
fi

RECORD_ARMED=0
REC_PATH=""
if [[ -n "$SESSION_CWD" ]]; then
  # Worktree root = path up to and including .apex-worktrees/<token> (cwd may
  # be a subdir of the worktree; strip everything from the token's next slash).
  OWN="${SESSION_CWD##*/.apex-worktrees/}"
  OWN="${OWN%%/*}"
  WT_ROOT="${SESSION_CWD%%/.apex-worktrees/*}/.apex-worktrees/${OWN}"
else
  # record-armed probe, two keys, first hit wins: (1) the event session_id
  # (CC_SESSION_ID env as override/fallback) - rotates on /clear; (2) the
  # claude process pid (pid-<pid>) - stable across /clear and shared with
  # in-process subagents. Both written by mint-worktree.sh. Gated on the
  # fence dir being non-empty so sessions with no live apex mint pay nothing
  # (the pid walk shells out to ps).
  FENCE_DIR="${APEX_FENCE_DIR:-$HOME/.claude/tmp/apex-fence}"
  WT_ROOT=""
  shopt -s nullglob
  _RECS=("$FENCE_DIR"/*)
  shopt -u nullglob
  if [[ ${#_RECS[@]} -eq 0 ]]; then
    echo "$ALLOW"; exit 0
  fi
  SID="${EVENT_SID:-${CC_SESSION_ID:-}}"
  if [[ -n "$SID" && -f "$FENCE_DIR/$SID" ]]; then
    REC_PATH="$FENCE_DIR/$SID"
  else
    _HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _CPID="$(bash "$_HOOK_DIR/find-claude-pid.sh" 2>/dev/null || true)"
    if [[ -n "$_CPID" && -f "$FENCE_DIR/pid-$_CPID" ]]; then
      REC_PATH="$FENCE_DIR/pid-$_CPID"
    fi
  fi
  if [[ -n "$REC_PATH" ]]; then
    WT_ROOT="$(head -n 1 "$REC_PATH" 2>/dev/null || true)"
    if [[ -n "$WT_ROOT" && -d "$WT_ROOT" ]]; then
      RECORD_ARMED=1
    else
      rm -f "$REC_PATH" 2>/dev/null || true  # stale (worktree gone): self-heal
      echo "$ALLOW"; exit 0
    fi
  else
    echo "$ALLOW"; exit 0
  fi
fi

# Unparsable / empty target -> nothing to enforce.
[[ -n "$TARGET" ]] || { echo "$ALLOW"; exit 0; }

# Relative targets: cwd-armed -> resolve under cwd (inside the worktree),
# always safe. Record-armed -> the session cwd is OUTSIDE the worktree, so a
# relative target is exactly the leak this mode exists to catch: resolve it
# against the event cwd (else $PWD) and classify like an absolute target.
case "$TARGET" in
  /*) : ;;
  *)
    if [[ "$RECORD_ARMED" -eq 0 ]]; then
      echo "$ALLOW"; exit 0
    fi
    TARGET="${EVENT_CWD:-$PWD}/$TARGET"
    ;;
esac

# Absolute target: resolve (~ + ..) and require it under the worktree root.
TARGET_ABS=$(python3 -c \
  "import os, sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))" \
  "$TARGET" 2>/dev/null || echo "$TARGET")

# Trailing-slash on both sides so /a/bar does not match root /a/ba.
case "$TARGET_ABS/" in
  "$WT_ROOT"/*) echo "$ALLOW"; exit 0 ;;
esac

# Framework-scratch escapes (lessons, error logs, shared tmp, harness scratchpad).
case "$TARGET_ABS" in
  "$HOME/.claude/tmp/"*) echo "$ALLOW"; exit 0 ;;
  /tmp/*) echo "$ALLOW"; exit 0 ;;
  /private/tmp/*) echo "$ALLOW"; exit 0 ;;
  /var/folders/*) echo "$ALLOW"; exit 0 ;;
  /private/var/folders/*) echo "$ALLOW"; exit 0 ;;
esac

if [[ "$RECORD_ARMED" -eq 1 ]]; then
  msg="Worktree fence (session record): this session's apex worktree is $WT_ROOT "
  msg+="but the write resolves to $TARGET_ABS outside it. Anchor first (cd $WT_ROOT) "
  msg+="or target a path under it. If main-tree writes are intentional (apex work "
  msg+="finished), disarm: rm $REC_PATH"
else
  msg="Worktree fence: $TARGET_ABS is outside this apex session's worktree "
  msg+="($WT_ROOT). /apex edits must stay inside the worktree; integration "
  msg+="happens via /apex-merge."
fi
deny "$msg"
exit 0
