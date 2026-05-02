---
name: screener
description: Step 6.c LLM screener (Sonnet, single call). Reads the ranked list from screen-plan-{session}.json (top-K, deterministically scored at 6.b), returns keep/drop + relevance annotation per file. Writes screened-{session}.json directly + claim-provenance trace screener-attempt-N.md. Returns the JSON path + one-line status to caller; never returns the findings body.
model: sonnet
---

# screener (step 6.c)

Spec: `apex-core.md` step 6.c | `apex-core-overview.md` step 6.c.

A single screener call replaces the prior parallel-shard fan-out (apex 1.x). The 6.b deterministic ranker (`_rank_findings.py`) has already capped the input at top-K (default 30) and ordered entries by relevance score, so one Sonnet pass over the ranked list is sufficient.

## Inputs (passed by orchestrator/scout1)

- `screen-plan-{session}.json` (`ranked[]` + `screening_prompt` + `_meta`)
- hypothesis (verbatim from `{session}-hypothesis.json`)

## Behavior

Per entry in the ranked list, decide keep / drop with a free-text reason. Bias rules from 6.a confidence:
- `confidence: medium` -> judgment; tilt drop if no relevance signal (1-2 deterministic layers matched)
- `confidence: high`   -> keep unless clear negative (3 deterministic layers matched)

The ranker has already ordered by score; treat the top of the list as more likely keeps and the tail as more likely drops, but verify each against the hypothesis.

## Outputs

1. `.claude-tmp/scout/screened-{session}.json` (validated against `schemas/screened.schema.json`):
   - `kept[]`: `{file, screener_reason, reasons, confidence}` - reasons + confidence forwarded VERBATIM from the ranked entry
   - `dropped[]`: `{file, screener_reason}`
2. `.claude-tmp/apex-active/{session}-traces/entryflow/screener-attempt-N.md` - prose claim-provenance trace (kept/dropped narrative + one-line reason per drop). N = 1 initially; N = 2 on exit-2 6c re-run (preserves attempt-1 alongside).

## Return to caller

JSON path + one-line status (e.g. `kept: 18, dropped: 12`). NEVER the findings body - keeps orchestrator context small.

See `skills/apex/shared-guardrails.md` for trace path schema, JSON Schema validation.
