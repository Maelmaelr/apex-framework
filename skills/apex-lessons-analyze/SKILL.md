---
name: apex-lessons-analyze
description: "Deduplicate, freshness-check, merge, and route lessons to their best permanent home."
triggers:
  - apex-lessons-analyze
---

<!-- Called by: apex-eod/SKILL.md Step 4 (chained), standalone via /apex-lessons-analyze -->

# apex-lessons-analyze - Consolidate, Triage, and Route Lessons

Consolidates lessons.md (deduplication, freshness, merging) then routes lessons to their best permanent home.

## Task Setup

**After Step 1**, determine pipeline mode:

**Simplified mode** (total lessons < 10 AND unverified < 5): Skip TaskCreate chain. Execute all steps inline without task tracking or freshness-check agents. Use direct Grep/Glob for freshness checks instead of dispatching Explore agents.

**Full mode** (all other cases): Create 5 tasks with sequential blockedBy chain:

1. **Consolidate** (Steps 1-2.5): Read files, deduplicate, merge, detect promoted entries
2. **Triage** (Steps 3-4): Freshness check, archive stale lessons, filter unverified -- blockedBy: Consolidate
3. **Clean** (Step 4.5): Consolidate small sections + condense verbose entries -- blockedBy: Triage
4. **Route** (Steps 5-6): Read targets, analyze and route -- blockedBy: Clean (may be immediately completed if Step 4 finds all lessons verified)
5. **Finalize** (Steps 6.5-9): Verify routing, write files, regenerate index, report -- blockedBy: Route

Mark each task in_progress when entering its phase, completed when exiting.

## Step 1: Read Lessons and Index

**Pre-check lessons.md size** before reading (avoids token-limit errors on large files):
1. Run `wc -l < .claude/lessons.md 2>/dev/null || echo 0` via Bash to get line count.
2. If file missing (count = 0 and file does not exist), print "No lessons to analyze" and stop.
3. Per shared-guardrails #18, but threshold 400 for this file: if >400 lines, read with offset/limit (300 lines/chunk) alongside `.claude/lessons-index.md` in parallel.
4. Otherwise, read both files in a SINGLE message (parallel Read tool calls):
   - `.claude/lessons.md` - master lessons file
   - `.claude/lessons-index.md` - category-keyword mappings (used in Steps 3 and 5; format: `keyword1, keyword2 -> Category Name`)
5. If lessons.md content is empty after reading, print "No lessons to analyze" and stop.

**Pipeline mode gate.** Count total and unverified lessons. If total < 10 AND unverified < 5: print `ANALYZE MODE: simplified ({total} lessons, {unverified} unverified)`, skip TaskCreate. Otherwise: print `ANALYZE MODE: full ({total} lessons, {unverified} unverified)`, create the 5-task chain from Task Setup.

## Step 2: Deduplicate and Merge

**Pre-scan with script.** Run `python3 ~/.claude/skills/apex/scripts/lesson-dedup.py {project-root}/.claude/lessons.md --threshold 0.6` to identify candidate duplicate pairs. The script outputs pairs sorted by similarity score. Use the candidates as a starting point -- review each pair and decide: merge, dedup, or keep both (false positive).

Review ALL lessons (including verified) for:
- **Exact/near duplicates**: keep the more precise one, delete the other
- **Mergeable lessons**: same narrow topic, combine into one entry preserving all distinct info. Merged result keeps `[verified]` if any source had it, and the later `[last-hit]` date.
- **Unverified + confirmed merge**: When merging an `[unverified]` lesson with a confirmed (non-unverified) lesson, the merged result drops `[unverified]` -- the confirmed lesson's status wins.
- **Anti-pattern + regular merge**: Anti-patterns can be merged with regular lessons if they describe the inverse of the same pattern. The merged result should note both the correct approach and the failed approach.

Print each action:
```
MERGE: "lesson A" + "lesson B" -> "merged lesson"
DEDUP: Removed "duplicate lesson" (kept "original lesson")
```

## Step 2.5: Detect Promoted Entries

Read project CLAUDE.md, global `~/.claude/CLAUDE.md`, and relevant docs (use index categories to pick targets). For each lesson (including verified), check if its actionable advice already exists in a target (not just topical overlap).

Mark and remove promoted lessons:
```
PROMOTED: "lesson text snippet" -> already in {target file}:{section}
```

Keep target file contents in context for reuse in Step 5 (avoid re-reading the same files).

Mark Consolidate task completed.

## Step 3: Freshness Check

Review ALL remaining lessons (including verified) against the current codebase. Only check lessons with concrete references (file paths, component names, function names). Abstract lessons (patterns, conventions) skip codebase verification.

<!-- Design: Sonnet for freshness scouts -- read-only exploration (Glob/Grep only, no file modifications). -->

**Inline check** (simplified mode OR full mode with <10 checkable lessons): Batch all Glob/Grep checks in a single parallel call. No agents needed.

