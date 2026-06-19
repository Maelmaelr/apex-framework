# apex-lessons (analyze phase): Triage + Clean

Called from `analyze.md` after the Consolidate phase. Returns to `analyze.md` for the Route phase. Extracted to keep the dispatcher within the file-health content budget.

Covers the Triage and Clean tasks in the full-mode TaskCreate chain (freshness check, archival, unverified filter, section/entry cleanup).

## Step 3: Freshness Check

Review ALL remaining lessons (including verified) against the current codebase. Only check lessons with concrete references (file paths, component names, function names). Abstract lessons (patterns, conventions) skip codebase verification.

Freshness is a deterministic ref-existence check ("does this lesson's concrete reference still exist on disk?"), so it runs inline in the main context: batch all Glob/Grep checks for the checkable lessons in a single parallel call. No agent fan-out - a deterministic Glob/Grep sweep gets no AI bolted on (per-category Explore agents add spawn cost for zero benefit, and the inline Glob/Grep result is already authoritative). A lesson is STALE only when its concrete reference no longer exists.

Print each stale finding:
```
STALE: "lesson about FooComponent" - FooComponent no longer exists
```

## Step 3.5: Archive Stale Lessons

After freshness check, evaluate remaining lessons for relevance decay based on `[last-hit]` dates.

**Pre-scan with script.** Run `python3 ~/.claude/skills/apex-lessons/scripts/stale-lessons.py {project-root}/.claude/lessons.md --days 90` to identify stale lessons. The script outputs each stale lesson with line number, section, and last-hit date. Use the output as the archival candidate list - no need to manually parse dates.

**Archival criteria (90-day threshold, applied by script):**
- `[last-hit: YYYY-MM-DD]` with date > 90 days ago: ARCHIVE
- `[verified, last-hit: YYYY-MM-DD]` with date > 90 days ago: ARCHIVE
- `[unverified, last-hit: YYYY-MM-DD]` with date > 90 days ago: ARCHIVE
- `[anti-pattern, last-hit: YYYY-MM-DD]` with date > 90 days ago: ARCHIVE
- `[anti-pattern, unverified, last-hit: YYYY-MM-DD]` with date > 90 days ago: ARCHIVE
- `[]` (empty tag, legacy format): ARCHIVE
- `[verified]` without last-hit: EXEMPT (verified but no tracking yet - will get tracked on next grep hit)
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

**Zero-remaining gate.** If zero lessons remain after Steps 2-3.5 (all were deduplicated, promoted, stale-removed, or archived), skip to Step 7 (write updated file) and Step 8 (regenerate index). In full mode, mark Triage + Filter, Clean, and Route tasks as completed (skipped), then still run the Finalize task (Steps 7-8 live there) and proceed to Reflect + Cleanup (analyze.md Step 10). Print: `EARLY EXIT: 0 lessons remaining after consolidation/triage.`

## Step 3.7: Non-obvious Filter

`.claude/lessons.md` MUST contain only non-obvious lessons. This step drops obvious entries from BOTH the verified-kept set and the unverified-routing-candidate set.

**Definition** (LLM judgment, applied per-lesson):

A lesson is **non-obvious AND tricky** (KEEP) when it captures all three:
1. **Concrete failure / cause**: a specific way something broke or surprised the model, not a vague observation. Examples: "X silently returns null when Y", "API Z requires step W before step V or it 500s".
2. **Concrete fix or guard**: the lesson tells the next reader what to do differently, not just what surprised someone. "Be careful of X" without an actionable counter-move = obvious.
3. **At least one** of:
   - Hidden constraint not implied by language / framework documentation
   - Anti-default behavior that would surprise a careful programmer
   - Framework / tooling quirk specific to a version or config combination
   - Counter-intuitive performance / security implication
   - Anti-pattern category entry (these always pass the criterion-3 bar)

A lesson is **obvious** (DROP) when it:
- Restates a generic best practice (e.g., "always use try/catch around async calls")
- Repeats existing CLAUDE.md or framework-docs content
- States a basic style preference (e.g., "use const over let")
- Explains language semantics covered in language documentation
- Restates a framework's getting-started examples
- Reads like an observation rather than a tricky-cause + fix pair (fails criteria 1 or 2)
- Sounds like something that could have been written without ever hitting a retry / fix-loop on the codebase

**Procedure**:

For each remaining lesson, classify obvious | non-obvious-tricky. Drop the obvious ones; keep the non-obvious-tricky. **When borderline, DROP** - lessons.md is meant to be lean and high-signal; an obvious lesson clutters more than it helps. Inverted from the historical "when in doubt, keep" stance: the lesson volume problem the bar exists to fix is generated by keep-on-doubt.

Print each drop:
```
NON-OBVIOUS DROP: "{snippet}" - {reason: too generic | restates docs | trivial style}
```

