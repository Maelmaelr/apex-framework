---
name: apply
description: apex-improve Step 4 - op application. Step 4a applies semantic / replace ops via inline Edit (preferred). Step 4b delegates structural ops to admin-apex/evolve.md task 6. Appends to {run}-applied-ops.json + {run}-dirty-paths.txt with actual delta_lines per op.
---

# apply (apex-improve Step 4)

Spec: `skills/apex-improve/SKILL.md` Step 4.

## Inputs

- `.claude-tmp/admin-apex-active/{run}-evolve-plan.json` (from `plan.md`)

## Outputs

- `.claude-tmp/admin-apex-active/{run}-applied-ops.json` - JSON array of applied-op outcome entries `{plan_op_index: N, status: "applied", delta_lines: <int|null>, dirty_paths: [...]}` that reference the plan op by index; do NOT restate `kind` / `target` / `rationale` verbatim (the plan is authoritative - same shape as evolve.md task 6). `delta_lines` computed post-edit.
- `.claude-tmp/admin-apex-active/{run}-dirty-paths.txt` - one repo-relative path per line; appended after each successful op

## Step 4 pre-flight: pre-apply baseline drift report

Before applying ANY op, snapshot the pre-apply drift state so Step 5a `polish-check.sh` diffs against a real baseline and surfaces only NET-NEW drift. apex-improve skips the admin-apex audit, so without this `{run}-drift-report.json` is absent, `audit-detectors.py --prior-drift` treats the baseline as empty, and every standing approaching-budget file mis-reports as "introduced by apply" even when the apply was net-negative (a -2-word edit to a near-cap file otherwise surfaces as 4 "new" approaching-budget clusters).

```
bash skills/admin-apex/scripts/inventory-apex.sh --out .claude-tmp/admin-apex-active/{run}-inventory.json >/dev/null
python3 skills/admin-apex/scripts/audit-detectors.py \
  --inventory .claude-tmp/admin-apex-active/{run}-inventory.json --mode audit --run {run} \
  --out .claude-tmp/admin-apex-active/{run}-drift-report.json
```

This is the same `inventory-apex.sh` + `audit-detectors.py --mode audit` invocation admin-apex/audit.md task 3 runs pre-apply; the inventory it writes is the one Step 4b's structural path also consumes.

## Step 4a: Semantic / replace ops - inline Edit

For each `op.kind == edit` operation:

1. Read the target file (full).
2. Apply the edit via the Edit tool. Use `replace_all` only when the rename is unambiguous across the file (e.g., a renamed symbol).
3. Re-read the target file; compute actual `delta_lines = new_total - old_total`.
4. Append an outcome entry `{plan_op_index: N, status: "applied", delta_lines: <computed>, dirty_paths: [<target>]}` to `{run}-applied-ops.json` - reference the plan op by index, do NOT restate `kind` / `target` / `rationale` (matches evolve.md task 6 so Step 4b's structural ops produce the same shape).
5. Append the target path to `{run}-dirty-paths.txt`.

**Dangling-ref pre-flight (multi-Edit batches on same file)**: when two or more ops in this run target the same file, OR a single op deletes a variable/function/path-definition that other parts of the file may rely on, after the final Edit re-read the file and grep for tokens that were just removed (variable names, function names, file paths). Any surviving reference to a now-undefined name is a dangling ref - apply a follow-on Edit before moving on. Example: a Step 2 collapse deletes a bash variable definition while a later step still references `$scope_path` until a follow-on Edit fixes it. Discipline check, not tooling - the cost of one extra grep is much lower than the cost of shipping a broken contract.

If an Edit tool call fails (string not found, ambiguous match), surface AskUserQuestion (header: "Edit failure on op {N}"; options: `retry-with-context | skip-finding | abort-run`; dismiss = `abort-run`). Never silently move on.

## Lean-prose discipline (always-on)

Apply edits per apex-core.md Conventions **Lean prose**. When promoting a reflector-log finding into a guard / rule in a runtime-loaded doc (`skills/apex*/**`, `skills/admin-apex/**`, `agents/**`) or the mirrored central spec `apex-core.md`, state the rule positively and keep it lean: do NOT add a `What X does NOT do` / `Out of scope` disclaimer section, a scope-negative bullet, or an incident-narrative justification (the bug story behind the rule). Cite the cluster slug or nothing - NEVER inline the raw 8-hex session hash. The RULE is the payload; the originating hash + incident are audit trail that git history + the timestamped `tmp/improvements-archive/` snapshots already preserve. This is UNCONDITIONAL - it holds below 85% of tier, not only on the near-cap tightening path: `SKILL.md` Principle 3 and `plan.md`'s near-cap discipline govern only the >85% band, but noise accretes on the climb UP to the cap where sub-85% new-guard prose had no governance. Two `audit-detectors.py` detectors enforce this deterministically at audit + polish (Step 5a): `hash-roster` (ceiling + doc list in `content-budget.json` -> `hash_roster`) trips on a re-introduced inline session hash, and `negative-scope` trips on a re-added `What X does NOT do` / `Out of scope` section or a third-person `Does NOT ...` bullet across any skills/agents/spec doc.

## Step 4b: Structural ops - delegate to admin-apex/evolve.md

For any operation in `{create, rename, split, merge, retire, schema-add, schema-remove, hook-add, hook-remove}`:

1. **Read and follow** `~/.claude/skills/admin-apex/evolve.md` from its `## Task 6` heading onward ("Apply ops") - skip `## Task 5` (lines above the Task 6 heading): apex-improve's `plan.md` already composed the plan, so the ~38-line Task 5 plan-compose block is dead weight here; reading the whole file pulls it for nothing. Inputs are already in place: `{run}-evolve-plan.json` (Step 3 wrote it; same schema).
2. The Step-4 pre-flight (above) already wrote `{run}-inventory.json`; evolve.md task 6 reads it for re-snapshot drift detection. (Re-run `inventory-apex.sh --out` only if it is somehow absent.)
3. evolve.md handles per-op re-snapshot, applies via Edit / Write / Bash with `grep-apex-refs.sh` ref-rewriting, appends to `{run}-applied-ops.json` + `{run}-dirty-paths.txt`.
4. Mid-flight drift -> evolve.md surfaces `restart | commit-partial | rollback`. apex-improve maps:
   - `restart` -> exit cleanly; let user re-invoke (no truncation, no commit).
   - `commit-partial` -> proceed to Step 5 with ops-so-far.
   - `rollback` -> evolve.md handles `git restore` on dirty paths + exits.

Skip the admin-apex audit (tasks 2-4) entirely - the plan came from session-reflection signals, not drift. evolve.md task 6 does NOT depend on having `{run}-drift-report.json` on disk; it reads only the plan + the inventory.

## File-health gate

If a Step 4a semantic edit would push the target past its file-health budget (docs: its per-role content-budget tier in `skills/apex/scripts/content-budget.json`; scripts: >400-500 lines or any line >120 chars), the file-health PreToolUse hook fires (shrinking / neutral edits and new files always pass). apex-improve MUST AskUserQuestion (header: "file-health gate"; options: `split-now | reduce-edit | abort`; dismiss = `abort`). NEVER bypass the hook - same gate every apex skill respects. This reactive hard-hook (100% of tier) is the backstop to the PROACTIVE near-cap rule in `plan.md` (net-neutral-or-negative once a file passes 85% of its tier) and Principle 3's near-cap tightening in `SKILL.md` - read the three together, not in isolation.

## Cap-reached / no-progress abort

If after iterating every op in the plan, **zero** ops were applied (every Step 4a Edit failed AND every Step 4b structural op hit drift -> rollback / restart), still proceed to Step 5 (archive + truncate + stamp + minimal report) and skip Steps 7-8. Signals were *seen* by analyze + plan - the failure was in apply, not the signal track - so consumed inputs reset normally; deferred findings live on in `{run}-deferred-findings.json` (preserved across SessionEnd by `cleanup-run.sh`) for the next run. Exit message: `apex-improve: 0 ops applied; consumed signals archived, deferred preserved`.

Commit + mirror + push live in Steps 7-8 (`sync-git.md`); the structural-vs-semantic op decision lives in `plan.md`. Step 5 here is archive + version-stamp cleanup, not git.
