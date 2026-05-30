#!/usr/bin/env bash
# Purpose: post-implementation polish (staleness/inconsistency/unused) check.
# Spec: skills/admin-apex/sync-docs.md (admin-apex polish phase) +
#       skills/apex-improve/finalize.md (apex-improve polish phase).
#
# Re-snapshots inventory POST-apply, then delegates to the shared detector engine
# (scripts/audit-detectors.py --mode polish: orphan-refs / missing-refs /
# schema-mismatch / dead-hook / approaching-budget (WARN), relabeled staleness/unused/inconsistency) which
# diffs against the pre-apply drift report so only NEW issues introduced by the
# implementation surface. No-op when zero ops were applied this run. The engine
# is the same code audit.md task 3 runs (--mode audit) - audit + polish can no
# longer silently diverge (the recurring reflector-patch source A1 collapsed).
#
# Args:
#   --run <RUN>   8-hex run token (required)
#
# Outputs:
#   .claude-tmp/admin-apex-active/{run}-inventory-post.json
#   .claude-tmp/admin-apex-active/{run}-polish-report.json
#
# Exit codes:
#   0   clean (or skipped because no ops applied)
#   1   new drift introduced; caller surfaces to user
#   2   bad args / state-corruption (caller aborts)

set -euo pipefail

RUN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) RUN="${2:-}"; shift 2 ;;
    *) echo "Usage: polish-check.sh --run <RUN>" >&2; exit 2 ;;
  esac
done
[[ -n "$RUN" ]] || { echo "Usage: polish-check.sh --run <RUN>" >&2; exit 2; }

REPO_ROOT="${CLAUDE_PROJECT_DIR:-$HOME/.claude}"
ACTIVE="$REPO_ROOT/.claude-tmp/admin-apex-active"
APPLIED="$ACTIVE/${RUN}-applied-ops.json"
DRIFT="$ACTIVE/${RUN}-drift-report.json"
INV_POST="$ACTIVE/${RUN}-inventory-post.json"
POLISH="$ACTIVE/${RUN}-polish-report.json"

# Skip when zero ops applied (nothing to polish).
OPCOUNT=0
if [[ -s "$APPLIED" ]]; then
  OPCOUNT=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$APPLIED" 2>/dev/null || echo 0)
fi
if [[ "$OPCOUNT" -lt 1 ]]; then
  echo "polish-check: 0 ops applied; skip" >&2
  exit 0
fi

# Re-snapshot post-apply inventory (own snapshot - never share with task 2's).
bash "$REPO_ROOT/skills/admin-apex/scripts/inventory-apex.sh" --out "$INV_POST" >/dev/null

# Delegate to the shared detector engine. --mode polish relabels to
# staleness/unused/inconsistency and diffs against the pre-apply drift report so
# only NEW drift surfaces; it prints $POLISH and exits 1 on NEW drift (which
# set -e propagates as this script's exit code), else 0.
python3 "$REPO_ROOT/skills/admin-apex/scripts/audit-detectors.py" \
  --inventory "$INV_POST" --mode polish --run "$RUN" \
  --prior-drift "$DRIFT" --out "$POLISH"
