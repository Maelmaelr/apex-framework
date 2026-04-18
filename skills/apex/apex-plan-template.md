# APEX Plan Template and Writing Guidance

<!-- Called by: apex-apex.md Step 6 (plan writing and validation) -->

## Plan Length Guideline

If the plan exceeds 200 lines, apply structural strategies to keep acceptance criteria in high-attention zones:
- Split ownership rules to a separate `.claude-tmp/apex-context/ownership-rules-{uid}.md` file, referenced by path in the plan
- Summarize lower-priority criteria as a numbered checklist rather than full prose descriptions
- Move file-level implementation details to teammate task descriptions (Step 6), keeping the plan focused on architecture and acceptance criteria
- Target: plan body under 200 lines, with supplementary files for detailed rules

**Plan-mode search discipline.** Plan-mode searches fill specific gaps not covered by scan/scout findings. Before issuing a Grep or Read, verify the pattern does not substantially overlap with a prior search in the current session (scan, scout, or earlier plan-mode). If >50% of search terms match a prior query, reuse those results instead. Soft budget: ~10 targeted searches (Reads + Greps combined) beyond scout findings. Print `PLAN SEARCH: {N}/~10` after each Read/Grep in plan mode beyond scout findings. If approaching 10, consolidate remaining gaps into a single targeted batch. Parallels scan's hard budget (5 calls) and scout's early stopping (3+ consistent results) but is softer because plan gaps are less predictable.

Write the plan to the plan mode file. Synthesize all information into a plan. Key principles:

