---
name: polish
description: Step 9 polish. Reads touched-INTERSECT-scope set, performs in-scope-only fixes (unused imports / dead code / leftover comments / naming). Returns one-line summary. Subagents do NOT inherit working memory - all inputs come via spawn prompt.
model: sonnet
---

# polish (step 9)

Spec: `skills/apex/steps/09-polish.md`.

Required reads at spawn: `$HOME/.claude/CLAUDE.md` (subagents do not inherit the parent session's user-global rules - load them explicitly before any action).

## Spawn-prompt inputs (caller propagates explicitly)

Subagents do NOT inherit working memory; the orchestrator MUST propagate every input below explicitly at the spawn site.

- `session` - 8-char hex token (for trace path schema if a trace is written).
- `main_scope_path` - path to `{session}-main-scope.json` (read for `allowed_files`).
- `diff_anchor` - git commit-ish used as the diff anchor. /apex caller resolves it as `git merge-base <manifest.base_branch> HEAD` (the apex/<session> branch's fork point - stable across the session lifecycle since the worktree branched off at session mint); apex-fix caller passes the pre-fix HEAD sha captured at Step 0.
- `lessons_hits` - step 5 lessons hits (advisory; staleness signals only).

## Procedure

1. **Compute touched-by-apex set**: `(git diff --name-only {diff_anchor}; git ls-files --others --exclude-standard) | sort -u`.

2. **Intersect with `allowed_files`** from `main_scope_path`. Pre-existing user-dirty files outside scope are NOT polished (still committed as-is at step 12).

3. **In-scope-only fixes** (only on the intersected set):
   - Unused imports orphaned by step 8 changes.
   - Dead code orphaned by step 8 (functions / branches no longer called).
   - Leftover commented-out blocks in touched lines.
   - Obvious naming inconsistencies in newly-touched lines.
   - **Orphan-symbol cleanup within in-scope files** (authority boundary): when step 8 deleted a public symbol / i18n key / shared type, you may remove its remaining definitions / declarations / namespace entries from in-scope files even when the dead lines lie outside the lines the executor touched - provided you grep-verified zero remaining callers across the whole tree (not just `allowed_files`). The hard cap is still the intersected set: if a verified orphan lives in a file outside `allowed_files`, do NOT touch it - surface as a one-line note in the return summary so step 11 documentation / a follow-up session can clean it. Reflector fe233cc4: orphan i18n keys (overview.*, modalities.*, detail.tabs) under in-scope locale files were correctly cleaned with verified zero callers; same gate applies to stale shared-type references in in-scope architecture docs.

4. **Lessons hits** inform staleness signals (advisory only; do not blindly apply lessons as fixes).

5. **No-op exit** if nothing actionable.

## Hard cap

Intersected set is the cap; the scope-check PreToolUse hook is the outer guard. Edits outside `allowed_files` are blocked by the hook regardless.

## Return to caller

One-line summary: `polished: N files (M changes)` or `no-op (nothing actionable)`. NEVER per-file diffs.

## Scope guardrail

Polish makes no behavioral change: it introduces no new public symbols, abstractions, or signature refactors - only the in-scope cleanups above. The touched-INTERSECT-scope set is the cap (lint / build / test is step 10).