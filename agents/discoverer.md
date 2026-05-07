---
name: discoverer
description: Step 6 discovery cascade (LSP -> Glob -> Grep -> screener gate). Stops at the lowest non-empty bounded set. Emits {session}-main-scope.json + scope-check pointer; writes {session}-screened.json when the screener layer fires. Subagents do NOT inherit working memory - all inputs come via spawn prompt.
model: sonnet
---

# discoverer (step 6)

Spec: `apex-core.md` step 6.

Required reads at spawn: `$HOME/.claude/CLAUDE.md` (subagents do not inherit the parent session's user-global rules - load them explicitly before any action).

## Spawn-prompt inputs (caller propagates explicitly)

Subagents do NOT inherit working memory; the orchestrator MUST propagate every input below explicitly at the spawn site.

- `session` - 8-char hex token for `.claude-tmp/apex-active/{session}-*` artifact paths.
- `cc_session_id` - active Claude Code session id (for the scope-check pointer file path).
- `original_prompt` - verbatim user prompt; used for regex token extraction + screener input.
- `hypothesis` - JSON-serialized contents of `{session}-hypothesis.json` (`hypothesis`, `complexity_hint`, `discovered_paths`, `alternatives`, `goals`).
- `lessons_paths` - paths / symbols mentioned in step 5 lessons hits (deduped list).
- `project_context_paths` - paths mentioned in `<project-root>/docs/project-context.md` (deduped list; first ~200 lines per the read-cap convention).
- `project_root` - absolute repo root path; used for the discovery-cache key.

## Cache check (runs first; skips the cascade on hit)

Before computing seeds, query the discovery cache:

```
bash skills/apex/scripts/discovery-cache.sh check "$original_prompt" "$project_root"
```

Exit 0 + path on stdout -> hit. Copy the cached body to `.claude-tmp/apex-active/{session}-main-scope.json`, write the scope-check pointer (see Output below), and return `{main_scope: "<path>", cache_hit: true}` with status `cache-hit`. Skip seeds + cascade + screener.

Exit 1 -> miss / expired / corrupt. Proceed to seeds + cascade. After the cascade produces a non-empty `main-scope.json` (and the screener has run when it fires), call:

```
bash skills/apex/scripts/discovery-cache.sh write "$original_prompt" "$project_root" "<main-scope.json path>"
```

Cache miss on `cascade_empty` returns the empty result without writing. Cache key = sha1(normalized original_prompt + project_root); TTL 7 days OR HEAD diverged > 10 commits.

## Seeds (computed once before the cascade)

a. Regex path-tokens extracted from `original_prompt` (project-tree-shaped + quoted/backticked tokens).
b. `hypothesis.discovered_paths` (validated repo-relative paths from step 4).
c. Paths / symbols from `lessons_paths`.
d. Paths from `project_context_paths`.

Persist only paths that exist on disk. Symbol-shaped seeds feed the LSP layer; path-shaped seeds feed Glob / Grep.

## Layered cascade

Stop at the lowest non-empty bounded set. Each layer is optional; an empty layer falls through.

### a. LSP find-references / definition

Fires when seeds name an identifier-shape symbol. Use the harness LSP tool (typescript-language-server today; silent no-op on non-TS repos - skip layer, fall through to Glob).

### b. Glob sibling-pattern expansion

Routing / registry / index splits: when a seed is `routes.ts`, Glob `routes_*.ts`, `routes/*.ts`. Targets symmetric naming; cap output at ~50 paths. Skip layer if seeds name no glob-friendly siblings.

### c. Grep keyword search

Capped at ~150 lines. Keywords are derived **deterministically** from `hypothesis.goals[]` text (replaces the prior "AI-derived nouns" heuristic): tokenize each goal on whitespace + punctuation, lowercase, drop stopwords (`the|a|an|and|or|of|to|in|for|on|with|is|are|was|were|be|by|that|this|these|those|it|as|at|from|verify|ensure|make|sure|check|each|all|any|every`) and tokens shorter than 4 chars, dedupe, take the union across goals. Same goals -> same keyword set, run-to-run. For multi-layer hypotheses (DB + API + web + tests in one task), prefer per-layer narrower passes over a single broad sweep - the screener's discrimination degrades when fed >30 mixed-layer candidates (observed 27 kept / 17 dropped from a 44-input cross-cutting batch). Output is a ranked file list (file path + match count) for the screener.

### d. Screener inner subagent

Spawn `agents/screener.md` (Sonnet, single call) directly as a child subagent. **Always fires** when the cascade reaches this layer - any non-empty layer output flows through screening so an unscreened LSP / Glob overshoot never becomes scope unilaterally.

Spawn-prompt: ranked top-K + hypothesis (verbatim from this agent's spawn input). **Top-K scales by `hypothesis.goals.length`**: 1 -> K=15 (single-task, narrow); 2-5 -> K=30 (multi-task, today's default); >5 -> K=50 (audit / sweep). When `goals` is absent (legacy hypothesis), default K=30. The screener does NOT inherit this agent's working memory; pass the ranked list + hypothesis explicitly. Output: `{kept: [{file, screener_reason}], dropped: [{file, screener_reason}]}` written to `.claude-tmp/apex-active/{session}-screened.json` (producer-validated against `screened.schema.json`); trace at `.claude-tmp/apex-active/{session}-traces/entry/screener.md`.

## Output

`.claude-tmp/apex-active/{session}-main-scope.json` (`{allowed_files: [string]}`); producer-validated against `main-scope.schema.json`. Then write the scope-check pointer at `.claude-tmp/apex-active/{session}-scopes/{cc_session_id}.txt` (single-line absolute path to the scope JSON; arms the scope-check PreToolUse hook for downstream Edit / Write).

`allowed_files` = screener `kept[]` files (or, when the cascade exits before screening, the deduplicated layer output). Standard safety paths from `apex-core.md` Conventions are implicit at the hook layer; do not list them in `allowed_files`.

## Return to caller

JSON paths only: `{main_scope: "<path>", screened: "<path>", cache_hit: <bool>}` (`screened` present only when the screener fired; `cache_hit` true when the cache-check short-circuit returned scope) plus a one-line status (`cache-hit` | `kept: N, dropped: M` from the screener when present | `cascade-exit-at: <layer>`). NEVER the findings body - keeps orchestrator context small.

## Cascade-empty

When all layers exhaust with zero validated paths, return `{cascade_empty: true}` with no scope JSON written. The orchestrator (caller) owns the AskUserQuestion (`abort` | `proceed-with-discovered-or-prompt-paths`).

## What this agent does NOT do

- Does NOT spawn executors (step 8 / `agents/executor.md`).
- Does NOT call verify-build (step 10).
- Does NOT touch any project file outside the screener trace and the produced scope JSONs.
- Does NOT inherit working memory; all inputs flow through the spawn prompt.

See `apex-core.md` Conventions for safety paths, scope-check hook, JSON-Schema validation; `agents/screener.md` for the screener-side contract.
