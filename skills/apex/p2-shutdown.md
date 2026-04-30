---
name: p2-shutdown
description: p2.2 owner. Per-teammate ack + shutdown_request, then TeamDelete. Blocked until every surviving teammate has completed (or been formally dropped via teammates.md failure-recovery (c)). Inline orchestrator action; no subagent.
---

# p2-shutdown (p2.2)

Spec: `apex-core.md` "Path 2 (p2)" p2.2 | `apex-core-overview.md` p2.2.

Pure inline orchestrator action - no skill spawn, no agent spawn. Runs after every surviving teammate has completed (or been formally dropped via the `teammates.md` failure-recovery (c) branch).

`teammates.md` already monitors and coordinates teammates until done; p2.2 begins once `TaskList` shows every teammate's terminal task `completed` (or dropped). The team itself remains active (members are still alive in the `apex-{session}` team) until this step retires them.

## Step 1: Per-teammate ack + shutdown_request

For each teammate still active in the team, send a one-line acknowledgement (resolves the teammate's last idle notification cleanly) then a `shutdown_request`. Teammates respond with `shutdown_response` and exit. Per `SendMessage` docs, originating `shutdown_request` here is explicitly authorised because the teammate's work is complete -- this is not a forced kill.

```
for tid in "${TEAMMATE_IDS[@]}"; do
  # ack final message (plain text)
  SendMessage
    to:      "$tid"
    summary: "ack p2.1 completion"
    message: "Task complete -- shutting down."

  # shutdown_request (structured); teammate replies with shutdown_response (approve=true) and exits
  SendMessage
    to:      "$tid"
    message: {"type": "shutdown_request", "reason": "p2.1 complete"}
done
```

Wait for every `shutdown_response` (or the equivalent post-shutdown idle notification) before proceeding. Replacement teammates (failure-recovery (b)) and survivors are treated identically -- both go through the same loop.

## Step 2: TeamDelete

Once every teammate has shut down (the team has zero active members), call `TeamDelete`. This removes:

- `~/.claude/teams/apex-{session}/` -- team config + member registry
- `~/.claude/tasks/apex-{session}/` -- the shared TaskList created by `TeamCreate` at p2.1

```
TeamDelete
```

`TeamDelete` fails if the team still has active members -- the per-teammate `shutdown_request` loop in Step 1 is mandatory before this call. The team name is resolved from the current session's team context (set by the `TeamCreate` call in `teammates.md` Step 3a).

## Failure-recovery interaction

If a teammate aborted earlier and was formally dropped via `teammates.md` failure-recovery (c) ("continue with surviving teammates"), it never registered as completing its task and was already removed from the team. Skip dropped teammates in the Step 1 loop -- they are not in `TEAMMATE_IDS`.

See `teammates.md` for the spawn / monitor contract; `teammates-failure.md` for the failure-recovery decision tree; `p2.md` for the surrounding p2.0 -> p2.7 chain.
