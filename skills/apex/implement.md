---
name: implement
description: p1.1 dispatch skill. TaskCreates per-task implementation work, spawns executor.md subagents in parallel where dependencies allow. Trace writes on failure or split go to {session}-traces/p1/executor-{task-id}.md (main) or {session}-traces/p2/executor-{teammate-id}-{task-id}.md (teammate).
---

# implement (p1.1)

Spec: `apex-core.md` p1.1 | `apex-core-overview.md` p1.1.

Owner: TaskCreates per-task implementation tasks; dependencies wired via TaskUpdate `addBlockedBy` after creation. ALL slices must precede p1.1b - polish needs every p1.1.* task complete before it intersects touched-by-apex with scope.

Executor: `agents/executor.md` (Sonnet latest).

## Findings consultation

When `preflight-{session}.json` is present and schema-valid (medium mode dispatched from step 9), `implement.md` consults `screened-{session}.json` BEFORE TaskCreate so each task's slice maps onto kept-file relevance:

```
PYTHONPATH="$HOME/.claude/skills/apex/scripts" python3 -c "
import sys
from _validate import consumer_load
data = consumer_load('.claude-tmp/scout/screened-{session}.json', 'screened')
if data is None:
    sys.exit('screened-{session}.json missing or invalid')
for entry in data['kept']:
    print(f\"{entry['file']}\t{entry['confidence']}\t{entry['screener_reason']}\")
"
```

When preflight is absent (trivial branch from step 5, or zero-layer proceed from step 6.a): no findings consultation; rely on prompt + scope file list (`{session}-main-scope.json`) only.

When in teammate mode: findings consultation is OPTIONAL - the teammate's `{session}-{teammate-id}-task.md` already names the slice (planner extracted it from screened at p2.0b); read screened only if the task description points at line ranges that need confirmation.

## Task-slice derivation

Slice the prompt into one or more implementation tasks. Each slice should:
- target a coherent file set (callers-and-callee, shared module + consumers, etc.)
- be implementable independently of other slices (cross-slice dependencies become `Blocked by #`)
- map onto `kept` files when findings are present (one-to-many is fine - several kept files per slice)

Default to **one task per concern** (frontend slice, backend slice, schema slice). Avoid one-task-per-file for trivial mechanical changes - those should be batched into a single executor invocation.

## Parallel vs sequential

For each pair of tasks, decide:
- **Parallel** if their files are disjoint AND neither task depends on the other's output
- **Sequential** otherwise (wire via `TaskUpdate({taskId, addBlockedBy: [<prior>]})` after both are created)

Default to parallel when files are clearly disjoint - executor agents are independent processes, parallelism is free latency. Common sequential triggers:
- Task A adds a new function; task B calls it -> B addBlockedBy A
- Task A renames a symbol; task B updates call sites -> B addBlockedBy A
- Task A creates a new module; task B imports from it -> B addBlockedBy A

## TaskCreate template

Per slice, call `TaskCreate` with the content shape below. `TaskCreate` accepts only `{subject, description, activeForm, metadata}` - dependencies and owner are set via `TaskUpdate` afterwards.

```
TaskCreate({
  subject:    "p1.1.<n> <one-line slice description>",
  activeForm: "Implementing p1.1.<n>",
  description:
    "Slice files: <subset of allowed_files>
     Findings:    <kept entries from screened-{session}.json with reasons + confidence,
                   OR 'no preflight - trivial / zero-layer branch'>
     Lessons:     <relevant matched blocks from step 4 grep-lessons.sh, if any>
     Trace path:  .claude-tmp/apex-active/{session}-traces/p1/executor-<task-id>.md   (main)
                  .claude-tmp/apex-active/{session}-traces/p2/executor-<teammate-id>-<task-id>.md (teammate)"
})
```

After every slice is created, wire dependencies and owner:

```
TaskUpdate({taskId: <p1.1.n>, addBlockedBy: [<p1.1.m>]})   # per sequential pair, optional
TaskUpdate({taskId: <p1.1b>,  addBlockedBy: [<every p1.1.*>]})   # ALWAYS - polish waits
TaskUpdate({taskId: <p1.1.n>, owner: "executor"})         # set after Agent spawn
```

## Executor spawn (per task)

The executor is a Sonnet subagent. Spawn prompt:

```
You are agents/executor.md. Read it at $HOME/.claude/agents/executor.md and follow it.

Slice files (allowed_files subset):
<list>

Task description:
<one-line slice description + any spec details>

Findings (medium mode only):
<kept entries with file/screener_reason/reasons/confidence, or "no preflight">

Lessons (best-effort, advisory only):
<relevant lessons.md blocks>

Trace path on failure or split:
<{session}-traces/p1/executor-<task-id>.md OR teammate variant>

Hooks active:
- scope-check (PreToolUse Edit/Write/MultiEdit/NotebookEdit)
- file-health (PreToolUse Edit/Write; split file > 400 lines before adding > 10 lines)

Architecture context: see agents/executor.md "Architecture context" for the read criterion.

Return one-line summary; write trace ONLY on failure or split decision.
```

See `agents/executor.md` for trace structure and behavior contract; `shared-guardrails.md` for safety paths, scope-check hook, trace path schema.

## Mode-specific trace path

| Mode | Trace path |
|------|-----------|
| main p1.1 | `.claude-tmp/apex-active/{session}-traces/p1/executor-{task-id}.md` |
| teammate p1.1 (under p2) | `.claude-tmp/apex-active/{session}-traces/p2/executor-{teammate-id}-{task-id}.md` |

`implement.md` injects the correct trace path into each executor spawn prompt; the executor only writes the trace on failure or file-split decision.
