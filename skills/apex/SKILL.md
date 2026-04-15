---
name: apex
description: Lean coding workflow. Quick scan, then direct implementation or plan-based execution.
triggers:
  - apex
---

# APEX Workflow

Two paths: direct tasks execute immediately, complex tasks go through planning with agent teams.

## Decision Points

When any step needs user direction (multiple valid approaches, conflicting patterns, scope ambiguity), use AskUserQuestion with structured options. Applies to all steps and both paths.

## Step 0: Concurrency Check

<!-- Design: Advisory system, not hard-lock. Warns on overlap via AskUserQuestion. Stale manifests (>2h) auto-cleaned. -->

1. `echo "apex-$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 8)"` -- keep session-id in context
2. `mkdir -p .claude-tmp/apex-active`
3. Glob `*.json` in that dir. Delete >2h old manifests (stale), else print `CONCURRENT SESSION: {task} (started {time})`. Clean orphaned scope/budget files: extract session ID prefix from `*-scope.json`/`*-budget.json`, delete if no matching manifest exists. Print `ORPHAN CLEANUP: {N} files removed` if any.
4. If concurrent: AskUserQuestion -- "Proceed", "Abort", "Show file claims"
5. Batch-fetch deferred tools: `ToolSearch select:TaskCreate,TaskUpdate,TaskList,AskUserQuestion,EnterPlanMode,ExitPlanMode,TeamCreate,TeamDelete,SendMessage` (single call, max_results: 10).
6. After compaction, PostCompact hook re-injects session state. Use echoed state (path, step, files, tail mode, task description, user decisions) to resume. StopFailure hook fires on API errors using same script.

Manifest written after Step 2 scan to include file claims. All manifest operations are best-effort -- never retry on failure. Manifests are advisory only.

## Step 1: Parse Request

Extract the user's task description.

**Batch-mode detection.** If task argument matches `.claude-tmp/{type}/*.md` (type: `audit` or `prd`), set task type. Session type reference: see `~/.claude/skills/apex/apex-doc-formats.md`. Read file, parse YAML front matter for progress counters and completed-items lists. Remaining items = IDs not in completed list.

**Audit-matrix JSON detection.** If task matches `.claude-tmp/audit-matrix/*.json` (type 3: `audit-matrix-remediation`), extract FAIL cells via Bash: `python3 -c "import json,sys;d=json.load(open(sys.argv[1]));m=d.get('matrix',d.get('cells',[]));defs=d.get('criteria_definitions',{});fails=[c for c in m if c.get('status')=='fail'];[print(f\"{c['criterion']} [{defs.get(c['criterion'],{}).get('severity','?')}] | {c['target']}\n  Evidence: {c.get('evidence','n/a')}\n  Criterion: {defs.get(c['criterion'],{}).get('description','n/a')}\") for c in fails];print(f'{len(fails)} FAIL / {len(m)} total')" {path}`. Print `MATRIX REMEDIATION: {N} FAIL cells extracted`. All failures = one batch. For audit inputs, see Audit Input Trust in apex-doc-formats.md. Proceed to Step 2.

**Batch selection.** Pick items by priority order (see reference), sized 3-5 items or single priority tier (whichever smaller). Exception: full tier when all items are mechanically independent and user approves via AskUserQuestion. Selected batch items become the task description for the rest of the flow.

**Batch verification (audit-remediation and prd-implementation).** Before selecting batch: verify remaining items in bulk. Budget: max 2 Grep per item (combine regex alternation for shared dirs). Print `VERIFY BUDGET: {N}/{max} Grep`. Drop already-resolved items. Select from verified remaining.

Present batch via AskUserQuestion: "Proceed with all" vs "Defer items" (specify which). If user defers, remove from batch. If none remain, report "{Type} complete." Route to Path 1 or Path 2 based on batch scope (apply Step 3 to the batch, not the full document).
- Homogeneity: if all items share same violation type/area and fix pattern, treat as single concern for Step 3
- For batches decomposing into independently-mechanical groups (no shared files), apply Step 3 per group -- all Path 1 = batch Path 1 with parallel agents

**Large homogeneous tier (>10 items).** Single AskUserQuestion: "All {N}" / "By area ({groups})" / "Recently modified ({M})". Cap: one AskUserQuestion for batch selection.

