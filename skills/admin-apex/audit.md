---
name: audit
description: Read-only drift detection for the apex framework. Consumes {run}-inventory.json (from inventory-apex.sh) and emits {run}-drift-report.json clustered by drift kind. Structural detectors run via scripts/audit-detectors.py (shared with polish-check.sh); stale-spec + user-driven stay LLM-owned. Pure read - never mutates files.
---

# audit (admin-apex task 3)

Spec: `skills/admin-apex/SKILL.md` task 3 (audit drift) | task 4 (audit gate).

## Input

`.claude-tmp/admin-apex-active/{run}-inventory.json` (written at task 2 by `scripts/inventory-apex.sh`, per `schemas/inventory.schema.json`).

## Output

`.claude-tmp/admin-apex-active/{run}-drift-report.json`:

```
{
  "run": "<8-hex>",
  "clusters": [
    { "id": "<slug>", "kind": "<see below>", "items": [ "<path|descriptor>", ... ],
      "source_block_token": "<run-or-block-id>", "summary": "<one-liner>" }, ...
  ],
  "_meta": { "generated_at": "<iso>" }
}
```

Empty `clusters: []` -> "clean" (SKILL task 4 prints report path, exits 0; tasks 5-9 skipped).

## Drift kinds

Five **structural** kinds are detected deterministically by `scripts/audit-detectors.py --mode audit` - the shared engine `polish-check.sh` also runs, so audit and polish cannot diverge. The engine's module docstring + per-detector functions are the source of truth for the exact rules; the slug `id` is what the `--prior-drift` diff and evolve.md's cluster->op table key on:

| Kind (slug id) | Flags |
|------|---------|
| `oversized-files` (`oversized`) | skills/agents `.md` > 150 lines, scripts > 500, prose docs (apex-core/overview/README/CLAUDE) > 800. Audit-only - never run post-apply. |
| `orphan-refs` (`orphan`) | Spec-doc path ref absent from inventory (bare-`scripts/X` shorthand, glob, trailing-slash dir refs excepted). |
| `missing-refs` (`missing`) | Inventory file referenced by zero spec doc (intra-skill, cross-apex-skill, and parent-dir/glob refs count as covered; `SKILL.md` / `_`-prefixed / `__pycache__` excluded). |
| `schema-mismatch` (`schema`) | `schemas[]` entry where `id != basename(path)`. |
| `dead-hook` (`dead-hook`) | `hooks[]` command referencing a script absent on disk. |

Two **judgment** kinds stay LLM-owned here (NOT in the engine), merged AFTER the structural clusters via `--extra-clusters`:

| Kind | Detector |
|------|---------|
| `stale-spec` | A file that existed in the inventory at task 2 but is GONE on disk at task 3 read time (race / mid-flight rename). Hard-stop cluster - SKILL task 4 downgrades to audit-only. A task-2-vs-task-3 race check, not a pure inventory function, so it stays prose. Almost always empty. |
| `user-driven` | Reads `{run}-user-concern.md` (SKILL task 1, from `$ARGUMENTS` or AskUserQuestion fallback). Present + non-blank -> one cluster: `summary` = first non-blank line (trunc 240); `items` = `skills/` / `agents/` / `scripts/` / `apex-core*.md` / `README.md` / `CLAUDE.md` paths grep'd from the body (rstrip `.,;:)`'\"`, deduped in doc order). **Slash-command fallback**: empty path grep -> grep `/[a-z][a-z0-9-]+` tokens, resolve each to `skills/<name>/SKILL.md` when it exists (reflector 8d961553). **Named-file resolution (A2)**: still empty AND the body names a file that EXISTS on disk but sits outside the grep prefixes above (e.g. a plan under `tmp/`, a design doc) -> READ that file and resolve concrete in-tree targets from its content (e.g. a plan's "Phase N targets") before falling through - the one user-driven sub-step with genuine non-determinism, so an inline `Read` / small agent step is in-scope. If the named file is a multi-phase plan and the concern picks no phase (a bare `continue`), targets are ambiguous: surface the phase choice at the SKILL task-1 concern prompt / task-4 gate rather than guessing (workflow-adoption plan A2). Empty `items` (no path token, no slash-command, no resolvable named file) -> set `source_block_token = {run}` so evolve task 5's placeholder carries a back-ref (reflector 03d9a286). No file = no cluster. |
| `semantic-drift` (A3) | LLM judgment greps cannot reach: spec prose contradicting a script's actual flags/behavior, cross-doc contradiction (two docs describing the same thing differently), or behavior a SKILL.md claims to invoke that is absent from its scripts. Runs ONLY in `audit+apply` mode via a per-skill-unit Workflow fan-out - see **Semantic-drift fan-out** below. Each finding cites `spec_ref` + `code_ref` + `confidence`; high -> cluster `items`, low -> `defer` (logged, never auto-applied). Open risk 4: gated to the interactive apply path, never a silent cron path. |

