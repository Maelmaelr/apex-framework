#!/usr/bin/env bash
# /apex-merge step 4: per-branch merge loop.
# Spec: skills/apex-merge/SKILL.md step 4.
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
# .apex-worktrees/ is the apex mint-worktree.sh worktree root (untracked-by-design;
# its mode-160000 gitlinks must never be committed). Filter ONLY it so the
# dirty-tree gate does not flag a routine apex layout. Project .claude/ + .claude-tmp/
# are NOT filtered: SKILL.md step-1 commits them onto main, so this gate requires
# them clean (committed) before merge (mirrors SKILL.md step-1).
if [[ -n "$(git status --porcelain | grep -v '^?? \.apex-worktrees/$')" ]]; then
  echo "merge-loop.sh: main worktree is dirty; resolve before merge" >&2
  exit 2
fi

mkdir -p "$ACTIVE_DIR"
# Append-or-init: preserve prior per-branch entries on conflict-interrupted resume
# (re-invoking the script after a manual conflict resolution must not erase the
# already-recorded clean-merge results).
[[ -f "$RESULT" ]] || echo '[]' > "$RESULT"

# Append a step-4 summary line per SKILL.md step 4 contract. Clean-merge /
# trivial-union / merge-refused cases write here directly so the orchestrator
# does not back-fill. The conflict-exit-20 path stays with
# the orchestrator - it owns the resolver decision and writes the line after
# the AskUserQuestion outcome.
append_summary() {
  echo "step-4: $1 $2 (conflicts=$3 resolver=$4)" >> "$ACTIVE_DIR/$RUN-summary.md"
}