**What to include:**
- Context: Project summary, scout findings, gotchas, relevant lesson sections
- Goals per teammate: Problem statement, acceptance criteria, required reading (docs + lessons), verification approach. **Helper import paths in Required reading:** When a goal references a helper function or utility that lives in a non-obvious location (sibling-folder re-export, parent barrel, shared module, cross-package export), include the exact import path in the teammate's Required reading (e.g., `checkRequiredFields from @/components/canvas/nodes/video-generation/video-node-components`). Scout pre-flight greps already surface these paths; carry them into the plan rather than forcing the teammate to rediscover them.
- Bug framing: When the user reports a specific behavior as a bug, frame the goal as fixing that behavior -- not as verifying whether the behavior is correct. If scouts found a plausible root cause, include it. Reserve "verify and fix if needed" framing only for behaviors discovered by scouts that the user did not explicitly report.
- Complexity and file health: Include all CLAUDE.md Code Quality constraints (cognitive complexity max 15, file health >400/500 line gates, barrel exports) as acceptance criteria in goals that modify at-risk files. Check file line counts from scan/scouts to identify at-risk files. When a goal extends an existing method with conditional branches, include an AC to pre-check the method's current cognitive complexity and extract/refactor first if near the limit (>10). Also flag new helpers introduced by the goal: if a new helper is estimated to contain >3 branches/type-guards, note it in the pre-mortem as a complexity risk. For goals that add new code to files already above the 500L hard gate (per scan file health notes), the plan MUST include a pre-extraction teammate task (or sequenced sub-task) scheduled before the content-adding task runs. The pre-extraction task separates a logically cohesive section -- not the newly added content -- to bring the file under the gate. Do NOT merge pre-extraction and content addition into one task: splitting scope from addition keeps teammate focus and avoids mid-implementation gate blockers.
- Prop wiring completeness: When a goal uses callback props for component extension (e.g., `onAction` callback instead of direct imports), the parent wiring must be assigned as an explicit acceptance criterion in a specific teammate's goal. If no teammate owns the parent file, assign it.
- Destructured-prop edit sites: When a goal adds props to components with destructured function params, AC must list all 3 edit sites: (1) type/interface definition, (2) destructuring parameter list in function signature, (3) usage/JSX. Missing the destructuring list is a common build failure -- the type compiles but the value is undefined at runtime. When the goal EXTRACTS a shared component from an existing consumer, read the actual callback signatures in the source consumer before writing AC -- plans that specify a theoretical API (e.g., `(file: File) => void`) rather than the consumer's real pattern (`() => void` with hidden input) produce downstream prop mismatches discovered only at teammate build.
- Integration wiring assignment: When two parallel teammates produce components that must be integrated (one creates sections/children, the other creates the container/parent), explicitly assign the integration wiring (imports, rendering, data passing) to one teammate or the lead.
- Type constructor coverage: When a goal adds required fields to shared types (packages/shared), the plan must enumerate all consumers that CONSTRUCT objects of that type (optimistic updates, factory functions, default objects, test fixtures, demo/mock providers), not just consumers that read/destructure the type. Constructor sites break at runtime when required fields are missing, unlike read sites which get type errors at build. Include constructor-site updates as explicit acceptance criteria in the owning teammate's goal. Also include consumers that use the field for comparison/threshold logic (e.g., balance checks, quota enforcement, feature gates) -- these sites need the new field to function correctly even though they compile without it.
- Type boundary friction: Flag transformation points at layer boundaries (validator -> controller -> service) where output types differ from domain types (e.g., form input vs. array -- controller must parse). Flag discriminated-union narrowing sites. When service helpers return optional fields (`reason?: string`), AC must note call sites narrow before use -- optionality mismatches compile but break at runtime.
- Semantic rename test coverage: When a goal renames shared constants or config keys that change semantic meaning (not just mechanical key renames), acceptance criteria must include test assertions that verify values across tiers still produce correct behavior. Mechanical renames (find-and-replace) pass tests by default, but semantic changes (e.g., renaming tier hierarchy, changing limit semantics) can silently break tests whose logic depends on the old tier relationships.
- Delegate signature verification: When a goal wraps re-exports (adding rate limiting, middleware), AC must verify the delegate's TypeScript signature before wrapping. Framework handlers (NextAuth, platform shims) may accept only `(request: NextRequest)` -- extra args cause type errors or silent mismatch.
- Audit remediation interface blast radius: When an audit-remediation batch includes items that change shared interfaces or types, include downstream consumer items from the audit backlog in the same batch -- even if they are separate BP-IDs. Interface changes cascade to consumers during build verification, and fixing those consumers ad-hoc during verification blurs audit item boundaries. Plan the consumers upfront so verification fixes are intentional, not incidental.
- Cross-agent file awareness: When two teammates' work converges on closely related files (e.g., one restructures a shared component while another adds content that uses it), note the relationship in both teammates' goal sections. Explicit awareness ("Teammate X is restructuring the billing component you consume").
- Item counts: When the task involves consolidation, migration, or merging across files, include concrete item counts from scout findings in each goal. Distinguish countable items (violations, files, BP-IDs) from volume metrics (line reductions, file size changes). Countable items use enumerated scout counts, re-grepped pre-spawn (scout totals drift). Volume metrics use directional language ("significant reduction", "substantial cleanup").
- Numeric threshold baselines: When a goal sets a numeric threshold (coverage %, performance target, line count limit), acceptance criteria must include measuring the current value before committing to the target. Plans that assume baseline values without measurement risk setting already-met targets (wasting verification effort) or unreachable targets (causing verification failures).
- Inline numeric test-case values: When ACs include worked examples with numeric inputs/outputs, direct the teammate to derive values from source (pricing table, tier constants, config) rather than trusting plan-embedded numbers -- they drift between scan and implementation. Phrase as "verify against {source-file}", not fixed assertions.
- docker-compose service name verification: When plan ownership references docker-compose service blocks or line ranges, verify the block name matches the actual YAML key in `docker-compose*.yml` (not a role label or hostname alias) before encoding the reference. Grep `^\s*(service-name):` to confirm. Mismatched names cause teammate scope confusion.
- Ownership: File boundaries per teammate (by package/layer)
- Finding coverage: Before finalizing Goals, enumerate all actionable scout findings and verify each is addressed in a teammate's acceptance criteria or explicitly noted as out-of-scope. A file being assigned to a teammate does not mean all findings about that file are covered -- multiple findings can target the same file. When deriving acceptance criteria from scout findings, maintain consistent numbering or use scout finding IDs (e.g., "Bug 1", "Finding 3") so verification can trace criteria back to scout reports without ambiguity. Also verify each AC has sufficient scout coverage -- if an AC requires data or understanding not covered by any scout finding, note it as a Required Reading gap or flag the teammate to investigate independently.

