---
name: scout2
description: Scout phase 2 preflight (step 7). Computes effective_blast and mode, writes preflight-{session}.json, gates targeted 7.x rescout when missed_regions != [].
---

# scout2 (step 7)

Spec: `apex-core.md` step 7 (full) | `apex-core-overview.md` step 7 (summary).

Inputs: `screened-{session}.json`, `shard-plan-{session}.json`, `{session}-hypothesis.json` (for `original_prompt` + intent).

Output: `.claude-tmp/scout/preflight-{session}.json` (validated against `schemas/preflight.schema.json`).

Gate (decided by the script's `mode` output):
| missed_regions | effective_blast | mode | next |
|----------------|-----------------|------|------|
| [] | small | medium | step 8 |
| [] | large | complex | step 8 (no rescout) |
| != [] | (any) | complex | TaskCreate 7.x then step 8 |

`effective_blast`: `small` if kept-file count <= 15 AND shard count == 1; otherwise `large`. Both terms required - a wide pre-screen scope that screening culled to <= 15 still routes to `large` / Path 2.

## Step 1: identify missed regions (LLM judgment)

Read `screened-{session}.json` and `{session}-hypothesis.json` (`original_prompt` + `hypothesis` + `alternatives`). Identify regions the screener may have under-covered relative to user intent. Each region: `{file, line_range?, reason}`. Empty array if screened scope already covers the hypothesis.

Compose as a JSON-string bash variable:

```
MISSED='[{"file":"...","reason":"..."}]'    # or '[]' for none
```

## Step 2: finalize (deterministic)

```
mode=$(bash $HOME/.claude/skills/apex/scripts/scout2-finalize.sh \
  --session {session} --missed "$MISSED")
```

The script reads `screened` + `shard-plan`, computes `effective_blast`, composes + validates `preflight-{session}.json`, echoes the selected `mode` to stdout. Non-zero exit aborts with explicit error (preflight malformed at producer source).

## Step 3: 7.x TaskCreate (only when `MISSED` was non-empty)

```
TaskCreate "7.x Targeted rescout" - blockedBy [7]
  -> agents/rescout.md (Sonnet) re-enumerates missed_regions
  -> scripts/merge-scout-findings.py merges into screened-{session}.json as kept (no re-screen)
```

Rescout entries: `confidence: medium` by default, `high` with explicit `line_range`. 7.x does NOT re-trigger preflight (complex mode is sticky). Trace path: `{session}-traces/entryflow/rescout-attempt-N.md`.

See `shared-guardrails.md` for trace path schema, JSON Schema validation.
