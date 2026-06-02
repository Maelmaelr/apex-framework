#!/usr/bin/env bash
# /apex-merge step 4: stamp a branch's TERMINAL merge-result entry after the
# orchestrator resolves (or aborts) that branch's conflicts.
#
# Producer-side fix for the step-4.6 lint-cleanup gate (plan F22). merge-loop.sh
# only writes a TRANSIENT `conflict` entry (detail = the conflicted-path CSV);
# the orchestrator owns the terminal rewrite. Step 4.6's two touchpoints both
# read merge-result.json for the orchestrator's stamp:
#   - RESOLVED_CONFLICTS count : jq '.[]|select(.status=="merged")|(.detail//"")' | grep -c 'resolver='
#   - conflict-touched paths   : jq '.[]|select(.status=="merged")|select(.detail|test("resolver="))|.paths'
# Neither ever matched before this script existed (`resolver=` only landed in
# <run>-summary.md, never in merge-result detail; `.paths` was never written),
# so step 4.6 silently skipped apex-fix after EVERY real conflict resolution.
# This script stamps both fields so both touchpoints fire.
#
# Rewrites IN PLACE the entry whose .branch == <branch>:
#   --status merged                -> detail = "resolver=<decision>", paths = [<resolved files>]
#   --status skipped-conflict-abort -> detail = "abort", no paths (4.6 must NOT fire)
# Any transient `conflict` detail / stale paths on the entry are dropped first.
# Idempotent: re-stamping the same branch updates in place (never appends a dup).
# Trivial-union-only merges are recorded directly by merge-loop.sh (detail
# "trivial-union=N", no `resolver=`) and intentionally do NOT trigger apex-fix -
# a bracket/backtick-balanced additive union cannot orphan an import.
#
# Args:
#   <run>                   required 8-hex run token
#   --branch <name>         required branch ref (e.g. apex/<session>)
#   --status <s>            required: merged | skipped-conflict-abort
#   --decision <d>          resolver decision (accept | reject-edit-manually | mixed);
#                           REQUIRED when --status merged
#   --paths <p1,p2,...>     comma-separated orchestrator-resolved file paths (merged only)
#   --result <path>         optional override (default <run>-merge-result.json)
#
# Exit: 0 stamped; 1 bad args / result file missing / no entry for <branch>.

set -uo pipefail

RUN=""; BRANCH=""; STATUS=""; DECISION=""; PATHS=""; RESULT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)   BRANCH="${2:-}";   shift 2 ;;
    --status)   STATUS="${2:-}";   shift 2 ;;
    --decision) DECISION="${2:-}"; shift 2 ;;
    --paths)    PATHS="${2:-}";    shift 2 ;;
    --result)   RESULT="${2:-}";   shift 2 ;;
    -*)
      echo "stamp-merge-result.sh: unknown flag: $1" >&2
      exit 1
      ;;
    *)
      if [[ -z "$RUN" ]]; then RUN="$1"
      else echo "stamp-merge-result.sh: unexpected positional arg: $1" >&2; exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$RUN" || ! "$RUN" =~ ^[0-9a-f]{8}$ ]]; then
  echo "stamp-merge-result.sh: <run> is required (8-hex token)" >&2
  exit 1
fi
[[ -n "$BRANCH" ]] || { echo "stamp-merge-result.sh: --branch is required" >&2; exit 1; }
case "$STATUS" in
  merged|skipped-conflict-abort) ;;
  *) echo "stamp-merge-result.sh: --status must be merged|skipped-conflict-abort" >&2; exit 1 ;;
esac
if [[ "$STATUS" == "merged" && -z "$DECISION" ]]; then
  echo "stamp-merge-result.sh: --decision is required when --status merged" >&2
  exit 1
fi

ACTIVE_DIR="$HOME/.claude/.claude-tmp/apex-merge-active"
[[ -z "$RESULT" ]] && RESULT="$ACTIVE_DIR/$RUN-merge-result.json"
if [[ ! -f "$RESULT" ]]; then
  echo "stamp-merge-result.sh: result file not found: $RESULT" >&2
  exit 1
fi

python3 - "$RESULT" "$BRANCH" "$STATUS" "$DECISION" "$PATHS" <<'PY'
import json, sys
path, branch, status, decision, paths_csv = sys.argv[1:6]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
paths = [p for p in (x.strip() for x in paths_csv.split(",")) if p]
found = False
for e in data:
    if e.get("branch") != branch:
        continue
    found = True
    e["status"] = status
    # Drop any transient conflict-path detail / stale paths before re-stamping.
    e.pop("detail", None)
    e.pop("paths", None)
    if status == "merged":
        e["detail"] = "resolver=%s" % decision
        if paths:
            e["paths"] = paths
    else:  # skipped-conflict-abort: no resolver stamp -> 4.6 must not fire
        e["detail"] = "abort"
    break
if not found:
    sys.stderr.write("stamp-merge-result.sh: no entry for branch %s in %s\n" % (branch, path))
    sys.exit(1)
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
PY
exit $?
