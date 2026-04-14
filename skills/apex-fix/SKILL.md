---
name: apex-fix
description: Fix all lint warnings/errors and build errors, then capture lessons.
triggers:
  - apex-fix
---

<!-- Called by: standalone via /apex-fix. May also be invoked manually after failed apex-verify. -->

# apex-fix - Fix Lint and Build Errors

Quick-fix workflow: resolve all lint warnings/errors and build errors, then capture lessons.

## Lesson Lookup Procedure

Run: `bash ~/.claude/skills/apex/scripts/grep-lessons.sh {project-root} {terms}` (terms: error-related rule names, module names, error patterns). If output, read matched sections and update `[last-hit]` dates: `bash ~/.claude/skills/apex/scripts/update-hit.sh {project-root}/.claude/lessons.md {line numbers from markers}`.

## Parallel Fix Subagent Spec

When 3+ independent files are affected, dispatch parallel fix agents. Read all affected files first. Create TaskCreate entries (one per file or group). Per shared-guardrails #1, spawn all agents in a single response. Print `PARALLEL SPAWN: [fix-{file1}, fix-{file2}, ...]`.

**Novel pattern validation.** When many files share an unfamiliar error pattern, fix 1-2 representative files and rebuild to validate the approach before spawning parallel agents for the rest. Avoids wasting a full build cycle if the fix strategy is wrong.

**Pre-spawn baseline:** `git diff --stat > .claude-tmp/pre-agent-diff.stat` (captures dirty-file state so post-fix check can detect agent modifications to already-dirty files).

Per subagent:
- subagent_type: "general-purpose"
- model: "sonnet" for mechanical/isolated fixes. Omit (Opus default) for cross-file dependency or logic-altering changes.
- mode: "bypassPermissions"
- description: "Fix {error-type} in {filename}"
- prompt: Include specific errors for this file, matched lesson sections (from sub-step 2) scoped to relevant files, and scope constraint: "Only modify your assigned file(s). Do not expand fixes to sibling files." For complexity fixes, include the Complexity fix pitfalls section verbatim. Mark task completed when done.

**Post-fix scope check:** After all agents return, run `git diff --name-only`. Additionally, run `git diff --stat` and compare against `.claude-tmp/pre-agent-diff.stat` -- files whose diff line count increased were modified by agents even if they were already dirty. If files outside the error list were modified, report them and use AskUserQuestion: "Scope violation: fix agents modified files outside error list: {files}. Revert these files / Keep changes / Review diff first". Per shared-guardrails #5, report scope violations only -- never auto-revert. Clean up: `rm -f .claude-tmp/pre-agent-diff.stat`.

## Step 1: Run Lint

Resolve project-root: run `pwd` once and store the result for reuse throughout this workflow. Per shared-guardrails #16, run `cd {project-root}` (absolute path) to guard against CWD drift.

**Pre-run cleanup.** `rm -f apps/web/.next/lock` (stale dev server lock file can cause lint or build hangs). Skip if file does not exist.

If all affected files are in a single package, run: `pnpm --filter <package> lint --fix`. For files spanning multiple packages, run: `pnpm lint --fix`.

If no errors or warnings remain: if lint passed on the first attempt with no `--fix` modifications, Steps 1 and 2 are independent -- proceed to Step 2 and run build immediately (no sequential dependency). If lint `--fix` modified files, build depends on lint output -- run Step 2 sequentially after lint completes.

If lint errors/warnings remain:

1. Read the errors/warnings output
2. Run the Lesson Lookup Procedure (terms: error-related rule names, error patterns).
**Effort assessment:** If cross-file dependency errors or logic-altering fixes are identified, read ~/.claude/skills/apex/effort-trigger.txt and output its content on a separate line. Skip when running as a subagent (model already fixed by caller).

