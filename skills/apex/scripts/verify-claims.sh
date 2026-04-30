#!/usr/bin/env bash
# Step 8: verify claims (anti-hallucination). Producer of {session}-main-scope.json on the normal path.
# Spec: apex-core.md step 8 + Conventions / verify-claims.sh modes.
#
# Modes:
#   default (no flag): full claim verification pass; dispatches via exit code per step 8 gates.
#                      On exit 0 writes {session}-main-scope.json as the LAST action.
#   --apply-resolved : skips re-validation (claims already validated), re-adds keep claims
#                      from claim-review-resolved-{session}.json, unconditionally writes scope, exits 0.
#
# Exit-code priority 1 > 2 > 3 > 0 (most-severe wins):
#   0  proceed; small-batch unresolveds (<3) stay dropped
#   1  abort  - abort_cause=preflight_bad        if preflight_bad >= 2 OR preflight invalid
#             - abort_cause=screened_unconverged if rerun cap reached OR screened invalid
#             abort_cause written to stderr.
#   2  re-run 6c+7 - screened_bad >= 3 OR rate >= 30%; cap 1 via {session}-verify-rerun.json
#   3  inline review - len(unresolved) >= 3; scope unwritten
#
# This bash wrapper validates args + session token shape, then delegates to _verify_claims.py.
# Scope-pointer write (.claude-tmp/apex-active/{session}-scopes/{cc_session_id}.txt) is the
# orchestrator's responsibility on exit 0 - this script only writes the scope JSON.
#
# Args:
#   --session <token>     (required, 8-char lowercase hex)
#   --apply-resolved       (optional)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SESSION=""
APPLY_FLAG=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)
      SESSION="${2:-}"
      shift 2
      ;;
    --apply-resolved)
      APPLY_FLAG=(--apply-resolved)
      shift
      ;;
    *)
      echo "verify-claims.sh: unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$SESSION" ]]; then
  echo "verify-claims.sh: --session is required" >&2
  exit 1
fi

if [[ ! "$SESSION" =~ ^[0-9a-f]{8}$ ]]; then
  echo "verify-claims.sh: invalid session token shape: $SESSION (expected 8-char lowercase hex)" >&2
  exit 1
fi

# Bash 3.2 (macOS default) treats ${APPLY_FLAG[@]} as unbound when the array is
# empty under `set -u`. The +-conditional expansion stays empty when unset and
# expands to the array elements when set.
exec python3 "$SCRIPT_DIR/_verify_claims.py" --session "$SESSION" ${APPLY_FLAG[@]+"${APPLY_FLAG[@]}"}
