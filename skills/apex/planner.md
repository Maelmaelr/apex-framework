---
name: planner
description: p2.0b. Sizes the team, picks per-teammate model (Opus or Sonnet from complexity_hint + scope size), assigns disjoint allowed_files, routes cross-cutting files to shared_files. Embeds the delegation plan inside Claude Code plan mode so it survives the p2.0c context clear.
---

# planner (p2.0b)

Spec: `apex-core.md` p2.0b | `apex-core-overview.md` p2.0b.

Inputs:
- `screened-{session}.json` - kept-files set per shard (scope source)
- `preflight-{session}.json` - effective_blast, mode
- `{session}-hypothesis.json` - `complexity_hint` for per-teammate model selection; `original_prompt` + `hypothesis` for task descriptions

Outputs (embedded in plan):
- team size + per-teammate model (Opus / Sonnet; high-effort fires when `complexity_hint == high`)
- per-teammate `{teammate-id}` (4-char lowercase hex shortened guid via `openssl rand -hex 2`)
- per-teammate scoped task description + `allowed_files`
- `shared_files: [...]` (cross-teammate files routed to p2.4 integration pass)

**Disjoint-scope rule**: per-teammate `allowed_files` MUST be pairwise disjoint (excluding standard safety paths). Validator: planner self-checks pairwise intersection BEFORE embedding the plan; on overlap, planner reassigns or moves the file to `shared_files` (no silent overlap).

**Main scope is the union**: if a teammate needs a file outside `{session}-main-scope.json`, the planner extends main scope first (single source of truth).

First instruction in plan: call `p2.md` (TaskCreate p2.1 -> p2.7).

See `shared-guardrails.md` for safety paths, manifest schema, scope write producers.

## Architecture awareness (project-context.md)

Re-read `<project-root>/docs/project-context.md` (if present) BEFORE running the team-sizing heuristic. The doc surfaces architectural boundaries (frontend / backend, auth / payments, monorepo package layout) that kept-file count alone cannot reveal. Boundary respect is the planner's responsibility:

- A teammate slice should not span an architectural boundary unless `original_prompt` + `hypothesis` explicitly require cross-cutting work.
- Files clearly belonging to multiple boundaries (shared types, root configs, `docs/**`) belong in `shared_files`, never in any teammate's `allowed_files`.
- Per-teammate model selection may shift to Opus when a slice crosses a boundary that project-context.md flags as security-sensitive (auth, payments, webhook signing) - the size heuristic below is a floor, not a ceiling.

If `project-context.md` is absent, fall back to the kept-file count + hypothesis only - no inferred architecture. See `shared-guardrails.md` "Project context" for the closed read contract.

## Team-sizing heuristic

Inputs:
- `complexity_hint` from `{session}-hypothesis.json`
- kept-file count from `screened-{session}.json`
- per-shard kept distribution from `shard-plan-{session}.json`
- architectural boundaries from `<project-root>/docs/project-context.md` (if present; see above)

| complexity_hint | kept-file count | suggested team size |
|-----------------|-----------------|---------------------|
| low             | <= 15           | 1 (degenerate; should rarely reach Path 2) |
| low / medium    | 16-45           | 2-3 |
| medium          | 46-90           | 3-5 |
| high            | 46-90           | 4-6 |
| high            | > 90            | 5-8 |

Team size should typically track shard count from 6.b (shards already partition the work into ~15-file chunks) but is not constrained to it - the planner may merge two adjacent shards into one teammate when the work is closely coupled, or split one shard across two teammates when files cluster around independent concerns.

## Model selection per teammate

| complexity_hint | per-teammate scope size | model | high-effort? |
|-----------------|-------------------------|-------|--------------|
| low             | any                     | Sonnet | no          |
| medium          | <= 15 files             | Sonnet | no          |
| medium          | > 15 files              | Sonnet | yes         |
| high            | <= 10 files             | Sonnet | yes         |
| high            | > 10 files              | Opus   | yes         |

`complexity_hint == high` triggers the high-effort keyword for that teammate; size pushes Opus selection only when the slice itself is large.

## Disjoint-scope validator

Run BEFORE embedding the plan. The check is deterministic - delegated to `scripts/validate-disjoint-scopes.py`, which enforces three invariants against `plan-candidate.schema.json`:

1. per-teammate `allowed_files` pairwise disjoint (excluding safety paths)
2. union of `allowed_files` is a subset of main scope (if `--main-scope` is supplied)
3. `shared_files` (if present) is disjoint from every teammate's `allowed_files`

See `plan-mode.md` p2.0b for the canonical call snippet (passes `--plan`, `--main-scope`, `--session`). Stdout violations:

- `OVERLAP <file>\t<a>\t<b>` (check 1) - reassign to the teammate that "owns" the file more strongly (more findings cite it, primary edit responsibility) OR move to `shared_files` if cross-cutting.
- `NOT_IN_MAIN_SCOPE <file>\t<teammate>` (check 2) - extend `{session}-main-scope.json` to include the file, then re-run. Main scope is the union; never narrow a teammate to bypass this.
- `SHARED_OVERLAP <file>\t<teammate>` (check 3) - decide ownership: a file is in `shared_files` XOR exactly one teammate's `allowed_files`. Remove from one of the two lists.

Safety paths (`.claude-tmp/`, `~/.claude/tmp/`, `/tmp/{session}-*`, `docs/**`, any `README*`) are excluded by the validator - they are shared by design and never count as overlap.

After reassignment, re-validate. If still violating after one reassign pass, hard-fail: planner cannot produce a valid disjoint partition. The orchestrator surfaces the conflict via AskUserQuestion (continue with merged scope as a single teammate / abort Path 2).

## Plan embed template

The plan embedded in plan mode (survives p2.0c context clear):

```
First instruction: call ~/.claude/skills/apex/p2.md

Session: {session}
Team size: N
Per-teammate plan:

  - {teammate-id-1} (model: <Sonnet|Opus>, high-effort: <yes|no>)
    task: <description>
    allowed_files:
      - <file 1>
      - <file 2>
      ...

  - {teammate-id-2} (...)
    ...

Shared files (routed to p2.4 documentation.md integration pass):
  - <shared file 1>
  - <shared file 2>

Hypothesis: <verbatim from {session}-hypothesis.json>
Original prompt: <verbatim>
```

The first instruction `call p2.md` is critical - it routes the post-context-clear session into the Path 2 chain (p2.0 -> p2.7).
