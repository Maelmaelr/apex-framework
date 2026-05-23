#!/usr/bin/env bash
# Purpose: Apex-scoped script + schema syntax / contract check.
# Spec: skills/admin-apex/SKILL.md task 8. Apex script-behavior spec lives in
#       apex-core.md (detailed workflow) + apex-core-overview.md (execution steps).
#
# Runs:
#   - bash -n on every skills/apex/scripts/*.sh AND skills/admin-apex/scripts/*.sh
#   - python3 -m py_compile on every skills/apex/scripts/*.py
#   - jsonschema parse + $id == basename(path) assertion on every
#     skills/apex/schemas/*.json AND skills/admin-apex/schemas/*.json
#
# No project app code, no lint, no test suite. This is the apex-scoped gate.
#
# Output: human-readable PASS / FAIL lines per check, plus a final summary.
#         Failing details written to stderr; orchestrator captures stdout+stderr.
#
# Exit codes:
#   0 - all checks passed
#   1 - one or more checks failed (failing list on stderr)

set -uo pipefail

# admin-apex always operates on the apex framework at ~/.claude.
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$HOME/.claude}"
cd "$REPO_ROOT"

failed=0
pass=0

check_bash() {
  shopt -s nullglob
  local files=("$@")
  shopt -u nullglob
  for f in "${files[@]}"; do
    if bash -n "$f" 2>/dev/null; then
      echo "PASS bash -n $f"
      pass=$((pass + 1))
    else
      {
        echo "FAIL bash -n $f"
        bash -n "$f" 2>&1 | sed 's/^/    /'
      } >&2
      failed=$((failed + 1))
    fi
  done
}

check_py() {
  shopt -s nullglob
  local files=("$@")
  shopt -u nullglob
  for f in "${files[@]}"; do
    if python3 -m py_compile "$f" 2>/dev/null; then
      echo "PASS py_compile $f"
      pass=$((pass + 1))
    else
      {
        echo "FAIL py_compile $f"
        python3 -m py_compile "$f" 2>&1 | sed 's/^/    /'
      } >&2
      failed=$((failed + 1))
    fi
  done
}

check_schemas() {
  shopt -s nullglob
  local files=("$@")
  shopt -u nullglob
  for f in "${files[@]}"; do
    local result
    result=$(F="$f" python3 - <<'PY' 2>&1
import json
import os
import sys

path = os.environ["F"]
basename = os.path.basename(path)
try:
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
except (OSError, json.JSONDecodeError) as e:
    print(f"json-parse-error: {e}")
    sys.exit(1)

sid = doc.get("$id", "")
if sid != basename:
    print(f"id-mismatch: $id={sid!r} basename={basename!r}")
    sys.exit(1)

try:
    import jsonschema  # noqa: F401
    from jsonschema import Draft202012Validator
    Draft202012Validator.check_schema(doc)
except ImportError:
    print("ok-no-jsonschema")
    sys.exit(0)
except Exception as e:
    print(f"schema-invalid: {e}")
    sys.exit(1)
print("ok")
sys.exit(0)
PY
    )
    if [[ $? -eq 0 ]]; then
      echo "PASS schema $f ($result)"
      pass=$((pass + 1))
    else
      {
        echo "FAIL schema $f"
        echo "    $result"
      } >&2
      failed=$((failed + 1))
    fi
  done
}

