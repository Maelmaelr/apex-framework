# admin-apex-improve - Analyze Session for Skill Workflow Improvements

<!-- Called by: admin-apex SKILL.md (when --improve flag active), apex-eod SKILL.md Step 3 -->

Analyzes transcripts and/or accumulated workflow improvements to identify friction and propose concrete improvements to APEX skill files (apex, apex-fix, apex-git, apex-party, apex-brainstorm, apex-lessons-extract, apex-lessons-analyze, apex-eod, apex-init, apex-file-health, admin-apex), agent definitions (`~/.claude/agents/`), and project-level skills (`.claude/commands/`). Also checks Claude Code version updates for new features. Uses plan mode to distill findings before implementation.

## Step 0: Tool Prefetch and Mode Detection

Batch-fetch: `ToolSearch select:AskUserQuestion,TaskCreate,TaskUpdate,TaskList,WebFetch,EnterPlanMode,ExitPlanMode`

**Budget/scope cleanup:** `find .claude-tmp/apex-active -maxdepth 1 -type f \( -name "*-scope.json" -o -name "*-budget.json" \) -delete 2>/dev/null || true`. Use `find` -- zsh `NULL_GLOB=off` aborts `rm -f *.json` at glob expansion when zero matches.

**Subagent mode:** If no user conversation history (only spawn prompt), set `SUBAGENT_MODE=true`. Skips AskUserQuestion and plan mode (Steps 6-8).

## Step 0.5: Structural Self-Check

1. `find {expanded-path} -maxdepth 2 -name 'SKILL.md' | sort` (Glob fails on `*/SKILL.md` -- known limitation). Count: M.
2. Parse Skills section from admin-apex/SKILL.md (in context). Count listed: N. Extract Token Budget count.
3. Set comparison (reuse sub-step 1):
   - (a) Every listed path exists on disk. Missing = listed but absent.
   - (b) Every disk path in list. Extra = unlisted.
   - (c) Token Budget count matches M.
4. Mismatches -> append to `~/.claude/tmp/apex-workflow-improvements.md`:
   ```
   ## [self-check] Skill registry mismatch: {description}
   Source: structural-self-check
   Finding: {listed but missing / on disk but unlisted / token-budget count off}
   Fix: Update admin-apex/SKILL.md Skills section and/or Token Budget count.
   ```
5. Print: `SELF-CHECK: {N} listed, {M} on disk, {K} mismatches`.

## Step 1: Load Transcript (Conditional)

<!-- FRAGILE: Depends on Claude Code JSONL transcript format. If extraction fails, rely on apex-workflow-improvements.md from apex-reflect. -->
If no conversation ID, skip to Step 1.5.

- Delete stale extracts: `find ~/.claude/tmp -maxdepth 1 -name 'apex-improve-extract*.md' -delete 2>/dev/null; true`
- Expand tilde: `echo ~/.claude/projects`. Glob: `{expanded-path}/**/{conversationId}.jsonl`
- No match: error, stop. Multiple: use current project's directory name match.
- Run extraction (never Read raw JSONL): `python3 ~/.claude/skills/admin-apex/scripts/apex-extract.py "$TRANSCRIPT_PATH" > ~/.claude/tmp/apex-improve-extract.md`
- Read extract for Steps 3-4. If too large, Grep with targeted patterns.

## Step 1.5: Claude Code Version Check

1. Parallel: `claude --version` + read `~/.claude/tmp/apex-claude-code-version.txt`. First run (no saved file): write version, print "Claude Code version tracking initialized at {version}.", skip to Step 2.
2. Same version: print "Claude Code version unchanged ({version}).", skip to Step 2.
3. Fetch changelog:
   - Auth check: `gh auth status 2>/dev/null | grep -q 'Logged in'`. If not authenticated, skip to Tier 2.
   - **Tier 1:** `gh api repos/anthropics/claude-code/contents/CHANGELOG.md -H 'Accept: application/vnd.github.v3.raw' | python3 ~/.claude/skills/admin-apex/scripts/apex-changelog-extract.py {saved} {current}`
   - **Tier 2:** WebFetch `https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md` -> `/tmp/apex-changelog-raw.md`, pipe through extract script, delete temp. Both fail: print skip message, update saved version, skip to Step 2.
