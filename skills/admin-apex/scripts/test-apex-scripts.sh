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

REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
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

# Fixture tests for the dispatcher-extracted scripts (apex-baseline, apex-
# conflict-check, apex-p2-init, zero-layer-extract). One assertion per script
# covers the critical exit code path the orchestrator reads.
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
  # $1 = label, $2 = expected exit, rest = command to run inside a temp dir
  local label="$1" expected="$2" got
  shift 2
  local tmp; tmp=$(mktemp -d)
  ( cd "$tmp" && "$@" >/dev/null 2>&1 )
  got=$?
  rm -rf "$tmp"
  check_fixtures "$label" "$expected" "$got"
}

# 1. Each new script rejects missing/bad {session} arg.
run_fixture "apex-baseline.sh missing-arg" 1 \
  bash "$REPO_ROOT/skills/apex/scripts/apex-baseline.sh"
run_fixture "apex-conflict-check.sh missing-arg" 2 \
  bash "$REPO_ROOT/skills/apex/scripts/apex-conflict-check.sh"
run_fixture "apex-p2-init.sh missing-arg" 1 \
  bash "$REPO_ROOT/skills/apex/scripts/apex-p2-init.sh"
run_fixture "zero-layer-extract.sh missing-arg" 1 \
  bash "$REPO_ROOT/skills/apex/scripts/zero-layer-extract.sh"

# 2. zero-layer-extract.sh exits 10 on zero validated paths (orchestrator runs
#    verify-exit-1 abort surface).
zero_paths_fixture() {
  mkdir -p .claude-tmp/apex-active
  echo '{"original_prompt": "no real paths here just plain words"}' \
    > .claude-tmp/apex-active/aabbccdd-hypothesis.json
  CC_SESSION_ID=test-cc bash "$REPO_ROOT/skills/apex/scripts/zero-layer-extract.sh" aabbccdd
}
run_fixture "zero-layer-extract.sh zero-validated-paths" 10 zero_paths_fixture

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

# 5. admin-apex-finalize.sh: rejects missing args (exit 1).
run_fixture "admin-apex-finalize.sh missing-args" 1 \
  bash "$REPO_ROOT/skills/admin-apex/scripts/admin-apex-finalize.sh"

# 6. admin-apex-finalize.sh: defensive validation - --bump=none with non-doc_only
#    op in applied-ops.json must exit 1 (caller-side bump-rule misapplication).
finalize_defensive_fixture() {
  mkdir -p .claude-tmp/admin-apex-active
  printf '%s' '[{"op":"create","target":"foo","doc_only":false}]' \
    > .claude-tmp/admin-apex-active/abcdef01-applied-ops.json
  bash "$REPO_ROOT/skills/admin-apex/scripts/admin-apex-finalize.sh" \
    --run abcdef01 --bump none
}
run_fixture "admin-apex-finalize.sh bump=none-with-nondoc-op" 1 finalize_defensive_fixture

# 7. Entry-flow 7-10 script argv contracts. Each rejects missing/invalid args
#    with the documented exit code; reflect-traces.sh stays fail-silent (exit 0).
run_fixture "verify-claims.sh missing-arg" 1 \
  bash "$REPO_ROOT/skills/apex/scripts/verify-claims.sh"
run_fixture "verify-claims.sh invalid-token" 1 \
  bash "$REPO_ROOT/skills/apex/scripts/verify-claims.sh" --session BADTOKEN
run_fixture "decide-path.sh missing-arg" 1 \
  bash "$REPO_ROOT/skills/apex/scripts/decide-path.sh"
run_fixture "decide-path.sh invalid-token" 1 \
  bash "$REPO_ROOT/skills/apex/scripts/decide-path.sh" --session BADTOKEN
run_fixture "reflect-traces.sh missing-args" 0 \
  bash "$REPO_ROOT/skills/apex/scripts/reflect-traces.sh"
run_fixture "reflect-traces.sh invalid-phase" 0 \
  bash "$REPO_ROOT/skills/apex/scripts/reflect-traces.sh" --session aabbccdd --phase nope
run_fixture "merge-scout-findings.py missing-args" 2 \
  python3 "$REPO_ROOT/skills/apex/scripts/merge-scout-findings.py"

echo ""
echo "test-apex-scripts.sh: pass=$pass fail=$failed"
[[ $failed -eq 0 ]] || exit 1
exit 0
