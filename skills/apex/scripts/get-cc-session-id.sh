#!/usr/bin/env bash
# Canonical resolver for the current Claude Code session id.
# Spec: shared-guardrails.md "cc_session_id resolution".
#
# Resolution order (first hit wins):
#   1. $CC_SESSION_ID env var (if set + non-empty)
#   2. Most-recently-modified .jsonl in ~/.claude/projects/<encoded-cwd>/
#      where <encoded-cwd> = pwd with `/` and `.` replaced by `-`.
#
# Echoes the resolved id to stdout. Exits 0 on success, 1 if no id can be
# resolved (callers must surface this; never default-to-empty).
#
# Idempotent + side-effect-free. Safe to call from any script.

set -euo pipefail

# 1. env-var fast path
if [[ -n "${CC_SESSION_ID:-}" ]]; then
  printf '%s\n' "$CC_SESSION_ID"
  exit 0
fi

# 2. most-recent jsonl in projects dir
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
