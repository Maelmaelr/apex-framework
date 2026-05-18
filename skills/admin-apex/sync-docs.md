---
name: sync-docs
description: Rewrites references in README.md, apex-core.md, apex-core-overview.md, and project CLAUDE.md apex sections after evolve.md applied structural ops. Glob/Grep before any Edit. Returns docs-changed.txt.
---

# sync-docs (admin-apex task 7)

Spec: `skills/admin-apex/SKILL.md` task 7.

## Inputs

- `.claude-tmp/admin-apex-active/{run}-applied-ops.json` (from `evolve.md`)
- Spec docs (read targets): `README.md`, `apex-core.md`, `apex-core-overview.md`, repo-root `CLAUDE.md` (if present)

## Output

- `.claude-tmp/admin-apex-active/{run}-docs-changed.txt` - one repo-relative path per line, **deduplicated** before the final write (a file edited N times appears once). Used by SKILL task 9 git-add manifest.

## Procedure

1. **Read applied-ops**:
   ```
   ops=$(jq -c '.[]' .claude-tmp/admin-apex-active/{run}-applied-ops.json)
   ```
   Empty array -> exit 0 (no doc changes needed).

2. **For each op, derive ref-rewrite pairs**:

   | Op kind | Old token -> new token |
   |---------|-------------------------|
   | `rename` | `target` -> `rename_to` (full path AND basename) |
   | `split` | `target` -> first `split_into[0]` (heuristic: primary successor); add a "see also" line for the rest in the same paragraph |
   | `merge` | each `merge_sources[i]` -> `target` |
   | `retire` | `target` -> (delete the doc line entirely; if line is part of a list/table row, drop the row) |
   | `create` / `schema-add` / `hook-add` | (no rewrite; new file may need a doc mention - flagged but NOT auto-added; surface as missing-ref next audit) |
   | `schema-remove` / `hook-remove` | mirror `retire` |

3. **For each rewrite pair**:
   1. Run `scripts/grep-apex-refs.sh <old-token>` to get every hit.
   2. For each hit in spec docs (`README.md`, `apex-core.md`, `apex-core-overview.md`, `CLAUDE.md`):
      - `Read` the file at the hit line.
      - `Edit` with `old_string` = surrounding context (enough to be unique) and `new_string` = same context with `<old-token>` replaced by `<new-token>`.
      - Append the file path to `{run}-docs-changed.txt`.
   3. Hits inside `skills/` or `agents/` are NOT touched here - those were rewritten by `evolve.md` task 6 already.

4. **For `retire` / `*-remove`**: read the line containing the old-token, decide if it is a list item / table row / paragraph sentence, and `Edit` to drop it (preserve surrounding markdown structure). When in doubt, leave a single-line marker:
   ```
   <!-- removed: <old-token> ({run}) -->
   ```
   so the next audit surfaces a `dead comment` cleanup.

5. **Write `docs-changed.txt`** even if empty - SKILL task 9 expects the file to exist. Dedup the accumulated paths before the final write (`sort -u`, or equivalent): a file edited N times in step 3 must appear exactly once. Duplicate entries waste downstream git-add reads and make the audit trail misleading (reflectors 130a8c9f + 19826768: apex-core.md listed twice across two runs).

6. **Polish (post-implementation check)**: `bash scripts/polish-check.sh --run {run}`. Re-snapshots inventory, re-runs the orphan-refs / missing-refs / schema-mismatch / dead-hook detectors (mirrors `audit.md`), diffs against `{run}-drift-report.json` so only NEW drift introduced by evolve apply + sync-docs surfaces. Skipped automatically when 0 ops applied.
   - Exit `0` -> clean; continue.
   - Exit `1` -> new drift in `{run}-polish-report.json`. Treat exactly like the out-of-scope stale-refs escalation below: append a finding-shaped block to `~/.claude/tmp/apex-workflow-improvements.md` (one per cluster) so the next `/apex-improve` run picks it up; do NOT block the current admin-apex run.
   - Exit `2` -> bad args / state corruption; abort with explicit error.

## Out-of-scope stale-refs: escalation

While processing rewrite hits in step 3, sync-docs may encounter stale-refs in spec docs that are NOT in this run's `applied-ops.json` (e.g., a previously removed CLAUDE.md section that an old comment still cites). The rewrite map cannot fix them - they are out-of-scope for the current run. Instead of leaving them as silent rot in reflector logs as manual follow-ups, append a finding-shaped block to `~/.claude/tmp/apex-workflow-improvements.md` so the next `/apex-improve` invocation picks it up:

```
## sync-docs - stale-ref - {ISO-8601}
- gaps: stale-ref in {file}:{line} ({old-token} no longer exists)
- improvements: rewrite or remove
```

Continue processing the in-scope rewrites; do NOT block the current admin-apex run on out-of-scope drift. This closes the manual-follow-up loop.

## Glob/Grep before Edit

For every Edit call:
- Run `grep-apex-refs.sh <old>` first to enumerate occurrences.
- Run `Read` on the file before composing `old_string` so the line snippet is verbatim (the file-health hook + scope-check hook fire on Edit; reading first matches apex orchestrator convention).
- Use `replace_all: false` (default). If multiple identical lines need rewriting in one file, expand `old_string` with surrounding context to make each match unique.

## Doc surfaces NOT in scope

- Project app docs under `docs/` - those are documentation.md territory (apex step 11), not admin-apex.
- Lesson files (`.claude/lessons*.md`) - owned by the future `/apex-improve` workflow.
- Reflector log (`~/.claude/tmp/apex-workflow-improvements.md`) - same.

## Doc-only ops

If task 5 emitted any op with `doc_only: true` and it survived the gate, this skill is the executor. Treat it like a `rename` whose old/new tokens are user-supplied via the gate prompt; no `evolve.md` artifact change.

## What this skill does NOT do

- Does NOT touch `skills/` or `agents/` files; those were already rewritten in evolve.md task 6.
- Does NOT bump VERSION or commit; SKILL task 9 owns that.
- Does NOT add new sections to docs; only rewrites existing references. New-section drafting is out of scope (would require human review).

See `skills/admin-apex/SKILL.md` for the orchestrator chain and gate semantics; `apex-core.md` Conventions for safety paths and Edit-tool conventions.
