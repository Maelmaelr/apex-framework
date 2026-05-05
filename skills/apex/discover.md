---
name: discover
description: Step 6 discovery cascade. Layered LSP -> Glob -> Grep -> screener gate; stops at the lowest non-empty bounded set. Emits {session}-main-scope.json + scope-check pointer; writes {session}-screened.json when the screener layer fires.
---

# discover (step 6)

Spec: `apex-core.md` step 6.

## Inputs (from main-orchestrator working memory)

- `{session}-hypothesis.json` (`original_prompt`, `hypothesis`, `complexity_hint`, `alternatives`, `discovered_paths`)
- Step 5 lessons hits + matched paths (working memory)
- `<project-root>/docs/project-context.md` (read at step 1, cached; consumers re-read directly when their work requires it)

## Seeds

Cheap, pre-paid in working memory; computed once before the cascade:

a. Regex path-tokens extracted from `original_prompt` (project-tree-shaped + quoted/backticked tokens)
b. `hypothesis.discovered_paths` (validated repo-relative paths from step 4)
c. Paths / symbols mentioned in step 5 lessons hits
d. Paths mentioned in `<project-root>/docs/project-context.md`

Persist only paths that exist on disk. Symbol-shaped seeds (identifiers) feed the LSP layer; path-shaped seeds feed Glob / Grep.

## Layered cascade

Stop at the lowest non-empty bounded set. Each layer is optional; an empty layer falls through.

### a. LSP find-references / definition

Fires when seeds name an identifier-shape symbol. Use the harness LSP tool (typescript-language-server today; silent no-op on non-TS repos - skip layer, fall through to Glob).

### b. Glob sibling-pattern expansion

Routing / registry / index splits: when a seed is `routes.ts`, Glob `routes_*.ts`, `routes/*.ts`. Targets symmetric naming; cap output at ~50 paths. Skip layer if seeds name no glob-friendly siblings.

### c. Grep keyword search

Capped at ~150 lines. Keywords derived from hypothesis nouns + symbol names; narrow if the cap is hit (drop common words, add scope qualifiers). Output is a ranked file list (file path + match count) for the screener.

### d. Screener LLM gate

`agents/screener.md` (Sonnet, single call). **Always fires** when the cascade reaches this layer - any non-empty layer output flows through screening so an unscreened LSP / Glob overshoot never becomes scope unilaterally.

Inputs: ranked top-K (default 30) + hypothesis. Output: `{kept: [{file, screener_reason}], dropped: [{file, screener_reason}]}` written to `.claude-tmp/apex-active/{session}-screened.json` (producer-validated against `screened.schema.json`); trace at `.claude-tmp/apex-active/{session}-traces/entry/screener.md`.

## Output

`.claude-tmp/apex-active/{session}-main-scope.json` (`{allowed_files: [string]}`); producer-validated against `main-scope.schema.json`. Then write the scope-check pointer at `.claude-tmp/apex-active/{session}-scopes/{cc_session_id}.txt` (single-line absolute path to the scope JSON; arms the scope-check PreToolUse hook for downstream Edit / Write).

`allowed_files` = screener `kept[]` files (or, when the cascade exits before screening, the deduplicated layer output). Standard safety paths from `apex-core.md` Conventions are implicit at the hook layer; do not list them in `allowed_files`.

## Cascade-empty abort

When all layers exhaust with zero validated paths:

AskUserQuestion (header: "Discovery exhausted"):
- `abort` -> orchestrator runs `session-end-hook.sh {session}` inline; exit cleanly.
- `proceed-with-discovered-or-prompt-paths` -> first reuse `hypothesis.discovered_paths` (already disk-validated at step 4); if empty/absent, regex-extract from `original_prompt` and validate on disk. Write scope inline with the surviving set + safety paths; if both yield zero validated paths, fall through to abort.
- Dismiss / cancel = `abort`.

## What this skill does NOT do

- Does NOT spawn executors (step 8 / `execute.md`)
- Does NOT call verify-build (step 10)
- Does NOT touch any project file outside the screener trace and the produced scope JSONs
- Does NOT inherit working memory in subagent contexts; the screener spawn carries the ranked list + hypothesis explicitly

See `apex-core.md` Conventions for safety paths, scope-check hook, JSON-Schema validation; `agents/screener.md` for the screener-side contract.
