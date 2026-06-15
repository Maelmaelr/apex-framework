#!/usr/bin/env bash
# resolve-apex-active.sh -- given an apex {session} token, print the ABSOLUTE
# path of that session's worktree-resident apex-active dir
# (<worktree_path>/.claude-tmp/apex-active).
#
# Why this exists (cluster: worktree-marker-leak):
#   Apex producers (discoverer / screener / executor / orchestrator inline
#   writes) emit `{session}-*` markers under `.claude-tmp/apex-active/`. A bare
#   relative path resolves against the project root, not the bash CWD, and
#   subagent CWD inheritance into the session worktree is unreliable - so a
#   marker (notably main-scope.json + the scope-check pointer) can land in the
#   MAIN tree and block unrelated sibling sessions. This resolver is the single
#   source of truth for anchoring every such write to the session worktree.
#
# Resolution order (mirrors session-end-hook.sh's manifest scan):
#   1. <cwd>/.claude-tmp/apex-active/{session}.json  (CWD already in the worktree)
#   2. <main>/.apex-worktrees/*/.claude-tmp/apex-active/{session}.json
#      where <main> = `git rev-parse --git-common-dir` stripped of trailing /.git
#   Read .worktree_path from the matched manifest; print
#   <worktree_path>/.claude-tmp/apex-active.
#
# Fails CLOSED (exit non-zero, nothing on stdout) when the manifest is missing
# or carries no worktree_path. It NEVER echoes a main-tree fallback - a fail-open
# resolver would silently re-introduce the leak.
#
# Output:
#   - On success: absolute apex-active dir on stdout, exit 0.
#   - On failure: stderr diagnostic, exit non-zero (1 bad args, 2 unresolved).
#
# Args:
#   $1 = {session}  8-char lowercase hex apex token.

set -uo pipefail

SESSION="${1:-}"
if [[ ! "$SESSION" =~ ^[0-9a-f]{8}$ ]]; then
  echo "resolve-apex-active.sh: requires an 8-hex {session} token (got: '${SESSION}')" >&2
  exit 1
fi

# Read .worktree_path from a manifest, append the apex-active suffix, print.
# Returns non-zero (and prints nothing) when the file is absent / unparseable /
# missing worktree_path - so the caller's `||` fail-closed branch fires.
emit_from_manifest() {
  local manifest="$1" wt
  [[ -f "$manifest" ]] || return 1
  wt=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    sys.exit(1)
wt = d.get('worktree_path', '')
if not wt:
    sys.exit(1)
print(wt)
" "$manifest" 2>/dev/null) || return 1
  [[ -n "$wt" ]] || return 1
  printf '%s/.claude-tmp/apex-active\n' "$wt"
  return 0
}

# 1. CWD-local manifest (the common case: producer already cd'd to the worktree).
if emit_from_manifest ".claude-tmp/apex-active/$SESSION.json"; then
  exit 0
fi

# 2. Scan worktree-resident manifests under <main>/.apex-worktrees/.
MAIN="$(git rev-parse --git-common-dir 2>/dev/null | sed -e 's,/\.git$,,' -e 's,^\.git$,.,')"
if [[ -n "$MAIN" && -d "$MAIN/.apex-worktrees" ]]; then
  shopt -s nullglob
  for manifest in "$MAIN"/.apex-worktrees/*/.claude-tmp/apex-active/"$SESSION".json; do
    if emit_from_manifest "$manifest"; then
      shopt -u nullglob
      exit 0
    fi
  done
  shopt -u nullglob
fi

echo "resolve-apex-active.sh: no manifest with worktree_path for session $SESSION (refusing main-tree fallback)" >&2
exit 2
