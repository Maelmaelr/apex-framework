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
| `user-driven` | `edit` per cluster item (each `items[]` path becomes one `edit` op; `rationale` = the cluster `summary` so the user concern propagates verbatim into the audit trail). If `items` is empty, emit a single `edit` op with `target = skills/admin-apex/SKILL.md` as a placeholder so the planner is forced to redirect at validation time (signals "concern is informational, no concrete file picked"). `doc_only` follows the standard rule: true iff every target sits outside `skills/apex*/`, `skills/admin-apex/`, `agents/`, `settings.json`. **Stub drift-report on the user-concern override path:** when audit tasks 2-3 were bypassed (mode=audit+apply driven by a user concern) so no `{run}-drift-report.json` is on disk, write a stub `{run}-drift-report.json` = `{"scope":"user-concern","clusters":[<the user-driven cluster>]}` BEFORE composing the plan - the artifact must exist so the reflector does not flag a false "no drift-report / drift detection bypassed" gap (reflector 8ec42151). |

Set `doc_only: true` for any op that does NOT touch `skills/apex*/`, `skills/admin-apex/`, `agents/`, or `settings.json` (only README/apex-core/overview/CLAUDE.md edits). The `skills/apex*/` glob covers `skills/apex/` and every `skills/apex-*/` sibling (apex-lessons, apex-improve, apex-tech-watch, apex-init, apex-fix, apex-eod, apex-file-health) so a logic edit to any of them classifies as non-doc_only and bumps minor (reflector f00a80eb: an apex-lessons/route.md logic edit was misclassified doc_only=true under the old `skills/apex/`-only prefix). Drives task 9 patch-vs-minor bump rule. The `skills/admin-apex/` inclusion is what makes structural mutations to admin-apex itself (e.g., split `evolve.md`, retire a sub-skill) correctly classify as non-doc_only and bump minor.

**Cluster-vs-applied-ops accounting.** A drift cluster routinely mixes code-edit targets (which become evolve ops here) with doc-sync targets (apex-core.md / overview / SKILL.md spec mirrors, applied by sync-docs task 7, NOT evolve ops). `applied-ops.json` therefore covers only the code-edit subset, so a smaller applied-ops count than cluster `items[]` size is expected, not a miss - audits must compare applied-ops against the code-edit items only (reflector bc695e6f: a 4-item cluster with 2 code edits + 3 doc-sync targets read as a phantom 2-vs-4 discrepancy). **Skip-rationale record.** When the plan does NOT translate a cluster `items[]` entry into an op (already-fixed in current code, intentionally deferred, doc-sync-only, etc.), record the skip in `_meta.skipped_items`: an array of `{path, cluster_id, reason}` triples added alongside `_meta.source_clusters`. The reflector reads this list to distinguish skipped-by-design from forgotten and stops flagging the cluster-vs-ops gap (reflector 77eb9f50: a 9-item cluster produced 6 ops + 3 silent drops with no audit trail). **Placeholder-redirect entries.** When the planner auto-redirects a user-driven placeholder target (the `skills/admin-apex/SKILL.md` placeholder emitted for an empty-items cluster, OR an items[] entry replaced because the user-concern body names a different concrete target), append `{path: <original placeholder>, cluster_id, reason: "redirected to <new target>"}` to `_meta.skipped_items` AND retain the legacy `_meta.redirected_from` mapping for traceability - the skipped_items entry is what makes the redirect visible to `analyze.md` clustering across runs (reflector 8d961553: redirect recorded only in `_meta.redirected_from`, invisible to clustering). The evolve-plan schema's `_meta` is open-shape so both keys are accepted without a schema bump.

**Plan is the single source of op rationale.** `{run}-evolve-plan.json` is authoritative; `{run}-applied-ops.json` MUST NOT restate the `rationale` / `target` / `kind` fields of an op verbatim - applied entries reference the plan by op-index (`{plan_op_index: N, status: applied, delta_lines: ..., dirty_paths: [...]}`) and any structured outcome fields (drift, errors, retries). Task 6 may patch the plan in place before applying when an auto-fix or scope-overspill discovers an extra op (preserve original `_meta.generated_at`; bump `_meta.amended_at`); task 8 auto-fixes that add ops likewise patch the plan first, NEVER append directly to applied-ops without a plan op. Closes the recurring plan-vs-applied divergence cluster (reflector 5df5c184 10-vs-13 count delta; 5b218a81 verbatim duplication doubling artifact size; 67cd0fff ~117 vs ~25 LOC rationale drift; ac85c725 passively-mirrored files conflated with applied ops).

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