**Brainstorm-then-implement.** If request is design/brainstorm (conceptual exploration, "how should we X"), answer inline. Once concrete spec emerges, treat as task description and proceed to Step 2. Design-to-implementation = re-entry to Step 2, not skip of APEX.

## Step 1.5: Audit Catalog Routing

<!-- Design: Unifies /apex and /apex-audit-matrix entry points. Matching catalog -> deterministic audit-matrix flow (no scan/scout/Path 2). /apex-audit-matrix remains for direct invocation. -->

Skip if: (a) batch-mode detected in Step 1, (b) audit-matrix-remediation detected, or (c) task doesn't mention "audit"/"verify compliance"/"check against criteria"/"run audit matrix".

1. **Glob catalogs** from `{project-root}/.claude/audit-criteria/*.md` and `~/.claude/audit-criteria/*.md`. None found: skip to Step 2.
2. **Extract subject.** Strip "audit" + filler words (the/for/all/my/our/this/run/do/check). Normalize: lowercase, hyphens. E.g., "audit the API consistency" -> "api-consistency".
3. **Match against catalogs.** Derive match key from filename stem. Rules (first wins):
   - Exact: subject == key
   - Prefix: either starts with the other
   - Substring: either contained in the other
   - Multiple matches at same level: collect all
4. **Route:**
   - **Single match:** Print `AUDIT ROUTING: auto-selected catalog "{key}" at {path}`. Build args: `--catalog {path}`. If catalog has `project-root` metadata (first 15 lines), append `--root {value}`. Read and follow `~/.claude/skills/apex-audit-matrix/SKILL.md`. STOP after matrix. Cleanup: `bash ~/.claude/skills/apex/scripts/cleanup-session.sh {session-id}` if manifest exists. Then read/follow `~/.claude/skills/apex/apex-reflect.md` with `mode: execution`, `has_scan_phase: false`, `has_build: false`. Skip reflection if audit completed in single inline verification.
   - **Multiple matches:** AskUserQuestion with each catalog + "Scout audit (no catalog)" option.
   - **No match, catalogs exist:** AskUserQuestion listing ALL catalogs + "Scout audit (no catalog)". Header: "No catalog matched '{subject}'."
   - **No subject** (bare "audit"): AskUserQuestion listing ALL catalogs + "Scout audit (no catalog)". Header: "Which audit?"
5. "Scout audit (no catalog)" -> fall through to Step 2 (Step 3 routes to Path 2 scout audit mode).

## Step 2: Quick Scan

Budget: max 5 Grep/Glob + 3 doc Read. Print after each: `SCAN BUDGET: {N}/5 search, {M}/3 doc-read`. project-context.md is mandatory and budget-exempt. At 5/5, stop searches and proceed to Step 3 -- exceptions (a)/(b) source reads and remaining doc reads may continue. Source file reads are forbidden during scan. If you need more searches, the task needs scouts -- proceed to Step 3. Audit tasks: resist deep-scanning; scouts handle discovery. No subagents during scan. Use Glob not Bash ls/find (per project conventions).

1. Read docs/project-context.md (mandatory, budget-exempt). For audit tasks, prioritize security/auth doc within 3-doc-read limit.

**Arm scan budget.** `echo '{"grep_glob_count": 0, "max": 5, "doc_read_count": 0, "doc_read_max": 3}' > .claude-tmp/apex-active/{session-id}-budget.json`

2. Grep key terms. Tips:
   - Auto-save/callback tasks: also grep actual save/persist/write function names
   - Broad terms (`new Date`, `window\.`): combine with context (e.g., `useMemo.*new Date`)
   - New features: include synonyms/partial-name variants to surface existing implementations
3. Glob likely file patterns (scope to `apps/`, `packages/`). Multiple globs or broader patterns for framework auxiliary files (page, layout, error, not-found, loading). Bracket dirs (`[id]`, `[locale]`): prefer `bash find` (e.g., `find apps/web/app -name 'page.tsx'`). Fallback: `*` wildcard in Glob to replace bracket segments (e.g., `apps/web/app/*/app/*/page.tsx`).

**Specialized scan shortcuts:**
- **Size-based tasks:** `find <dir> -name '*.{ext}' -exec wc -l {} + | sort -rn | head -40` -- skip grep/glob, go to file health check
- **Visual/asset replacement:** Search by asset content (`<svg>`, `<img src=`, filenames) + API wrappers -- inline duplicates across rendering surfaces miss API-name-only search
- **Config-driven structures:** Grep for components duplicating config inline (esp. mobile counterparts)

