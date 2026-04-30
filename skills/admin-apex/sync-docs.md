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

- `.claude-tmp/admin-apex-active/{run}-docs-changed.txt` - one repo-relative path per line; lines may repeat (one per Edit). Used by SKILL task 9 git-add manifest.

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

5. **Write `docs-changed.txt`** even if empty - SKILL task 9 expects the file to exist.

## Glob/Grep before Edit

For every Edit call:
- Run `grep-apex-refs.sh <old>` first to enumerate occurrences.
- Run `Read` on the file before composing `old_string` so the line snippet is verbatim (the file-health hook + scope-check hook fire on Edit; reading first matches apex orchestrator convention).
- Use `replace_all: false` (default). If multiple identical lines need rewriting in one file, expand `old_string` with surrounding context to make each match unique.

## Doc surfaces NOT in scope

- Project app docs under `docs/` - those are scout / documentation.md territory, not admin-apex.
- Lesson files (`.claude/lessons*.md`) - owned by the future `/apex-improve` workflow.
- Reflector log (`~/.claude/tmp/apex-workflow-improvements.md`) - same.

## Doc-only ops

If task 5 emitted any op with `doc_only: true` and it survived the gate, this skill is the executor. Treat it like a `rename` whose old/new tokens are user-supplied via the gate prompt; no `evolve.md` artifact change.

## What this skill does NOT do

- Does NOT touch `skills/` or `agents/` files; those were already rewritten in evolve.md task 6.
- Does NOT bump VERSION or commit; SKILL task 9 owns that.
- Does NOT add new sections to docs; only rewrites existing references. New-section drafting is out of scope (would require human review).

See `skills/admin-apex/SKILL.md` for the orchestrator chain and gate semantics; `skills/apex/shared-guardrails.md` for safety paths and Edit-tool conventions.
