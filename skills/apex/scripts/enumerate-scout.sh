#!/usr/bin/env bash
# Step 6.a: deterministic enumeration. Thin bash dispatcher.
# Spec: apex-core.md step 6.a.
#
# Layers (each optional; "ran" = executed AND emitted >=1 finding):
#   1. Static imports     - madge (JS/TS), pydeps (Python). Explicit deps, zero noise.
#   2. ast-grep           - structural queries via sg/ast-grep (tree-sitter).
#   3. Framework-conv     - Next.js (app/, pages/), Rails (config/routes.rb), Django (urls.py).
#
# The ripgrep keyword fallback was retired (apex 1.x): the noise it generated
# poisoned 6.b sharding and amplified 6.c screener cost. When all three
# deterministic layers are empty the merger emits the zero-layer sentinel
# (exit code 10) and the orchestrator routes to zero-layer-extract or refine.
#
# Output: findings-{session}.json (validated against schemas/findings.schema.json).
#   - Dedupe by realpath-canonicalized file
#   - reasons[]: one item per matching layer with detail + line_range (when known)
#   - confidence: 3 deterministic = high; 1-2 = medium
#   - rescout layer reserved for 7.x merge (never appears here)
#
# Zero-layer case (all 3 deterministic layers produce 0):
#   - empty findings file with _meta.warnings=['no layers produced findings']
#   - exit 10 (orchestrator dispatches zero-layer branch)
#
# Args:
#   --session <token>     (required, 8-hex)
#   --hypothesis <path>   (required) - .claude-tmp/apex-active/{session}-hypothesis.json
#
# Exit codes: 0 = success | 10 = zero-layer | 1 = unrecoverable error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOUT_DIR=".claude-tmp/scout"

SESSION=""
HYPOTHESIS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)    SESSION="${2:-}";    shift 2 ;;
    --hypothesis) HYPOTHESIS="${2:-}"; shift 2 ;;
    *) echo "enumerate-scout.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$SESSION" || ! "$SESSION" =~ ^[0-9a-f]{8}$ ]]; then
  echo "enumerate-scout.sh: --session required (8-hex)" >&2; exit 1
fi
if [[ -z "$HYPOTHESIS" || ! -f "$HYPOTHESIS" ]]; then
  echo "enumerate-scout.sh: --hypothesis required and must exist" >&2; exit 1
fi

mkdir -p "$SCOUT_DIR"
LAYER_DIR="/tmp/${SESSION}-enumerate"
mkdir -p "$LAYER_DIR"
trap 'rm -rf "$LAYER_DIR"' EXIT

OUTPUT="$SCOUT_DIR/findings-${SESSION}.json"

# Run deterministic layers (writes per-layer jsonl into $LAYER_DIR).
python3 "$SCRIPT_DIR/_enumerate.py" \
  --hypothesis "$HYPOTHESIS" \
  --layer-dir "$LAYER_DIR"

# Merge layers, dedupe, derive confidence, write findings.json.
# _enumerate_merge.py exits 10 on zero-layer, 1 on schema validation failure, 0 otherwise.
set +e
python3 "$SCRIPT_DIR/_enumerate_merge.py" \
  --layer-dir "$LAYER_DIR" \
  --output "$OUTPUT"
exit_code=$?
set -e
exit $exit_code
