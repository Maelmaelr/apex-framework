---
name: scout2
description: Scout phase 2 preflight (step 7). Computes effective_blast and mode, writes preflight-{session}.json, gates targeted 7.x rescout when missed_regions != [].
---

# scout2 (step 7)

Spec: `apex-core.md` step 7 (full) | `apex-core-overview.md` step 7 (summary).

Inputs: `screened-{session}.json`, `shard-plan-{session}.json`, `{session}-hypothesis.json` (for `original_prompt` + intent).

Outputs: `.claude-tmp/scout/preflight-{session}.json` (validated against `schemas/preflight.schema.json`):
```
{missed_regions: [{file, line_range: [start, end] | null, reason}],
 effective_blast: small|large,
 mode: medium|complex}
```

`effective_blast`: `small` if `kept-file count <= 15 AND shard count == 1`; `large` otherwise.

Gate:
| missed_regions | effective_blast | mode | next |
|----------------|-----------------|------|------|
| [] | small | medium | step 8 |
| [] | large | complex | step 8 (no rescout) |
| != [] | (any) | complex | TaskCreate 7.x |

7.x targeted rescout:
- `agents/rescout.md` (Sonnet) re-enumerates missed regions
- `scripts/merge-scout-findings.py` merges into `screened-{session}.json` as kept (no re-screen)
- rescout entries: `confidence: medium` by default, `high` with explicit `line_range`
- DOES NOT re-trigger preflight (complex mode is sticky)
- trace: `{session}-traces/entryflow/rescout-attempt-N.md`

See `shared-guardrails.md` for trace path, JSON Schema validation.

## `missed_regions` (LLM judgment)

scout2 reads `screened-{session}.json` and the hypothesis (`original_prompt` + `hypothesis` + `alternatives`) and identifies regions the screener may have under-covered relative to user intent. Each region carries a `file`, optional `line_range`, and short `reason` -- the input contract for `agents/rescout.md`.

Empty list when the screened scope already covers the hypothesis. Construct the missed-regions array as a JSON-string bash variable `$MISSED` (e.g., `MISSED='[{"file":"foo","reason":"bar"}]'`) -- the gate dispatch below reads it via `--argjson` directly, no `/tmp` staging.

## `effective_blast` computation (inline)

Both terms required: shard count is pre-screen (from 6.b), kept-file count is post-screen. A wide pre-screen scope that screening culled to <= 15 still indicates non-trivial blast and routes to `large` / Path 2.

`screened-{session}.json` and `shard-plan-{session}.json` are producer-validated upstream (6.c aggregator + 6.b shard-findings.sh); inline jq reads here are safe under the same-pipeline invariant.

```
kept_count=$(jq '.kept | length' .claude-tmp/scout/screened-{session}.json)
shard_count=$(jq '.shards | length' .claude-tmp/scout/shard-plan-{session}.json)

if [[ "$kept_count" -le 15 && "$shard_count" -eq 1 ]]; then
  effective_blast=small
else
  effective_blast=large
fi
```

## Gate dispatch + write (inline)

```
missed_count=$(printf '%s' "$MISSED" | jq 'length')

if [[ "$missed_count" -eq 0 ]]; then
  if [[ "$effective_blast" == "small" ]]; then
    mode=medium     # -> step 8
  else
    mode=complex    # -> step 8 (no rescout - nothing to look for)
  fi
else
  mode=complex      # -> TaskCreate 7.x first, then step 8
fi

# Compose preflight-{session}.json + producer-validate before downstream reads.
# Mandatory per shared-guardrails "Producer scripts validate before write".
jq -n \
  --arg mode "$mode" \
  --arg blast "$effective_blast" \
  --argjson missed "$MISSED" \
  '{missed_regions: $missed, effective_blast: $blast, mode: $mode}' \
  > .claude-tmp/scout/preflight-{session}.json

bash $HOME/.claude/skills/apex/scripts/validate-json.sh \
  preflight.schema.json .claude-tmp/scout/preflight-{session}.json
# exit 1 -> abort with explicit error (preflight malformed at producer source).
```

## 7.x TaskCreate (only when `missed_regions != []`)

```
TaskCreate "7.x Targeted rescout" - blockedBy [7] - agents/rescout.md (Sonnet) re-enumerates missed_regions, then scripts/merge-scout-findings.py --screened .claude-tmp/scout/screened-{session}.json --rescout .claude-tmp/scout/rescout-{session}.json
```

7.x does NOT re-trigger preflight (complex mode is sticky).