check_bash skills/apex/scripts/*.sh skills/admin-apex/scripts/*.sh
check_py   skills/apex/scripts/*.py
check_schemas skills/apex/schemas/*.json skills/admin-apex/schemas/*.json

# Fixture tests for v2 scripts that have orchestrator-visible exit-code
# contracts (apex-baseline, apex-conflict-check, cleanup-session, session-end,
# reflect-traces, find-claude-pid). One assertion per script covers the
# critical exit code path the orchestrator reads.
check_fixtures() {
  local label="$1"
  local expected="$2"
  local got="$3"
  if [[ "$got" == "$expected" ]]; then
    echo "PASS fixture $label (exit=$got)"
    pass=$((pass + 1))
  else
    {
      echo "FAIL fixture $label"
      echo "    expected exit=$expected, got exit=$got"
    } >&2
    failed=$((failed + 1))
  fi
}

run_fixture() {
  # $1 = label, $2 = expected exit, rest = command to run inside a temp dir.
  # APEX_ADMIN_ACTIVE_DIR is set to the temp's per-fixture admin-apex-active
  # subdir so admin-apex scripts that anchor at $HOME/.claude/.claude-tmp/...
  # in production resolve to the sandbox during fixtures (production hardcoding
  # is what closes the cwd-pollution bug; the env override is the test seam).
  local label="$1" expected="$2" got
  shift 2
  local tmp; tmp=$(mktemp -d)
  ( cd "$tmp" \
      && APEX_ADMIN_ACTIVE_DIR="$tmp/.claude-tmp/admin-apex-active" \
         "$@" >/dev/null 2>&1 )
  got=$?
  rm -rf "$tmp"
  check_fixtures "$label" "$expected" "$got"
}

# Age mtime of every arg by 120s. Required for fixtures that exercise
# cleanup-run.sh / sweep-stale-runs.sh: those refuse cleanup when the latest
# manifest + {run}-* mtime is < 60s old (in-flight guard, cleanup-run.sh:93).
# Python-based for portability across BSD (macOS) and GNU touch.
age_mtime() {
  python3 -c "
import os, sys, time
ts = time.time() - 120
for p in sys.argv[1:]:
    os.utime(p, (ts, ts))
" "$@"
}

# 1. Each script rejects missing/bad {session} arg.
run_fixture "apex-baseline.sh missing-arg" 1 \
  bash "$REPO_ROOT/skills/apex/scripts/apex-baseline.sh"
run_fixture "bump-version.sh missing-arg" 1 \
  bash "$REPO_ROOT/skills/apex/scripts/bump-version.sh"
run_fixture "bump-version.sh bad-kind" 1 \
  bash "$REPO_ROOT/skills/apex/scripts/bump-version.sh" --kind major

# 3. cleanup-run.sh: idempotent contract (always exit 0; warnings to stderr).
run_fixture "cleanup-run.sh missing-arg" 0 \
  bash "$REPO_ROOT/skills/admin-apex/scripts/cleanup-run.sh"
run_fixture "cleanup-run.sh bad-token" 0 \
  bash "$REPO_ROOT/skills/admin-apex/scripts/cleanup-run.sh" --run BADTOKEN

# 4. session-end-hook.sh: empty stdin -> non-/admin-apex CC session, exit 0.
session_end_empty_stdin_fixture() {
  bash "$REPO_ROOT/skills/admin-apex/scripts/session-end-hook.sh" </dev/null
}
run_fixture "session-end-hook.sh empty-stdin" 0 session_end_empty_stdin_fixture

# 4a. session-end-hook.sh happy path: manifest with cc_session_id X + stdin
#     {session_id:X} -> manifest + siblings removed. Closes regression risk in
#     stdin parsing, the {run}.json vs {run}-*.json name guard, and the
#     cleanup-run.sh dispatch from the hook.
session_end_happy_fixture() {
  mkdir -p .claude-tmp/admin-apex-active
  printf '{"run":"deadbe01","cc_session_id":"FIXTURE-SID","producer":"admin-apex"}\n' \
    > .claude-tmp/admin-apex-active/deadbe01.json
  printf 'inv\n'      > .claude-tmp/admin-apex-active/deadbe01-inventory.json
  printf 'summary\n'  > .claude-tmp/admin-apex-active/deadbe01-summary.md
  age_mtime .claude-tmp/admin-apex-active/deadbe01.json \
            .claude-tmp/admin-apex-active/deadbe01-inventory.json \
            .claude-tmp/admin-apex-active/deadbe01-summary.md
  printf '{"session_id":"FIXTURE-SID"}' \
    | bash "$REPO_ROOT/skills/admin-apex/scripts/session-end-hook.sh"
  # Assert all three artifacts gone (exit 1 if any survives -> fixture fails).
  for f in deadbe01.json deadbe01-inventory.json deadbe01-summary.md; do
    [[ -e ".claude-tmp/admin-apex-active/$f" ]] && return 1
  done
  return 0
}
run_fixture "session-end-hook.sh happy-path" 0 session_end_happy_fixture

# 4b. session-end-hook.sh sibling-preserve: stdin session_id NOT matching any
#     manifest -> all manifests left intact (no cross-session collateral damage).
session_end_sibling_preserve_fixture() {
  mkdir -p .claude-tmp/admin-apex-active
  printf '{"run":"deadbe02","cc_session_id":"OWNED-BY-OTHER","producer":"admin-apex"}\n' \
    > .claude-tmp/admin-apex-active/deadbe02.json
  printf '{"session_id":"UNRELATED-SID"}' \
    | bash "$REPO_ROOT/skills/admin-apex/scripts/session-end-hook.sh"
  [[ -f .claude-tmp/admin-apex-active/deadbe02.json ]] || return 1
  rm -f .claude-tmp/admin-apex-active/deadbe02.json
  return 0
}
run_fixture "session-end-hook.sh sibling-preserve" 0 session_end_sibling_preserve_fixture

# 4c. sweep-stale-runs.sh: manifest with dead PID -> cleaned. Manifest with
#     alive PID + comm=claude -> preserved. Use `: &; pid=$!; wait $!` to mint
#     a guaranteed-dead PID; use $$ as alive (but comm will be "bash", not
#     "claude" - so $$ is treated as stale via comm-mismatch). This means we
#     cannot exercise the "alive + comm=claude -> preserve" branch from inside
#     the test harness without spawning a real claude binary. Test focuses on
#     the dead-PID branch (high-value: false positives in this branch would
#     orphan everything; correctness here is non-negotiable).
sweep_stale_dead_pid_fixture() {
  mkdir -p .claude-tmp/admin-apex-active
  # Mint a guaranteed-dead PID by forking a no-op subshell and waiting on it.
  local dead_pid
  ( true ) &
  dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true
  printf '{"run":"deadbe03","cc_session_id":"X","pid":%d,"producer":"admin-apex"}\n' "$dead_pid" \
    > .claude-tmp/admin-apex-active/deadbe03.json
  printf 'inv\n' > .claude-tmp/admin-apex-active/deadbe03-inventory.json
  age_mtime .claude-tmp/admin-apex-active/deadbe03.json \
            .claude-tmp/admin-apex-active/deadbe03-inventory.json
  bash "$REPO_ROOT/skills/admin-apex/scripts/sweep-stale-runs.sh"
  for f in deadbe03.json deadbe03-inventory.json; do
    [[ -e ".claude-tmp/admin-apex-active/$f" ]] && return 1
  done
  return 0
}
run_fixture "sweep-stale-runs.sh dead-pid-cleaned" 0 sweep_stale_dead_pid_fixture

# 4d. sweep-stale-runs.sh: manifest WITHOUT a pid field -> SKIPPED (legacy
#     graceful-degradation contract). Without this guard the sweep would
#     collateral-damage manifests written before the PID-capture upgrade.
sweep_stale_no_pid_fixture() {
  mkdir -p .claude-tmp/admin-apex-active
  printf '{"run":"deadbe04","cc_session_id":"X","producer":"admin-apex"}\n' \
    > .claude-tmp/admin-apex-active/deadbe04.json
  bash "$REPO_ROOT/skills/admin-apex/scripts/sweep-stale-runs.sh"
  [[ -f .claude-tmp/admin-apex-active/deadbe04.json ]] || return 1
  rm -f .claude-tmp/admin-apex-active/deadbe04.json
  return 0
}
run_fixture "sweep-stale-runs.sh no-pid-preserved" 0 sweep_stale_no_pid_fixture

# 4e. apex session-end-hook.sh (worktree mode): cc_session_id match -> hook
#     scans <main>/.apex-worktrees/*/.claude-tmp/apex-active/*.json, locates
#     the worktree-resident manifest, dispatches cleanup-session.sh, which
#     removes the worktree (clean tree + no commits past base).
apex_session_end_clean_fixture() {
  # Mint a real git sandbox with a worktree-resident apex session.
  git init -q -b main . >/dev/null
  printf '.claude-tmp/\n.apex-worktrees/\n' > .gitignore
  git -c user.email=t@t -c user.name=t add .gitignore >/dev/null
  git -c user.email=t@t -c user.name=t commit -q -m init >/dev/null
  local token="feedface" wt=".apex-worktrees/feedface"
  git worktree add -q -b "apex/$token" "$wt" HEAD >/dev/null
  mkdir -p "$wt/.claude-tmp/apex-active"
  printf '{"session":"%s","pid":1,"cc_session_id":"FIXTURE-CC1","worktree_path":"%s","branch":"apex/%s","base_branch":"main"}\n' \
    "$token" "$PWD/$wt" "$token" \
    > "$wt/.claude-tmp/apex-active/$token.json"
  CLAUDE_PROJECT_DIR="$PWD" \
    bash -c 'printf "{\"session_id\":\"FIXTURE-CC1\"}" | bash "$1"' \
    _ "$REPO_ROOT/skills/apex/scripts/session-end-hook.sh"
  # Worktree removed -> the entire subtree (incl. manifest) is gone.
  [[ -d "$wt" ]] && return 1
  # Branch deleted.
  git show-ref --verify --quiet "refs/heads/apex/$token" && return 1
  return 0
}
run_fixture "apex session-end-hook.sh clean" 0 apex_session_end_clean_fixture

# 4h. find-claude-pid.sh: smoke test. Walks up the process tree from $$ looking
#     for a comm whose basename is "claude". When this test runs under /apex or
#     /admin-apex (the production case), claude IS in the ancestry so exit 0 +
#     stdout is a numeric pid. When run in CI without claude in the ancestry,
#     exit 1 with a stderr warning. Both branches are valid - the fixture
#     verifies stdout shape on the success branch and accepts either exit code.
find_claude_pid_fixture() {
  local out
  out=$(bash "$REPO_ROOT/skills/apex/scripts/find-claude-pid.sh" 2>/dev/null)
  local rc=$?
  if (( rc == 0 )); then
    [[ "$out" =~ ^[0-9]+$ ]] || return 1
  elif (( rc == 1 )); then
    [[ -z "$out" ]] || return 1
  else
    return 1
  fi
  return 0
}
run_fixture "find-claude-pid.sh smoke" 0 find_claude_pid_fixture

# 4i. cleanup-session.sh (worktree mode): clean tree + no commits past
#     base_branch -> git worktree remove --force + git branch -D.
cleanup_session_clean_fixture() {
  git init -q -b main . >/dev/null
  printf '.claude-tmp/\n.apex-worktrees/\n' > .gitignore
  git -c user.email=t@t -c user.name=t add .gitignore >/dev/null
  git -c user.email=t@t -c user.name=t commit -q -m init >/dev/null
  local token="deafbead" wt=".apex-worktrees/deafbead"
  git worktree add -q -b "apex/$token" "$wt" HEAD >/dev/null
  mkdir -p "$wt/.claude-tmp/apex-active"
  printf '{"session":"%s","pid":1,"cc_session_id":"X","worktree_path":"%s","branch":"apex/%s","base_branch":"main"}\n' \
    "$token" "$PWD/$wt" "$token" \
    > "$wt/.claude-tmp/apex-active/$token.json"
  bash "$REPO_ROOT/skills/apex/scripts/cleanup-session.sh" \
    --session "$token" \
    --apex-active-dir "$PWD/$wt/.claude-tmp/apex-active"
  [[ -d "$wt" ]] && return 1
  git show-ref --verify --quiet "refs/heads/apex/$token" && return 1
  return 0
}
run_fixture "cleanup-session.sh worktree-clean" 0 cleanup_session_clean_fixture

# 4j. session-end-hook.sh manual mode: dispatches cleanup-session.sh against
#     the supplied token. The cleanup decision is purely worktree state.
session_end_manual_clean_fixture() {
  git init -q -b main . >/dev/null
  printf '.claude-tmp/\n.apex-worktrees/\n' > .gitignore
  git -c user.email=t@t -c user.name=t add .gitignore >/dev/null
  git -c user.email=t@t -c user.name=t commit -q -m init >/dev/null
  local token="deafdead" wt=".apex-worktrees/deafdead"
  git worktree add -q -b "apex/$token" "$wt" HEAD >/dev/null
  mkdir -p "$wt/.claude-tmp/apex-active"
  printf '{"session":"%s","pid":1,"cc_session_id":"X","worktree_path":"%s","branch":"apex/%s","base_branch":"main"}\n' \
    "$token" "$PWD/$wt" "$token" \
    > "$wt/.claude-tmp/apex-active/$token.json"
  printf 'hyp\n' > "$wt/.claude-tmp/apex-active/$token-hypothesis.json"
  # Manual mode: cd into the worktree so cleanup-session.sh's APEX_ACTIVE
  # resolution lands on the worktree-resident apex-active dir.
  ( cd "$wt" && bash "$REPO_ROOT/skills/apex/scripts/session-end-hook.sh" "$token" )
  [[ -d "$wt" ]] && return 1
  git show-ref --verify --quiet "refs/heads/apex/$token" && return 1
  return 0
}
run_fixture "apex session-end-hook.sh manual" 0 session_end_manual_clean_fixture

# 4k. block-destructive-hook.sh: `-c X=Y` and `-C path` prefix-flags before `reset --hard` must deny (reflectors ac85c725 + 5b218a81: regex hardening landed without coverage).
block_destructive_reset_prefix_fixture() {
  local hook="$REPO_ROOT/skills/apex/scripts/block-destructive-hook.sh" out
  for cmd in 'git -c user.email=t@t reset --hard HEAD~1' 'git -C /tmp reset --hard'; do
    out=$(printf '{"tool_input":{"command":"%s"}}' "$cmd" | bash "$hook" 2>/dev/null)
    [[ "$out" == *'"deny"'* ]] || return 1
  done; return 0
}
run_fixture "block-destructive-hook.sh reset prefix-flags" 0 block_destructive_reset_prefix_fixture

# 5. admin-apex-finalize.sh: rejects missing args (exit 1).
run_fixture "admin-apex-finalize.sh missing-args" 1 \
  bash "$REPO_ROOT/skills/admin-apex/scripts/admin-apex-finalize.sh"

# 6. admin-apex-finalize.sh: defensive validation - --bump=none with any applied
#    op in applied-ops.json must exit 1 (caller-side bump-rule misapplication).
finalize_defensive_fixture() {
  mkdir -p .claude-tmp/admin-apex-active
  printf '%s' '[{"kind":"create","target":"foo","doc_only":false}]' \
    > .claude-tmp/admin-apex-active/abcdef01-applied-ops.json
  bash "$REPO_ROOT/skills/admin-apex/scripts/admin-apex-finalize.sh" \
    --run abcdef01 --bump none
}
run_fixture "admin-apex-finalize.sh bump=none-with-applied-op" 1 finalize_defensive_fixture

# 7. v2 step-13 reflect-traces.sh fail-silent contract: missing or bad args
#    still exit 0 (the heuristic block is best-effort, never blocks the flow).
run_fixture "reflect-traces.sh missing-args" 0 \
  bash "$REPO_ROOT/skills/apex/scripts/reflect-traces.sh"
run_fixture "reflect-traces.sh invalid-token" 0 \
  bash "$REPO_ROOT/skills/apex/scripts/reflect-traces.sh" --session BADTOKEN

# 8. verify-tests.sh: missing required args -> exit 2 (invocation error).
run_fixture "verify-tests.sh missing-args" 2 \
  bash "$REPO_ROOT/skills/apex/scripts/verify-tests.sh"

# 9. verify-tests.sh: valid args but no session baseline -> skip cleanly (exit 0).
#    The script's auto-detect contract: no baseline = silent skip, never an error.
verify_tests_no_baseline_fixture() {
  bash "$REPO_ROOT/skills/apex/scripts/verify-tests.sh" \
    --session deadbeef --project-type node
}
run_fixture "verify-tests.sh no-baseline-skip" 0 verify_tests_no_baseline_fixture

# 10. verify-build.sh --with-tests end-to-end at empty cwd: no manifest detected
#     by verify-build.sh -> exit 0 before reaching the tests phase. Confirms the
#     flag does not break the no-manifest fast path.
run_fixture "verify-build.sh --with-tests no-manifest" 0 \
  bash "$REPO_ROOT/skills/apex/scripts/verify-build.sh" --session deadbeef --with-tests

echo ""
echo "test-apex-scripts.sh: pass=$pass fail=$failed"
[[ $failed -eq 0 ]] || exit 1
exit 0
