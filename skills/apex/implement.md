---
name: implement
description: p1.1 dispatch skill. TaskCreates per-task implementation work, spawns executor.md subagents in parallel where dependencies allow. Trace writes on failure or split go to {session}-traces/p1/executor-{task-id}.md (main) or {session}-traces/p2/executor-{teammate-id}-{task-id}.md (teammate).
---

# implement (p1.1)

Spec: `apex-core.md` p1.1 | `apex-core-overview.md` p1.1.

Owner: TaskCreates per-task implementation tasks (use `Blocked by #` for sequencing; ALL inserted before p1.1b - polish needs all p1.1.* tasks complete before it intersects touched-by-apex with scope).

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
- **Sequential** otherwise (use `Blocked by #` to enforce ordering)

Default to parallel when files are clearly disjoint - executor agents are independent processes, parallelism is free latency. Common sequential triggers:
- Task A adds a new function; task B calls it -> B blockedBy A
- Task A renames a symbol; task B updates call sites -> B blockedBy A
- Task A creates a new module; task B imports from it -> B blockedBy A

## TaskCreate template

```
TaskCreate "p1.1.<n> <one-line slice description>"
  blockedBy:   [<other p1.1.<m>>]   # optional, only when sequential
  blocks:      [p1.1b]              # ALWAYS - polish must wait for all slices
  owner:       agents/executor.md (Sonnet latest)
  description: |
    Slice files:    <subset of allowed_files>
    Findings:       <kept entries from screened-{session}.json with reasons + confidence,
                     OR "no preflight - trivial / zero-layer branch">
    Lessons:        <relevant matched blocks from step 4 grep-lessons.sh, if any>
    Trace path:     {session}-traces/p1/executor-<task-id>.md   # main mode
                    {session}-traces/p2/executor-<teammate-id>-<task-id>.md   # teammate mode
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

Return one-line summary; write trace ONLY on failure or split decision.
```

See `agents/executor.md` for trace structure and behavior contract; `shared-guardrails.md` for safety paths, scope-check hook, trace path schema.

## Mode-specific trace path

| Mode | Trace path |
|------|-----------|
| main p1.1 | `.claude-tmp/apex-active/{session}-traces/p1/executor-{task-id}.md` |
| teammate p1.1 (under p2) | `.claude-tmp/apex-active/{session}-traces/p2/executor-{teammate-id}-{task-id}.md` |

`implement.md` injects the correct trace path into each executor spawn prompt; the executor only writes the trace on failure or file-split decision.
