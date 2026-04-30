---
name: teammates
description: p2.1. Spawns N teammates per planner output, writes per-teammate scope + task.md, monitors and coordinates until done. Single producer for {session}-{teammate-id}-scope.json. Handles teammate failure recovery (self-fix / replacement teammate / AskUserQuestion).
---

# teammates (p2.1)

Spec: `apex-core.md` p2.1 | `apex-core-overview.md` p2.1.

Runs inline on Opus (main orchestrator). Spawned teammates themselves are Sonnet or Opus per planner decision in p2.0b.

## Inputs (from the embedded plan body)

The plan body composed by `planner.md` at p2.0b survives the p2.0c context clear. Read from it:

- `{session}` token
- Team size `N`
- Per-teammate record: `{teammate-id, model, high-effort, task, allowed_files}`
- `shared_files: [...]` (reference only; teammates never own these -- p2.4 documentation.md handles first-write)
- `original_prompt` + `hypothesis` (passed in each teammate prompt for context)

## Per-teammate setup (parallel batch)

For each teammate, the orchestrator does three things in order:

### Step 1: Write the teammate scope artifact

Single producer for `{session}-{teammate-id}-scope.json` (`schemas/teammate-scope.schema.json`). Subset of `{session}-main-scope.json`; the planner already extended main scope first if the teammate needed files outside it (p2.0b "Main scope is the union" rule).

```
PYTHONPATH="$HOME/.claude/skills/apex/scripts" python3 -c "
import sys, json, datetime
from _validate import producer_validate, ValidationError
data = {
    'session': '{session}',
    'teammate_id': '{teammate-id}',
    'allowed_files': ${ALLOWED_FILES_JSON},   # JSON array literal substituted by orchestrator
    'produced_at': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
}
try:
    producer_validate(data, 'teammate-scope')
except ValidationError as e:
    print(f'teammate-scope producer-validate failed: {e}', file=sys.stderr)
    sys.exit(1)
with open('.claude-tmp/apex-active/{session}-{teammate-id}-scope.json', 'w') as f:
    json.dump(data, f)
"
```

### Step 2: Write the teammate task description

Sourced from the planner's per-teammate task description at p2.0b. Consumed by the teammate's p1.6 inline summary; cleaned up at p2.6.

```
cat > .claude-tmp/apex-active/{session}-{teammate-id}-task.md <<'EOF'
{TASK_DESCRIPTION}
EOF
```

### Step 3: Spawn the teammate

The teammate is a fresh Claude Code subagent with its own `cc_session_id`. Two-call pattern:

**3a. Create the team** (once, before any Agent spawn):

```
TeamCreate
  team_name: "apex-{session}"
  agent_type: "apex-teammate"
  description: "Path 2 teammate pool for apex session {session}"
```

**3b. Spawn each teammate via the `Agent` tool** -- one Agent tool call per teammate, all in a single parallel batch (single message, multiple Agent tool uses):

```
Agent
  team_name:     "apex-{session}"
  name:          "{teammate-id}"
  subagent_type: "general-purpose"
  model:         <"sonnet"|"opus" per planner>
  description:   "Apex teammate {teammate-id} -- {short task summary}"
  prompt: |
    Read and follow ~/.claude/skills/apex/p1.md with the --teammate flag.

    Session: {session}
    Teammate id: {teammate-id}
    Scope file: .claude-tmp/apex-active/{session}-{teammate-id}-scope.json
    Task file:  .claude-tmp/apex-active/{session}-{teammate-id}-task.md

    Active peers (one-line summaries):
      - {peer-id-1}: <one-line what they do>
      - {peer-id-2}: <one-line what they do>
      ...

    Original user prompt: <verbatim from {session}-hypothesis.json>
    Hypothesis: <verbatim>

    First task: call ~/.claude/skills/apex/p1.md --teammate.
```