**What NOT to include:**
- Implementation details
- Code snippets (exception: security audit-remediation plans may include specific algorithms, SQL patterns, and validation regexes in ACs where ambiguity would risk wrong security choices)
- Step-by-step instructions
- Line number references in acceptance criteria (they become stale as files are edited -- use section headings or grep-able content patterns instead)
- Hardcoded sequential resource identifiers (migration prefixes, seeder batch numbers, enum ordinals) -- these go stale between scan and implementation. Use directional language ("next available migration prefix") and add an AC for the teammate to verify the actual next identifier at implementation time
- Extended deliberation on solved tradeoffs (commit to a direction after one evaluation pass; do not re-evaluate the same tradeoff with the same information)

Determine teammate boundaries:
- Split by package/layer (apps/web, apps/api, packages/shared)
- No file overlap (each file owned by exactly one teammate). Exception: shared data files (e.g., i18n JSON, shared config JSON) that multiple teammates need to extend -- assign to one teammate but sequence dependents after it, or have the lead merge additions post-implementation to avoid merge conflicts.
- Lightweight threshold: If a teammate would own only 1 file with clear, mechanical changes (e.g., prop passthrough, adding a wrapper), consider whether the lead can handle it as a subagent task during Phase 2 verification instead of spawning a full teammate. Prefer full teammates when the file requires investigation, build/lint verification is critical, or changes interact with other teammates' work.
- Heavyweight threshold: If a teammate would own >4 files or >5 acceptance criteria items, split along sub-boundaries within the same package (e.g., controllers vs services within apps/api) or redistribute items to balance load. Teammates that context-compact lose coherence and produce lower-quality output -- prevention is cheaper than recovery.
- packages/shared: assign to the teammate whose changes drive the type updates
- Tightly coupled changes: When a type change and its primary callback/handler consumers are semantically coupled (splitting would require constant cross-dependency messages), assign them to the same teammate regardless of layer naming conventions. Splitting by layer is the default -- override it when coupling is concrete (e.g., SessionPayload + JWT/session callbacks that use the new field inline).
- Parallel type coordination: When multiple parallel teammates create or consume the same shared types, the plan must specify type ownership direction -- which teammate creates the type definition (in packages/shared or their package), and which teammates import from it. If the type must exist before consumers can build, either sequence the type-owning teammate first or instruct consumers to define a local interface initially and switch to the shared import after the type-owning teammate's changes land. Without explicit direction, teammates independently define overlapping types that diverge.

Plan format:

