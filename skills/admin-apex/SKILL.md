---
name: admin-apex
description: "APEX workflow administration, improvement, and skill management reference."
triggers:
  - admin-apex
---

# admin-apex - APEX Workflow Administration

Reference for understanding, modifying, or extending APEX.

## Flags

Parse arguments for flags before displaying reference:
- `--improve [conversationId]`: Read and follow `~/.claude/skills/admin-apex/admin-apex-improve.md`. Checks for Claude Code version updates (analyzes release notes for new features), runs catalog health checks (`audit-catalog-health.py` on global `~/.claude/audit-criteria/` and project `.claude/audit-criteria/`), then analyzes conversation transcript (if conversationId provided) and/or accumulated workflow improvements from `~/.claude/tmp/apex-workflow-improvements.md`. Applies improvements to any global skill (see Skills section below), project-level skills (`.claude/commands/`), and audit criteria catalogs. Auto-commits and pushes global skill file changes to git after implementation. Project-level skill changes are left for the user to commit via `/apex-git`. Stop after (do not display reference below).

If no flags but freeform text follows (e.g., audit requests, health checks), first batch-fetch deferred tools: `ToolSearch select:TaskCreate,TaskUpdate,TaskList,AskUserQuestion`. Then use the reference below as context and act on the request. Follow CLAUDE.md workflow rules (TaskCreate for 3+ distinct concerns (APEX sessions override: see apex/SKILL.md Step 5A), parallel Explore agents for multi-area investigation, shared-guardrails.md). Follow the Forbidden Actions at the bottom of this file.

For complex multi-concern freeform tasks (audits spanning 3+ skills, health checks across workflow areas), recommend `/apex` for structured scouting and planning. For single-concern queries (explanations, quick checks, single-file reviews), handle inline.

If no flags and no freeform text, display reference below.

## Skills

- `~/.claude/skills/apex/` - Main workflow (entry: SKILL.md)
- `~/.claude/skills/apex-fix/` - Fix lint/build errors, then capture lessons
- `~/.claude/skills/apex-git/` - Commit and push using accumulated diff summaries
- `~/.claude/skills/apex-party/` - Multi-persona panel discussion
- `~/.claude/skills/apex-brainstorm/` - Brainstorming facilitator (see brain-methods.md for technique catalog)
- `~/.claude/skills/apex-lessons-extract/` - Consolidate temp lessons
- `~/.claude/skills/apex-lessons-analyze/` - Deduplicate, freshness-check, merge, and route lessons
- `~/.claude/skills/apex-eod/` - End of day (chains file-health, extract, improve, analyze, git sequentially)
- `~/.claude/skills/apex-file-health/` - Remediate oversized files flagged by apex-verify
- `~/.claude/skills/apex-init/` - Initialize new projects with APEX-compatible structure
- `~/.claude/skills/apex-audit-matrix/` - Coverage-tracked audit with deterministic enumeration, persistent verdict storage (`.claude/audit-verdicts/`), file-hash-based change detection, and incremental re-verification. Uses criteria catalogs (project-level `.claude/audit-criteria/`), enumeration script (`scripts/enumerate-audit-matrix.py`), and findings-to-catalog pipeline (`scripts/findings-to-catalog.py`) for evolving catalogs from OPEN-01 findings
- `~/.claude/skills/apex/apex-doc-formats.md` - Audit/PRD document schemas, Session Type Reference (path/ID prefix/completed-list key/priority order), and Document Mutation Protocol (inline markers, YAML update, completion gate). Referenced by SKILL.md Step 1 (batch-mode detection), apex-tail.md Agent 3 (document mutation), apex-apex.md Step 2.6 (document creation).
- `~/.claude/skills/apex/apex-update.md` - Doc updates (called by apex-tail.md Agent 2, apex-file-health Step 6)
- `~/.claude/skills/apex/apex-learn.md` - Captures implementation lessons. Called by apex-tail.md Agent 1, apex-fix Step 3, and apex-file-health Step 6.
- `~/.claude/skills/apex/apex-reflect.md` - Captures workflow execution observations (scan accuracy, path decisions, token waste, bias, compliance). Called by apex-apex.md Step 4.5 (discovery), plan Phase 4 (execution), admin-apex-improve.md Phase 3.7 (execution), and SKILL.md Step 6A (Path 2 downgrade).
- `~/.claude/skills/apex/apex-verify.md` - Build/lint/test verification. Called by SKILL.md Step 6A, apex-file-health Step 5.
- `~/.claude/skills/apex/apex-tail.md` - Post-implementation tail dispatch (lessons, docs, audit/PRD updates). Called by SKILL.md Step 6A, apex-apex.md Phase 4.
- `~/.claude/skills/apex/apex-apex.md` - Path 2 delegated flow orchestrator (scout, lessons, pre-plan reflect, plan, team execution, tail). Called by SKILL.md Step 6A when Path 2 is selected.
- `~/.claude/skills/apex/apex-scout.md` - Scouting and discovery. Called by apex-apex.md Step 2.
- `~/.claude/skills/apex/apex-team.md` - Team lifecycle management. Called by apex-apex.md Step 4.
- `~/.claude/skills/apex/apex-teammate-workflow.md` - Teammate execution phases. Called by apex-team.md.
- `~/.claude/skills/admin-apex/` - This reference

