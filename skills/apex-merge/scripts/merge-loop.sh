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

ACTIVE_DIR="$HOME/.claude/.claude-tmp/apex-merge-active"
[[ -z "$DISCOVERY" ]] && DISCOVERY="$ACTIVE_DIR/$RUN-discovery.json"
[[ -z "$RESULT" ]]    && RESULT="$ACTIVE_DIR/$RUN-merge-result.json"

if [[ ! -f "$DISCOVERY" ]]; then
  echo "merge-loop.sh: discovery file not found: $DISCOVERY" >&2
  exit 1
fi

# Precheck: must run from MAIN worktree.
# git-common-dir returns "$worktree_root/.git" for linked worktrees and a bare ".git"
# for the main worktree, so resolve via "$(...)/.." + pwd -P (handles both shapes).
TOP_RES="$(cd "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null && pwd -P || true)"
COMMON_ABS="$(cd "$(git rev-parse --git-common-dir 2>/dev/null)/.." 2>/dev/null && pwd -P || true)"
if [[ -z "$TOP_RES" || "$TOP_RES" != "$COMMON_ABS" ]]; then
  echo "merge-loop.sh: must run from main worktree (top=$TOP_RES common=$COMMON_ABS)" >&2
  exit 2
fi
# .apex-worktrees/ is the apex create-session worktree root (untracked-by-design);
# .claude-tmp/ holds apex temp artifacts (lessons-tmp, scope JSONs). Filter both so
# the dirty-tree gate does not flag a routine apex layout (mirrors SKILL.md step-1).
if [[ -n "$(git status --porcelain | grep -v '^?? \.apex-worktrees/$' | grep -v '^...\.claude-tmp/')" ]]; then
  echo "merge-loop.sh: main worktree is dirty; resolve before merge" >&2
  exit 2
fi

mkdir -p "$ACTIVE_DIR"
# Append-or-init: preserve prior per-branch entries on conflict-interrupted resume
# (re-invoking the script after a manual conflict resolution must not erase the
# already-recorded clean-merge results; reflector 4c827a2b: orchestrator restitched
# inline because unconditional truncation wiped sibling entries on re-entry).
[[ -f "$RESULT" ]] || echo '[]' > "$RESULT"

# Append a step-4 summary line per SKILL.md step 4 contract. Clean-merge /
# trivial-union / merge-refused cases write here directly so the orchestrator
# does not back-fill (reflector 492224ba). The conflict-exit-20 path stays with
# the orchestrator - it owns the resolver decision and writes the line after
# the AskUserQuestion outcome.
append_summary() {
  echo "step-4: $1 $2 (conflicts=$3 resolver=$4)" >> "$ACTIVE_DIR/$RUN-summary.md"
}

append_result() {
  python3 - "$RESULT" "$1" "$2" "$3" "$4" <<'PY'
import json, sys
path, branch, base, status, detail = sys.argv[1:6]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
entry = {"branch": branch, "base": base, "status": status}
# Omit empty detail per SKILL.md step 4 contract (mirrors Step 2 omit-empty
# discipline; reflector 32455372: clean-merge entries emitted "detail": ""
# as downstream parse noise without information value).
if detail:
    entry["detail"] = detail
data.append(entry)
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
PY
}

# Iterate discovery entries via python (avoid jq dependency assumption parity
# with apex hot path which already mixes both). Use a portable while-read loop
# rather than `mapfile -t` so macOS env-resolved bash 3.2 does not silently
# abort with `unbound variable` (mapfile is a bash 4+ builtin).
ENTRIES=()
while IFS= read -r _line; do
  ENTRIES+=("$_line")
done < <(python3 - "$DISCOVERY" "$SINGLE_BRANCH" <<'PY'
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
    append_summary "$BRANCH" "checkout-failed" 0 "none"
    continue
  fi
  if [[ -z "$SUBJECT" ]]; then
    SUBJECT="$(git log -1 --pretty=%s "$BRANCH" 2>/dev/null || echo "$BRANCH")"
  fi
  if git merge --no-ff "$BRANCH" -m "Merge $BRANCH: $SUBJECT" >/dev/null 2>&1; then
    append_result "$BRANCH" "$BASE" "merged" ""
    append_summary "$BRANCH" "merged" 0 "none"
    continue
  fi
  # Merge stopped (conflict OR refusal). Capture conflicted paths.
  CONFLICTS="$(git diff --name-only --diff-filter=U 2>/dev/null || true)"
  if [[ -n "$CONFLICTS" ]]; then
    # Trivial-union skip: deterministically resolve single-hunk additive
    # conflicts in small markdown files (<=20kb) by inline union of both
    # sides' adds; saves the ~5-10k-token resolver spawn on the common
    # docs-pile case (reflector c946e283). Files this predicate rejects
    # fall through to the resolver-spawn path below.
    REMAINING=""
    TRIVIAL_COUNT=0
    while IFS= read -r P; do
      [[ -z "$P" ]] && continue
      python3 - "$P" <<'PY'
import os, re, sys
p = sys.argv[1]
if not p.endswith(".md") or os.path.getsize(p) > 20 * 1024:
    sys.exit(1)
with open(p, "r", encoding="utf-8", errors="replace") as f:
    body = f.read()
hunks = re.findall(r"<<<<<<<[^\n]*\n(.*?)\n=======\n(.*?)\n>>>>>>>[^\n]*\n", body, flags=re.S)
if len(hunks) != 1:
    sys.exit(1)
ours, theirs = hunks[0]
if not ours.splitlines() and not theirs.splitlines():
    sys.exit(1)
if ours == theirs:
    union = ours
else:
    union = ours + ("\n" if ours and not ours.endswith("\n") else "") + theirs
new = re.sub(
    r"<<<<<<<[^\n]*\n.*?\n=======\n.*?\n>>>>>>>[^\n]*\n",
    union + ("\n" if union and not union.endswith("\n") else ""),
    body, count=1, flags=re.S,
)
with open(p, "w", encoding="utf-8") as f:
    f.write(new)
sys.exit(0)
PY
      if [[ $? -eq 0 ]]; then
        git add "$P"
        TRIVIAL_COUNT=$((TRIVIAL_COUNT + 1))
      else
        REMAINING="${REMAINING:+$REMAINING$'\n'}$P"
      fi
    done <<< "$CONFLICTS"
    if [[ -z "$REMAINING" && "$TRIVIAL_COUNT" -gt 0 ]]; then
      if git commit --no-edit >/dev/null 2>&1; then
        append_result "$BRANCH" "$BASE" "merged" "trivial-union=$TRIVIAL_COUNT"
        append_summary "$BRANCH" "merged" "$TRIVIAL_COUNT" "none"
        continue
      fi
    fi
    REPORT="${REMAINING:-$CONFLICTS}"
    append_result "$BRANCH" "$BASE" "conflict" "$(echo "$REPORT" | tr '\n' ',' | sed 's/,$//')"
    echo "merge-loop.sh: conflict on $BRANCH (trivial-union resolved $TRIVIAL_COUNT):"
    echo "$REPORT"
    exit 20
  fi
  append_result "$BRANCH" "$BASE" "merge-refused" "git merge returned non-zero without conflicts"
  append_summary "$BRANCH" "merge-refused" 0 "none"
  exit 21
done

echo "merge-loop.sh: all queued branches merged"
exit 0
