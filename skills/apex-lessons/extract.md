# apex-lessons: Extract Phase

Called from `SKILL.md` Step 1. Returns to `SKILL.md` for the analyze phase.

Lightweight linear pipeline. No subagents or parallel dispatch - all operations are sequential reads and file writes. Model selection is the caller's responsibility (apex-improve uses sonnet).

**Output rules:** Suppress intermediate narration. Only print: the project guard message (if triggered), the "No lessons to extract" early exit (if triggered), and the Step 5 summary line. No step announcements, no per-lesson reasoning, no index regeneration details.

Processes temporary lessons into the master lessons file. No deduplication - that is handled by the analyze phase. Self-reflects at end via `agents/reflector.md` so signals feed `/apex-improve`.

Project-scoped run state at `.claude-tmp/lessons-extract-active/` (NOT `~/.claude/.claude-tmp/`; operates on the project's `.claude/lessons.md`). Per-step summary trace at `{run}-summary.md` (read by reflector). Swept by Step 6 (post-success) or SessionEnd hook on hard-stop.

## Determinism / non-determinism mix

Mirrors the analyze phase: deterministic pre-scan + read -> LLM category routing -> deterministic write.

| Phase | Deterministic | Non-deterministic |
|-------|---------------|-------------------|
| Read | `wc -l`, grep headers, file Read | - |
| Write / index | Edit/Write to lessons.md, lessons-index.md, lessons-tmp.md (clear) | category routing, keyword selection |
| Reflect + Cleanup | `append-with-lock.sh`, `cleanup-run.sh` | Sonnet reflector gap / improvement extraction |

## Step 0: Mint run

```
RUN=$(bash $HOME/.claude/skills/apex-lessons/scripts/init-run.sh --phase extract)
```

Echoes 8-hex `RUN` to stdout. Writes manifest at `.claude-tmp/lessons-extract-active/{RUN}.json` (`{run, cc_session_id, pid, producer:"lessons-extract"}`) and touches `{RUN}-summary.md`. Capture `RUN` and use throughout.

After each step below, append one line to `.claude-tmp/lessons-extract-active/{RUN}-summary.md` in the format `step-{N}: <outcome>` (e.g., `step-1: tmp=12 lines master=523 lines mode=headers-only`, `step-2: 8 added / 1 skipped-duplicate`, `step-5: 8 lessons extracted`). Captures friction the linear text steps don't (early-exit reasons, pre-check size jump, write volume); read by Step 6's reflector. The step-1 line's `mode=` token records which read-branch fired (`headers-only` for the >400-line grep-headers path, `full-read` for the <=400 full Read) so the reflector confirms the size-optimisation ran without re-reading lessons.md. **Counts-only contract**: each trace line is one outcome aggregate - never inline lesson titles, lesson bodies, full lesson lists, or narrative parentheticals like `(1 already verified)` into `{RUN}-summary.md`. When any lessons are skipped before write (already present in lessons.md by content hash, malformed, etc.) the step-2 aggregate MUST encode the skip count explicitly as `N skipped-duplicate` rather than parenthetical prose - the friction signal is the count, not its prose explanation. The trace exists for friction signals, not for re-presenting the lesson surface that lessons.md / lessons-tmp.md already hold.

## Step 1: Read Input Files

**Project guard:** If `.claude/lessons.md` does not exist in CWD, append `step-1: early-exit no-project-context` to `{RUN}-summary.md`, print "No project context (no .claude/lessons.md) - cannot extract", then jump to Step 6 (Reflect + Cleanup ALWAYS runs - the early-exit reason IS the gap signal worth reflecting on).

**Resolve `lessons-tmp.md` path.** `agents/learn.md` writes the file to the MAIN worktree (so worktree-cleanup does not destroy it). Read/clear from the same anchor so apex-lessons works whether invoked from main or from a linked apex worktree:

```
MAIN=$(git rev-parse --git-common-dir 2>/dev/null | sed 's,/\.git$,,')
[[ -z "$MAIN" || "$MAIN" == ".git" ]] && MAIN=$(pwd)
LESSONS_TMP="$MAIN/.claude-tmp/lessons-tmp.md"
```

Use `$LESSONS_TMP` for the read in this step and the clear in Step 3.

**Pre-check lessons.md size** before reading (avoids token-limit errors on large files):
1. Run `wc -l < .claude/lessons.md` via Bash to get line count.
2. If >400 lines, run `grep -n '^## ' .claude/lessons.md` (Bash) to get category headers and line numbers. Read `$LESSONS_TMP` in parallel with the grep. Category headers are sufficient for insertion routing (Step 2). For Step 2 insertion, use offset/limit to read only the target category section - do not read the full file.
3. Otherwise, read BOTH files in a SINGLE message (parallel Read tool calls):
   - `$LESSONS_TMP` - pending lessons (MAIN-anchored)
   - `.claude/lessons.md` - existing categorized lessons

If `$LESSONS_TMP` does not exist or is empty, append `step-1: early-exit no-lessons` to `{RUN}-summary.md`, print "No lessons to extract", then jump to Step 6.

## Step 2: Write Lessons

Write each new lesson to `.claude/lessons.md`. Insert it into the appropriate existing category section. If a new lesson does not fit any existing category, create a new section (keep total categories between 3-10). Categories should be domain-specific (e.g., "Next.js", "AdonisJS", "Testing", "Pipelines"). Preserve existing lessons and category structure unchanged.

**Rules anti-duplicate pre-gate (cheap, narrow).** Before writing a pending lesson, grep its distinctive nouns against `.claude/rules/**` (best-effort; skip when the dir is absent). When the lesson's actionable advice already exists as a graduated rule there, DROP it instead of writing - writing it only forces the next analyze phase to detect + remove it (a promote-remove round-trip). This is NOT lesson-deduplication (that stays the analyze phase's job per the "No deduplication" note above); it is a one-way drop of content that already lives in `.claude/rules/`.

