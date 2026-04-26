# Teammate Execution Phases

<!-- Referenced by: apex-team.md Step 2 spawn prompt -->

<!-- Design: Mirrors Path 1 guardrails (dependency gates, scope enforcement, structured verification, reflect/learn) but skips scan/path-decision phases (already handled by lead). Teammates are NOT mini-APEX sessions -- they receive scoped goals and pre-selected files. -->

## Phase 1: Understand

0. **Tool prefetch.** `ToolSearch select:TaskCreate,TaskUpdate,TaskList,SendMessage` -- required for task tracking (Phase 2) and lead communication (Phase 2 escalation, Phase 4 reporting).
1. Read in parallel (single response with multiple Read calls): (a) CLAUDE.md Doc Quick Reference for doc routing, (b) docs/project-context.md for cross-cutting rules, (c) all required reading from your goal.
2. If patterns are unclear after step 1, explore (Glob, Grep, Read)

Follow effort assessment procedure (`effort-trigger.txt`) against your assigned goal.

## Phase 2: Plan and Implement

4. Create ALL implementation tasks upfront via TaskCreate (one per logical unit) BEFORE any implementation begins. Also create a per-teammate completion task ("Verify and reflect") with addBlockedBy on all implementation task IDs. This is a teammate-local task distinct from the lead's Path 1/Path 2 tail dispatch (SKILL.md Step 6A / apex-apex.md plan Phase 4) -- do not conflate. Do not create tasks incrementally during implementation -- the full task list must exist before step 5. Set in_progress/completed as you work. **HARD GATE: Do not proceed to step 5 until all tasks are created and verified with TaskList.**
5. Follow pre-delegation checks (items 1-3) in `~/.claude/skills/apex/subagent-delegation.md`. Item 2 (dependency gate per shared-guardrails #9) determines parallel vs sequential execution -- do not skip.
6. Implement per acceptance criteria:

**Single change:**
- TaskUpdate to in_progress, implement, TaskUpdate to completed

**Multiple independent changes (2+ files, unless small-change exception applies):**
Follow subagent delegation protocol (model: "sonnet") in `~/.claude/skills/apex/subagent-delegation.md`. Pass: modification list, lessons from context, scout findings, Related Existing patterns.
- TaskUpdate each to completed as agents return
- **Post-subagent follow-up (teammate override).** If follow-up is outside your owned files: include in Phase 4 report as "stale references in non-owned files" (do not fix -- lead handles cross-boundary fixes).

**Dependent changes:**
- Execute sequentially: TaskUpdate to in_progress, implement, TaskUpdate to completed

**Always:**
- When removing exports/types/components: clean both barrel files AND source definitions
- When removing a parameter from a function/handler: check for now-unused imports in the same file (lint --fix catches them, but fix during implementation rather than as lint rework)
- When modifying a shared component's prop signature: grep `<ComponentName` across ALL packages (not just the owning package) before proceeding -- cross-package JSX consumers are not caught by package-scoped lint and surface only at lead verification build
- When an AC directs retargeting/migrating/updating imports for a symbol, grep BOTH value form (`import { X }`) AND type form (`import type { X }`) -- a type-only sweep silently passes lint while leaving value imports broken at build. Use a single alternation grep `import(?: type)? \{[^}]*\bX\b[^}]*\}` to cover both in one pass.

6b. **File health gate.** Apply CLAUDE.md file health thresholds (>400 lines with >10 new lines: split first; >500 lines with >10 new lines: split first; trivial edits <=10 new lines are always allowed regardless of file size). Handle bracket paths per shared-guardrails #20. If creating a new file, keep under 400 lines (leave headroom for future additions). Exception: single-concern continuous documents (legal prose) are exempt.

6c. **CWD restoration after activation commands.** If any implementation step runs commands that change directory (`cd apps/api && node ace ...`, `cd apps/web && ...`, or similar), restore CWD to the project root immediately after the command completes. Use absolute paths: `cd <project-root>` (Bash). CWD drift from activation commands (migrations, seeders, code generation) invalidates all subsequent relative-path tool calls silently. Alternative: use absolute paths exclusively in all tool calls after activation.

6d. **Escalation trigger.** If implementation reveals unexpected complexity (scope doubles, undocumented dependencies surface, approach hits a dead end), STOP. Do not keep pushing. SendMessage the lead with `ESCALATION: {reason}` describing the blocker and wait for instructions. The lead will assess whether to retry, reassign, or restructure. Silently struggling through scope explosion wastes tokens and produces poor output.

7. **Post-subagent scope check** (after parallel subagents only). Follow delegation protocol post-delegation (item 10) in `~/.claude/skills/apex/subagent-delegation.md`. Compare against your owned files list. If unauthorized files were changed or created, report scope violations to the lead via SendMessage -- do NOT automatically revert or delete. Note any scope violations in your report.

## Phase 3: Verify and Reflect

8. **Requirements cross-check.** Re-read your goal's acceptance criteria AND re-read each owned file you modified to verify each AC is actually present in the code -- do not rely on memory of what was written. False completion (claiming AC met without verifying the code) is a recurring failure mode that ships broken end-to-end chains. Fix any gaps before proceeding to verification. **Baseline error snapshot:** If you need to capture baseline type errors before changes, filter `tsc --noEmit` output by filename (`| grep <file>`) rather than using `git stash` -- stash pop failures (e.g., tsconfig.tsbuildinfo conflict) can destroy uncommitted work.
9. **Lightweight verification.** Run package-scoped lint inline: `pnpm --filter <package> lint --fix` for each package containing modified files. Fix any errors before proceeding. **LSP diagnostic triage:** When LSP reports errors or warnings mid-implementation (e.g., in parallel subagent context where files are changing), treat the first stale-looking diagnostic with one cross-check (Grep or Read the flagged file). If confirmed stale (already fixed in actual file state), defer ALL subsequent LSP snapshots to the formal lint/build step -- do not evaluate each individually. This avoids burning attention on intermediate states already resolved by the edit sequence. **Exception:** `"module has no exported member"` for a symbol named in the plan's Tool Constraints section is a strong signal that the plan's import-source assertion was wrong -- do a pre-emptive package export check (`grep -r "symbolName" node_modules/pkg/`) before final build rather than deferring. This is the dominant plan-assumption-failure pattern. Then: if you own test files (`*.spec.ts`, `*.test.ts`), run them scoped: `pnpm --filter <package> test <test-file-paths>`. Fix failures before proceeding. **New-TS-file gate:** If `git diff --name-only` AND `git ls-files --others --exclude-standard` show any newly-created `.ts`/`.tsx` files, also run package-level build/typecheck (`pnpm --filter <package> build` or equivalent) before reporting. **Backend compile gate:** When the modified package uses a test runner that compiles tests separately from the production build (e.g., Japa/AdonisJS), a clean scoped-test pass does not imply a clean build -- always run package-level build independently even when no new `.ts` files were created. **Lint-revert typecheck gate:** If this teammate's implementation included any interface/type-field change, prop-signature change, or removal of a typed symbol AND `pnpm --filter <package> lint --fix` wrote to any owned file during this verification step, also run `pnpm --filter <package> build` (or equivalent typecheck) before reporting -- `lint --fix` can auto-remove imports that look unused after field/prop edits, silently reverting type-definition or JSX prop-threading work. Report each sub-gate explicitly in the Phase 4 completion report (step 13). A missing sub-gate line is treated as non-compliance by the lead. Scoped test runners use looser TS configs than production build -- DOM-vs-Node type ambiguity (e.g., `RequestInfo`) and unused imports/fixtures slip past scoped tests and surface only at lead verification. The lead's post-merge apex-verify (plan Phase 2) handles full build, security scan, cross-boundary test sweep, and file health -- teammates handle lint + owned tests + new-file typecheck.
10. **Teammate reflect.** Lightweight inline reflection. Review your execution against these categories:
    - **Spawn context quality:** Was the spawn prompt sufficient? Missing context, ambiguous requirements, files not listed in ownership that you needed?
    - **Ownership coverage:** Did your file list cover the actual changes needed? Files discovered outside ownership?
    - **Subagent quality** (if you used parallel subagents): Did they have enough context? Scope violations caught?
    - **Cross-boundary issues:** Contract mismatches, stale references in non-owned files?
    - **Wasted effort:** Redundant reads, unnecessary exploration, context gaps that caused rework?

    If observations exist (2-5 bullets max), append to ~/.claude/tmp/apex-workflow-improvements.md (GLOBAL path, not project-local .claude-tmp/):
    ```
    <!-- {date} - teammate-reflect -->
    - {category}: {observation}
    ```
    Write high-level observations only. Abstract away project-specific details (names, URLs, selectors). Describe the pattern, not the instance. If no observations worth capturing: skip silently.

11. **Lessons.** If non-obvious patterns/gotchas discovered AND `.claude/lessons.md` exists in CWD, append to .claude-tmp/lessons-tmp.md tagged with your teammate name:
    ```
    <!-- {date} - teammate:{your-name} -->
    - {lesson}
    ```
    Filter: only non-obvious lessons (tricky patterns, gotchas, edge cases, conventions). Do NOT capture workflow observations here (those go in step 10). Skip if nothing non-obvious.

12. **Doc updates:** Apply minor updates to owned docs, flag others in report.

TaskUpdate the "Verify and reflect" per-teammate completion task to completed.

## Phase 4: Report

13. **Same-turn completion report (HARD GATE).** Send this report in the SAME turn your final implementation/verification task completes -- before ending the turn or entering idle. Going idle without a report is non-compliance: the lead cannot detect silent completion and must round-trip to elicit it. Prerequisite: Phase 3 step 8 requirements cross-check (re-read owned files vs ACs) must be complete before sending this report -- do not send a completion report before verifying code matches each AC. Read ~/.claude/teams/{team-name}/config.json for team names. Send completion report to lead via SendMessage:
    - Changes summary: list ALL files modified AND all files created (including new files from file-health splits, extracted modules, barrel updates, and any other side-effect file creation). Use `git diff --name-only` and `git ls-files --others --exclude-standard` to capture the complete set -- do not rely on memory of what you changed.
    - Verification result:
      - Lint: {pass|fail, N fixes}
      - Owned tests: {pass|fail|n/a (no owned test files)}
      - New-file build gate: {pass|fail|n/a (no new .ts/.tsx files)} -- state "n/a" only after running `git diff --name-only` and `git ls-files --others --exclude-standard` to confirm zero new .ts/.tsx files
      - Lint-revert typecheck gate: {pass|fail|n/a (no type/prop changes OR lint --fix made no writes)}
    - Out-of-ownership modifications: files modified or created outside your assigned ownership (e.g., file-health splits, import fixes, cascading renames). List each file with reason. "none" if all changes are within ownership. Compare `git diff --name-only` output against your ownership list from the plan.
    - Scope violations caught (count, or "none" -- from step 7)
    - Reflect observations (count + categories, or "none")
    - Lessons captured (count + topics, or "none")
    - Doc updates (applied or flagged for others)
    - Stale references in non-owned files (path, pattern, suggested fix)
    - Exported symbol renames: if any exported symbol (component name, type, function, constant) was renamed during implementation -- even within ownership -- flag it here with old name, new name, and affected packages. Silent renames break callers the lead cannot detect from the files-changed list alone.
    - Extraction candidates: if 2+ files in your scope implement the same helper pattern (e.g., token refresh, provider dispatch, error mapping), flag as extraction candidate with file paths and pattern description -- drift risk increases with duplication count
    - Cross-boundary contract mismatches in non-owned files: if you changed an API response shape, error format, or field naming, grep consumer code (BFF routes, frontend clients) for usages of the old shape and flag mismatches (e.g., consumer reads `data.error` but producer now returns `data.message`). Check response field nesting, error field naming, and required field presence.
    - Self-corrections: if you discovered mid-implementation that an approach was wrong and pivoted (e.g., fixed a payload leak, changed a return shape, switched a code path), list each correction as a bullet with: what was wrong, what you changed, and which file it affects. "none" if no pivots occurred. The lead verifies these immediately because mid-implementation pivots are the most common source of undetected regressions.
14. Message teammates directly for dependencies or proactive alerts (shared interface changes, completed blockers).
15. On shutdown_request: SendMessage (type "shutdown_response", approve: true, request_id from the request) after completing in-progress work.

15b. **Post-completion idle discipline (HARD WAIT).** After sending the Phase 4 completion report, enter a strict waiting state. Do NOT re-enter Phase 2 implementation on idle wake-up or TaskList replay. Respond only to shutdown_request or direct lead questions via SendMessage. If new pending tasks appear in TaskList after your completion report, treat them as informational only -- the lead is responsible for explicit reassignment via SendMessage before you resume work. Replaying the task queue after declaring completion produces spurious "already done" reports and noise for the lead.

## Forbidden Actions

Shared guardrails: read ~/.claude/skills/apex/shared-guardrails.md. Additionally:

- Implement without TaskCreate (always create tasks, even for single changes)
- Capture workflow observations in .claude-tmp/lessons-tmp.md (those go to ~/.claude/tmp/apex-workflow-improvements.md via teammate-reflect)
- Capture codebase lessons in the workflow improvements file (those go to .claude-tmp/lessons-tmp.md)
- Use AskUserQuestion directly (relay all user questions through the lead via SendMessage -- the lead has user context and can consolidate queries)
