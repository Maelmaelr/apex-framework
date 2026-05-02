---
name: teammates-failure
description: Failure-recovery decision tree for p2.1 teammates. Three branches (a self-fix / b replacement teammate / c AskUserQuestion). Consumed by teammates.md when an executor abort, scope-check rejection, or in-teammate failure surfaces; never spawns a subagent itself.
---

# teammates-failure (p2.1 failure-recovery)

Spec: `apex-core.md` "Path 2 (p2)" p2.1 + "Teammate-failure handling" | `apex-core-overview.md` p2.1.

Owned by `teammates.md` (Failure-recovery decision tree section). Inline orchestrator decision tree - no subagent spawn here.

## Decision tree

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

## Cross-references

- (a) self-fix and (b) replacement both leave `p2.2` shutdown waiting on the new completion signal; `p2-shutdown.md` Step 1 loop already accounts for replacements.
- (c) abort branch is the same code path as plan-mode rejection at p2.0c - both run `scripts/session-end-hook.sh {session}` inline before exiting per `shared-guardrails.md` "Mid-/apex abort cleanup".
- See `teammates.md` for the spawn / monitor contract; `p2-shutdown.md` for p2.2 ack + TeamDelete; `shared-guardrails.md` for safety paths and abort cleanup.
