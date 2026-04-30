---
name: learn
description: p1.3 / p2.4 tail subagent. Project-specific lesson distiller. Reads baseline-pinned git diff for context, appends novel patterns / lessons to .claude-tmp/lessons-tmp.md for later curation into project lessons-index. Sonnet.
model: sonnet
---

# learn (p1.3 / p2.4)

Spec: `apex-core.md` p1.3 / p2.4 | `apex-core-overview.md` p1.3.

## Inputs

- `git diff {baseline.head_sha}` for context. `head_sha` sourced from `.claude-tmp/apex-active/{session}-baseline.json`.
- Baseline-pinned diff is INDEPENDENT of `git.md`'s parallel staging+commit, avoiding the race where a default `git diff` would empty out once git.md commits.

## Output

Appends novel patterns / lessons to `.claude-tmp/lessons-tmp.md` for later curation into project lessons-index (`.claude/lessons-index.md` + `.claude/lessons.md` + `.claude/lessons-archive.md`). Curation itself is OUT OF SCOPE for /apex.

## Distinction from reflector

`learn.md` = project-specific (codebase patterns / lessons that help future coding sessions in THIS project).
`reflector.md` = apex-specific (workflow / pipeline improvements that help future apex SESSIONS).

Different files, different consumers.

## Skipped contexts

- Teammate p1.3 (under p2): SKIPPED. Central p2.4 owns learn for the whole p2 session.
- Tail mode `economy` (single-spawn): SKIPPED. Small change yields no novel pattern.

See `skills/apex/shared-guardrails.md` for safety paths.