**CRITICAL**: New lessons must be written with `[unverified, last-hit: {today}]` (YYYY-MM-DD format, e.g. today's date) - NOT `[verified]`, NOT bare `[last-hit: ...]`, and NOT empty `[]`. Example:
```
- [unverified, last-hit: 2026-02-28] Windows Next.js cache clearing: When clearing...
```

Only the analyze phase marks lessons as `[verified]` after review. The extract phase writes unverified lessons with their creation date as the initial last-hit. A second session hitting the same lesson via grep-lessons.sh promotes it to confirmed status (removes `[unverified]` prefix, becoming `[last-hit: YYYY-MM-DD]`).

**Anti-pattern entries** (tagged `[anti-pattern]` in lessons-tmp.md) are written with `[anti-pattern, unverified, last-hit: {today}]`. Place them in a dedicated "Anti-patterns" category section in lessons.md (create the `## Anti-patterns` section if it does not exist).

**Lesson tag formats** (two distinct formats - do not mix):
- Codebase lessons (lessons.md): `- [unverified, last-hit: YYYY-MM-DD] Lesson text...` (new) or `- [last-hit: YYYY-MM-DD] Lesson text...` (confirmed)
- Anti-pattern lessons (lessons.md): `- [anti-pattern, unverified, last-hit: YYYY-MM-DD] Lesson text...` (new) or `- [anti-pattern, last-hit: YYYY-MM-DD] Lesson text...` (confirmed)

## Step 3: Clear Temp File

Clear the contents of `$LESSONS_TMP` (the MAIN-anchored path resolved in Step 1) by writing an empty string. Do not delete the file. Runs immediately after Step 2 to prevent duplicate extraction on crash recovery - once lessons are written to their targets, the temp file is consumed. Append `step-3: tmp-cleared` to `{RUN}-summary.md` so the reflector can confirm the clear ran.

## Step 4: Regenerate Index

Read .claude/lessons-index.md with `limit: 1` (Write tool requires a prior read; content is fully regenerated so only 1 line satisfies the contract). Write to .claude/lessons-index.md. Format: one line per category with 6-12 discriminating keywords followed by arrow and category name. Append `step-4: index-regenerated` to `{RUN}-summary.md` so the reflector can confirm the regen ran.

Keyword quality rules:
- Include the most distinctive terms per category (component names, function names, error patterns, framework-specific terms)
- Avoid generic terms that match many categories (e.g., "state", "error", "config" alone)
- When a category has many lessons, pick the 15 most distinctive terms rather than listing every keyword
- Each keyword should help a grep query match the RIGHT category, not just any category

Example: `nextjs, next.js, turbopack, global-error, async-params, dynamic-routes, field-sizing -> Next.js / Turbopack`

## Step 5: Report

Print: "{added} lessons extracted. Index regenerated."

## Step 6: Reflect + Cleanup

ALWAYS runs - including on Step 1 early-exits. Closes the self-improvement loop by feeding Sonnet-reflector signals into `~/.claude/tmp/apex-workflow-improvements.md` (consumed by `/apex-improve`'s next run).

Spawn `agents/reflector.md` (Sonnet, foreground) with the `lessons-extract` phase. The agent reads its own contract (`agents/reflector.md` invocation-table row `lessons-extract`); this skill supplies only the run-specific context.

Spawn-prompt template (substitute `{RUN}`):

```
You are agents/reflector.md. Read it at $HOME/.claude/agents/reflector.md and
follow the `lessons-extract` row of the invocation table. No reflect-traces.sh
heuristic block exists for this phase; inputs are this run's per-step summary
trace at .claude-tmp/lessons-extract-active/{RUN}-summary.md.

Token:    {RUN}              # 8-hex; used in place of {session}
Phase:    lessons-extract
Manifest: .claude-tmp/lessons-extract-active/{RUN}.json   # CWD-relative; CWD is the project root.

Errors -> ~/.claude/tmp/reflector-errors.log (silent failure otherwise).
Shut down silently (no main-session output).
```

After reflector returns:

```
bash $HOME/.claude/skills/apex-lessons/scripts/cleanup-run.sh --phase extract --run {RUN} --post-success
```

The `--post-success` flag bypasses the 60s in-flight mtime guard (the just-written `{RUN}-summary.md` keeps the guard armed otherwise). Reflector failure does NOT block cleanup - the agent self-silences per its contract; signal loss for one run is acceptable, leaking artifacts into the next session is not.

## Forbidden Actions

Standard apex safety guardrails apply (hook + global-`CLAUDE.md` enforced - no stash, no env-file edits, destructive-op gating, tool-output integrity). Additionally:

- Do not mark lessons as `[verified]` (that is the analyze phase's job - extract writes `[unverified, last-hit: {today}]` only)
- Do not reorganize, merge, rewrite, or move existing lessons between categories (reorganization is the analyze phase's domain)
- Do not skip Step 6 - early-exit reasons (no project context, no lessons to extract) are gap signals worth reflecting on
- Do not leave temp files on success - `cleanup-run.sh --phase extract --run {run} --post-success` removes `.claude-tmp/lessons-extract-active/{run}-*` (the `--run` flag is required; cleanup-run.sh exits 0 without cleaning if it is absent)
