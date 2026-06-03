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

Empty `clusters: []` -> "clean" (SKILL task 4 prints report path, exits 0; soft-skip tasks 5-8, task 9 still runs to capture private-tracked-root deltas).

## Drift kinds

Eight **structural** kinds are detected deterministically by `scripts/audit-detectors.py --mode audit` - the shared engine `polish-check.sh` also runs, so audit and polish cannot diverge. The engine's module docstring + per-detector functions are the source of truth for the exact rules; the slug `id` is what the `--prior-drift` diff and evolve.md's cluster->op table key on:

| Kind (slug id) | Flags |
|------|---------|
| `oversized-files` (`oversized`) | skills/agents `.md` over its per-role content budget (resolved by `cap_for` from `skills/apex/scripts/content-budget.json`: 2500 default, higher for orchestrator-core / hot-path-heavy files; line count informational), scripts >500 lines OR longest line >120 chars, central-prose docs (apex-core/overview/README/CLAUDE) >11400 words. Audit-only - never run post-apply. |
| `orphan-refs` (`orphan`) | Spec-doc path ref that resolves to neither an inventory entry nor a real on-disk file (bare-`scripts/X` shorthand, glob, trailing-slash dir refs, and refs to committed-but-untracked artifacts like `scripts/fixtures/*.jsonl` excepted - the gate flags dead references, not inventory-membership gaps). |
| `missing-refs` (`missing`) | Inventory file referenced by zero spec doc (intra-skill, cross-apex-skill, and parent-dir/glob refs count as covered; `SKILL.md` / `_`-prefixed / `__pycache__` excluded). |
| `schema-mismatch` (`schema`) | `schemas[]` entry where `id != basename(path)`. |
| `dead-hook` (`dead-hook`) | `hooks[]` command referencing a script absent on disk. |
| `approaching-budget` (`approaching`) | skills/agents `.md` within the near-cap band (`near_cap_ratio * cap < words <= cap`; default 85%), EXCLUDING paths in `near_cap_exempt` (plan-pinned dense files whose tier was set at current+~10% headroom - they sit permanently in-band so the WARN would be every-run noise; currently empty). WARN only - never blocks; routed to `defer` at the gate as standing leanness pressure below the hard oversized cap. Fires in `--mode polish` too (escalated, not blocking). |
| `hash-roster` (`hash-roster`) | Runtime-loaded docs (the `content-budget.json` `hash_roster.docs` list) carrying inline 8-hex reflector/session citations above `hash_roster.ceiling` (default 0; matcher counts keyword-led or rostered hashes, ignores isolated non-citation hex). Re-bloat guard: once the session-hash rosters are stripped, new guards cite a cluster slug or nothing - the deterministic backstop for that discipline. WARN-class at the gate (strip = `edit` op, or `defer`). Fires in `--mode polish` too (NEW-only diff: a doc that newly breaches the ceiling). |
| `negative-scope` (`negative-scope`) | Any skills/agents/spec `.md` (whole inventory, no roster needed) carrying a negative-scope disclaimer: a dedicated `What X does NOT do` / `Out of scope` / `Non-goals` section heading, or a third-person `Does NOT ...` / `Doesn't ...` scope-disclaimer bullet. The other half of the `apex-core.md` Lean-prose re-bloat guard (hash-roster covers inline hashes). Anchored zero-false-positive patterns - imperative operational rules (`Do not run X`, `never blind-edit`) and the banned phrases quoted inside prose do NOT match. WARN-class at the gate (strip the disclaimer = `edit` op, or `defer`). Fires in `--mode polish` too (NEW-only diff: a doc that newly grows a disclaimer). |

Two **judgment** kinds stay LLM-owned here (NOT in the engine), merged AFTER the structural clusters via `--extra-clusters`:

| Kind | Detector |
|------|---------|
| `stale-spec` | A script in the inventory `scripts[]` at task 2 but GONE on disk at task 3 read time (race / mid-flight rename). Hard-stop cluster - SKILL task 4 downgrades to audit-only. A task-2-vs-task-3 race check, not a pure inventory function, so it stays prose. Almost always empty. |
| `user-driven` | Reads `{run}-user-concern.md` (SKILL task 1, from `$ARGUMENTS` or AskUserQuestion fallback). Present + non-blank -> one cluster: `summary` = first non-blank line (trunc 240); `items` = `skills/` / `agents/` / `scripts/` / `apex-core*.md` / `README.md` / `CLAUDE.md` paths grep'd from the body (rstrip `.,;:)`'\"`, deduped in doc order). **Slash-command fallback**: empty path grep -> grep `/[a-z][a-z0-9-]+` tokens, resolve each to `skills/<name>/SKILL.md` when it exists. **Named-file resolution**: still empty AND the body names a file that EXISTS on disk but sits outside the grep prefixes above (e.g. a plan under `tmp/`, a design doc) -> READ that file and resolve concrete in-tree targets from its content (e.g. a plan's "Phase N targets") before falling through - the one user-driven sub-step with genuine non-determinism, so an inline `Read` / small agent step is in-scope. If the named file is a multi-phase plan and the concern picks no phase (a bare `continue`), targets are ambiguous: surface the phase choice at the SKILL task-1 concern prompt / task-4 gate rather than guessing. Empty `items` (no path token, no slash-command, no resolvable named file) -> set `source_block_token = {run}` so evolve task 5's placeholder carries a back-ref. No file = no cluster. |
| `semantic-drift` (A3) | LLM judgment greps cannot reach: spec prose contradicting a script's actual flags/behavior, cross-doc contradiction (two docs describing the same thing differently), or behavior a SKILL.md claims to invoke that is absent from its scripts. Runs ONLY when SKILL task 1's semantic-drift toggle = `run` (opt-in; offered only in `audit+apply`, default `skip` - the expensive fan-out is off on a normal session) via a per-skill-unit Workflow fan-out - see **Semantic-drift fan-out** below. Each finding cites `spec_ref` + `code_ref` + `confidence`; high -> cluster `items`, low -> `defer` (logged, never auto-applied). Open risk 4: gated to the interactive apply path, never a silent cron path. |