## Procedure

1. **Read inventory**; validate it parses as JSON. If not, abort with explicit error (do NOT emit empty clusters - that masks state corruption).
2. **Compute the judgment clusters** (prose; the engine does not): `stale-spec` (for each `scripts[].path`, `test -e`; vanished -> hard-stop cluster), `user-driven` (per the row above - when the literal-token + slash-command greps come up empty, run the row's Named-file resolution before emitting `items: []`), and - in `audit+apply` mode only - `semantic-drift` (see **Semantic-drift fan-out** below). Write the 0-3 clusters as a JSON array to `.claude-tmp/admin-apex-active/{run}-extra-clusters.json` (`[]` when none).
3. **Run the engine** (it appends the judgment clusters after the structural ones, writes the report, exits 0 - drift is normal, the gate decides):
   ```
   python3 scripts/audit-detectors.py --inventory "$inv" --mode audit --run {run} \
     --extra-clusters .claude-tmp/admin-apex-active/{run}-extra-clusters.json \
     --out .claude-tmp/admin-apex-active/{run}-drift-report.json
   ```
4. **Print the report path** to stdout so the SKILL gate (task 4) can present it.

## Semantic-drift fan-out (A3)

Computed in step 2 ONLY when SKILL task 1 selected `audit+apply` (never `audit-only`, never a silent cron path - Open risk 4). Build one drift-check **unit** per skill: `{name, files}` where `files` = the skill's `SKILL.md` + every script under its `scripts/` dir (from inventory `scripts[]`), plus one cross-doc unit `{name: "core-docs", files: ["apex-core.md", "apex-core-overview.md"]}`.

**Opt-in (skill-instructs-Workflow trigger - apex, not a human, is the caller).** When the Workflow tool is reachable, dispatch `scripts/semantic-drift.workflow.js` via an ABSOLUTE `scriptPath` (`$HOME/.claude/skills/admin-apex/scripts/semantic-drift.workflow.js`) with `args = { units, maxFleet: 16 }`. It fans out one `agentType:'Explore'` agent per unit (fleet cap 16; overflow returned in `dropped`), schema-validates each return, and returns `{findings, unitsChecked, dropped}`. No interactive gate sits inside the fan-out (the gate is task 4, after the barrier).

**Workflow-absent fallback (headless/cron).** Dispatch the SAME per-unit `Explore` agents in a single response (read each unit's files, identical prompt + schema) - degrade silently, never block on Workflow being unreachable. Produces identical findings.

**Map findings -> cluster.** Process any `dropped` units serially and fold their findings in. Partition by `confidence`: high-confidence findings become the `semantic-drift` cluster `items` (each `"<spec_ref> <-> <code_ref>: <summary>"`); low-confidence findings go to the cluster `_meta.deferred` and are routed to `defer` at the gate (logged, never auto-applied). Append the cluster to `{run}-extra-clusters.json` only when `items` is non-empty.

## Gate (SKILL task 4)

The orchestrator owns the AskUserQuestion. Per cluster: `keep` (ignore this run), `apply` (items become candidate evolve ops), `defer` (like keep but logged for next run). Empty clusters -> "audit clean" + exit 0. All `keep`/`defer` -> audit-only outcome (skip 5-9, exit 0).

## Audit-only mode

When SKILL task 1 selects `audit-only`, task 3 still runs but the gate prints the report and exits before evolve. No mutation, no VERSION bump, no commit.

## What this skill does NOT do

- Does NOT mutate any file (only the drift-report + extra-clusters JSON under `.claude-tmp/admin-apex-active/`).
- Does NOT decide what to apply - the gate (SKILL task 4) does. Does NOT consume the reflector log (that is `/apex-improve`). Does NOT touch project app code.
- Does NOT run the post-apply check: `polish-check.sh` is the mirror - SAME engine, `--mode polish` (relabeled staleness/unused/inconsistency), diffing `{run}-drift-report.json` so only NEW drift surfaces. audit fires PRE-apply (task 3); polish fires POST-apply (sync-docs.md step 6 + apex-improve/finalize.md step 5a).

## Lean rule

The >150-line cap applies to `skills/apex/*.md` AND `skills/admin-apex/*.md`. If audit.md / evolve.md / sync-docs.md grow past 150 lines, they surface in `oversized-files` like any other. See `apex-core.md` Conventions for safety paths + JSON validation; admin-apex follows the same rules on its own `.claude-tmp/admin-apex-active/` tree.
