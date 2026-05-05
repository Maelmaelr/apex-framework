---
name: learn
description: Step 11 tail subagent. Project-specific lesson distiller. Reads baseline-pinned git diff for context, appends novel patterns / lessons to .claude-tmp/lessons-tmp.md for later curation into project lessons-index. Sonnet. Skipped under economy tier.
model: sonnet
---

# learn (step 11)

Spec: `apex-core.md` step 11.

## Inputs

- `git diff {baseline.head_sha}` for context. `head_sha` from `.claude-tmp/apex-active/{session}-baseline.json`. Baseline-pinned diff is INDEPENDENT of step 12's parallel staging+commit, avoiding the race where a default `git diff` would empty out once step 12 commits.

## Output

Appends novel patterns / lessons to `.claude-tmp/lessons-tmp.md` under `flock` via:

```
bash skills/apex/scripts/append-with-lock.sh .claude-tmp/lessons-tmp.md
```

Curation into the project lessons-index (`.claude/lessons-index.md` + `.claude/lessons.md` + `.claude/lessons-archive.md`) is OUT OF SCOPE for /apex (handled by `/apex-lessons`).

## Out of scope (do NOT record)

Project-state facts belong in project `CLAUDE.md` / `docs/`, NOT in `lessons-tmp.md`:
- env-var defaults / values (e.g., "`NEXT_PUBLIC_FOO` defaults to `true`")
- DB table or column descriptions (e.g., "`system_config` is a key-value store for runtime admin state")
- route / endpoint catalog facts (which path serves which payload)
- one-off bug fixes with no transferable pattern

Record only **patterns** that would not be derivable from `CLAUDE.md` or framework docs alone: anti-patterns with concrete rationale, non-obvious API discoveries, multi-touch-point cascading rules, established test seams, race-condition guards, project-established coordination conventions.

If unsure whether a finding is a pattern or a state fact, prefer dropping it - curation cannot reliably reclassify a state fact as a pattern.

## Distinction from reflector

`learn.md` = project-specific (codebase patterns / lessons that help future coding sessions in THIS project).
`reflector.md` = apex-specific (workflow / pipeline improvements that help future apex SESSIONS).

Different files, different consumers.

## Skipped contexts

- Tier `economy`: SKIPPED. Bounded scope rarely produces novel project-specific patterns worth distilling.
- Tier `standard`: runs in parallel with `documentation.md` at step 11.

See `apex-core.md` Conventions for safety paths.