```markdown
# APEX Plan

## Instructions (Execute After Approval)

Read this plan top to bottom. Do not deviate unless blocked.
Do not add context or summary here -- all context belongs in the ## Context section below.

### Phase 1: Team Setup
Read and follow ~/.claude/skills/apex/apex-team.md.
Pass it the Context, Ownership, and Goals sections from this plan.

### Phase 2: Verification
Read and follow ~/.claude/skills/apex/apex-verify.md. Path: 2.

### Phase 3: Team Cleanup
Send shutdown_request to teammates not already shut down in a SINGLE response message (multiple parallel SendMessage calls). Skip teammates whose shutdown was already confirmed (early shutdown in apex-team.md Step 3 item 7) or who have already terminated.
After sending, output "Waiting for teammates." and end your turn. If idle notifications arrive before shutdown_response, output ONLY "Waiting for teammates." -- the shutdown is still processing. Do NOT re-send, interpret, or act on idle notifications.
After all teammates confirm shutdown, call TeamDelete. If TeamDelete fails, wait 10 seconds and retry once. If second attempt also fails, clean up manually: `rm -rf ~/.claude/teams/<team-name> ~/.claude/tasks/<team-name>` (where `<team-name>` is the team name created in Phase 1) and proceed. Do not retry more than twice total.

### Phase 4: Tail Workflows
**Placeholder runtime guard.** If the literal string `{session-id}` (including braces) appears in the bash command below, the placeholder was not replaced before ExitPlanMode. STOP: print `PHASE 4 GUARD: placeholder unreplaced -- aborting cleanup to avoid stale manifest`, skip the cleanup-session.sh call, and notify the user. Do not proceed to cleanup with an unreplaced placeholder.
**Catalog-only override.** If ALL files from the modification list are under `.claude/audit-criteria/` or `~/.claude/audit-criteria/`, force `TAIL_MODE=economy` and skip detect-tail-mode.sh. Otherwise run `bash ~/.claude/skills/apex/scripts/detect-tail-mode.sh {files from modification list}`. Read the output for tail mode.
Run `git diff --name-only` to compute the modified-files list. Pass to apex-tail.md: tail mode, session type, files modified list, and implementation summary from Phase 1 (apex-team.md) completion reports.

**Inline diff write (MANDATORY, before tail dispatch).** Owned by the plan executor, not by apex-tail.md, so the Write tool call cannot be dropped into a parallel agent-spawn batch. Skip only for zero-implementation or lessons-only sessions (document-only output). Steps: (1) generate RUN_ID via Bash: `echo "$(date +%Y%m%d)-$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)"`; (2) `mkdir -p .claude-tmp/git-diff` (Bash); (3) write 1-3 sentence summary with `Files: [list]` line (all modified file paths) to `.claude-tmp/git-diff/git-diff-{RUN_ID}.md` (Write tool, direct call); (4) print `DIFF WRITTEN: .claude-tmp/git-diff/git-diff-{RUN_ID}.md`. Execute as its own sequential tool call, then proceed to tail dispatch.

Read and follow ~/.claude/skills/apex/apex-tail.md. Tail evaluates pre-flights and spawns only applicable agents. Tail will abort if `DIFF WRITTEN` was not printed above (non-lessons-only mode).
Session type: {task-type}. {If prd-implementation: PRD file: {prd-path}. If audit-remediation: Audit file: {audit-path}.}
Read each agent's returned output. Print their summary line verbatim.
IMPORTANT: Replace {session-id} with the actual manifest filename from SKILL.md Step 0 before plan approval. Do not leave as placeholder.
Clean up session artifacts: `bash ~/.claude/skills/apex/scripts/cleanup-session.sh {session-id}` (Bash). Session ID: {embedded from Step 0}.
Read and follow ~/.claude/skills/apex/apex-reflect.md with mode: `execution`, economy: `{true if tail mode is economy, false otherwise}` through ALL steps including the write step (inline, execution-phase reflection -- runs after tail so it can observe tail behavior).
**Completion gate.** Run TaskList. If any implementation tasks are pending or in_progress, print `BLOCKED: {N} tasks incomplete -- {subjects}` and resolve them before continuing.
Print completion summary: run `git diff --stat` (or read from inline diff if already computed), then print: `APEX completed. {N} files changed, {teammates} teammates. Verify: {pass/fail}. Tail: {economy/full}.` Use numbered list format for any extended summary, not tables (shared-guardrails #15).

---

## Context

See docs/project-context.md (included in all teammates' Required Reading).

### Scout Findings
{If scouted: reference the scout findings absolute file path from Step 2, e.g. "See {absolute-path-from-Step-2}". Use the absolute path returned by the scout, not a relative path -- relative paths resolve against the wrong base directory in team execution contexts. Include only a 2-3 line summary of key findings here -- full details are in the file. Teammates read the file as Required Reading.}
{If not scouted: omit this subsection}

### Lessons
{Reference apex-context file for lessons -- do not paste verbatim here. Lessons are persisted in the apex-context file (apex-team.md Step 2) and read by teammates via Required Reading.}
{If no lessons matched: omit this subsection}

### Tool Constraints
{If the project has specific tool preferences (required/forbidden MCP namespaces, efficiency rules for expensive tools like screenshots/page reads), list them here so teammates inherit them. Omit if none.}

**Import-source verification:** Before asserting that a symbol is available at a given import path (e.g., "shallow is re-exported from @xyflow/react"), verify with one Grep of the package exports. Unverified import-path claims fail build across all teammates who trust them -- treat all import-source assertions in this section as hypotheses until verified.

## Infrastructure Commands

{List ALL runtime activation commands (migrations, seeders, code generation, infra provisioning, dependency installs). apex-verify executes these post-build. None: write "None."}

- {command 1, e.g., `cd apps/api && node ace migration:run`}

## Ownership

- {teammate-name}: {list of file paths this teammate owns}
- {teammate-name}: {list of file paths this teammate owns}

Split by package boundaries. No overlaps.

**Ownership pre-filter:** Prune files that scouts did not flag for changes. Teammates can still discover additional files within their package boundary during implementation.

**Ownership validation:** Verify every file from scout findings, acceptance criteria, and verification steps appears in exactly one teammate's list. Also verify every Shared Contracts endpoint has its implementing file assigned. Note dependencies for blockedBy setup when criteria reference another teammate's output.

**Path existence verification:** Before finalizing the Ownership section, Glob every literal file path. For paths referencing existing files: Glob must return a match. For paths referencing files the teammate will CREATE: Glob the parent directory instead (must return a match). Mismatches indicate directory-name typos (singular/plural) or stale paths -- fix the plan before Exit Plan Mode. Batch Globs in a single response.

**Construction-site ownership:** When goals add required fields to shared types, verify ALL construction-site files (optimistic updates, factories, auth mappers, test fixtures) appear in a teammate's list. Unowned construction sites cause build failures that are more expensive to fix post-hoc.

**Type propagation ownership:** When goals add members to cross-component types (shared enums, union types, discriminated unions), grep consumer files for TypeName across source AND test directories to discover: switch/case handlers, type guards, display components, barrel re-exports, i18n keys, `Record<TypeName>` literals (each is a mandatory inclusion -- TS exhaustiveness failures in test fixtures break build). Plans adding union members underestimate web-side scope by 3-5 files. **Union narrowing** (removing a literal member): also grep the bare literal string -- construction sites write the literal directly and do not surface via TypeName grep.

**Test-mock registry ownership:** When a goal adds an entry to a component registry tested with per-entry `vi.mock` isolation (peer components mocked to avoid heavy imports during unit tests), grep test files for existing peer mocks: `grep -rn "vi\.mock.*{registry-folder}" apps/*/__tests__ apps/*/app 2>/dev/null`. For any test file that mocks 2+ peer entries from the same folder, treat the test file as an ownership inclusion for the adding teammate and include an AC line: "Add `vi.mock('{new-entry-path}', ...)` alongside existing peer mocks in `{test-file}`." Skip when no peers are mocked (test file uses shallow rendering or a registry stub). **New shared module imports:** When a teammate adds a new `import` from an existing shared module (e.g., adding `shallow` from `zustand/shallow`), grep test files that mock that module path (`vi.mock.*{module-path}`) -- those test files become implicit dependents and must appear in the adding teammate's ownership.

**Test-mock layer cascade:** When an AC adds a new external-call path (DB query, API client, filesystem I/O, queue push) to an existing function, grep the function's `*.spec.ts` / `*.test.ts` for existing mocks. If sibling tests mock the caller at a different layer than the new call site (e.g., mocking only the top-level service method while the function now touches the DB directly), add an AC to install `group.each.setup` defaults (or equivalent) for the new layer. Previously-safe sibling tests otherwise execute real-layer calls on a code path they never intended to exercise, failing unpredictably at verification.

**Smoke-test depth selection:** When an AC asserts visible output of a shared utility rendered inside a component with peer `vi.mock` isolation, direct-test the utility (import the function, feed inputs, assert output) rather than rendering the full component tree. Peer-mocked imports do NOT honor `importActual` on consumers -- the utility under test may never execute. Use full-render smoke tests only when the component chain has no peer mocks.

**Inverse type propagation:** When goals create new code that calls existing functions accepting typed parameters (enums, unions, discriminated unions) with values not yet in the type, the type definition file must be in the same teammate's ownership. Common pattern: new service calling `auditLog()` / `logEvent()` / error taxonomy with new event strings requires extending the event type union.

**Shared component prop ownership:** Adding/removing/narrowing props on a shared UI component -- assign the component file to the driving teammate; removal/narrowing requires prop-change propagation across consumers (grep `<propName>` in the feature folder, include intermediate view/container JSX in ownership). **AC prop signatures must mirror the real shape** (narrow signatures force mid-session widening or silent prop-mismatch): extraction uses the consumer's actual callback / DOM-element pattern (e.g., hidden-input + `() => void` vs `(file: File) => void`); SDK wrappers include the library's interpolation dimension (e.g., next-intl `t: (key: string, values?: Record<string, string | number | Date>) => string`, not bare `(key: string) => string`).

**Symbol removal ownership:** When a goal removes an exported symbol (component, type, function) from a subfolder, include (a) the source-folder's own `index.ts` (it must drop the moved symbol's export) AND (b) all ancestor-folder barrels. Grep: `grep -rn "from ['\"]\./{subfolder-name}" <package>/**/index.ts` plus named re-exports matching the symbol name. Omitting the local barrel (e.g., `text-generation/index.ts` when a component moves to `shared/`) causes stale-export TS errors at verification.

**Service/method extraction ownership:** When a goal extracts methods from ServiceA into ServiceB, grep all callers of the extracted method names (`grep -r "serviceA.methodName" --include="*.ts"`) to discover the full consumer graph -- controllers, helpers, other services, test files. Include all discovered consumers in the teammate that owns ServiceB (they need import updates). Plans extracting service methods routinely miss 2-4 consumer files (helpers, spec files) that still reference the old service.

**Shared-helper determinism:** When two or more teammates consume the same helper function, the plan must commit to a single reuse approach in ACs -- "extract to a dedicated shared file" OR "import in place from its current location" -- never both as alternatives. "Extract OR import" lets the dependent teammate pick, producing duplicate helpers or skipped extractions that surface only at lead verification. If the helper is currently private (not exported), add an explicit AC "Export `helperName` from `{path}`" owned by the source-file teammate -- non-exported helpers are a routine mid-implementation blocker trivially resolvable in the plan. **Bulk deduplication ACs:** enumerate each duplicate site explicitly (file:line pairs or pattern + match count) -- implicit counts cause partial removal.

**Cross-boundary data flow specification.** When parallel teammates share a data-flow boundary (one produces data the other consumes), list the specific fields that cross the boundary and their direction in the Shared Contracts section. Teammates must not create cross-boundary props beyond what the contracts specify -- unlisted props become orphans discovered only at lint/build.

**Test-file ownership discovery (general rule):** For every source file in a teammate's ownership, discover corresponding test files via naming convention (`{name}.spec.{ts,tsx}`, `{name}.test.{ts,tsx}`, `__tests__/{name}*`, `__tests__/components/{name}*`) and assign them to the same teammate. Include all discovered test files in acceptance criteria test lists. The file-move and semantic-rename rules below are special cases of this general rule -- this rule covers all modified source files, not just moved or renamed ones.

**File-move test ownership:** Grep the test suite for `readFileSync`/`readComponent` referencing reorganized directories. Assign discovered test files to the teammate owning the moved source files -- use grep-based discovery, not hardcoded scout lists.

**Transitive component-consumer test ownership:** When a goal adds new required props to a shared component (or changes existing props from optional to required), name-based test-file discovery misses tests that render the component from a different file. Grep JSX consumers across test directories: `grep -rn "<ComponentName" apps/*/__tests__ 2>/dev/null`. For each matching test file not already in the source-owning teammate's ownership, add it and include an AC line: "update `{ComponentName}` baseProps fixtures in `{test-file}` to include new required props: `{prop-list}`".

**Hook extraction threading:** When a goal involves extracting logic into a new hook (sub-hook, custom hook), include in ownership: (1) the hook's types/interface file, (2) context providers that thread the new hook's inputs, (3) parent components that pass props consumed by the new hook. Extracting logic changes the hook's input contract -- callers and type definitions are always in scope.

**Runner/orchestrator data-shape ownership:** When a goal adds, removes, or renames a field on a per-type data shape in a registry-based system (node-type registries, job-type dispatch, event-type handlers), include the central runner/executor/orchestrator file that serializes that shape for downstream calls (API body builder, worker payload, message producer). These files typically live outside the type's own folder (e.g., `canvas-runner-*.ts` dispatches across all node types) and are unowned by any single teammate in package-boundary splits. Grep for the type discriminator name (e.g., `textGeneration`, `imageGeneration`) across `**/*runner*.ts`, `**/*executor*.ts`, `**/*orchestrator*.ts`, `**/*dispatch*.ts` and include matches in the driving teammate's ownership. Unowned runners produce build-clean but runtime-broken serialization (stale fields sent in request bodies) caught only mid-verification.

**Feature-folder utility ownership:** Same-folder `.ts` utility helpers imported by owned components (e.g., `{feature}-utils.ts`, `{feature}-helpers.ts`) must be included in the teammate's ownership when component param changes thread through them (derivation, validation, grouping). Grep `from ['"]\./{basename}` from owned component files to discover candidates. Missed helpers cause scope expansion at implementation time when the helper needs matching parameter changes -- especially costly when the helper is near the file-health gate and forces a mid-session split.

**Shared hook/barrel prescoping:** When a plan splits ownership across frontend packages, shared barrel files (`shared/index.ts`, `use-*.ts` hooks) are predictable scope-expansion sites -- teammates discover them mid-session when their component needs the hook path. Grep `from ['"]@/components/.*/shared` across owned component files during planning and include matching barrels in pre-scoped ownership.

## Shared Contracts

When the plan involves multiple agents that share API route contracts (typically API + web agents), the Context must explicitly list the agreed API endpoints with request/response shapes so both agents use the same URLs AND the same payload structures. Add a subsection:

```
### Shared Contracts
- POST /api/v1/canvas/generate - Create canvas generation
  Request:  { "prompt": string, "style": string }
  Success:  { "data": { "id": string, "status": "pending" } }
  Error:    { "error": { "message": string, "code": string } }
