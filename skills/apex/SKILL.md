---
name: apex
description: Main coding orchestrator. Linear 15-step flow with three tiers (trivial / economy / standard). Trivial decided at step 3; economy decided at step 7. Determinism via session manifest, scope-check hook, file-health hook, bounded fix-loop. Inline orchestrator + delegates to skills/agents per step.
---

# /apex

Main session orchestrator. Full behavioral contract: `apex-core.md`. Light-read skeleton + skip matrix: `apex-core-overview.md`.

## Step 0: queue tasks

```
TaskCreate "1.  Analyze + read project-context.md"
TaskCreate "2.  Create session manifest"
TaskCreate "3.  Trivial pre-flight"
TaskCreate "4.  Hypothesis"
TaskCreate "5.  Load lessons"
TaskCreate "6.  Discovery"
TaskCreate "7.  Economy pre-flight"
TaskCreate "8.  Execute"
TaskCreate "9.  Polish"
TaskCreate "10. Verify"
TaskCreate "11. Tail (documentation [+learn])"
TaskCreate "12. VERSION bump + git sync"
TaskCreate "13. Self-reflect"
TaskCreate "14. Cleanup session"
TaskCreate "15. Inline summary"
```

All 15 always queued. Trivial branch at step 3 marks 4-13 completed-skipped.

## Tier matrix

| Tier     | Decided at | Effect                                                                |
|----------|------------|-----------------------------------------------------------------------|
| trivial  | step 3     | Step 3.1 inline `Edit` / `Write` -> jump to 14. Skips 4-13.           |
| economy  | step 7     | Step 8 executors run on Sonnet; step 11 skips `learn`.                |
| standard | step 7     | Step 8 executors run on the main session model; full tail.            |

## Step contracts (terse)

1. **Analyze** - inline. AskUserQuestion if ambiguous; abort = clean exit (no manifest yet, skip session-end-hook). Read `<project-root>/docs/project-context.md` (best-effort; absent = silent skip; cached for downstream).
2. **Session manifest** - `bash skills/apex/scripts/create-session.sh --cc-session-id "$(bash skills/apex/scripts/get-cc-session-id.sh)"`.
   - exit 0: `{session}` token to stdout; manifest written + producer-validated.
   - exit 10: stale-only -> auto-cleanup-and-proceed (`bash skills/apex/scripts/session-end-hook.sh <stale-token> --foreign` per stale; re-run create-session). Active-detected -> AskUserQuestion (`abort` | `proceed alongside` | `cleanup-stale-and-proceed`); dismiss/cancel = abort. On abort with no manifest: skip session-end-hook and exit cleanly.
3. **Trivial pre-flight** - inline. Trivial = ALL of: single file edit (or single new file) AND file path explicitly named in `original_prompt` AND no new public symbol / endpoint / component AND no cross-file dependency. ANY ambiguity = non-trivial.
   - **3.1** (trivial only): inline `Write` of `{session}-main-scope.json` (`allowed_files = [<the single file>] + safety paths`) + scope-check pointer at `.claude-tmp/apex-active/{session}-scopes/{cc_session_id}.txt`. Inline `Write` of minimal hypothesis stub (`original_prompt` verbatim; `hypothesis` = one-line restatement; `complexity_hint = "low"`; `alternatives = [{interpretation: original_prompt, status: "kept", reason: "trivial path"}]`; producer-validate via `bash skills/apex/scripts/validate-json.sh hypothesis.schema.json <path>`). Inline `Edit` / `Write` of the target. Jump to step 14.
   - Trivial trade-off: skips verify (10), commit (12), reflect (13). User owns lint/build + `git add+commit` afterwards.
4. **Hypothesis** - inline. Emit `original_prompt` (verbatim user prompt; do NOT paraphrase) + `hypothesis` (1-2 sentence working interpretation) + `complexity_hint: low|medium|high` + `alternatives: [{interpretation, status: kept|rejected, reason}]` (1-3 entries; structured anti-bias check; minItems: 1 schema-required) + optional `discovered_paths: [<paths>]` (validated repo-relative paths from bounded inline `Glob` / `Grep` / `Read`, cap ~5 calls when the prompt is conceptual; persist only paths that exist on disk; empty/absent when the prompt itself names paths or is too abstract). Write to `.claude-tmp/apex-active/{session}-hypothesis.json`; producer-validate via `bash skills/apex/scripts/validate-json.sh hypothesis.schema.json <path>`. Validation failure = abort with explicit error.
5. **Load lessons + project docs** - `bash skills/apex/scripts/grep-lessons.sh <project-root> <term1> [<term2> ...]` reads `<project-root>/.claude/lessons-index.md` + `lessons.md` for ~8 keywords derived from `{session}-hypothesis.json`. Then `bash skills/apex/scripts/update-hit.sh <project-root>/.claude/lessons.md <line>...` bumps hit timestamps. Tolerate empty output (no `lessons-index.md` -> silent skip). Project-context cached from step 1. Working memory propagates lessons hits + matched paths + project context to steps 6 / 8 / 9 / 10 / 11.
6. **Discovery** - skill `skills/apex/discover.md`. Layered cascade (LSP -> Glob -> Grep -> screener gate); seeds = regex tokens from prompt + hypothesis.discovered_paths + lessons paths + project-context paths. Output: `{session}-main-scope.json` + scope-check pointer. Cascade-empty -> AskUserQuestion (`abort` | `proceed-with-discovered-or-prompt-paths`); dismiss/cancel = abort. Both empty -> abort runs `session-end-hook.sh` inline.
7. **Economy pre-flight** - inline. Single AI-judged emit (no subagent). Inputs: `{session}-hypothesis.json`, `{session}-main-scope.json` (file count + paths), step 5 lessons hits. Prompt:
   ```
   Classify tier: "economy" | "standard".
   Economy when: bounded scope, no new public abstractions, reversible risk, no cross-cutting concerns.
   Standard when: unclear scope, new public surface, irreversible risk, or "rewrite/migrate/redesign" intent.
   Output JSON: {"tier": "economy"|"standard", "reason": "<one line>"}
   ```
   Write `{session}-tier.json`; producer-validate via `bash skills/apex/scripts/validate-json.sh tier.schema.json <path>`. Drives step 8 executor model + step 11 learn skip.
