---
name: polish
description: p1.1b in-scope polish skill. Runs inline on the host model (Opus in main / trivial / Opus-teammate; Sonnet in Sonnet-teammate per planner per-teammate model selection). Computes touched-by-apex INTERSECTED with active scope's allowed_files; applies in-scope-only fixes (orphaned imports, dead code, leftover commented blocks, obvious naming inconsistencies in newly-touched lines). Self-enforces hard cap; scope-check hook is outer guard.
---

# polish (p1.1b)

Spec: `apex-core.md` p1.1b | `apex-core-overview.md` p1.1b.

## Step 1: Compute touched-by-apex set

Read `head_sha` from `{session}-baseline.json` (written by p1.0 in main mode, or by p2.0 in teammate mode under Path 2).

```
head_sha=$(jq -r '.head_sha' .claude-tmp/apex-active/{session}-baseline.json)
touched=$( (git diff --name-only "$head_sha"; git ls-files --others --exclude-standard) | LC_ALL=C sort -u )
```

The union covers tracked-modified AND untracked-non-ignored. Both are required: `git diff` excludes untracked files, so apex-newly-created files via the `Write` tool would otherwise be invisible to polish.

## Step 2: Resolve active scope path

Active scope file: `.claude-tmp/apex-active/{session}-main-scope.json` in main mode, `.claude-tmp/apex-active/{session}-{teammate-id}-scope.json` in teammate mode (under Path 2).

## Step 3: Intersect touched-by-apex with allowed_files

```
in_scope=$(jq -r '.allowed_files[]' <scope_file> \
  | LC_ALL=C sort -u \
  | LC_ALL=C comm -12 - <(printf '%s\n' "$touched"))
```

`<scope_file>` is the Step 2 path (main or teammate variant).

`LC_ALL=C` on both `sort -u` and `comm -12` is required: `comm` expects byte-order ordering and silently emits empty output if either input is sorted under a different locale. `$touched` was C-sorted in Step 1; both sides match.

`in_scope` is the set polish is allowed to edit. Pre-existing user-dirty files outside scope are NOT polished here - they still get committed by `git.md` per the "process as normal file" rule, but apex does not auto-modify user WIP code outside its declared scope.

## Step 4: Apply in-scope-only fixes

For each file in `$in_scope`, scan for and fix (only inside the intersected set):

| Fix | Trigger |
|-----|---------|
| Unused imports | Imports orphaned by p1.1 edits (reference dropped or symbol no longer used) |
| Dead code | Functions / branches no longer called from anywhere AFTER p1.1 edits |
| Leftover commented blocks | Commented-out code on lines that p1.1 touched (use `git diff "$head_sha" -- <file>` to scope detection) |
| Naming inconsistencies | Obvious mismatches in newly-touched lines (camelCase vs snake_case in same file, etc.) |

Use the `Edit` tool for in-place fixes. Touch ONLY files in `$in_scope`; the scope-check PreToolUse hook is the outer guard, but polish self-enforces by gating its own edits.

## Step 5: Hard cap (self-enforcement)

The intersected set from Step 3 is the ceiling. Polish runs inline on the host model (no subagent), so the gate is a host-side rule:

- Hold `$in_scope` in working memory after Step 3 (the captured stdout from the bash block).
- Before every `Edit` / `Write` tool call, check the target path against that set.
- If the target is NOT in `$in_scope`, skip the fix - do NOT escalate, do NOT widen the set.

The scope-check PreToolUse hook is the outer guard: a missed self-check fails closed at the tool call. Self-enforcement is the inner guard so the host model does not burn tool calls on rejected edits.

If a fix would require touching a file outside `$in_scope`, leave it for the next session - `learn.md` at p1.3 captures the pattern in `lessons-tmp.md` if it generalises.

## Step 6: No-op exit

If `$in_scope` is empty OR no actionable fixes are found, exit cleanly with no edits. A no-op polish is the common case for trivial / zero-layer branches; do NOT manufacture work.

## Breakage routing

Any breakage introduced by polish edits is caught by the next verify step:
- Main mode: `p1.2` verify (counts toward the 3-attempt fix cap in `{session}-fix-attempts-main.json`)
- Teammate mode: central `p2.3` (teammate p1.2 is skipped; central verify absorbs polish-introduced breakage into `{session}-fix-attempts-p2.json`)

## Host model

Polish runs INLINE on the host model (no subagent spawn). The host model is determined by caller:
- Main / trivial / zero-layer paths -> Opus (main orchestrator)
- Path 2 teammate -> Opus or Sonnet per planner's per-teammate model selection at p2.0b

See `shared-guardrails.md` for safety paths, scope-check hook resolution, mid-/apex abort cleanup.