## Project-Level Skills

Some projects have project-specific slash commands in `.claude/commands/`. These are markdown files that become `/command-name` in Claude Code, committed with the project repo (not the global skills repo).

**Tracking:** Projects should list their skills in the "Project Skills" section of their CLAUDE.md. apex-init creates this section during initialization.

**Improving:** `admin-apex --improve` covers both global skills (`~/.claude/skills/`) and project-level skills (`.claude/commands/`). Changes are written as diff summaries for `/apex-git` to commit and push (no inline git operations). In the eod chain, `/apex-git` runs after improve and picks up the summaries automatically.

**Creating:** apex-init creates the `.claude/commands/` directory. Users add skill files manually as needed and document them in CLAUDE.md.

**Overriding:** Project CLAUDE.md entries can override APEX behavior per-project without modifying global skill files. Since CLAUDE.md is loaded into context alongside skill instructions, it can redirect behavior (e.g., file path resolution, phase routing). Use this when a project needs different defaults from the global APEX workflow.

## Git Sync

Repository: https://github.com/Maelmaelr/claude-code-apex (private)
Git root: `~/.claude/` (tracks full Claude Code config, not just skills)

Tracked content: skills/, settings, keybindings, statusline, project memories, plugin config, tmp/.
Excluded (via .gitignore): sessions, debug, history, caches, telemetry, project session data.

When user requests git sync (e.g., "update git", "sync apex", "push changes"):

1. Check for changes: `cd ~/.claude && git status`
2. If changes exist, stage ALL changes and commit:
   ```bash
   cd ~/.claude && git add . && git commit -m "Update Claude Code config" && git push
   ```
   `git add .` is safe -- `.gitignore` already excludes sessions, caches, credentials, and runtime data. Using selective staging misses untracked (new) files.
3. Report what was committed

To pull latest: `cd ~/.claude && git pull`

## Architecture

Two paths based on task complexity. Full flow details in `apex/SKILL.md`.

