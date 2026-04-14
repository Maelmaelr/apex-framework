---
name: apex-file-health
description: Remediate oversized files flagged by apex-verify. Splits files, verifies, runs tail tasks.
triggers:
  - apex-file-health
---

# apex-file-health - File Health Remediation

<!-- Called by: apex-eod/SKILL.md Step 1, standalone via /apex-file-health -->

Safety net for legacy files and edge cases. Primary prevention is enforced during implementation via size gates in SKILL.md Step 2, CLAUDE.md File health gate, and teammate workflow Phase 2 step 6b.

Processes persisted file health notes from `.claude-tmp/file-health/`, splits oversized files, verifies correctness, and cleans up.

## Step 1: Scan Health Notes

Resolve project-root: run `pwd` once and store the result for reuse throughout this workflow.

Batch-fetch deferred tools: `ToolSearch select:TaskCreate,TaskUpdate,AskUserQuestion`.

Glob `.claude-tmp/file-health/file-health-*.md` for health notes.

If no files found, print "No file health notes found. apex-file-health completed." and stop.

If files found, print: `FILE HEALTH: {count} note(s) found`. Read all notes and collect the list of target files with their metadata (path, lines, type).

## Step 2: Validate Targets

Batch-validate all targets in a single Bash call: `wc -l file1 file2 ... 2>/dev/null; for f in file1 file2 ...; do [ -f "$f" ] || echo "MISSING: $f"; done`. Then for each file:
1. If missing (no wc -l output or MISSING), mark note as resolved
2. If <=500 lines, mark note as resolved (file already split in a prior session)
3. If note contains `status: not-separable`, mark note as resolved (previously triaged)

If all notes are resolved, print "All flagged files already remediated. apex-file-health completed." Delete the resolved note files and stop.

Print: `FILE HEALTH: {count} file(s) still need splitting`.

## Step 2.5: Load Relevant Lessons

Extract terms from: target file names, directory names, file types (component, hook, service, controller, test), plus generic split-related terms ("file health", "split", "extract", "barrel", "refactor").

Run: `bash ~/.claude/skills/apex/scripts/grep-lessons.sh {project-root} {terms}`. If output, update `[last-hit]` dates: `bash ~/.claude/skills/apex/scripts/update-hit.sh {project-root}/.claude/lessons.md {line numbers from markers}`. Keep loaded lessons in context -- include relevant sections in subagent spawn prompts (Steps 4, 5).

## Step 3: Analyze and Plan Splits

**Effort assessment:** If files require deep structural analysis for splitting (high cohesion ambiguity, complex dependency graphs), read ~/.claude/skills/apex/effort-trigger.txt and output its content on a separate line.

<!-- Design: Inline analysis preferred (works at any model tier). 6+ files delegate to Step 4 agents (combined analyze+execute pass). -->

**Single target file:** Read the file in main context. Identify separable concerns (distinct functional groups, UI sections, helper clusters, type blocks). Determine split strategy (see checklist below). Print the split plan before executing.

**2-5 target files:** Read all files in parallel (multiple Read calls in a single response). After all reads return, analyze each file inline -- identify separable concerns (same analysis as single file). This avoids agent overhead for small-to-medium batches.

**6+ target files:** Group by parent directory. Build the split strategy checklist template (below) for each group. Pass group assignments to Step 4 agents directly -- each agent analyzes and executes in a single pass (no separate Explore agents). If Agent tool is unavailable (e.g., running as a subagent), proceed inline regardless of count.

**Split strategy checklist** (applied per file, whether analyzed inline or by agent):
- What to extract (name, responsibility, approximate line range)
- Target file name (sibling file in same directory, following project naming conventions)
- Whether barrel export (index.ts) needs updating
- Import updates needed in the source file and external consumers
- Cohesion check: confirm extracted concern is truly separable (not tightly coupled to remaining code via shared mutable state or circular dependencies). If not separable, skip that file and note in report.

Print the validated split plan for each file before executing.

