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

## Team-sizing heuristic

Inputs:
- `complexity_hint` from `{session}-hypothesis.json`
- kept-file count from `screened-{session}.json`
- per-shard kept distribution from `shard-plan-{session}.json`

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

Run BEFORE embedding the plan. On overlap: reassign the file to the teammate that "owns" it more strongly (more findings cite it, primary edit responsibility), OR move it to `shared_files` if cross-cutting.

The check is deterministic - delegated to `scripts/validate-disjoint-scopes.py` so the planner does not re-implement set arithmetic in prose:

```
# Write the candidate plan to a tmp file (planner-driven; tmp-keyed so concurrent
# planners do not collide).
plan_tmp=".claude-tmp/apex-active/{session}-plan-candidate.json"
cat > "$plan_tmp" <<'JSON'
{"teammates": [
  {"teammate_id": "ab12", "allowed_files": ["..."]},
  {"teammate_id": "cd34", "allowed_files": ["..."]}
]}
JSON

python3 ~/.claude/skills/apex/scripts/validate-disjoint-scopes.py \
  --plan "$plan_tmp" --session "{session}"
```

Exit codes:
- `0` - all teammate scopes pairwise disjoint (excluding safety paths)
- `1` - overlap detected; stdout lists `OVERLAP\t<file>\t<teammate-a>\t<teammate-b>` per offending pair. Planner reassigns each file (heuristic: keep in the teammate with more findings citing it; route to `shared_files` if unclear) and re-runs the validator
- `2` - input malformed (planner bug); hard-fail and surface to user

Safety paths (`.claude-tmp/`, `~/.claude/tmp/`, `/tmp/{session}-*`, `docs/**`, any `README*`) are excluded by the validator - they are shared by design and never count as overlap.

After reassignment, re-validate. If still overlapping after one reassign pass, hard-fail: planner cannot produce a valid disjoint partition. The orchestrator surfaces the conflict via AskUserQuestion (continue with merged scope as a single teammate / abort Path 2).

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
