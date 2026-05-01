---
name: apply
description: apex-improve Step 4 - Phase 3 op application. Path A applies semantic / replace ops via inline Edit (preferred). Path B delegates structural ops to admin-apex/evolve.md task 6. Appends to {run}-applied-ops.json + {run}-dirty-paths.txt with actual delta_lines per op.
---

# apply (apex-improve Step 4)

Spec: `skills/apex-improve/SKILL.md` Step 4.

## Inputs

- `.claude-tmp/admin-apex-active/{run}-evolve-plan.json` (from `plan.md`)

## Outputs

- `.claude-tmp/admin-apex-active/{run}-applied-ops.json` - JSON array of applied ops (verbatim from plan) with **actual** `delta_lines` field per op (computed post-edit)
- `.claude-tmp/admin-apex-active/{run}-dirty-paths.txt` - one repo-relative path per line; appended after each successful op

## Path A: Semantic / replace ops -- inline Edit

For each `op.kind == edit` operation:

1. Read the target file (full).
2. Apply the edit via the Edit tool. Use `replace_all` only when the rename is unambiguous across the file (e.g., a renamed symbol).
3. Re-read the target file; compute actual `delta_lines = new_total - old_total`.
4. Append the operation (verbatim from the plan) to `{run}-applied-ops.json` with the **actual** `delta_lines` attached.
5. Append the target path to `{run}-dirty-paths.txt`.

If an Edit tool call fails (string not found, ambiguous match), surface AskUserQuestion (header: "Edit failure on op {N}"; options: `retry-with-context | skip-finding | abort-run`; dismiss = `abort-run`). Never silently move on.

## Path B: Structural ops -- delegate to admin-apex/evolve.md

For any operation in `{create, rename, split, merge, retire, schema-add, schema-remove, hook-add, hook-remove}`:

1. **Read and follow** `~/.claude/skills/admin-apex/evolve.md` task 6 ("Apply ops"). Inputs are already in place: `{run}-evolve-plan.json` (Step 3 wrote it; same schema).
2. If `{run}-inventory.json` is absent (apex-improve normally skips inventory; admin-apex flow always writes it), run `bash skills/admin-apex/scripts/inventory-apex.sh --out .claude-tmp/admin-apex-active/{run}-inventory.json` first - evolve.md task 6 reads it for re-snapshot drift detection.
3. evolve.md handles per-op re-snapshot, applies via Edit / Write / Bash with `grep-apex-refs.sh` ref-rewriting, appends to `{run}-applied-ops.json` + `{run}-dirty-paths.txt`.
4. Mid-flight drift -> evolve.md surfaces `restart | commit-partial | rollback`. apex-improve maps:
   - `restart` -> exit cleanly; let user re-invoke (no truncation, no commit).
   - `commit-partial` -> proceed to Step 5 with ops-so-far.
   - `rollback` -> evolve.md handles `git restore` on dirty paths + exits.

Skip the admin-apex audit (tasks 2-4) entirely - the plan came from session-reflection signals, not drift. evolve.md task 6 does NOT depend on having `{run}-drift-report.json` on disk; it reads only the plan + the inventory.

## File-health gate

If a Path A semantic edit would push the target past 400 lines (or 150 for `skills/*/SKILL.md` and `agents/*.md`), the file-health PreToolUse hook fires. apex-improve MUST AskUserQuestion (header: "file-health gate"; options: `split-now | reduce-edit | abort`; dismiss = `abort`). NEVER bypass the hook - same gate every apex skill respects.

## Cap-reached / no-progress abort

If after iterating every op in the plan, **zero** ops were applied (every Path A Edit failed AND every Path B structural op hit drift -> rollback / restart), exit with `apex-improve: 0 ops applied; signals preserved for next run`. Do NOT proceed to Step 5 (truncation would lose unconsumed signals). The next run gets the same inputs.

## What this step does NOT do

- Does NOT commit or push (Steps 7-8 own commit + mirror + push in standalone mode via `sync-git.md`; under apex-eod, the subagent prompt suppresses 7-8 and apex-eod step 5 commits inline). Step 5 here is just archive + version-stamp cleanup, not git.
- Does NOT mirror to public repo (Step 8 / `sync-git.md` does).
- Does NOT decide on its own that a structural op should be downgraded to semantic - that decision lives in `plan.md`.
- Does NOT bypass the file-health hook to make an oversized edit fit (Principle 3 again: if it doesn't fit, the finding belongs elsewhere).
