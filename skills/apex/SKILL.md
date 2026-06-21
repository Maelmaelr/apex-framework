---
name: apex
description: Main coding orchestrator. Linear 15-step flow with three tiers (trivial / economy / standard). Trivial decided at step 3; economy decided at step 7. Determinism via session manifest, scope-check hook, file-health hook, bounded fix-loop. Inline orchestrator + delegates to skills/agents per step.
---

# /apex

Main session orchestrator. This SKILL plus the lazy-loaded `steps/NN-*.md` per-step contracts are the complete runtime spec - self-contained, read nothing else to run /apex.

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
TaskCreate "12. Commit + persist bump_hint"
TaskCreate "13. Self-reflect"
TaskCreate "14. Cleanup session"
TaskCreate "15. Inline summary"
```

All 15 always queued. Trivial branch at step 3 marks 4-13 completed-skipped.

**Deferred-tool guard.** `TaskCreate`/`TaskUpdate`/`TaskList` are deferred (schema absent at session start) - load once via `ToolSearch select:TaskCreate,TaskUpdate,TaskList` before queuing. If a `TaskCreate` errors (`InputValidationError` / "schema not sent to the API"), do NOT fire the remaining queue calls - re-run that ToolSearch load, then retry ONCE; a second failure -> STOP and surface to the user (an empty/flaky ToolSearch return makes every call fail identically, so re-firing all 15 is the failure mode not the fix).

## Tier matrix

| Tier     | Decided at | Effect                                                                                                  |
|----------|------------|---------------------------------------------------------------------------------------------------------|
| trivial  | step 3     | Step 3.1 inline `Edit`/`Write` + commit -> jump to 14. Skips 4-13.                                      |
| economy  | step 7     | Step 8 executors run on Sonnet; step 9 polish + step 10.5 review skipped; step 11 skips `learn`.        |
| standard | step 7     | Step 8 executors run on Opus; full tail (step 9 polish always; step 11 documentation unless `code-only-no-docs` mode; learn runs when the difficulty gate holds - no tier-conditional skip path under standard). |

Step 13 reflector is **background** in non-trivial paths (economy + standard); the reflector owns the post-reflect `cleanup-session.sh` call as its final action. Step 14 only runs on the trivial path (where step 13 was skipped).

## Per-step dispatch (read-before-work gate)

Dispatch each step N in this exact order - the order is load-bearing for the `step-read-gate-hook.sh` gate (settings.json, wired at all touchpoints):
1. `TaskUpdate(taskId=N, status="in_progress", metadata={step: N})` - the step-start signal; stamps the gate's `active_step`/`active_since`.
2. `Read(skills/apex/steps/NN-*.md)` - loads the contract. It MUST follow the step-1 `TaskUpdate`: a read taken before the step became active does not satisfy the gate (`read_steps[N] >= active_since`).
3. Step work (`Edit` / `Write` / `MultiEdit` / `NotebookEdit` / `Task` / `Bash`) - the gate denies the first work tool of step N until its contract has been read since activation, then passes for the rest of the step.

The trivial branch still marks step 3 `in_progress` with `metadata={step: 3}` before its 3.1 inline `Edit`. Step 0 (the `TaskCreate` queue) runs before any step is active, so the gate fail-opens there. The gate is orchestrator-only and fail-opens on every non-apex / unset-step / parse-error path (`skills/apex/scripts/step-read-gate-hook.sh`). R3-a perf + a real-transcript canary green were signed off over a captured standard run at VERSION 10.0.0 (replay via `skills/apex/scripts/replay-canary.sh`).

## Step contracts (terse)

1. **Analyze** - lazy step. Read `skills/apex/steps/01-analyze.md` before executing. Inline analyze + project-context read; early-scope-narrowing / review-only / deploy-doc / switch-verb / plan-completed gates; abort = clean exit (no manifest yet, skip session-end-hook).
2. **Session manifest** - lazy step. Read `skills/apex/steps/02-manifest.md` before executing. `create-session.sh` mints the worktree + manifest; exit 0 -> `{session}` token (test -d the worktree, never fabricate); exit 1 -> abort cleanly.
3. **Trivial pre-flight** - lazy step. Read `skills/apex/steps/03-trivial.md` before executing. Inline trivial gate (single named file, no new public symbol, no cross-file dep); trivial -> 3.1 inline edit+commit, jump to 14, skip 4-13.
4. **Hypothesis** - lazy step. Read `skills/apex/steps/04-hypothesis.md` before executing. Inline emit of `original_prompt` + hypothesis + `alternatives` + `goals` -> `{session}-hypothesis.json` (producer-validated); mandatory under EVERY mode.
5. **Load lessons + project docs** - lazy step. Read `skills/apex/steps/05-lessons.md` before executing. `grep-lessons.sh` + screener gate (K=25 inline; Haiku >25); propagate `goals[]`-axis-filtered kept lessons to steps 6/8/9/10/11.
6. **Discovery** - lazy step. Read `skills/apex/steps/06-discovery.md` before executing. `agents/discoverer.md` cache-check then LSP -> `discovery-expand.sh` (one-call deterministic expansion) -> screener cascade (or inline-skip); writes `{session}-main-scope.json` + scope-check pointer.
7. **Economy pre-flight** - lazy step. Read `skills/apex/steps/07-economy.md` before executing. Inline deterministic tier rule -> `{session}-tier.json`; drives step-8 executor model + step-9 polish / step-10.5 review / step-11 learn skips.
8. **Execute** - lazy step. Read `skills/apex/steps/08-execute.md` before executing. 8.0 diff_anchor resolve (`git merge-base $base_branch HEAD` from manifest); 8.1 wc-l split queue; 8.2 goals-driven task split (B0-B3 pre-splits: concerns-aware, decomposition scout, scope-size hard split + B1 enum-exception, coupled-merge sequential ceiling, read-only audit cluster; barrel-file owner sub-goal; disjoint-scopes validation); 8.3 dispatch `agents/executor.md` per task (Sonnet economy / Opus standard; parallel via `run_in_background` when N>=2; explicit spawn-prompt context E1-E3 + helper_snapshot; dispatch-summary actuals + post-dispatch self-report reconciliation + cross-scope rollup). Orchestrator MUST NOT inline `Edit` / `Write` / `MultiEdit` / `NotebookEdit` of scope files at step 8.
9. **Polish** - lazy step. Read `skills/apex/steps/09-polish.md` before executing (standard ALWAYS runs; economy skips - the skip gate is here so economy short-circuits without the read). In-scope-only cleanup via `agents/polish.md`; returns one-line summary, no-op if nothing actionable.
10. **Verify** - lazy step. Read `skills/apex/steps/10-verify.md` before executing. `verify-build.sh --session {session} --with-tests --in-scope-only` (project-aware, first-fail-stop); exit 0 -> 10.5 review; non-zero -> scope-partition fix-loop (in-scope-changed -> `agents/executor.md` Sonnet, cap 3; in-scope-foreign-line / out-of-scope parked to `~/.claude/tmp/git-agent-errors.log`). **10.5 Review** (runs only after exit 0) fires under standard tier on a non-trivial diff (>=3 in-scope files + complexity / structural-deletion / verb signal, or the doc-consistency carve-out) -> `agents/reviewer.md` (Sonnet, foreground; cap 2 reviews + 1 fix); economy skips polish + review.
11. **Tail** - lazy step. Read `skills/apex/steps/11-tail.md` before executing. `agents/documentation.md` (UNLESS `code-only-no-docs`) + `agents/learn.md` (standard, difficulty-gate `count>=1`); economy = doc only.
12. **Commit + persist bump_hint** - lazy step. Read `skills/apex/steps/12-commit.md` before executing. Inline `git add -A` / commit / push `apex/{session}`; classify diff -> `bump_hint` persisted in manifest; empty diff is valid.
13. **Self-reflect** - lazy step. Read `skills/apex/steps/13-reflect.md` before executing. `reflect-traces.sh` + background `agents/reflector.md` (owns post-reflect `cleanup-session.sh` + non-convergence detection).
14. **Cleanup session (trivial-only)** - lazy step. Read `skills/apex/steps/14-cleanup.md` before executing. Runs ONLY when step 13 was skipped (trivial path; non-trivial cleanup comes from the step-13 reflector); `cleanup-session.sh`, idempotent, worktree-only.
15. **Inline summary** - lazy step. Read `skills/apex/steps/15-summary.md` before executing. 15.0 cd-back sweep first; emit the fixed deterministic sections (Original request / Hypothesis vs reality / Root cause / Per-goal status / Mid-run notes / Result); then close task 15.

## Cross-step invariants

Coordination that spans steps - the orchestrator owns these because no single step file does; each step file holds its own mechanics, this is the canonical map (do NOT re-state the coupling per step file).
- **Scope is seeded up-front, never grown at the tail (steps 1/6 -> 8/11/12).** Step 1 pre-coordinates the doc-touch surface (`full-scope`, report-only deliverable paths; `code-only-no-docs` instead skips the step-11 doc agent and admits no doc paths) and step 6 folds the doc-surface + co-located test files into `allowed_files` at scope-finalization - so steps 8/11/12 act inside a fixed scope and never reactively expand it. A reactive step-12 doc/scope expand means step 1/6 under-populated `allowed_files`.
- **Doc-fold feeds the tail (step 6 -> 11/12).** The doc-surface files step 6 folds into `allowed_files` are exactly what step 11's documentation agent edits and step 12 stages; a doc edit stranded outside `allowed_files` at step 12 is an under-populated step 6, not a step-12 bug.
- **Tier drives the tail (step 7 -> 8/9/10.5/11).** The step-7 tier selects the step-8 executor model (Sonnet economy / Opus standard) and gates step-9 polish + step-10.5 review + step-11 learn (economy skips all three) - see the Tier matrix above; step files must not re-derive the tier.

## Mid-flow abort cleanup

Any orchestrator exit bypassing step 14 runs `bash skills/apex/scripts/session-end-hook.sh {session}` inline. Triggers:
- AskUserQuestion-abort at step 1 (no manifest yet -> skip session-end-hook)
- Step 6 cascade-empty + abort
- Step 6 cascade-empty + proceed-with-prompt-paths but zero validated paths
- Step 10 verify cap-3 + `abort`
- Any unexpected error path

Claude Code SessionEnd hook catches the case where the entire CC session ends mid-/apex; the inline call covers "user aborts /apex but stays in the same CC session" so the worktree-resident manifest is swept and the worktree dir is cleaned. After the inline `session-end-hook.sh {session}` call, the orchestrator MUST `cd "$(session-end-hook.sh ... output | tail -1)"` (the forwarded cleanup-session.sh stdout, the main-worktree absolute path) so the shell leaves the (possibly removed) worktree before /apex returns control to the user.

## Parallel CC sessions on one project

Two Claude Code sessions running /apex against the same project repo mint independent worktrees (`<main>/.apex-worktrees/<sessionA>/`, `<main>/.apex-worktrees/<sessionB>/`) on independent branches (`apex/<sessionA>`, `apex/<sessionB>`). Each has its own index, working tree, and `.claude-tmp/apex-active/`; the sessions do not observe each other's edits during execution. Each lands back on its recorded `base_branch` via its own `/apex-merge` run; textual overlap surfaces as a conflict in the standard `/apex-merge` step 4 resolver flow. No coordination is required at mint - worktree isolation is the coordination.