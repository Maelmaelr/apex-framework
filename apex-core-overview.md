# /apex - Skeleton

What to load, when, under what condition. Full spec: `apex-core.md`.

Legend: `inline` = main-orchestrator inline prompt | `skill` = `~/.claude/skills/apex/*.md` | `agent` = `~/.claude/agents/*.md` | `script` = `~/.claude/skills/apex/scripts/*`.

---

## Entry flow

Step 0 TaskCreates 1-5.

```
1. Analyze prompt        inline (reads docs/project-context.md if present)
2. Create session        create-session.sh
3. Hypothesis            inline -> {session}-hypothesis.json
4. Load lessons          grep-lessons.sh + update-hit.sh
5. Trivial detection     inline
   trivial      -> trivial.md writes scope -> p1.md          [skip 6-9]
   non-trivial  -> TaskCreate 6-9
```

```
6.  Scout phase 1        scout1.md (TaskCreates 6.a, 6.b, 6.c)
 6.a Enumerate           enumerate scripts -> findings-{session}.json
       zero-layer        -> zero-layer-extract.sh writes scope -> p1.md   [skip 6.b/c, 7-9]
 6.b Shard               shard script -> shard-plan-{session}.json
       >8 shards         -> AskUserQuestion (refine | proceed-with-prompt-paths | continue)
                            proceed-with-prompt-paths -> p1.md            [skip 6.c, 7-9]
 6.c Screen              screener.md (Sonnet, parallel) -> screened-{session}.json
7.  Scout phase 2        scout2.md -> preflight-{session}.json
 7.x Targeted rescout    rescout.md (Sonnet, only if missed_regions != [])
8.  Verify claims        verify-claims.sh
       exit 0 -> proceed (scope written)
       exit 1 -> abort (preflight_bad | screened_unconverged)
       exit 2 -> re-run 6.c+7 (cap 1)
       exit 3 -> inline review -> verify-claims.sh --apply-resolved
9.  Decide path          decide-path.sh
       medium  -> p1.md
       complex -> TaskCreate 10, p2.0a, p2.0b, p2.0c
10. Self-reflect (P2)    reflect-traces.sh + reflector.md (Haiku, background)
```

---

## Path 1

p1.0 TaskCreates p1.1 -> p1.6 (main mode) | p1.1, p1.1b, p1.3, p1.6 (teammate trim).

```
p1.0  Init               p1.md (main: baseline + concurrent-apex conflict-check)
p1.1  Implement          implement.md -> executor.md (Sonnet, per task, parallel where possible)
p1.1b Polish             polish.md (inline; touched-by-apex INTERSECT scope)
p1.2  Verify+fix         verify-fix.md -> verify-build.sh -> executor.md (cap 3)   [main only]
p1.3  Tail               detect-tail-mode.sh -> agents (parallel, Sonnet)
                           economy = git.md only
                           full    = learn.md + documentation.md + git.md
                           teammate = documentation.md only
p1.4  Self-reflect       reflect-traces.sh + reflector.md (Haiku, fg, param=entryflow+p1)  [main only]
p1.5  Cleanup session    cleanup-session.sh   [main only]
p1.6  Inline summary     inline (reads hypothesis | {teammate-id}-task.md; removes hypothesis on success)
```

Teammate trim (under Path 2): `p1.0 -> p1.1 -> p1.1b -> p1.3 (docs only) -> p1.6`.

---

## Path 2

```
p2.0a Enter plan mode    EnterPlanMode (plan-mode.md)
p2.0b Embed plan         planner.md (validates via validate-disjoint-scopes.py)
p2.0c Exit plan mode     ExitPlanMode (plan-mode.md)
        rejected         -> abort (session-end-hook.sh inline)
```

After context clear, p2.0 TaskCreates p2.1 -> p2.7.

```
p2.0  Init (post-clear)  p2.md (baseline + conflict-check; appends p2_cc_session_id)
p2.1  Setup teammates    teammates.md (inline, Opus). Each teammate calls p1.md --teammate.
                           failure -> teammates-failure.md (a self-fix | b replace | c AskUserQuestion)
p2.2  Shutdown           p2-shutdown.md (inline; per-teammate ack + shutdown_request + TeamDelete)
p2.3  Verify+fix         verify-fix.md -> verify-build.sh -> executor.md (central, cap 3)
p2.4  Tail+shared docs   detect-tail-mode.sh -> agents (parallel)
                           documentation.md owns first-write on planner's shared_files
p2.5  Self-reflect       reflect-traces.sh + reflector.md (Haiku, fg, param=p2)
p2.6  Cleanup session    cleanup-session.sh
p2.7  Inline summary     inline
```

---

## Reflector

- `reflect-traces.sh`: heuristic regex (`error|failed|skip`); counts `fix-attempt-N.md`; lists verbose traces; appends block to `~/.claude/tmp/apex-workflow-improvements.md` under `flock`. Flags novel traces in `novel_traces:` line.
- `reflector.md` (Haiku): always fires (since v1.4.0). Background at step 10 (entryflow); foreground at p1.4 / p2.5. Snapshots traces (50KB cap). Errors -> `~/.claude/tmp/reflector-errors.log` (silent).
- Consumer: `/apex-improve` (auto-fired by `/apex-eod` step 3) reads the log alongside `/apex-tech-watch` output -> framework edits.

---

## See `apex-core.md` for

scope enforcement (scope-check hook, scope write producers, safety paths) | `project-context.md` read contract | failure handling (`session-end-hook.sh`, mid-/apex abort cleanup) | trace files schema (`.claude-tmp/apex-active/{session}-traces/{phase}/`) | artifact validation (JSON Schemas at `skills/apex/schemas/`) | conventions (session token, `cc_session_id` resolution, manifest schema)