append_result() {
  python3 - "$RESULT" "$1" "$2" "$3" "$4" "${5:-}" <<'PY'
import json, sys
path, branch, base, status, detail, merged_sha = sys.argv[1:7]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
# Dedup by (branch, status) before the terminal write: a conflict-interrupted
# resume re-invokes the loop, which must not append a 2nd row for a branch
# already recorded at this status (append-per-merge produced 2x entries).
# Sibling branches (different branch or status) are preserved.
data = [e for e in data if not (e.get("branch") == branch and e.get("status") == status)]
entry = {"branch": branch, "base": base, "status": status}
# Omit empty detail per SKILL.md step 4 contract (mirrors Step 2 omit-empty
# discipline).
if detail:
    entry["detail"] = detail
# merged_sha = the merged tip SHA, recorded on successful merges only, so a
# post-mortem can pin the exact merge commit after the branch is pruned.
if merged_sha:
    entry["merged_sha"] = merged_sha
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
  # Resume idempotency: a branch already at a terminal status was handled by a
  # prior invocation (conflict-interrupted resume). Re-merging would re-stamp
  # "merged" with empty detail, wiping the resolver=/paths[] fields that gate
  # step 4.6, and re-append its summary line. Skip it.
  if python3 - "$RESULT" "$BRANCH" <<'PY'
import json, sys
path, branch = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(1)
terminal = {"merged", "skipped-conflict-abort"}
sys.exit(0 if any(e.get("branch") == branch and e.get("status") in terminal for e in data) else 1)
PY
  then
    echo "merge-loop.sh: $BRANCH already terminal in merge-result; skipping (resume)"
    continue
  fi
  if ! git checkout "$BASE" >/dev/null 2>&1; then
    append_result "$BRANCH" "$BASE" "checkout-failed" "could not check out base $BASE"
    append_summary "$BRANCH" "checkout-failed" 0 "none"
    continue
  fi
  if [[ -z "$SUBJECT" ]]; then
    SUBJECT="$(git log -1 --pretty=%s "$BRANCH" 2>/dev/null || echo "$BRANCH")"
  fi
  # Rich merge-commit message (audit traceability when multiple branches land in
  # one push): subject line + every merged commit's subject in the body + an
  # M/A/D diff-stat of the branch's net contribution + co-author trailer. Compute
  # before the merge so a conflict-path resolution commit (which reuses the
  # prepared .git/MERGE_MSG) inherits the same body.
  MERGE_BASE="$(git merge-base "$BASE" "$BRANCH" 2>/dev/null || echo "$BASE")"
  MERGED_COMMITS="$(git log --reverse --pretty='- %s' "$BASE..$BRANCH" 2>/dev/null || true)"
  MAD_RAW="$(git diff --name-status "$MERGE_BASE" "$BRANCH" 2>/dev/null || true)"
  MAD="$(printf '%s\n' "$MAD_RAW" | awk \
    '{c[substr($1,1,1)]++} END{printf "M:%d A:%d D:%d", c["M"]+0, c["A"]+0, c["D"]+0}')"
  if git merge --no-ff "$BRANCH" \
       -m "Merge $BRANCH: $SUBJECT" \
       -m "Merged commits:"$'\n'"$MERGED_COMMITS" \
       -m "Changes: $MAD" \
       -m "Co-Authored-By: Claude <noreply@anthropic.com>" >/dev/null 2>&1; then
    append_result "$BRANCH" "$BASE" "merged" "" "$(git rev-parse HEAD 2>/dev/null || true)"
    append_summary "$BRANCH" "merged" 0 "none"
    continue
  fi
  # Merge stopped (conflict OR refusal). Capture conflicted paths.
  CONFLICTS="$(git diff --name-only --diff-filter=U 2>/dev/null || true)"
  if [[ -n "$CONFLICTS" ]]; then
    # Partition by index state. UU/AA carry <<<< markers (content conflicts the
    # trivial-union pass or the content resolver can splice). DU/UD/DD are
    # delete/modify (or delete/delete) index-state conflicts: one side deleted
    # the path, so the working tree has NO markers - the content resolver cannot
    # splice what is absent. They need a keep-deleted|keep-modified decision the
    # orchestrator owns (SKILL.md step 4), never the resolver (apex-merge-du-ud).
    DU_UD=""; CONTENT_CONFLICTS=""
    while IFS= read -r _CP; do
      [[ -z "$_CP" ]] && continue
      case "$(git status --porcelain -- "$_CP" 2>/dev/null | cut -c1-2)" in
        DU|UD|DD) DU_UD="${DU_UD:+$DU_UD$'\n'}$_CP" ;;
        *)        CONTENT_CONFLICTS="${CONTENT_CONFLICTS:+$CONTENT_CONFLICTS$'\n'}$_CP" ;;
      esac
    done <<< "$CONFLICTS"
    # Trivial-union skip: deterministically resolve single-hunk additive
    # conflicts whose combined span is small (<=50 lines), in bracket/backtick-
    # balanced files, by inline union of both sides' adds; saves the ~5-10k-token
    # resolver spawn on the common docs-pile + balanced-code case (gate the
    # conflicted hunk span, not whole-file size, so big append-only files like
    # lessons.md with a one-line conflict still qualify).
    # Files this predicate rejects fall through to the resolver-spawn path below.
    REMAINING=""
    TRIVIAL_COUNT=0
    while IFS= read -r P; do
      [[ -z "$P" ]] && continue
      python3 - "$P" <<'PY'
import re, sys
p = sys.argv[1]
with open(p, "r", encoding="utf-8", errors="replace") as f:
    body = f.read()
hunks = re.findall(r"<<<<<<<[^\n]*\n(.*?)\n=======\n(.*?)\n>>>>>>>[^\n]*\n", body, flags=re.S)
if len(hunks) != 1:
    sys.exit(1)
ours, theirs = hunks[0]
if not ours.splitlines() and not theirs.splitlines():
    sys.exit(1)
# Hunk-span gate: bound the CONFLICTED span, not the whole
# file - a large append-only file (lessons.md) with a one-line date-bump conflict
# was rejected by the prior whole-file <=20kb gate and always spawned the resolver.
# Cap the single hunk's combined add-span so big files with a tiny conflict qualify
# while large-hunk conflicts still fall through to the resolver.
if len(ours.splitlines()) + len(theirs.splitlines()) > 50:
    sys.exit(1)
