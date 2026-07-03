#!/usr/bin/env bash
# /apex: mint a per-session git worktree - keeps only what the fenced-dynamic
# model needs.
#
# Behavior:
#   1. {session} via openssl rand -hex 4.
#   2. git worktree add at <main>/.apex-worktrees/<session>/ on branch
#      apex/<session> off HEAD; cd into it.
#   3. Symlink gitignored dep caches (node_modules/.venv/... + monorepo
#      subpackages) + .env* from the main worktree so verify-build does not
#      fail on missing deps. Run an optional project bootstrap hook.
#   4. Write a MINIMAL manifest {session, branch, base_branch, worktree_path}.
#      /apex-merge reads only base_branch (jq, default main) and derives the
#      worktree from `git worktree list` - so no schema validation, no pid,
#      no cc_session_id. Integration + worktree removal are owned by /apex-merge.
#   5. Arm the session-record fence: write the worktree root to BOTH
#      $APEX_FENCE_DIR/<cc_session_id> and $APEX_FENCE_DIR/pid-<claude-pid>
#      (default dir ~/.claude/tmp/apex-fence/) so worktree-fence-hook.sh +
#      block-destructive-hook.sh enforce the boundary even for unanchored
#      subagents whose cwd never entered the worktree. The pid key survives
#      /clear session-id rotation. Best-effort: neither key resolvable ->
#      fence stays cwd-only. Stale sibling records (worktree gone) swept here.
#   6. Echo {session} to stdout.
#
# Deliberately absent (machinery the fenced-dynamic model does not have):
#   pid (stale-sweep), manifest cc_session_id (SessionEnd sweep), schema
#   validation. The fence record above is the one cc_session_id use: keyed
#   OUTSIDE the manifest, self-healing (hooks drop it when the worktree goes).
#
# Exit codes: 0 ok ({session} on stdout); 1 unrecoverable (bad cwd, no git, etc.)

set -euo pipefail  # bash 3.2-safe (macOS /bin/bash); no bash-4 constructs.

# CWD guards: never run from inside the apex install tree, and (in a git repo)
# only from the git toplevel - the manifest lands under the worktree's
# .claude-tmp and a wrong cwd would strand the session.
_PWD="$(pwd -P)"
_HOME_CLAUDE="$(cd "$HOME/.claude" 2>/dev/null && pwd -P || echo "$HOME/.claude")"
case "$_PWD/" in
  "$_HOME_CLAUDE"/*)
    echo "mint-worktree.sh: refusing to run from inside the apex install tree ($_PWD); cd to the project root" >&2
    exit 1
    ;;
esac

if ! command -v openssl >/dev/null 2>&1; then
  echo "mint-worktree.sh: openssl not found (required for session token)" >&2
  exit 1
fi

_TOP="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
_COMMON="$(git rev-parse --git-common-dir 2>/dev/null | sed -e 's,/\.git$,,' -e 's,^\.git$,.,' || echo "")"
_COMMON_RES="$(cd "$_COMMON" 2>/dev/null && pwd -P || echo "$_COMMON")"
_TOP_RES="$(cd "$_TOP" 2>/dev/null && pwd -P || echo "$_TOP")"
if [[ -z "$_TOP_RES" || -z "$_COMMON_RES" ]]; then
  echo "mint-worktree.sh: requires a git repo; refusing to mint worktree" >&2
  exit 1
fi
# Nested-worktree guard: must start from the main worktree, not a secondary one.
if [[ "$_TOP_RES" != "$_COMMON_RES" ]]; then
  echo "mint-worktree.sh: refuses to start from a secondary worktree (cwd=$_TOP_RES, main=$_COMMON_RES); cd to main" >&2
  exit 1
fi
BASE_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo "")"
if [[ -z "$BASE_BRANCH" ]]; then
  echo "mint-worktree.sh: HEAD is detached; checkout a branch first" >&2
  exit 1
fi

SESSION="$(openssl rand -hex 4)"
WORKTREE_PATH="$_COMMON_RES/.apex-worktrees/$SESSION"
BRANCH="apex/$SESSION"
if [[ -e "$WORKTREE_PATH" ]]; then
  echo "mint-worktree.sh: worktree exists at $WORKTREE_PATH; 'git worktree remove $WORKTREE_PATH --force' first" >&2
  exit 1
fi
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "mint-worktree.sh: branch $BRANCH already exists; 'git branch -D $BRANCH' first" >&2
  exit 1
fi
if ! git worktree add -b "$BRANCH" "$WORKTREE_PATH" HEAD >/dev/null 2>&1; then
  echo "mint-worktree.sh: git worktree add failed for $WORKTREE_PATH on branch $BRANCH" >&2
  exit 1
fi
cd "$WORKTREE_PATH"

# Dep bootstrap: git worktree add only checks out tracked files, so gitignored
# caches + .env* are absent and verify-build would fail on missing deps.
# Symlinking is the documented exception to the never-read-.env rule (ln, not read).
for _cache in node_modules .venv venv target .gradle .next .nuxt .turbo; do
  if [[ -e "$_COMMON_RES/$_cache" && ! -e "$_cache" ]]; then
    ln -s "$_COMMON_RES/$_cache" "$_cache" 2>/dev/null || true
  fi
done
_is_monorepo=0
[[ -f "$_COMMON_RES/pnpm-workspace.yaml" ]] && _is_monorepo=1
if [[ $_is_monorepo -eq 0 && -f "$_COMMON_RES/package.json" ]]; then
  grep -q '"workspaces"' "$_COMMON_RES/package.json" 2>/dev/null && _is_monorepo=1
fi
if [[ $_is_monorepo -eq 1 ]]; then
  shopt -s nullglob
  for _pkgdir in "$_COMMON_RES"/packages/*/ "$_COMMON_RES"/apps/*/ "$_COMMON_RES"/services/*/; do
    [[ -d "$_pkgdir" ]] || continue
    _rel="${_pkgdir#$_COMMON_RES/}"; _rel="${_rel%/}"
    [[ -d "$_rel" ]] || mkdir -p "$_rel" 2>/dev/null || continue
    for _sub in node_modules dist; do
      if [[ -e "$_pkgdir$_sub" && ! -e "$_rel/$_sub" ]]; then
        ln -s "$_pkgdir$_sub" "$_rel/$_sub" 2>/dev/null || true
      fi
    done
  done
  shopt -u nullglob
