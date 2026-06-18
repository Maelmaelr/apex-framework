# apex-lessons (analyze phase): Consolidate

Called from `analyze.md` after Task Setup Step 0a (run mint). Performs the Step 0b pipeline mode gate itself in Step 1 (counting total/unverified lessons requires reading `.claude/lessons.md`, which only this phase does). Returns to `analyze.md` for the Triage phase. Extracted to keep the dispatcher under the 175-line cap.

This phase is the Consolidate task in the full-mode TaskCreate chain (read, deduplicate, merge, detect promoted entries).

## Step 1: Read Lessons and Index

**Pre-check lessons.md size** before reading (avoids token-limit errors on large files):
1. Run `wc -l < .claude/lessons.md 2>/dev/null || echo 0` via Bash to get line count.
2. If file missing (count = 0 and file does not exist), print "No lessons to analyze" and proceed to Reflect + Cleanup (analyze.md Step 10) - early exits never skip reflection.
3. Targeted-read gate (threshold 400 for this file vs the global 250-line default): if >400 lines, read with offset/limit (300 lines/chunk) alongside `.claude/lessons-index.md` in parallel.
4. Otherwise, read both lessons files in a SINGLE message (parallel Read tool calls):
   - `.claude/lessons.md` - master lessons file
   - `.claude/lessons-index.md` - category-keyword mappings (used in Steps 3 and 5; format: `keyword1, keyword2 -> Category Name`)

   The promoted-content targets (`<project-root>/CLAUDE.md`, `~/.claude/CLAUDE.md`) are NOT read here - they load once at Step 2.5, gated on survivors, so an empty / fully-deduped corpus never pays the CLAUDE.md read. Both corpus-size paths now defer identically (the >400-line chunked path above also skips them), removing the prior small-vs-large preload asymmetry.
5. If lessons.md content is empty after reading, print "No lessons to analyze" and proceed to Reflect + Cleanup (analyze.md Step 10) - early exits never skip reflection.

**Pipeline mode gate.** Count total and unverified lessons. If total < 10 AND unverified < 5: print `ANALYZE MODE: simplified ({total} lessons, {unverified} unverified)`, skip TaskCreate. Otherwise: print `ANALYZE MODE: full ({total} lessons, {unverified} unverified)`, create the 5-task chain from Task Setup.

## Step 2: Deduplicate and Merge

**Pre-scan with script.** Run `python3 ~/.claude/skills/apex-lessons/scripts/lesson-dedup.py {project-root}/.claude/lessons.md --threshold 0.6` to identify candidate duplicate pairs. The script outputs pairs sorted by similarity score. Use the candidates as a starting point - review each pair and decide: merge, dedup, or keep both (false positive). **Do NOT re-run the script at a lower threshold (e.g. `--threshold 0.5`) when the 0.6 pass returned 0 pairs** - same corpus, a lower threshold only surfaces false positives the review then discards; a 0-pair 0.6 result means nothing to merge, proceed to Step 2.5.

Reuse the Step 1 in-context read of lessons.md here; do not re-read the file (the snapshot is already loaded - re-reading 200+ entries wastes tokens when the merge candidates are already flagged by the dedup pre-scan). Review ALL lessons (including verified) for:
- **Exact/near duplicates**: keep the more precise one, delete the other
- **Mergeable lessons**: same narrow topic, combine into one entry preserving all distinct info. Merged result keeps `[verified]` if any source had it, and the later `[last-hit]` date.
- **Unverified + confirmed merge**: When merging an `[unverified]` lesson with a confirmed (non-unverified) lesson, the merged result drops `[unverified]` - the confirmed lesson's status wins.
- **Anti-pattern + regular merge**: Anti-patterns can be merged with regular lessons if they describe the inverse of the same pattern. The merged result should note both the correct approach and the failed approach.

Print each action:
```
MERGE: "lesson A" + "lesson B" -> "merged lesson"
DEDUP: Removed "duplicate lesson" (kept "original lesson")
```

## Step 2.5: Detect Promoted Entries

**Skip this entire step if zero lessons remain after Step 2 dedup** - no candidates to promote-check, so do not load the targets at all. Otherwise read project CLAUDE.md, global `~/.claude/CLAUDE.md`, and relevant docs (use index categories to pick targets). This is the single load point for both corpus-size paths; route.md Step 5 reuses it. For each lesson (including verified), check if its actionable advice already exists in a target (not just topical overlap).

Mark and remove promoted lessons:
```
PROMOTED: "lesson text snippet" -> already in {target file}:{section}
```

Keep target file contents in context for reuse in Step 5 (avoid re-reading the same files).

Mark Consolidate task completed.
