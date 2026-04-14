---
name: apex-lessons-extract
description: "Consolidate pending lessons into master file and regenerate index."
triggers:
  - apex-lessons-extract
---
<!-- Called by: apex-eod/SKILL.md Step 2 (chained), standalone via /apex-lessons-extract -->
<!-- Design: Lightweight linear pipeline. No subagents or scouts needed -- all operations are sequential classification and file writes. Model selection is caller's responsibility (apex-eod uses sonnet). -->

**Output rules:** Suppress intermediate narration. Only print: the project guard message (if triggered), the "No lessons to extract" early exit (if triggered), and the Step 6 summary line. No step announcements, no per-lesson classification reasoning, no index regeneration details.

# apex-lessons-extract - Consolidate Pending Lessons

Processes temporary lessons into the master lessons file. Routes workflow-specific lessons separately. No deduplication -- that's handled by apex-lessons-analyze.

## Step 1: Read Input Files

**Project guard:** If `.claude/lessons.md` does not exist in CWD, print "No project context (no .claude/lessons.md) -- cannot extract" and stop.

**Pre-check lessons.md size** before reading (avoids token-limit errors on large files):
1. Run `wc -l < .claude/lessons.md` via Bash to get line count.
2. If >400 lines, run `grep -n '^## ' .claude/lessons.md` (Bash) to get category headers and line numbers. Read `.claude-tmp/lessons-tmp.md` in parallel with the grep. Category headers are sufficient for classification (Step 2) and insertion routing (Step 3). For Step 3 insertion, use offset/limit to read only the target category section -- do not read the full file.
3. Otherwise, read BOTH files in a SINGLE message (parallel Read tool calls):
   - `.claude-tmp/lessons-tmp.md` -- pending lessons
   - `.claude/lessons.md` -- existing categorized lessons

If lessons-tmp.md does not exist or is empty, print "No lessons to extract" and stop.

## Step 2: Classify

For each new lesson, classify it as **workflow** or **codebase**:

**Workflow lessons** are about APEX workflow behavior itself -- how scouts, plans, teams, verification, audits, delegation, or path routing worked (or failed). They describe friction in the APEX process, not in the project codebase. Note: workflow observations primarily come from apex-reflect (which writes directly to ~/.claude/tmp/apex-workflow-improvements.md). This classification step serves as a safety net for any workflow items that still end up in lessons-tmp.md.

Indicators: mentions scout behavior, plan quality, team coordination, agent file ownership, audit compilation, path misrouting, verification sequencing, task dependency ordering, lesson capture, doc updates, context clearing, token waste in workflow steps.

**Codebase lessons** are everything else -- project patterns, framework gotchas, tooling quirks, conventions discovered.

**Anti-pattern lessons** (entries with `[anti-pattern]` tag in lessons-tmp.md) are always classified as codebase lessons -- they describe failed approaches specific to the project.

## Step 3: Write Lessons

**3a. Codebase lessons** -- Write to .claude/lessons.md. Insert new codebase lessons into the appropriate existing category sections. If a new lesson does not fit any existing category, create a new section (keep total categories between 3-10). Categories should be domain-specific (e.g., "Next.js", "AdonisJS", "Testing", "Pipelines"). Preserve existing lessons and category structure unchanged.

**CRITICAL**: New lessons must be written with `[unverified, last-hit: {today}]` (YYYY-MM-DD format, e.g. today's date) - NOT `[verified]`, NOT bare `[last-hit: ...]`, and NOT empty `[]`. Example:
```
- [unverified, last-hit: 2026-02-28] Windows Next.js cache clearing: When clearing...
```

Only `apex-lessons-analyze` marks lessons as `[verified]` after review. The extract workflow writes unverified lessons with their creation date as the initial last-hit. A second session hitting the same lesson via grep-lessons.sh promotes it to confirmed status (removes `[unverified]` prefix, becoming `[last-hit: YYYY-MM-DD]`).

**Anti-pattern entries** (tagged `[anti-pattern]` in lessons-tmp.md) are written with `[anti-pattern, unverified, last-hit: {today}]`. Place them in a dedicated "Anti-patterns" category section in lessons.md (create the `## Anti-patterns` section if it does not exist).

**Lesson tag formats by source** (three distinct formats -- do not mix):
- Codebase lessons (lessons.md): `- [unverified, last-hit: YYYY-MM-DD] Lesson text...` (new) or `- [last-hit: YYYY-MM-DD] Lesson text...` (confirmed)
- Anti-pattern lessons (lessons.md): `- [anti-pattern, unverified, last-hit: YYYY-MM-DD] Lesson text...` (new) or `- [anti-pattern, last-hit: YYYY-MM-DD] Lesson text...` (confirmed)
- Workflow improvements (apex-workflow-improvements.md): `<!-- YYYY-MM-DD -->\n- Observation text...`
- Teammate lessons (lessons-tmp.md): `<!-- YYYY-MM-DD - teammate:{name} -->\n- Lesson text...`

**3b. Workflow improvements** -- If workflow lessons exist, read ~/.claude/tmp/apex-workflow-improvements.md (create if missing). Before appending, rewrite each workflow lesson to be high-level: abstract away project-specific details (site names, tool names, URLs, selectors, error codes). Describe the pattern or principle, not the instance. Append with date:

```
<!-- {date} -->
- {workflow lesson}
```

If no workflow lessons, skip 3b.

**Parallelization:** 3a and 3b target independent files. If both codebase and workflow lessons exist, issue Edit/Write tool calls for both in a single parallel response. Step 5 depends on 3a completing.

## Step 4: Clear Temp File

Clear the contents of .claude-tmp/lessons-tmp.md (write empty string). Do not delete the file. Runs immediately after Step 3 to prevent duplicate extraction on crash recovery -- once lessons are written to their targets, the temp file is consumed.

## Step 5: Regenerate Index

Read .claude/lessons-index.md with `limit: 1` (Write tool requires a prior read; content is fully regenerated so only 1 line satisfies the contract). Write to .claude/lessons-index.md. Format: one line per category with 6-12 discriminating keywords followed by arrow and category name.

Keyword quality rules:
- Include the most distinctive terms per category (component names, function names, error patterns, framework-specific terms)
- Avoid generic terms that match many categories (e.g., "state", "error", "config" alone)
- When a category has many lessons, pick the 15 most distinctive terms rather than listing every keyword
- Each keyword should help a grep query match the RIGHT category, not just any category

Example: `nextjs, next.js, turbopack, global-error, async-params, dynamic-routes, field-sizing -> Next.js / Turbopack`

## Step 6: Report

Print: "{added} lessons extracted, {workflow} workflow improvement(s) routed. Index regenerated."

## Forbidden Actions

Shared guardrails: read ~/.claude/skills/apex/shared-guardrails.md. Additionally:

- Do not mark lessons as `[verified]` (that is apex-lessons-analyze's job -- extract writes `[unverified, last-hit: {today}]` only)
- Do not reorganize, merge, rewrite, or move existing lessons between categories (reorganization is apex-lessons-analyze's domain)