- GET /api/v1/canvas/generations/:id - Get generation status
  Success:  { "data": { "id": string, "status": string, "url": string | null } }
  Error:    { "error": { "message": string, "code": string } }
```

Adapt to the actual endpoints and shapes. Before writing contract shapes, grep existing API controllers for the project's response envelope pattern (resource-named keys vs generic `{ "data": {...} }` wrappers) and match the convention. Include concrete field names, nesting structure, and types for success/error responses. Contracts with storage paths must use the full container path (e.g., `data.settings[paramKey]`, not just `settings[paramKey]`) and cite an existing hook with the same nesting -- `updateNodeData`-style callers need it to avoid silent data loss. This prevents URL and shape mismatches (divergent paths, flat-vs-nested envelopes, divergent error field naming like `message` vs `error`).

Include all foreign key and reference ID fields that controllers need for entity resolution -- do not assume services will derive references not in the contract. Ensure PK types in contracts match the migration definition (string for UUID, number for integer).

**Enum granularity.** List only distinct semantic categories that consumers actually branch on -- not every variant string. If two enum values trigger the same recovery path, collapse to one. Over-specification forces artificial distinctions at implementation sites.

**Rename/reorganization conflict pre-check.** For rename or reorganization tasks, the Shared Contracts must include the target names (routes, file paths, DB columns) and confirm they do not conflict with existing names. Before writing contracts, grep the codebase for each target name to verify availability. If a conflict exists, resolve the naming in the plan before teammates begin -- mid-flight naming corrections cause URL/path mismatches between teammates and require lead fixups. Lock the canonical naming convention in the plan so all teammates use consistent names.

## Goals

### Teammate: {teammate-name}

**Problem:**
{What needs to be solved, in user terms}

**Acceptance Criteria:**
- {criterion 1}
- {criterion 2}

**Required Reading:**
- docs/project-context.md (cross-cutting rules)
- {scout findings absolute file path from Step 2, if scouted}
- {specific doc files from CLAUDE.md Doc Update Rules routing}
- {reference implementation files if found}
- {relevant lesson sections from Context above}

**Verification:**
{Acceptance-criteria-specific checks only. Do not embed lint/build commands -- teammates follow apex-teammate-workflow.md Phase 3 for standard verification. Only include domain-specific checks here (e.g., "verify new route returns 200", "confirm i18n keys render correctly").}

**Files Owned:**
{List from Ownership section}

---

### Teammate: {teammate-name}

{Repeat structure for each teammate}

```