- **Concurrency detection** (Step 0): Session manifests in `.claude-tmp/apex-active/`, advisory overlap warnings. See SKILL.md Step 0.
- **Path 1 (Direct):** Scan -> path gate -> lessons -> implement -> verify -> conditional tail (pre-flight gated). See SKILL.md Steps 3-6A.
- **Path 2 (Delegated):** Scan -> path gate -> scout -> re-evaluate (2.6) -> lessons -> pre-plan reflect -> effort assessment -> plan -> plan approval -> team execution -> verify -> team cleanup -> tail -> reflect. See apex-apex.md, apex-scout.md, apex-team.md, apex-teammate-workflow.md, apex-tail.md.
- **Audit/PRD flows:** Scout auto-detects audit mode; apex-apex.md Step 2.6 routes to audit or PRD document output. Incremental remediation via subsequent `/apex .claude-tmp/{audit,prd}/<name>.md`. Session type mapping (path, ID prefix, completed-list key, priority order) and Document Mutation Protocol (inline markers, YAML update, completion gate) live in apex-doc-formats.md. See apex-scout.md, apex-apex.md Step 2.6, apex-tail.md Agent 4, apex-doc-formats.md.
- **Audit catalog auto-routing (Step 1.5):** `/apex audit {subject}` auto-detects matching criteria catalogs in `.claude/audit-criteria/` (project) and `~/.claude/audit-criteria/` (global). Single match routes directly to audit-matrix (skips scan/scout/Path 2). Multiple matches or no match prompts user via AskUserQuestion. Falls through to scout audit mode when user selects "no catalog". See SKILL.md Step 1.5.
- **Coverage-tracked audit flow:** `/apex-audit-matrix` generates a deterministic (target x criterion) matrix via enumeration script, distributes cells to scouts with inline criterion definitions (from matrix JSON `criteria_definitions` field -- scouts never read the catalog file), persists verdicts. Persistent verdict storage (`.claude/audit-verdicts/`) with file-hash change detection makes `--resume` optional for subsequent runs. OPEN-01 FAIL findings auto-generate candidate catalog entries via `findings-to-catalog.py`. Criteria catalogs live in project `.claude/audit-criteria/` (project-level) and `~/.claude/audit-criteria/` (global/skill-level). Catalog limits: max 60 criteria, max 600 lines per catalog file; larger domains must be split into thematic sub-catalogs. `/apex` auto-routes to this flow when a matching catalog is found (Step 1.5); `/apex-audit-matrix` remains available for direct invocation with explicit `--catalog`, `--resume`, `--scope`, `--verdicts-dir`, `--no-persist` flags. Large audits (>60 unchecked cells, >15 files) route to Agent Teams via TeamCreate for independent 1M-token context windows per worker (fallback to subagent dispatch if TeamCreate fails). See apex-audit-matrix/SKILL.md (Catalog Design section), SKILL.md Step 1.5, apex-audit-matrix/verdict-storage.md.
- **Skill quality audit flow:** `/apex-audit-matrix --catalog ~/.claude/audit-criteria/skill-quality.md --root ~/.claude/skills` audits skill structure, cross-references, and quality. 23 criteria across entry points, sub-workflows, cross-references, quality, and scripts. Health check: `python3 ~/.claude/skills/apex/scripts/audit-catalog-health.py --catalog-dir ~/.claude/audit-criteria/ --project-root ~/.claude/skills`.
- **File health flow:** apex-verify Step 3.8 persists notes; apex-file-health remediates. See apex-file-health/SKILL.md.
- **Context health flow:** `context-health-check.sh` enforces char budgets on CLAUDE.md, skill files, rules, and MEMORY.md. admin-apex-improve.md Phase 1.9 gates additions to over-budget files. Category 12 (context rot) spot-checks CLAUDE.md entries against codebase during improve cycles.
- **Diff/Git flow:** Diff summaries written inline (SKILL.md Step 6A, apex-tail.md, admin-apex-improve.md Phase 3.6); `/apex-git` batch-commits. See apex-git/SKILL.md.
- **PreCompact/PostCompact/StopFailure hooks:** `~/.claude/skills/apex/scripts/precompact-apex.sh` echoes active session state (task, path, step, files). PreCompact runs before compaction (helps summarizer preserve state); PostCompact runs after compaction (guarantees full-fidelity re-injection); StopFailure runs on API errors (rate limit, auth failure) to preserve state before session drops. Config in `~/.claude/settings.json` hooks.
- **Lesson flow:** See apex-lessons-extract/SKILL.md for write/consolidate flow (includes tag format reference for all three lesson types). SKILL.md Step 3.5 for read/hit-tracking (canonical procedure, referenced by both paths).
- **Agent types:** Subagents (Agent tool) are child processes within one session -- used in Path 1 parallel implementation, Path 2 scouts, tail workflows. Agent Teams (TeamCreate/SendMessage) are independent Claude Code instances for Path 2 implementation -- see apex-teammate-workflow.md for the 4-phase lifecycle.
- **Agent definitions** (`~/.claude/agents/`): Reusable agent definitions with YAML frontmatter (name, description, tools, disallowedTools, model, effort, maxTurns). Three definitions: `scout.md` (read-only exploration/audit), `verifier.md` (build/lint/test validation), `evaluator.md` (independent PASS verdict re-verification). Invoked via Agent tool with agent definition reference.
- **Scope enforcement hook** (PreToolUse, Edit|Write): `scope-check-hook.sh` reads `.claude-tmp/apex-active/{session}-scope.json` and blocks writes to files outside the allowed scope. Inactive when no scope file exists (non-APEX sessions). Always allows `.claude-tmp/` paths, `.claude/plans/` paths (system-generated plan files), and APEX infrastructure paths (`.claude/audit-criteria/`, `.claude/audit-verdicts/`, `.claude/scout-findings/`, `.claude/lessons*`).
- **Scan budget hook** (PostToolUse, Grep|Glob): `scan-budget-hook.sh` reads/increments counter in `.claude-tmp/apex-active/{session}-budget.json` and blocks when count exceeds max. Inactive when no budget file exists.
- **Evaluator loop** (Phase 2.5 in audit-matrix): After scout verdicts (Phase 2), samples 20-30% of PASS cells weighted by severity, launches independent evaluator agent for re-verification. Overrides false PASS to FAIL. Cap at 2 rounds. Skipped when < 10 PASS cells. See apex-audit-matrix/SKILL.md Phase 2.5.
- **Env/credential protection hook** (PreToolUse, Read|Edit|Write): `protect-env-hook.sh` blocks access to `.env*` files (except `.env.example/sample/template`) and known credential files (`credentials.json`, `secrets.yaml`, `.npmrc`, etc.). Always active.
- **Destructive command hook** (PreToolUse, Bash): `block-destructive-hook.sh` blocks destructive git commands (`git checkout --`, `git restore`, `git reset --hard`, `git clean -f`), force push to main/master, `.env` reads via shell (`cat/grep .env`), and dangerous `rm` operations targeting `/`, `~`, or `.`. Always active.