Collect: matching files, packages, obvious dependencies.

**File health check (mandatory gate).** `bash ~/.claude/skills/apex/scripts/file-health-check.sh 400 {files}` -- standalone Bash call (do not batch with other parallel commands -- exit behavior can cancel siblings). Quote bracket paths. Outputs violations only (`blocked` >500L, `split-first` >400L), exits 0. Hard gates.

**Scan methodology:**
- Use Grep/Glob + CLAUDE.md Doc Quick Reference for file enumeration
- **Union type/interface additions:** LSP `findReferences` on type name (budget-free) to enumerate consumers. Include in modification list.
- Read docs, not source files. Source reads in Step 5A.
- **Exception (a) -- Architecture decisions:** Read minimal source for scope decisions. Cap: >3 source reads -> Path 2 recommendation.
- **Exception (b) -- Bug investigation:** Source reading IS the scan. Prefer empirical validation (test scripts) over multi-round reading. Capture build/test output: `{cmd} 2>&1 | tee .claude-tmp/{type}-{target}.txt`. Parse from captured file -- do not re-run for different views. Stale cache: clean framework cache once, retry once.
- **Infrastructure diagnostics:** Batch inspection commands into single Bash script.

**Interface/type blast radius.** Grep all callers including tests. Required-field additions break constructors. Removals break readers (frontend consumers, not just API). Include in modification list.