**Task type embedding:** Replace `{task-type}` in Phase 4 with the task type detected in SKILL.md Step 1 (`prd-implementation`, `audit-remediation`, or `standard`). If `prd-implementation`, replace `{prd-path}` with the PRD file path. If `audit-remediation`, replace `{audit-path}` with the audit file path. If `standard`, remove the conditional sentence. This information must be embedded in the plan because context clears after approval -- the Phase 4 executor has no other way to know the task type.

**Plan validation checklist** (verify before proceeding to Exit Plan Mode):

**Core (always check):**
- [ ] Phase 3 (Team Cleanup) is present with shutdown_request + TeamDelete
- [ ] Every HIGH/CRITICAL finding from scout reports is addressed in at least one teammate's Goals or explicitly noted as out-of-scope with justification
- [ ] Each Goal has Required Reading, Acceptance Criteria, and Verification
- [ ] Schema-to-AC consistency: if the plan Context includes a DB schema or data structure, every item appears explicitly in at least one teammate's AC bullets
- [ ] Cross-service wiring (service A calling service B) appears as explicit AC in the controller-owning teammate's goal, not only as a cross-boundary note
- [ ] Content migration boundaries: when plan splits extract-and-trim across teammates (A extracts content, B trims source), both sides appear as explicit ACs -- not only the extraction side
- [ ] Shared-state dependencies: if teammate A owns a state layer (hooks, context providers, stores) and teammate B owns consumers, the context/provider wiring between them appears as explicit AC in the provider-owning teammate's goal (e.g., "context exposes X from hook for consumer Y")
- [ ] ACs within each goal are internally consistent (no AC hedges "keep X if Y" while a later AC resolves Y by removing it)
- [ ] Infrastructure Commands section is populated (list all runtime activation commands) or explicitly states "None." -- do not omit the section
- [ ] All {session-id} placeholders in Phase 4 replaced with actual manifest filename from SKILL.md Step 0
- [ ] All {task-type}, {prd-path}, {audit-path} placeholders in Phase 4 replaced with actual values from Step 1 (or conditional sentence removed for standard tasks)