3. Fix the errors/warnings in the code:

   **1-2 files affected**: Fix directly, sequentially.

   <!-- Design: Sonnet for mechanical lint fixes (import ordering, unused vars, complexity extraction, formatting). Opus for cross-file dependency fixes or logic-altering changes. Lint error rule name drives selection. -->

   **3+ independent files affected**: Follow the Parallel Fix Subagent Spec above. Use model "sonnet" for mechanical lint fixes (import ordering, unused vars, cognitive complexity extraction, formatting), Opus for cross-file dependency or logic-altering changes. Lint error rule name drives selection.

   **Complexity fix pitfalls:** ESLint `complexity` counts nested arrow functions (useCallback/useMemo callbacks) toward the enclosing function. Extract the callback body to a named module-scope helper, not the outer function. When extracting helpers, declare parameter types using shared domain types from the project's shared type package -- inline structural types often omit required fields and cause build failures. TypeScript control-flow narrowing does not survive function extraction -- if the extracted block relies on a preceding guard (`if (!x) return`) to narrow a variable, the caller loses the narrowing after the function call. Use type guards, pass the narrowed type explicitly, or apply non-null assertions at the call site.

4. Re-run `pnpm lint --fix`
5. **Deterministic failure shortcut.** If two consecutive lint runs produce identical error output (same files, same rules, same lines), stop retrying and report the failure.
6. Per shared-guardrails #8, retry up to 2 more times (3 total attempts)

## Step 2: Run Build

If all affected files are in a single package, run: `pnpm --filter <package> build`. For files spanning multiple packages, run: `pnpm build`.

If no build errors, proceed to Step 3.

If build fails:

1. Read the error output
2. Run the Lesson Lookup Procedure (terms: error-related module names, error patterns).
**Effort assessment:** If cross-file dependency errors or logic-altering fixes are identified, read ~/.claude/skills/apex/effort-trigger.txt and output its content on a separate line. Skip when running as a subagent (model already fixed by caller).

3. Fix the issues in the code:

   <!-- Design: Same model tiering as Step 1. Sonnet for isolated type errors, Opus for cross-file dependency or logic errors. Error message content drives selection. -->

   **1-2 files affected**: Fix directly, sequentially.

   **3+ independent files affected**: Follow the Parallel Fix Subagent Spec above. Use model "sonnet" for type errors in isolated files, Opus for cross-file dependency or logic errors. Error message content drives selection.

   **Stale cache fallback.** If the first build attempt fails with stale reference errors (module not found for deleted/renamed files, cached route types) AND the error references files NOT in the current error list, `rm -rf apps/web/.next` and retry once. Only clear cache once per run.

   **TypeScript unused-code pitfalls.** TS6133 `_` prefix suppresses warnings for variables and parameters only. Unused function declarations must be deleted or have a consumer added -- do not batch-apply `_` prefix to function names.

4. Re-run `pnpm build`
5. Per shared-guardrails #8, retry up to 2 more times (3 total attempts)

## Step 3: Report and Learn

Print: "Fix: {passed/failed}. Fixed: {number of fixes applied}"

If any fixes were applied, evaluate learn pre-flight: Only spawn if fixes were non-mechanical (cross-file dependency fixes, logic-altering changes, or verification required research). Mechanical single-rule lint fixes (import ordering, unused vars, formatting, missing semicolons) never produce non-obvious lessons. Exception: build failures caused by agent-dispatched fixes are always non-mechanical (agent's fix strategy was wrong; the pattern should be captured). Print `LEARN PRE-FLIGHT: {spawn|skip} -- {reason}`.

If spawning, spawn a single learn subagent:
- subagent_type: "general-purpose"
- model: "sonnet"
- mode: "bypassPermissions"
- description: "Capture fix lessons"
- prompt: "ASCII only. No tables, no diagrams. Flat sections with numbered lists. Read and follow ~/.claude/skills/apex/apex-learn.md. Context: apex-fix session. Summary of what was fixed: {list}. Error patterns encountered: {patterns}. Tricky resolutions: {any}."

Do NOT read apex-learn.md yourself -- the subagent will read it. Just include the file path in the spawn prompt.

Print the subagent's summary line verbatim, then "apex-fix completed."

If no fixes were needed: Print "No issues found. apex-fix completed."

## Forbidden Actions

Shared guardrails: read ~/.claude/skills/apex/shared-guardrails.md. Additionally:

- Address lint warnings (warnings can hide real issues)
- Run apex-learn when non-mechanical fixes were applied
