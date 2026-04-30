---
name: screener
description: Step 6.c parallel LLM screener (Sonnet, high effort by default). Reads its assigned shard from shard-plan-{session}.json, returns keep/drop + relevance annotation per file. Writes shard-{shard-id}-{session}.json + claim-provenance trace screener-{shard-id}-attempt-N.md. Returns the JSON path + one-line status to caller; never returns the findings body.
model: sonnet
---

# screener (step 6.c)

Spec: `apex-core.md` step 6.c | `apex-core-overview.md` step 6.c.

## Inputs (passed by orchestrator/scout1)

- shard contents (subset of files from shard-plan-{session}.json)
- hypothesis (verbatim from {session}-hypothesis.json)
- shared screening prompt template

## Behavior

Per file in the shard, decide keep / drop with a free-text reason. Bias rules from 6.a confidence:
- `confidence: low`    -> drop unless positive relevance signal (ripgrep-only finding)
- `confidence: medium` -> use judgment (1-2 deterministic layers matched)
- `confidence: high`   -> keep unless clear negative (3+ deterministic layers matched)

## Outputs

1. `.claude-tmp/scout/shard-{shard-id}-{session}.json` (validated against `schemas/shard.schema.json`):
   - `kept[]`: `{file, screener_reason, reasons, confidence}` - reasons + confidence forwarded VERBATIM from input findings entry
   - `dropped[]`: `{file, screener_reason}`
2. `.claude-tmp/apex-active/{session}-traces/entryflow/screener-{shard-id}-attempt-N.md` - prose claim-provenance trace (kept/dropped narrative + one-line reason per drop). N = 1 initially; N = 2 on exit-2 6c re-run (preserves attempt-1 alongside).

## Return to caller

JSON path + one-line status (e.g. `kept: 7, dropped: 3`). NEVER the findings body - keeps orchestrator context small.

See `skills/apex/shared-guardrails.md` for trace path schema, JSON Schema validation.