## Scripts

Deterministic utility scripts in `~/.claude/skills/apex/scripts/`. Replace LLM-driven mechanical tasks with reusable bash/python. All scripts support `--help`, use exit codes as signals, and are idempotent.

**Workflow infrastructure (bash):**
- `precompact-apex.sh` -- Echo active session state for compaction preservation. Called by: PreCompact/PostCompact/StopFailure hooks.
- `detect-tail-mode.sh` -- Determine economy vs full tail from file change scope. Called by: SKILL.md Step 6A, apex-plan-template.md.
- `grep-lessons.sh` -- Extract matching lesson blocks from lessons-index.md + lessons.md. Called by: SKILL.md Step 3.5, apex-verify.md, apex-fix.
- `update-manifest.sh` -- Update APEX session manifest JSON fields. Called by: SKILL.md (3x), apex-apex.md (2x).
- `file-health-check.sh` -- wc -l wrapper, outputs files exceeding threshold (blocked >500L, split-first >threshold). Called by: SKILL.md Step 2, admin-apex-improve.md Phase 1.8.
- `context-health-check.sh` -- Char budget checker for CLAUDE.md, skill files, rules, and MEMORY.md. Thresholds: project CLAUDE.md warn 30k/block 40k, skill SKILL.md warn 35k/block 45k, skill sub-files warn 30k/block 40k, rules warn 6k/block 10k. Exit 0=clean, 1=warnings, 2=blocks. Called by: admin-apex-improve.md Phase 1.9.
- `update-hit.sh` -- Bump `[last-hit]` dates to today for specified lines in lessons.md. Called by: SKILL.md Step 3.5, apex-verify.md.
- `cleanup-session.sh` -- Pattern-based .claude-tmp/ session artifact cleanup by session-id. Called by: apex-git Step 4.
- `scope-check-hook.sh` -- APEX scope constraint hook (PreToolUse). Reads allowed files from `{session}-scope.json`, blocks Edit/Write to out-of-scope files. Called by: settings.json PreToolUse hook.
- `scan-budget-hook.sh` -- APEX scan budget hook (PostToolUse). Tracks Grep/Glob call count in `{session}-budget.json`, blocks when budget exceeded. Called by: settings.json PostToolUse hook.
- `scout-context-truncate-hook.sh` -- APEX scout context advisory hook (PostToolUse, matcher: Read). If a Read result exceeds 300 lines and an active APEX session manifest exists, emits additionalContext suggesting offset/limit for targeted reads. Advisory only -- does not block. Called by: settings.json PostToolUse hook.
- `security-scan.sh` -- Pattern-based security scan fallback (3-tier: FAIL/WARN/INFO, excludes test/fixture files). Called by: apex-verify.md (when Semgrep unavailable).
- `protect-env-hook.sh` -- Guardrail hook (PreToolUse, Read|Edit|Write). Blocks .env* files (except .env.example/sample/template) and known credential files. Called by: settings.json PreToolUse hook.
- `block-destructive-hook.sh` -- Guardrail hook (PreToolUse, Bash). Blocks destructive git commands, force push to main/master, shell .env reads, dangerous rm. Called by: settings.json PreToolUse hook.

