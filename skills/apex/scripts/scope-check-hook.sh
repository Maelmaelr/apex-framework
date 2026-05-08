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
#   2. Pointer misses AND no active main-scope.json anywhere -> entry-flow /
#      non-/apex session: pass through.
#   3. Pointer misses AND >=1 active main-scope.json exist -> ambiguous between
#      "subagent leak from an apex orchestrator on THIS claude process" and
#      "non-apex session running concurrently with sibling apex orchestrators
#      in other claude processes (same project cwd, different terminals)".
#      Resolved by walking the process tree to the calling claude pid and
#      matching against each apex manifest's recorded pid. Match -> enforce
#      that orchestrator's scope; no match -> pass through (sibling claude
#      processes have no authority over this one's edits).
#
# Stale-PID-reuse guard (subagent fallback only):
#   PID match alone is unsafe when an apex orchestrator crashed without
#   cleanup and the OS reused its PID for a fresh non-apex claude. Without
#   the guard, the new session's subagent edits get denied by the leaked
#   manifest. We compare the calling claude's lstart (process start time)
#   against the manifest file's mtime: a manifest written BEFORE the
#   calling claude started cannot belong to it (PID reuse) and is skipped.
#   Lstart-resolution failures fall through to the prior PID-only behavior
#   (still better than blanket-deny).
#
# Standard safety paths (closed set, always allowed):
#   - .claude-tmp/
#   - ~/.claude/tmp/
#   - /tmp/{session}-*  (any session token; the directory is shared)
#   - project docs/**
#   - any README* file at any depth
#   - any VERSION file at any depth (consumed by step 12 git-sync inline bumps
#     post-agent; reflector 00bac875 surfaced the gate denial)
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

# Pointer miss with active main-scope(s). Walk the process tree to the calling
# claude pid; only enforce scopes whose apex manifest claims THIS claude process
# (subagent-of-this-orchestrator). Sibling apex sessions running in other claude
# processes have no authority over this process's edits.
if [[ -z "$POINTER" ]]; then
  shopt -s nullglob
  ACTIVE_SCOPES=("$APEX_ACTIVE"/*-main-scope.json)
  shopt -u nullglob
  if [[ ${#ACTIVE_SCOPES[@]} -eq 0 ]]; then
    echo "$ALLOW"
    exit 0
  fi

  HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  CALLING_PID=$(bash "$HOOK_DIR/find-claude-pid.sh" 2>/dev/null || true)
  if [[ -z "$CALLING_PID" ]]; then
    # Process-tree walk failed to find a claude ancestor (non-standard
    # launcher). Cannot prove subagent leak; pass through rather than
    # blanket-deny on sibling-session scopes unrelated to this process.
    echo "$ALLOW"
    exit 0
  fi

  # Calling claude's process start time (epoch). Used as the lower bound for
  # manifest mtime: any manifest predating this start cannot belong to the
  # current OS process at this PID (PID reuse). Empty on resolution failure;
  # downstream falls back to PID-only matching.
  CALLING_PID_LSTART_EPOCH=$(python3 -c "
import datetime, subprocess, sys
try:
    out = subprocess.check_output(['ps', '-o', 'lstart=', '-p', sys.argv[1]], text=True).strip()
    if not out:
        sys.exit(0)
    t = datetime.datetime.strptime(out, '%a %b %d %H:%M:%S %Y')
    print(int(t.timestamp()))
except Exception:
    pass
" "$CALLING_PID" 2>/dev/null)

  MATCHED_SCOPES=()
  for SCOPE in "${ACTIVE_SCOPES[@]}"; do
    SCOPE_BASE=$(basename "$SCOPE")
    SESSION_TOKEN="${SCOPE_BASE%-main-scope.json}"
    MANIFEST="$APEX_ACTIVE/$SESSION_TOKEN.json"
    [[ -f "$MANIFEST" ]] || continue
    MANIFEST_PID=$(python3 -c "
import json, sys
try:
    print(json.load(open(sys.argv[1])).get('pid', ''))
except Exception:
    print('')
" "$MANIFEST" 2>/dev/null)
    [[ -z "$MANIFEST_PID" ]] && continue
    if [[ "$MANIFEST_PID" == "$CALLING_PID" ]]; then
      # Stale-PID-reuse guard: skip manifests that predate the calling claude.
      # Manifest mtime is set at create-session.sh write time and never updated;
      # if it is older than the calling claude's lstart, the manifest belongs
      # to a previous (now-dead) process at the same PID.
      if [[ -n "$CALLING_PID_LSTART_EPOCH" ]]; then
        MANIFEST_MTIME=$(stat -f %m "$MANIFEST" 2>/dev/null || stat -c %Y "$MANIFEST" 2>/dev/null || echo "")
        if [[ -n "$MANIFEST_MTIME" && "$MANIFEST_MTIME" -lt "$CALLING_PID_LSTART_EPOCH" ]]; then
          continue
        fi
      fi
      MATCHED_SCOPES+=("$SCOPE")
    fi
  done

  if [[ ${#MATCHED_SCOPES[@]} -eq 0 ]]; then
    # No apex manifest claims this claude process. Caller is not running under
    # an apex orchestrator (or under one whose manifest has not yet been
    # written). Sibling apex sessions in other claude processes do not gate
    # this one.
    echo "$ALLOW"
    exit 0
  fi

  for TARGET in "${TARGETS[@]}"; do
    is_safety_path "$TARGET" && continue
    ALLOWED=$(python3 -c "
import json, os, sys, fnmatch
target = sys.argv[1]
target_abs = os.path.abspath(target)
for sc in sys.argv[2:]:
    try:
        files = json.load(open(sc, encoding='utf-8')).get('allowed_files', [])
    except Exception:
        continue
    for allowed in files:
        allowed_abs = os.path.abspath(os.path.expanduser(allowed))
        if target == allowed or target_abs == allowed_abs:
            print('yes'); sys.exit(0)
        if '*' in allowed or '?' in allowed:
            if fnmatch.fnmatch(target, allowed) or fnmatch.fnmatch(target_abs, allowed_abs):
                print('yes'); sys.exit(0)
print('no')
" "$TARGET" "${MATCHED_SCOPES[@]}" 2>/dev/null || echo "error")
    [[ "$ALLOWED" == "yes" ]] && continue
    if [[ "$ALLOWED" == "error" ]]; then
      deny "Scope check (subagent fallback): could not read matched main-scope files for orchestrator pid=$CALLING_PID. Investigate apex session state."
      exit 0
    fi
    deny "Scope violation (subagent fallback): $TARGET not in apex main-scope allowed_files of orchestrator pid=$CALLING_PID. Spawned subagent must respect parent session scope."
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
