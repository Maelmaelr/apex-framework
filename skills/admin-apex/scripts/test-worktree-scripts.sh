#!/usr/bin/env bash
# Purpose: fixture suite for the /apex fenced-dynamic session scripts
#          (mint-worktree.sh + worktree-fence-hook.sh). Sibling of
#          test-apex-scripts.sh (that harness is at the file-health cap);
#          invoked from there and folded into its totals.
#
# Exit codes: 0 all fixtures passed; 1 one or more failed (details on stderr).

set -uo pipefail

REPO_ROOT="${CLAUDE_PROJECT_DIR:-$HOME/.claude}"
failed=0
pass=0

check() {
  local label="$1" expected="$2" got="$3"
  if [[ "$got" == "$expected" ]]; then
    echo "PASS fixture $label (exit=$got)"
    pass=$((pass + 1))
  else
    { echo "FAIL fixture $label"; echo "    expected exit=$expected, got exit=$got"; } >&2
    failed=$((failed + 1))
  fi
}

run_fixture() {
  local label="$1" expected="$2" got
  shift 2
  local tmp; tmp=$(mktemp -d)
  ( cd "$tmp" && "$@" >/dev/null 2>&1 )
  got=$?
  rm -rf "$tmp"
  check "$label" "$expected" "$got"
}

# 1. mint-worktree.sh: refuses a non-git cwd (exit 1, nothing minted).
run_fixture "mint-worktree.sh non-git-cwd" 1 \
  bash "$REPO_ROOT/skills/apex/scripts/mint-worktree.sh"

# 2. mint-worktree.sh happy path: git sandbox -> exit 0, 8-hex session on
#    stdout, worktree dir + branch + manifest all minted.
mint_worktree_happy_fixture() {
  git init -q -b main . >/dev/null
  printf '.claude-tmp/\n.apex-worktrees/\n' > .gitignore
  git -c user.email=t@t -c user.name=t add .gitignore >/dev/null
  git -c user.email=t@t -c user.name=t commit -q -m init >/dev/null
  local out
  out=$(bash "$REPO_ROOT/skills/apex/scripts/mint-worktree.sh") || return 1
  [[ "$out" =~ ^[0-9a-f]{8}$ ]] || return 1
  [[ -d ".apex-worktrees/$out" ]] || return 1
  git show-ref --verify --quiet "refs/heads/apex/$out" || return 1
  [[ -f ".apex-worktrees/$out/.claude-tmp/apex-active/$out.json" ]] || return 1
  return 0
}
run_fixture "mint-worktree.sh happy-path" 0 mint_worktree_happy_fixture

# 3. mint-worktree.sh: detached HEAD -> exit 1 (needs a branch to record).
mint_worktree_detached_fixture() {
  git init -q -b main . >/dev/null
  printf 'x\n' > f
  git -c user.email=t@t -c user.name=t add f >/dev/null
  git -c user.email=t@t -c user.name=t commit -q -m init >/dev/null
  git checkout -q --detach HEAD
  bash "$REPO_ROOT/skills/apex/scripts/mint-worktree.sh"
}
run_fixture "mint-worktree.sh detached-head" 1 mint_worktree_detached_fixture

# 4. worktree-fence-hook.sh: cwd outside a worktree -> allow (fail-open).
fence_outside_fixture() {
  local out
  out=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"/etc/hosts"}}' \
    | bash "$REPO_ROOT/skills/apex/scripts/worktree-fence-hook.sh") || return 1
  [[ "$out" == *'"allow"'* ]]
}
run_fixture "worktree-fence-hook.sh outside-allow" 0 fence_outside_fixture

# 5. worktree-fence-hook.sh: inside a worktree, absolute target outside the
#    worktree root -> deny; relative target -> allow; absolute target inside
#    the worktree root -> allow.
fence_boundary_fixture() {
  local hook="$REPO_ROOT/skills/apex/scripts/worktree-fence-hook.sh" out
  mkdir -p .apex-worktrees/feed0001/sub
  out=$(cd .apex-worktrees/feed0001/sub \
    && printf '{"tool_name":"Edit","tool_input":{"file_path":"/etc/hosts"}}' \
    | bash "$hook") || return 1
  [[ "$out" == *'"deny"'* ]] || return 1
  out=$(cd .apex-worktrees/feed0001/sub \
    && printf '{"tool_name":"Edit","tool_input":{"file_path":"rel/inside.txt"}}' \
    | bash "$hook") || return 1
  [[ "$out" == *'"allow"'* ]] || return 1
  local inside="$PWD/.apex-worktrees/feed0001/deep/file.txt"
  out=$(cd .apex-worktrees/feed0001/sub \
    && printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$inside" \
    | bash "$hook") || return 1
  [[ "$out" == *'"allow"'* ]] || return 1
  return 0
}
run_fixture "worktree-fence-hook.sh boundary" 0 fence_boundary_fixture

echo ""
echo "test-worktree-scripts.sh: pass=$pass fail=$failed"
[[ $failed -eq 0 ]] || exit 1
exit 0
