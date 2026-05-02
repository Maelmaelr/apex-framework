---
name: rescout
description: Step 7.x targeted rescout (Sonnet). Re-enumerates missed_regions from preflight-{session}.json, writes rescout-{session}.json + trace rescout-attempt-N.md. Findings merged as kept (no re-screen) by merge-scout-findings.py.
model: sonnet
---

# rescout (step 7.x)

Spec: `apex-core.md` step 7.x | `apex-core-overview.md` step 7.x.

Fires only when `preflight-{session}.json.missed_regions != []`.

## Inputs

- `preflight-{session}.json` (specifically the `missed_regions` array)
- {session}-hypothesis.json (for context)

## Behavior

For each missed region (file + optional line_range + reason), re-enumerate to surface files that the deterministic 6.a + screener 6.c missed. Use the same deterministic-layer toolkit (static imports, ast-grep, framework conventions, nested-folder walk) but scoped to the missed region. When a region path is a directory or a known feature parent (e.g., `app/components/`, `src/features/<feature>/`, admin BFF route directories), enumerate immediate children by structural convention -- ripgrep symbol search misses subcomponent folders like `maintenance-banner/` whose only entry is an import in the parent.

## Outputs

1. `.claude-tmp/scout/rescout-{session}.json` (validated against `schemas/rescout.schema.json`):
   - `found[]`: `{file, reason, line_range?}` - include `line_range` whenever the layer that surfaced the file reports one (ast-grep, framework, rescout match locations); merge promotes confidence to `high` when `line_range` is present, else `medium`
2. `.claude-tmp/apex-active/{session}-traces/entryflow/rescout-attempt-N.md` - regions queried, files newly found, why prior pass missed them. N = 1 initially; N = 2 on exit-2 6c+7 re-run.

## Final action: run merge

Last step of the 7.x task: invoke

```
python3 ~/.claude/skills/apex/scripts/merge-scout-findings.py \
  --screened .claude-tmp/scout/screened-{session}.json \
  --rescout  .claude-tmp/scout/rescout-{session}.json
```

`merge-scout-findings.py` rewrites `screened-{session}.json` in place (rescout entries appended as kept; if a file was previously dropped, it is moved to kept; if previously kept, the rescout reason is appended to its `reasons[]`). Confidence on rescout-introduced kept entries is derived from `line_range` presence; previously-kept entries keep their deterministic-layer-count-derived confidence.

7.x does NOT re-trigger preflight (complex mode is sticky).

See `skills/apex/shared-guardrails.md` for trace path schema, JSON Schema validation.
