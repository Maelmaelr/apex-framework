#!/usr/bin/env bash
# Step 6.b: deterministic ranker + top-K cap. Thin bash dispatcher.
# Spec: apex-core.md step 6.b.
#
# Behavior + telemetry: see _rank_findings.py.
#
# Args:
#   --session <token>          (required, 8-hex)
#   --findings <path>          (required) - .claude-tmp/scout/findings-{session}.json
#   --hypothesis <path>        (required) - .claude-tmp/apex-active/{session}-hypothesis.json
#   --min-confidence <level>   (optional) - medium|high (default medium = no filter)
#   --top-k <N>                (optional) - cap on ranked[] (default 30)
#
# Exit codes: 0 = success | 11 = top-K cap overshot (dropped_below_cap >= top_k) | 1 = unrecoverable error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOUT_DIR=".claude-tmp/scout"

SESSION=""
FINDINGS=""
HYPOTHESIS=""
MIN_CONFIDENCE="medium"
TOP_K="30"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)        SESSION="${2:-}";        shift 2 ;;
    --findings)       FINDINGS="${2:-}";       shift 2 ;;
    --hypothesis)     HYPOTHESIS="${2:-}";     shift 2 ;;
    --min-confidence) MIN_CONFIDENCE="${2:-}"; shift 2 ;;
    --top-k)          TOP_K="${2:-}";          shift 2 ;;
    *) echo "rank-findings.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

case "$MIN_CONFIDENCE" in
  medium|high) ;;
  *) echo "rank-findings.sh: --min-confidence must be one of medium|high" >&2; exit 1 ;;
esac

if [[ -z "$SESSION" || ! "$SESSION" =~ ^[0-9a-f]{8}$ ]]; then
  echo "rank-findings.sh: --session required (8-hex)" >&2; exit 1
fi
if [[ -z "$FINDINGS" || ! -f "$FINDINGS" ]]; then
  echo "rank-findings.sh: --findings required and must exist" >&2; exit 1
fi
if [[ -z "$HYPOTHESIS" || ! -f "$HYPOTHESIS" ]]; then
  echo "rank-findings.sh: --hypothesis required and must exist" >&2; exit 1
fi

mkdir -p "$SCOUT_DIR"
OUTPUT="$SCOUT_DIR/screen-plan-${SESSION}.json"

set +e
python3 "$SCRIPT_DIR/_rank_findings.py" \
  --findings "$FINDINGS" \
  --hypothesis "$HYPOTHESIS" \
  --output "$OUTPUT" \
  --min-confidence "$MIN_CONFIDENCE" \
  --top-k "$TOP_K"
exit_code=$?
set -e
exit $exit_code
