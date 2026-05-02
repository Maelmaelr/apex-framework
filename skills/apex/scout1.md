---
name: scout1
description: Scout phase 1 owner (steps 6.a / 6.b / 6.c). Enumerate findings deterministically, rank by deterministic relevance score (top-K cap), screen via a single screener call into screened-{session}.json.
---

# scout1 (step 6)

Spec: `apex-core.md` step 6 (full) | `apex-core-overview.md` step 6 (summary).

TaskCreate (insert before task 7) the 3 sub-tasks:
- **6.a Enumerate** - `scripts/enumerate-scout.sh` -> `findings-{session}.json`
- **6.b Rank** - `scripts/rank-findings.sh` -> `screen-plan-{session}.json`
- **6.c Screen** - single `agents/screener.md` call -> `screened-{session}.json`

Routing:
- 6.a exit code 10 (zero-layer): orchestrator AskUserQuestion - see "AskUserQuestion contracts" below.
- 6.b exit code 11 (top-K cap overshot): orchestrator AskUserQuestion - see "AskUserQuestion contracts" below.
- 6.c: the screener writes its trace at `{session}-traces/entryflow/screener-attempt-N.md`.

## AskUserQuestion contracts (orchestrator-side)

Surfaced by `scout1.md` / `scout2.md`; `SKILL.md` step 6 routing is the entry point. All questions: dismiss / cancel = abort.

```
AskUserQuestion at 6.a (zero-layer; exit code 10 from enumerate):
  - "abort"
  - "proceed-with-prompt-paths"  (regex-extract paths from original_prompt,
                                  validate each on disk, write scope inline + pointer,
                                  SKIP 6.b/6.c/7/8/9, call p1.md directly)
0 validated paths after extraction -> abort like verify exit-1.

AskUserQuestion at 6.b (cap overshot; exit code 11 from rank-findings.sh):
  Read screen-plan-{session}.json _meta to size the overshoot (dropped_below_cap
  vs top_k). All listed options MUST be surfaced verbatim - the orchestrator MUST
  NOT collapse the option set by judgment call (e.g., dropping
  "proceed-with-prompt-paths" because it believes it already knows the right
  files). Option labels MUST NOT add freelance descriptions that imply any path
  other than the one defined below ("refine" is hard abort, NOT a license for
  inline implementation).

  Options:
    - "refine"                       (recommended; hard abort - see post-gate routing rule)
    - "proceed-with-prompt-paths"    (reuse zero-layer-extract.sh per "Zero-layer
                                      proceed" below; SKIP 6.c/7/8/9, call p1.md)
    - "continue"                     (last resort; run the screener over the
                                      already-capped top-K; entries below the cap
                                      stay dropped)
```

Aggregation: gone with the parallel fan-out. The single screener call writes `screened-{session}.json` directly (validated against `screened.schema.json`); scout1 returns the artifact path to apex.

See `shared-guardrails.md` for safety paths, scope-check hook, JSON Schema validation.

## TaskCreate template

```
TaskCreate "6.a Enumerate"  - blockedBy [5]    - scripts/enumerate-scout.sh --session {session} --hypothesis .claude-tmp/apex-active/{session}-hypothesis.json
TaskCreate "6.b Rank"       - blockedBy [6.a]  - scripts/rank-findings.sh   --session {session} --findings .claude-tmp/scout/findings-{session}.json --hypothesis .claude-tmp/apex-active/{session}-hypothesis.json
TaskCreate "6.c Screen"     - blockedBy [6.b]  - single screener.md call
```

## 6.a noise filter (token-cost contract)

`enumerate-scout.sh` is built to stay token-cheap without cropping determinism / exhaustivity. The ripgrep keyword fallback was retired (apex 1.x) - it generated noise that propagated through 6.b ranking into expensive 6.c screener cost, and the worst case (zero deterministic layers) is now handled cleanly by the zero-layer exit-10 dispatch.

Two safety nets remain:

- **Workspace excludes (deterministic layers).** `_walk()` skips dot-prefixed dirs at any depth (`apps/web/.next`, `apps/api/.turbo`, `.cache`, `.pytest_cache`, `.mypy_cache`, etc.) plus an explicit `WORKSPACE_EXCLUDES` set for non-dot build dirs (`node_modules`, `dist`, `build`, `out`, `coverage`, `__pycache__`, `venv`, `target`).
- **Post-merge denylist (safety net for all layers).** `_enumerate_merge.py` drops any path whose extension or basename matches a clearly-not-source pattern (lockfiles, sourcemaps, minified bundles, compiled bytecode, archives, fonts, AV, raster images). Source-shaped extensions (`ts/tsx/js/jsx/py/md/json/svg/html/css/yaml/toml/sh/rb/go/rs/...`) are NEVER in the denylist - the rule is "drop if clearly not human-edited", not an extension allowlist. Dropped count surfaces in `_meta.warnings`.

Explicit dot-paths in the prompt (e.g., `.github/workflows/ci.yml`) still flow through `seed_paths` (extracted from `original_prompt` / `hypothesis` text and validated on disk) so they are reachable via `static-imports` / `framework` layers without needing to widen the walk.

## 6.a layer rules + confidence (carried verbatim through to ranker, screener, and verify)