8. **Execute** - skill `skills/apex/execute.md`. 8.0 baseline + conflict check; 8.1 wc-l split queue; 8.2 task split + disjoint-scopes validation (`python3 skills/apex/scripts/validate-disjoint-scopes.py`); 8.3 dispatch `agents/executor.md` per task (Sonnet if economy, main model if standard; spawn-prompt carries explicit working-memory propagation). Orchestrator MUST NOT inline `Edit` / `Write` / `MultiEdit` / `NotebookEdit` of scope files at step 8.
9. **Polish** - inline (host model). Touched-by-apex set: `(git diff --name-only {baseline.head_sha}; git ls-files --others --exclude-standard) | sort -u` from `{session}-baseline.json`, INTERSECTED with `allowed_files` from `{session}-main-scope.json`. In-scope-only fixes: unused imports orphaned by step 8, dead code orphaned by step 8, leftover commented-out blocks in touched lines, obvious naming inconsistencies in newly-touched lines. Lessons hits inform staleness signals (advisory). Hard cap = intersected set; scope-check hook is outer guard. No-op exit if nothing actionable.
10. **Verify** - `bash skills/apex/scripts/verify-build.sh` (project-aware: `package.json` / `Cargo.toml` / `pyproject.toml` / `go.mod`; first-fail-stop).
    - exit 0 = clean, proceed.
    - non-zero = errors at `.claude-tmp/apex-active/{session}-verify-errors.txt`. Dispatch `agents/executor.md` (always Sonnet, regardless of step 8 tier; trace at `{session}-traces/verify/fix-{attempt-N}.md`). Counter at `{session}-fix-attempts.json` (producer-validated). Cap 3. On cap exhaustion: AskUserQuestion (`abort` | `proceed-with-errors`). `abort` -> clean exit via `session-end-hook.sh {session}` inline. `proceed-with-errors` -> append errors to `~/.claude/tmp/git-agent-errors.log`; fall through to step 11.
11. **Tail** (foreground; Sonnet latest):
    - **standard**: parallel(`agents/documentation.md`, `agents/learn.md`).
    - **economy**: `agents/documentation.md` only (`learn` skipped).
    - Both read `git diff {baseline.head_sha}`. `learn` appends to `.claude-tmp/lessons-tmp.md` under `flock` (via `bash skills/apex/scripts/append-with-lock.sh`).
12. **VERSION bump + git sync** - read `<project-root>/VERSION` (`vX.Y.Z`; missing = silent skip). Inline-classify diff -> `minor` | `patch`. Never `major` (user-set only). Then:
    ```
    bash skills/apex/scripts/bump-version.sh --kind {minor|patch}
    ```
    Single chained git command (one Bash call):
    ```
    bash skills/apex/scripts/git-stage-files.sh --head-sha {baseline.head_sha} --session {session} && git commit -m "<freeform>" && git push
    ```
    `git-stage-files.sh` owns the change-set + filters (pre-dirty, dotenv allowlist, `git check-ignore`, cross-session). Push fail-silent (errors -> `~/.claude/tmp/git-agent-errors.log`).
13. **Self-reflect** - `bash skills/apex/scripts/reflect-traces.sh` writes a heuristic block to `~/.claude/tmp/apex-workflow-improvements.md` under `flock` (via `bash skills/apex/scripts/append-with-lock.sh`). Then spawn `agents/reflector.md` (Haiku, **foreground**, silent). Reflector reads traces in-place from `.claude-tmp/apex-active/{session}-traces/` (NO snapshot - step 14 cleanup is the only follow-up and explicitly blocks on step 13).
14. **Cleanup session** - `bash skills/apex/scripts/cleanup-session.sh --session {session} --post-success`. Idempotent. `--post-success` bypasses the live-PID guard for trusted own-session callers. Does NOT clean `{session}-hypothesis.json` (consumed by step 15).
15. **Inline summary** - inline. Read `{session}-hypothesis.json` (preserved by step 14). Emit:
    - Original prompt summary (from `original_prompt`)
    - Hypothesis vs reality (gaps spotted)
    - Short executive summary
    On success: remove `.claude-tmp/apex-active/{session}-hypothesis.json` (consumer cleans up its own input; SessionEnd-hook fallback otherwise).

## Mid-flow abort cleanup

Any orchestrator exit bypassing step 14 runs `bash skills/apex/scripts/session-end-hook.sh {session}` inline. Triggers:
- AskUserQuestion-abort at step 1 (no manifest yet -> skip session-end-hook)
- AskUserQuestion-abort at step 2 active-detected (no manifest written -> skip)
- Step 6 cascade-empty + abort
- Step 6 cascade-empty + proceed-with-prompt-paths but zero validated paths
- Step 8 conflict-check abort
- Step 10 verify cap-3 + `abort`
- Any unexpected error path

Claude Code SessionEnd hook catches the case where the entire CC session ends mid-/apex; the inline call covers "user aborts /apex but stays in the same CC session" so the manifest does not orphan and trigger false-positive concurrency from sibling /apex calls.

See `apex-core.md` for the full per-step contract (artifacts, exit codes, schemas, abort paths) and Conventions block (safety paths, cc_session_id resolution, manifest schema, scope-check hook, file-health hook, trace path schema, JSON-Schema validation).
