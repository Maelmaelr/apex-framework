#!/usr/bin/env bash
# Purpose: Task 9 finalize - bump VERSION (conditional), stage dirty paths +
#          docs + private-tracked roots, commit (if anything staged).
# Spec: skills/admin-apex/SKILL.md task 9
#
# Decision tree:
#   --bump != none -> invoke _bump-version.sh, append VERSION to dirty-paths.txt
#   stage {run}-dirty-paths.txt (if non-empty)
#   stage {run}-docs-changed.txt (if non-empty)
#   stage plugins/, statusline/, tmp/ (private-tracked roots; respects .gitignore
#     so transient flock targets / runtime caches stay out)
#   git diff --cached --quiet => no commit -> cleanup-run.sh --run {run} -> exit 10
#   else -> git commit -m <message> -m <body> -> exit 0
#
# `xargs ... < file` (input redirection) used instead of `xargs -a file` for
# macOS BSD-xargs portability. `git add -- plugins/ statusline/ tmp/` covers
# both modified-tracked and untracked files; `.gitignore` keeps lock targets /
# runtime caches out of the index.
#
# Args:
#   --run     <8-hex>                 required
#   --bump    patch|minor|major|none  required (decided by caller per SKILL.md task 9 bump rule)
#   --message <one-liner>             required when bump != none OR commit will fire
#   --body    <op-list>               required when bump != none OR commit will fire
#
# Defensive validation against {run}-applied-ops.json (catches caller-side
# bump-rule misapplication). Required tier per applied-op kinds:
#   any of {rename, split, merge, retire, schema-remove, hook-remove}  -> major
#   else any of {create, schema-add, hook-add}                          -> minor
#   else (only edit ops, or empty)                                      -> patch
# --bump must be at least the required tier; lower tier -> exit 1.
# --bump=none with any applied op (regardless of doc_only) -> exit 1.
#
# Exit codes:
#   0   commit created (caller proceeds to task 10)
#   10  no-commit + cleanup done (caller skips task 10)
#   1   bad args / defensive-validation failure
#   2   commit failure (artifacts left in place; surface to user)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Anchored at framework root regardless of caller cwd.
# APEX_ADMIN_ACTIVE_DIR override is reserved for test fixtures.
ADMIN_ACTIVE="${APEX_ADMIN_ACTIVE_DIR:-$HOME/.claude/.claude-tmp/admin-apex-active}"

RUN=""
BUMP=""
MESSAGE=""
BODY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)     RUN="${2:-}";     shift 2 ;;
    --bump)    BUMP="${2:-}";    shift 2 ;;
    --message) MESSAGE="${2:-}"; shift 2 ;;
    --body)    BODY="${2:-}";    shift 2 ;;
    *)
      echo "admin-apex-finalize.sh: unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$RUN" ]]; then
  echo "admin-apex-finalize.sh: --run is required" >&2
  exit 1
fi
if ! [[ "$RUN" =~ ^[0-9a-f]{8}$ ]]; then
  echo "admin-apex-finalize.sh: invalid run token shape: $RUN (expected 8-char lowercase hex)" >&2
  exit 1
fi
case "$BUMP" in
  patch|minor|major|none) ;;
  "")
    echo "admin-apex-finalize.sh: --bump is required (patch|minor|major|none)" >&2
    exit 1
    ;;
  *)
    echo "admin-apex-finalize.sh: invalid --bump value: $BUMP (expected patch|minor|major|none)" >&2
    exit 1
    ;;
esac

DIRTY="$ADMIN_ACTIVE/${RUN}-dirty-paths.txt"
DOCS="$ADMIN_ACTIVE/${RUN}-docs-changed.txt"
APPLIED="$ADMIN_ACTIVE/${RUN}-applied-ops.json"
SUMMARY="$ADMIN_ACTIVE/${RUN}-summary.md"

# Defensive validation: --bump must match the tier required by the applied-ops
# kinds. Catches caller-side mistake where bump rule was misapplied.
#   any of {rename, split, merge, retire, schema-remove, hook-remove}  -> major
#   else any of {create, schema-add, hook-add}                          -> minor
#   else (only edit ops, or empty)                                      -> patch
# --bump=none with any applied op (regardless of kind) -> rejected.
# --bump < required tier -> rejected (e.g., --bump=patch with create op).
# --bump > required tier is permitted (caller-elected over-bump is intentional).
if [[ -s "$APPLIED" ]]; then
  required=$(python3 -c "
import json, sys
try:
    ops = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    sys.exit(0)
if not isinstance(ops, list) or not ops:
    sys.exit(0)
MAJOR = {'rename', 'split', 'merge', 'retire', 'schema-remove', 'hook-remove'}
MINOR = {'create', 'schema-add', 'hook-add'}
tier = 'patch'
for op in ops:
    if not isinstance(op, dict):
        continue
    k = op.get('kind', '')
    if k in MAJOR:
        tier = 'major'
        break
    if k in MINOR and tier != 'major':
        tier = 'minor'
print(tier)
" "$APPLIED" 2>/dev/null || true)
  if [[ -n "$required" ]]; then
    if [[ "$BUMP" == "none" ]]; then
      echo "admin-apex-finalize.sh: --bump=none but $APPLIED contains applied ops (required tier=$required)" >&2
      exit 1
    fi
    rank_required=0
    rank_chosen=0
    case "$required" in patch) rank_required=1 ;; minor) rank_required=2 ;; major) rank_required=3 ;; esac
    case "$BUMP"     in patch) rank_chosen=1   ;; minor) rank_chosen=2   ;; major) rank_chosen=3   ;; esac
    if (( rank_chosen < rank_required )); then
      echo "admin-apex-finalize.sh: --bump=$BUMP but applied ops require at least --bump=$required (bump rule misapplied)" >&2
      exit 1
    fi
  fi