Append a one-line summary to `.claude-tmp/lessons-analyze-active/{run}-summary.md`:
```
step-3.7: dropped {N} obvious lessons (kept {M})
```

**Zero-after-filter gate.** If zero lessons remain after Step 3.7, skip to Step 7 (write updated file) and Step 8 (regenerate index); mark Clean and Route tasks as completed (skipped), then still run the Finalize task (Steps 7-8 live there) and proceed to Reflect + Cleanup. Print: `EARLY EXIT: 0 lessons remaining after non-obvious filter.`

## Step 4: Filter for Routing

Extract lessons that do NOT have `[verified]` marker. A verified lesson looks like:
```
- [verified] Lesson text here...
```

`[unverified]` lessons are excluded from routing - they require promotion via a second session hit before they are eligible for integration. Only confirmed (non-`[unverified]`) unverified-by-analyze lessons proceed to Steps 5-6 for the CLAUDE.md / docs / skill-file destinations.

`[verified]` lessons are ALSO extracted into the routing set, but ONLY as candidates for the `.claude/rules/` graduation branch (route.md Step 6) - never for CLAUDE.md / docs / skill files. Verified is the stability signal that QUALIFIES graduation, not a blanket routing exclusion. To keep normal runs incremental, the verified candidates are limited to those touched this run (promoted to `[verified]` this run, or hit during Steps 2-3); the `--sweep` flag (analyze.md "Sweep mode") widens this to the entire verified set for the backlog pass. route.md's rules destination enforces the eligibility bar (path-correlated + frequent + terse); a verified lesson that fails it stays put.

**Per-promotion audit line (mandatory).** Every `[unverified]` -> confirmed promotion (the second-hit tag drop, including the consolidate.md Step 2 unverified+confirmed merge-drop) MUST emit one greppable line, mirroring the consolidate.md `PROMOTED:` convention: `PROMOTED-STATUS: "lesson text snippet" -> confirmed (2nd hit, prior last-hit {YYYY-MM-DD})`. A status promotion with no audit line is a silent promotion - unauditable on the next /apex-improve pass. Zero promotions this run -> emit nothing (no line is the correct signal).

If all lessons are verified or `[unverified]` (after Steps 2-3) AND no `[verified]` lesson qualifies as a rules-graduation candidate (none touched this run, or none path-correlated + terse - and `--sweep` not set), skip Triage and Route but still run Clean (Step 4.5) before proceeding to Step 7. **Symmetric all-new fast-path**: if zero confirmed-unverified routable lessons remain (every entry is either `[verified]` or `[unverified]`-pending-promotion), the same skip applies - Route has nothing to do regardless of whether the input was all-old-verified or all-new-unverified. Otherwise, the qualifying `[verified]` lessons proceed to Steps 5-6 for the rules branch only.

Mark Triage task completed. Also mark Route task completed (skipped - no routable lessons).

## Step 4.5: Clean (consolidate small sections + condense verbose entries)

In a single pass over the lessons, identify and apply both:

1. **Small sections** (<3 entries): Find the most semantically related larger section and merge entries into it. Remove the empty section header.
2. **Verbose entries** (>500 characters): Rewrite to preserve the core lesson in <=400 characters. Strip examples, redundant context, and verbose phrasing. Preserve `[verified]` and `[last-hit: ...]` markers.
3. **Oversized sections** (>80 lines OR >12 entries): Split into sub-topic sections (e.g., "Canvas / Connection Rules", "Canvas / History", "Canvas / Media Inputs"). Sections WITH an identifiable sub-domain axis (a named domain such as Canvas / AdonisJS / Testing, a lifecycle stage, or a surface area) MUST be split inline this run even if cluster boundaries are imperfect - logging without action on a named-domain section is a compliance failure. Log `OVERSIZED: "{section}" ({N} entries / {M} lines) - no axis; manual review required` ONLY when no such axis exists. Re-check split outputs in the same pass: a resulting sub-section still >12 entries OR >80 lines with no further sub-domain axis is itself logged `OVERSIZED` - a split that exhausts the axis but leaves an over-threshold residual is logged, never silently treated as resolved. **Hard split threshold (>100 entries)**: a section above 100 entries MUST be split this run regardless of axis quality - emit at least two sub-topics. Splitting requires updating `lessons-index.md` to route distinctive keywords to the new sub-sections in Step 8.

Print each action:
```
SECTION MERGE: "{small section}" (N entries) -> "{target section}"
CONDENSE: {before_chars} -> {after_chars} chars: "condensed text snippet..."
OVERSIZED SPLIT: "{section}" -> ["{sub1}", "{sub2}"]
```

If no small sections, no verbose entries, and no oversized sections exist, skip this step.

Mark Clean task completed.
