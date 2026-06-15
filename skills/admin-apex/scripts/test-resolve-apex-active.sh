#!/usr/bin/env bash
# Purpose: fixtures for skills/apex/scripts/resolve-apex-active.sh (WS0 of the
#          worktree-marker-leak fix). Asserts the resolver prints the absolute
#          worktree-resident apex-active dir from a manifest's worktree_path, and
#          fails CLOSED (non-zero, no stdout) when no manifest / worktree_path is
#          found - never a main-tree fallback.
# Spec: skills/apex/scripts/resolve-apex-active.sh header; cluster
#       worktree-marker-leak.
#
# Kept separate from test-apex-scripts.sh (at the file-health cap), which invokes
# this one and folds the result. Also runnable standalone.
#
# Exit codes: 0 all fixtures pass; 1 one or more failed.

set -uo pipefail
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$HOME/.claude}"
RESOLVER="$REPO_ROOT/skills/apex/scripts/resolve-apex-active.sh"
TOKEN="feedf00d"
pass=0
failed=0

check() {  # label expected_exit expected_stdout actual_exit actual_stdout
  local label="$1" exp_rc="$2" exp_out="$3" rc="$4" out="$5"
  if [[ "$rc" == "$exp_rc" && "$out" == "$exp_out" ]]; then
    echo "PASS $label (exit=$rc)"; pass=$((pass + 1))
  else
    { echo "FAIL $label"; echo "    expected exit=$exp_rc stdout='$exp_out'; got exit=$rc stdout='$out'"; } >&2
    failed=$((failed + 1))
  fi
}

# 1. CWD-local manifest with worktree_path -> absolute apex-active dir, exit 0.
cwd_local_fixture() {
  local tmp; tmp=$(mktemp -d)
  local wt="$tmp/.apex-worktrees/$TOKEN"
  mkdir -p "$wt/.claude-tmp/apex-active"
  printf '{"session":"%s","pid":1,"cc_session_id":"X","worktree_path":"%s","branch":"apex/%s","base_branch":"main"}\n' \
    "$TOKEN" "$wt" "$TOKEN" > "$wt/.claude-tmp/apex-active/$TOKEN.json"
  local out rc
  out=$( cd "$wt" && bash "$RESOLVER" "$TOKEN" 2>/dev/null ); rc=$?
  rm -rf "$tmp"
  check "cwd-local manifest -> worktree path" 0 "$wt/.claude-tmp/apex-active" "$rc" "$out"
}

# 2. Worktree-scan fallback: cwd = main tree, manifest under .apex-worktrees/.
worktree_scan_fixture() {
  local tmp; tmp=$(mktemp -d)
  ( cd "$tmp" && git init -q -b main . && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init ) >/dev/null 2>&1
  local wt="$tmp/.apex-worktrees/$TOKEN"
  mkdir -p "$wt/.claude-tmp/apex-active"
  printf '{"session":"%s","pid":1,"cc_session_id":"X","worktree_path":"%s","branch":"apex/%s","base_branch":"main"}\n' \
    "$TOKEN" "$wt" "$TOKEN" > "$wt/.claude-tmp/apex-active/$TOKEN.json"
  local out rc
  out=$( cd "$tmp" && bash "$RESOLVER" "$TOKEN" 2>/dev/null ); rc=$?
  rm -rf "$tmp"
  check "worktree-scan fallback -> worktree path" 0 "$wt/.claude-tmp/apex-active" "$rc" "$out"
}

# 3. No manifest anywhere -> fail closed (exit 2, empty stdout). NEVER a path.
no_manifest_fixture() {
  local tmp; tmp=$(mktemp -d)
  local out rc
  out=$( cd "$tmp" && bash "$RESOLVER" "$TOKEN" 2>/dev/null ); rc=$?
  rm -rf "$tmp"
  check "no manifest -> fail closed (no stdout)" 2 "" "$rc" "$out"
}

# 4. Manifest present but worktree_path absent -> fail closed (exit 2).
missing_wt_field_fixture() {
  local tmp; tmp=$(mktemp -d)
  mkdir -p "$tmp/.claude-tmp/apex-active"
  printf '{"session":"%s","pid":1,"cc_session_id":"X"}\n' "$TOKEN" \
    > "$tmp/.claude-tmp/apex-active/$TOKEN.json"
  local out rc
  out=$( cd "$tmp" && bash "$RESOLVER" "$TOKEN" 2>/dev/null ); rc=$?
  rm -rf "$tmp"
  check "manifest without worktree_path -> fail closed" 2 "" "$rc" "$out"
}

# 5. Bad token shape -> invocation error (exit 1).
bad_token_fixture() {
  local out rc
  out=$( bash "$RESOLVER" NOTAHEX 2>/dev/null ); rc=$?
  check "bad token -> exit 1" 1 "" "$rc" "$out"
}

cwd_local_fixture
worktree_scan_fixture
no_manifest_fixture
missing_wt_field_fixture
bad_token_fixture

echo ""
echo "test-resolve-apex-active.sh: pass=$pass fail=$failed"
[[ $failed -eq 0 ]] || exit 1
exit 0
