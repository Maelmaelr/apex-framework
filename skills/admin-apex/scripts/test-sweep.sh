#!/usr/bin/env bash
# Purpose: regression coverage for the orphan/stale sweep scripts -
#          skills/apex/scripts/sweep-orphan-artifacts.sh and
#          skills/admin-apex/scripts/sweep-stale-runs.sh.
# Spec: skills/admin-apex/SKILL.md task 8; apex-core.md "sweep-orphan-artifacts.sh".
#
# Why a dedicated suite (the bug test-apex-scripts.sh could NOT catch):
#   A heredoc body nested in a process substitution - `done < <(python3 ... <<PY
#   ... PY)` - is mis-scanned by bash 3.2 (macOS /bin/bash 3.2.57) at RUNTIME:
#   it aborts "bad substitution" and the while-read loop reaps nothing, exit 0,
#   silently swallowed by `2>/dev/null || true` callers. The failure is
#   content-dependent (the heredoc body's paren balance) and `bash -n` parses
#   it cleanly, so check_bash (bash -n) in test-apex-scripts.sh is blind to it.
#   The only faithful guard is to RUN the script under bash 3.2 and assert it
#   actually sweeps - plus a portable static guard that forbids reintroducing
#   the construct (apex-improve bddf6173: this was the root cause of the
#   ~19-orphan deferred-findings leak; sweep-orphan was fixed to a pipe, but the
#   identical construct lingered in sweep-stale-runs.sh working only by paren-luck).
#
# Kept separate from test-apex-scripts.sh (past the 400-line file-health cap),
# which folds this suite's result. Also runnable standalone. Mirrors the
# test-session-end-worktree.sh / test-workflow-scripts.sh sibling-suite pattern.
#
# Exit codes: 0 all cases pass (bash-3.2 functional cases SKIP-as-pass when no
# 3.x bash is present); 1 one or more failed.

set -uo pipefail
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$HOME/.claude}"
cd "$REPO_ROOT"
pass=0
failed=0

# Locate a bash whose major version is 3 (the failing interpreter). Prefer
# /bin/bash (macOS system bash, typically 3.2.57). Empty stdout + rc 1 when no
# 3.x bash exists (Linux CI = bash 4/5) -> the functional cases SKIP-as-pass.
find_bash3() {
  local cand maj
  for cand in /bin/bash "$(command -v bash 2>/dev/null)"; do
    [[ -x "$cand" ]] || continue
    maj=$("$cand" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null)
    [[ "$maj" == "3" ]] && { echo "$cand"; return 0; }
  done
  return 1
}

# Mint a guaranteed-dead PID (fork a no-op subshell, reap it) - mirrors
# test-apex-scripts.sh fixture 4c.
dead_pid() { local p; ( true ) & p=$!; wait "$p" 2>/dev/null || true; echo "$p"; }

record() {
  local label="$1" rc="$2"
  if [[ "$rc" -eq 0 ]]; then
    echo "PASS case $label"; pass=$((pass + 1))
  else
    echo "FAIL case $label (exit=$rc)" >&2; failed=$((failed + 1))
  fi
}

# --- Static guard (portable; runs on any bash) -----------------------------
# Forbid `<(... <<HEREDOC ...)` anywhere in the apex/admin-apex script set.
# Same-line detection covers the realistic anti-pattern (the heredoc opener sits
# on the `<(` line in every real occurrence); a multi-line split is not flagged.
antipattern_guard() {
  python3 - "$REPO_ROOT" <<'PY'
import glob, os, re, sys
root = sys.argv[1]
pat = re.compile(r'<\(.*<<-?\s*[\'"]?\w')   # process-sub open + heredoc opener, same line
bad = []
files = (glob.glob(os.path.join(root, "skills/apex/scripts/*.sh")) +
         glob.glob(os.path.join(root, "skills/admin-apex/scripts/*.sh")))
for f in sorted(files):
    for i, line in enumerate(open(f, encoding="utf-8"), 1):
        stripped = line.lstrip()
        if stripped.startswith("#"):   # comment lines may legitimately name the anti-pattern
            continue
        if "<<<" in line:
            continue
        if pat.search(line):
            bad.append(f"{os.path.relpath(f, root)}:{i}: {line.strip()}")
if bad:
    sys.stderr.write("heredoc-in-process-substitution anti-pattern (bash-3.2-fatal):\n")
    for b in bad:
        sys.stderr.write("  " + b + "\n")
    sys.exit(1)
sys.exit(0)
PY
}
antipattern_guard 2>/tmp/test-sweep-antipattern.err
record "static guard: no heredoc-in-process-substitution" $?
[[ -s /tmp/test-sweep-antipattern.err ]] && sed 's/^/    /' /tmp/test-sweep-antipattern.err >&2