**Audit infrastructure (python, stdlib only):**
- `enumerate-audit-matrix.py` -- Parse criteria catalog, expand target globs, pre-filter via grep, output coverage matrix JSON. Called by: apex-audit-matrix/SKILL.md Phase 1. Supports --resume for incremental re-audit, --verdicts-dir/--no-persist for persistent verdict storage with file-hash change detection.
- `audit-catalog-health.py` -- Validate catalogs against codebase state: stale targets, size limit violations, criteria-count mismatches, source drift. Called by: apex-audit-matrix/SKILL.md Phase 0, admin-apex --improve. Supports --json for CI output. v3.0.
- `audit_matrix_lib.py` -- Shared library for audit scripts. Functions: parse_catalog, parse_catalog_with_metadata, expand_targets, pre_filter_applicable, is_scope_all, compute_summary, compute_file_hash. Imported by: enumerate-audit-matrix.py, findings-to-catalog.py, audit-catalog-health.py, mechanical-audit.py. v2.0.
- `findings-to-catalog.py` -- Extract OPEN-01 FAIL cells from matrix JSON, generate candidate catalog entries for human review. Called by: apex-audit-matrix/SKILL.md Phase 3 (auto-run after OPEN-01 failures). Output: `{catalog-dir}/candidates-{date}.md`.
- `evaluator-sample.py` -- Sample PASS cells from audit matrix for evaluator re-verification. Weights by criterion severity (CRITICAL 3x, HIGH 2x, MEDIUM 1x, LOW 0.5x), verifies file hashes current. Called by: apex-audit-matrix/SKILL.md Phase 2.5. Supports --matrix, --sample-pct, --min-sample.
- `mechanical-audit.py` -- Deterministic shell checks for mechanical audit cells (file existence, grep, count). Called by: apex-audit-matrix/SKILL.md Phase 1.5. Supports --matrix, --catalog.
- `mark-cells-remediated.py` -- Mark specific audit matrix cells as remediated after code fixes. Updates cell status, recomputes summary stats, writes back matrix JSON. Called by: apex-audit-matrix/SKILL.md Marking Cells section. Args: matrix-path + one or more "target:CRITERION_ID" pairs.
- `validate-document.py` -- Structural validation for audit/PRD documents. Called by: apex-apex.md Step 2.6.
- `audit-baselines.py` -- Audit improvement baseline metrics (token-proxy, finding-delta, coverage-gap subcommands). Utility, no .md caller.