1. **Re-snapshot inventory**: `bash scripts/inventory-apex.sh --out .claude-tmp/admin-apex-active/{run}-inventory-current.json` (constant filename, overwritten between ops; never emit per-step files - the drift check below is the sole consumer, so `step1` / `step2` / `post` snapshots are pure artifact bloat, reflectors ac85c725 / 67cd0fff / 8917fc0e).
2. **Diff against** `{run}-inventory.json`. If any path the upcoming op depends on (target / merge_sources / split source) has moved/renamed/disappeared since task 2, that is **mid-flight drift**. Skip the post-mirror inventory write entirely - the drift report is the only downstream consumer and it lives in `{run}-drift-report.json`, not in a final inventory snapshot.
3. On drift -> AskUserQuestion (header: "Mid-flight drift on op {N}"):
   - `restart` - abort current op, re-run audit (SKILL task 3) with current state
   - `commit-partial` - skip remaining ops, jump to task 7 (sync-docs) with applied ops so far
   - `rollback` - explicit user-confirmed `git restore` on every path in `{run}-applied-ops.json`, then `bash skills/admin-apex/scripts/cleanup-run.sh --run {run} --post-success`. Untouched paths are NOT restored. (Task 8 `rollback-evolve` is the other admin-apex codepath that runs `git restore`.)
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

After each successful op, append an outcome entry to `.claude-tmp/admin-apex-active/{run}-applied-ops.json` (JSON array, append-and-rewrite) of shape `{plan_op_index: N, status: "applied", delta_lines: <int|null>, dirty_paths: [<paths>], notes: <optional>}` - reference the plan op by index, do NOT restate `kind` / `target` / `rationale` (per the plan-is-authoritative rule above). Append every modified/created/deleted path to `{run}-dirty-paths.txt` as a clean repo-relative path with NO trailing ` (deleted)` suffix - `admin-apex-finalize.sh` strips defensively but writers MUST emit clean paths to avoid xargs split (reflector 00d40528).

## Failure modes

- Op fails mid-execution (e.g., Edit fails because the target line is gone) -> roll back THIS op only (not prior ops); surface to gate as drift; AskUserQuestion (`restart | commit-partial | rollback`).
- All ops `doc_only: true` -> task 9 picks `patch` bump.
- Any non-doc op succeeds -> task 9 picks `minor` bump.

## Async token-accounting (concurrent /apex sessions)

Task 9 (commit) and task 10 (mirror + push) are not atomic across concurrent /apex orchestrators sharing `~/.claude`. A sibling session's commit can land between this run's commit and its mirror; the post-mirror diff at `dev/apex-framework` will then include that sibling commit as well as this run's. This is **expected**, not state corruption: `mirror-to-dev.sh` rsyncs current ~/.claude state, so it tracks any commit landed by mirror time. Reflectors that surface `non-convergence: prior session X touched {...}` after the mirror window are flagging the same window. No mid-flight remediation is required - sibling commits are pushed to public dev on their next run, and the public dev branch converges to the same HEAD as ~/.claude.

## Mid-flight drift example

Task 6 op 3 expects `agents/discoverer.md`. Re-snapshot at op 3 shows `discoverer.md` is gone (a sibling /apex session moved it). Surface AskUserQuestion. `restart` -> SKILL re-enters task 3; `commit-partial` -> jump to task 7 with ops 1-2 only; `rollback` -> `git restore` on `{run}-dirty-paths.txt`.

## What this skill does NOT do

- Does NOT edit spec docs directly (README/apex-core/overview/CLAUDE.md). That is `sync-docs.md` (task 7).
- Does NOT bump VERSION or commit. That is task 9.
- Does NOT touch project app code; apex-internal only.
- Does NOT silently retry on op failure; always surfaces via AskUserQuestion.

See `apex-core.md` Conventions for the JSON-Schema validation contract; admin-apex schemas live at `skills/admin-apex/schemas/`.
