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

Pattern = non-derivable from `CLAUDE.md` / framework docs: anti-patterns with rationale, non-obvious API discoveries, multi-touch-point cascading rules, race-condition guards, project coordination conventions.

NOT patterns (state facts -> project `CLAUDE.md` / `docs/`): env-var defaults, table/column descriptions, route catalog, one-off bug fixes. If unsure, drop it.

`reflector` (step 13) is the apex-workflow counterpart; this agent stays project-scoped.

## Tiers

`economy`: SKIPPED. `standard`: parallel with `documentation.md`.

See `apex-core.md` Conventions for safety paths.
