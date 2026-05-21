#!/usr/bin/env bash
# /apex-merge step 4: per-branch merge loop.
# Spec: skills/apex-merge/SKILL.md step 4 + tmp/worktree-migration-spec.md.
#
# Reads <run>-discovery.json (written by SKILL step 2), iterates each entry whose
# status is "needs-merge", performs `git checkout <base>; git merge --no-ff <branch>`,
# and records the per-branch outcome in <run>-merge-result.json. Conflict resolution
# is owned by the orchestrator (spawns agents/apex-merge-resolver.md per file +
# runs the AskUserQuestion); this script halts on conflict, prints the conflicted
# path list to stdout, and returns exit 20 so the orchestrator can take over.
#
# This script never mutates remote refs - cleanup + push run from SKILL steps 5/6.
#
# Args:
#   <run>                    required, 8-hex run token
#   --discovery <path>       optional override (default: .claude-tmp/apex-merge-active/<run>-discovery.json)
#   --result <path>          optional override (default: .claude-tmp/apex-merge-active/<run>-merge-result.json)
#   --branch <name>          optional filter (single branch only; SKILL step 2 already filters,
#                            this is a safety net for stand-alone re-runs)
#
# Exit codes:
#   0  - all queued branches merged cleanly (or nothing to merge)
#   1  - bad args / setup error
#   2  - precheck failure (cwd not main worktree, dirty tree, etc.)
#   20 - conflict on current branch; orchestrator must resolve
#   21 - non-FF or refused merge (operator intervention required)

set -uo pipefail

RUN=""
DISCOVERY=""
RESULT=""
SINGLE_BRANCH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --discovery) DISCOVERY="${2:-}"; shift 2 ;;
    --result)    RESULT="${2:-}";    shift 2 ;;
    --branch)    SINGLE_BRANCH="${2:-}"; shift 2 ;;
    -*)
      echo "merge-loop.sh: unknown flag: $1" >&2
      exit 1
      ;;
    *)
      if [[ -z "$RUN" ]]; then RUN="$1"
      else
        echo "merge-loop.sh: unexpected positional arg: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$RUN" || ! "$RUN" =~ ^[0-9a-f]{8}$ ]]; then
  echo "merge-loop.sh: <run> is required (8-hex token)" >&2
  exit 1
fi

ACTIVE_DIR=".claude-tmp/apex-merge-active"
[[ -z "$DISCOVERY" ]] && DISCOVERY="$ACTIVE_DIR/$RUN-discovery.json"
[[ -z "$RESULT" ]]    && RESULT="$ACTIVE_DIR/$RUN-merge-result.json"

if [[ ! -f "$DISCOVERY" ]]; then
  echo "merge-loop.sh: discovery file not found: $DISCOVERY" >&2
  exit 1
fi

# Precheck: must run from MAIN worktree.
TOP="$(git rev-parse --show-toplevel 2>/dev/null || true)"
COMMON="$(git rev-parse --git-common-dir 2>/dev/null | sed 's,/\.git$,,' || true)"
COMMON="$(cd "$COMMON" 2>/dev/null && pwd -P || echo "$COMMON")"
TOP_RES="$(cd "$TOP" 2>/dev/null && pwd -P || echo "$TOP")"
if [[ -z "$TOP_RES" || "$TOP_RES" != "$COMMON" ]]; then
  echo "merge-loop.sh: must run from main worktree (top=$TOP_RES common=$COMMON)" >&2
  exit 2
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "merge-loop.sh: main worktree is dirty; resolve before merge" >&2
  exit 2
fi

mkdir -p "$ACTIVE_DIR"
echo '[]' > "$RESULT"

append_result() {
  python3 - "$RESULT" "$1" "$2" "$3" "$4" <<'PY'
import json, sys
path, branch, base, status, detail = sys.argv[1:6]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
data.append({"branch": branch, "base": base, "status": status, "detail": detail})
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
PY
}

# Iterate discovery entries via python (avoid jq dependency assumption parity
# with apex hot path which already mixes both).
mapfile -t ENTRIES < <(python3 - "$DISCOVERY" "$SINGLE_BRANCH" <<'PY'
import json, sys
path, only = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
for e in data.get("branches", []):
    if e.get("status") != "needs-merge":
        continue
    if only and e.get("branch") != only:
        continue
    print(f"{e['branch']}\t{e.get('base','main')}\t{e.get('subject','')}")
PY
)

if [[ ${#ENTRIES[@]} -eq 0 ]]; then
  echo "merge-loop.sh: no branches queued for merge"
  exit 0
fi

for ENTRY in "${ENTRIES[@]}"; do
  IFS=$'\t' read -r BRANCH BASE SUBJECT <<<"$ENTRY"
  if ! git checkout "$BASE" >/dev/null 2>&1; then
    append_result "$BRANCH" "$BASE" "checkout-failed" "could not check out base $BASE"
    continue
  fi
  if [[ -z "$SUBJECT" ]]; then
    SUBJECT="$(git log -1 --pretty=%s "$BRANCH" 2>/dev/null || echo "$BRANCH")"
  fi
  if git merge --no-ff "$BRANCH" -m "Merge $BRANCH: $SUBJECT" >/dev/null 2>&1; then
    append_result "$BRANCH" "$BASE" "merged" ""
    continue
  fi
  # Merge stopped (conflict OR refusal). Capture conflicted paths and hand off.
  CONFLICTS="$(git diff --name-only --diff-filter=U 2>/dev/null || true)"
  if [[ -n "$CONFLICTS" ]]; then
    append_result "$BRANCH" "$BASE" "conflict" "$(echo "$CONFLICTS" | tr '\n' ',' | sed 's/,$//')"
    echo "merge-loop.sh: conflict on $BRANCH:"
    echo "$CONFLICTS"
    exit 20
  fi
  append_result "$BRANCH" "$BASE" "merge-refused" "git merge returned non-zero without conflicts"
  exit 21
done

echo "merge-loop.sh: all queued branches merged"
exit 0