Each `findings-{session}.json` entry carries `reasons: [{layer, detail, line_range|null}]` with `layer` in `{static-imports, ast-grep, framework, rescout}`. `confidence` is derived from layer count:
- `high` - 3 deterministic layers (static-imports / ast-grep / framework)
- `medium` - 1-2 deterministic layers
- `rescout` layer is special-cased at 7.x merge time (never appears here); see `scout2.md`.

Screener (6.c) consumes confidence to bias keep/drop: `medium` -> judgment; `high` -> keep unless clear negative. Verify (8) treats all mechanically-passing claims as confirmed (no low-confidence-routing path exists since ripgrep retirement).

## 6.b ranker

After enumerate, scout1 invokes the ranker:

```
bash scripts/rank-findings.sh \
  --session {session} \
  --findings .claude-tmp/scout/findings-{session}.json \
  --hypothesis .claude-tmp/apex-active/{session}-hypothesis.json
```

The ranker:
- Optionally filters by `--min-confidence medium|high` (default `medium` = no filter).
- Computes a deterministic score per entry: `base (layer-count) + path-token-overlap-bonus - size-penalty`, clamped to [0, 1].
- Sorts descending and applies a top-K cap (default 30; `--top-k N` to override).
- Producer-validates and writes `screen-plan-{session}.json` (`ranked[]` + `screening_prompt` + `_meta`).
- Exits 11 when `dropped_below_cap >= top_k` (signal hypothesis is too broad - see 6.b AskUserQuestion).

`screen-plan-{session}.json` replaces the legacy `shard-plan-{session}.json` (single ranked list, no shards).

## 6.c screener (single call)

scout1 spawns `agents/screener.md` (Sonnet, single call) with the ranked list. The agent writes `screened-{session}.json` (`kept[]` + `dropped[]` + optional `_meta`) directly - no per-shard intermediates, no aggregator. Returns the JSON path + one-line status to scout1; never the findings body.

The exit-2 6c+7 re-run (driven by `verify-claims.sh`) re-invokes this single call with `attempt-2` in the trace path.

## Zero-layer proceed (6.a exit code 10)

Orchestrator (NOT scout1) handles the AskUserQuestion. On "proceed-with-prompt-paths":

```
bash $HOME/.claude/skills/apex/scripts/zero-layer-extract.sh {session}
```

The script reads `original_prompt` from `{session}-hypothesis.json`, regex-extracts paths (project-tree-shaped + quoted/backticked tokens), validates each on disk, writes `{session}-main-scope.json` + the scope pointer at `{session}-scopes/$CC_SESSION_ID.txt`. Exit codes: `0` = scope written, `10` = zero validated paths -> abort like verify exit-1.

Then SKIP 6.b / 6.c / 7 / 8 / 9 (mark TaskList completed as no-op) and call `p1.md` directly with NO preflight artifact written. p1.0 reads absent preflight as no-findings-consultation branch.

**Anti-rule (post-gate routing).** The script writes the scope; the orchestrator MUST NOT pre-write or post-write `{session}-main-scope.json` freehand. After `zero-layer-extract.sh` returns 0, the orchestrator MUST call `p1.md` directly. Forbidden from this branch: `EnterPlanMode`, `plan-mode.md`, `planner.md`, freehand inline `Write` of the scope JSON, manual scope synthesis from grep results, marking 6.c / 7 / 8 / 9 completed without their actual scripts having run as a stand-in for "I have my own scope". Path 2 is unreachable from the 6.a / 6.b proceed branches by design - if Path 2 is needed, the user must `refine` and re-prompt with a scope the deterministic layers can pick up.

**Anti-rule (post-`refine` routing).** When the user picks `refine` at the 6.a / 6.b gate, the orchestrator MUST run `bash $HOME/.claude/skills/apex/scripts/session-end-hook.sh {session}` inline and exit cleanly. Forbidden from this branch: any inline `Edit` / `Write` / `MultiEdit` / `NotebookEdit` to files mentioned in the original prompt, freehand p1.0 baseline / conflict-check execution, freehand p1.1 implementation, freehand p1.2 verify, freehand p1.3 tail spawns. `refine` means "the user will re-prompt with a narrower scope"; it is a hard abort, NOT a license to bypass the apex chain by editing inline. Implementing the user's request from prompt-extracted file paths is exactly what `proceed-with-prompt-paths` does (via `zero-layer-extract.sh` -> `p1.md` -> `implement.md` -> `executor.md`); if the orchestrator believes it has the right files, it MUST surface `proceed-with-prompt-paths` as an option (per "AskUserQuestion contracts" above) and let the user pick - it MUST NOT silently re-route a `refine` choice into an inline implementation.

## Cap-overshoot proceed (6.b exit code 11, "proceed-with-prompt-paths" branch)

Same flow as zero-layer: invoke `zero-layer-extract.sh {session}`, mark 6.c/7/8/9 completed as no-op, call `p1.md`. The screen plan (already written to disk by rank-findings.sh) is left for the reflector; the empty post-extract scope handles the "0 validated paths" abort identically to 6.a. The "Anti-rule (post-gate routing)" above applies verbatim to this branch.

## Cap-overshoot continue (6.b exit code 11, "continue" branch)

The ranker has already capped at top-K and ordered by deterministic score; on "continue" the orchestrator proceeds straight to 6.c with the existing `screen-plan-{session}.json` (no re-run). Entries below the cap stay dropped; the surfaced overshoot warning is preserved in `_meta.warnings` for the reflector.
