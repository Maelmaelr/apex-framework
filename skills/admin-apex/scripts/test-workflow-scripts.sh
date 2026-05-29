#!/usr/bin/env bash
# Purpose: syntax gate for committed Workflow scripts (skills/*/scripts/*.workflow.js).
# Spec: skills/admin-apex/SKILL.md task 8 (apex-scoped script check); workflow-adoption A3.
#
# Workflow scripts run inside the Workflow runtime as an async-fn body with
# injected globals (agent/parallel/pipeline/log/phase/args/budget/workflow) plus
# top-level export/return/await. A bare `node --check <file>` mis-detects the
# module type and FALSE-PASSES broken files, so we wrap each script the way the
# runtime does (strip `export` from `export const meta`, enclose the body in an
# async fn) and syntax-check the wrapped form as a module - the reliable gate.
#
# Kept separate from test-apex-scripts.sh (past the 400-line file-health cap),
# which folds this suite's result. Also runnable standalone.
#
# Exit codes: 0 all scripts parse (or node absent -> SKIP); 1 one or more failed.

set -uo pipefail
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$HOME/.claude}"
cd "$REPO_ROOT"
pass=0
failed=0

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP test-workflow-scripts.sh (node not installed)"
  exit 0
fi

shopt -s nullglob
files=(skills/*/scripts/*.workflow.js)
shopt -u nullglob

for f in "${files[@]}"; do
  err=$( { printf 'async function __wf(agent,parallel,pipeline,log,phase,args,budget,workflow){\n'
           sed 's/^export const /const /' "$f"
           printf '\n}\n'; } | node --check --input-type=module 2>&1 )
  if [[ $? -eq 0 ]]; then
    echo "PASS node --check $f"; pass=$((pass + 1))
  else
    { echo "FAIL node --check $f"; echo "$err" | sed 's/^/    /'; } >&2
    failed=$((failed + 1))
  fi
done

echo "test-workflow-scripts.sh: pass=$pass fail=$failed"
[[ $failed -eq 0 ]] || exit 1
exit 0