## Step 4: Execute Splits

<!-- Design: Inline splitting preferred (works at any model tier). Parallel agents only for 6+ files across multiple directories. -->

Create TaskCreate entries for each file split (subject: "Split {filename}", description: split plan details, activeForm: "Splitting {filename}").

**Single file to split:** TaskUpdate to in_progress. Execute inline -- extract to sibling file, update imports, update barrel exports, grep for external consumers (including test directories: `__tests__/`, `tests/unit/`, `tests/functional/`) and update their imports. Include relevant lesson sections loaded in Step 2.5. TaskUpdate to completed.

**2-5 files to split:** Execute all splits inline sequentially. For each file: TaskUpdate to in_progress, extract to sibling file, update imports, update barrel exports, grep for external consumers (including test directories: `__tests__/`, `tests/unit/`, `tests/functional/`) and update their imports. Include relevant lesson sections loaded in Step 2.5. TaskUpdate to completed. When multiple files share a barrel (index.ts), update the barrel once after all splits in the group are complete.

**6+ files to split:** Group by parent directory. Files in the same directory are batched into a single splitting agent (shared barrel updates handled consistently by one agent, avoiding conflicting edits). Files in different directories spawn separate agents in parallel. Within a directory group, if files import from each other, note in the agent prompt that splits must be applied sequentially within the group. Assess cross-directory dependencies as before.
- **Pre-spawn baseline:** `git diff --stat > .claude-tmp/pre-agent-diff.stat` (captures dirty-file state so post-split check can detect agent modifications to already-dirty files).
Per shared-guardrails #1, execute all parallel agents in a single response. If Agent tool is unavailable (e.g., running as a subagent), proceed inline regardless of count.

Per subagent:
- subagent_type: "general-purpose"
- model: "sonnet"
- mode: "bypassPermissions"
- description: "Split files in {directory}"
- prompt: "ASCII only. No tables, no diagrams. For each assigned file: (1) read the full file and identify separable concerns (distinct functional groups, UI sections, helper clusters, type blocks). For each concern, determine name/responsibility, approximate line range, target file name (sibling, following project naming conventions). Check if parent directory has an index.ts barrel. (2) Apply cohesion check: confirm each concern is truly separable (no shared mutable state or circular dependencies). Print `SPLIT PLAN: {file}: {concern} -> {target-file}` for each extraction. If cohesion check fails, print `COHESION SKIP: {file}: {reason}` and skip that file. (3) Execute: extract to sibling file, update imports in source file. After all extractions in the group, update barrel exports if applicable, grep for external consumers (including test directories: `__tests__/`, `tests/unit/`, `tests/functional/`) and update their imports. Files: {file list with line counts}. {relevant lesson sections from Step 2.5}. Scope constraint: Only modify files in your assigned group and their direct consumers. Do not expand to sibling files exhibiting similar patterns." When multiple files share a barrel (index.ts), note in prompt to update the barrel once after all splits in the group are complete. Mark your task completed when done.

Each subagent marks its task completed when done.

**Post-split scope check:** After all agents return, run `git diff --name-only` (Bash). Compare changed files against the split plans. Additionally, run `git diff --stat` and compare against `.claude-tmp/pre-agent-diff.stat` -- files whose diff line count increased were modified by agents even if they were already dirty. If any file appears that is NOT in any split plan, report the scope violation and use AskUserQuestion: "Scope violation: split agents modified files outside plan: {files}. Revert these files / Keep changes / Review diff first". Per shared-guardrails #5, report scope violations only -- never auto-revert. Clean up: `rm -f .claude-tmp/pre-agent-diff.stat`.

Wait for all splits to complete before proceeding.

## Step 5: Verify

Verify splits inline. Do not spawn a subagent -- file-health often runs as a subagent itself (e.g., from eod), making sub-subagent spawning unreliable.

**CWD assertion:** Per shared-guardrails #16, run `cd <project-root>` (absolute path) before verification commands.

