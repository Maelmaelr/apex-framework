---
name: screener
description: Step 6 discovery gate (Sonnet, single call). Reads ranked file list (Glob / Grep output, top-K) + hypothesis; returns keep/drop + relevance per file. Writes {session}-screened.json + claim-provenance trace screener.md. Returns the JSON path + one-line status to caller; never returns the findings body.
model: sonnet
---

# screener (step 6.d)

Spec: `apex-core.md` step 6 (discovery cascade, screener gate).

Required reads at spawn: `$HOME/.claude/CLAUDE.md` (subagents do not inherit the parent session's user-global rules - load them explicitly before any action).

A single screener call is the only LLM gate in the cascade. Always fires when the cascade reaches this layer, regardless of upstream layer (LSP / Glob / Grep) so an unscreened overshoot never becomes scope unilaterally.

## Inputs (passed by agents/discoverer.md as inner subagent)

- Ranked file list (top-K, default 30; ordered by upstream relevance score)
- hypothesis (verbatim from `{session}-hypothesis.json`)

## Behavior

Per file in the ranked list, decide keep / drop with a free-text reason. Bias rules:
- Top of the list -> more likely keep (higher upstream signal).
- Tail -> drop unless the file is named in `hypothesis.discovered_paths` or implicated by a goal noun beyond mere import / test usage (reflector 5f2005be: 3 kept tail files were never edited - kept context, not kept work).
- Conceptual prompts (no specific file mentioned) -> tilt keep when the file is part of the hypothesis's named module.
- Mechanical prompts (named file in `original_prompt`) -> tilt drop unless the file is in the dependency neighborhood of the named target.
- Fix-site isolation: when the hypothesis points at a single resolution site (e.g., one controller handling a class of errors transparently for upstream/downstream callers), drop the upstream fetcher + sibling tests even if grep matched - they are not edited, only dragged through context. Keep them only when the hypothesis names a cross-file invariant.
- Read-only doc/rules gate: when a kept file is a doc/rules path (`docs/**`, top-level `*.md`, `CLAUDE.md`, `.claude/rules/**`) that no `hypothesis.goals[]` / `discovered_paths` entry names as a write target, keep it but prefix its `screener_reason` with `READ-ONLY: `. The discoverer / execute.md E3 preamble then surfaces these under `Shared read-only context (do not write)` so executors skip full re-reads instead of paying ~20k tokens/run re-reading scoped-in-but-unmodified docs (reflector c4b6d57b: 6 docs/rules files in scope, only 1 impacted; bc5f23cf: precautionary architecture-api.md / canvas-patterns.md both read-only).
- Asymmetric-cost rule (keep on genuine uncertainty): a wrongly-kept file costs only context tokens; a wrongly-dropped edit target costs a mid-dispatch scope expansion + re-grep at step 8 (the more expensive error). When keep/drop stays genuinely uncertain after the rules above, keep. The bias rules cut clear non-targets - they are NOT a mandate to minimize `kept[]`. Opus 4.7 obeys "be conservative / drop" more faithfully than 4.6, so measured recall drops unless coverage is explicitly favored here; step 8 dispatch is the real filter.

## Outputs

1. `.claude-tmp/apex-active/{session}-screened.json` (producer-validated against `screened.schema.json`):
   - `kept[]`: `{file, screener_reason}`
   - `dropped[]`: `{file, screener_reason}`
2. `.claude-tmp/apex-active/{session}-traces/entry/screener.md` - prose claim-provenance trace (kept/dropped narrative + one-line reason per drop).

## Return to caller

JSON path + one-line status. The status MUST report `retained=N` and `dropped=M` as ACTUAL post-screen counts, NOT the upstream rank-top-K heuristic value. Example: `kept: 18, dropped: 12, retained_of_input=18/30`. This lets the discoverer + reflector see how aggressively the screener cut, not just how many candidates it received (reflector dc44e292: "screener trace lists 28 grep candidates but reports only rank-top-K=30 heuristic, could emit actual retained-count / dropped-count for clarity"). NEVER the findings body - keeps orchestrator context small.

See `apex-core.md` Conventions for trace path schema and JSON-Schema validation.