**Conditional (check when trigger applies -- new entries go above Pre-mortem, never below):**
- [ ] IF total ACs across all goals exceeds 10: verify effort trigger was evaluated at Step 4.6
- [ ] IF ACs reference external SDK/library method names (e.g., Stripe API calls, framework hooks): verify the method exists in the installed SDK version (check node_modules type definitions or package.json version). Stale method names from docs/lessons cause predictable build failures.
- [ ] IF goals delete or rename i18n keys: grep for template-literal i18n calls (`t(`...`${...}`) and `t(prefix +`) in affected namespaces. Dynamic key interpolation hides deleted keys from static grep -- verify each computed key's possible values still exist in message files.
- [ ] IF ACs swap or rename a component's label/placeholder key (e.g., changing `labelKey`, `placeholderKey`, title prop to a new i18n key): read the target namespace block in the messages file and verify the NEW key exists there. The key may exist in a sibling namespace but be absent from the one the component actually uses -- static grep on the key string produces a false-present result.
- [ ] IF ACs describe i18n key locations (e.g., "top-level X block", "under Y namespace"): read the actual messages file and replace prose descriptions with the verified dot-notation path (e.g., `pricing.currency.label`) -- structural descriptions in ACs diverge from actual nesting and cause teammate key-not-found errors.
- [ ] IF ACs define or rename HTTP routes with dynamic segments (Next.js app router `[param]`, Express/Adonis `:param`): verify the route tree at plan time. Framework-specific constraint: Next.js app router treats sibling dynamic directories at the same path level (e.g., `[id]/` alongside `[nodeId]/`) as colliding segments and fails at build. Colocate handlers under a single dynamic segment or nest under disambiguating static parents.
- [ ] Pre-mortem (always last): list 2-3 failure modes (wrong assumptions, missing dependencies, scope underestimate). If likely, add mitigation to relevant teammate's goal