The `--teammate` flag MUST be on the `p1.md` invocation. p1.md trims its chain on the flag (skips baseline / conflict check / p1.2 / p1.4 / p1.5; central p2.3 / p2.5 / p2.6 own each).

The teammate's `cc_session_id` is the new Claude Code session id assigned to the spawned subagent (distinct from main / p2 session). p1.0 under `--teammate` writes the per-teammate scope-check pointer at `{session}-scopes/{teammate_cc_session_id}.txt`.

Trace path for the teammate's executor: `{session}-traces/p2/executor-{teammate-id}-{task-id}.md` (the `{teammate-id}` segment disambiguates parallel teammates).

## Peer-summary distribution

Peer summaries are baked into each teammate's spawn prompt at Step 3b -- the orchestrator already has every teammate's task description on disk (`{session}-{teammate-id}-task.md`) and the planner's per-teammate summary in the plan body, so a one-line summary per peer is composed inline before the parallel spawn.

If a replacement teammate is spawned later (failure-recovery branch (b)), send updated peer summaries to the survivors via `SendMessage`:

```
for survivor in "${SURVIVING_TEAMMATES[@]}"; do
  SendMessage
    to: "$survivor"
    message: "New peer joined: {replacement-id} -- <one-line task summary>"
done
```

## Monitor and coordinate

Teammates can talk to the main orchestrator and to each other via `SendMessage`. The orchestrator stays inline on Opus, fielding questions and watching for completion or failure signals. Teammates mark their assigned tasks completed via `TaskUpdate`; the orchestrator polls `TaskList` between teammate messages to detect quiet completion.

p2.2 shutdown is blocked until every surviving teammate has either (a) completed its task, (b) been replaced and the replacement has completed, or (c) been formally dropped via the failure-recovery (c) branch.

## Failure-recovery decision tree

When a teammate surfaces an abort (executor abort, scope-check rejection it cannot work around, or any in-teammate failure -- note teammate p1.2 verify is skipped, so fix-cap aborts only happen at central p2.3):

```
1. Is the failure obvious to fix from outside (e.g., scope too narrow, single missing import)?
   YES -> (a) self-fix:
            orchestrator runs targeted edits + re-verifies the slice;
            mark teammate slice complete; continue p2.2 with surviving + this slice
   NO  -> step 2

2. Is a re-plan of the slice feasible (e.g., split the work, narrow scope)?
   YES -> (b) replacement teammate:
            new {teammate-id} = `openssl rand -hex 2` (fresh shortened guid;
              random space makes collision with failed id negligible, no bookkeeping);
            planner-style re-plan limited to the failed slice;
            spawn replacement via the Step 3 sequence (TeamCreate already exists for the session);
            distribute updated peer summaries to survivors via SendMessage;
            p2.2 shutdown waits for the replacement
   NO  -> step 3

3. Recovery is non-obvious -> (c) AskUserQuestion (header: "Teammate failure"):
        - "continue with surviving teammates" (drop the failed slice; flag in p2.7 summary)
        - "retry failed slice" (orchestrator reasons about why and decides between (a)/(b))
        - "abort Path 2" (run scripts/session-end-hook.sh {session} inline; exit cleanly)
        Dismiss / cancel = abort Path 2
```

Surviving teammates continue independently throughout the recovery. The replacement-teammate guid is freshly generated via `openssl rand -hex 2`; the random 4-char hex space (65k values) makes collision with the failed id negligible, so executor-trace files (`executor-{teammate-id}-{task-id}.md`) and scope / task artifacts stay collision-free with the failed run's leftovers without explicit "next unused index" bookkeeping.

## Scope write producer

`{session}-{teammate-id}-scope.json` is written EXCLUSIVELY by this skill (Step 1). No other apex skill writes the teammate scope artifact -- this is the single producer per `shared-guardrails.md` "Scope write producers".

See `shared-guardrails.md` for safety paths, scope-check hook resolution, trace path schema, mid-/apex abort cleanup, JSON Schema validation.
