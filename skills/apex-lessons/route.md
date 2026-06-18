# apex-lessons (analyze phase): Route + Finalize

Called from `analyze.md` after the Triage + Clean phase. Returns to `analyze.md` for the final report. Extracted to keep the dispatcher under the 175-line cap.

Covers the Route and Finalize tasks in the full-mode TaskCreate chain (route to permanent homes, verify, write, index, report).

## Step 5: Read Integration Targets

Skip re-reading files already loaded in Step 2.5. Only read new targets not covered there.

**Always read (if not already in context from Step 2.5):** Project CLAUDE.md (current directory).

**Conditionally read based on unverified lesson categories** (use index mappings to determine relevance):
- `~/.claude/CLAUDE.md` (global rules) - if lessons relate to cross-project patterns, tool usage, or universal conventions
- `~/.claude/skills/apex/SKILL.md` (apex workflow) - if lessons relate to workflow, delegation, or APEX behavior
- `docs/*` specific file - use index categories to pick the right docs file from the CLAUDE.md Doc Quick Reference instead of blanket project-context.md reads (e.g., canvas lessons -> `docs/features/canvas/index.md`, auth lessons -> `docs/auth-flow.md`)

Read all new targets in parallel. Append `step-5: read N new (K already in context from step 2.5)` to `{run}-summary.md` even when N=0 - zero-read is signal too. The N=0 line is only for the case where Route RAN (every target already in context from Step 2.5); when the triage.md Step 4 route-gate skipped Route (all-verified / zero-routable / all-new-unverified), Steps 5-6 are bypassed entirely and emit NO step-5 line.

## Step 6: Analyze and Route Each Routable Lesson