**Analysis (python, stdlib only):**
- `stale-lessons.py` -- Identify lessons with stale `[last-hit]` dates (>N days, default 90). Called by: apex-lessons-analyze Step 3.5.
- `lesson-dedup.py` -- Fuzzy-match lesson blocks via difflib SequenceMatcher, output candidate pairs. Called by: apex-lessons-analyze Step 2.
- `scout-dedup.py` -- Scout finding deduplication and convergence detection. Reads findings with FINGERPRINT fields, deduplicates against persistent store keyed by theme, reports delta + convergence metrics (exit 0=new findings, exit 1=converged <10% new). Called by: apex-scout.md after findings write (both single and multi-scout paths). Supports --theme, --findings-file, --no-persist.
- `rebuild-memory-index.py` -- Parse memory/*.md frontmatter, regenerate MEMORY.md index. Manual invocation.

**Extraction (python, standalone):**
- `apex-extract.py` -- Extract compact summary from Claude Code JSONL transcript. Called by: admin-apex-improve.md Step 1.
- `apex-changelog-extract.py` -- Extract changelog sections between semver versions. Called by: admin-apex-improve.md Step 1.5.

## Runtime Files

**Persistent (project knowledge):** .claude/lessons.md, .claude/lessons-index.md, .claude/lessons-archive.md -- master lessons with hit-tracking, keyword index, and stale lesson archive. Use Glob/Grep to discover specific files.

**Global (cross-project):** ~/.claude/tmp/ -- workflow observations (apex-workflow-improvements.md) and version tracking (apex-claude-code-version.txt).

**Project audit infrastructure:** .claude/audit-criteria/ -- criteria catalog markdown files (security.md, etc.) defining verifiable properties with target globs, pre-filter patterns, and severity. Max 60 criteria / 600 lines per catalog; split larger domains into thematic sub-catalogs. Committed with the project repo. .claude/audit-verdicts/ -- persistent verdict JSON files ({theme}-verdicts.json) with file-hash change detection, auto-created by audit-matrix runs. .claude/scout-findings/ -- persistent scout finding store JSON files ({theme}.json) with file-hash-based staleness detection, written by scout-dedup.py after each scout run for cross-session deduplication and convergence tracking.

**Session (ephemeral):** .claude-tmp/ -- pending lessons, concurrency manifests, scout findings, audit checklists, diff summaries, teammate context, party/brainstorm transcripts, test gaps, file health notes, audit/PRD documents, audit-matrix JSON (coverage state). Cleaned by apex-git or per-session.

**Infrastructure (team execution):** ~/.claude/tasks/{team-name}/ and ~/.claude/teams/{team-name}/ -- shared task lists and team configs managed by TeamCreate/TeamDelete.

## Key Design Decisions
1. Mandatory project-context.md read -- SKILL.md Step 2, apex-apex.md plan Context
2. Context clearing via plan -- apex-apex.md EnterPlanMode
3. Conditional scouting -- apex-scout.md Mode Selection
4. Path re-evaluation gate -- apex-apex.md Step 2.6
5. All tasks created upfront -- SKILL.md Step 5A, apex-teammate-workflow.md Phase 2
6. Parallel where independent -- scout agents, teammates, subagents, tail workflows
7. Economy tail -- SKILL.md Step 6A (<=5 files, <=80 lines triggers reduced tail)

Additional design decisions are documented as `<!-- Design: ... -->` HTML comments in SKILL.md, apex-apex.md, apex-team.md, apex-teammate-workflow.md.

## Model Selection

Three-tier strategy for subagent spawn points. Rationale: most APEX subagents perform read-only exploration, classification, or lightweight file operations where Sonnet is sufficient. Reserving Opus for deep reasoning tasks saves tokens without sacrificing quality.

**Opus (default/inherited):** Deep reasoning -- plan writing, teammate spawns, file splitting, complex multi-file fixes. Path 1 subagents default Opus but downgrade to Sonnet for mechanical single-file tasks.

**Sonnet:** Read-only exploration, classification, lightweight writes, verification, mechanical implementation -- scouts, tail agents, lesson/doc operations, inline lint, eod orchestration, file-health scouts, mechanical lint fixes, skill edits.

**Haiku:** Trivial single-command agents (e.g., test-gaps cleanup).

**Effort levels (Opus 4.6):**
- Main agent: high effort (global `settings.json`). Subagents/teammates: medium by default.
- Dynamic trigger: `~/.claude/skills/apex/effort-trigger.txt` contains the high-effort keyword. Indirection avoids static triggering (keyword in skill content would enable high effort for ALL invocations).
- Trigger placement: skills with "Effort assessment" blocks evaluate complexity during scan/assessment and output the keyword if deep reasoning is needed. Scouts (apex-scout.md), plan writing (apex-apex.md Step 4.6), teammates (apex-teammate-workflow.md).
- Exempt (no effort assessment): mechanical/orchestration skills (apex-git, apex-eod, apex-lessons-extract, apex-lessons-analyze, apex-init).

## Token Budget

`SLASH_COMMAND_TOOL_CHAR_BUDGET` env var controls skill description text in system-reminder (default: unset/~16K chars). Current skill count (12) is well within limits. Dynamic validation: admin-apex-improve.md Step 0.5. Revisit if total system-reminder skills exceed ~30.

## Semantic Rules

All APEX output follows CLAUDE.md Output rules (ASCII only, concise) plus:
- Step numbering: `## Step N:` format
- Every workflow ends with "Forbidden Actions" section
- Callers noted in HTML comment at top of sub-workflows
- No tables or diagrams. Numbered lists when they improve clarity.
- AI-optimized output: no decorative markdown in generated text, no narrative fluff. Structured data over prose.
- Script extraction threshold: when a verification or analysis step exceeds ~20 lines of procedural logic embedded in skill prose, extract it to a standalone script in `~/.claude/skills/apex/scripts/`. Standalone scripts are independently testable, reusable, and keep skill docs focused on workflow control flow.

## Forbidden Actions

Shared guardrails: read ~/.claude/skills/apex/shared-guardrails.md. Additionally:

- Do not modify skill files from freeform requests without user confirmation. Freeform requests (non-flag) are for auditing, reviewing, and reporting -- not auto-applying fixes. Present findings and ask before editing.
- Do not skip reading shared-guardrails.md when acting on freeform requests. The reference sections above are context; the guardrails are constraints.