1. **Lint check:** Run `pnpm --filter <package> lint --fix` for each affected package (deduplicated). Fix errors, retry per shared-guardrails #8 (max 3 attempts).

2. **Build check:** Run `pnpm --filter <package> build` for each affected package (deduplicated). If build fails, read errors, fix, retry per shared-guardrails #8 (max 3 attempts). If unfixable after 3 attempts, mark as failed.

3. **Orphaned import check:** For each source file that had code extracted, Grep for imports of symbols that were moved to the new file. Fix any broken imports.

4. **Size confirmation:** Run `wc -l` on all source and new files. Confirm source files are now <=500 lines and new files are reasonable.

If any check fails after retries, print the failure details and stop. Do NOT delete health notes for files that failed verification. Do NOT run tail tasks (Step 6).

## Step 6: Tail Tasks

<!-- Sibling pattern: apex/apex-tail.md implements the primary tail pattern. Keep pre-flight logic and agent spawn protocol in sync when modifying. -->

Run pre-flight gates to determine which tail agents to spawn.

**Diff (inline):** Generate a RUN_ID (`echo "$(date +%Y%m%d)-$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)"`), `mkdir -p .claude-tmp/git-diff`. Read the diff file first if it exists (Write tool requires prior Read for existing files). Write a 1-3 sentence summary to `.claude-tmp/git-diff/git-diff-{RUN_ID}.md`. No subagent needed.

**Learn pre-flight:** Only spawn if splitting encountered cohesion issues, unexpected consumers, or import tangles. Print `LEARN PRE-FLIGHT: {spawn|skip} -- {reason}`.

If spawning:
- subagent_type: "general-purpose"
- model: "sonnet"
- mode: "bypassPermissions"
- description: "Capture split lessons"
- prompt: "ASCII only. No tables, no diagrams. Flat sections with numbered lists. Read and follow ~/.claude/skills/apex/apex-learn.md. Context: File health remediation split {count} oversized files. Files modified: {list}. New files created: {list}. Splits performed: {brief description of each split}. Tricky patterns: {any cohesion issues, import tangles, or unexpected consumers found during splitting}."

**Update pre-flight:** Only spawn if split files appear in CLAUDE.md Doc Quick Reference targets. Print `UPDATE PRE-FLIGHT: {spawn|skip} -- {reason}`.

If spawning:
- subagent_type: "general-purpose"
- model: "sonnet"
- mode: "bypassPermissions"
- description: "Update docs after splits"
- prompt: "ASCII only. No tables, no diagrams. Read and follow ~/.claude/skills/apex/apex-update.md. Context: File health remediation split {count} oversized files. Files modified: {list}. New files created: {list}. Features/behaviors unchanged -- structural refactor only."

Spawn applicable subagents in parallel (single message, multiple Agent tool calls). Print `PARALLEL SPAWN: [{agent_list}]` before launching. If no subagents needed, skip spawn.

Wait for all spawned agents to complete. Print each agent's summary line verbatim.

## Step 7: Clean Up

Delete each `.claude-tmp/file-health/file-health-*.md` note file that was successfully processed (target file split and verification passed).

Do NOT delete notes for files that:
- Failed verification in Step 5
- Were skipped due to errors during splitting

For files skipped due to cohesion check failure (Step 3): update the note to add a `status: not-separable` line. The note is preserved but auto-resolved on the next run (Step 2 item 3).

## Step 8: Report

Print: "apex-file-health: {split_count} file(s) split, {resolved_count} already resolved, {skipped_count} skipped (not separable), {failed_count} failed. apex-file-health completed."

## Forbidden Actions

Shared guardrails: read ~/.claude/skills/apex/shared-guardrails.md. Additionally:

- Do not delete health notes for files that failed verification
- Do not run tail tasks if verification failed
- Do not retry failed splits more than once
- Do not read target files in main context when 6 or more files need analysis -- delegate to Step 4 agents (up to 5 files may be analyzed inline)
- Do not split a file that fails the cohesion check (tightly coupled concerns are not separable)
