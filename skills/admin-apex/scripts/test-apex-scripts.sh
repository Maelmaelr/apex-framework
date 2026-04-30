#!/usr/bin/env bash
# Purpose: Apex-scoped script + schema syntax / contract check.
# Spec: skills/admin-apex/SKILL.md task 8
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

echo ""
echo "test-apex-scripts.sh: pass=$pass fail=$failed"
[[ $failed -eq 0 ]] || exit 1
exit 0
