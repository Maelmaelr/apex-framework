---
name: lsp-scout
description: Step 6.a layer 3 agent fallback (Sonnet, low effort). Covers non-TS / non-JS languages and deterministic-LSP-failed cases. Uses MCP LSP plugins (mcp__*lsp__find_references) against long-running plugin-managed servers - no per-invocation spawn cost (the deterministic Python client at scripts/_lsp_query.py pays that cost for TS/JS). Writes lsp-agent-{session}.json to .claude-tmp/scout/. Spawned by scout1.md when (a) seed_paths include non-TS-family languages, or (b) deterministic layer 3 returned 0 references.
model: sonnet
---

# lsp-scout (step 6.a layer 3 agent fallback)

Spec: `apex-core.md` step 6.a layer 3 (LSP references; hybrid integration).

## Inputs (passed by scout1.md)

- `findings-{session}.json` (read-only - what the deterministic layers already found)
- `{session}-hypothesis.json` (verbatim `original_prompt` + `hypothesis` + `alternatives`)
- list of seed_paths and seed_terms (extracted from hypothesis by enumerate-scout.sh seed step; scout1.md re-extracts and passes verbatim)

## Behavior

For each `(seed_path, seed_term)` pair where the language is NOT in the deterministic-handled set (TS/JS family - .ts/.tsx/.js/.jsx/.mjs/.cjs/.mts/.cts), AND an MCP LSP plugin tool is available for that language (`mcp__*lsp__find_references`), call the tool to find references.

Plugin map (extend as MCP plugins land):
- `.py` -> `mcp__pylsp__*` (when registered)
- `.go` -> `mcp__gopls__*` (when registered)
- `.rs` -> `mcp__rust_analyzer__*` (when registered)

If no MCP tool is available for a seed_path's language, skip - layer 5 ripgrep + layer 2 ast-grep already cover it.

ALSO covers TS/JS files when the deterministic Python client (scripts/_lsp_query.py) returned 0 references for them - the long-running MCP-side server may have the project indexed where the one-shot subprocess did not.

## Output

`.claude-tmp/scout/lsp-agent-{session}.json` (validated against `skills/apex/schemas/lsp-agent.schema.json`):

```
{
  "found": [
    {"file": "<realpath>", "detail": "lsp '<term>' from <seed>", "line_range": [start, end] | null}
  ],
  "_meta": {"warnings": [...], "languages_covered": ["python", "go", ...]}
}
```

scout1.md (sequential, BEFORE 6.b shard) immediately invokes `skills/apex/scripts/merge-lsp-agent.py --findings findings-{session}.json --lsp-agent lsp-agent-{session}.json`, which folds entries into findings as `layer=lsp` reasons (dedup by detail, recompute confidence per the same rule as `_enumerate_merge.py`).

## Trace

Write a brief claim-provenance trace at `.claude-tmp/apex-active/{session}-traces/entryflow/lsp-scout-attempt-N.md`: per (seed_path, seed_term, mcp_tool) tuple - tool used, references found count, one-line reason for any skips.

## Return to caller

JSON path + one-line status (e.g., `lsp-agent: 12 refs across python+go`). NEVER the findings body.

## Scope

Single Sonnet pass. No internal agent recursion. No file edits. Read + MCP LSP tool calls only.

See `skills/apex/shared-guardrails.md` for trace path schema.
