---
name: evolve
description: Owns mutation. Composes {run}-evolve-plan.json from gated drift clusters, then applies ops one at a time (create/rename/split/merge/retire/schema-add/schema-remove/hook-add/hook-remove). Re-snapshots inventory before each op; on mid-flight drift surfaces restart | commit-partial | rollback. Returns applied-ops.json + dirty-paths.txt.
---

# evolve (admin-apex tasks 5/6)

Spec: `skills/admin-apex/SKILL.md` task 5 (compose plan) + task 6 (apply).

## Inputs

- `.claude-tmp/admin-apex-active/{run}-drift-report.json` (from `audit.md`)
- Gate decisions from SKILL task 4 (per cluster: `keep | apply | defer`)
- `.claude-tmp/admin-apex-active/{run}-inventory.json` (re-read before each op)

## Outputs

- `.claude-tmp/admin-apex-active/{run}-evolve-plan.json` (task 5; conforms to `schemas/evolve-plan.schema.json`)
- `.claude-tmp/admin-apex-active/{run}-applied-ops.json` (task 6; appended after each successful op)
- `.claude-tmp/admin-apex-active/{run}-dirty-paths.txt` (task 6; one repo-relative path per line)

## Task 5: Compose evolve plan

For each cluster the gate marked `apply`, translate items into ops:

| Cluster | Default op |
|---------|-----------|
| `oversized-files` | `split` (target = oversized file; `split_into` = candidate names per concern) |
| `orphan-refs` | `retire` if file gone; otherwise rewrite-only via sync-docs (no evolve op needed) |
| `missing-refs` | doc-only via sync-docs (no evolve op needed) - mark as `doc_only: true` placeholder if surfaced |
| `stale-spec` | hard-stop cluster: SKILL must downgrade to audit-only; this skill should NOT see `apply` for stale-spec. If it does, abort with explicit error. |
| `schema-mismatch` | `rename` (rename schema file to match `$id`) OR edit `$id` to match basename - prefer rename (safer; refs less coupled). |
| `dead-hook` | `hook-remove` (settings.json entry deletion) |

Set `doc_only: true` for any op that does NOT touch `skills/apex/`, `agents/`, or `settings.json` (only README/apex-core/overview/CLAUDE.md edits). Drives task 9 patch-vs-minor bump rule.

Validate the plan before write. Admin-apex schemas live at `skills/admin-apex/schemas/` (siblings of apex schemas). Two equivalent invocation paths:

```
# Preferred: shell wrapper (sets APEX_SCHEMA_DIR internally under --admin)
bash skills/apex/scripts/validate-json.sh --admin evolve-plan {path}

# Direct python (e.g., from inline scripts that already build the data dict)
APEX_SCHEMA_DIR=$HOME/.claude/skills/admin-apex/schemas \
  PYTHONPATH=$HOME/.claude/skills/apex/scripts \
  python3 -c "from _validate import producer_validate; ..."
```

`APEX_SCHEMA_DIR` is the canonical override read by `_validate.py` at module load. Exit 0 = valid; exit 1 = malformed (abort with explicit error).

Strict-mode: admin-apex task 1 calls `scripts/check-deps.sh`, which hard-fails if `jsonschema` is missing. So evolve never reaches the lenient parse-only fallback (that fallback exists only for apex hot path).

## Task 6: Apply ops

Per-op loop. Before each op:

1. **Re-snapshot inventory**: `bash scripts/inventory-apex.sh --out .claude-tmp/admin-apex-active/{run}-inventory-step{N}.json`
2. **Diff against** `{run}-inventory.json`. If any path the upcoming op depends on (target / merge_sources / split source) has moved/renamed/disappeared since task 2, that is **mid-flight drift**.
3. On drift -> AskUserQuestion (header: "Mid-flight drift on op {N}"):
   - `restart` - abort current op, re-run audit (SKILL task 3) with current state
   - `commit-partial` - skip remaining ops, jump to task 7 (sync-docs) with applied ops so far
   - `rollback` - explicit user-confirmed `git restore` on every path in `{run}-applied-ops.json`. **This is the only admin-apex codepath that runs `git restore`**, and only via this gate. Untouched paths are NOT restored.
   - Dismiss / cancel = `restart`

### Per-op execution

Use `Glob` and `Grep` (or `scripts/grep-apex-refs.sh`) BEFORE any `Edit` to confirm each ref site. NEVER blind-edit.

| Kind | Steps |
|------|-------|
| `create` | Verify `target` does not exist. `Write` new file (caller supplies content via the gate prompt). |
| `rename` | Verify `target` exists and `rename_to` does not. `mv` via Bash (NOT `git mv`; explicit single-step). For each ref returned by `grep-apex-refs.sh <basename(target)>`, `Edit` to point at `rename_to`. Mirror absolute path refs too. |
| `split` | Read `target`. For each path in `split_into`, `Write` an extracted concern. After all writes, delete the original via `rm` (Bash). Update refs in spec docs to point at the new files (defer the spec-doc edits to sync-docs.md when applicable). |
| `merge` | For each `merge_sources` path, append its body into `target` (host file is `target`). After all appended, `rm` each source. Rewrite refs from sources -> target via `grep-apex-refs.sh` + `Edit`. |
| `retire` | `grep-apex-refs.sh` first. If any non-doc reference remains, abort the op with explicit error (the cluster did not capture the full ref graph). Otherwise `rm` and let sync-docs prune doc references. |
| `schema-add` / `schema-remove` | Mirror `create` / `retire`. Producer must enforce `$id == basename`. |
| `hook-add` / `hook-remove` | Edit `settings.json` only. JSON edit via Python (not Edit tool) to preserve formatting; one-shot inline `python3 -c "..."` snippet. |

After each successful op, append the op (verbatim from the plan) to `.claude-tmp/admin-apex-active/{run}-applied-ops.json` (JSON array, append-and-rewrite). Append every modified/created/deleted path to `{run}-dirty-paths.txt`.

## Failure modes

- Op fails mid-execution (e.g., Edit fails because the target line is gone) -> roll back THIS op only (not prior ops); surface to gate as drift; AskUserQuestion (`restart | commit-partial | rollback`).
- All ops `doc_only: true` -> task 9 picks `patch` bump.
- Any non-doc op succeeds -> task 9 picks `minor` bump.

## Mid-flight drift example

Task 6 op 3 expects `skills/apex/p1.md`. Re-snapshot at op 3 shows `p1.md` is gone (a sibling /apex session moved it). Surface AskUserQuestion. `restart` -> SKILL re-enters task 3; `commit-partial` -> jump to task 7 with ops 1-2 only; `rollback` -> `git restore` on `{run}-dirty-paths.txt`.

## What this skill does NOT do

- Does NOT edit spec docs directly (README/apex-core/overview/CLAUDE.md). That is `sync-docs.md` (task 7).
- Does NOT bump VERSION or commit. That is task 9.
- Does NOT touch project app code; apex-internal only.
- Does NOT silently retry on op failure; always surfaces via AskUserQuestion.

See `skills/apex/shared-guardrails.md` for the JSON-Schema validation contract; admin-apex schemas live at `skills/admin-apex/schemas/`.