The 4-store taxonomy (where a confirmed lesson lives long-term):
- **lessons.md** - rare, narrow, or not-yet-stable runtime lookups; pulled by grep when a matching task surfaces.
- **`.claude/rules/*`** - `[verified]`, path-scoped, terse gotchas; auto-pushed into context on every touch of the matching path.
- **docs/** - reference material and contracts; pulled on demand via a CLAUDE.md pointer.
- **CLAUDE.md** (project + global) - always-on broad rules plus the doc/index pointers.

For each routable lesson, determine the best destination:

**Project CLAUDE.md**: Project-specific convention, security rule, or pattern that applies broadly to this codebase, expressible as ONE concise rule or a one-line pointer. Structural contract (a lean project CLAUDE.md is layered, not a catch-all - mirror a hand-curated exemplar): a narrow/runtime gotcha, edge case, or single-file quirk is NOT a CLAUDE.md route - keep it in `lessons.md` (Verified) instead; a cross-project/tool/universal pattern goes to Global, never duplicated into project CLAUDE.md; deep feature/architecture/implementation detail goes to `docs/` with at most a one-line pointer added under the existing doc-reference section. Only route here when the rule is broad, durable, and cannot be expressed as a pointer elsewhere.

**Global CLAUDE.md**: Tool usage pattern, cross-project habit, or universal best practice.

**apex/SKILL.md**: Workflow step improvement, flag behavior, or phase guidance.

**docs/**: Feature behavior, architecture decision, or API documentation.

**`.claude/rules/` (path-scoped auto-push)**: The one destination that ACCEPTS `[verified]` lessons - this is graduation, not a runtime lookup. Eligible when the lesson is `[verified]` AND path-correlated (its subject is a concrete file/dir) AND high-frequency (needed on a large fraction of touches to that path) AND terse (<=3 lines). Match: read each rule's YAML `paths:` frontmatter under `.claude/rules/`; if a glob covers the lesson's subject path, that rule is the target. Action: append the one-liner as a `-` bullet under a fitting heading in the rule, then remove the entry from lessons.md via the Step 6 Delete guard below (no separator-collapse). No glob match -> do NOT auto-create a rule (a new rule is a structural decision): emit a deferred line `NEEDS-RULE: "{snippet}" -> proposed glob {...}` for human/admin-apex review and keep the lesson in lessons.md. **Per-rule leanness budget** (mirrors the CLAUDE.md budget below; rules auto-load per path-match and can stack, so each must stay lean): before appending, `wc -c` the target rule; soft ceiling ~12k chars. If the append would cross it, route to the most relevant `docs/` file instead - never grow a rule into a second 98k-char canvas-patterns.md.

**Verified (keep)**: Runtime lookup value - a `[verified]` gotcha that is narrow, rare, or not path-correlated enough to graduate to `.claude/rules/`, and not reference-grade enough for `docs/`. Stays in lessons.md as a grep-pulled lookup. `[verified]` is a graduation signal, not a terminal state: verified + path-correlated + frequent + terse graduates to rules; verified + reference-grade routes to docs.

**Delete**: Outdated, superseded by another lesson, or too obvious to keep.

**Anti-pattern routing**: Verified `[anti-pattern]` lessons can be routed to CLAUDE.md or docs as warnings/gotchas. Routing format: "Warning: {approach} fails because {reason}." Anti-patterns are especially valuable in docs sections where a developer might otherwise attempt the failed approach.

**CLAUDE.md leanness budget (gates every Project CLAUDE.md route)**: project CLAUDE.md loads on every turn; Claude Code degrades past a ~40k-char hard cliff. Before routing anything to it, `wc -c CLAUDE.md`. Soft ceiling = 30k chars. If the file is already >= 30k OR the append would cross it, do NOT append - route the lesson to the most relevant `docs/` file instead (CLAUDE.md keeps only a one-line pointer). If already over the soft ceiling, also evict: move the bulkiest stale/superseded section bodies into `docs/` and leave a pointer line, until back under 30k. Leanness over completeness - CLAUDE.md holds broadly-applicable rules and pointers, never accumulated detail.

Execute each routing action:
- **Project/Global CLAUDE.md**: Append under an EXISTING section whose domain matches the lesson; never invent a new top-level section in project CLAUDE.md - the curated section taxonomy IS the structure, preserve it (if nothing fits, prefer a `docs/` pointer or `lessons.md` over a new heading). One concise rule or pointer line, never narrative or accumulated implementation detail. Project CLAUDE.md appends are also subject to the leanness budget above (evict-to-docs on breach); global `~/.claude/CLAUDE.md` is user-curated - never auto-evict it.
- **apex/SKILL.md or subfiles**: Edit the relevant workflow file.
- **docs/**: Identify the most relevant doc file and append or suggest the edit.
- **`.claude/rules/`**: Append the one-liner as a `-` bullet under the best-matching heading in the rule chosen by `paths:` glob match. Apply the per-rule leanness budget first; on breach route to `docs/` instead. Then remove the lesson from lessons.md using the Delete guard below. No matching rule -> emit `NEEDS-RULE:` and keep the lesson.
- **Verified (keep)**: Update tag to `[verified, last-hit: YYYY-MM-DD]` (preserving the existing last-hit date) in lessons.md.
- **Delete**: Remove the lesson from lessons.md. Delete the whole entry line including its trailing newline in the Edit `old_string`; never empty-replace text in place or across a section-separator boundary - that collapses adjacent separators (recurring step-6.5 corruption, fixed inline 3x/run when not guarded here).

**Subagent mode**: Route global/skill file and `.claude/rules/` targets to "Verified (keep)" instead of editing directly. Print `ROUTE DEFERRED: "{snippet}" -> {target}`. Append deferred items to `.claude-tmp/lessons-deferred-routing.md` (create if needed). Print: `Note: N lessons deferred - run standalone /apex-lessons to route.` Direct target edits only in standalone mode.

Mark Route task completed.

## Step 6.5: Verify Routing

Re-read ALL modified target sections in parallel (one Read per file, single message). Confirm no truncation, duplication, or surrounding content damage - the recurring failure is separator-collapse from a Step 6 Delete empty-replace; apply the Step 6 Delete guard rather than re-deriving the fix each run. Fix any remaining issues before proceeding to Step 7. Append `step-6.5: verified N targets (corruption=K)` to `{run}-summary.md` even when N=0 - no-corruption is signal too.

## Step 7: Update Lessons File

Write the updated .claude/lessons.md with:
- Merged/deduplicated lessons from Step 2
- Stale lessons from Step 3 removed
- Verified lessons marked with the `[verified, last-hit: YYYY-MM-DD]` tag (per Step 6)
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

Also append `step-9: merged=M stale=S integrated=I verified=V deleted=D remaining=R` to `{run}-summary.md` as a counts-only aggregate. The stdout block is for the user; the trace line is for the next reflector.

Mark Finalize task completed.
