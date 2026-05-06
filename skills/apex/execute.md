---
name: execute
description: Step 8 dispatch. Captures baseline, runs cross-session conflict check, queues split tasks for >400 LOC files, decides per-task scope (default 1; splits into 2+ for clearly independent areas), spawns executor.md per task with explicit working-memory propagation. Sonnet executors under economy; main-session model under standard.
---

# execute (step 8)

Spec: `apex-core.md` step 8.

## 8.0 Init

- Capture working-tree baseline:
  ```
  bash skills/apex/scripts/apex-baseline.sh
  ```
  Writes `.claude-tmp/apex-active/{session}-baseline.json`: `{head_sha: <git rev-parse HEAD>, pre_dirty: [<repo-relative paths>]}`. Consumed by steps 9 / 11 / 12 / 13. Step 12 excludes `pre_dirty` from staging so user-pre-existing WIP is never bundled into the apex commit.
- Concurrent-apex conflict check:
  ```
  bash skills/apex/scripts/apex-conflict-check.sh
  ```
  Reads `pre_dirty` from baseline; for each, scan `.claude-tmp/apex-active/*-main-scope.json` excluding our own `{session}` token. On overlap (a pre-dirty file appears in another active apex session's `allowed_files`): AskUserQuestion (`abort` | `proceed-anyway`; dismiss/cancel = abort). On `proceed-anyway`, the apex edit lands on top of the user WIP; the merged file stays dirty post-apex (excluded from step 12) for the user to review and commit.

## 8.1 Pre-flight wc-l split queue

- Run `wc -l` on `{session}-main-scope.json` `allowed_files`. Files > 500 LOC always split. Files > 400 LOC queue a split task ahead of normal edits unless the file is continuous-prose (`*.md` heuristic + author judgement).
- The `file-health-hook.sh` PreToolUse hook is the safety net for files that grow during execution (blocks `Edit` / `Write` on > 500 LOC files).

## 8.2 Task split + disjoint scopes (goals-driven)

- **`hypothesis.goals.length == 1`** (single-task / fix-bug-in-file-Y prompts): 1 executor task spanning the full scope. Spawn prompt carries the single goal verbatim. Behaviour identical to the prior default; the goal text is now structured rather than implicit in the hypothesis prose.
- **`hypothesis.goals.length > 1`** (multi-task / audit prompts): N executor tasks, one goal per spawn prompt. Per-task `allowed_files` is the subset of `{session}-main-scope.json` `allowed_files` whose paths match the goal's nouns. Compute by cheap grep: tokenize each goal (lowercase, drop stopwords + tokens <4 chars - same recipe as discoverer keyword extraction), then intersect main-scope paths with `grep -li <token>` hits. A goal whose noun-set yields no scope intersection inherits the full main-scope (degenerate fallback; logged in trace).
- **Goals with overlapping `allowed_files`** are serialized into a single follow-up task per the existing cross-task touch-points rule, so pairwise-disjoint validation continues to hold for the parallel set.
- When 2+ tasks are spawned (regardless of goals.length), validate per-task `allowed_files` via:
  ```
  python3 skills/apex/scripts/validate-disjoint-scopes.py <plan-json>
  ```
  - per-task `allowed_files` pairwise disjoint (excluding standard safety paths)
  - union is a subset of `{session}-main-scope.json` `allowed_files`
- Cross-task touch points are routed to a serialised follow-up task (no parallel write conflict).
- **Idempotency**: re-running the same prompt produces the same `goals[]` (deterministic from the user-prompt + the step-1/4 prompt-template hint), therefore the same N tasks. If the prior run achieved the goals, each executor returns `already-satisfied` (see `agents/executor.md`); nothing is staged at step 12 -> empty-diff path skips the commit.

## 8.3 Dispatch

Per task:

- Spawn `agents/executor.md` (Sonnet if `tier=economy`; main session model if `tier=standard`; the tier was decided at step 7).
- **Spawn-prompt context (executor stack)** - explicit, not inherited:
  - hypothesis (verbatim)
  - `goal` - the single goal string from `hypothesis.goals[]` for this task (one task per goal under `goals.length > 1`; the single goal under `goals.length == 1`)
  - per-task scope (`allowed_files` subset)
  - step 5 lessons hits relevant to the task
  - project-context paths
  - one-line task description
  - trace path: `.claude-tmp/apex-active/{session}-traces/execute/executor-{task-id}.md`
- The executor respects file-health + scope-check PreToolUse hooks.
- The executor returns `{goal, status, notes}` where status is `implemented` | `already-satisfied` | `failed`. Collect per-goal returns in a session-local map for step 15's per-goal summary.
- On failure or split decision, the executor writes a structured trace before returning (see `agents/executor.md`).

## Dispatch-only constraint

The orchestrator MUST NOT inline `Edit` / `Write` / `MultiEdit` / `NotebookEdit` against scope files at step 8. Slice writes belong to executor subagents. Inline writes outside the scope (e.g., `.claude-tmp/` artifacts) remain allowed via the standard safety-path set.

## Output

- `{session}-baseline.json` (from 8.0)
- Per-task trace files (only on failure or split)
- Modified scope files (touched-by-executor set; consumed by step 9 polish via `git diff` against `baseline.head_sha`)

## What this skill does NOT do

- Does NOT decide tier (step 7 owns that)
- Does NOT run lint / build (step 10 verify owns that)
- Does NOT commit or bump VERSION (step 12 owns that)
- Does NOT spawn screener / documentation / learn / reflector

See `apex-core.md` step 8 for the full contract; `agents/executor.md` for executor behavior; `apex-core.md` Conventions for safety paths and hook gating.
