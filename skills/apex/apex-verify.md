# apex-verify - Lint and Build Verification

<!-- Called by: SKILL.md Step 6A (Path 1). Path 2: invoked via apex-plan-template.md Phase 2 executed by plan-mode after ExitPlanMode -- not directly by apex-apex.md. -->

This workflow runs lint and build to verify implementation correctness.

## Step 0: Detect Change Type

**CWD assertion.** All verification commands assume project root CWD. Run `cd <project-root>` (absolute path) at the start of verification to guard against CWD drift from prior phases (e.g., `cd apps/api` for test commands in implementation).

**Path routing.** If Path = 1, skip Steps 1 and 5 (Path 1 tasks are single-concern and don't require cross-boundary verification).

Check if all modified files are documentation-only (.md files). If yes, skip Steps 1-3 (lint and build are irrelevant for doc-only changes) and proceed directly to Step 6 (Doc Link Verification).

## Step 1: Pre-Build Checks (Path 2 only)

Check agent completion reports for flagged cross-boundary stale references. Fix these before running build/lint, as they are a known source of build failures after parallel agent work.

When the task involved both API and web changes, cross-verify BFF proxy URLs and body shapes:

1. **URL verification:** Grep BFF routes in `apps/web/app/api/` for fetch URLs, confirm each matches an API route in `apps/api/start/routes.ts`.
2. **Body shape verification:** Confirm field names and nesting match. Check: flat-vs-nested mismatches, error field naming consistency, required fields present in both sides.

Fix any mismatches before proceeding to build.

## Step 2: Run Lint

Run: pnpm lint --fix (timeout: 300000)

For changes confined to a single package (either path), use `pnpm --filter <package> lint --fix` instead of the full monorepo lint. Package-scoped is the minimum granularity -- never run lint on individual files. For changes spanning multiple packages, use the default `pnpm lint --fix` (full monorepo). Do not run per-package lint in parallel -- packages may lack lint scripts, causing cascade failures.

If lint fails:
1. Read the error output
2. Run: `bash ~/.claude/skills/apex/scripts/grep-lessons.sh {project-root} {terms}` (terms: error-related rule names, error patterns). If output, read matched sections and update `[last-hit]` dates: `bash ~/.claude/skills/apex/scripts/update-hit.sh {project-root}/.claude/lessons.md {line numbers from markers}`.
3. Fix the issues in the code
4. Retry (up to 3 attempts total)

If the same error persists after 2 failed correction attempts, print `STUCK: {error} -- recommend fresh context` and halt. Do not exhaust the third attempt on the same error pattern -- accumulated context carries forward incorrect reasoning that biases subsequent fixes.

**Complexity warnings after lint pass.** If lint passes (exit 0) but reports complexity warnings:
- **Economy sessions:** Always defer complexity warnings -- both mechanical and significant. Write file health notes per Step 3.8 pattern. Economy changes are small by definition; post-session splits via apex-file-health are safe. Skip to the Print line.
- **Mechanical additions** (added parameters, field mappings, case branches) to functions already near the complexity limit before changes: defer. Write a file health note per Step 3.8 pattern. Do not refactor inline during verification.
- **Significant new logic** introduced by the current task (not mechanical): fix by extracting helpers before proceeding to build.
- Print: `COMPLEXITY: {file}:{function} -- {deferred: mechanical addition to near-limit function | fixed: extracted helper}`

## Parallelization Note (after Step 2 completes)

Steps 3 (build), 3.5 (security scan), 3.6 (criterion re-verification), 3.7 (scoped tests), 3.8 (file health), and 3.9 (env var validation) are independent -- none consume each other's output. After lint completes (including any --fix rewrites), run all concurrently by issuing build, security scan, criterion re-verification, test commands, file health checks, and env var validation as parallel tool calls in a single response. Note: Step 3.6 runs after build/lint pass -- if build fails, skip 3.6 until build is fixed.

If lint --fix modified files, all steps still read the corrected source. Process each step's output per its own error-handling rules (retry limits, failure classification) independently.

## Step 3: Run Build

**Pre-build cleanup.** Remove stale framework lock files that cause spurious failures: `rm -f apps/web/.next/lock` (Next.js dev server lock). Skip if the file does not exist.

Run: pnpm build (timeout: 600000 for monorepo builds, 300000 for single-package builds)

**Package-scoped builds.** Derive changed packages from the modification list. Build only changed packages plus their dependents. Package-scoped is the minimum granularity -- never build individual files. Do not run per-package builds in parallel -- packages may lack build scripts, causing cascade failures.

**Dependency map.** Derive from the project's `pnpm-workspace.yaml` and package.json `dependencies`/`devDependencies` fields. If a shared package is changed, build it first, then all workspace packages that depend on it (sequential -- shared must finish first). If only one app package changed, build that package alone. If multiple app packages changed (no shared), build each sequentially. If cross-package dependencies are unclear, fall back to `pnpm build` (full monorepo).

If build fails:
1. Read the error output
2. **Deterministic failure shortcut.** If the error is a syntax error, type error, or missing module in a file from the modification list, classify as deterministic. Fix the issue and retry. If the retry produces the identical error output (same file, same line, same message), stop retrying and report the failure -- do not exhaust remaining attempts on a deterministic error.
3. Run: `bash ~/.claude/skills/apex/scripts/grep-lessons.sh {project-root} {terms}` (terms: error-related module names, error patterns). If output, read matched sections and update `[last-hit]` dates: `bash ~/.claude/skills/apex/scripts/update-hit.sh {project-root}/.claude/lessons.md {line numbers from markers}`.
4. Fix the issues in the code
5. Retry (up to 3 attempts total)

If the same error persists after 2 failed correction attempts, print `STUCK: {error} -- recommend fresh context` and halt. Do not exhaust the third attempt on the same error pattern -- accumulated context carries forward incorrect reasoning that biases subsequent fixes.

**Stale cache fallback.** If the first build attempt fails with stale reference errors (module not found for deleted/renamed files, cached route types, stale exports) AND the error references files that are NOT in the current modification list, delete the framework cache (e.g., `rm -rf apps/web/.next` for Next.js) and retry the build. This addresses false build failures caused by stale framework caches. Only clear cache once per verification run -- do not loop.

## Step 3.5: Security Scan

Scan modified source files only. Exclude test files (`*.spec.ts`, `*.test.ts`, `*.spec.tsx`, `*.test.tsx`, `__tests__/*`, `tests/*`), example configs (`*.example`, `env.example`), and fixture files (`fixtures/*`, `helpers.ts` in test directories) from all tiers.

**Preferred: Semgrep.** Check `which semgrep` (Bash). If available, run a single command scoped to modified source files:
```
semgrep scan --config=auto --severity ERROR --severity WARNING --include <file1> --include <file2> ... --quiet --no-git-ignore
```
Map Semgrep severity to tiers: ERROR = Tier 1, WARNING = Tier 2, INFO = Tier 3.

**Fallback: pattern-based scan.** If Semgrep is not available, run: `bash ~/.claude/skills/apex/scripts/security-scan.sh {file1} {file2} ...` (scoped to modified source files only). The script handles tier classification, exclusion rules, and summary output.

Not a full SAST tool -- pattern-based detection catches obvious issues. Project-specific exceptions can be captured as lessons to reduce false positives over time.

Print: `SECURITY: {tier1_count} FAIL, {tier2_count} WARN, {tier3_count} INFO` (output comes from the script's summary line). If Tier 1 issues found, list each and halt verification. If Tier 2 issues found, list each and continue.

## Step 3.6: Criterion Re-Verification (audit-remediation only)

Skip unless the caller's prompt specifies an audit-remediation session with original finding details.

After build and lint pass, re-run the original verification check that triggered each audit finding being remediated:
1. For each remediated finding, extract the original check type (Grep pattern, file read, call-chain trace).
2. Re-run the check against the remediated file(s).
3. If the original violation is still present, classify as REMEDIATION INCOMPLETE and report: `RE-VERIFY FAIL: {finding-id} -- {original pattern still matches at {file}:{line}}`.
4. If the check passes, report: `RE-VERIFY PASS: {finding-id}`.

Print: `RE-VERIFY: {pass_count} PASS, {fail_count} FAIL out of {total} findings`. If any FAIL, halt verification (same as Tier 1 security scan behavior).

## Step 3.7: Related Tests

**UI-only skip.** If the caller's prompt specifies UI-only session, skip test execution entirely. Note "Tests skipped: UI-only changes" in report and proceed to Step 3.8.

**Economy skip.** If the caller's prompt specifies economy session, skip test execution entirely. Note "Tests skipped: economy session" in report and proceed to Step 3.8.

Detect if modified source files have corresponding test files. **Strict name matching only:** source file `foo_bar.ts` corresponds to `foo_bar.spec.ts`, `foo_bar.test.ts`, or `__tests__/foo_bar.test.ts`. Also search dedicated test directories in the package root (`tests/unit/`, `tests/functional/`) for files matching the source basename. For a source file at `apps/api/app/services/foo_service.ts`, also check `apps/api/tests/unit/**/foo_service.spec.ts` and `apps/api/tests/functional/**/foo_service.spec.ts`. Do not expand to semantically related test files, files that import the modified source, or files testing the same functional area. The scoped-test rule bans test suite widening -- strict name correspondence is the enforcement mechanism. Determine the test runner per package from `package.json` scripts (look for `vitest`, `jest`, `japa`, `mocha` in test scripts). Construct scoped commands using the detected runner's CLI syntax.

**If test files found -- always run scoped, never full suite.** Construct the scoped command from the modification list. Common runner patterns:
- Vitest/Jest: `pnpm --filter <package> test -- path/to/test1.spec.tsx path/to/test2.spec.tsx` (space-separated relative paths)
- Japa (AdonisJS): `cd <api-dir> && node ace test -- --files=<comma-separated relative paths>`
- Mocha/other: consult the runner's `--file` or `--spec` flag syntax

Do NOT fall back to the full test suite. If a scoped test command fails to execute (exit code from runner itself, not from test failures), fix the command syntax and retry -- do not widen to the full suite as a workaround. If the scoped command executes successfully but runs more tests than specified (project-specific runner behavior), do not retry with alternative scoping flags -- classify the results against the modification list using the pre-existing failure shortcut below.

**After fix re-runs:** If a scoped test fails, fix the issue, then re-run ONLY the previously failing test file(s) -- not the full scoped set and never the full suite. When scoped tests fail because assertions don't match new implementation behavior (the implementation intentionally changed output), update the test assertions to match the new behavior -- do not revert or modify the source implementation. Implementation changes from the modification list are intentional.

After running tests, restore working directory to the project root (absolute path from session start). Test commands that use `cd` to enter a package directory shift the CWD for all subsequent tool calls.

**Pre-existing failure shortcut.** If scoped tests fail, classify each failing test file: if the test file is NOT in the modification list AND its corresponding source file is NOT in the modification list, the failure is pre-existing. Note "pre-existing (unmodified)" in report and continue. No per-function git-diff analysis needed -- file-level membership in the modification list is sufficient.

**Phantom test name heuristic.** If a modification-list test file reports failures with test names that cannot be found via Grep in that file, re-run ONLY that specific test file in isolation before investigating the error. If the isolated re-run passes, classify the failures as phantom (runner interleaving artifact) and continue. Do not spend calls investigating test names that do not exist in the source.

**If no test files found:** Flag in report: "No test coverage for: {files}" (awareness signal, not a blocker). Write test gap artifact to `.claude-tmp/test-gaps.md` with the following structure (on first creation only -- append targets to existing file):

````markdown
# Test Gap Targets

## Instructions
This file lists source files without test coverage, detected by apex-verify.
Feed to APEX: /apex .claude-tmp/test-gaps.md

When processing as an APEX task:
1. Prioritize: services/controllers (highest), components (moderate), utilities (lowest). Prefer files with nearby test examples.
2. For each target: read 1-2 nearby test files to extract conventions (runner, structure, mocks, assertions, naming).
3. Test type by file type: API controllers/routes = integration tests (HTTP layer). Services = unit tests (mock deps). Components = React Testing Library. Hooks = renderHook. Utilities = pure input/output. Skip type definitions, barrel exports, simple getters, config files.
4. Generate behavioral tests (what, not how). Prioritize edge cases and error paths. Descriptive names: "should {behavior} when {condition}".
5. Run generated tests. Fix failures (max 3 iterations per file). Fix the test, not the source code.
6. Max 20 test cases per invocation.

## Targets

### {file-path}
- Package: {apps/web | apps/api}
- Type: {component | service | controller | utility | route}
- Suggested test type: {unit | integration}
- Nearby test examples: {paths to closest existing test files in same area}
````

When appending to an existing file, add only new `### {file-path}` entries under the existing `## Targets` section -- do not duplicate the Instructions header.

## Step 3.8: File Health Check (Safety Net)

This is a safety net -- primary prevention is enforced during implementation via size gates in SKILL.md Step 2, teammate workflow Phase 2 step 6b, and CLAUDE.md. This step catches edge cases that slipped through.

Check modified files for size and structure. Run `wc -l` in a single batched Bash call: `wc -l file1 file2 file3 ...` (all modified files from `git diff --name-only HEAD` or the modification list). Handle bracket paths per shared-guardrails #20.

**Size check:** Flag any file >400 lines. Thresholds: >400 lines = `split-first` (split before adding >10 lines), >500 lines = `blocked` (split first when the task adds >10 lines; trivial edits <=10 lines are allowed). Print: `FILE HEALTH: {path} ({lines} lines) -- {split-first|blocked}`. If changes in this session pushed a file past 500 (was under before, over now), print `FILE HEALTH WARNING: {path} grew to {lines} lines -- split recommended before next task`. This is a verification warning, not a blocker.

**Persist health notes:** For each flagged file (both already-over-500 and grew-past-500), write a health note to `.claude-tmp/file-health/file-health-<8char-uid>.md` (run `mkdir -p .claude-tmp/file-health` first). Format: `# File Health Note` header, then bulleted fields: `path` (file-path), `lines` (line-count), `type` (grew-past-500 | already-over-500), `detected` (YYYY-MM-DD), `session-task` (brief description). Skip writing if a health note already exists for the same path (grep `.claude-tmp/file-health/` for the path before writing).

**Barrel check:** For any newly created files OR existing files that gained new exported symbols (check `git diff` for added `export` lines), check if the parent folder has an `index.ts`. If yes and the new/added exports are not re-exported through the barrel, flag: `BARREL: {path} -- update index.ts`.

**Cleanup check:** For files that had code extracted or moved out during this session, verify no orphaned imports remain (lint catches most, but check for unused type-only imports that some lint configs miss).

**Dependency audit.** If `pnpm-lock.yaml` is in the modification list (indicating dependency changes), run `pnpm audit --audit-level=high`. Flag critical/high vulnerabilities: `DEPS: {count} high/critical vulnerabilities found`. This is a warning, not a blocker. Skip if lockfile was not modified.

Skip for doc-only changes.

## Step 3.9: Env Var Validation

Grep modified source files for new env var references: `process\.env\.\w+`, `Env\.get\(`, `NEXT_PUBLIC_\w+`. Use the Grep tool directly on each modified source file -- shell `git diff | grep 'Env\.get('` is blocked by the env-read guardrail hook and wastes a round trip. For newly created files (not in HEAD -- detect via `git diff --name-only --diff-filter=A HEAD`), treat ALL env var references as newly introduced and skip the `git show` comparison. For existing files, check if each env var existed before the session (Grep the same pattern in `git show HEAD:{file}`). For newly introduced env vars only, verify they exist in `env.example` and `env.production.example`. For API-specific vars (`Env.get`), also check `apps/api/env.test.example`.

Flag missing entries: `ENV: {var} referenced in {file} but missing from {example-file}`. This is a blocker -- missing env vars cause production startup failures that build and lint cannot detect.

For each newly introduced env var `{var}`, run the docker peer-group check as mechanical steps:
1. Infer `{peer-pattern}` from `{var}` (shared prefix/suffix group, e.g., `.*_EMAIL`, `REDIS_.*`, `.*_WEBHOOK_URL`). Grep: `grep -nE "({var}|{peer-pattern})" docker-compose*.yml apps/*/Dockerfile 2>/dev/null`.
2. If any docker file shows peer matches but `{var}` itself is absent in that file, flag `ENV-DOCKER: {var} missing from {docker-file} (peers: {matched-peers})`. Warning (not blocker) -- docker entries may intentionally omit vars.
3. **`NEXT_PUBLIC_*` rule (blocker):** Next.js inlines `NEXT_PUBLIC_*` at build time. Each such var MUST appear as `ARG` + `ENV` in the owning service's Dockerfile (e.g., `apps/web/Dockerfile`) AND as both a build-arg and a runtime env entry in `docker-compose*.yml`. Missing any of ARG / build-args / runtime env: flag `ENV-DOCKER-NEXTPUBLIC: {var} missing {location}`. Blocker -- build-time inlining cannot be recovered at runtime.

Skip for doc-only changes. Skip for env var references in test files (tests may reference vars defined in test setup).

## Step 4: Run Activation Commands

Two detection sources -- BOTH are mandatory checks (not optional):
1. **Auto-detect from modified files:** if any modified file is a migration (`database/migrations/`), seeder (`database/seeders/`), or code generator, run the corresponding command without deferring to the user.
2. **Explicit commands from context:** check the plan's Infrastructure Commands section (Path 2), the verifier spawn prompt's `Infrastructure commands:` field (Path 1), and the plan's verification sections. Execute ALL listed commands. This is not optional -- these commands were identified during planning/scanning as required for the implementation to be complete.

Common patterns:
- Migrations: `pnpm db:migrate` or `cd apps/api && node ace migration:run`
- Seeders: `cd apps/api && node ace db:seed --files=database/seeders/{seeder_file}.ts`
- Code generation: `pnpm generate` or similar
- External service provisioning: `stripe products create`, `stripe prices create`, or equivalent CLI commands for third-party services (Stripe, cloud providers, etc.)
- Dependency installs: `pnpm install`, `pip install`, etc.

If a command fails, read the error, fix the underlying issue, and retry (up to 3 attempts). If unrecoverable, report the failure.

Skip this step only if ALL of: (a) no modified files trigger auto-detection, (b) no plan/prompt-specified commands exist, AND (c) no external service provisioning was part of the task.

After Step 4 completes (whether activation commands ran, diagnostic checks ran, or the step was skipped), restore working directory to the project root (absolute path from session start). Any `cd` to a package directory during this step shifts CWD for all subsequent tool calls. This ensures Step 5's Glob, Grep, and Read calls resolve paths correctly.

## Step 5: Acceptance Criteria Verification (Path 2 only)

If the plan includes acceptance criteria with verification commands (greps, checks), run them now:

1. **Enumerate**: List all acceptance criteria checks from the plan. Print: `VERIFY BATCH: [check1, check2, ...]`
2. **Execute**: Issue ALL listed checks in a SINGLE response (multiple Grep/Read/Bash tool calls in one message). Do NOT run checks one per turn.
3. **Review**: After all results return, identify failures.
4. **Retry**: For failed checks, fix and retry (up to 3 attempts).

Use quote-agnostic grep patterns for import/string checks (e.g., `from .@/lib/foo.` where `.` matches any quote style, instead of `from '@/lib/foo'`) to handle both single and double quote styles. If a verification check fails because expected content appears missing, re-read the file before concluding failure. Large files (translation JSONs, generated outputs) may have delayed filesystem visibility after parallel agent writes.

**File-move path-literal check:** When the task involved file moves or directory reorganization, grep the ENTIRE test suite (`__tests__/`, `*.spec.ts`, `*.spec.tsx`, `*.test.ts`) for `readFileSync` and `readComponent` referencing any directory that was reorganized. These tests use hardcoded file paths that break silently on file moves -- no import error, no compile error. If stale paths are found, update them to point to the new file locations.

**User-field propagation check:** When the task adds fields to session/auth types (e.g., `SessionPayload`, `Session`, `User`), grep for session-shaped inline object literals (e.g., `{ user: {`, `session: {`, `as Session`) across the full codebase -- not just named providers and test fixtures. Inline construction sites outside the auth layer break silently at runtime when required fields are missing. Treat any object literal matching the session shape as a construction site requiring the new field.

If parallel checks produce "Sibling tool call errored" results, re-run only the affected checks individually (one per tool call) to isolate real failures from cascading artifacts.

## Step 6: Doc Link Verification

For documentation-only changes, verify internal links: grep for markdown links with `](`, confirm target files exist. For links with anchors (`#section`), verify the heading exists in the target file.

**Document structure checks.** When any modified file path matches `.claude-tmp/audit/` or `.claude-tmp/prd/`, run the following sub-steps:

6a. **Severity count match.** Extract the summary table or severity totals (lines containing "HIGH", "MEDIUM", "LOW", "CRITICAL", or "INFO" adjacent to a count). Count actual findings in the body (numbered sections or list items with matching severity labels). Report mismatch: `DOC STRUCTURE: severity count mismatch -- summary says {N} HIGH, body has {M}`.

6b. **Sequential numbering.** Extract all finding numbers from section headers or list items (e.g., "Finding 1", "F-001", "#3"). Verify the sequence is contiguous with no gaps and no duplicates. Report each gap or duplicate: `DOC STRUCTURE: finding numbering gap between {N} and {M}` or `DOC STRUCTURE: duplicate finding number {N}`.

6c. **Cross-reference resolution.** Grep for references to finding numbers (e.g., "Finding 3", "F-003", "see #5"). For each reference, verify the referenced finding number exists in the document. Report each dangling reference: `DOC STRUCTURE: cross-reference to Finding {N} does not exist`.

If any sub-step reports an error, halt and report before proceeding to Step 7.

Skip this step for code-only changes.

## Step 7: Report

Print: "Verification {passed/failed}. Fixed: {number of fixes applied}". If Steps 1-3 were skipped due to doc-only changes, note "lint/build skipped (doc-only)" in the report.

**Timing.** Print step durations: `TIMING: lint {N}s, build {N}s, security {N}s, tests {N}s, total {N}s`. Omit steps that were skipped. Use wall-clock estimates from command execution -- precision is not critical, order-of-magnitude is sufficient for identifying slow steps across sessions.

**Scope expansion output.** If verification fixed build/lint errors by modifying files NOT in the received modification list, report each: `SCOPE EXPANSION: {file}: {reason}`. This signals to callers (SKILL.md Step 6A, apex-apex.md Phase 2) that verification touched files outside the planned scope. **Lint-fix differentiation:** When a file was modified only by `pnpm lint --fix` (not in the teammate modification list AND only changed during the lint step), use `SCOPE EXPANSION (lint-fix): {file}` instead. This distinguishes auto-formatting from teammate scope violations, reducing false-positive investigation.

**Audit/PRD cross-reference output.** If verification fixed build/lint errors across multiple files (especially from shared interface/type changes), list the files and nature of fixes: `VERIFY FIXES: [{file}: {fix description}, ...]`. This list is consumed by apex-tail Agent 3 (document mutation) to cross-reference -- verification fixes may incidentally resolve pending document items that should be marked as complete rather than re-implemented.

Change back to project root directory after verification.

## Forbidden Actions

Shared guardrails: read ~/.claude/skills/apex/shared-guardrails.md. Additionally:

- Do not ignore lint warnings that could hide real issues
- Do not skip activation commands when specified in the plan's verification sections
- Do not modify files outside the modification list without reporting each as `SCOPE EXPANSION: {file}: {reason}` in the report
- Do not revert or undo implementation changes to pass tests -- update test assertions to match the new behavior instead
- Do not refactor or restructure code during economy verification -- only fix errors that block the lint or build. Defer complexity warnings to file health notes.