# --- Functional: sweep-orphan-artifacts.sh under bash 3.2 ------------------
# Pre-fix this aborted "bad substitution" and reaped nothing. The pipe form
# must reap the orphan, keep the manifested sibling, and emit no bad-subst.
sweep_orphan_reap_b3() {
  local b3="$1" sb err rc=0
  sb=$(mktemp -d)
  printf 'x\n' > "$sb/aaaabbbb-inventory.json"           # orphan: no {token}.json manifest -> reap
  printf 'z\n' > "$sb/eeeeffff-deferred-findings.json"   # orphan backlog -> EXEMPT, must survive
  printf '{}\n' > "$sb/ccccdddd.json"                     # manifest present
  printf 'y\n' > "$sb/ccccdddd-inventory.json"            # owned sibling -> must survive
  python3 -c "import os,time;ts=time.time()-90000;[os.utime('$sb/'+f,(ts,ts)) for f in os.listdir('$sb')]"
  err=$("$b3" "$REPO_ROOT/skills/apex/scripts/sweep-orphan-artifacts.sh" --dir "$sb" --age-hours 24 2>&1 >/dev/null)
  printf '%s' "$err" | grep -q 'bad substitution' && rc=1   # the 3.2 procsub failure signature
  [[ -e "$sb/aaaabbbb-inventory.json" ]] && rc=1           # non-exempt orphan must be reaped
  [[ -e "$sb/eeeeffff-deferred-findings.json" ]] || rc=1   # backlog must survive (never reaped)
  [[ -e "$sb/ccccdddd.json" ]] || rc=1                      # manifest must survive
  [[ -e "$sb/ccccdddd-inventory.json" ]] || rc=1            # owned sibling must survive
  rm -rf "$sb"
  return $rc
}

# --- Functional: sweep-stale-runs.sh under bash 3.2 -----------------------
sweep_stale_reap_b3() {
  local b3="$1" sb aa err rc=0 dp
  sb=$(mktemp -d); aa="$sb/admin-apex-active"; mkdir -p "$aa"
  dp=$(dead_pid)
  printf '{"run":"deadbe09","cc_session_id":"X","pid":%s,"producer":"admin-apex"}\n' "$dp" > "$aa/deadbe09.json"
  printf 'inv\n' > "$aa/deadbe09-inventory.json"
  python3 -c "import os,time;ts=time.time()-200;[os.utime('$aa/'+f,(ts,ts)) for f in os.listdir('$aa')]"
  err=$(APEX_ADMIN_ACTIVE_DIR="$aa" "$b3" "$REPO_ROOT/skills/admin-apex/scripts/sweep-stale-runs.sh" 2>&1 >/dev/null)
  printf '%s' "$err" | grep -q 'bad substitution' && rc=1   # procsub failure signature
  [[ -e "$aa/deadbe09.json" ]] && rc=1                      # dead-pid manifest must be cleaned
  rm -rf "$sb"
  return $rc
}

BASH3="$(find_bash3 || true)"
if [[ -n "$BASH3" ]]; then
  echo "test-sweep.sh: bash-3.x functional cases using $BASH3 ($("$BASH3" -c 'echo $BASH_VERSION'))"
  sweep_orphan_reap_b3 "$BASH3"; record "sweep-orphan reaps under bash 3.2 (no bad-substitution)" $?
  sweep_stale_reap_b3 "$BASH3"; record "sweep-stale reaps under bash 3.2 (no bad-substitution)" $?
else
  echo "SKIP bash-3.x functional cases (no 3.x bash found; static guard still enforced)"
fi

# --- sweep-stale PID-classification logic (default bash; migrated 4c/4d) ---
# Dead PID -> manifest + siblings cleaned. (High-value: a false positive here
# would orphan everything; correctness is non-negotiable.)
sweep_stale_dead_pid_case() {
  local tmp; tmp=$(mktemp -d)
  ( cd "$tmp" \
    && mkdir -p .claude-tmp/admin-apex-active \
    && printf '{"run":"deadbe03","cc_session_id":"X","pid":%d,"producer":"admin-apex"}\n' "$(dead_pid)" \
         > .claude-tmp/admin-apex-active/deadbe03.json \
    && printf 'inv\n' > .claude-tmp/admin-apex-active/deadbe03-inventory.json \
    && python3 -c "
import os,time
ts=time.time()-120
[os.utime('.claude-tmp/admin-apex-active/'+f,(ts,ts)) for f in os.listdir('.claude-tmp/admin-apex-active')]
" \
    && APEX_ADMIN_ACTIVE_DIR="$tmp/.claude-tmp/admin-apex-active" \
       bash "$REPO_ROOT/skills/admin-apex/scripts/sweep-stale-runs.sh" \
    && [[ ! -e .claude-tmp/admin-apex-active/deadbe03.json ]] \
    && [[ ! -e .claude-tmp/admin-apex-active/deadbe03-inventory.json ]] )
  local rc=$?; rm -rf "$tmp"; return $rc
}
sweep_stale_dead_pid_case; record "sweep-stale dead-pid cleaned (default bash)" $?

# Manifest WITHOUT a pid field -> SKIPPED (legacy graceful-degradation contract).
sweep_stale_no_pid_case() {
  local tmp; tmp=$(mktemp -d)
  ( cd "$tmp" \
    && mkdir -p .claude-tmp/admin-apex-active \
    && printf '{"run":"deadbe04","cc_session_id":"X","producer":"admin-apex"}\n' \
         > .claude-tmp/admin-apex-active/deadbe04.json \
    && APEX_ADMIN_ACTIVE_DIR="$tmp/.claude-tmp/admin-apex-active" \
       bash "$REPO_ROOT/skills/admin-apex/scripts/sweep-stale-runs.sh" \
    && [[ -f .claude-tmp/admin-apex-active/deadbe04.json ]] )
  local rc=$?; rm -rf "$tmp"; return $rc
}
sweep_stale_no_pid_case; record "sweep-stale no-pid preserved (default bash)" $?

echo "test-sweep.sh: pass=$pass fail=$failed"
[[ $failed -eq 0 ]] || exit 1
exit 0
