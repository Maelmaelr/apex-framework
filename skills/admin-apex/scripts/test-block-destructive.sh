#!/usr/bin/env bash
# Purpose: fixtures for skills/apex/scripts/block-destructive-hook.sh - locks
#          the deny/allow verdict table AND two structural regressions:
#          (a) no backtick anywhere in the hook file (a double-quoted python
#              block once command-substituted its own comments, executing
#              git stash apply / git branch on EVERY Bash call);
#          (b) the hook is side-effect-free: running it inside a repo with a
#              pre-existing stash must not mutate the working tree.
# Spec: CLAUDE.md Git Safety + Security (Non-Negotiable); hook header.
#
# Sibling of test-apex-scripts.sh (400-line file-health cap), invoked from
# there and folded into its totals. Also runnable standalone.
#
# Exit codes: 0 all fixtures pass; 1 one or more failed.

set -uo pipefail
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$HOME/.claude}"
HOOK="$REPO_ROOT/skills/apex/scripts/block-destructive-hook.sh"
pass=0
failed=0

verdict() {  # command-string [cwd]; prints allow|deny
  local c="$1" cwd="${2:-$PWD}"
  ( cd "$cwd" && printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
      "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$c")" \
    | bash "$HOOK" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecision"])' \
      2>/dev/null )
}

check() {  # expected command-string [cwd]
  local expected="$1" c="$2" cwd="${3:-$PWD}" got
  got=$(verdict "$c" "$cwd")
  if [[ "$got" == "$expected" ]]; then
    echo "PASS [$expected] $c"; pass=$((pass + 1))
  else
    { echo "FAIL $c"; echo "    expected=$expected got=$got"; } >&2
    failed=$((failed + 1))
  fi
}

# (a) structural: zero backticks in the hook file (command-substitution guard).
if grep -q '`' "$HOOK"; then
  { echo "FAIL backtick-free hook file"; grep -n '`' "$HOOK" | sed 's/^/    /'; } >&2
  failed=$((failed + 1))
else
  echo "PASS backtick-free hook file"; pass=$((pass + 1))
fi

# (b) behavioral: hook run is side-effect-free in a repo with a user stash,
#     and the stash gate still denies in a MULTI-branch repo (a broken parser
#     once fail-opened exactly there).
side_effect_fixture() {
  local tmp; tmp=$(mktemp -d)
  (
    cd "$tmp" || exit 1
    git init -q -b main . && git config user.email t@t && git config user.name t
    echo one > f.txt && git add f.txt && git commit -qm init
    git branch -q b1 && git branch -q b2
    echo two > f.txt && git stash push -qm demo
    printf '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}' \
      | bash "$HOOK" >/dev/null 2>&1
    [[ -z "$(git status --porcelain)" ]] || exit 1
    [[ "$(git stash list | wc -l | tr -d ' ')" == "1" ]] || exit 1
    out=$(printf '{"tool_name":"Bash","tool_input":{"command":"git stash"}}' | bash "$HOOK" 2>/dev/null)
    [[ "$out" == *'"deny"'* ]] || exit 1
  )
  local got=$?
  rm -rf "$tmp"
  if [[ $got -eq 0 ]]; then
    echo "PASS side-effect-free + multi-branch stash deny"; pass=$((pass + 1))
  else
    echo "FAIL side-effect-free + multi-branch stash deny" >&2; failed=$((failed + 1))
  fi
}
side_effect_fixture

# Deny table: baselines + closed bypasses (git prefix options, push force
# forms, rm split flags / absolute targets, .env readers).
check deny 'git checkout -- src/a.ts'
check deny 'git checkout HEAD -- file.ts'
check deny 'git -C /proj checkout -- .'
check deny 'git restore src/'
check deny 'git -C /proj restore src/'
check deny 'git restore --staged --worktree f'
check deny 'git stash'
check deny 'git stash pop'
check deny 'git -C /proj stash'
check deny 'git -c X=Y reset --hard'
check deny 'git reset 725fdcf --hard'
check deny 'git -C /proj clean -fd'
check deny 'git push --force origin main'
check deny 'git push -f origin HEAD'
check deny 'git push --force-with-lease origin feat'
check deny 'git push origin +main'
check deny 'git show HEAD:file.ts > file.ts'
check deny 'git archive HEAD | tar -x'
check deny 'rm -rf /'
check deny 'rm -r -f ~'
check deny 'rm -rf /Users/someone/proj/src'
check deny 'rm -rf ~/dev/oldproj'
check deny 'rm -rf .apex-worktrees/deadbeef'
check deny 'cat .env'
check deny 'base64 .env'
check deny 'cp .env /tmp/e'
check deny 'python3 -c "print(open(\".env\").read())"'
check deny 'echo x && git checkout -- f'

# Allow table: the legit flows /apex + /apex-merge + /apex-git actually run.
check allow 'git status'
check allow 'git commit -m "mention reset --hard in message"'
check allow 'git push origin feature'
check allow 'git push origin --delete apex/deadbeef'
check allow 'git merge --no-ff apex/x -m "Merge apex/x"'
check allow 'git worktree add -b apex/x .apex-worktrees/x HEAD'
check allow 'git worktree remove .apex-worktrees/x'
check allow 'git branch -D apex/deadbeef'
check allow 'git stash list'
check allow 'git checkout -b feat'
check allow 'git restore --staged file.ts'
check allow 'rm -rf node_modules'
check allow 'rm -rf /tmp/foo'
check allow 'rm -rf ~/.claude/tmp/scratch'
check allow 'cat .env.example'
check allow 'cat production.env'
check allow 'bash scripts/deploy.sh'

# Self-teardown guard: worktree removal denied ONLY from inside a worktree cwd.
teardown_tmp=$(mktemp -d)
mkdir -p "$teardown_tmp/.apex-worktrees/deadbeef"
check deny  'git worktree remove .apex-worktrees/deadbeef' "$teardown_tmp/.apex-worktrees/deadbeef"
check deny  'git branch -D apex/deadbeef'                  "$teardown_tmp/.apex-worktrees/deadbeef"
check allow 'git commit -m x'                              "$teardown_tmp/.apex-worktrees/deadbeef"
rm -rf "$teardown_tmp"

echo ""
echo "test-block-destructive.sh: pass=$pass fail=$failed"
[[ $failed -eq 0 ]] || exit 1
exit 0