fi

# Step 1: Conditional VERSION bump.
if [[ "$BUMP" != "none" ]]; then
  # Drift pre-check: working-tree VERSION must match git HEAD:VERSION before
  # bump. Catches externally-modified VERSION (e.g., hand-edit between prior
  # commit and this finalize) before _bump-version.sh advances from a wrong
  # base, which forces a mid-finalize amendment loop pre-push.
  WT_VERSION_PRE="$(cat VERSION 2>/dev/null || true)"
  HEAD_VERSION="$(git show HEAD:VERSION 2>/dev/null || true)"
  if [[ -n "$WT_VERSION_PRE" && -n "$HEAD_VERSION" && "$WT_VERSION_PRE" != "$HEAD_VERSION" ]]; then
    echo "admin-apex-finalize.sh: VERSION drift detected (working-tree=$WT_VERSION_PRE, HEAD=$HEAD_VERSION); reset working-tree VERSION and re-run, or invoke with --bump=none" >&2
    exit 1
  fi
  # Compute expected post-bump value (mirrors _bump-version.sh: patch +1 on
  # patch field; minor +1 on minor field, patch reset 0; major +1 on major
  # field, minor and patch reset 0). Sibling-bump race detector: if a parallel
  # finalize.sh advances WT VERSION between this point and _bump-version.sh
  # below, WT_VERSION_POST will not match EXPECTED and we abort. The pre-check
  # above catches HEAD drift; this check catches concurrent WT drift from a
  # parallel sibling that targets the same starting VERSION.
  EXPECTED=$(python3 -c "
import sys
parts = sys.argv[1].split('.')
maj, min_, pat = int(parts[0]), int(parts[1]), int(parts[2])
if sys.argv[2] == 'patch':
    pat += 1
elif sys.argv[2] == 'minor':
    min_ += 1
    pat = 0
elif sys.argv[2] == 'major':
    maj += 1
    min_ = 0
    pat = 0
print(f'{maj}.{min_}.{pat}')
" "$WT_VERSION_PRE" "$BUMP" 2>/dev/null || true)
  if ! bash "$SCRIPT_DIR/_bump-version.sh" "$BUMP" >/dev/null; then
    echo "admin-apex-finalize.sh: _bump-version.sh $BUMP failed" >&2
    exit 1
  fi
  WT_VERSION_POST="$(cat VERSION 2>/dev/null || true)"
  if [[ -n "$EXPECTED" && "$WT_VERSION_POST" != "$EXPECTED" ]]; then
    echo "admin-apex-finalize.sh: post-bump drift detected (working-tree=$WT_VERSION_POST, expected=$EXPECTED); a parallel sibling bumped VERSION between the pre-check and _bump-version.sh - reset working-tree VERSION, git pull, and re-run" >&2
    exit 1
  fi
  echo VERSION >> "$DIRTY"
fi

# Step 2: Stage evolve dirty paths + docs + private-tracked roots.
if [[ -s "$DIRTY" ]]; then
  xargs git add -- < "$DIRTY"
fi
if [[ -s "$DOCS" ]]; then
  xargs git add -- < "$DOCS"
fi
git add -- plugins/ statusline/ tmp/

# Step 3: Decide commit vs no-commit-cleanup.
if git diff --cached --quiet; then
  # Nothing staged - clean up artifacts and signal caller to skip task 10.
  echo "task-9: nothing staged, no commit" >> "$SUMMARY"
  if [[ -x "$SCRIPT_DIR/cleanup-run.sh" ]]; then
    "$SCRIPT_DIR/cleanup-run.sh" --run "$RUN" 2>/dev/null || true
  fi
  exit 10
fi

# Commit path requires --message and --body.
if [[ -z "$MESSAGE" ]]; then
  echo "admin-apex-finalize.sh: --message is required when commit fires" >&2
  exit 1
fi
if [[ -z "$BODY" ]]; then
  echo "admin-apex-finalize.sh: --body is required when commit fires" >&2
  exit 1
fi

if ! git commit -m "$MESSAGE" -m "$BODY" >/dev/null; then
  echo "admin-apex-finalize.sh: git commit failed (artifacts left for inspection)" >&2
  exit 2
fi

# Audit trail: surface bump tier + body summary + commit SHA in summary.md
# (previously only in {run}-applied-ops.json; reflector reads summary.md for
# friction signals).
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "task-9: bump=$BUMP $BODY, commit $SHA" >> "$SUMMARY"

exit 0