**Agent dispatch** (full mode, 10+ checkable lessons): Group by index categories. Per shared-guardrails #1, dispatch all parallel Explore agents in a single response. Print `PARALLEL SPAWN: [freshness-{category1}, freshness-{category2}, ...]` before launching. Per agent: subagent_type "Explore", model "sonnet", description "Check {category} lesson freshness", prompt with "ASCII only. No tables, no diagrams." constraint and ONLY that category's lessons and instructions to Glob/Grep each reference. Return: stale lessons with reason, confirmed lessons.

Print each stale finding:
```
STALE: "lesson about FooComponent" - FooComponent no longer exists
```

**Post-check verification.** Verify each STALE finding: Grep/Glob the specific reference in the main context to confirm it is truly gone. Only accept confirmed stale findings. Drop unconfirmed:
```
STALE DROPPED: "lesson" - reference still exists (agent false negative)
```

## Step 3.5: Archive Stale Lessons

After freshness check, evaluate remaining lessons for relevance decay based on `[last-hit]` dates.

**Pre-scan with script.** Run `python3 ~/.claude/skills/apex/scripts/stale-lessons.py {project-root}/.claude/lessons.md --days 90` to identify stale lessons. The script outputs each stale lesson with line number, section, and last-hit date. Use the output as the archival candidate list -- no need to manually parse dates.

**Archival criteria (90-day threshold, applied by script):**
- `[last-hit: YYYY-MM-DD]` with date > 90 days ago: ARCHIVE
- `[verified, last-hit: YYYY-MM-DD]` with date > 90 days ago: ARCHIVE
- `[unverified, last-hit: YYYY-MM-DD]` with date > 90 days ago: ARCHIVE
- `[anti-pattern, last-hit: YYYY-MM-DD]` with date > 90 days ago: ARCHIVE
- `[anti-pattern, unverified, last-hit: YYYY-MM-DD]` with date > 90 days ago: ARCHIVE
- `[]` (empty tag, legacy format): ARCHIVE (never hit since tracking was added)
- `[verified]` without last-hit: EXEMPT (verified but no tracking yet -- will get tracked on next grep hit)
- `[last-hit: YYYY-MM-DD]` with date <= 90 days: KEEP
- `[verified, last-hit: YYYY-MM-DD]` with date <= 90 days: KEEP
- `[unverified, last-hit: YYYY-MM-DD]` with date <= 90 days: KEEP
- `[anti-pattern, last-hit: YYYY-MM-DD]` with date <= 90 days: KEEP
- `[anti-pattern, unverified, last-hit: YYYY-MM-DD]` with date <= 90 days: KEEP

**Archive process:**
1. Use stale-lessons.py output as the candidate list
2. Read .claude/lessons-archive.md (create if missing)
3. Move archived lessons to .claude/lessons-archive.md, preserving their text and last-hit date
4. Remove archived lessons from .claude/lessons.md

Print each archival:
```
ARCHIVE: "lesson text snippet" (last-hit: YYYY-MM-DD / never)
```

**Retrieval (optional, if .claude/lessons-archive.md exists and <20 entries):** Grep archived lesson references (file paths, function names) against the codebase. If a reference reappears (file/function restored or recreated), unarchive: move back to lessons.md with `[last-hit: {today}]`. Print `UNARCHIVE: "{snippet}"`. Skip if archive does not exist or has 20+ entries (cost cap).

If no lessons meet archival criteria and no unarchival candidates found, skip this step.

**Zero-remaining gate.** If zero lessons remain after Steps 2-3.5 (all were deduplicated, promoted, stale-removed, or archived), skip to Step 7 (write updated file) and Step 8 (regenerate index). In full mode, mark Triage, Clean, Route, and Finalize tasks as completed (skipped). Print: `EARLY EXIT: 0 lessons remaining after consolidation/triage.`

## Step 4: Filter Unverified for Routing

Extract lessons that do NOT have `[verified]` marker. A verified lesson looks like:
```
- [verified] Lesson text here...
```

`[unverified]` lessons are excluded from routing -- they require promotion via a second session hit before they are eligible for integration. Only confirmed (non-`[unverified]`) unverified-by-analyze lessons proceed to Steps 5-6.

If all lessons are verified or `[unverified]` (after Steps 2-3), skip Triage and Route but still run Clean (Step 4.5) before proceeding to Step 7.

Mark Triage task completed. Also mark Route task completed (skipped -- no routable lessons).

## Step 4.5: Clean (consolidate small sections + condense verbose entries)

In a single pass over the lessons, identify and apply both:

1. **Small sections** (<3 entries): Find the most semantically related larger section and merge entries into it. Remove the empty section header.
2. **Verbose entries** (>500 characters): Rewrite to preserve the core lesson in <=400 characters. Strip examples, redundant context, and verbose phrasing. Preserve `[verified]` and `[last-hit: ...]` markers.

Print each action:
```
SECTION MERGE: "{small section}" (N entries) -> "{target section}"
CONDENSE: {before_chars} -> {after_chars} chars: "condensed text snippet..."
```

