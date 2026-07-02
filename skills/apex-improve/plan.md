---
name: plan
description: apex-improve Step 3 - op planning. Translates {run}-findings.json into an evolve-plan (smallest op-class per finding, Principle 3 promotion rules), validates against admin-apex/schemas/evolve-plan.schema.json, writes {run}-evolve-plan.json.
---

# plan (apex-improve Step 3)

Spec: `skills/apex-improve/SKILL.md` Step 3.

## Inputs

- `.claude-tmp/admin-apex-active/{run}-findings.json` (from `analyze.md`)

## Output

`.claude-tmp/admin-apex-active/{run}-evolve-plan.json` - same schema as admin-apex evolve.md task 5 (`skills/admin-apex/schemas/evolve-plan.schema.json`). This shared schema lets Step 4 hand off to `admin-apex/evolve.md` task 6 without translation.

## Procedure

For each finding, pick the **smallest** op-class that satisfies it (per the SKILL.md edit hierarchy). Default bias toward `edit` (semantic). Promotion rules:

- A semantic finding cannot be expressed without breaking sentence flow -> promote to `replace` (still `kind: edit`, larger string swap).
- A replace finding would push the target past its file-health budget (docs: the per-role content-budget tier in `skills/apex/scripts/content-budget.json` - 2500 default, higher for the orchestrator-core / hot-path-heavy files; code: >400 lines split-first, >500 regardless) -> promote to `extract` (`kind: split` or `kind: create` for new sub-file).
- **Prose-budget discipline (near-cap)**: an op targeting an apex skill/agent .md already above 85% of its tier cap (the `approaching-budget` band) MUST be net-neutral-or-negative in word delta - bundle compensating tightening into the SAME file in the same op, or promote to `extract`. Never let a near-cap file grow without an offsetting tighten. New prose follows caveman house style (drop filler; keep every threshold / MUST; cite a cluster slug or nothing, never an inline `reflector <hex>` session hash - see `apply.md` Citation discipline).
- An extract finding has no obvious split seam -> AskUserQuestion (header: "no-seam extract"; options: `split-anyway | reduce-finding | defer`; dismiss = `defer`). Do NOT silently demote to `additive`.

A finding with `target_files: []` (e.g., a tech-watch never-run / stale finding) must NOT produce any op - it is report-only; surface in Step 6 only.

## Mirror-pair invariant

The apex framework maintains one mandatory mirror pair (per `apex-core.md`, which names the overview as its execution summary):

- `apex-core.md` (architecture rationale + cross-cutting conventions) <-> `apex-core-overview.md` (execution skeleton)

When any op in the plan targets one half of the pair, auto-pair the same `kind` against the other half and emit it as a second op in the same `ops` array (same `rationale`, suffixed `mirror-pair:`). The LLM may drop the auto-paired op only with an explicit per-op `rationale` prefixed `mirror-drop:` justifying scoped divergence (e.g., `mirror-drop: change is overview-only formatting; contract surface unaffected`); silent drops are not permitted.

Future mirror pairs plug in by extending the list above. Do NOT generalize prematurely to a registry / detector while the list is one entry - one extra bullet is cheaper than a new mechanism (Principle 3).

## Plan shape

```
{
  "run": "{run}",
  "ops": [
    {
      "kind": "edit" | "create" | "rename" | "split" | "merge" | "retire" | "schema-add" | "schema-remove" | "hook-add" | "hook-remove",
      "target": "<repo-relative path>",
      "split_into":    ["<paths>"],   // only when kind == split
      "merge_sources": ["<paths>"],   // only when kind == merge
      "rename_to":     "<path>",      // only when kind == rename
      "rationale":     "<one-line tied to finding id>",
      "doc_only":      true | false   // true if op only edits README/apex-core/overview/CLAUDE.md
    },
    ...
  ],
  "_meta": {
    "generated_at": "<ISO-8601>",
    "source_clusters": ["<finding ids that motivated each op>"]
  }
}
```

## Validation

Validate before write via the canonical helper:

```
bash skills/apex/scripts/validate-json.sh --admin evolve-plan {path}
```

Exit 0 = valid; exit 1 = malformed -> abort with explicit error (the plan is malformed; do NOT silently fall back).

## doc_only classification

`doc_only` is mechanical, not intent-based: true iff every modified file is in `{README.md, apex-core.md, apex-core-overview.md, CLAUDE.md}`. Op application is `apply.md` (Step 4); this step only reads findings.json.