## Procedure

1. **Read inventory**; validate it parses as JSON. If not, abort with explicit error (do NOT emit empty clusters - that masks state corruption).
2. **Compute the judgment clusters** (prose; the engine does not): `stale-spec` (for each `scripts[].path`, `test -e`; vanished -> hard-stop cluster), `user-driven` (per the row above - when the literal-token + slash-command greps come up empty, run the row's Named-file resolution before emitting `items: []`), and - when SKILL task 1's semantic-drift toggle = `run` - `semantic-drift` (see **Semantic-drift fan-out** below). Write the 0-3 clusters as a JSON array to `.claude-tmp/admin-apex-active/{run}-extra-clusters.json` (`[]` when none).
3. **Run the engine** (it appends the judgment clusters after the structural ones, writes the report, exits 0 - drift is normal, the gate decides):
   ```
   python3 skills/admin-apex/scripts/audit-detectors.py --inventory "$inv" --mode audit --run {run} \
     --extra-clusters .claude-tmp/admin-apex-active/{run}-extra-clusters.json \
     --out .claude-tmp/admin-apex-active/{run}-drift-report.json
   ```
4. **Print the report path** to stdout so the SKILL gate (task 4) can present it.

## Semantic-drift fan-out (A3)

Computed in step 2 ONLY when SKILL task 1's semantic-drift toggle = `run` (the toggle is offered only after an `audit+apply` mode select and defaults to `skip`; never `audit-only`, never a silent cron path - Open risk 4). Build one drift-check **unit** per skill: `{name, files}` where `files` = the skill's `SKILL.md` + every script under its `scripts/` dir (from inventory `scripts[]`), plus one cross-doc unit `{name: "core-docs", files: ["apex-core.md", "apex-core-overview.md"]}`.

**Opt-in (skill-instructs-Workflow trigger - apex, not a human, is the caller).** When the Workflow tool is reachable, dispatch `scripts/semantic-drift.workflow.js` via an ABSOLUTE `scriptPath` (`$HOME/.claude/skills/admin-apex/scripts/semantic-drift.workflow.js`) with `args = { units, maxFleet: 16 }`. It fans out one `agentType:'Explore'` agent per unit (fleet cap 16; overflow returned in `dropped`), schema-validates each return, and returns `{findings, unitsChecked, dropped}`. No interactive gate sits inside the fan-out (the gate is task 4, after the barrier).

**Workflow-absent fallback (headless/cron).** Dispatch the SAME per-unit `Explore` agents in a single response (read each unit's files, identical prompt + schema) - degrade silently, never block on Workflow being unreachable. Produces identical findings.

**Map findings -> cluster.** Process any `dropped` units serially and fold their findings in. Partition by `confidence`: high-confidence findings become the `semantic-drift` cluster `items` (each `"<spec_ref> <-> <code_ref>: <summary>"`); low-confidence findings go to the cluster `_meta.deferred` and are routed to `defer` at the gate (logged, never auto-applied). Append the cluster to `{run}-extra-clusters.json` only when `items` is non-empty.

## Gate (SKILL task 4)

The orchestrator owns the AskUserQuestion. Per cluster: `keep` (ignore this run), `apply` (items become candidate evolve ops), `defer` (like keep but logged for next run). Empty clusters -> "audit clean" + exit 0. All `keep`/`defer` -> soft-skip (skip 5-8; task 9 still runs per SKILL.md task 4), exit 0.

## Audit-only mode

When SKILL task 1 selects `audit-only`, task 3 still runs but the gate prints the report and exits before evolve. No mutation, no VERSION bump, no commit.

## Audit vs polish (same engine)

`polish-check.sh` is the post-apply mirror - SAME engine, `--mode polish` (relabeled staleness/unused/inconsistency), diffing `{run}-drift-report.json` so only NEW drift surfaces. audit fires PRE-apply (task 3); polish fires POST-apply (sync-docs.md step 6 + apex-improve/finalize.md step 5a). The gate (SKILL task 4) decides what to apply; reflector-log consumption lives in `/apex-improve`.

## Lean rule

The per-role content budget (`skills/apex/scripts/content-budget.json`; 2500 default) applies to `skills/apex/*.md` AND `skills/admin-apex/*.md`. If audit.md / evolve.md / sync-docs.md grow past their budget they surface in `oversized-files` like any other (and in `approaching-budget` once past 85%). See `apex-core.md` Conventions for safety paths + JSON validation; admin-apex follows the same rules on its own `.claude-tmp/admin-apex-active/` tree.