**Preliminary modification list.** Print numbered list (per shared-guardrails #15). Best-effort estimate -- scouts (Path 2) or implementation agents (Path 1) may discover additional files. Check symmetric structures (images-tab + videos-tab, en.json + fr.json, create + update route, API + frontend). Note `Related existing: [patterns]` for semantic overlaps with the task.

**Reorganization scope.** AskUserQuestion: top-level restructuring vs within-folder subgrouping.

**Blast radius check.** Shared files (layout, context, utility) affecting more than mentioned scope: AskUserQuestion to confirm. Exception: user explicitly requests codebase-wide changes.

**Scope-affecting architecture choices.** Multiple valid approaches with different scope: AskUserQuestion BEFORE Step 3.

**Stale-state + dirty-state checks** -- run git commands in parallel, process AskUserQuestion sequentially.
- **Stale-state:** `git log --oneline -10`. Related recent commit: AskUserQuestion "Continue or Abort?". Skip for audit-remediation/prd-implementation.
- **Dirty-state:** `git diff --name-only` + `git diff --cached --name-only`. Overlap with mod list: print `DIRTY STATE: {files}`, AskUserQuestion: "Stash and continue" / "Continue anyway" / "Abort". Skip `.claude-tmp/`.

**Question batching.** Multiple AskUserQuestion triggers: batch into single call (max 4).

**Write session manifest.** `.claude-tmp/apex-active/{session-id}.json`: `{"task": "...", "started": "<ISO>", "files": [...], "path": null, "current_step": "2", "tail_mode": null, "scout_findings": null, "decisions": ""}`. Check other manifests for overlapping file claims -> `FILE CONFLICT` + AskUserQuestion.

**Record decisions.** `bash ~/.claude/skills/apex/scripts/update-manifest.sh {session-id} decisions="{summary}"` (comma-separated, e.g. "blast-radius: modify shared, scope: full impl"). Must run AFTER manifest write -- update-manifest.sh is best-effort and silently no-ops if the manifest file does not yet exist.

**Write scope file.** `{session-id}-scope.json`: `{"files": [...]}`. Supports glob patterns for undetermined filenames. **Verify:** `cat` the file, confirm non-empty, rewrite once if wrong. Print `SCOPE WRITTEN: {N} files`.

**Disconfirmation.** (1) Re-evaluate scan data: alternative implementations, doc warnings, intentional behavior, audit file-attribution accuracy. (2) 1-2 counter-Greps (budget-exempt): alternative implementations, guard clauses codifying current behavior, test assertions expecting current behavior. No testable counter-hypothesis: skip phase 2. Contradicting evidence: note as "Counter-evidence: ..." for path decision. Print: `DISCONFIRMATION: {counter-evidence found | no contradicting evidence | no testable counter-hypothesis}`.

For audit inputs, see Audit Input Trust in `~/.claude/skills/apex/apex-doc-formats.md`.

**Scan exit.** Print preliminary modification list. For audit/discovery tasks, list defines exploration scope (minimal is expected -- scouts expand). **Disarm budget:** `rm -f .claude-tmp/apex-active/{session-id}-budget.json`.

**Scan-exit checkpoint (Path 2 only).** Verify: (1) top 2 files exist via Glob, (2) named function/component in at least one file via Grep. Budget-exempt. Update mod list if check fails.

Ambiguous request: AskUserQuestion before proceeding.

## Step 3: Decide Path

<!-- Design: Path selection is automatic -- no flags. Criteria below are the canonical definition. -->

**Path 1 (Direct)** -- ALL true:
- Single concern
- <=5 files with non-trivial changes (mechanical changes don't count)
- Patterns clear

**Caution:** Cross-layer renames/refactors (DB + API + shared + frontend) -> Path 2.

**Path 2 (Delegated)** -- ANY true:
- Multiple concerns (frontend + backend, cross-layer)
- >5 files
- Cross-cutting across packages
- Uncertain scope
- "audit" mentioned (needs scout audit mode). Exceptions: (1) audit-remediation evaluates normally. (2) Small-scope behavioral audits meeting ALL Path 1 criteria stay Path 1. (3) Catalog-matched audits routed via Step 1.5.
- Document creation requested ("create a prd", "write requirements", "spec out") -> Path 2 for apex-apex.md Step 2.6

Print: `PATH DECISION: Path {1/2}` + one-line justification. No source reads between scan exit and Step 5A.
Update manifest: `bash ~/.claude/skills/apex/scripts/update-manifest.sh {session-id} path={path} current_step=3` (best-effort)

**Effort assessment (Path 1 only).** Follow `effort-trigger.txt`. Path 2 skips (scouts/plan have own triggers).

## Step 3.5: Load Relevant Lessons (Path 1 only)

Skip for Path 2 (apex-apex.md Step 3.5 calls this directly).

1. Extract key terms from task, file names, package names.
   - Max 8 terms. Prefer specific (function names, tables, components) over generic.
   - Blocklist (bare): `token`, `config`, `migration`, `email`, `auth`, `service`, `model`, `error` -- qualify them (e.g., `tiktok_token`).
   - Meta/workflow tasks: use specific skill/mechanism names.
   - Max 2 attempts. >150 lines output: re-run after dropping the 1-2 most generic terms (preserve specific function/component/table names). Do not replace with highly specific symbols -- that tends to match nothing. Do not Read tool result files or pipe through cat. Empty: skip.
2. `bash ~/.claude/skills/apex/scripts/grep-lessons.sh {project-root} {term1} {term2} ...` -- script missing or no output: skip.
3. Output has `--- LINES {start}-{end} ---` markers. Update `[last-hit]` dates (skip if all within current ISO week):
   `bash ~/.claude/skills/apex/scripts/update-hit.sh {project-root}/.claude/lessons.md {line1} {line2} ...` (idempotent).
4. Keep lessons in context. Include relevant sections in subagent spawn prompts.

## Step 5A: Execute Direct (Path 1)

Update manifest: `bash ~/.claude/skills/apex/scripts/update-manifest.sh {session-id} current_step=5A` (best-effort)

**Zero-implementation path.** No changes needed (audit: zero discrepancies, investigation: current behavior correct): skip to Step 6A sub-step 4 (reflect) + 5-6 (cleanup + summary).

Always TaskCreate for every change (overrides global 3+ threshold -- APEX needs per-change tracking).

**Create implementation tasks upfront** before any implementation. Lead tail-dispatch tasks (lessons, docs, reflect) are created in Step 6A. Teammates (Path 2) also create a per-teammate "Verify and reflect" completion task in apex-teammate-workflow.md Phase 2 -- that is distinct from lead tail dispatch.

1. TaskCreate per change (subject, description, activeForm).
2. **File health gate resolution.** For each flagged file:
   - >400L AND >10 net new lines: split first (extract to new module), add as prerequisite task
   - Modify-only (no net additions): skip
   - Trivial-edit (>500L but <=10 net new): allow inline, log to `.claude-tmp/file-health-notes.md` as `deferred-split-trivial-edit-{N}L`
   - New extraction targets: (i) pre-extend scope file BEFORE first Write, (ii) grep all import sites before extracting
   - Print `GATE RESOLVED: {path} -- {disposition}` for each
3. Execute implementation:

**Single change:** TaskUpdate in_progress -> implement -> TaskUpdate completed

**Multiple changes:** Read and follow `~/.claude/skills/apex/subagent-delegation.md` (includes mandatory pre-spawn baseline [step 4] and post-spawn scope check [step 10]). Pass: modification list, lessons, scout findings summary, Related Existing patterns.

**Mid-implementation file health.** Before adding >10 lines to any file, run `wc -l`. Apply gates per Step 2.

**Scope extension.** Legitimate cascades to out-of-scope files: `python3 -c "import json; d=json.load(open('.claude-tmp/apex-active/{session}-scope.json')); d['files'].append('{path}'); json.dump(d, open('.claude-tmp/apex-active/{session}-scope.json','w'))"`. Also update manifest via update-manifest.sh.

**Parallel spawn notes:**
- Audit-remediation doc-code mismatch: instruct agent to grep affected term across target dir (stale terms in sibling files)
- TaskUpdate each to completed as agents return
- Stale diagnostic filter: per shared-guardrails #19
- Post-subagent scope check: per delegation protocol steps 4+10. Unauthorized files: AskUserQuestion "Revert / Keep / Review diff"
- **Replan trigger.** Unexpected complexity (scope doubles, dead end): STOP, print `REPLAN: {reason}`. Re-evaluate path criteria. Path 2 needed: abandon Path 1, restart from Step 5B with new `PATH DECISION: Path 2`. Same path, different approach: AskUserQuestion before reverting.

**Dependent (sequential):** Execute sequentially with TaskUpdate in_progress -> implement -> completed.

## Step 6A: Tail (Path 1)

**Diagnostic blackout** (agent return through verification PASS). No LSP/TS diagnostic investigation. Verifier is authoritative.

Update manifest: `bash ~/.claude/skills/apex/scripts/update-manifest.sh {session-id} current_step=6A tail_mode={economy|full}` (best-effort)

1. **Requirements cross-check.** Re-read task. Verify each requirement covered in ALL mod list files. Asset-replacement: re-grep replaced pattern for missed surfaces.
1a. **Infrastructure commands (Path 1).** Identify runtime activation needed: migrations, seeders, codegen, external service provisioning, dependency installs. Collect for verifier prompt.
1b. **Doc update setup (audit-remediation/prd-implementation only).** Include "Update audit/PRD file" tail task in sub-step 3.
1c. **Economy tail detection.** Catalog-only override: ALL files under `.claude/audit-criteria/` or `~/.claude/audit-criteria/` -> force economy (skip detect-tail-mode.sh). Otherwise: `bash ~/.claude/skills/apex/scripts/detect-tail-mode.sh {files}`. Economy: <=5 files AND <=80 lines changed; else full.

2. **Verification.** Catalog-only: skip apex-verify, run `python3 ~/.claude/skills/apex/scripts/audit-catalog-health.py --catalog-dir {dir} --project-root {root}`. Fix issues. Print `CATALOG VERIFY: {N} issues`.
Otherwise: spawn sonnet subagent: "ASCII only. No tables, no diagrams. Read and follow ~/.claude/skills/apex/apex-verify.md. Modified files: {list}. Path: 1. Change type: {type}. Scope: modification list only. Minimal corrections only. Infrastructure commands: {list or 'auto-detect'}."
   - Economy: append "Economy -- build+lint only, skip tests."
   - UI-only: append "UI-only -- skip tests (Step 3.7)."
   - Full tail: wrap in TaskCreate "Verify build and lint" with blockedBy.
   - Fail after retries: stop and report.
   - **Agent fallback:** spawn fails/times out/no verdict: run `pnpm build 2>&1 | tail -30` then `pnpm lint 2>&1 | tail -20` directly.
   - After PASS: trust verdict, don't re-read files for stale diagnostics.
   - **Post-verify scope check.** `git diff --name-only`. Out-of-scope: AskUserQuestion "Revert / Keep / Review diff". No autonomous revert.

2b. **Inline diff write (MANDATORY, before tail dispatch).** Owned by the caller, not by apex-tail.md, so the Write tool call cannot be dropped into a parallel agent-spawn batch. Skip only for zero-implementation sessions (no changes committed). Steps:
   1. Generate RUN_ID via Bash: `echo "$(date +%Y%m%d)-$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)"`
   2. `mkdir -p .claude-tmp/git-diff` (Bash)
   3. Write a 1-3 sentence summary with a `Files: [list]` line (all modified file paths) to `.claude-tmp/git-diff/git-diff-{RUN_ID}.md` (Write tool, direct call by main agent -- no subagent).
   4. Print `DIFF WRITTEN: .claude-tmp/git-diff/git-diff-{RUN_ID}.md` verbatim.
   Do not batch this with Step 3 agent spawns -- execute it as its own sequential tool call, then proceed to Step 3.

3. **Tail dispatch.** Read and follow ~/.claude/skills/apex/apex-tail.md. Pass: tail mode, session type, implementation summary, files modified, tricky patterns, doc targets from CLAUDE.md Doc Quick Reference. Audit-remediation/prd-implementation: include doc path + completed IDs. For test-gaps source: note .claude-tmp/test-gaps.md origin. Tail pre-flight will abort if `DIFF WRITTEN` was not printed in sub-step 2b.

   **Path 1 task tracking (full tail only).** Create TaskCreate per applicable tail agent before following apex-tail.md spawn protocol. Set in_progress, follow parallel spawn, mark completed after return. Economy: skip tracking.
3b. **Post-tail scope advisory.** `git diff --name-only` -- print `TAIL TOUCHED: {extra files}` (informational).
3c. **Tail-discovered code gaps.** Tail agent reports code changes needed: extend scope, make edit, re-run verification on new files if build-affecting. Print `TAIL CODE FIX: {files}, reason: {report}`.
4. **Reflect decision.** Print `REFLECT DECISION: {spawn|skip} -- {reason}`. Condition: session downgraded from Path 2 (manifest `path` == `'1-downgraded'` or apex-apex.md Step 2.6 executed). Economy + spawn: `REFLECT DECISION: skip -- economy gate supersedes downgrade`. Full + spawn: run reflect inline (mode: execution, economy: false, categories 1-6, 9-11, skip 7-8, 12). Not downgraded: skip (Path 1 lacks scout/plan/team phases).
5. Cleanup: `bash ~/.claude/skills/apex/scripts/cleanup-session.sh {session-id}`
6. **Completion gate.** TaskList. Pending/in_progress: `BLOCKED: {N} tasks incomplete -- {subjects}`. Resolve before summary.
7. Print: `APEX completed. {N} files changed. Verify: {pass/fail}. Tail: {economy/full} ({agents}).` Use `git diff --stat`. Numbered list format (shared-guardrails #15).

Stop here for Path 1.

## Step 5B: Execute Delegated (Path 2)

Read ~/.claude/skills/apex/apex-apex.md and execute from Step 2. That file owns the entire Path 2 workflow (scout, lessons, plan, EnterPlanMode). Do not do any of these here. Includes audit tasks -- audit document creation handled by apex-apex.md Step 2.6.

**Mandatory handoff -- no shortcuts.** Extended scan-phase discussion does not substitute for Path 2 flow. PRD/audit tasks still require full chain: apex-apex.md Step 2 onward (Step 2.6, pre-plan reflection Step 4.5, lessons-only tail). Do not jump to document creation from SKILL.md.

## Forbidden Actions

Shared guardrails: read ~/.claude/skills/apex/shared-guardrails.md. Additionally:

- Route complex tasks through apex-apex.md -- SKILL.md lacks scout/plan/team phases
- Call EnterPlanMode only from apex-apex.md, not SKILL.md
- Delegate scouts to apex-apex.md for Path 2
- Delegate independent tasks to parallel subagents (not direct parallel Edit/Write) unless small-change exception (Step 5A)
- Per shared-guardrails #1: foreground agents for tail tasks -- main session blocks until all return before "APEX completed"
- Defer source reads to Step 5A (Step 2 scan rule). Source reads in main context cause context rot.
- Respect Step 2 scan budget (5 Grep/Glob, 3 doc Read). At 5/5: stop, proceed to Step 3. Exception (a)/(b) source reads and remaining doc reads may continue. Route to Path 2 if underexplored.
- Direct Glob/Grep only during Quick Scan (Step 2). Subagents start in Step 5A or apex-apex.md Step 2.
- Browser automation/interactive tools (Chrome MCP): inline in main session only
- Always run concurrency check (Step 0)
- Route audit document creation through apex-apex.md Step 2.6 exclusively
- Manifest operations (`.claude-tmp/apex-active/*.json`): best-effort, never retry
