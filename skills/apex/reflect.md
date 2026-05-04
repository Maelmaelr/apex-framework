---
name: reflect
description: step 10 / p1.4 / p2.5 self-reflect orchestrator. Runs scripts/reflect-traces.sh to append a heuristics block (focus-routing input), then spawns agents/reflector.md (Haiku) - background at step 10, foreground at p1.4 / p2.5. The novel_traces line in the heuristics block drives where the reflector focuses.
---

# reflect (step 10 / p1.4 / p2.5)

Spec: `apex-core.md` step 10 / p1.4 / p2.5 | `agents/reflector.md` invocation table.

Single skill body, three invocation contexts. Caller passes `--phase` and `--session`. Phase choice drives trace inputs, snapshot filename, foreground/background, and which manifest field (`cc_session_id` vs `p2_cc_session_id`) the reflector uses to locate its TaskList.

## Invocation contexts

| Caller | Phase arg | Foreground? | Trace inputs (snapshot) | Snapshot file | Manifest field |
|--------|-----------|-------------|--------------------------|---------------|----------------|
| `SKILL.md` step 10 (Path 2 only) | `entryflow` | background | `{session}-traces/entryflow/*.md` | `/tmp/{session}-entryflow-snapshot.txt` | `cc_session_id` |
| `p1.md` p1.4 (main mode only) | `entryflow+p1` | foreground | `{session}-traces/entryflow/*.md` + `{session}-traces/p1/*.md` | `/tmp/{session}-p1-snapshot.txt` | `cc_session_id` |
| `p2.md` p2.5 (after p2.4) | `p2` | foreground | `{session}-traces/p2/*.md` | `/tmp/{session}-p2-snapshot.txt` | `p2_cc_session_id` |

The p1.4 snapshot suffix is `p1` (NOT `entryflow+p1`) - phase param and snapshot filename intentionally differ.

Teammate mode (`p1.md --teammate`) skips this skill entirely - central p2.5 owns Path 2 reflection.

## Step 1: Run the heuristics script

```
bash $HOME/.claude/skills/apex/scripts/reflect-traces.sh --session {session} --phase {phase}
```

Always exits 0; always appends a block (under `flock` via `append-with-lock.sh`) so the reflector spawn prompt can read the latest `novel_traces:` paths. Block format:

```
## {session} - {phase}-heuristics - {timestamp}
- gap_signals: <count>
- fix_attempts: <count>
- verbose_traces: <count>
- novel_flagged: <count>
- novel_traces: <comma-separated trace paths, max 5>
```

## Step 2: Spawn agents/reflector.md (Haiku)

Foreground vs background per the table above (`run_in_background: true` for `entryflow`, default foreground for `entryflow+p1` / `p2`). One Agent tool call, model = haiku. When background-spawned (entryflow phase), the orchestrator MUST mark the corresponding task `completed` in the SAME response as the spawn - the reflector is a fire-and-forget telemetry signal, never a blocking dependency, and waiting for it soft-blocks p2.0a.

**Resolve project root before composing the prompt.** Run `pwd` (orchestrator CWD = project root by /apex contract) and capture the output as `{project_root}`. The Manifest + Hypothesis paths in the spawn prompt MUST be absolute - subagent CWD inheritance is unreliable (Haiku subagents have been observed to land at `~/.claude` where the agent file lives, NOT the project root), and the manifest sits at `<project>/.claude-tmp/apex-active/...` for apex hot path. A relative path silently misses, every Read fails, the reflector falls through to SKIPPED-no-inputs, and `workflow-respected` / `token-reductions` checks never reach the log. Fixed in 2026-05-04 after 4-out-of-5 SKIPPED entryflow+p1 reflections accumulated in the per-day archives.

Spawn-prompt template (substitute `{session}`, `{phase}`, `{snapshot_suffix}` per the table - `entryflow` | `p1` | `p2` - and `{project_root}` per the resolution above):

```
You are agents/reflector.md. Read it at $HOME/.claude/agents/reflector.md and follow it.

Session:    {session}
Phase:      {phase}             # entryflow | entryflow+p1 | p2
Manifest:   {project_root}/.claude-tmp/apex-active/{session}.json          # absolute (orchestrator pwd-resolved)
Hypothesis: {project_root}/.claude-tmp/apex-active/{session}-hypothesis.json  # absolute; preserved across p1.5 / p2.6 cleanup; carries original_prompt + hypothesis + complexity_hint + alternatives
Snapshot:   /tmp/{session}-{snapshot_suffix}-snapshot.txt                  # absolute
```

Manifest-readable + Hypothesis-readable -> structured block (gaps / fixes-observed / improvements / workflow-respected / token-reductions). Both unreadable AND snapshot is the literal `[no source files...]` placeholder -> SKIPPED-no-inputs sentinel via `bash $HOME/.claude/skills/apex/scripts/emit-reflector-skipped.sh {session} {phase}`. See agents/reflector.md "Empty-input gate" for the strict 2-AND contract.

## Fail-silent contract

Reflection is an improvement signal, not a correctness gate. Both `reflect-traces.sh` and the reflector self-silence (errors -> `~/.claude/tmp/reflector-errors.log`); the chain (p1.5 / p2.6) is never blocked.

The `/tmp/{session}-{suffix}-snapshot.txt` files are written by the reflector and removed by `cleanup-session.sh` (p1.5 / p2.6) via the `/tmp/{session}-*` glob.

See `agents/reflector.md` for the agent's input/output contract; `scripts/reflect-traces.sh` for the heuristic categorisation; `shared-guardrails.md` for safety paths, manifest schema, trace path schema.