4. Evaluate each entry:
   - What is this feature/change?
   - Already leveraged in APEX? If not, which skill(s) benefit?
   - Deprecated/removed/renamed? Grep skill files for old name -- HIGH priority if found (breakage risk).
   - Skip pure bugfixes (memory leaks, race conditions).
5. Fetch docs for actionable features:
   - Preferred: Context7 `query-docs` with `/websites/code_claude` (stable ID)
   - Fallback: WebFetch `https://code.claude.com/docs/en/{page}.md` (pages: agent-teams, hooks, hooks-guide, skills, sub-agents, cli-reference, settings, permissions, mcp, plugins, headless, interactive-mode, memory, checkpointing, fast-mode, changelog)
   - Batch by doc page. Unambiguous features: assess directly without fetch.
6. Append actionable features to `~/.claude/tmp/apex-workflow-improvements.md`:
   ```
   ## [version-update] {feature name} (v{version})
   Source: Claude Code release notes v{version}
   Feature: {one-line}
   APEX impact: {skill file(s) + how}
   Docs: {URL or "n/a"}
   ```
7. Update saved version file.
8. Print: "Claude Code updated {old} -> {new}. {N} versions checked, {M} actionable features."

## Step 2: Load Workflow Improvements

Read `~/.claude/tmp/apex-workflow-improvements.md`. Parse items if content exists.

**Pre-filter rules:**
1. DROP confirmatory-only items (no proposed change): 'works as expected', 'correctly handles', 'behaves as designed', 'properly follows'
2. SURVIVE if ANY: contrast (but/however/although/except/unlike/whereas), comparison (vs/instead of/rather than), suggestion (should/could/consider/recommend), issue (fails/misses/skips/breaks/ignores/drops/loses)
3. SURVIVE if concrete change proposed (Fix field with action, imperative verbs targeting file/step)
4. Compound items survive if ANY clause triggers rule 2

Print: `WORKFLOW-IMPROVEMENTS: {N} loaded, {M} confirmatory dropped`.

**Occurrence counting:** Similar observations (same category + target) with 3+ occurrences from different contexts -> auto-promote HIGH in Step 5.

Surviving items become findings with source "workflow-improvements".

If no transcript (Step 1) AND no workflow improvements (after filtering), continue to Step 2.7. If Step 2.7 also empty, report "Nothing to improve." and stop.

## Step 2.7: Catalog Health Check

Run `audit-catalog-health.py` against catalog directories. Issues become findings.

1. **Global:** If `~/.claude/audit-criteria/` has `.md` files:
   `python3 ~/.claude/skills/apex/scripts/audit-catalog-health.py --catalog-dir ~/.claude/audit-criteria/ --project-root ~/.claude/skills`
2. **Project:** If `.claude/audit-criteria/` exists:
   `python3 ~/.claude/skills/apex/scripts/audit-catalog-health.py --catalog-dir .claude/audit-criteria/ --project-root . > /tmp/apex-catalog-health-project.txt 2>&1`
   **Volume gate:** Parse `ISSUES:` line for count. >50: log count-only summary, skip finding generation. <=50: read and proceed. Delete temp after.
3. **Issue types -> findings:**
   - STALE_TARGET: targets nonexistent files -> update/remove target glob
   - COUNT_MISMATCH / MISSING_COUNT: declared != actual -> update metadata
   - SIZE_EXCEEDED: >60 criteria or >600 lines -> split into sub-catalogs
   - SOURCE_DRIFT: source modified since catalog update -> re-validate criteria
4. Priority: HIGH = STALE_TARGET, COUNT_MISMATCH, SIZE_EXCEEDED. LOW = MISSING_COUNT, SOURCE_DRIFT. Source: "catalog-health".
5. Print: `CATALOG-HEALTH: {N} checked, {M} issues ({H}H/{Med}M/{L}L)`.

## Step 2.5: Stale-State Check

