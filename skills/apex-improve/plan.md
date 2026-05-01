---
name: plan
description: apex-improve Step 3 - Phase 2 op planning. Translates {run}-findings.json into an evolve-plan (smallest op-class per finding, Principle 3 promotion rules), validates against admin-apex/schemas/evolve-plan.schema.json, writes {run}-evolve-plan.json.
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
- A replace finding would push the target file past 500 lines (or 150 for skills/agents per the file-health cap) -> promote to `extract` (`kind: split` or `kind: create` for new sub-file).
- An extract finding has no obvious split seam -> AskUserQuestion (header: "no-seam extract"; options: `split-anyway | reduce-finding | defer`; dismiss = `defer`). Do NOT silently demote to `additive`.

A finding with `target_files: []` (e.g., a tech-watch never-run / stale finding) must NOT produce any op - it is report-only; surface in Step 6 only.

## Plan shape

```
{
  "run": "{run}",
  "ops": [
    {
      "kind": "edit" | "create" | "rename" | "split" | "merge" | "retire",
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

## What this step does NOT do

- Does NOT apply ops - that is `apply.md` (Step 4).
- Does NOT touch findings.json beyond reading it.
- Does NOT decide doc_only based on intent - it is mechanical: true iff every modified file is in `{README.md, apex-core.md, apex-core-overview.md, CLAUDE.md}`.
