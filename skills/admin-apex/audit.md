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
      "kind": "oversized-files | orphan-refs | missing-refs | stale-spec | schema-mismatch | dead-hook | user-driven",
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
| `oversized-files` | Any inventory entry (`skills[]`, `agents[]`, `scripts[]`, `spec_docs[]`) with `lines > 500` OR any `skills[]` / `agents[]` entry with `lines > 150` (covers apex sub-skills, sibling apex-* skills, admin-apex sub-skills, and all agents - Principle 3: prevent silent framework bloat). Continuous-prose docs (apex-core.md, apex-core-overview.md, README.md, CLAUDE.md) only flagged at >800 lines. |
| `orphan-refs` | Spec docs (apex-core.md, apex-core-overview.md, README.md, CLAUDE.md) reference a `skills/apex/...` / `skills/admin-apex/...` / `agents/...` / `scripts/...` path NOT present in the inventory. Detected by extracting `\b(skills/apex/[^ \t\n\)\`]+\|skills/admin-apex/[^ \t\n\)\`]+\|agents/[^ \t\n\)\`]+\|scripts/[^ \t\n\)\`]+)` substrings via grep on each spec doc, then set-differencing against the inventory. The `skills/admin-apex/` alternative is what makes admin-apex paths participate in drift detection (Self-coverage per SKILL.md). **Bare-`scripts/X` shorthand exception**: matches whose first path segment is exactly `scripts/` (i.e., NOT `skills/apex/scripts/...` or `skills/admin-apex/scripts/...`) are shorthand used in apex-core.md / apex-core-overview.md prose for "the script lives under one of the apex script dirs". Treat the shorthand as covered if EITHER `skills/apex/<match>` OR `skills/admin-apex/<match>` is present in inventory; only flag as orphan when neither full path exists. **Glob-pattern exception**: captured paths containing `*` or `?` are prose-level path families (e.g., `skills/apex/schemas/*.schema.json`, `skills/apex/*.md`, `skills/apex/scripts/*`); skip them from orphan flagging - they cover their directory by inventory expansion. **Trailing-slash dir-ref exception**: captured paths ending in `/` (e.g., `skills/apex/schemas/`, `skills/admin-apex/schemas/`) are prose-level dir references and are treated identically to glob patterns - skip them from orphan flagging. They cover the directory by inventory expansion. |
| `missing-refs` | Inventory file present but appears in zero spec docs (best-effort: filename basename grep across spec_docs[]; wildcard / parent-dir refs in specs like `skills/X/schemas/*.schema.json` or `skills/X/schemas/` count as covering all files in that directory). A non-`SKILL.md` file under `skills/<X>/` (sub-skill OR script under `skills/<X>/scripts/`) is treated as intra-skill-covered when referenced from any sibling under the same `skills/<X>/` root (intra-skill helpers don't need spec-doc references; e.g., `grep-apex-refs.sh` referenced from `skills/admin-apex/audit.md` is covered). **Cross-apex-skill exception**: a file under `skills/apex/` referenced from any sibling apex skill (`skills/apex-*/`, e.g., `lesson-dedup.py` referenced from `skills/apex-lessons/consolidate.md`) is also treated as covered. The apex hot-path scripts under `skills/apex/scripts/` are intentionally shared across `apex-*` siblings; cross-skill references count toward coverage just like intra-skill ones. Excluded: `__pycache__`, files starting with `_` (private helpers), `SKILL.md` itself. |
| `stale-spec` | A spec doc names a file under skills/apex/scripts that did exist in the inventory at task 2 but does NOT exist on disk at task 3 read time (i.e., race / mid-flight rename). Flagged as a hard-stop cluster - SKILL gate downgrades to audit-only. |
| `schema-mismatch` | Inventory `schemas[]` entry where `id != basename(path)`. The `$id == filename` rule (per apex-core.md Conventions / JSON Schema validation) is non-negotiable. |
| `dead-hook` | Inventory `hooks[]` entry whose `command` references a script path that does not exist on disk. Use `${CLAUDE_PROJECT_DIR}` substitution (resolves to repo root) when checking existence. |
| `user-driven` | Reads `.claude-tmp/admin-apex-active/{run}-user-concern.md` written by SKILL task 1 (sourced from `$ARGUMENTS` or an AskUserQuestion fallback). If the file is present and non-blank, emits a single cluster with `summary` = first non-blank line and `items` = repo-relative `skills/...` / `agents/...` / `scripts/...` / `apex-core*.md` / `README.md` / `CLAUDE.md` paths grep'd from the body (de-duplicated, in document order). No file = no cluster. This is the user-supplied channel - it sits alongside the structural detectors so user concerns flow through the same gate (keep / apply / defer) instead of needing a manual override of task 4's soft-skip. |

## Procedure

1. **Read inventory**:
   ```
   inv=".claude-tmp/admin-apex-active/{run}-inventory.json"
   ```
   Validate it parses as JSON. If not, abort with explicit error - do NOT silently produce an empty cluster list (that would mask state corruption).

2. **Run each detector** in declaration order; collect non-empty clusters into `clusters[]`. Each cluster gets a short slug id (`oversized`, `orphan`, `missing`, `stale`, `schema`, `dead-hook`, `user-driven`) plus a human one-liner.

   For `user-driven`: read `.claude-tmp/admin-apex-active/{run}-user-concern.md`. If the file is missing or blank (only whitespace), skip - emit no cluster. Otherwise: `summary` = first non-blank line (truncated at 240 chars); `items` = `grep -oE '\b(skills/[^\s\)\`]+|agents/[^\s\)\`]+|scripts/[^\s\)\`]+|apex-core[^\s\)\`]*\.md|README\.md|CLAUDE\.md)' <file>` rstripped of `.,;:)`'\"` and de-duplicated in document order. Empty items list is allowed (the concern is informational); evolve.md task 5 will then translate it to a single `edit` op against `skills/admin-apex/SKILL.md` as a placeholder for the planner to redirect.

3. **Pre-compute spec-doc coverage map ONCE** (single `scripts/grep-apex-refs.sh` sweep over inventory basenames against spec_docs[]); orphan-refs and missing-refs both consume it - never re-grep per detector. Treat zero hits as "missing"; any hit pointing at a path not in inventory as "orphan".

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
- Does NOT run the post-implementation check; `scripts/polish-check.sh` is the post-apply mirror of this skill (orphan-refs / missing-refs / schema-mismatch / dead-hook). audit.md fires PRE-apply at SKILL task 3; polish-check.sh fires POST-apply at sync-docs.md step 6 (admin-apex) and apex-improve/finalize.md step 5a, diffing against this skill's `{run}-drift-report.json` so only NEW drift surfaces.

## Lean rule

This skill audits oversized files in apex AND in admin-apex itself (the >150-line cap applies to both `skills/apex/*.md` and `skills/admin-apex/*.md`). If audit.md or evolve.md or sync-docs.md grow past 150 lines, they show up in `oversized-files` like any other.

See `apex-core.md` Conventions for safety paths and JSON validation conventions; admin-apex follows the same rules but operates on its own `.claude-tmp/admin-apex-active/` artifact tree.