## Exit Plan Mode

**Placeholder gate:** Before calling ExitPlanMode, grep the plan file for the literal strings `{session-id}`, `{task-type}`, `{prd-path}`, `{audit-path}`. Also grep for `apex-[a-z0-9]{4,}` tokens -- each must equal the current session-id from the Step 0 manifest; hardcoded stale IDs from plan-drafting reuse are placeholder violations. If any found, fix before proceeding.

**Ownership gate:** For each teammate's acceptance criteria, grep for file paths and function names referenced in the AC text. Verify each referenced file appears in that teammate's or another teammate's Files Owned list. If any file is referenced in ACs but unowned, add it to the appropriate teammate before proceeding.

Call ExitPlanMode. Wait for user approval. If rejected, stop and wait for user direction -- do not retry. If a retry returns "not in plan mode", the plan was approved externally -- proceed to implementation.

After approval, context clears. The embedded "Instructions" section is what gets executed.

## Forbidden Actions

Shared guardrails: read ~/.claude/skills/apex/shared-guardrails.md. Additionally:

- Do not ExitPlanMode with any `{session-id}`, `{task-type}`, `{prd-path}`, or `{audit-path}` placeholders still literal in the plan body -- the Placeholder gate above MUST run
- Do not add implementation steps to the plan (plans are goals + required reading, not step-by-step)
- Do not embed full scout findings in Context; reference the scout findings file path and let teammates read it via Required Reading
- Do not write the plan to an intermediate file before entering plan mode -- use only the plan-mode system's designated file path