Run `cd ~/.claude && git log --oneline -50` and `cd ~/.claude && git log --name-only --pretty=format: -50 | sort -u` (restore CWD per shared-guardrails #16). Cross-check findings against recent commits. Drop findings whose issue appears resolved (commit message references same guardrail/step/behavior). For survivors whose target file is in changed-files list, diff and Grep for specific target text -- drop if already modified. Print `STALE-STATE: {N} dropped ({M} message, {K} diff)` only if N > 0.

**Concurrency check:** `find ~/.claude/.claude-tmp/apex-active -maxdepth 1 -name 'apex-*.json' -mmin -30 2>/dev/null | wc -l`. If count > 1 (another active improve session detected), print `CONCURRENCY WARNING: parallel improve session detected -- findings may overlap`. Record `CONCURRENCY_DETECTED=true` for Phase 3.6.

## Step 3: Identify Skill Execution (Transcript Only)

If no transcript loaded, skip.

Read extract and identify skill invocations: `/apex`, `/apex-fix`, `/apex-git`, `/apex-eod`, `/apex-file-health`, `/apex-party`, `/apex-brainstorm`, `/apex-init`, `/apex-lessons-extract`, `/apex-lessons-analyze`, `/admin-apex`. Also: project-level skills, task creation/updates, team coordination, errors/retries/manual interventions, skill-specific outputs.

Work from extract directly -- do not spawn Explore agents.

Note which skill(s) executed -> determines in-scope files. No skill execution AND no workflow improvements: stop. Workflow improvements alone: continue.

## Step 4: Analyze for Improvements

**From transcript** (if loaded), check categories:

1. **Workflow friction** - confusion, skipped steps, manual corrections, systematic tool failures
2. **Wasted tokens** - unnecessary reads, redundant searches, verbose prompts, unused info, compaction overhead. Compaction indicators: PostCompact hook lines, same files re-read after system message. Count events, assess state loss.
3. **Missing guardrails** - errors preventable by a constraint
4. **Task coordination** - stuck tasks, wrong status, blockedBy violations, ownership conflicts
5. **Plan quality** - missing context, unclear descriptions, wrong dependency order
6. **Verification gaps** - build/lint issues catchable earlier
7. **Subagent/teammate issues** - redundant work, missing constraints, wrong ownership
8. **Timing issues** - sequential work that could be parallel, or vice versa
9. **Accumulated bloat / context health** - cross-file duplication, guardrail consolidation (multiple rules = one principle), stale guardrails (one-time issue now resolved), file size growth (measure by `context-health-check.sh` from Phase 1.9 -- blocked files are mandatory compression targets; warned files are candidates). Heuristic: >20 lines prose collapsible to 5-bullet list = bloat. Strategies: prose-to-bullets, extract examples to separate files, deduplicate with shared-guardrails.md, collapse mechanical steps to script references.
10. **Model/effort optimization** - Opus where Sonnet suffices, missing effort spec, Explore agents without `model: "sonnet"`
11. **Catalog drift** - stale targets, count mismatches, source drift, overlap, uncovered files (from Step 2.7)
12. **Context rot** - CLAUDE.md/rules entries referencing functions, files, or patterns that no longer exist in the codebase. Pick 3-5 longest entries from CLAUDE.md and each rules file. For each, Grep the codebase for the specific function/file/pattern named. If the reference target is gone (renamed, deleted, refactored away), the entry is stale -- create a HIGH finding to remove or update it. Also flag entries that describe one-time incident workarounds where the code has since been permanently fixed. Print: `CONTEXT ROT: {N} entries checked, {M} stale`.

**Category gating:** Skip inapplicable based on Step 3 markers. No subagents: skip 7. No plan mode: skip 5. No parallel: skip 8. No catalog findings: skip 11. No project CLAUDE.md or rules: skip 12. Print: `CATEGORIES: {N}/12 applicable`.

**Staleness scan (version check only):** Cross-reference deprecated/renamed features against in-scope skill files.

Ambiguous findings (correct fix depends on user intent): AskUserQuestion before including.

Work from extract. Need more context: Grep raw JSONL for specific line number.

Per transcript issue, note: what happened (cite lines), responsible skill file, fix.

**From workflow improvements:** Each item is pre-classified. Map to responsible file. No transcript evidence needed (source: "workflow-improvements").

Merge and deduplicate both sets.

**Verify against current state.** Grep target file for anchor text (step number, rule name, heading) before finalizing each fix. ~10% token cost of full Read. Drop if already addressed. Adjust fix wording to match actual content. Verify occurrence counts in Fix field via Grep.

**Disconfirmation check.** Per finding: (a) check if a related guardrail intentionally restricts the targeted behavior; (b) Grep `~/.claude/skills/` for current rule text (cross-references, shared-guardrails entries, caller comments). Batch greps: combine patterns as `pattern1|pattern2|pattern3` alternation. Group by target file. Only constraint-modifying findings need guardrail check. Print `DISCONFIRMATION finding-{N}: {reason}` only when counter-evidence found. Conclusive counter-evidence: drop. Partial: downgrade HIGH->MEDIUM, note in Fix. Guardrail relaxation: verify against shared-guardrails.md, escalate via AskUserQuestion if violated.

**Effort assessment:** Score 1 point each: (a) >8 findings, (b) 3+ target files, (c) modifies/relaxes guardrail, (d) structural changes (renumbering, moves, restructuring), (e) cross-file dependency chain. 0: skip. 1-2: think. 3+: ultrathink. Print: `EFFORT: {score}/5 -- {keyword}`.

## Step 4.5: Dependency and Cross-Reference Analysis

Per finding's target file, grep `~/.claude/skills/**/*.md` for basename references. Note cross-ref sites for Fix field. Changed heading/step/path referenced elsewhere -> add note: "Cross-ref: {file} references {element}." Check admin-apex SKILL.md (Skills, Architecture, Runtime Files) and caller comments (`<!-- Called by: -->`) -- highest-density cross-ref sites.

Per HIGH/MEDIUM finding:

**Symmetric pair check:** Finding modifies one side of a structural pair (modes, phases, Path 1/2) -> verify counterpart needs analogous change. Extend Fix or create dependent finding. Print `SYMMETRIC: finding-{N} -> {counterpart}`.

**Cross-file enforcement check:** Finding adds guardrail -> verify enforcement covers all workflow stages (scan, scout, plan, implementation, verification). Print `ENFORCEMENT: finding-{N} checked {stages}` when multiple stages apply.

Skip symmetric/enforcement for single-section findings with no constraint modifications.

## Step 5: Prioritize

- **High**: Bug causing incorrect behavior (wrong output, data loss, stuck state)
- **Medium**: Inefficiency wasting significant tokens or time
- **Low**: Style, minor friction, edge case

Check new guardrails for duplication/consolidation with existing ones. Drop one-off user errors unrelated to workflow design.

## Step 5.3: Drop Summary

Print: `FINDINGS SUMMARY: {total} analyzed, {dropped} dropped ({N} pre-filter, {M} stale, {K} disconfirmed, {L} deprioritized), {remaining} surviving`.

## Step 5.5: Gate Check

No findings remaining: clean up (clear `~/.claude/tmp/apex-workflow-improvements.md` if processed; delete extract variants), report "No improvements identified from {sources}.", stop.

## Step 5.6: Lightweight Mode Gate

<=10 findings AND single target file: skip Steps 6-8, proceed to Implementation Protocol. Print: `LIGHTWEIGHT MODE: {yes|no} -- {N} findings, {M} files`.

## Step 6: Enter Plan Mode

<!-- Design: Plan mode required -- improve findings can be numerous across multiple files. Context clearing ensures clean implementation start. -->

Call EnterPlanMode. Failure: report and stop.

## Step 7: Write Plan

```markdown
# Skill Improve Plan

## Instructions (Execute After Approval)

### Constraints
- Only modify: ~/.claude/skills/, ~/.claude/agents/, .claude/commands/, ~/.claude/CLAUDE.md, ~/.claude/audit-criteria/, .claude/audit-criteria/
- No changes beyond findings. Preserve formatting (ASCII, ## Step N:, Forbidden Actions). AI-optimized per shared-guardrails #12, #15.
- No tests -- these are instruction files

Batch-fetch: `ToolSearch select:TaskCreate,TaskUpdate,TaskList`. Grep `## Implementation Protocol` in this file, Read from there. **Execute ALL phases**: 1 -> 1.5 -> 1.8 -> 1.9 -> 2 -> 2.5 -> 3 -> 3.6 (mandatory apex-git) -> 3.7 -> 4. Stopping before Phase 4 is a violation.

---

Sources: {transcript / workflow-improvements / catalog-health / combination}
Session: {conversationId or "none"}
Skills detected: {list or "n/a"}
Outcome: {success/partial/failure or "n/a"}

## Findings

### {N}. [{HIGH/MEDIUM/LOW}] {title}
- What: {description with transcript evidence}
- File: {path}
- Fix: {concrete change}
- Deps: {numbers or "none"}
- Token impact: {large|medium|small|negligible} -- {rationale} (optional)

## Summary
{count} findings ({h}H / {m}M / {l}L)
```

## Step 8: Exit Plan Mode

Call ExitPlanMode. Wait for approval. Rejected: stop. Retry returns "not in plan mode": plan approved externally, proceed. After approval, context clears -- embedded Instructions execute.

## Implementation Protocol

<!-- Referenced by: Step 7 plan template (post-approval), apex-eod/SKILL.md Step 3 (subagent direct). Not a sequential step -- skip during analysis (Steps 0-5.6). -->

### Phase 1: Setup Tasks
Create tasks for all findings. <=10: one per finding (subject: title, description: file + fix, activeForm: "Applying: {title}"). >10: batch by target file. Mark same-file dependencies.

**Gate:** All tasks created + dependencies set before Phase 2. Verify with TaskList.

Lightweight mode: skip tail task creation. Economy tail default, cleanup + reflection run inline.

Tail tasks (blocked by all implementation tasks):
- "Update admin-apex reference" -- update SKILL.md if changes affect workflow structure
- "Update CLAUDE.md" -- update project CLAUDE.md if changes affect user-facing behavior
- "Clean up improve temp files" -- delete extract, clear workflow-improvements. Always runs.
- "Self-reflection" -- call apex-reflect.md. Blocked by cleanup (cleanup clears consumed improvements before reflection writes new observations).

### Phase 1.5: Pre-flight State Check
`cd ~/.claude && git status --short` (restore CWD per shared-guardrails #16). Uncommitted changes on target files: also run `git diff --stat -- {target-files}` and include the stat in AskUserQuestion "Stash / Continue / Abort?". Stash: `cd ~/.claude && git stash`. `SUBAGENT_MODE=true`: skip ask, print warning, continue.

### Phase 1.8: File Health Gate
`bash ~/.claude/skills/apex/scripts/file-health-check.sh 400 {target files}`. Script outputs violations only (exits 0). `blocked` (>500L): AskUserQuestion for split approach (`SUBAGENT_MODE`: skip, warn). `split-first` (>400L) where finding adds >10 net lines: extract separable section first. Insert split task + update deps if needed.

### Phase 1.9: Context Health Gate
Run `bash ~/.claude/skills/apex/scripts/context-health-check.sh --project-root {project-root}`. Parse output, record each file's current chars and limit.

- **Blocked files** (over limit): findings adding content MUST include equal/greater char removal to offset. Add-only: flag `CONTEXT GATE: finding-{N} adds to blocked file {path} ({chars}c > {limit}c)`, downgrade to LOW, append offset requirement to Fix.
- **Warned files** (approaching limit): estimate net char delta per finding (addition minus removal). If current + net delta would exceed block limit, apply same offset requirement as blocked.
- **All targeted files**: record baseline chars for Phase 2.5 post-check.

Print: `CONTEXT HEALTH: {blocks} blocks, {warnings} warnings, {gated} findings gated`.

### Phase 2: Implementation
**Context clearing reminder:** Re-read every target file before editing -- prior reads cleared after plan approval.

**Pre-implementation stale-state re-check:** `cd ~/.claude && git log --oneline -3 -- {target-files}` (restore CWD). If any commit appeared since Step 2.5 ran, re-verify affected findings have not been resolved. Drop resolved findings before editing.

Print dependency gate per shared-guardrails #8. Same-file = dependent. Exception: `~/.claude/CLAUDE.md` different sections may be independent.

- **Direct** (<10 lines/finding AND <30 total): inline sequential. TaskUpdate in_progress -> Read -> fix -> verify -> TaskUpdate completed. Per shared-guardrails #18, offset/limit for >250L files. Batch Grep + Read in same response when locating needed.
- **Parallel** (3+ files AND (any >10 lines OR >=30 total)): per shared-guardrails #1, all agents in single response. Print `PARALLEL SPAWN: [finding-{N}, ...]`.
  Per subagent (foreground, shared-guardrails #1):
  - subagent_type: "general-purpose", mode: "bypassPermissions"
  - model: "sonnet" for single-section edits; inherit Opus for structural changes
  - Prompt: finding description, current content, conventions (ASCII, `## Step N:`, Forbidden Actions, AI-optimized). Scope: only assigned file. Content: only Fix field changes. Include effort keyword if set.
- **Dependent** (same file): sequential, same flow as direct.

Post-implementation: `cd ~/.claude && git diff --name-only` + `git ls-files --others --exclude-standard`. Verify only expected files changed. Unauthorized: report via AskUserQuestion per shared-guardrails #5 (never auto-revert). If `~/.claude/CLAUDE.md` targeted, diff-verify it matches spec.

### Phase 2.5: Verification
Deduplicate modified files, Read each once. Per shared-guardrails #18, offset/limit for >250L localized changes.

**Structural validity:**
- Caller comment (`<!-- Called by: -->`) accurate
- Step numbering: `## Step N:` no gaps/duplicates
- Forbidden Actions present at bottom (if existed)
- File path references resolve (Glob)
- Content moved between files: Grep all skill files for old location, update cross-refs (admin-apex/SKILL.md, caller comments, lesson flow refs)

**Findings correctness:**
- Each applied correctly, none missed, no regressions, no scope creep (revert excess)
- >10 findings: spot-check via Grep. Minimums: ALL HIGH, >=50% MEDIUM, >=1 LOW per file.

**Context health post-check:** Re-run `bash ~/.claude/skills/apex/scripts/context-health-check.sh --project-root {project-root}`. Compare modified files against Phase 1.9 baselines. If any file crossed from warn to block (or stayed blocked without offsetting removal), the implementation violated the context budget -- compress or revert the excess before proceeding. Print: `CONTEXT POST-CHECK: {pass|fail} -- {details}`.

Fix failures before proceeding.

### Phase 3: Tail Tasks
**Fast-path:** Lightweight mode -> `TAIL MODE: economy`, skip to Phase 3.6.

`cd ~/.claude && git diff --stat` (restore CWD).

<!-- Economy threshold intentionally lower than SKILL.md/apex-tail (3/40 vs 5/80) -- skill prose has higher impact-per-line. Sync check: SKILL.md Step 6A sub-step 1c uses 5/80 -->
**Economy:** <=3 files AND <=40 lines AND no structural changes: `TAIL MODE: economy`, skip both agents, mark tasks completed "economy tail", proceed to Phase 3.6.

**Full:** Above thresholds -> `TAIL MODE: full`. Pre-flights:
- `ADMIN-APEX UPDATE PRE-FLIGHT: {spawn|skip}` -- spawn only if added/removed/renamed files, phases, or Architecture-referenced sections.
- `CLAUDE-MD PRE-FLIGHT: {spawn|skip}` -- spawn only if modified user-facing flags, commands, or documented behavior.

Both skip: mark completed "pre-flight skip", Phase 3.6. Either spawns: per shared-guardrails #1, single response. Print `PARALLEL SPAWN: [admin-apex-update, claude-md-update]`.

**Agent 1 - admin-apex update** (foreground, sonnet, bypassPermissions): Read admin-apex/SKILL.md, update Skills/Architecture/Runtime Files if structural changes. Context budget constraint: run `wc -c` before editing; if file is over 24,000c, offset additions with equal removal. Print "No updates required" if none.

**Agent 2 - CLAUDE.md update** (foreground, sonnet, bypassPermissions): Read ~/.claude/CLAUDE.md and project CLAUDE.md, update APEX sections if structural changes. Check `.claude/commands/` modifications. Context budget constraint: project CLAUDE.md must stay under 40,000c; global under 12,000c -- run `wc -c` before editing, offset if needed. Print "No updates required" if none.

Both: ASCII only, no tables.

### Phase 3.6: Clean Up, Diff Summary, and Auto-Commit

1. Check: `cd ~/.claude && git diff --name-only` + `git ls-files --others --exclude-standard`.
1a. **Concurrency check:** `find ~/.claude/.claude-tmp/apex-active -maxdepth 1 -name 'apex-*.json' -mmin -30 2>/dev/null | wc -l` + check git status for modifications outside finding targets. If detected: `CONCURRENCY_DETECTED=true`, skip step 3 workflow-improvements clear only. Extract cleanup and step 5 auto-commit always run.
2. **Diff summary:** If files changed, generate RUN_ID (`apex-improve-$(date +%Y%m%d)-$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)`), write `~/.claude/.claude-tmp/git-diff/git-diff-{RUN_ID}.md` with subject, files list, abbreviated diff.
3. **Cleanup** (task in_progress): Delete extracts: `find ~/.claude/tmp -maxdepth 1 -name 'apex-improve-extract*.md' -delete 2>/dev/null; true`. Clear workflow-improvements if processed AND not `CONCURRENCY_DETECTED`: `echo -n > ~/.claude/tmp/apex-workflow-improvements.md`. Task completed.
4. No files changed: "No skill files modified, skipping diff summary and auto-commit."
5. **Auto-commit:** Files changed -> invoke `/apex-git` via Skill tool. Mandatory per admin-apex contract. Runs regardless of concurrency.

### Phase 3.7: Self-Reflection

Skip if lightweight mode AND zero analytical friction (no disconfirmation evidence, no stale-state drops, no ambiguous findings). Reflection valuable when friction/complexity present.

Task in_progress -> call `apex-reflect.md` with `mode: execution`, `has_scan_phase: false`, `has_build: false`. Observations feed future improve sessions. Task completed.

### Phase 4: Complete

Print detailed summary:
```
## Improve Summary

**Committed:** {N} files changed, pushed to remote

### Changes Applied
1. [{priority}] {title} -- `{file}`: {1-2 sentence description}
2. ...

Metrics: {findings} findings, {categories}/10 categories, {files} files

APEX Improve completed.
```

No changes (Step 5.5 gate): print "Nothing to improve" only.

## Forbidden Actions

Shared guardrails: read ~/.claude/skills/apex/shared-guardrails.md. Additionally:

- Modify skill files only after user approves plan
- Base findings on transcript or workflow improvements evidence only
- Include user-error findings only when they reveal a missing guardrail
- Read only the specified session transcript
- Preserve ~/.claude/tmp/apex-workflow-improvements.md until plan approval or Step 5.5 gate
- Use EnterPlanMode/ExitPlanMode -- exceptions: `SUBAGENT_MODE=true`, lightweight mode
- Use canonical extraction scripts as-is at runtime
- Implement only after plan approval
- Run Phase 2.5 verification -- structural + correctness in single read pass per file
- Update saved version file (Step 1.5.8) only after all release notes analyzed
- Only new capabilities/behavioral changes are actionable -- skip pure bugfixes
- Run Phase 3.7 self-reflection unless lightweight + zero friction
- Never stop before Phase 4 -- Phase 3.6 apex-git is mandatory when files changed (regardless of concurrency); Phase 3.7 mandatory unless lightweight + zero friction; Phase 4 summary must print
- Quantitative claims need explicit derivation (Grep command + count). Unavailable: use qualitative language ("reduces token usage" not "saves ~2000 tokens")
- Never push a context file past its block threshold (Phase 1.9 limits). Net additions to any file must be offset by equal/greater removal when the result would exceed the limit. Phase 2.5 post-check enforces this -- if violated, compress or revert before proceeding
