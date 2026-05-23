#!/usr/bin/env bash
# Step 2: create session manifest + per-session worktree.
# Spec: apex-core.md step 2 + Conventions / Session manifest schema.
#
# Behavior:
#   1. Generate {session} via openssl rand -hex 4.
#   2. Capture base_branch, create git worktree at <main>/.apex-worktrees/<session>/
#      on branch apex/<session> off HEAD, cd into it.
#   3. Write manifest {session, pid: <claude-pid>, cc_session_id, worktree_path,
#      branch, base_branch}. pid is the claude main process pid, resolved via
#      find-claude-pid.sh (walks up the process tree until comm basename ==
#      "claude"). $PPID is NOT used: when this script is invoked as
#      `bash create-session.sh ...`, $PPID is the transient zsh subshell that
#      Claude Code's Bash tool spawned, not claude itself.
#   4. Echo {session} to stdout for orchestrator capture.
#
# Per-worktree isolation: each apex session lives in its own working tree +
# index + branch. No concurrent-session conflict surface exists between
# worktrees, so no sibling overlap detection or scope-overlap classification
# is needed.
#
# Args:
#   --cc-session-id <id>  (required) - Claude Code session id passed by orchestrator.
#
# Exit codes:
#   0  - manifest written, {session} on stdout
#   1  - unrecoverable error (bad args, openssl missing, etc.)

set -euo pipefail

# Bash 4+ guard (reflector 4cbf7e86): this script uses heredocs inside process
# substitutions which fail silently on macOS's default /bin/bash 3.2, leaving
# the manifest half-written and stranding the session with no clear error.
# Fail loud at entry rather than mid-heredoc.
if (( BASH_VERSINFO[0] < 4 )); then
  echo "create-session.sh: bash >= 4 required (current: $BASH_VERSION). On macOS install via 'brew install bash' and re-run with /opt/homebrew/bin/bash (or /usr/local/bin/bash on Intel)." >&2
  exit 1
fi