# Trivial-union safety gate (replaces the prior markdown-only restriction):
# each side must independently nest () [] {} correctly AND carry an even
# backtick count, so unioning the two adds cannot split a bracket pair or a
# code fence. Single/double-quote parity is deliberately NOT checked - prose
# apostrophes ("don't") and char literals make it a false-positive magnet;
# bracket nesting + backtick parity is the robust core. Anything this rejects
# falls through to the resolver (safe, just costs a spawn).
def _balanced(s):
    pairs = {")": "(", "]": "[", "}": "{"}
    stack = []
    for ch in s:
        if ch in ("(", "[", "{"):
            stack.append(ch)
        elif ch in pairs:
            if not stack or stack.pop() != pairs[ch]:
                return False
    return not stack and s.count("`") % 2 == 0
if not _balanced(ours) or not _balanced(theirs):
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
    done <<< "$CONTENT_CONFLICTS"
    # Auto-commit the trivial-union result ONLY when nothing else is unresolved -
    # no content remainder AND no DU/UD index-state conflict awaiting a decision.
    if [[ -z "$REMAINING" && -z "$DU_UD" && "$TRIVIAL_COUNT" -gt 0 ]]; then
      if git commit --no-edit >/dev/null 2>&1; then
        append_result "$BRANCH" "$BASE" "merged" "trivial-union=$TRIVIAL_COUNT" \
          "$(git rev-parse HEAD 2>/dev/null || true)"
        append_summary "$BRANCH" "merged" "$TRIVIAL_COUNT" "trivial-union"
        continue
      fi
    fi
    # Content remainder for the resolver; fall back to the content set when the
    # trivial-union staged everything but the commit failed (rare git-hook case).
    CONTENT_REPORT="$REMAINING"
    [[ -z "$CONTENT_REPORT" && -z "$DU_UD" ]] && CONTENT_REPORT="$CONTENT_CONFLICTS"
    DETAIL="$(echo "$CONTENT_REPORT" | tr '\n' ',' | sed 's/,$//;s/^,//')"
    [[ -n "$DU_UD" ]] && DETAIL="${DETAIL:+$DETAIL }du-ud=$(echo "$DU_UD" | tr '\n' ',' | sed 's/,$//;s/^,//')"
    append_result "$BRANCH" "$BASE" "conflict" "$DETAIL"
    echo "merge-loop.sh: conflict on $BRANCH (trivial-union resolved $TRIVIAL_COUNT):"
    [[ -n "$CONTENT_REPORT" ]] && { echo "content-conflicts:"; echo "$CONTENT_REPORT"; }
    [[ -n "$DU_UD" ]] && { echo "du-ud (keep-deleted|keep-modified, NOT resolver):"; echo "$DU_UD"; }
    # Per-iteration reload reminder (SKILL.md step 4 / resolve-one-conflict.md
    # dispatch; Workstream B item-4). Emit one line per remaining conflicted file
    # (content + du/ud) as the LAST stdout block so the orchestrator re-reads the
    # per-conflict contract before resolving each, keeping it recent across the
    # unbounded loop. A 2-conflict-file branch therefore prints the reminder twice.
    { [[ -n "$CONTENT_REPORT" ]] && printf '%s\n' "$CONTENT_REPORT"
      [[ -n "$DU_UD" ]] && printf '%s\n' "$DU_UD"; } \
      | while IFS= read -r _RP; do
          [[ -z "$_RP" ]] && continue
          echo "CONFLICT on $_RP. Per dispatch, Read skills/apex-merge/resolve-one-conflict.md before resolving."
        done
    exit 20
  fi
  append_result "$BRANCH" "$BASE" "merge-refused" "git merge returned non-zero without conflicts"
  append_summary "$BRANCH" "merge-refused" 0 "none"
  exit 21
done

echo "merge-loop.sh: all queued branches merged"
exit 0
