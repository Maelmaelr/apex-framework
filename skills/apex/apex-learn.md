# apex-learn - Capture Lessons from Implementation

<!-- Called by: apex-tail.md (Agent 1, spawned from SKILL.md Step 6A or apex-apex.md plan Phase 4), apex-fix/SKILL.md Step 3, apex-file-health/SKILL.md Step 6 -->

<!-- Capture lessons if: (1) took multiple attempts, (2) tricky/non-obvious solution, (3) new pattern worth remembering, (4) verification failure that required research. -->

**Output rules:** Only output the Step 1 guard/skip message, Step 2 skip message, or Step 4 summary. No other output.

## Step 1: Review Session

**Project guard:** If `.claude/lessons.md` does not exist in CWD, print "Learn: No project context (no .claude/lessons.md) -- skipping" and stop.

**Temp file cap.** Run `wc -l < .claude-tmp/lessons-tmp.md 2>/dev/null || echo 0`. If line count exceeds 50, print "Learn: lessons-tmp.md has {N} entries (cap: 50). Run /apex-lessons-extract to consolidate before capturing more." and stop. Do not append to an overflowing temp file.

Extract implementation lessons from your spawn context. If no context provided, print "Learn: No context provided -- skipping" and stop.
If spawn context includes "lessons-only", "document-output", "audit-document", or "prd-document": focus on discovery-phase patterns from the provided context only.

Extract:
- Tricky patterns that were hard to get right
- Gotchas and edge cases discovered
- Conventions discovered in the codebase
- Performance or security learnings

Verify: For lessons containing code-specific claims (function signatures, parameter types, return types, API shapes), check the actual source before capturing. Budget: max 2 source file reads. For claims beyond the budget, phrase the lesson as a pattern hint ("X appears to accept...") rather than an assertion.

Filter: Only capture non-obvious lessons. Skip obvious or common knowledge.
Do NOT capture workflow observations (how APEX itself performed -- scan, path, scout, plan, team, verification quality). Those belong in apex-reflect.

**Non-obvious definition.** A lesson is non-obvious if it: (a) contradicts what the codebase structure or framework docs suggest, OR (b) caused a retry, failure, or rollback during this session. Do not capture lessons that are directly discoverable from reading the relevant source file or its documentation.

**Anti-pattern capture.** When an approach was attempted and failed (caused a retry, build failure, or produced incorrect results), capture it as a negative lesson with [anti-pattern] tag. Format in lessons-tmp.md:
```
<!-- {date} -->
- [anti-pattern] {What was tried} fails because {why it failed}. Correct approach: {what worked instead}.
```
Anti-patterns are especially valuable when the failed approach seems reasonable or matches a common pattern from other frameworks/projects.

## Step 2: Skip If None

If no lessons worth capturing:
Print: "Learn: No new lessons captured"
Stop here.

## Step 3: Append to Temp File

Read .claude-tmp/lessons-tmp.md first (if exists). Skip lessons already present (exact or near-duplicate match). Append remaining lessons (create file if missing).

Format:
```
<!-- {date} [{session-label}] -->
- {lesson 1}
- {lesson 2}
```

Session label is optional context derived from the task type (e.g., audit, compliance, file-health). Omit for standard implementation sessions.

## Step 4: Report

Print a brief summary (this gets surfaced to the user by the caller):
"Learn: {count} lessons captured ({one-line summary of topics, e.g. 'i18n gotcha, parallel task ordering'})"

## Forbidden Actions

- Do not persist literal credentials, tokens, API keys, or secret values
- Do not modify or write to files without reading them first
- ASCII only -- no emojis, no unicode
- Do not modify lessons.md directly (use lessons-tmp.md for new lessons)
- Do not add `[verified]` or `[last-hit]` tags to lesson entries -- only apex-lessons-extract and apex-lessons-analyze manage these tags
