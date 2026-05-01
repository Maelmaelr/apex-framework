#!/usr/bin/env bash
# Canonical resolver for the current Claude Code session id.
# Spec: shared-guardrails.md "cc_session_id resolution".
#
# Resolution order (first hit wins):
#   1. $CC_SESSION_ID env var (if set + non-empty)        -- explicit override
#   2. Walk ancestor PIDs for `claude --session-id <UUID>` -- authoritative
#   3. Most-recently-modified .jsonl in ~/.claude/projects/<encoded-cwd>/ -- legacy fallback
#
# Step 2 is the fix for the latest-jsonl race: when multiple sibling Claude
# Code sessions share the same encoded-cwd, step 3 picks whichever session
# wrote a transcript line most recently, which can be a sibling. Step 2
# parses --session-id from the actual claude process in this conversation's
# parent chain and is unambiguous. Step 3 stays as fallback for off-tree
# callers (cron, scripted tests) that have no claude ancestor.
#
# Echoes the resolved id to stdout. Exits 0 on success, 1 if no id can be
# resolved (callers must surface this; never default-to-empty).
#
# Idempotent + side-effect-free. Safe to call from any script.

set -uo pipefail

# 1. env-var fast path
if [[ -n "${CC_SESSION_ID:-}" ]]; then
  printf '%s\n' "$CC_SESSION_ID"
  exit 0
fi

# 2. ancestor process walk -- find a `claude ... --session-id <UUID>` invocation.
# Bash sub-shell chains can be 1-3 levels deep (script <- bash wrapper <- claude
# Bash tool <- claude main). Cap depth at 10 for safety.
SESSION_ID=""
pid=$$
for _ in 1 2 3 4 5 6 7 8 9 10; do
  cmd=$(ps -o command= -p "$pid" 2>/dev/null || true)
  if [[ -z "$cmd" ]]; then
    break
  fi
  if [[ "$cmd" =~ claude([[:space:]].*)?--session-id[[:space:]]+([0-9a-f-]{36}) ]]; then
    SESSION_ID="${BASH_REMATCH[2]}"
    break
  fi
  ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
  if [[ -z "$ppid" || "$ppid" == "0" || "$ppid" == "1" ]]; then
    break
  fi
  pid="$ppid"
done

if [[ -n "$SESSION_ID" ]]; then
  printf '%s\n' "$SESSION_ID"
  exit 0
fi

# 3. legacy fallback: most-recent .jsonl in projects dir
encoded_cwd="$(pwd | tr '/.' '--')"
projects_dir="$HOME/.claude/projects/$encoded_cwd"

if [[ ! -d "$projects_dir" ]]; then
  echo "get-cc-session-id.sh: projects dir not found: $projects_dir" >&2
  exit 1
fi

latest=$(ls -t "$projects_dir"/*.jsonl 2>/dev/null | head -1 || true)

if [[ -z "$latest" ]]; then
  echo "get-cc-session-id.sh: no .jsonl session file in $projects_dir" >&2
  exit 1
fi

basename "$latest" .jsonl
exit 0
