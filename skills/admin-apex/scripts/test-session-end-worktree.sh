#!/usr/bin/env bash
# Purpose: regression coverage for skills/apex/scripts/session-end-hook.sh
#          sweep_stale_worktrees - the SessionEnd reaper for sibling worktrees.
# Spec: skills/admin-apex/SKILL.md task 8; apex-core.md "session-end-hook.sh".
#
# Two SessionEnd cases the cc_session_id-matched cleanup path does NOT cover:
#   - sibling-reap: a manifest-present worktree whose owning session is no longer
#     a live claude AND whose branch is fully merged (clean + no commits past
#     base) is removed, even though its cc_session_id != the ending session. This
#     is the sole reaper for a worktree integrated outside /apex-merge (or whose
#     /apex-merge step-5 cleanup was interrupted).
#   - sibling-preserve: a dead-owner worktree with commits past base (un-integrated
#     work) is KEPT - the reaper delegates to cleanup-session.sh, which preserves
#     it (awaiting /apex-merge). Guards the reaper against deleting unmerged work.
#
# Kept separate from test-apex-scripts.sh (past the 400-line file-health cap),
# which folds this suite's result. Also runnable standalone. Mirrors the
# test-workflow-scripts.sh / test-audit-detectors.sh sibling-suite pattern.
#
# Exit codes: 0 all cases pass (or git absent -> SKIP); 1 one or more failed.

set -uo pipefail
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$HOME/.claude}"
cd "$REPO_ROOT"
HOOK="$REPO_ROOT/skills/apex/scripts/session-end-hook.sh"
pass=0
failed=0

if ! command -v git >/dev/null 2>&1; then
  echo "SKIP test-session-end-worktree.sh (git not installed)"
  exit 0
fi

# Mint a guaranteed-dead PID (fork a no-op subshell, reap it) - mirrors
# test-apex-scripts.sh fixture 4c. A dead owner pid is the dominant production
# case (the claude process that owned the session has exited).
dead_pid() { local p; ( true ) & p=$!; wait "$p" 2>/dev/null || true; echo "$p"; }

# Seed a git repo (cwd) with one apex worktree, no manifest. Echoes worktree path.
seed_repo_worktree() {
  local token="$1" wt=".apex-worktrees/$1"
  git init -q -b main . >/dev/null
  printf '.claude-tmp/\n.apex-worktrees/\n' > .gitignore
  git -c user.email=t@t -c user.name=t add .gitignore >/dev/null
  git -c user.email=t@t -c user.name=t commit -q -m init >/dev/null
  git worktree add -q -b "apex/$token" "$wt" HEAD >/dev/null
  mkdir -p "$wt/.claude-tmp/apex-active"
  echo "$wt"
}

# Seed with a pid-carrying manifest (legacy/admin schema). Echoes worktree path.
seed_worktree() {
  local token="$1" pid="$2" sid="$3" wt
  wt=$(seed_repo_worktree "$token")
  local fmt='{"session":"%s","pid":%s,"cc_session_id":"%s",'
  fmt+='"worktree_path":"%s","branch":"apex/%s","base_branch":"main"}\n'
  printf "$fmt" "$token" "$pid" "$sid" "$PWD/$wt" "$token" \
    > "$wt/.claude-tmp/apex-active/$token.json"
  echo "$wt"
}

# Seed with a pid-less manifest (/apex mint schema). Echoes worktree path.
seed_worktree_pidless() {
  local token="$1" wt
  wt=$(seed_repo_worktree "$token")
  printf '{"session":"%s","branch":"apex/%s","base_branch":"main","worktree_path":"%s"}\n' \
    "$token" "$token" "$PWD/$wt" \
    > "$wt/.claude-tmp/apex-active/$token.json"
  echo "$wt"
}

# Fire the hook in SessionEnd mode with a session_id matching no manifest, so
# ONLY the sweep_stale_worktrees path runs (no cc_session_id-matched cleanup).
fire_sessionend_nonmatch() {
  CLAUDE_PROJECT_DIR="$PWD" \
    bash -c 'printf "{\"session_id\":\"NONMATCH-CC\"}" | bash "$1"' _ "$HOOK"
}

# Run one case in an isolated temp git repo; $1=label, $2=fixture fn.
run_case() {
  local label="$1" fn="$2" tmp got
  tmp=$(mktemp -d)
  ( cd "$tmp" && "$fn" ); got=$?
  rm -rf "$tmp"
  if [[ "$got" -eq 0 ]]; then
    echo "PASS case $label"; pass=$((pass + 1))
  else
    echo "FAIL case $label (exit=$got)" >&2; failed=$((failed + 1))
  fi
}

sibling_reap_case() {
  local wt; wt=$(seed_worktree cafef00d "$(dead_pid)" OTHER-CC)
  fire_sessionend_nonmatch
  # Merged-clean (no commits past base) dead-owner sibling -> reaped.
  [[ -d "$wt" ]] && return 1
  git show-ref --verify --quiet "refs/heads/apex/cafef00d" && return 1
  return 0
}

sibling_preserve_case() {
  local wt; wt=$(seed_worktree c0ffee11 "$(dead_pid)" OTHER-CC)
  # A commit past base -> cleanup-session.sh keeps it (un-integrated work).
  ( cd "$wt" && printf 'x\n' > work.txt \
    && git -c user.email=t@t -c user.name=t add work.txt >/dev/null \
    && git -c user.email=t@t -c user.name=t commit -q -m work >/dev/null )
  fire_sessionend_nonmatch
  # Commits-past-base dead-owner sibling -> preserved.
  [[ -d "$wt" ]] || return 1
  git show-ref --verify --quiet "refs/heads/apex/c0ffee11" || return 1
  return 0
}

# pid-less (/apex mint schema) manifests: liveness is unknowable, so the reaper
# age-gates on manifest mtime (APEX_REAP_AGE_HOURS, default 24). A fresh clean
# worktree is a LIVE session's mint-to-first-edit window - never reap it.
pidless_young_preserve_case() {
  local wt; wt=$(seed_worktree_pidless beef0001)
  fire_sessionend_nonmatch
  [[ -d "$wt" ]] || return 1
  git show-ref --verify --quiet "refs/heads/apex/beef0001" || return 1
  return 0
}

# Past the age gate, a clean no-commits pid-less worktree is a stale leftover
# and IS reaped (mtime backdated 25h; cheaper than a 24h wait, same contract).
pidless_old_reap_case() {
  local wt; wt=$(seed_worktree_pidless beef0002)
  python3 -c "
import os, sys, time
ts = time.time() - 25 * 3600
os.utime(sys.argv[1], (ts, ts))
" "$wt/.claude-tmp/apex-active/beef0002.json"
  fire_sessionend_nonmatch
  [[ -d "$wt" ]] && return 1
  git show-ref --verify --quiet "refs/heads/apex/beef0002" && return 1
  return 0
}

run_case "sibling-reap (merged-clean dead-owner removed)" sibling_reap_case
run_case "sibling-preserve (commits-past-base dead-owner kept)" sibling_preserve_case
run_case "pidless-young-preserve (live mint window kept)" pidless_young_preserve_case
run_case "pidless-old-reap (stale pid-less leftover removed)" pidless_old_reap_case

echo "test-session-end-worktree.sh: pass=$pass fail=$failed"
[[ $failed -eq 0 ]] || exit 1
exit 0
