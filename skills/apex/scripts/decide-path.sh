#!/usr/bin/env bash
# Step 9: decide path (medium -> Path 1, complex -> Path 2).
# Spec: apex-core.md step 9 | apex-core-overview.md step 9.
#
# Reads .claude-tmp/scout/preflight-{session}.json (consumer-validates against
# preflight.schema.json), branches on the `mode` field, echoes the selected token
# to stdout for orchestrator capture.
#
# Orchestrator dispatches:
#   medium  -> call p1.md
#   complex -> TaskCreate tasks 10, p2.0a, p2.0b, p2.0c
#
# Args:
#   --session <token>  (required, 8-char lowercase hex)
#
# Exit codes:
#   0  selected mode echoed to stdout
#   1  preflight missing/invalid OR mode field unrecognised (error to stderr)
#
# `mode` values that map to a path:
#   medium  -> Path 1
#   complex -> Path 2
# Anything else (schema-allowed but unexpected, or mutated artifact) -> exit 1.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SESSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)
      SESSION="${2:-}"
      shift 2
      ;;
    *)
      echo "decide-path.sh: unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$SESSION" ]]; then
  echo "decide-path.sh: --session is required" >&2
  exit 1
fi

if [[ ! "$SESSION" =~ ^[0-9a-f]{8}$ ]]; then
  echo "decide-path.sh: invalid session token shape: $SESSION (expected 8-char lowercase hex)" >&2
  exit 1
fi

PREFLIGHT=".claude-tmp/scout/preflight-$SESSION.json"

# Delegate read+validate+mode-extract to python so the consumer-validation contract
# matches every other artifact reader (consumer_load returns None on missing or schema-invalid).
mode=$(SCRIPT_DIR="$SCRIPT_DIR" PREFLIGHT="$PREFLIGHT" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SCRIPT_DIR"])
import _validate

data = _validate.consumer_load(os.environ["PREFLIGHT"], "preflight")
if data is None:
    sys.exit(1)

mode = data.get("mode")
if mode not in ("medium", "complex"):
    sys.exit(1)

print(mode)
PY
) || {
  echo "decide-path.sh: preflight missing or invalid: $PREFLIGHT" >&2
  exit 1
}

printf '%s\n' "$mode"
exit 0
