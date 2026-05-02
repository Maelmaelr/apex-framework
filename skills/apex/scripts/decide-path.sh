#!/usr/bin/env bash
# Step 9: decide path (medium -> Path 1, complex -> Path 2).
# Spec: apex-core.md step 9 | apex-core-overview.md step 9.
#
# Reads .claude-tmp/scout/preflight-{session}.json (consumer-validates against
# preflight.schema.json), echoes the `mode` field to stdout for orchestrator capture.
#
# Args:
#   --session <token>  (required, 8-char lowercase hex)
#
# Exit: 0 with `medium` or `complex` on stdout; 1 on missing/invalid preflight.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SESSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session) SESSION="${2:-}"; shift 2 ;;
    *) echo "decide-path.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ "$SESSION" =~ ^[0-9a-f]{8}$ ]] || { echo "decide-path.sh: --session must be 8-char lowercase hex" >&2; exit 1; }

PYTHONPATH="$SCRIPT_DIR" python3 - "$SESSION" <<'PY' || { echo "decide-path.sh: preflight missing or invalid mode" >&2; exit 1; }
import sys
from _validate import consumer_load
data = consumer_load(f".claude-tmp/scout/preflight-{sys.argv[1]}.json", "preflight")
mode = (data or {}).get("mode")
if mode not in ("medium", "complex"):
    sys.exit(1)
print(mode)
PY
