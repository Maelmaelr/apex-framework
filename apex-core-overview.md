# /apex - Skeleton

What to load, when, under what condition. Full spec: `apex-core.md`.

Legend: `inline` = main-orchestrator inline prompt | `skill` = `~/.claude/skills/apex/*.md` | `agent` = `~/.claude/agents/*.md` | `script` = `~/.claude/skills/apex/scripts/*`.

---

## Tiers

| Tier     | Decided at | Effect                                                                       |
|----------|------------|------------------------------------------------------------------------------|
| trivial  | step 3     | step 3.1 inline edit -> jump to 14. Skips 4-13.                              |
| economy  | step 7     | step 8 executors = sonnet; step 11 learn skipped. All other steps run.       |
| standard | step 7     | step 8 executors = main session model; full tail.                            |

---

## Entry flow

Step 0 TaskCreates 1-15 (trivial detection at step 3 may collapse 4-13 into "skipped").

```
1. Analyze prompt + read project-context.md: inline
   - if ambiguous: AskUserQuestion (abort | clarification options)

2. Create session: create-session.sh
   - exit 10 (overlap):
     - stale-only: auto-cleanup-and-proceed (session-end-hook.sh <stale> --foreign per stale; re-run create-session.sh)
     - active: AskUserQuestion (abort | proceed-alongside | cleanup-stale-and-proceed)

3. Trivial pre-flight: inline
   - trivial = single-file edit, no new public symbol, named target file, ANY ambiguity = non-trivial
   - if trivial:
     - 3.1 inline single Edit/Write; orchestrator writes minimal hypothesis stub (original_prompt + one-line hypothesis) so step 15 contract stays uniform
     - jump to 14 (skip 4-13). Trade-off: no verify, no commit, no reflect; user owns lint/build + git add+commit.
   - if non-trivial: proceed to 4

4. Hypothesis: inline -> {session}-hypothesis.json
   - original_prompt, hypothesis, complexity_hint, alternatives, discovered_paths
   - validate-json.sh hypothesis.schema.json

5. Load lessons + project docs: grep-lessons.sh + update-hit.sh
   - project-context.md cached from step 1
   - tolerate empty output (no lessons-index.md = silent skip)

6. Discovery: discover.md
   seeds: prompt regex + hypothesis.discovered_paths + lessons paths + project-context paths
   cascade (stop at lowest non-empty bounded set):
     a. LSP find-references / definition (when seeds name a symbol; TS-only today)
     b. Glob sibling-pattern expansion (routing/registry/index splits)
     c. Grep keyword search (capped ~150 lines)
     d. Screener LLM gate: screener.md (single Sonnet call; always fires when cascade reaches this layer)
   output: {session}-main-scope.json
   write scope-check pointer: .claude-tmp/apex-active/{session}-scopes/{cc_session_id}.txt

7. Economy pre-flight: inline
   - AI judgement; inputs: {session}-hypothesis.json, {session}-main-scope.json (file count + paths), step 5 lessons hits
   - output: {session}-tier.json (validated against tier.schema.json) -> {tier: economy | standard, reason: <one line>}
   - downstream: step 8 executor model (sonnet vs main); step 11 learn skip flag

8. Execute: execute.md -> executor.md (per task)
   - 8.0 init: apex-baseline.sh (captures head_sha + pre_dirty for step 12 exclusion); apex-conflict-check.sh (cross-session scope overlap)
   - pre-flight wc -l on scope; >400 LOC -> queue split task ahead of edits
   - main orchestrator decides task count + per-task scope (default 1; splits into 2+ only for clearly independent areas); validate-disjoint-scopes.py enforces disjoint when 2+
   - spawn-prompt carries executor stack (hypothesis, per-task scope, lessons hits, project-context, task description) - subagents do NOT inherit working memory
   - file-health hook = safety net during edits
   - executor model: sonnet if economy, main session model if standard
   - dispatch-only: orchestrator MUST NOT inline Edit/Write/MultiEdit/NotebookEdit slice files at step 8

9. Polish: inline (touched INTERSECT scope)
   - staleness / inconsistency / unused check
   - lessons context advisory

10. Verify: verify-build.sh
    - if errors: executor.md (always Sonnet for fix-loop, regardless of step 8's tier; cap 3)
    - on cap exhaustion: AskUserQuestion (abort | proceed-with-errors)

11. Tail (foreground):
    - standard: parallel(documentation.md, learn.md)
    - economy: documentation.md only (learn skipped)

12. VERSION bump + git sync: bump-version.sh -> single chained git command
    - read <project-root>/VERSION (vX.Y.Z); missing = silent skip
    - inline classify diff -> minor | patch (never major; major is user-set)
    - increment + reset patch=0 on minor
    - git-stage-files.sh (change-set + pre-dirty/dotenv/check-ignore/cross-session filters + per-file add) && git commit -m "<freeform>" && git push (one chain)

13. Self-reflect: reflect-traces.sh + reflector.md (foreground)
    - reads traces in-place from .claude-tmp/apex-active/{session}-traces/
    - appends to ~/.claude/tmp/apex-workflow-improvements.md

14. Cleanup session: cleanup-session.sh
    - wipes session dir except {session}-hypothesis.json (do not clean concurrent session files)

15. Inline summary: inline
    - reads {session}-hypothesis.json
    - emits summary
    - removes hypothesis on success
```

---

## Mid-flow abort cleanup

Any orchestrator exit bypassing step 14 runs `session-end-hook.sh {session}` inline. Triggers:
- AskUserQuestion-abort at step 1 (no manifest yet -> skip session-end-hook)
- AskUserQuestion-abort at step 2 active-detected (no manifest written for this session -> skip)
- Step 6 cascade-empty (abort, or proceed-with-discovered-or-prompt-paths but zero validated)
- Step 8 conflict-check-abort
- Step 10 verify cap-3 exhaustion (if user opts to abort)
- Any unexpected error path

---

## Skip matrix

| Step | trivial | economy | standard |
|------|---------|---------|----------|
| 1    | run     | run     | run      |
| 2    | run     | run     | run      |
| 3    | run     | run     | run      |
| 3.1  | run     | -       | -        |
| 4    | skip    | run     | run      |
| 5    | skip    | run     | run      |
| 6    | skip    | run     | run      |
| 7    | skip    | run     | run      |
| 8    | skip    | run (sonnet) | run (main) |
| 9    | skip    | run     | run      |
| 10   | skip    | run     | run      |
| 11   | skip    | run (no learn) | run (full) |
| 12   | skip    | run     | run      |
| 13   | skip    | run     | run      |
| 14   | run     | run     | run      |
| 15   | run     | run     | run      |
