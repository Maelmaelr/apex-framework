---
name: audit
description: Read-only drift detection for the apex framework. Consumes {run}-inventory.json (from inventory-apex.sh) and emits {run}-drift-report.json clustered by drift kind. Pure read - never mutates files.
---

# audit (admin-apex task 3)

Spec: `skills/admin-apex/SKILL.md` task 3 (audit drift) | task 4 (audit gate).

## Inputs

- `.claude-tmp/admin-apex-active/{run}-inventory.json` (written at task 2 by `scripts/inventory-apex.sh`, conforming to `schemas/inventory.schema.json`)

## Output

`.claude-tmp/admin-apex-active/{run}-drift-report.json` - JSON object:

```
{
  "run": "<8-hex>",
  "clusters": [
    {
      "id": "<short-slug>",
      "kind": "oversized-files | orphan-refs | missing-refs | stale-spec | schema-mismatch | dead-hook",
      "items": [ "<repo-relative path or descriptor>", ... ],
      "summary": "<one-line human description>"
    }, ...
  ],
  "_meta": { "generated_at": "<iso>" }
}
```

Empty `clusters: []` -> "clean" outcome (SKILL task 4 prints report path and exits 0; tasks 5-9 skipped).

## Drift kinds

| Kind | Detector |
|------|---------|
| `oversized-files` | Any inventory entry (skills, agents, scripts, spec_docs) with `lines > 500` OR (skills/agents/admin-apex sub-skills with `lines > 150`). Continuous-prose docs (apex-core.md, apex-core-overview.md, README.md, CLAUDE.md) only flagged at >800 lines. |
| `orphan-refs` | Spec docs (apex-core.md, apex-core-overview.md, README.md, CLAUDE.md) reference a `skills/apex/...` / `agents/...` / `scripts/...` path NOT present in the inventory. Detected by extracting `\b(skills/apex/[^ \t\n\)\`]+\|agents/[^ \t\n\)\`]+\|scripts/[^ \t\n\)\`]+)` substrings via grep on each spec doc, then set-differencing against the inventory. |
| `missing-refs` | Inventory file present but appears in zero spec docs (best-effort: filename basename grep across spec_docs[]). Excluded: `__pycache__`, files starting with `_` (private helpers), `SKILL.md` itself. |
| `stale-spec` | A spec doc names a file under skills/apex/scripts that did exist in the inventory at task 2 but does NOT exist on disk at task 3 read time (i.e., race / mid-flight rename). Flagged as a hard-stop cluster - SKILL gate downgrades to audit-only. |
| `schema-mismatch` | Inventory `schemas[]` entry where `id != basename(path)`. The `$id == filename` rule (per shared-guardrails / apex-core JSON Schema validation) is non-negotiable. |
| `dead-hook` | Inventory `hooks[]` entry whose `command` references a script path that does not exist on disk. Use `${CLAUDE_PROJECT_DIR}` substitution (resolves to repo root) when checking existence. |

## Procedure

1. **Read inventory**:
   ```
   inv=".claude-tmp/admin-apex-active/{run}-inventory.json"
   ```
   Validate it parses as JSON. If not, abort with explicit error - do NOT silently produce an empty cluster list (that would mask state corruption).

2. **Run each detector** in declaration order; collect non-empty clusters into `clusters[]`. Each cluster gets a short slug id (`oversized`, `orphan`, `missing`, `stale`, `schema`, `dead-hook`) plus a human one-liner.

3. **For orphan-refs and missing-refs**: use `scripts/grep-apex-refs.sh <basename>` to count cross-references. Treat zero hits in spec_docs[] as "missing". Treat any hit pointing at a path not in inventory as "orphan".

4. **Write the drift report** at `.claude-tmp/admin-apex-active/{run}-drift-report.json`. Pretty-printed JSON (2-space indent), matching the shape above.

5. **Print the report path to stdout** so the SKILL gate (task 4) can present it via AskUserQuestion.

## Gate (SKILL task 4)

The orchestrator owns the AskUserQuestion. For each cluster, options are `keep | apply | defer`:

- `keep`: cluster ignored this run; not added to evolve plan.
- `apply`: cluster's items become candidate evolve ops.
- `defer`: like `keep` but logged for the next run.

Empty clusters list -> SKILL prints "audit clean" + report path, exits 0 (no commit).

All clusters set to `keep`/`defer` -> treated as audit-only outcome (skip 5-9, exit 0).

## Audit-only mode

When SKILL task 1 selects `audit-only`, this skill still runs (task 3) but the gate at task 4 prints the report and exits before evolve. No mutation, no VERSION bump, no commit.

## What this skill does NOT do

- Does NOT mutate any file (no Edit / Write to anything except the drift-report JSON under `.claude-tmp/admin-apex-active/`).
- Does NOT decide what to apply - the gate (SKILL task 4) does.
- Does NOT consume the reflector log (`apex-workflow-improvements.md`); that is the future `/apex-improve` workflow.
- Does NOT cross into project app code; apex-internal only.

## Lean rule

This skill audits oversized files in apex AND in admin-apex itself (the >150-line cap applies to both `skills/apex/*.md` and `skills/admin-apex/*.md`). If audit.md or evolve.md or sync-docs.md grow past 150 lines, they show up in `oversized-files` like any other.

See `skills/apex/shared-guardrails.md` for safety paths and JSON validation conventions; admin-apex follows the same rules but operates on its own `.claude-tmp/admin-apex-active/` artifact tree.
