# apex-lessons (analyze phase): Reflect + Cleanup

Called from `analyze.md` after Route + Finalize. ALWAYS runs - including on early-exits (consolidate "no lessons", triage zero-remaining, all-verified). Closes the self-improvement loop by feeding Sonnet-reflector signals into `~/.claude/tmp/apex-workflow-improvements.md` (consumed by `/apex-improve`'s next run).

This phase is the final task in the analyze TaskCreate chain (Reflect + Cleanup).

## Step 10: Spawn reflector

Spawn `agents/reflector.md` (Sonnet, foreground) with the `lessons-analyze` phase. The agent reads its own contract (`agents/reflector.md` invocation-table row `lessons-analyze`); this skill supplies only the run-specific context.

Spawn-prompt template (substitute `{run}`):

```
You are agents/reflector.md. Read it at $HOME/.claude/agents/reflector.md and
follow the `lessons-analyze` row of the invocation table. No reflect-traces.sh
heuristic block exists for this phase; inputs are this run's per-task summary
trace + JSON artifacts at .claude-tmp/lessons-analyze-active/{run}-*.

Token:    {run}              # 8-hex; used in place of {session}
Phase:    lessons-analyze
Manifest: .claude-tmp/lessons-analyze-active/{run}.json   # CWD-relative; CWD is the project root.

Errors -> ~/.claude/tmp/reflector-errors.log (silent failure otherwise).
Shut down silently (no main-session output).
```

The reflector writes a structured block to `~/.claude/tmp/apex-workflow-improvements.md` (header `## {run} - lessons-analyze - {ts}`). The block is consumed by `/apex-improve`'s next run.

## Step 10.5: Cleanup

After reflector returns:

```
bash skills/apex-lessons/scripts/cleanup-run.sh --phase analyze --run {run} --post-success
```

Removes `.claude-tmp/lessons-analyze-active/{run}-*` and the `{run}.json` manifest. The `--post-success` flag bypasses the 60s in-flight mtime guard (the just-written `{run}-summary.md` keeps the guard armed otherwise).

Reflector failure does NOT block cleanup - the agent self-silences per its contract; signal loss for one run is acceptable, leaking artifacts into the next session is not.

Mark Reflect + Cleanup task completed.

## Phase rules

- Reflect even on early-exits - the early-exit reason (consolidate "no lessons", triage zero-remaining, all-verified) IS the gap signal. Run the reflector with the summary trace as-is.
- Cleanup runs unconditionally after reflector return - the agent's silent-failure contract means absence of output cannot be read as "still in use".
- Leave `~/.claude/tmp/apex-workflow-improvements.md` in place - it is per-CC-session-spanning; truncated by `/apex-improve` Step 5 only.