# CWD=PROJECT_ROOT fail-fast guard (reflector c5ea7797): this script writes the
# manifest to the RELATIVE path .claude-tmp/apex-active, so it MUST run from the
# project root. Invoked from the apex skill dir (or any non-root CWD) it would
# silently create a manifest under the wrong .claude-tmp and strand the session.
# Fail loudly instead of corrupting state.
#   (a) never run from inside the apex install tree ($HOME/.claude/...)
#   (b) when in a git repo, CWD must be the git toplevel (manifest at repo root)
# Non-git projects skip (b) but still get (a). No jq/git dependency for (a).
_CSH_PWD="$(pwd -P)"
_CSH_HOME_CLAUDE="$(cd "$HOME/.claude" 2>/dev/null && pwd -P || echo "$HOME/.claude")"
case "$_CSH_PWD/" in
  "$_CSH_HOME_CLAUDE"/*)
    echo "create-session.sh: refusing to run from inside the apex install tree ($_CSH_PWD); cd to the project root first" >&2
    exit 1
    ;;
esac
if _CSH_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  _CSH_TOPLEVEL="$(cd "$_CSH_TOPLEVEL" 2>/dev/null && pwd -P || echo "$_CSH_TOPLEVEL")"
  if [[ "$_CSH_PWD" != "$_CSH_TOPLEVEL" ]]; then
    echo "create-session.sh: CWD ($_CSH_PWD) is not the git toplevel ($_CSH_TOPLEVEL); run from the project root so the manifest lands in the right .claude-tmp" >&2
    exit 1
  fi
fi

APEX_ACTIVE=".claude-tmp/apex-active"

CC_SESSION_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cc-session-id)
      CC_SESSION_ID="${2:-}"
      shift 2
      ;;
    *)
      echo "create-session.sh: unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$CC_SESSION_ID" ]]; then
  echo "create-session.sh: --cc-session-id is required" >&2
  exit 1
fi

# Defensive cc_session_id format check: Claude Code session ids are UUIDs
# (hex + hyphens). Rejecting anything else closes the printf injection edge
# below (we trust the bytes when writing JSON).
if ! [[ "$CC_SESSION_ID" =~ ^[0-9a-fA-F-]+$ ]]; then
  echo "create-session.sh: --cc-session-id has unexpected shape: $CC_SESSION_ID" >&2
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "create-session.sh: openssl not found (required for session token generation)" >&2
  exit 1
fi

mkdir -p "$APEX_ACTIVE"

# Discovery-cache global eviction (TTL_DAYS-based). Without this, entries only
# evict per-key on `check` reads of the same prompt; the cache dir grows
# unbounded when prompts are not re-issued. Best-effort; never blocks.
SCRIPT_DIR_PRE_SCAN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "$SCRIPT_DIR_PRE_SCAN/discovery-cache.sh" ]]; then
  bash "$SCRIPT_DIR_PRE_SCAN/discovery-cache.sh" prune 2>/dev/null || true
fi

# Per-worktree isolation: no sibling-overlap scan needed (each apex session
# owns an isolated working tree + index + branch + apex-active dir).
# Issue token, mint worktree below, write manifest, echo token to stdout.
SESSION="$(openssl rand -hex 4)"
MANIFEST="$APEX_ACTIVE/$SESSION.json"

# Resolve claude pid via tree walk (see header doc). Recorded in the manifest
# for admin-apex's stale-run sweep (sweep-stale-runs.sh classifies a sibling
# manifest as orphaned when its recorded pid is dead OR no longer comm==claude).
# Fall back to $PPID only if the walk fails - $PPID is the transient zsh
# subshell when this script runs under `bash` invocation, but it is the best
# signal available when claude is not in the ancestry (non-standard launcher).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PID="$(bash "$SCRIPT_DIR/find-claude-pid.sh" 2>/dev/null)"
if [[ -z "$CLAUDE_PID" || ! "$CLAUDE_PID" =~ ^[0-9]+$ ]]; then
  echo "create-session.sh: find-claude-pid.sh found no claude ancestor; falling back to \$PPID=$PPID (non-standard launcher; manifest.pid may not survive the run)" >&2
  CLAUDE_PID="$PPID"
fi

# Worktree creation (unconditional post-Phase-4): creates
# <main-worktree>/.apex-worktrees/<session> on a fresh apex/<session> branch
# off current HEAD, cd's into it, persists worktree_path/branch/base_branch
# in the manifest. The rest of step 2 (manifest write below) and all
# subsequent /apex steps operate inside the worktree. Integration is owned
# by /apex-merge (skills/apex-merge/SKILL.md).
_WT_TOP="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
_WT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null | sed -e 's,/\.git$,,' -e 's,^\.git$,.,' || echo "")"
_WT_COMMON_RES="$(cd "$_WT_COMMON" 2>/dev/null && pwd -P || echo "$_WT_COMMON")"
_WT_TOP_RES="$(cd "$_WT_TOP" 2>/dev/null && pwd -P || echo "$_WT_TOP")"
if [[ -z "$_WT_TOP_RES" || -z "$_WT_COMMON_RES" ]]; then
  echo "create-session.sh: requires a git repo; refusing to mint worktree" >&2
  exit 1
fi
# Nested-worktree guard: refuse if cwd is already a non-main (secondary)
# worktree (e.g., another apex/<session> worktree). The user must cd to the
# main worktree first; nesting apex worktrees produces unowned branch graphs.
if [[ "$_WT_TOP_RES" != "$_WT_COMMON_RES" ]]; then
  echo "create-session.sh: refuses to start from a secondary worktree (cwd=$_WT_TOP_RES, main=$_WT_COMMON_RES); cd to the main worktree and retry" >&2
  exit 1
fi
BASE_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo "")"
if [[ -z "$BASE_BRANCH" ]]; then
  echo "create-session.sh: requires HEAD on a branch (detached HEAD detected); checkout a branch first" >&2
  exit 1
fi
WORKTREE_PATH="$_WT_COMMON_RES/.apex-worktrees/$SESSION"
BRANCH="apex/$SESSION"
if [[ -e "$WORKTREE_PATH" ]]; then
  echo "create-session.sh: worktree dir already exists at $WORKTREE_PATH; run 'git worktree remove $WORKTREE_PATH --force' first" >&2
  exit 1
fi
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "create-session.sh: branch $BRANCH already exists; run 'git branch -D $BRANCH' first" >&2
  exit 1
fi
if ! git worktree add -b "$BRANCH" "$WORKTREE_PATH" HEAD >/dev/null 2>&1; then
  echo "create-session.sh: git worktree add failed for $WORKTREE_PATH on branch $BRANCH" >&2
  exit 1
fi
cd "$WORKTREE_PATH"
APEX_ACTIVE=".claude-tmp/apex-active"
mkdir -p "$APEX_ACTIVE"
MANIFEST="$APEX_ACTIVE/$SESSION.json"

# Worktree dep bootstrap (Layer 1): symlink gitignored cache dirs + .env files
# from the main worktree. `git worktree add` only checks out tracked files;
# node_modules / .venv / target / .next / .gradle / .nuxt / .turbo / .env* are
# absent, so step-10 verify-build fails on missing deps and burns fix-loop
# tokens on a "you didn't pnpm install" problem. Cost = zero; transparent.
# .env symlink is the documented exception to the global "never read .env"
# rule (per apex-core.md Conventions) - symlinking via `ln -s` is not reading.
# Closed list at root only - monorepos with app-level node_modules use the
# Layer 2 hook below.
for _cache in node_modules .venv venv target .gradle .next .nuxt .turbo; do
  if [[ -e "$_WT_COMMON_RES/$_cache" && ! -e "$_cache" ]]; then
    ln -s "$_WT_COMMON_RES/$_cache" "$_cache" 2>/dev/null || true
  fi
done
shopt -s nullglob
for _envf in "$_WT_COMMON_RES"/.env "$_WT_COMMON_RES"/.env.*; do
  [[ -f "$_envf" ]] || continue
  _envbn="$(basename "$_envf")"
  [[ -e "$_envbn" ]] && continue
  ln -s "$_envf" "$_envbn" 2>/dev/null || true
done
shopt -u nullglob

# Worktree dep bootstrap (Layer 2): optional project bootstrap hook. Projects
# that need codegen / install / DB seed beyond a cache symlink wire
# `docs/apex-bootstrap.sh` (preferred) or `.apex/bootstrap.sh`. Invoked from
# the worktree root with no args; non-zero exit is non-fatal (logged to
# stderr) so a missing language toolchain does not block session mint -
# step-10 verify-build surfaces the real failure with full context.
for _hook in docs/apex-bootstrap.sh .apex/bootstrap.sh; do
  if [[ -f "$_hook" ]]; then
    echo "create-session.sh: running project bootstrap hook $_hook" >&2
    bash "$_hook" >&2 || echo "create-session.sh: bootstrap hook $_hook exited non-zero (continuing)" >&2
    break
  fi
done

# Manifest write: 6 required fields. Python (not printf) so values pass
# through json.dumps and survive any future quoting weirdness in BASE_BRANCH.
python3 - "$MANIFEST" "$SESSION" "$CLAUDE_PID" "$CC_SESSION_ID" "$WORKTREE_PATH" "$BRANCH" "$BASE_BRANCH" <<'PY'
import json, sys
path, sess, pid, cc, wt, br, base = sys.argv[1:8]
m = {
    "session": sess,
    "pid": int(pid),
    "cc_session_id": cc,
    "worktree_path": wt,
    "branch": br,
    "base_branch": base,
}
with open(path, "w", encoding="utf-8") as f:
    f.write(json.dumps(m) + "\n")
PY

# Producer-validates-before-write: shells the manifest through validate-json.sh
# (jsonschema-fallback is parse-only when the lib is missing, but the call
# point uniformly enforces the rule across script + inline-LLM producers).
# validate-json.sh ships in this script's dir; missing = corrupt install -> hard fail.
# (SCRIPT_DIR resolved above for find-claude-pid.sh; reuse.)
if [[ ! -x "$SCRIPT_DIR/validate-json.sh" ]]; then
  rm -f "$MANIFEST"
  echo "create-session.sh: validate-json.sh missing or non-executable at $SCRIPT_DIR (install corruption); aborting" >&2
  exit 1
fi
if ! "$SCRIPT_DIR/validate-json.sh" manifest.schema.json "$MANIFEST"; then
  rm -f "$MANIFEST"
  echo "create-session.sh: manifest failed schema validation; aborting" >&2
  exit 1
fi

echo "$SESSION"
exit 0