If no small sections and no verbose entries exist, skip this step.

Mark Clean task completed.

## Step 5: Read Integration Targets

Skip re-reading files already loaded in Step 2.5. Only read new targets not covered there.

**Always read (if not already in context from Step 2.5):** Project CLAUDE.md (current directory).

**Conditionally read based on unverified lesson categories** (use index mappings to determine relevance):
- `~/.claude/CLAUDE.md` (global rules) - if lessons relate to cross-project patterns, tool usage, or universal conventions
- `~/.claude/skills/apex/SKILL.md` (apex workflow) - if lessons relate to workflow, delegation, or APEX behavior
- `docs/*` specific file - use index categories to pick the right docs file from the CLAUDE.md Doc Quick Reference instead of blanket project-context.md reads (e.g., canvas lessons -> `docs/features/canvas/index.md`, auth lessons -> `docs/auth-flow.md`)

Read all new targets in parallel.

## Step 6: Analyze and Route Each Unverified Lesson

For each unverified lesson, determine the best destination:

**Project CLAUDE.md**: Project-specific convention, security rule, or pattern that applies broadly to this codebase.

**Global CLAUDE.md**: Tool usage pattern, cross-project habit, or universal best practice.

**apex/SKILL.md**: Workflow step improvement, flag behavior, or phase guidance.

**docs/**: Feature behavior, architecture decision, or API documentation.

**Verified (keep)**: Runtime lookup value - specific gotcha, edge case, or implementation detail that helps during coding but doesn't warrant permanent documentation.

**Delete**: Outdated, superseded by another lesson, or too obvious to keep.

**Anti-pattern routing**: Verified `[anti-pattern]` lessons can be routed to CLAUDE.md or docs as warnings/gotchas. Routing format: "Warning: {approach} fails because {reason}." Anti-patterns are especially valuable in docs sections where a developer might otherwise attempt the failed approach.

Execute each routing action:
- **Project/Global CLAUDE.md**: Append to appropriate section. Keep concise.
- **apex/SKILL.md or subfiles**: Edit the relevant workflow file.
- **docs/**: Identify the most relevant doc file and append or suggest the edit.
- **Verified (keep)**: Update tag to `[verified, last-hit: YYYY-MM-DD]` (preserving the existing last-hit date) in lessons.md.
- **Delete**: Remove the lesson from lessons.md.

**Subagent mode**: Route global/skill file targets to "Verified (keep)" instead of editing directly. Print `ROUTE DEFERRED: "{snippet}" -> {target}`. Append deferred items to `.claude-tmp/lessons-deferred-routing.md` (create if needed). Print: `Note: N lessons deferred -- run standalone /apex-lessons-analyze to route.` Direct target edits only in standalone mode.

Mark Route task completed.

## Step 6.5: Verify Routing

Re-read ALL modified target sections in parallel (one Read per file, single message). Confirm no truncation, duplication, or surrounding content damage. Fix any issues before proceeding to Step 7.

## Step 7: Update Lessons File

Write the updated .claude/lessons.md with:
- Merged/deduplicated lessons from Step 2
- Stale lessons from Step 3 removed
- Verified lessons marked with `[verified]` prefix
- Routed lessons removed (they now live elsewhere)
- Deleted lessons removed
- Order and categories preserved

## Step 8: Update Index

If any lessons were changed (merged, deleted, integrated, or marked verified), review and update .claude/lessons-index.md if categories or keywords changed. If merges/deletions did not change the category structure, verify the index is still accurate and skip rewriting. Format: one line per category with 6-12 discriminating keywords followed by arrow and category name.

Keyword quality rules:
- Include the most distinctive terms per category (component names, function names, error patterns, framework-specific terms)
- Avoid generic terms that match many categories (e.g., "state", "error", "config" alone)
- When a category has many lessons, pick the 15 most distinctive terms rather than listing every keyword
- Each keyword should help a grep query match the RIGHT category, not just any category

Example:
```
nextjs, next.js, turbopack, global-error, async-params, dynamic-routes -> Next.js
adonisjs, adonis, japa, vine -> AdonisJS
```

## Step 9: Report

Print summary:
```
Lessons consolidated: {total reviewed}
- Merged: {count} (from {original count} entries)
- Stale/removed: {count}
- Integrated to docs/config: {count}
- Marked verified: {count}
- Deleted (other): {count}
- Remaining: {count}
```

Mark Finalize task completed.

## Forbidden Actions

Shared guardrails: read ~/.claude/skills/apex/shared-guardrails.md. Additionally:

- Do not delete lessons without freshness evidence (stale codebase reference) or deduplication justification (exact/near duplicate of another lesson)
- Do not route verified lessons through Steps 5-6 (only unverified lessons go through routing)
- Do not skip the blockedBy task chain in full mode -- all 5 tasks (Consolidate, Triage, Clean, Route, Finalize) must reach completed status. Simplified mode skips task tracking entirely.
- Do not accept scout stale findings without main-context verification (Step 3 post-scout check)