fi
shopt -s nullglob
for _envf in "$_COMMON_RES"/.env "$_COMMON_RES"/.env.*; do
  [[ -f "$_envf" ]] || continue
  _envbn="$(basename "$_envf")"
  [[ -e "$_envbn" ]] && continue
  ln -s "$_envf" "$_envbn" 2>/dev/null || true
done
shopt -u nullglob

# Optional project bootstrap hook (codegen / install / seed beyond a symlink).
for _hook in docs/apex-bootstrap.sh .apex/bootstrap.sh; do
  if [[ -f "$_hook" ]]; then
    echo "mint-worktree.sh: running project bootstrap hook $_hook" >&2
    bash "$_hook" >&2 || echo "mint-worktree.sh: bootstrap hook $_hook exited non-zero (continuing)" >&2
    break
  fi
done

# Minimal manifest. Python (not printf) so base_branch survives any quoting.
APEX_ACTIVE=".claude-tmp/apex-active"
mkdir -p "$APEX_ACTIVE"
MANIFEST="$APEX_ACTIVE/$SESSION.json"
python3 - "$MANIFEST" "$SESSION" "$BRANCH" "$BASE_BRANCH" "$WORKTREE_PATH" <<'PY'
import json, sys
path, sess, br, base, wt = sys.argv[1:6]
m = {"session": sess, "branch": br, "base_branch": base, "worktree_path": wt}
with open(path, "w", encoding="utf-8") as f:
    f.write(json.dumps(m) + "\n")
PY

# Arm the session-record fence (header step 5). Sweep stale sibling records
# first (their worktree is gone; hooks also self-heal, this keeps the dir lean).
FENCE_DIR="${APEX_FENCE_DIR:-$HOME/.claude/tmp/apex-fence}"
if mkdir -p "$FENCE_DIR" 2>/dev/null; then
  shopt -s nullglob
  for _rec in "$FENCE_DIR"/*; do
    [[ -f "$_rec" ]] || continue
    _wt="$(head -n 1 "$_rec" 2>/dev/null || true)"
    if [[ -z "$_wt" || ! -d "$_wt" ]]; then
      rm -f "$_rec" 2>/dev/null || true
    fi
  done
  shopt -u nullglob
  _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _ARMED=0
  if _CC_SID="$(bash "$_SCRIPT_DIR/get-cc-session-id.sh" 2>/dev/null)" && [[ -n "$_CC_SID" ]]; then
    printf '%s\n' "$WORKTREE_PATH" > "$FENCE_DIR/$_CC_SID" 2>/dev/null && _ARMED=1
  fi
  if _CPID="$(bash "$_SCRIPT_DIR/find-claude-pid.sh" 2>/dev/null)" && [[ -n "$_CPID" ]]; then
    printf '%s\n' "$WORKTREE_PATH" > "$FENCE_DIR/pid-$_CPID" 2>/dev/null && _ARMED=1
  fi
  if [[ "$_ARMED" -eq 0 ]]; then
    echo "mint-worktree.sh: no session id / claude pid resolved; fence stays cwd-only" >&2
  fi
else
  echo "mint-worktree.sh: cannot create $FENCE_DIR; fence stays cwd-only" >&2
fi

echo "$SESSION"
exit 0
