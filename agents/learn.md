---
name: learn
description: Project-specific lesson distiller. Reads baseline-pinned git diff, appends novel patterns to .claude-tmp/lessons-tmp.md.
model: sonnet
---

# learn

Spec: `apex-core.md` step 11.

Required reads at spawn: `$HOME/.claude/CLAUDE.md` (subagents do not inherit the parent session's user-global rules - load them explicitly before any action).

## Input

`git diff {baseline.head_sha}` (head_sha from `.claude-tmp/apex-active/{session}-baseline.json`; pinned so the diff stays valid through step 12's commit).

## Output

Append novel patterns under `flock`:

```
bash skills/apex/scripts/append-with-lock.sh .claude-tmp/lessons-tmp.md
```

Curation into the project lessons-index is owned by `/apex-lessons`.

## What counts as a pattern

The bar is **evidence of difficulty** in this session. A lesson is worth recording ONLY if all three hold:

1. **Difficulty signal in the trace.** `.claude-tmp/apex-active/{session}-fix-attempts.json` shows `attempts >= 1` (verify fix-loop ran), OR the spawn prompt explicitly tags this run as multi-retry / non-converging. First-try-clean sessions do NOT produce lessons - skip the agent's body and exit silently.
2. **Concrete cause.** The diff carries the surprise that caused the retry: a hidden constraint, a race / ordering rule, a framework gotcha, an anti-default behavior. State the cause and the fix together; both are required.
3. **Non-derivable.** The pattern is NOT inferable from `CLAUDE.md`, framework docs, or apex-core.md.

NOT patterns (drop, even if interesting): trivial bug fixes, env-var defaults, table / column descriptions, route catalog, "I learned the API" facts, generic best-practice restatements, one-off cleanups, observations that did not require a retry.

**Default = drop.** A normal-difficulty session SHOULD append zero lessons. One lesson per ~5-10 sessions is the calibration target. If you find yourself writing more than one entry, you are catching trivia - re-read criterion 1.

`reflector` (step 13) is the apex-workflow counterpart; this agent stays project-scoped.

## Tiers

`economy`: SKIPPED. `standard`: parallel with `documentation.md`.

See `apex-core.md` Conventions for safety paths.
